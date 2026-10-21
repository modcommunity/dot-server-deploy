#!/usr/bin/env bash
#
# The deployment wizard: everything deploy/ does, asked for in one place.
#
#   ./deploy.sh                    a menu
#   ./deploy.sh new                a public server: config, certificate, TLS, service, firewall
#   ./deploy.sh config             cfg/: name, game, slots, tickrate, password, ports, transport
#   ./deploy.sh cert               a certificate (Let's Encrypt by any method, the dev CA, files)
#   ./deploy.sh proxy              wss:// in front of a server (nginx + a certificate)
#   ./deploy.sh origin             the browser player's https:// origin (nginx + a certificate)
#   ./deploy.sh service            start on boot (systemd)
#   ./deploy.sh firewall           open the ports this server uses
#   ./deploy.sh publish            the web build, or a content tree, to an S3 bucket
#   ./deploy.sh list               what is deployed here
#   ./deploy.sh modify [...]       change or remove a deployed domain: deploy/modify.sh
#
#   --dry-run    ask everything, print the commands, run none of them
#   --yes, -y    take every default; with the flags below, a whole deployment unattended
#   --verbose    show each step's command in the plan
#
# Every question has a flag that answers it (./deploy.sh --help lists them), so
#
#   ./deploy.sh new -y --domain play.example.com --email ops@example.com --method webroot
#
# is the same deployment as the wizard, for a provisioning script.
#
# THIS DOES NOTHING ITSELF. Every step is a script in deploy/ or setup.sh, called with
# the answers as flags, and the plan it prints is those exact commands. A deployment
# made here is one somebody could have typed, and is changed later the same way --
# which is what lets deploy/modify.sh read it back out of nginx rather than out of a
# record of this wizard's own. setup.sh --full is the short form of `new` for a box
# that is being set up from nothing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'
    DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'
else
    RED=""; GRN=""; YLW=""; CYN=""; DIM=""; BLD=""; OFF=""
fi

ASSUME_YES=0
DRY_RUN=0
VERBOSE=0
SUDO=""

. "$ROOT/deploy/lib.sh" || { printf 'deploy/lib.sh is missing; this is not a complete checkout\n' >&2; exit 1; }
. "$ROOT/deploy/wizard-lib.sh" || { printf 'deploy/wizard-lib.sh is missing; this is not a complete checkout\n' >&2; exit 1; }

usage() {
    sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'
Answers, any of which skips its question:

  config     --name NAME  --game ID  --slots N  --tick N  --port N
             --transport dual|websocket|enet  --public-ip HOST
             --set FILE:KEY=VALUE    (any other key; repeatable; VALUE is YAML as written)
  cert       --domain NAME  --cert-source letsencrypt|local-ca|files|self-signed
             --email ADDR  --method webroot|nginx|standalone|dns|manual  --webroot DIR
             --dns-plugin NAME  --dns-credentials FILE  --wildcard  --staging
             --cert FILE --key FILE  (files)   --create-ca  (local-ca)
  proxy      --domain NAME  --public-port N  --backend HOST:PORT
  origin     --domain NAME  --site-origins "https://a https://b"  --root DIR
             --content-root DIR  --cache VALUE
  service    --unit NAME  --user USER
  publish    --bucket B  --region R  --prefix P  --endpoint URL  --public-base URL
             --source DIR  --content  --brotli  --gzip  --env-file FILE
  new        all of the above, and --no-service, --no-firewall

Credentials for publish come from the environment (AWS_ACCESS_KEY_ID and
AWS_SECRET_ACCESS_KEY, or S3_ACCESS_KEY and S3_ACCESS_SECRET), or from --env-file,
which is read when the step runs and never printed. Never from an argument.
EOF
}

# --- Arguments ---------------------------------------------------------------

CMD=""
CMD_ARGS=()
G_NAME=""; G_GAME=""; G_SLOTS=""; G_TICK=""; G_PORT=""; G_TRANSPORT=""; G_PUBLIC_IP=""
G_SETS=()
G_DOMAIN=""; G_CERT_SOURCE=""; G_EMAIL=""; G_METHOD=""; G_WEBROOT=""; G_DNS_PLUGIN=""
G_DNS_CRED=""; G_WILDCARD=0; G_STAGING=0; G_CERT=""; G_KEY=""; G_CREATE_CA=0
G_PUBLIC_PORT=""; G_BACKEND=""
G_SITE_ORIGINS=""; G_ROOT=""; G_CROOT=""; G_CACHE=""
G_UNIT=""; G_USER=""
G_BUCKET=""; G_REGION=""; G_PREFIX=""; G_ENDPOINT=""; G_PUBLIC_BASE=""; G_SOURCE=""
G_CONTENT=0; G_BROTLI=0; G_GZIP=0; G_ENV_FILE=""
NO_SERVICE=0; NO_FIREWALL=0

need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value" 2; }

# `./deploy.sh [flags] modify ...` is deploy/modify.sh, flags and all: its certificate
# flags share names with this script's, and parsing them here would keep them. The
# word after a flag that takes a value is that value, not the command (`--email
# ops@x.com modify`), so the scan steps over it; the flags that take none are listed.
i=0; skip=0
for a in "$@"; do
    i=$((i + 1))
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
        modify)
            rm -f "$WIZARD_DIE_FILE"
            exec "$ROOT/deploy/modify.sh" "${@:1:i-1}" "${@:i+1}" ;;
        --*=*|-y|--yes|--dry-run|-v|--verbose|--wildcard|--staging|--create-ca|--content|--brotli|--gzip|\
        --no-service|--no-firewall|--delete-cert|--keep-cert|--restart|--no-restart|-h|--help) continue ;;
        -*) skip=1; continue ;;
    esac
    break
done

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)         ASSUME_YES=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -v|--verbose)     VERBOSE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        --name)           need "$@"; G_NAME="$2"; shift 2 ;;
        --game)           need "$@"; G_GAME="$2"; shift 2 ;;
        --slots)          need "$@"; G_SLOTS="$2"; shift 2 ;;
        --tick)           need "$@"; G_TICK="$2"; shift 2 ;;
        --port)           need "$@"; G_PORT="$2"; shift 2 ;;
        --transport)      need "$@"; G_TRANSPORT="$2"; shift 2 ;;
        --public-ip)      need "$@"; G_PUBLIC_IP="$2"; shift 2 ;;
        --set)            need "$@"; G_SETS+=("$2"); shift 2 ;;
        --domain)         need "$@"; G_DOMAIN="$2"; shift 2 ;;
        --cert-source)    need "$@"; G_CERT_SOURCE="$2"; shift 2 ;;
        --email)          need "$@"; G_EMAIL="$2"; shift 2 ;;
        --method)         need "$@"; G_METHOD="$2"; shift 2 ;;
        --webroot)        need "$@"; G_WEBROOT="$2"; shift 2 ;;
        --dns-plugin)     need "$@"; G_DNS_PLUGIN="$2"; shift 2 ;;
        --dns-credentials) need "$@"; G_DNS_CRED="$2"; shift 2 ;;
        --wildcard)       G_WILDCARD=1; shift ;;
        --staging)        G_STAGING=1; shift ;;
        --cert)           need "$@"; G_CERT="$2"; G_CERT_SOURCE="${G_CERT_SOURCE:-files}"; shift 2 ;;
        --key)            need "$@"; G_KEY="$2"; shift 2 ;;
        --create-ca)      G_CREATE_CA=1; shift ;;
        --public-port)    need "$@"; G_PUBLIC_PORT="$2"; shift 2 ;;
        --backend)        need "$@"; G_BACKEND="$2"; shift 2 ;;
        --site-origins)   need "$@"; G_SITE_ORIGINS="$2"; shift 2 ;;
        --root)           need "$@"; G_ROOT="$2"; shift 2 ;;
        --content-root)   need "$@"; G_CROOT="$2"; shift 2 ;;
        --cache)          need "$@"; G_CACHE="$2"; shift 2 ;;
        --unit)           need "$@"; G_UNIT="$2"; shift 2 ;;
        --user)           need "$@"; G_USER="$2"; shift 2 ;;
        --bucket)         need "$@"; G_BUCKET="$2"; shift 2 ;;
        --region)         need "$@"; G_REGION="$2"; shift 2 ;;
        --prefix)         need "$@"; G_PREFIX="$2"; shift 2 ;;
        --endpoint)       need "$@"; G_ENDPOINT="$2"; shift 2 ;;
        --public-base)    need "$@"; G_PUBLIC_BASE="$2"; shift 2 ;;
        --source)         need "$@"; G_SOURCE="$2"; shift 2 ;;
        --content)        G_CONTENT=1; shift ;;
        --brotli)         G_BROTLI=1; shift ;;
        --gzip)           G_GZIP=1; shift ;;
        --env-file)       need "$@"; G_ENV_FILE="$2"; shift 2 ;;
        --no-service)     NO_SERVICE=1; shift ;;
        --no-firewall)    NO_FIREWALL=1; shift ;;
        -*)
            # modify takes its own flags; everything after the word is its.
            if [ "$CMD" = modify ]; then CMD_ARGS+=("$1"); shift
            else die "unknown option: $1 (./deploy.sh --help)" 2; fi ;;
        *)
            if [ -z "$CMD" ]; then CMD="$1"; else CMD_ARGS+=("$1"); fi
            shift ;;
    esac
done

# modify is its own script with its own flags; hand it the line as typed.
to_modify() {
    local a=()
    [ "$ASSUME_YES" -eq 1 ] && a+=(--yes); [ "$DRY_RUN" -eq 1 ] && a+=(--dry-run)
    [ "$VERBOSE" -eq 1 ] && a+=(--verbose)
    rm -f "$WIZARD_DIE_FILE"; exec "$ROOT/deploy/modify.sh" "${a[@]}" "${CMD_ARGS[@]}"
}
[ "$CMD" = modify ] && to_modify

detect_root

# --- What cfg/ says --------------------------------------------------------------
#
# A question's default is what cfg/ already says, and, on a checkout setup.sh has not
# configured yet, what cfg.example/ will write. A step earlier in THIS plan may have
# changed a value the next one needs (`new` asks the port before the proxy), so those
# are kept here as well and win over the file.

PLANNED_PORT=""
PLANNED_TRANSPORT=""
CFG_QUEUED=0
SETUP_QUEUED=0

cfgv() {
    local v
    v="$(cfg_get "cfg/$1" "$2" 2>/dev/null)"
    [ -z "$v" ] && [ ! -f "cfg/$1" ] && v="$(cfg_get "cfg.example/$1" "$2" 2>/dev/null)"
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$3"
}
game_port()      { printf '%s' "${PLANNED_PORT:-$(cfgv net.yml net_port 6064)}"; }
game_transport() { printf '%s' "${PLANNED_TRANSPORT:-$(cfgv net.yml net_transport dual)}"; }

# Queues a cfg/ change only when it is one. The YAML is passed as written (a string
# arrives quoted), and the comparison is on what cfg_get reads back, unquoted.
set_cfg() {
    local file="$1" key="$2" yaml="$3" shown="$4" now
    now="$(cfgv "$file" "$key" "")"
    [ "$now" = "$shown" ] && return 0
    if cfg_is_secret "$key"; then
        act "cfg/$file: $key -> $([ -n "$shown" ] && echo '(the one typed)' || echo cleared)" do_cfg_set "cfg/$file" "$key" "$yaml"
        return 0
    fi
    act "cfg/$file: $key ${now:-unset} -> ${shown:-\"\"}" do_cfg_set "cfg/$file" "$key" "$yaml"
}

# No cfg/ means a checkout setup.sh has not been run in, and the config is the least
# of what it is missing: no runtime, no addons, no ./server. setup.sh is the one
# thing that writes cfg/ (with an RCON password of its own), so the plan starts there
# rather than this script growing a second way to.
plan_setup_if_needed() {
    [ "$CFG_QUEUED" -eq 1 ] && return 0
    CFG_QUEUED=1
    if [ ! -f cfg/server.yml ]; then
        warn "this checkout has not been set up yet (no cfg/). The plan starts with ./setup.sh."
        act "set this checkout up: runtime, addons, games, cfg/" "$ROOT/setup.sh" --yes
        SETUP_QUEUED=1
    fi
}

# --- config ----------------------------------------------------------------------

# The games a server here can run: content/<id>/game.yml that is a pack and has a name.
games_offered() {
    local f id name
    for f in content/*/game.yml; do
        [ -f "$f" ] || continue
        grep -qE '^kind:[[:space:]]*pack' "$f" || continue
        id="$(basename "$(dirname "$f")")"
        name="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)"
        name="${name#\"}"; name="${name%\"}"
        printf '%s\t%s\n' "$id" "${name:-$id}"
    done
}

q_config() {
    local name game slots tick pass port transport s file key value opts=()
    section "The server"
    plan_setup_if_needed

    name="$(ask_until is_any "Server name, as the browser lists it" "$G_NAME" "$(cfgv server.yml sv_name 'TMC Server')")"
    set_cfg server.yml sv_name "$(yaml_str "$name")" "$name"

    opts=(default "whatever the server runs when nothing names a game")
    while IFS=$'\t' read -r s value; do opts+=("$s" "$value"); done < <(games_offered)
    game="$(cfgv server.yml sv_game "")"
    game="$(choose_given "Which game does it start with?" "$G_GAME" "${game:-default}" "${opts[@]}")"
    [ "$game" = default ] && game=""
    set_cfg server.yml sv_game "$(yaml_str "$game")" "$game"

    slots="$(ask_until is_number "Player slots" "$G_SLOTS" "$(cfgv server.yml sv_maxplayers 64)")"
    set_cfg server.yml sv_maxplayers "$slots" "$slots"
    tick="$(ask_until is_number "Tick rate (Hz)" "$G_TICK" "$(cfgv server.yml sv_tickrate 60)")"
    set_cfg server.yml sv_tickrate "$tick" "$tick"

    # A password is never a flag (it would be in `ps` and the history); --set can
    # still write one for a script that accepts that.
    if [ "$ASSUME_YES" -eq 0 ]; then
        pass="$(ask_secret "Join password ($( [ -n "$(cfgv server.yml sv_password '')" ] && echo set || echo none) now)")"
        if [ "$pass" = "-" ]; then set_cfg server.yml sv_password '""' ""
        elif [ -n "$pass" ]; then act "cfg/server.yml: sv_password -> (the one typed)" do_cfg_set cfg/server.yml sv_password "$(yaml_str "$pass")"; fi
    fi

    port="$(ask_until is_port "Game port (WebSocket and ENet on TCP and UDP; RCON is one above)" "$G_PORT" "$(cfgv net.yml net_port 6064)")"
    set_cfg net.yml net_port "$port" "$port"
    PLANNED_PORT="$port"
    transport="$(choose_given "Which clients can connect directly?" "$G_TRANSPORT" "$(cfgv net.yml net_transport dual)" \
        dual      "browsers (WebSocket) and desktop clients (ENet) on the one port" \
        websocket "browsers only" \
        enet      "desktop clients only")"
    set_cfg net.yml net_transport "$transport" "$transport"
    PLANNED_TRANSPORT="$transport"

    for s in web desktop mobile; do
        value="$(cfgv server.yml "sv_allow_$s" 1)"
        if [ "$ASSUME_YES" -eq 1 ]; then continue; fi
        if ask_yn "Let $s players in?" "$([ "$value" = 0 ] && echo n || echo y)"; then
            set_cfg server.yml "sv_allow_$s" 1 1
        else
            set_cfg server.yml "sv_allow_$s" 0 0
        fi
    done

    if [ -n "$G_PUBLIC_IP" ]; then
        set_cfg net.yml net_public_ip "$(yaml_str "$G_PUBLIC_IP")" "$G_PUBLIC_IP"
    fi

    for s in "${G_SETS[@]}"; do
        case "$s" in *:*=*) ;; *) die "--set $s: write it FILE:KEY=VALUE, e.g. server.yml:sv_tags=[tmc, eu]" 2 ;; esac
        file="${s%%:*}"; key="${s#*:}"; key="${key%%=*}"; value="${s#*=}"
        file="${file#cfg/}"
        [ -f "cfg/$file" ] || [ -f "cfg.example/$file" ] || die "--set $s: there is no cfg/$file" 2
        s="${value#\"}"; set_cfg "$file" "$key" "$value" "${s%\"}"
    done

    # Anything else, by name: the file, the key, the YAML. cfg/ has a few hundred
    # settings and a wizard that asked all of them would be read by nobody.
    if [ "$ASSUME_YES" -eq 0 ]; then
        while ask_yn "Change any other setting (FILE:KEY, e.g. server.yml:sv_tags)?" n; do
            s="$(ask "Setting" "")"
            case "$s" in *:*) ;; *) warn "write it as FILE:KEY"; continue ;; esac
            file="${s%%:*}"; file="${file#cfg/}"; key="${s#*:}"
            if [ ! -f "cfg/$file" ] && [ ! -f "cfg.example/$file" ]; then warn "there is no cfg/$file"; continue; fi
            value="$(cfg_get "cfg/$file" "$key" 2>/dev/null || cfg_get "cfg.example/$file" "$key" 2>/dev/null)"
            note "now: ${value:-unset}. Strings in double quotes; lists as [a, b]."
            value="$(ask "$key" "")"
            [ -z "$value" ] && continue
            act "cfg/$file: $key -> $value" do_cfg_set "cfg/$file" "$key" "$value"
        done
    fi
}

# --- cert ------------------------------------------------------------------------

ask_domain() {
    local d="${1:-}"
    [ -z "$d" ] && d="$(cfgv net.yml net_public_ip '')"
    is_host "$d" || d="$(hostname -f 2>/dev/null)"
    is_host "$d" || d=""
    ask_until is_host "${2:-Public domain}" "$G_DOMAIN" "$d"
}

# Puts the G_* answers where cert_ask reads them; the names are the same for that.
q_cert() {
    local domain
    section "A certificate"
    domain="$(ask_domain)"
    cert_ask "$domain" 0
    cert_plan
    if [ "$C_SRC" = letsencrypt ]; then
        plan_note "renewal: certbot's timer renews it and the hook reloads nginx"
    fi
}

# --- proxy -------------------------------------------------------------------------

q_proxy() {
    local domain pport backend i
    section "wss:// in front of the server"
    domain="$(ask_domain "" "Domain players connect to")"

    pport="$(ask_until is_port "Public TLS port" "$G_PUBLIC_PORT" "$(default_tls_port)")"
    check_tls_port "$pport"
    backend="$(ask_until is_hostport "The server behind it" "$G_BACKEND" "127.0.0.1:$(game_port)")"

    entries_scan
    for i in "${!E_KIND[@]}"; do
        if [ "${E_KIND[$i]}" = proxy ] && [ "${E_DOMAIN[$i]}" = "$domain" ] && [ "${E_PORT[$i]}" = "$pport" ]; then
            warn "wss://$domain:$pport is already deployed (to ${E_BACKEND[$i]}). This replaces it;
       ./deploy.sh modify changes one piece of it instead."
            ask_yn "Replace it?" y || die "nothing was done." 0
        fi
    done

    cert_ask "$domain" 0
    plan_nginx
    cert_plan
    act_vhost "nginx: wss://$domain:$pport -> $backend" "$(proxy_vhost "$domain" "$pport")" \
        $SUDO "$ROOT/deploy/install-server-tls.sh" --domain "$domain" --port "$pport" --backend "$backend" \
        --cert "$C_CERT" --key "$C_KEY"

    # The server this checkout runs, behind its own proxy, binds loopback (nothing
    # but nginx should reach the WebSocket in the clear) and advertises the domain,
    # because the address it would advertise otherwise is one the browser refuses.
    if backend_is_here "$backend" || { [ -n "$PLANNED_PORT" ] && [ "${backend##*:}" = "$PLANNED_PORT" ]; }; then
        plan_setup_if_needed
        # ENet has its own bind (net_enet_bind_ip, empty follows query_bind_ip "*"),
        # so desktop clients still reach UDP directly with the WebSocket on loopback.
        set_cfg net.yml net_bind_ip '"127.0.0.1"' 127.0.0.1
        set_cfg net.yml net_public_ip "$(yaml_str "$domain")" "$domain"
    else
        plan_note "$backend is not this checkout's server: set its net_public_ip to $domain there"
    fi
    PROXY_PORT="$pport"
}
PROXY_PORT=""

# --- origin ------------------------------------------------------------------------

q_origin() {
    local domain origins root croot cache a=() i
    section "The browser player's origin"
    domain="$(ask_until is_host "Domain the player is served from (not the site's own)" "$G_DOMAIN" "")"
    entries_scan
    for i in "${!E_KIND[@]}"; do
        if [ "${E_KIND[$i]}" = origin ] && [ "${E_DOMAIN[$i]}" = "$domain" ]; then
            origins="${E_ORIGINS[$i]}"; root="${E_ROOT[$i]}"; croot="${E_CROOT[$i]}"; cache="${E_CACHE[$i]}"
            warn "https://$domain is already a game origin. This re-renders it."
        fi
    done
    origins="$(ask_until is_any "The site(s) allowed to frame it, space-separated" "$G_SITE_ORIGINS" "${origins:-}")"
    root="$(given "Directory the web export is published into" "$G_ROOT" "${root:-/srv/tmc-game}")"
    croot="$(given "Directory the content packs are published into" "$G_CROOT" "${croot:-/srv/tmc-content}")"
    cache="$(given "Cache-Control on the player" "$G_CACHE" "${cache:-no-store}")"

    cert_ask "$domain" 1
    plan_nginx
    if [ "$C_SRC" = self-signed ]; then
        a=(--self-signed)
    else
        cert_plan
        a=(--cert "$C_CERT" --key "$C_KEY")
    fi
    act_vhost "nginx: https://$domain/game/ from $root, framed by $origins" "$(origin_vhost "$domain")" \
        $SUDO "$ROOT/deploy/install-game-origin.sh" --domain "$domain" --site-origins "$origins" \
        --root "$root" --content-root "$croot" --cache "$cache" "${a[@]}"
    plan_note "then: copy web/build into $root, and point the site's game origin at https://$domain/game/"
}

# --- service -----------------------------------------------------------------------

q_service() {
    local unit user existing
    section "Start on boot"
    command -v systemctl >/dev/null 2>&1 || { warn "no systemd here; run ./server under whatever supervises this box"; return 0; }
    # The unit runs ./server, which setup.sh generates. Said now, not as the step that
    # fails after the certificate and the vhost are already in.
    if [ ! -x "$ROOT/server" ] && [ "$SETUP_QUEUED" -eq 0 ]; then
        warn "there is no ./server in this checkout yet: run ./setup.sh, then ./deploy.sh service"
        return 0
    fi
    existing="$(unit_for_root)" || existing=""
    if [ -n "$existing" ] && [ -z "$G_UNIT" ]; then
        ok "$existing.service already runs this checkout"
        if [ "${#PLAN_CMD[@]}" -gt 0 ] && ask_yn "Restart it once the rest is done?" y; then
            act "restart $existing" do_restart "$existing"
        fi
        return 0
    fi
    unit="$(ask_until is_unit "Unit name" "$G_UNIT" "${existing:-dot-server}")"
    user="${SUDO_USER:-$(id -un)}"
    user="$(ask_until is_user "Run it as" "$G_USER" "$user")"
    [ "$user" = root ] && warn "a game server running as root runs every delivered game's scripts as root"
    act "systemd: $unit.service runs ./server as $user, at boot" \
        $SUDO "$ROOT/deploy/install-systemd.sh" --name "$unit" --user "$user"
}

# --- firewall ---------------------------------------------------------------------

q_firewall() {
    local fw port transport http=0
    section "Firewall"
    if ! fw="$(firewall_active)"; then
        note "no active firewall (ufw, firewalld): nothing to open here. A cloud provider's is separate."
        return 0
    fi
    port="$(game_port)"; transport="$(game_transport)"
    case "$C_SRC:$C_METHOD" in letsencrypt:webroot|letsencrypt:nginx|letsencrypt:standalone) http=1 ;; esac
    ask_yn "Open this server's ports in $fw?" y || return 0
    [ "$http" -eq 1 ] && act "$fw: 80/tcp (Let's Encrypt validates and renews through it)" do_fw open "$fw" 80 tcp
    if [ -n "$PROXY_PORT" ]; then
        act "$fw: $PROXY_PORT/tcp (wss)" do_fw open "$fw" "$PROXY_PORT" tcp
    else
        act "$fw: $port/tcp (the game)" do_fw open "$fw" "$port" tcp
    fi
    [ "$transport" != websocket ] && act "$fw: $port/udp (desktop clients, server queries)" do_fw open "$fw" "$port" udp
}

# --- publish ------------------------------------------------------------------------

# Runs the publisher with the credentials in the environment. An env file is read
# here, in a subshell, at run time -- never into this script's own variables, never
# printed, never on a command line. The website's names and the games bucket's are
# both accepted, so one .env drives every publisher on a box.
do_publish() {
    (
        if [ -n "${1:-}" ]; then
            # The operator's own file, by design.
            set -a
            # shellcheck disable=SC1090
            . "$1" || exit 1
            set +a
            shift
        else
            shift
        fi
        : "${S3_ACCESS_KEY:=${GAMES_S3_ACCESS_KEY:-}}"
        : "${S3_ACCESS_SECRET:=${GAMES_S3_ACCESS_SECRET:-}}"
        export S3_ACCESS_KEY S3_ACCESS_SECRET
        if [ -z "${AWS_ACCESS_KEY_ID:-}${S3_ACCESS_KEY:-}" ]; then
            printf '    no credentials: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or S3_ACCESS_KEY/S3_ACCESS_SECRET\n' >&2
            exit 1
        fi
        "$ROOT/deploy/publish-web-s3.sh" "$@"
    )
}

# What an env file says about the bucket, without reading a secret out of it: only
# the four non-secret names are looked at.
env_file_value() {
    [ -n "$G_ENV_FILE" ] && [ -f "$G_ENV_FILE" ] || return 1
    sed -n "s/^\(export \)\{0,1\}$1=//p" "$G_ENV_FILE" | head -1 | sed 's/^["'\'']//; s/["'\'']$//'
}

q_publish() {
    local what bucket region prefix endpoint base src a=() creds
    section "Publish to S3"
    what="$(choose_given "What goes up?" "$([ "$G_CONTENT" -eq 1 ] && echo content)" web \
        web     "the browser player (web/build): the game origin" \
        content "a dot-cloud content tree (dist/): game packs")"
    if [ -z "$G_ENV_FILE" ] && [ -z "${AWS_ACCESS_KEY_ID:-}${S3_ACCESS_KEY:-}" ] && [ "$ASSUME_YES" -eq 0 ]; then
        note "no S3 credentials in the environment. An env file is read when the step runs, never printed."
        G_ENV_FILE="$(ask "Env file with the credentials (empty: export them yourself first)" "$([ -f .env ] && echo .env)")"
    fi
    [ -n "$G_ENV_FILE" ] && [ ! -f "$G_ENV_FILE" ] && die "no env file at $G_ENV_FILE" 2

    bucket="$(ask_until is_any "Bucket" "$G_BUCKET" "${TMC_S3_BUCKET:-$(env_file_value GAMES_S3_BUCKET || env_file_value TMC_S3_BUCKET)}")"
    region="$(given "Region" "$G_REGION" "${TMC_S3_REGION:-$(env_file_value GAMES_S3_REGION || env_file_value TMC_S3_REGION)}")"
    region="${region:-us-east-1}"
    if [ "$what" = content ]; then
        prefix="$(given "Prefix in the bucket" "$G_PREFIX" content/)"
        src="$(given "Content tree" "$G_SOURCE" dist)"
        a=(--content)
    else
        prefix="$(given "Prefix in the bucket" "$G_PREFIX" game/)"
        src="$(given "Web export" "$G_SOURCE" web/build)"
        [ -f "$src/index.html" ] || warn "$src has no index.html: export the web build first (./server export-web)"
    fi
    endpoint="$(given "Endpoint (empty for AWS; R2, B2, MinIO need theirs)" "$G_ENDPOINT" "")"
    base="$(given "Public URL it is served from (CDN), for the loader check" "$G_PUBLIC_BASE" "")"
    [ -n "$endpoint" ] && a+=(--endpoint "$endpoint")
    [ -n "$base" ] && a+=(--public-base "$base")
    if [ "$G_BROTLI" -eq 1 ] || { [ "$G_GZIP" -eq 0 ] && ask_yn "Pre-compress with brotli (when no CDN compresses)?" n; }; then a+=(--brotli)
    elif [ "$G_GZIP" -eq 1 ]; then a+=(--gzip); fi

    creds="the environment's credentials"; [ -n "$G_ENV_FILE" ] && creds="credentials from $G_ENV_FILE"
    act "upload $src to s3://$bucket/$prefix ($region), with $creds" \
        do_publish "$G_ENV_FILE" --bucket "$bucket" --region "$region" --prefix "$prefix" --source "$src" "${a[@]}"
}

# --- The commands ---------------------------------------------------------------------

banner() {
    printf '\n  %sdot-server-deploy%s  %s%s%s\n' "$BLD" "$OFF" "$DIM" "$ROOT" "$OFF"
    [ "$DRY_RUN" -eq 1 ] && printf '  %s--dry-run: nothing will be changed%s\n' "$YLW" "$OFF"
    [ "$CAN_ROOT" -eq 0 ] && warn "no root here (sudo needs a password and nobody is at the terminal): nginx, certificates and systemd will fail"
}

menu() {
    local c
    entries_scan
    c="$(choose "What do you want to do?" "$([ "${#E_KIND[@]}" -eq 0 ] && echo new || echo list)" \
        new      "a public server, start to finish" \
        config   "the server's settings (cfg/)" \
        cert     "a certificate on its own" \
        proxy    "wss:// for a server" \
        origin   "https:// for the browser player" \
        service  "start on boot" \
        firewall "open the ports" \
        publish  "upload to S3" \
        list     "what is deployed here" \
        modify   "change a deployed domain, port, backend or certificate" \
        quit     "")"
    printf '%s' "$c"
}

run_cmd() {
    case "$1" in
        new)
            q_config
            q_proxy
            [ "$NO_SERVICE" -eq 1 ] || q_service
            [ "$NO_FIREWALL" -eq 1 ] || q_firewall
            ;;
        config)   q_config
                  local u; u="$(unit_for_root)" && ask_yn "Restart $u once the settings are written?" y \
                      && act "restart $u" do_restart "$u" ;;
        cert)     q_cert ;;
        proxy)    q_proxy; [ "$NO_FIREWALL" -eq 1 ] || q_firewall ;;
        origin)   q_origin ;;
        service)  q_service ;;
        firewall) q_firewall ;;
        publish)  q_publish ;;
        list)     section "Deployed here"; entries_print; printf '\n'; return 0 ;;
        modify)   to_modify ;;
        quit|q)   exit 0 ;;
        *)        die "no such command: $1 (./deploy.sh --help)" 2 ;;
    esac
    run_plan || exit 1
    if [ "$DRY_RUN" -eq 0 ] && [ "$1" != list ]; then
        printf '\n  %sDone.%s ./deploy.sh list shows it; ./deploy.sh modify changes it.\n\n' "$BLD" "$OFF"
    fi
}

banner
if [ -z "$CMD" ]; then
    [ "$ASSUME_YES" -eq 1 ] && die "--yes needs a command: ./deploy.sh new -y ..." 2
    CMD="$(menu)"
fi
run_cmd "$CMD"
