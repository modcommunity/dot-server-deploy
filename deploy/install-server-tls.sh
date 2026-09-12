#!/usr/bin/env bash
#
# Put TLS in front of one dot-server.
#
#   ./deploy/install-server-tls.sh --domain example.net --port 6065 --backend 127.0.0.1:6071
#
# One invocation per server: each needs its own reachable host:port, because the
# boot descriptor carries a host and a port and nothing else. See the template.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; BLD=$'\e[1m'; OFF=$'\e[0m'
die() { printf '\n  %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

DOMAIN="${TMC_SERVER_DOMAIN:-demo.example.com}"
PUBLIC_PORT="${TMC_SERVER_PUBLIC_PORT:-}"
BACKEND="${TMC_SERVER_BACKEND:-}"
SSL_CERT="${TMC_SERVER_SSL_CERT:-/opt/tmc.crt}"
SSL_KEY="${TMC_SERVER_SSL_KEY:-/opt/tmc.key}"
SITES_DIR="${TMC_NGINX_SITES_DIR:-/etc/nginx/sites-available}"
# Where a directive that must live in nginx's `http` context goes. On Debian and
# Ubuntu the stock nginx.conf includes conf.d/*.conf from inside `http {}`.
CONF_DIR="${TMC_NGINX_CONF_DIR:-/etc/nginx/conf.d}"
ENABLED_DIR="${TMC_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)  DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
        --port)    PUBLIC_PORT="${2:?--port needs a value}"; shift 2 ;;
        --backend) BACKEND="${2:?--backend needs a value}"; shift 2 ;;
        --cert)    SSL_CERT="${2:?--cert needs a value}"; shift 2 ;;
        --key)     SSL_KEY="${2:?--key needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *)         die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$PUBLIC_PORT" ] || die "--port is the public TLS port, e.g. 6065" 2
[ -n "$BACKEND" ]     || die "--backend is where the server actually listens, e.g. 127.0.0.1:6071" 2
[ -f "$SSL_CERT" ]    || die "no certificate at $SSL_CERT"

LOG_NAME="$(printf '%s' "${DOMAIN}-${PUBLIC_PORT}" | tr -c 'A-Za-z0-9._-' '-')"
NAME="server-tls-$LOG_NAME"

# --- The map the server block depends on ------------------------------------
#
# [b]This script emitted `$connection_upgrade` and never defined it.[/b] That
# variable comes from a `map`, a `map` may only appear in nginx's `http` context,
# and this script writes a `server` block -- so it could not define it from where it
# was writing, and did not define it anywhere else either. Nothing in this
# repository did.
#
# So the documented way to put TLS in front of a dot-server worked only on a box
# that already had the map from some unrelated vhost, and failed everywhere else
# with `unknown "connection_upgrade" variable` -- which reads as a broken template
# rather than as a missing prerequisite. Found by running it on a server that had
# nginx and nothing else.
#
# Guarded by `nginx -T`, which dumps the FULLY RESOLVED configuration: a second
# `map` for the same variable is a duplicate-directive error, and a box that already
# has one -- the demo host does -- must not be broken by installing this.
# `--dry-run` must change nothing, including this. It prints the server block it
# would install and exits below; a dry run that had already written a file into
# /etc/nginx is not a dry run.
if [ -z "$DRY_RUN" ] \
        && ! sudo nginx -T 2>/dev/null \
            | grep -qE 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade'; then
    map_file="$(mktemp)"
    cat > "$map_file" <<'MAP'
# Written by dot-server-deploy's install-server-tls.sh.
#
# `Connection: upgrade` for a WebSocket handshake, `Connection: close` for anything
# else. Hardcoding "upgrade" instead would send that header on ordinary requests to
# this port too, which some proxies and health checks answer badly.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
MAP
    sudo install -m 644 "$map_file" "$CONF_DIR/dot-websocket-upgrade.conf" \
        || die "could not write $CONF_DIR/dot-websocket-upgrade.conf"
    rm -f "$map_file"
    ok "installed the websocket upgrade map in $CONF_DIR"
fi

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

sed -e "s|@DOMAIN@|$DOMAIN|g" \
    -e "s|@PUBLIC_PORT@|$PUBLIC_PORT|g" \
    -e "s|@BACKEND@|$BACKEND|g" \
    -e "s|@SSL_CERT@|$SSL_CERT|g" \
    -e "s|@SSL_KEY@|$SSL_KEY|g" \
    -e "s|@LOG_NAME@|$LOG_NAME|g" \
    "$ROOT/deploy/server-tls.nginx.template" > "$rendered"

if grep -q '@[A-Z_]*@' "$rendered"; then
    die "template still has placeholders: $(grep -o '@[A-Z_]*@' "$rendered" | sort -u | tr '\n' ' ')"
fi

if [ -n "$DRY_RUN" ]; then cat "$rendered"; exit 0; fi

sudo install -m 644 "$rendered" "$SITES_DIR/$NAME.conf" || die "could not write $SITES_DIR/$NAME.conf"
sudo ln -sf "$SITES_DIR/$NAME.conf" "$ENABLED_DIR/$NAME.conf"
sudo nginx -t >/dev/null 2>&1 || { sudo nginx -t; die "nginx rejected the configuration"; }
sudo systemctl reload nginx || die "could not reload nginx"

ok "wss://$DOMAIN:$PUBLIC_PORT  ->  $BACKEND"
