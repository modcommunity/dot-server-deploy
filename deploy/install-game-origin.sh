#!/usr/bin/env bash
#
# Render deploy/game-origin.nginx.template and install it.
#
# The game is served from an origin of its own -- see the template for why that
# is a security boundary and not a deployment preference. Which domain that is
# differs per deployment, so nothing here hardcodes one: the domain, the site
# origins allowed to frame it, the web root and the certificate are all
# arguments, and every one of them has an environment variable behind it.
#
#   ./deploy/install-game-origin.sh --domain games.example.com \
#       --site-origins "https://example.com" \
#       --cert /etc/letsencrypt/live/games.example.com/fullchain.pem \
#       --key  /etc/letsencrypt/live/games.example.com/privkey.pem
#
# --self-signed makes a certificate for the domain first, which is what a
# development box wants and what a real one must not have.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; OFF=$'\e[0m'
die() { printf '\n  %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn(){ printf '  %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }

DOMAIN="${TMC_GAME_DOMAIN:-games.example.net}"
SITE_ORIGINS="${TMC_SITE_ORIGINS:-https://example.com https://www.example.com}"
WEB_ROOT="${TMC_GAME_WEB_ROOT:-/srv/tmc-game}"
# Where the packs a game downloads while it plays are served from. Beside the player
# rather than inside it: `./server export-web` rewrites the web root on every export,
# and content that lived under it would be deleted by a rebuild of the client.
CONTENT_ROOT="${TMC_GAME_CONTENT_ROOT:-/srv/tmc-content}"
SSL_CERT="${TMC_GAME_SSL_CERT:-}"
SSL_KEY="${TMC_GAME_SSL_KEY:-}"
CACHE_CONTROL="${TMC_GAME_CACHE_CONTROL:-no-store}"
SELF_SIGNED=""
LOCAL_CA=""
CA_CERT="${TMC_LOCAL_CA_CERT:-/opt/tmc-local-ca.crt}"
CA_KEY="${TMC_LOCAL_CA_KEY:-/opt/tmc-local-ca.key}"
SITES_DIR="${TMC_NGINX_SITES_DIR:-/etc/nginx/sites-available}"
ENABLED_DIR="${TMC_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)       DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
        --site-origins) SITE_ORIGINS="${2:?--site-origins needs a value}"; shift 2 ;;
        --root)         WEB_ROOT="${2:?--root needs a value}"; shift 2 ;;
        --content-root) CONTENT_ROOT="${2:?--content-root needs a value}"; shift 2 ;;
        --cert)         SSL_CERT="${2:?--cert needs a value}"; shift 2 ;;
        --key)          SSL_KEY="${2:?--key needs a value}"; shift 2 ;;
        --cache)        CACHE_CONTROL="${2:?--cache needs a value}"; shift 2 ;;
        --self-signed)  SELF_SIGNED=1; shift ;;
        --local-ca)     LOCAL_CA=1; shift ;;
        --ca-cert)      CA_CERT="${2:?--ca-cert needs a value}"; shift 2 ;;
        --ca-key)       CA_KEY="${2:?--ca-key needs a value}"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
        *)              die "unknown argument: $1" 2 ;;
    esac
done

case "$DOMAIN" in
    ''|*/*|*:*) die "--domain is a bare hostname, not a URL: $DOMAIN" 2 ;;
esac

# The check the whole arrangement rests on. Serving the game from an origin the
# site also serves from turns the iframe sandbox into a no-op, so refuse it here
# as well as in the loader -- this is the copy a person reads.
for origin in $SITE_ORIGINS; do
    if [ "${origin#*://}" = "$DOMAIN" ] || [ "${origin#*://}" = "www.$DOMAIN" ]; then
        die "the game domain ($DOMAIN) is also a site origin ($origin).
  The frame sandbox is only a boundary while the game is cross-origin with the
  page that frames it. Give the game a domain of its own." 2
    fi
done

if [ -n "$LOCAL_CA" ]; then
    # A LOCAL CERTIFICATE AUTHORITY, rather than a self-signed leaf.
    #
    # Both are untrusted until somebody says otherwise, so this looks like the
    # same amount of work. It is not, for two reasons.
    #
    # A self-signed LEAF has to be trusted once per name, and browsers increasingly
    # refuse to remember that: Firefox reports MOZILLA_PKIX_ERROR_SELF_SIGNED_CERT
    # and tells the visitor there is nothing they can do. A CA is trusted ONCE, on
    # the machine, and then every name it issues is simply valid -- including the
    # next game domain, and the site's own.
    #
    # And it is the only thing that fixes the IFRAME. A certificate error inside a
    # frame produces no interstitial and no click-through: the frame is blank and
    # the console says almost nothing. There is no "accept the risk" to press,
    # because nothing asks. So an exception added for the top-level URL is not
    # enough to make the player work, and a trusted issuer is.
    SSL_CERT="${SSL_CERT:-/opt/$DOMAIN.crt}"
    SSL_KEY="${SSL_KEY:-/opt/$DOMAIN.key}"

    if [ -f "$CA_CERT" ] && [ -f "$CA_KEY" ]; then
        ok "local CA already present: $CA_CERT"
    else
        sudo openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
            -keyout "$CA_KEY" -out "$CA_CERT" \
            -subj "/CN=TMC Local Development CA/O=TMC Development" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1 \
            || die "could not create a CA at $CA_CERT"

        sudo chmod 600 "$CA_KEY"; sudo chmod 644 "$CA_CERT"
        ok "created local CA: $CA_CERT"
    fi

    # The leaf. Reissued every run: it is cheap, and a stale one outliving a
    # changed SAN list is a confusing failure.
    tmpdir="$(mktemp -d)"
    cat > "$tmpdir/ext" <<EXT
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$DOMAIN,DNS:www.$DOMAIN,DNS:*.$DOMAIN
EXT

    sudo openssl req -newkey rsa:2048 -nodes -keyout "$SSL_KEY" \
        -out "$tmpdir/csr" -subj "/CN=$DOMAIN/O=TMC Development" >/dev/null 2>&1 \
        || die "could not create a key for $DOMAIN"

    sudo openssl x509 -req -in "$tmpdir/csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
        -CAcreateserial -out "$SSL_CERT" -days 825 -sha256 \
        -extfile "$tmpdir/ext" >/dev/null 2>&1 \
        || die "could not sign a certificate for $DOMAIN"

    rm -rf "$tmpdir"
    sudo chmod 640 "$SSL_KEY"; sudo chmod 644 "$SSL_CERT"
    ok "issued $SSL_CERT, signed by the local CA"

    TRUST_CA="$CA_CERT"

elif [ -n "$SELF_SIGNED" ]; then
    SSL_CERT="${SSL_CERT:-/opt/$DOMAIN.crt}"
    SSL_KEY="${SSL_KEY:-/opt/$DOMAIN.key}"

    if [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; then
        ok "certificate already present: $SSL_CERT"
    else
        sudo openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$SSL_KEY" -out "$SSL_CERT" -days 3650 \
            -subj "/CN=$DOMAIN/O=TMC Development" \
            -addext "subjectAltName=DNS:$DOMAIN,DNS:www.$DOMAIN,DNS:*.$DOMAIN" \
            -addext "basicConstraints=CA:FALSE" \
            -addext "keyUsage=digitalSignature,keyEncipherment" \
            -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 \
            || die "could not write a certificate to $SSL_CERT"

        sudo chmod 640 "$SSL_KEY"; sudo chmod 644 "$SSL_CERT"
        ok "self-signed certificate: $SSL_CERT"
    fi

    warn "a self-signed certificate is refused by every browser until somebody
       trusts it. Development only -- use a real one in production."
fi

[ -n "$SSL_CERT" ] || die "no certificate: pass --cert/--key, or --self-signed for a development box" 2
[ -n "$SSL_KEY" ]  || die "no key: pass --key" 2

TEMPLATE="$ROOT/deploy/game-origin.nginx.template"
[ -f "$TEMPLATE" ] || die "missing $TEMPLATE"

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

sed -e "s|@GAME_DOMAIN@|$DOMAIN|g" \
    -e "s|@SITE_ORIGINS@|$SITE_ORIGINS|g" \
    -e "s|@WEB_ROOT@|$WEB_ROOT|g" \
    -e "s|@CONTENT_ROOT@|$CONTENT_ROOT|g" \
    -e "s|@SSL_CERT@|$SSL_CERT|g" \
    -e "s|@SSL_KEY@|$SSL_KEY|g" \
    -e "s|@CACHE_CONTROL@|$CACHE_CONTROL|g" \
    "$TEMPLATE" > "$rendered"

if grep -q '@[A-Z_]*@' "$rendered"; then
    die "template still has placeholders: $(grep -o '@[A-Z_]*@' "$rendered" | sort -u | tr '\n' ' ')"
fi

if [ -n "$DRY_RUN" ]; then
    cat "$rendered"
    exit 0
fi

sudo install -m 644 "$rendered" "$SITES_DIR/$DOMAIN.conf" || die "could not write $SITES_DIR/$DOMAIN.conf"
sudo ln -sf "$SITES_DIR/$DOMAIN.conf" "$ENABLED_DIR/$DOMAIN.conf"
ok "installed $SITES_DIR/$DOMAIN.conf"

sudo nginx -t >/dev/null 2>&1 || { sudo nginx -t; die "nginx rejected the configuration"; }
sudo systemctl reload nginx || die "could not reload nginx"

ok "nginx reloaded"
printf '\n  %sthe game is served from%s  https://%s/game/\n' "$BLD" "$OFF" "$DOMAIN"
printf '  %sframeable by%s            %s\n' "$BLD" "$OFF" "$SITE_ORIGINS"

if [ -n "${TRUST_CA:-}" ]; then
    cat <<TRUST

  ${BLD}Trust the CA once per machine${OFF}, or the engine's iframe stays blank with
  no prompt -- a certificate error inside a frame raises no interstitial.

    copy it over        scp $(whoami)@$(hostname -I 2>/dev/null | awk '{print $1}'):$TRUST_CA .

    Firefox             Settings -> Privacy & Security -> Certificates ->
                        View Certificates -> Authorities -> Import,
                        tick "Trust this CA to identify websites".
                        Firefox has its OWN store and ignores the system one.

    Chrome / Brave      Settings -> Privacy and security -> Security ->
                        Manage certificates -> Authorities -> Import.
                        On Linux, or headlessly:
                        certutil -d sql:\$HOME/.pki/nssdb -A -t "C,," \\
                            -n "TMC Local Development CA" -i $(basename "$TRUST_CA")

    Linux system-wide   sudo cp $(basename "$TRUST_CA") /usr/local/share/ca-certificates/ \\
                          && sudo update-ca-certificates
    macOS               sudo security add-trusted-cert -d -r trustRoot \\
                          -k /Library/Keychains/System.keychain $(basename "$TRUST_CA")

TRUST
else
    printf '\n'
fi
