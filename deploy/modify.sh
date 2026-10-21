#!/usr/bin/env bash
#
# Change something already deployed: a domain, a port, a backend, a certificate, a
# game origin's settings; or take it out.
#
#   ./deploy/modify.sh                             pick one and say what to change
#   ./deploy/modify.sh list                        what is deployed here
#   ./deploy/modify.sh show    ENTRY               one of them, and its vhost
#   ./deploy/modify.sh domain  ENTRY NEW-DOMAIN    move it to another name
#   ./deploy/modify.sh port    ENTRY N             wss:// on another public port
#   ./deploy/modify.sh backend ENTRY HOST:PORT     point the proxy at another server
#   ./deploy/modify.sh cert    ENTRY               renew now, or change where it comes from
#   ./deploy/modify.sh origins ENTRY "https://a https://b"   who may frame a game origin
#   ./deploy/modify.sh root | content-root | cache  ENTRY VALUE
#   ./deploy/modify.sh remove  ENTRY               take it out of nginx
#
# ENTRY is a domain, domain:port when one domain has more than one, the vhost file's
# name, or the number ./deploy/modify.sh list prints. ./deploy.sh modify is the same.
#
#   --dry-run  --yes  --verbose      as ./deploy.sh
#   --delete-cert / --keep-cert      after a domain change or a removal, whether the old
#                                    Let's Encrypt certificate goes too (default: ask)
#   --restart / --no-restart         restart this checkout's service after a cfg/ change
#   --no-firewall                    leave the firewall alone after a port change
#   and the certificate flags of ./deploy.sh (--cert-source, --method, --email, ...)
#
# NOTHING HERE EDITS A VHOST. A change is the installer run again with every value the
# entry has now and the one that changed: the vhost is the template's, rendered, and a
# hand-edited copy is what drifts from the template until neither the next release's
# fixes nor this script can be applied to it. What the entry has now is read back out
# of the vhost itself (deploy/wizard-lib.sh), so there is no record here to go stale.
#
# A move is ADD THEN REMOVE: the new vhost is installed and tested before the old one
# is touched, so a change that nginx refuses leaves the deployment as it was rather
# than half-moved. And a name that clients are still using is not deleted quietly: the
# site's game origin, net_public_ip and an old certificate are each said or asked.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

POS=()
DELETE_CERT=""; RESTART=""; NO_FIREWALL=0
G_CERT_SOURCE=""; G_EMAIL=""; G_METHOD=""; G_WEBROOT=""; G_DNS_PLUGIN=""; G_DNS_CRED=""
G_WILDCARD=0; G_STAGING=0; G_CERT=""; G_KEY=""; G_CREATE_CA=0

need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value" 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)          ASSUME_YES=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -v|--verbose)      VERBOSE=1; shift ;;
        -h|--help)         sed -n '3,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --delete-cert)     DELETE_CERT=1; shift ;;
        --keep-cert)       DELETE_CERT=0; shift ;;
        --restart)         RESTART=1; shift ;;
        --no-restart)      RESTART=0; shift ;;
        --no-firewall)     NO_FIREWALL=1; shift ;;
        --cert-source)     need "$@"; G_CERT_SOURCE="$2"; shift 2 ;;
        --email)           need "$@"; G_EMAIL="$2"; shift 2 ;;
        --method)          need "$@"; G_METHOD="$2"; shift 2 ;;
        --webroot)         need "$@"; G_WEBROOT="$2"; shift 2 ;;
        --dns-plugin)      need "$@"; G_DNS_PLUGIN="$2"; shift 2 ;;
        --dns-credentials) need "$@"; G_DNS_CRED="$2"; shift 2 ;;
        --wildcard)        G_WILDCARD=1; shift ;;
        --staging)         G_STAGING=1; shift ;;
        --cert)            need "$@"; G_CERT="$2"; G_CERT_SOURCE="${G_CERT_SOURCE:-files}"; shift 2 ;;
        --key)             need "$@"; G_KEY="$2"; shift 2 ;;
        --create-ca)       G_CREATE_CA=1; shift ;;
        --)                shift; POS+=("$@"); break ;;
        -*)                die "unknown option: $1 (./deploy/modify.sh --help)" 2 ;;
        *)                 POS+=("$1"); shift ;;
    esac
done

detect_root

# --- The entry being changed ------------------------------------------------------
#
# I is its index in the E_* arrays; the N_* values are what it will be. Every action
# changes some N_* and then render_entry installs the lot.

I=""
N_DOMAIN=""; N_PORT=""; N_BACKEND=""; N_CERT=""; N_KEY=""
N_ORIGINS=""; N_ROOT=""; N_CROOT=""; N_CACHE=""; N_SELF_SIGNED=0

pick_entry() {
    local q="${1:-}" n
    entries_scan
    [ "${#E_KIND[@]}" -gt 0 ] || die "nothing deployed here to change (no vhost from deploy/ in $SITES_DIR).
    ./deploy.sh proxy or ./deploy.sh origin puts one there." 0
    if [ -z "$q" ]; then
        [ "$ASSUME_YES" -eq 1 ] && die "--yes needs the entry: ./deploy/modify.sh ACTION ENTRY" 2
        if [ "${#E_KIND[@]}" -eq 1 ]; then
            q=1
        else
            section "Deployed here"
            entries_print
            printf '\n' >&2
            n="$(ask_until is_number "Which one (number)?" "" "1")"
            q="$n"
        fi
    fi
    I="$(find_entry "$q")" || exit $?
    N_DOMAIN="${E_DOMAIN[$I]}"; N_PORT="${E_PORT[$I]}"; N_BACKEND="${E_BACKEND[$I]}"
    N_CERT="${E_CERT[$I]}"; N_KEY="${E_KEY[$I]}"
    N_ORIGINS="${E_ORIGINS[$I]}"; N_ROOT="${E_ROOT[$I]}"; N_CROOT="${E_CROOT[$I]}"; N_CACHE="${E_CACHE[$I]}"
    N_SELF_SIGNED=0
}

kind_is() {
    [ "${E_KIND[$I]}" = "$1" ] || die "${E_DOMAIN[$I]} is a $(kind_word "${E_KIND[$I]}"); $2 is for a $(kind_word "$1")" 2
}
kind_word() { [ "$1" = proxy ] && printf 'wss:// proxy' || printf 'game origin'; }

entry_name() {
    if [ "${E_KIND[$I]}" = proxy ]; then printf 'wss://%s:%s' "${E_DOMAIN[$I]}" "${E_PORT[$I]}"
    else printf 'https://%s/game/' "${E_DOMAIN[$I]}"; fi
}

new_vhost() {
    if [ "${E_KIND[$I]}" = proxy ]; then proxy_vhost "$N_DOMAIN" "$N_PORT"; else origin_vhost "$N_DOMAIN"; fi
}

# The installer again, with N_*. Then, when that wrote a DIFFERENT file (the name or
# port changed), the old one comes out -- only after the new one passed nginx -t.
render_entry() {
    local what="$1" f a=()
    f="$(new_vhost)"
    if [ "${E_KIND[$I]}" = proxy ]; then
        act_vhost "nginx: wss://$N_DOMAIN:$N_PORT -> $N_BACKEND ($what)" "$f" \
            $SUDO "$ROOT/deploy/install-server-tls.sh" --domain "$N_DOMAIN" --port "$N_PORT" \
            --backend "$N_BACKEND" --cert "$N_CERT" --key "$N_KEY"
    else
        if [ "$N_SELF_SIGNED" -eq 1 ]; then a=(--self-signed); else a=(--cert "$N_CERT" --key "$N_KEY"); fi
        act_vhost "nginx: https://$N_DOMAIN/game/ ($what)" "$f" \
            $SUDO "$ROOT/deploy/install-game-origin.sh" --domain "$N_DOMAIN" --site-origins "$N_ORIGINS" \
            --root "$N_ROOT" --content-root "$N_CROOT" --cache "$N_CACHE" "${a[@]}"
    fi
    if [ "$f" != "${E_FILE[$I]}" ]; then
        act "take the old $(entry_name) out of nginx" do_vhost_remove "${E_FILE[$I]}"
    fi
}

# Is a certificate named by any vhost other than this one? Then it stays, whatever
# was asked: deleting a lineage another server still serves is an outage at its next
# reload.
# Every nginx file counts, not only the vhosts deploy/ wrote: a proxy that reused the
# lineage the site's own vhost was already serving (issue-letsencrypt.sh keeps a valid
# one) must not take that site's certificate with it.
cert_in_use_elsewhere() {
    local j dir f mine
    for j in "${!E_KIND[@]}"; do
        [ "$j" = "$I" ] && continue
        [ "${E_CERT[$j]}" = "$1" ] && return 0
    done
    mine="$(readlink -f "${E_FILE[$I]}")"
    dir="$(dirname "$SITES_DIR")"
    # By the lineage directory, so a vhost naming privkey.pem or chain.pem counts too.
    while IFS= read -r f; do
        [ "$(readlink -f "$f")" = "$mine" ] && continue
        return 0
    done < <($SUDO grep -rlF -- "$(dirname "$1")/" "$dir" 2>/dev/null)
    return 1
}

# Offers to delete the entry's OLD Let's Encrypt certificate once nothing names it.
# Only a Let's Encrypt lineage: a development CA certificate is a file that costs
# nothing, and somebody's own files are never this script's to delete.
plan_old_cert_cleanup() {
    local old="${E_CERT[$I]}" name
    [ "$old" = "$N_CERT" ] && return 0
    name="$(le_lineage "$old")" || return 0
    if cert_in_use_elsewhere "$old"; then
        plan_note "the old certificate $name stays: another vhost here still uses it"
        return 0
    fi
    case "$DELETE_CERT" in
        1) act "delete the old certificate $name (nothing uses it now)" do_le_delete "$name" ;;
        0) plan_note "the old certificate $name stays (renewing, unused): certbot delete --cert-name $name" ;;
        *) if ask_yn "Delete the old certificate $name once nothing uses it? (it keeps renewing otherwise)" y; then
               act "delete the old certificate $name (nothing uses it now)" do_le_delete "$name"
           else
               plan_note "the old certificate $name stays: certbot delete --cert-name $name removes it"
           fi ;;
    esac
}

# A cfg/ change here wants the server to pick it up, which is a restart: dot-server
# reads net_* once, at boot.
plan_restart() {
    local u
    u="$(unit_for_root)" || { plan_note "restart ./server for the cfg/ change to apply"; return 0; }
    case "$RESTART" in
        1) act "restart $u" do_restart "$u" ;;
        0) plan_note "restart $u for the cfg/ change to apply" ;;
        *) if ask_yn "Restart $u so it picks up the change? (players on it are dropped)" y; then
               act "restart $u" do_restart "$u"
           else
               plan_note "restart $u for the cfg/ change to apply"
           fi ;;
    esac
}

set_cfg_here() {
    local file="$1" key="$2" yaml="$3" shown="$4" now
    [ -f "cfg/$file" ] || return 1
    now="$(cfg_get "cfg/$file" "$key" 2>/dev/null)"
    [ "$now" = "$shown" ] && return 1
    act "cfg/$file: $key ${now:-unset} -> $shown" do_cfg_set "cfg/$file" "$key" "$yaml"
}

# Is this port served by any vhost but the one being changed? Then it stays open.
port_in_use_elsewhere() {
    local j
    for j in "${!E_KIND[@]}"; do
        [ "$j" = "$I" ] && continue
        [ "${E_PORT[$j]}" = "$1" ] && return 0
    done
    return 1
}

# --- Actions -------------------------------------------------------------------------

a_show() {
    local f="${E_FILE[$I]}"
    section "$(entry_name)"
    printf '    vhost        %s%s\n' "$f" "$([ "${E_ENABLED[$I]}" -eq 0 ] && printf '  %s(not enabled)%s' "$YLW" "$OFF")"
    if [ "${E_KIND[$I]}" = proxy ]; then
        printf '    backend      %s%s\n' "${E_BACKEND[$I]}" "$(backend_is_here "${E_BACKEND[$I]}" && echo '  (this checkout)')"
    else
        printf '    framed by    %s\n    player       %s\n    content      %s\n    cache        %s\n' \
            "${E_ORIGINS[$I]}" "${E_ROOT[$I]}" "${E_CROOT[$I]}" "${E_CACHE[$I]}"
    fi
    printf '    certificate  %s\n                 %s\n' "${E_CERT[$I]}" "$(cert_describe "${E_CERT[$I]}")"
    if [ "$VERBOSE" -eq 1 ]; then printf '\n'; $SUDO cat "$f"; fi
    printf '\n'
}

a_domain() {
    local new="${1:-}" old="${E_DOMAIN[$I]}" j
    section "Move $(entry_name) to another domain"
    new="$(ask_until is_host "New domain" "$new" "")"
    [ "$new" = "$old" ] && die "$old is already its domain" 2
    entries_scan
    for j in "${!E_KIND[@]}"; do
        if [ "${E_KIND[$j]}" = "${E_KIND[$I]}" ] && [ "${E_DOMAIN[$j]}" = "$new" ] && [ "${E_PORT[$j]}" = "${E_PORT[$I]}" ]; then
            die "$new:${E_PORT[$j]} is already deployed here (${E_FILE[$j]}). Remove it first." 2
        fi
    done
    N_DOMAIN="$new"

    # The new name needs a certificate that names it. The old one's source is the
    # default, so a Let's Encrypt webroot deployment stays one without being asked
    # six questions it answered last time.
    cert_preset_from "${E_CERT[$I]}" "${E_KEY[$I]}"
    note "the certificate for $old is $(cert_describe "${E_CERT[$I]}")"
    if [ "$C_SRC" = files ] && [ -z "$G_CERT_SOURCE" ]; then
        if $SUDO openssl x509 -in "${E_CERT[$I]}" -noout -checkhost "$new" 2>/dev/null | grep -q 'does match'; then
            note "and it already names $new"
            G_CERT="${G_CERT:-${E_CERT[$I]}}"; G_KEY="${G_KEY:-${E_KEY[$I]}}"
        fi
    fi
    cert_ask "$new" "$([ "${E_KIND[$I]}" = origin ] && echo 1 || echo 0)"
    if [ "$C_SRC" = self-signed ]; then N_SELF_SIGNED=1
    else cert_plan; N_CERT="$C_CERT"; N_KEY="$C_KEY"; fi

    render_entry "moved from $old"
    plan_old_cert_cleanup

    if [ "${E_KIND[$I]}" = proxy ]; then
        if backend_is_here "${E_BACKEND[$I]}" && [ "$(cfg_get cfg/net.yml net_public_ip 2>/dev/null)" = "$old" ]; then
            set_cfg_here net.yml net_public_ip "$(yaml_str "$new")" "$new" && plan_restart
        elif [ "$(cfg_get cfg/net.yml net_public_ip 2>/dev/null)" != "$new" ]; then
            plan_note "the server behind it advertises its own address: set its net_public_ip to $new"
        fi
        plan_note "players with wss://$old:${E_PORT[$I]} saved (favourites, links) need the new name; DNS for $new must point here"
    else
        plan_note "then: the site's game origin setting becomes https://$new/game/ -- until it does, the site frames $old"
    fi
}

a_port() {
    local new="${1:-}" old="${E_PORT[$I]}" fw
    kind_is proxy port
    section "Move $(entry_name) to another port"
    new="$(ask_until is_port "New public port" "$new" "$([ "$old" = 443 ] && echo 6065 || echo 443)")"
    [ "$new" = "$old" ] && die "it is already on $old" 2
    check_tls_port "$new"
    [ -e "$(proxy_vhost "$N_DOMAIN" "$new")" ] && die "${N_DOMAIN}:$new is already deployed here. Remove it first." 2
    N_PORT="$new"
    render_entry "moved from :$old"
    if [ "$NO_FIREWALL" -eq 0 ] && fw="$(firewall_active)"; then
        act "$fw: $new/tcp" do_fw open "$fw" "$new" tcp
        if port_in_use_elsewhere "$old" || [ "$old" = 443 ]; then
            plan_note "$old/tcp stays open in $fw: something else here still serves it"
        else
            act "$fw: close $old/tcp (nothing serves it now)" do_fw close "$fw" "$old" tcp
        fi
    fi
    plan_note "the server's own address is unchanged; a client finds the port through the site's listing, which updates at its next report"
}

a_backend() {
    local new="${1:-}" old="${E_BACKEND[$I]}" here_before=0
    kind_is proxy backend
    section "Point $(entry_name) at another server"
    new="$(ask_until is_hostport "New backend" "$new" "$old")"
    [ "$new" = "$old" ] && die "it already points at $old" 2
    backend_is_here "$old" && here_before=1
    N_BACKEND="$new"
    render_entry "backend was $old"

    # Moving this checkout's own server to another port is one change in two places:
    # the vhost and cfg/net.yml. Offer the second, because doing only the first is a
    # 502 that looks like the server is down.
    if [ "$here_before" -eq 1 ] && [ "${new%:*}" = "${old%:*}" ] && [ -f cfg/net.yml ]; then
        if ask_yn "Move this checkout's server to :${new##*:} too (cfg/net.yml net_port)?" y; then
            set_cfg_here net.yml net_port "${new##*:}" "${new##*:}" && plan_restart
        fi
    fi
}

a_cert() {
    local how cur
    section "The certificate for $(entry_name)"
    note "now: $(cert_describe "${E_CERT[$I]}")"
    cert_preset_from "${E_CERT[$I]}" "${E_KEY[$I]}"
    cur="$C_SRC"
    how="$(choose_given "What should happen to it?" "${POS[2]:-}" renew \
        renew  "a fresh one from the same place, now (Let's Encrypt: force a renewal)" \
        change "from somewhere else: another method, Let's Encrypt, the dev CA, your own files")"
    if [ "$how" = renew ] && [ -z "$G_CERT_SOURCE" ]; then
        case "$cur" in
            letsencrypt) C_RENEW=1; G_CERT_SOURCE=letsencrypt ;;
            local-ca)    G_CERT_SOURCE=local-ca ;;
            files)       note "your own files: renewing them is whoever issued them. Give the new paths."; G_CERT_SOURCE=files ;;
        esac
    fi
    cert_ask "${E_DOMAIN[$I]}" "$([ "${E_KIND[$I]}" = origin ] && echo 1 || echo 0)"
    if [ "$C_SRC" = self-signed ]; then N_SELF_SIGNED=1
    else cert_plan; N_CERT="$C_CERT"; N_KEY="$C_KEY"; fi
    render_entry "certificate"
    plan_old_cert_cleanup
}

a_origin_field() {
    local field="$1" v="${2:-}"
    kind_is origin "$field"
    section "$(entry_name): $field"
    case "$field" in
        origins)
            v="$(ask_until is_any "Sites allowed to frame it, space-separated" "$v" "$N_ORIGINS")"
            [ "$v" = "$N_ORIGINS" ] && die "it already says that" 0
            N_ORIGINS="$v" ;;
        root)
            v="$(ask_until is_any "Directory the web export is in" "$v" "$N_ROOT")"
            N_ROOT="${v%/}"
            $SUDO test -f "$N_ROOT/index.html" || warn "$N_ROOT has no index.html yet: the player 404s until web/build is copied there" ;;
        content-root)
            v="$(ask_until is_any "Directory the content packs are in" "$v" "$N_CROOT")"
            N_CROOT="${v%/}" ;;
        cache)
            v="$(ask_until is_any "Cache-Control on the player (no-store, or e.g. public, max-age=300)" "$v" "$N_CACHE")"
            N_CACHE="$v" ;;
    esac
    # The certificate is not part of the question and stays exactly what it is. A
    # self-signed one is passed as files: --self-signed would mint a fresh one.
    render_entry "$field"
}

a_remove() {
    local fw name
    section "Take $(entry_name) out"
    act "take $(entry_name) out of nginx" do_vhost_remove "${E_FILE[$I]}"
    N_CERT=""
    plan_old_cert_cleanup
    if [ "${E_KIND[$I]}" = proxy ] && [ "$NO_FIREWALL" -eq 0 ] && fw="$(firewall_active)" \
            && ! port_in_use_elsewhere "${E_PORT[$I]}" && [ "${E_PORT[$I]}" != 443 ]; then
        if ask_yn "Close ${E_PORT[$I]}/tcp in $fw (nothing would serve it)?" y; then
            act "$fw: close ${E_PORT[$I]}/tcp" do_fw close "$fw" "${E_PORT[$I]}" tcp
        fi
    fi
    if [ "${E_KIND[$I]}" = proxy ] && backend_is_here "${E_BACKEND[$I]}" \
            && [ "$(cfg_get cfg/net.yml net_public_ip 2>/dev/null)" = "${E_DOMAIN[$I]}" ]; then
        plan_note "this checkout still advertises ${E_DOMAIN[$I]} (net_public_ip) and binds $(cfg_get cfg/net.yml net_bind_ip 2>/dev/null); browsers cannot reach it without the proxy"
    fi
}

# --- What to do ------------------------------------------------------------------------

ACTION="${POS[0]:-}"
case "$ACTION" in
    ''|list|show|domain|port|backend|cert|origins|root|content-root|cache|remove) ;;
    *) die "no such change: $ACTION (./deploy/modify.sh --help)" 2 ;;
esac

if [ "$ACTION" = list ]; then
    section "Deployed here"; entries_print; printf '\n'; exit 0
fi

pick_entry "${POS[1]:-}"

if [ -z "$ACTION" ]; then
    printf '\n' >&2
    if [ "${E_KIND[$I]}" = proxy ]; then
        ACTION="$(choose "Change what about $(entry_name)?" show \
            show    "what it is now" \
            domain  "the domain (a new certificate for it)" \
            port    "the public port" \
            backend "the server behind it" \
            cert    "the certificate: renew it, or change where it comes from" \
            remove  "take it out")"
    else
        ACTION="$(choose "Change what about $(entry_name)?" show \
            show         "what it is now" \
            domain       "the domain (a new certificate for it)" \
            origins      "the sites allowed to frame it" \
            root         "the directory the player is served from" \
            content-root "the directory the content packs are served from" \
            cache        "the player's Cache-Control" \
            cert         "the certificate: renew it, or change where it comes from" \
            remove       "take it out")"
    fi
fi

case "$ACTION" in
    show)    a_show; exit 0 ;;
    domain)  a_domain "${POS[2]:-}" ;;
    port)    a_port "${POS[2]:-}" ;;
    backend) a_backend "${POS[2]:-}" ;;
    cert)    a_cert ;;
    origins|root|content-root|cache) a_origin_field "$ACTION" "${POS[2]:-}" ;;
    remove)  a_remove ;;
esac

[ "$DRY_RUN" -eq 1 ] && printf '\n  %s--dry-run: nothing will be changed%s\n' "$YLW" "$OFF" >&2
run_plan || exit 1
if [ "$DRY_RUN" -eq 0 ]; then
    printf '\n' >&2
    section "Deployed here now"
    entries_print
    printf '\n'
fi
