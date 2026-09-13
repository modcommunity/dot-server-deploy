#!/usr/bin/env bash
#
# Get a real certificate from Let's Encrypt, by whichever method this box allows.
#
#   sudo ./deploy/issue-letsencrypt.sh --domain demo.example.com --email ops@example.com
#   sudo ./deploy/issue-letsencrypt.sh --method dns --dns-plugin cloudflare \
#        --dns-credentials /root/.secrets/cloudflare.ini \
#        --domain example.com --wildcard --email ops@example.com
#
# THE METHODS, and the one question that picks between them: what can reach this
# box, and on which port?
#
#   webroot     (default) HTTP-01, answered out of a directory an already-running
#               nginx serves. Nothing restarts and nothing is reconfigured.
#               Needs :80 reachable from the internet. --webroot DIR.
#   nginx       HTTP-01, with certbot driving nginx for the length of the challenge
#               and putting it back. Use when :80 is served but you do not know
#               which webroot. `certonly`, so it never edits the vhosts this repo
#               writes -- see below.
#   standalone  HTTP-01, with certbot binding :80 itself. For a box with no web
#               server, or one where nginx can stop for ten seconds. Installs the
#               stop/start hooks so RENEWALS work too, which is the half people
#               leave out.
#   dns         DNS-01 through a certbot plugin. The only method that issues a
#               WILDCARD, and the only one that works when :80 is closed, behind
#               CGNAT, or answered by somebody else. --dns-plugin, --dns-credentials.
#   manual      DNS-01 you satisfy by hand: it prints a TXT record and waits.
#               Fine once, and it CANNOT renew unattended. Needs a terminal.
#
# --staging issues from the staging CA: an untrusted certificate, off the rate
# limits, and the correct first run on a name you have not proved out. The limits
# on the real one are low enough to matter -- five failed validations per hostname
# per hour, fifty certificates per registered domain per week -- and they are
# counted against FAILURES, so a misconfigured webroot locks you out for an hour.
# --dry-run prints the certbot invocation and exits; --certbot-dry-run runs the
# whole validation for real and keeps nothing.
#
# WHAT THIS DOES THAT `certbot` ALONE DOES NOT
#
#   1. It probes the challenge path BEFORE asking Let's Encrypt to, so a webroot
#      that is not the one nginx serves costs a curl instead of a rate limit.
#   2. It writes a DEPLOY HOOK. A packaged certbot renews on a timer and reloads
#      NOTHING: the files under /etc/letsencrypt change, nginx goes on serving the
#      certificate it opened at startup, and sixty days later a browser that has
#      never been told anything reports an expired certificate on a box where
#      `certbot renew` has been succeeding all along. This is the single most
#      common way TLS breaks here.
#   3. It can COPY the pair somewhere a non-root process can read. Everything under
#      /etc/letsencrypt/archive is 0700 root, so a dot-server that terminates TLS
#      itself, or one in a container with its own mounts, cannot read privkey.pem
#      no matter what the config says. --install-to.
#   4. It hands you the next command -- install-server-tls.sh with these paths
#      already in it.
#
# Every argument has an environment variable behind it (TMC_LE_*), because a unit
# file or a CI job cannot add an argument to a line somebody else wrote. See
# deploy/env.example.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; DIM=$'\e[2m'; BLD=$'\e[1m'; OFF=$'\e[0m'
die()  { printf '\n  %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }
ok()   { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }
step() { printf '\n%s==>%s %s\n' "$BLD" "$OFF" "$1"; }
say()  { printf '       %s%s%s\n' "$DIM" "$1" "$OFF"; }

METHOD="${TMC_LE_METHOD:-webroot}"
EMAIL="${TMC_LE_EMAIL:-}"
WEBROOT="${TMC_LE_WEBROOT:-/var/www/html}"
DNS_PLUGIN="${TMC_LE_DNS_PLUGIN:-}"
DNS_CREDENTIALS="${TMC_LE_DNS_CREDENTIALS:-}"
DNS_WAIT="${TMC_LE_DNS_WAIT:-}"
CERT_NAME="${TMC_LE_CERT_NAME:-}"
KEY_TYPE="${TMC_LE_KEY_TYPE:-ecdsa}"
INSTALL_TO="${TMC_LE_INSTALL_TO:-}"
INSTALL_OWNER="${TMC_LE_INSTALL_OWNER:-}"
ACME_SERVER="${TMC_LE_ACME_SERVER:-}"
EAB_KID="${TMC_LE_EAB_KID:-}"
EAB_HMAC="${TMC_LE_EAB_HMAC_KEY:-}"
STAGING="${TMC_LE_STAGING:-}"
WILDCARD=""
FORCE=""
DRY_RUN=""
CERTBOT_DRY_RUN=""
NO_PROBE="${TMC_LE_NO_PROBE:-}"
NO_HOOK=""
INSTALL_CERTBOT=""

domains=()
while [ $# -gt 0 ]; do
    case "$1" in
        --domain|-d)       domains+=("${2:?--domain needs a value}"); shift 2 ;;
        --method|-m)       METHOD="${2:?--method needs a value}"; shift 2 ;;
        --email)           EMAIL="${2:?--email needs a value}"; shift 2 ;;
        --webroot|-w)      WEBROOT="${2:?--webroot needs a value}"; shift 2 ;;
        --dns-plugin)      DNS_PLUGIN="${2:?--dns-plugin needs a value}"; shift 2 ;;
        --dns-credentials) DNS_CREDENTIALS="${2:?--dns-credentials needs a value}"; shift 2 ;;
        --dns-wait)        DNS_WAIT="${2:?--dns-wait needs a value}"; shift 2 ;;
        --cert-name)       CERT_NAME="${2:?--cert-name needs a value}"; shift 2 ;;
        --key-type)        KEY_TYPE="${2:?--key-type needs a value}"; shift 2 ;;
        --install-to)      INSTALL_TO="${2:?--install-to needs a value}"; shift 2 ;;
        --owner)           INSTALL_OWNER="${2:?--owner needs a value}"; shift 2 ;;
        --acme-server)     ACME_SERVER="${2:?--acme-server needs a value}"; shift 2 ;;
        --eab-kid)         EAB_KID="${2:?--eab-kid needs a value}"; shift 2 ;;
        --eab-hmac-key)    EAB_HMAC="${2:?--eab-hmac-key needs a value}"; shift 2 ;;
        --wildcard)        WILDCARD=1; shift ;;
        --staging)         STAGING=1; shift ;;
        --force-renewal)   FORCE=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --certbot-dry-run) CERTBOT_DRY_RUN=1; shift ;;
        --no-probe)        NO_PROBE=1; shift ;;
        --no-hook)         NO_HOOK=1; shift ;;
        --install-certbot) INSTALL_CERTBOT=1; shift ;;
        -h|--help)         sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)                die "unknown argument: $1" 2 ;;
        *)                 domains+=("$1"); shift ;;
    esac
done

# TMC_LE_DOMAIN holds a space-separated list, so one variable can carry a SAN set.
if [ "${#domains[@]}" -eq 0 ] && [ -n "${TMC_LE_DOMAIN:-}" ]; then
    for d in ${TMC_LE_DOMAIN}; do domains+=("$d"); done
fi

# --- What was asked for, checked before anything is done about it -----------

[ "${#domains[@]}" -gt 0 ] || die "give at least one name: --domain demo.example.com" 2

case "$METHOD" in
    webroot|nginx|standalone|dns|manual) ;;
    *) die "unknown --method: $METHOD (webroot, nginx, standalone, dns, manual)" 2 ;;
esac

case "$KEY_TYPE" in
    ecdsa|rsa) ;;
    *) die "--key-type is ecdsa or rsa, not $KEY_TYPE" 2 ;;
esac

for d in "${domains[@]}"; do
    case "$d" in
        ''|*/*|*:*|*' '*) die "--domain is a bare hostname, not a URL: $d" 2 ;;
    esac
done

CERT_NAME="${CERT_NAME:-$(printf '%s' "${domains[0]}" | sed 's/^\*\.//')}"

# A STAGING certificate gets a lineage of its own, and the reason is the run after
# this one. certbot keys everything on the cert name: issue against staging into
# `demo.example.com`, then issue the real one into the same name, and certbot finds
# an existing certificate from a different ACME server and stops -- non-interactively
# it just fails, and the message is about servers rather than about the --staging
# flag that put it there. Two names, no collision, and both can exist at once while
# you are proving a configuration out.
[ -n "$STAGING" ] && CERT_NAME="$CERT_NAME-staging"

# The wildcard, and the rule that is not ours to bend: Let's Encrypt issues one
# only against DNS-01. Asking for `*.example.com` over HTTP-01 is not a
# configuration that half-works -- the order is refused at the ACME server, after
# the account and the challenge have been set up, and the message names a
# challenge type rather than the flag that chose it.
if [ -n "$WILDCARD" ]; then
    base="$(printf '%s' "${domains[0]}" | sed 's/^\*\.//')"
    already=""
    for d in "${domains[@]}"; do [ "$d" = "*.$base" ] && already=1; done
    [ -n "$already" ] || domains+=("*.$base")
fi

has_wildcard=""
for d in "${domains[@]}"; do case "$d" in \*.*) has_wildcard=1 ;; esac; done

if [ -n "$has_wildcard" ] && [ "$METHOD" != "dns" ] && [ "$METHOD" != "manual" ]; then
    die "a wildcard needs DNS-01: --method dns --dns-plugin <provider>, or --method manual.
  Let's Encrypt refuses a wildcard over HTTP-01, so --method $METHOD cannot issue one." 2
fi

if [ "$METHOD" = "dns" ]; then
    [ -n "$DNS_PLUGIN" ] || die "--method dns needs --dns-plugin (cloudflare, route53, digitalocean, google, ...)" 2
    # route53 reads AWS_* from the environment and has no credentials file, which is
    # why this is a warning rather than a requirement.
    if [ -z "$DNS_CREDENTIALS" ] && [ "$DNS_PLUGIN" != "route53" ]; then
        warn "no --dns-credentials; $DNS_PLUGIN will look for its own default and probably not find one"
    fi
    if [ -n "$DNS_CREDENTIALS" ]; then
        [ -f "$DNS_CREDENTIALS" ] || die "no credentials file at $DNS_CREDENTIALS" 2
        # certbot REFUSES a group- or world-readable credentials file, and it says so
        # only after the account has been registered -- so check it here, where the
        # answer costs nothing.
        mode="$(stat -c '%a' "$DNS_CREDENTIALS" 2>/dev/null)"
        case "${mode:-600}" in
            600|400) ;;
            *) warn "$DNS_CREDENTIALS is mode $mode; certbot wants 600 and will refuse it" ;;
        esac
    fi
fi

if [ "$METHOD" = "manual" ]; then
    if [ ! -t 0 ] && [ -z "$DRY_RUN" ]; then
        die "--method manual has to ask you for a TXT record, and stdin is not a terminal" 2
    fi
    warn "manual DNS-01 CANNOT renew unattended. In 90 days this is a person's job again."
fi

if [ -z "$EMAIL" ]; then
    warn "no --email: registering without one. Let's Encrypt then has no way to tell you
       that a renewal has been failing, which is when you would want to hear from it."
fi

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# nginx lives in /usr/sbin, and /usr/sbin IS NOT ON A NORMAL USER'S PATH on Debian.
# `command -v nginx` therefore answers "not installed" on every box where this script
# is run the documented way -- with sudo in front of it, by somebody whose own PATH
# is the one bash exported. That answer is wrong and it is wrong in the direction
# that refuses to work.
find_nginx() {
    local c
    for c in nginx /usr/sbin/nginx /sbin/nginx /usr/local/sbin/nginx; do
        command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
    done
    return 1
}
NGINX="$(find_nginx || true)"

# --- certbot ----------------------------------------------------------------

step "certbot"

HAVE_CERTBOT=1
if ! command -v certbot >/dev/null 2>&1; then
    HAVE_CERTBOT=""
    if [ -n "$DRY_RUN" ]; then
        warn "certbot is not installed; printing the command anyway (--dry-run)"
    elif [ -n "$INSTALL_CERTBOT" ] && command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq \
            && $SUDO apt-get install -y -qq certbot \
            || die "could not install certbot"
        HAVE_CERTBOT=1
        ok "installed certbot"
    else
        die "certbot is not installed.
  Debian/Ubuntu:  sudo apt-get install certbot
  anywhere:       sudo snap install --classic certbot
  or re-run this with --install-certbot" 1
    fi
fi
[ -n "$HAVE_CERTBOT" ] && ok "$(certbot --version 2>&1 | head -1)"

if [ "$METHOD" = "dns" ] && [ -n "$HAVE_CERTBOT" ]; then
    if ! $SUDO certbot plugins 2>/dev/null | grep -q "dns-$DNS_PLUGIN"; then
        die "certbot has no dns-$DNS_PLUGIN plugin.
  apt:   sudo apt-get install python3-certbot-dns-$DNS_PLUGIN
  snap:  sudo snap install certbot-dns-$DNS_PLUGIN
         sudo snap set certbot trust-plugin-with-root=ok
         sudo snap connect certbot:plugin certbot-dns-$DNS_PLUGIN" 1
    fi
    ok "dns-$DNS_PLUGIN is available"
fi

# --- Can the challenge actually be answered? --------------------------------
#
# Every check below happens before certbot is asked to do anything, because a
# FAILED validation is what the rate limit counts. Five of them on one hostname
# and the name is locked out for an hour -- so the cost of finding out from
# Let's Encrypt that the webroot is wrong is an hour, and the cost of finding out
# here is one curl.

case "$METHOD" in
webroot)
    step "the challenge path"

    if [ ! -d "$WEBROOT" ]; then
        [ -n "$DRY_RUN" ] || die "no webroot at $WEBROOT. Pass --webroot with the directory
  the vhost for ${domains[0]} actually serves on port 80." 2
        warn "no webroot at $WEBROOT (--dry-run, so this is not fatal here)"
    fi

    # A dry run prints a command and changes nothing, and that has to include this:
    # the probe creates a directory and a file under someone's web root. A dry run
    # that had already written into /var/www is not a dry run.
    if [ -n "$DRY_RUN" ]; then
        say "not probing $WEBROOT (--dry-run writes nothing)"
    elif [ -n "$NO_PROBE" ]; then
        warn "skipping the probe (--no-probe)"
    elif ! command -v curl >/dev/null 2>&1; then
        warn "no curl, so the challenge path cannot be probed; going in blind"
    else
        probe_dir="$WEBROOT/.well-known/acme-challenge"
        $SUDO mkdir -p "$probe_dir" || die "could not create $probe_dir"

        for d in "${domains[@]}"; do
            token="tmc-probe-$$-$RANDOM"
            printf '%s' "$token" | $SUDO tee "$probe_dir/$token" >/dev/null

            # -L because a vhost that redirects http to https is normal and
            # Let's Encrypt follows the redirect too; -k because the certificate
            # at the other end of that redirect is the thing we are here to fix.
            # The token is random and compared exactly, so neither weakens the test.
            got="$(curl -fsSL -k --max-time 10 \
                "http://$d/.well-known/acme-challenge/$token" 2>/dev/null)"
            $SUDO rm -f "$probe_dir/$token"

            if [ "$got" = "$token" ]; then
                ok "http://$d/.well-known/acme-challenge/ is served from $WEBROOT"
            else
                die "http://$d/.well-known/acme-challenge/ did not return what was put in
  $WEBROOT. Either the vhost for $d serves a different root, or :80 is not
  reachable, or DNS for $d does not point here.

  If this box cannot reach its own public address -- hairpin NAT does this, and
  Let's Encrypt would still succeed from outside -- re-run with --no-probe." 1
            fi
        done
    fi
    ;;

standalone)
    step "port 80"

    # certbot binds :80 itself here, so anything already on it has to go -- and it
    # has to go on every RENEWAL too, not only today. That is what the hooks are:
    # without them the renewal in sixty days fails with "address already in use"
    # on a box where the first run worked perfectly.
    # TWO questions, not one, and conflating them is how this reports a busy port as
    # free: `ss` prints the process column ONLY to root, so an unprivileged run that
    # greps for a name finds nothing on a port nginx is very much holding. So ask
    # first whether anything is listening -- which any user can see -- and only then
    # try to name it.
    listening=""
    holder=""
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END {exit !found}' && listening=1
        holder="$($SUDO ss -ltnpH 2>/dev/null \
            | awk '$4 ~ /:80$/ && match($0, /users:\(\("[^"]+"/) {
                       print substr($0, RSTART + 9, RLENGTH - 10); exit }')"
    elif command -v lsof >/dev/null 2>&1; then
        holder="$($SUDO lsof -nP -iTCP:80 -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | head -1)"
        [ -n "$holder" ] && listening=1
    else
        warn "neither ss nor lsof is here, so :80 cannot be checked; certbot will find out"
    fi

    if [ -z "$listening" ]; then
        ok ":80 is free"
    else
        case "$holder" in
            nginx)
                ok "nginx holds :80; installing stop/start hooks so renewals work too"
                STOP_HOOK="systemctl stop nginx"
                START_HOOK="systemctl start nginx"
                ;;
            '')
                die "something is listening on :80 and this run cannot see what.
  Re-run with sudo, or use --method webroot, which needs nothing stopped." 1
                ;;
            *)
                die "$holder is on :80 and --method standalone needs that port.
  Use --method webroot against whatever $holder is serving instead." 1
                ;;
        esac
    fi
    ;;

nginx)
    [ -n "$NGINX" ] || die "--method nginx needs nginx installed" 1
    ok "$("$NGINX" -v 2>&1)"
    ;;
esac

# --- The invocation ---------------------------------------------------------

args=(certonly --agree-tos --no-eff-email
      --cert-name "$CERT_NAME" --key-type "$KEY_TYPE")

# Every method but one runs unattended. `manual` has to ask a person for a TXT
# record, so it is the one that does not get --non-interactive -- and this is built
# in rather than removed afterwards, because dropping an element from a bash array
# by pattern substitution leaves an EMPTY STRING in it, which certbot receives as an
# argument and rejects.
[ "$METHOD" = "manual" ] || args+=(--non-interactive)

for d in "${domains[@]}"; do args+=(-d "$d"); done

if [ -n "$EMAIL" ]; then
    args+=(--email "$EMAIL")
else
    args+=(--register-unsafely-without-email)
fi

case "$METHOD" in
    webroot)    args+=(--webroot -w "$WEBROOT") ;;
    nginx)      args+=(--nginx) ;;   # certonly: the vhosts this repo writes stay ours
    standalone) args+=(--standalone)
                [ -n "${STOP_HOOK:-}" ]  && args+=(--pre-hook "$STOP_HOOK")
                [ -n "${START_HOOK:-}" ] && args+=(--post-hook "$START_HOOK") ;;
    dns)        args+=("--dns-$DNS_PLUGIN")
                [ -n "$DNS_CREDENTIALS" ] && args+=("--dns-$DNS_PLUGIN-credentials" "$DNS_CREDENTIALS")
                [ -n "$DNS_WAIT" ]        && args+=("--dns-$DNS_PLUGIN-propagation-seconds" "$DNS_WAIT") ;;
    manual)     args+=(--manual --preferred-challenges dns) ;;
esac

[ -n "$STAGING" ]         && args+=(--staging)
[ -n "$FORCE" ]           && args+=(--force-renewal)
[ -n "$CERTBOT_DRY_RUN" ] && args+=(--dry-run)
[ -n "$ACME_SERVER" ]     && args+=(--server "$ACME_SERVER")
[ -n "$EAB_KID" ]         && args+=(--eab-kid "$EAB_KID")
[ -n "$EAB_HMAC" ]        && args+=(--eab-hmac-key "$EAB_HMAC")

if [ -n "$DRY_RUN" ]; then
    printf '\n  %swould run%s\n\n      %scertbot' "$BLD" "$OFF" "${SUDO:+sudo }"
    printf ' %q' "${args[@]}"
    printf '\n\n'
    exit 0
fi

step "requesting a certificate"
[ -n "$STAGING" ] && warn "--staging: this certificate is signed by the STAGING CA and no browser trusts it"

$SUDO certbot "${args[@]}" || die "certbot did not issue a certificate.
  Its own log says why: /var/log/letsencrypt/letsencrypt.log
  A first run on a new name is cheaper with --staging." 1

if [ -n "$CERTBOT_DRY_RUN" ]; then
    ok "validation succeeded and nothing was kept (--certbot-dry-run)"
    exit 0
fi

LIVE="/etc/letsencrypt/live/$CERT_NAME"
FULLCHAIN="$LIVE/fullchain.pem"
PRIVKEY="$LIVE/privkey.pem"

$SUDO test -f "$FULLCHAIN" || die "certbot reported success but there is no $FULLCHAIN" 1
ok "issued $FULLCHAIN"
say "$($SUDO openssl x509 -in "$FULLCHAIN" -noout -enddate | sed 's/^notAfter=/expires /')"

# --- Where the server can read it -------------------------------------------

CRT="$FULLCHAIN"
KEY="$PRIVKEY"

if [ -n "$INSTALL_TO" ]; then
    step "installing a readable copy"

    $SUDO mkdir -p "$INSTALL_TO" || die "could not create $INSTALL_TO"
    CRT="$INSTALL_TO/$CERT_NAME.crt"
    KEY="$INSTALL_TO/$CERT_NAME.key"

    $SUDO install -m 644 "$FULLCHAIN" "$CRT" || die "could not write $CRT"
    $SUDO install -m 640 "$PRIVKEY" "$KEY"   || die "could not write $KEY"
    [ -n "$INSTALL_OWNER" ] && { $SUDO chown "$INSTALL_OWNER" "$KEY" "$CRT" \
        || die "could not chown $KEY to $INSTALL_OWNER"; }

    ok "$CRT"
    ok "$KEY${INSTALL_OWNER:+  (owned by $INSTALL_OWNER)}"
fi

# --- The renewal hook, which is the part that is always missing --------------

if [ -z "$NO_HOOK" ]; then
    step "renewal hook"

    HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
    HOOK="$HOOK_DIR/tmc-$CERT_NAME.sh"
    $SUDO mkdir -p "$HOOK_DIR" || die "could not create $HOOK_DIR"

    hook_tmp="$(mktemp)"
    {
        printf '#!/bin/sh\n'
        printf '#\n# Written by dot-server-deploy/deploy/issue-letsencrypt.sh. Runs after a renewal.\n'
        printf '#\n# Deploy hooks run for EVERY renewed lineage, so this one checks it is ours\n'
        printf '# before touching anything.\n\n'
        printf 'set -u\n'
        printf '[ "${RENEWED_LINEAGE:-}" = "%s" ] || exit 0\n\n' "$LIVE"
        if [ -n "$INSTALL_TO" ]; then
            printf 'install -m 644 "$RENEWED_LINEAGE/fullchain.pem" %q || exit 1\n' "$CRT"
            printf 'install -m 640 "$RENEWED_LINEAGE/privkey.pem" %q || exit 1\n' "$KEY"
            [ -n "$INSTALL_OWNER" ] && printf 'chown %q %q %q || exit 1\n' "$INSTALL_OWNER" "$CRT" "$KEY"
        fi
        printf '\n# nginx opens its certificates once, at startup. A renewal it is not told\n'
        printf '# about changes nothing it is serving.\n'
        printf 'if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then\n'
        printf '    systemctl reload nginx || nginx -s reload || true\n'
        printf 'fi\n'
    } > "$hook_tmp"

    $SUDO install -m 755 "$hook_tmp" "$HOOK" || die "could not write $HOOK"
    rm -f "$hook_tmp"
    ok "$HOOK"

    # A hook nothing ever runs is not a renewal. The packaged certbot ships a timer;
    # the snap ships its own. If neither is here, the certificate expires in 90 days
    # and nothing says so until it has.
    if $SUDO systemctl list-timers --all 2>/dev/null | grep -qi 'certbot\|snap.certbot'; then
        ok "a certbot renewal timer is active"
    elif [ -f /etc/cron.d/certbot ]; then
        ok "/etc/cron.d/certbot renews it"
    else
        warn "nothing is scheduled to renew this. Check: systemctl list-timers | grep certbot"
    fi
fi

# --- What to do with it -----------------------------------------------------

cat <<NEXT

$BLD  Done.$OFF  ${domains[*]}

    Put TLS in front of a dot-server with it:

      sudo ./deploy/install-server-tls.sh --domain $CERT_NAME \\
           --port 6065 --backend 127.0.0.1:6071 \\
           --cert $CRT \\
           --key  $KEY

    Or the game origin:

      sudo ./deploy/install-game-origin.sh --domain $CERT_NAME \\
           --cert $CRT --key $KEY

    Or in $ROOT/deploy/.env:

      TMC_SERVER_SSL_CERT=$CRT
      TMC_SERVER_SSL_KEY=$KEY

NEXT
