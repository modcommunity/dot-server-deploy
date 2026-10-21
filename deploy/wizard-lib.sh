# shellcheck shell=bash
# The engine deploy.sh and deploy/modify.sh share: questions, the plan, certificates,
# and reading back what is already deployed. Sourced after deploy/lib.sh, never run.
#
# Two rules hold everything here together, and both are setup.sh --full's:
#
#   NOTHING IS DONE UNTIL EVERY QUESTION IS ANSWERED. A step is queued with `act`, the
#   queue is printed as the plan, one confirmation covers the lot, and only then does
#   anything run. An installer that acts on answer three while asking answer four
#   cannot be stopped at answer five.
#
#   THE PLAN IS THE COMMANDS. Every queued step is the exact command line that will
#   run, quoted with printf %q, so --dry-run prints a script somebody can paste, and a
#   step that fails leaves the rest of the plan printed for running by hand rather
#   than a wizard that has to be started again from question one.
#
# What is deployed is read back from what was INSTALLED -- the vhosts the deploy/
# scripts render, certbot's renewal files, the units install-systemd.sh writes --
# never from a record of our own. A record is a second copy of the truth, and the
# first time somebody edits a vhost by hand the two disagree and the wizard believes
# the wrong one.

SITES_DIR="${TMC_NGINX_SITES_DIR:-/etc/nginx/sites-available}"
ENABLED_DIR="${TMC_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
SYSTEMD_DIR="${TMC_SYSTEMD_DIR:-/etc/systemd/system}"
LE_DIR="${TMC_LETSENCRYPT_DIR:-/etc/letsencrypt}"
LOCAL_CA_CERT="${TMC_LOCAL_CA_CERT:-/opt/tmc-local-ca.crt}"
LOCAL_CERT_DIR="${TMC_CERT_DIR:-/opt}"

# --- Output ------------------------------------------------------------------

step() { printf '\n%s==>%s %s\n' "$BLD" "$OFF" "$1"; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$OFF" >&2; }
# Most questions run in $(...), where exit leaves only the subshell and the caller
# goes on with an empty answer (a refused --domain became --domain ''). So die from
# a subshell also signals the script itself, which exits with the same code; the
# code crosses in a file because a signal carries none.
WIZARD_PID=$$
WIZARD_DIE_FILE="$(mktemp "${TMPDIR:-/tmp}/dot-deploy-die.XXXXXX")"
trap 'c="$(cat "$WIZARD_DIE_FILE" 2>/dev/null)"; rm -f "$WIZARD_DIE_FILE"; exit "${c:-1}"' USR1
trap 'rm -f "$WIZARD_DIE_FILE"' EXIT
die()  {
    printf '\n    %s%s%s\n\n' "$RED" "$1" "$OFF" >&2
    if [ "$BASH_SUBSHELL" -gt 0 ]; then
        printf '%s' "${2:-1}" > "$WIZARD_DIE_FILE"
        kill -USR1 "$WIZARD_PID" 2>/dev/null
    fi
    exit "${2:-1}"
}
section() { printf '\n  %s%s%s\n' "$CYN" "$1" "$OFF" >&2; }

# Root, and how much of it this box will give us. sudo WITHOUT -n waits for a
# password, which is a prompt when somebody is here and a hang when nobody is, so it
# is only allowed in the first case.
detect_root() {
    SUDO=""
    CAN_ROOT=1
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO="sudo"
    elif command -v sudo >/dev/null 2>&1 && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
        SUDO="sudo"
    else
        CAN_ROOT=0
    fi
}

# --- Questions -----------------------------------------------------------------
#
# Every question has a GIVEN form: a flag on the command line answers it, and the
# wizard says so instead of asking. That is what makes one script both the wizard
# and the thing a provisioning script calls.

# given "Question" "$GIVEN" default  ->  the flag's value if there was one, else asks.
given() {
    if [ -n "$2" ]; then
        printf '    %s%s%s %s%s (given)%s\n' "$BLD" "$1" "$OFF" "$DIM" "$2" "$OFF" >&2
        printf '%s' "$2"
    else
        ask "$1" "$3"
    fi
}

# ask_until validator "Question" "$GIVEN" default. Asks again until the validator
# accepts; a given or --yes answer that fails it is fatal, because asking again with
# nobody there is a hang.
ask_until() {
    local check="$1" q="$2" g="$3" d="$4" a
    while :; do
        a="$(given "$q" "$g" "$d")"
        if "$check" "$a"; then printf '%s' "$a"; return 0; fi
        if [ -n "$g" ] || [ "$ASSUME_YES" -eq 1 ]; then
            die "$q: \"$a\" is not $(describe_check "$check")" 2
        fi
        warn "that is not $(describe_check "$check")"
    done
}

describe_check() {
    case "$1" in
        is_port)     printf 'a port number (1-65535)' ;;
        is_number)   printf 'a whole number' ;;
        is_host)     printf 'a bare hostname (no scheme, no port, no path)' ;;
        is_hostport) printf 'host:port' ;;
        is_any)      printf 'an answer' ;;
        is_user)     printf 'a user on this machine' ;;
        is_unit)     printf 'a bare unit name, without .service' ;;
        *)           printf 'valid' ;;
    esac
}
is_any()      { [ -n "$1" ]; }
is_number()   { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
is_port()     { is_number "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_host()     { printf '%s' "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; }
is_hostport() { case "$1" in *:*) is_port "${1##*:}" && [ -n "${1%:*}" ] ;; *) return 1 ;; esac; }
is_user()     { id "$1" >/dev/null 2>&1; }
is_unit()     { case "$1" in ''|*/*|*.service|*' '*) return 1 ;; esac; }

# A password, read without echo. Empty keeps what is there; "-" clears it.
ask_secret() {
    local q="$1" a=""
    [ "$ASSUME_YES" -eq 1 ] && return 0
    printf '    %s%s%s %s[return keeps it, - clears it]%s ' "$BLD" "$q" "$OFF" "$DIM" "$OFF" >&2
    IFS= read -rs a || a=""
    printf '\n' >&2
    printf '%s' "$a"
}

# choose "Question" default  key "what it means"  key "what it means" ...
# A numbered list; a number or the key itself is an answer. Prints the key.
choose() {
    local q="$1" d="$2" keys=() descs=() i a mark
    shift 2
    while [ $# -gt 1 ]; do keys+=("$1"); descs+=("$2"); shift 2; done
    if [ "$ASSUME_YES" -eq 1 ]; then printf '%s' "$d"; return 0; fi
    printf '\n    %s%s%s\n' "$BLD" "$q" "$OFF" >&2
    for i in "${!keys[@]}"; do
        mark=" "; [ "${keys[$i]}" = "$d" ] && mark="*"
        printf '      %s%2d%s %s %-12s %s%s%s\n' "$CYN" "$((i + 1))" "$OFF" "$mark" \
            "${keys[$i]}" "$DIM" "${descs[$i]}" "$OFF" >&2
    done
    while :; do
        printf '    %s[%s]%s ' "$DIM" "$d" "$OFF" >&2
        IFS= read -r a || a=""
        [ -z "$a" ] && a="$d"
        if is_number "$a" && [ "$a" -ge 1 ] && [ "$a" -le "${#keys[@]}" ]; then
            printf '%s' "${keys[$((a - 1))]}"; return 0
        fi
        for i in "${keys[@]}"; do [ "$i" = "$a" ] && { printf '%s' "$a"; return 0; }; done
        warn "pick a number from the list, or one of: ${keys[*]}"
    done
}

# A choice that may also come from a flag. The flag must be one of the keys.
choose_given() {
    local q="$1" g="$2" d="$3" k
    shift 3
    if [ -n "$g" ]; then
        local args=("$@") i
        for ((i = 0; i < ${#args[@]}; i += 2)); do
            [ "${args[$i]}" = "$g" ] && {
                printf '    %s%s%s %s%s (given)%s\n' "$BLD" "$q" "$OFF" "$DIM" "$g" "$OFF" >&2
                printf '%s' "$g"; return 0; }
        done
        k=""; for ((i = 0; i < ${#args[@]}; i += 2)); do k="$k ${args[$i]}"; done
        die "$q: \"$g\" is not one of:$k" 2
    fi
    choose "$q" "$d" "$@"
}

# --- The plan ------------------------------------------------------------------

PLAN_DESC=()
PLAN_CMD=()
PLAN_SHOW=()

# act "what it does" command args...   queue a step. Internal steps are functions
# named do_*; they run like any other but are not offered as something to paste.
act() {
    local d="$1"; shift
    PLAN_DESC+=("$d")
    PLAN_CMD+=("$(printf '%q ' "$@")")
    case "$1" in do_*) PLAN_SHOW+=("") ;; *) PLAN_SHOW+=("$(printf '%q ' "$@")") ;; esac
}

# act_vhost "what" VHOST_FILE installer args...   an installer that writes VHOST_FILE,
# run so that a failure puts back what was there (do_guarded). Shown as the plain
# installer, which is what somebody finishing the plan by hand would type.
act_vhost() {
    local d="$1" f="$2"; shift 2
    act "$d" do_guarded "$f" "$@"
    PLAN_SHOW[$((${#PLAN_SHOW[@]} - 1))]="$(printf '%q ' "$@")"
}

# A line of the plan that is information, not a step: "nginx is already here".
plan_note() { PLAN_DESC+=("$1"); PLAN_CMD+=(""); PLAN_SHOW+=(""); }

plan_reset() { PLAN_DESC=(); PLAN_CMD=(); PLAN_SHOW=(); }

# The command as somebody would type it from the project directory.
shown_cmd() {
    local c="$1"
    c="${c//$(printf '%q' "$ROOT")\//./}"
    printf '%s' "${c% }"
}

print_plan() {
    local i
    printf '\n%s  This is the whole of it:%s\n\n' "$BLD" "$OFF" >&2
    for i in "${!PLAN_DESC[@]}"; do
        if [ -z "${PLAN_CMD[$i]}" ]; then
            printf '    %s·%s %s%s%s\n' "$DIM" "$OFF" "$DIM" "${PLAN_DESC[$i]}" "$OFF" >&2
        else
            printf '    %s-%s %s\n' "$GRN" "$OFF" "${PLAN_DESC[$i]}" >&2
            if [ "${VERBOSE:-0}" -eq 1 ] && [ -n "${PLAN_SHOW[$i]}" ]; then
                printf '        %s$ %s%s\n' "$DIM" "$(shown_cmd "${PLAN_SHOW[$i]}")" "$OFF" >&2
            fi
        fi
    done
    printf '\n' >&2
}

# The steps from $1 on, as commands to paste. do_* steps are this script's own and
# are named instead, with the subcommand that does the same.
print_remaining() {
    local i c
    for ((i = $1; i < ${#PLAN_CMD[@]}; i++)); do
        [ -z "${PLAN_CMD[$i]}" ] && continue
        c="${PLAN_SHOW[$i]}"
        if [ -z "$c" ]; then
            printf '      # %s\n' "${PLAN_DESC[$i]}"
        else
            printf '      %s\n' "$(shown_cmd "$c")"
        fi
    done
}

# Print, confirm, run. Returns non-zero when a step failed, after saying which.
run_plan() {
    local i any=0
    for i in "${PLAN_CMD[@]}"; do [ -n "$i" ] && any=1; done
    if [ "$any" -eq 0 ]; then
        printf '\n' >&2
        ok "nothing to change: it already says all of that"
        return 0
    fi

    print_plan
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        printf '  %s--dry-run: nothing was done. The commands, in order:%s\n\n' "$BLD" "$OFF"
        print_remaining 0
        printf '\n'
        return 0
    fi
    if ! ask_yn "Go ahead?" y; then
        printf '\n    nothing was done.\n\n'
        return 0
    fi

    for i in "${!PLAN_CMD[@]}"; do
        [ -z "${PLAN_CMD[$i]}" ] && continue
        step "${PLAN_DESC[$i]}"
        if ! eval "${PLAN_CMD[$i]}"; then
            printf '\n    %sthis step failed:%s %s\n' "$RED" "$OFF" "${PLAN_DESC[$i]}" >&2
            if [ $((i + 1)) -lt "${#PLAN_CMD[@]}" ]; then
                printf '\n    Everything before it is done. Once it is fixed, the rest is:\n\n' >&2
                print_remaining "$i" >&2
                printf '\n' >&2
            fi
            return 1
        fi
    done
    return 0
}

# --- Steps the plan can hold ---------------------------------------------------

# A string as YAML: quoted, with the two characters a double-quoted scalar escapes.
yaml_str() {
    local v="${1//\\/\\\\}"
    printf '"%s"' "${v//\"/\\\"}"
}

do_cfg_set() {
    local file="$1" key="$2" value="$3" before
    before="$(cfg_get "$file" "$key" 2>/dev/null)"
    cfg_set "$file" "$key" "$value" || { printf '    could not set %s in %s\n' "$key" "$file" >&2; return 1; }
    if cfg_is_secret "$key"; then ok "$file  $key: changed"; return 0; fi
    ok "$file  $key: ${before:-unset} -> $(cfg_get "$file" "$key")"
}

# The file each installer writes, by the installer's own rule, so a step can name
# the vhost before it exists.
proxy_vhost() {
    printf '%s/server-tls-%s.conf' "$SITES_DIR" "$(printf '%s' "$1-$2" | tr -c 'A-Za-z0-9._-' '-')"
}
origin_vhost() { printf '%s/%s.conf' "$SITES_DIR" "$1"; }

# Runs an installer that writes vhost $1, and puts back what was there if it fails.
# The installers test the configuration with `nginx -t` AFTER installing and linking
# the file, and die with it in place -- correct for a person at a terminal, who reads
# the error and edits it, but a wizard that stops there has left nginx unable to
# reload (or, at the next reboot, to start) over a change somebody only asked for.
do_guarded() {
    local f="$1" en bak="" had=0 nginx_bin
    shift
    en="$ENABLED_DIR/$(basename "$f")"
    if $SUDO test -f "$f"; then
        had=1; bak="$(mktemp)" || return 1
        $SUDO cat "$f" > "$bak" || { rm -f "$bak"; return 1; }
    fi
    "$@" && { [ -n "$bak" ] && rm -f "$bak"; return 0; }
    if [ "$had" -eq 1 ]; then
        $SUDO install -m 644 "$bak" "$f"; rm -f "$bak"
        printf '    put the previous %s back\n' "$f" >&2
    else
        $SUDO rm -f "$en" "$f"
        printf '    took the new %s out again\n' "$f" >&2
    fi
    nginx_bin="$(find_nginx)" || nginx_bin=nginx
    $SUDO "$nginx_bin" -t >/dev/null 2>&1 && $SUDO systemctl reload nginx >/dev/null 2>&1
    return 1
}

# Takes a vhost out, and puts it back if nginx refuses what is left: a removal that
# leaves nginx unable to start is worse than the vhost it removed.
do_vhost_remove() {
    local f="$1" en bak nginx_bin
    en="$ENABLED_DIR/$(basename "$f")"
    nginx_bin="$(find_nginx)" || nginx_bin=nginx
    bak="$(mktemp)" || return 1
    $SUDO cat "$f" > "$bak" 2>/dev/null || { rm -f "$bak"; printf '    cannot read %s\n' "$f" >&2; return 1; }
    $SUDO rm -f "$en" "$f" || { rm -f "$bak"; return 1; }
    if $SUDO "$nginx_bin" -t >/dev/null 2>&1; then
        $SUDO systemctl reload nginx || { rm -f "$bak"; return 1; }
        rm -f "$bak"
        ok "removed $f"
    else
        $SUDO install -m 644 "$bak" "$f" && $SUDO ln -sf "$f" "$en"
        rm -f "$bak"
        $SUDO "$nginx_bin" -t
        printf '    nginx refused the configuration without %s, so it was put back\n' "$f" >&2
        return 1
    fi
}

# A Let's Encrypt lineage, and the renewal hook issue-letsencrypt.sh wrote for it.
do_le_delete() {
    $SUDO certbot delete --non-interactive --cert-name "$1" || return 1
    $SUDO rm -f "$LE_DIR/renewal-hooks/deploy/tmc-$1.sh"
    ok "deleted the certificate $1 and its renewal hook"
}

do_pkg() {
    pkg_install "$1" "$2" "$3" || { printf '    could not install %s; install it and re-run\n' "$1" >&2; return 1; }
    ok "installed $1"
}

do_nginx_up() {
    $SUDO systemctl is-active --quiet nginx || $SUDO systemctl start nginx || return 1
    $SUDO systemctl is-enabled --quiet nginx 2>/dev/null || $SUDO systemctl enable nginx >/dev/null 2>&1
    ok "nginx is running and starts at boot"
}

do_fw() {
    local verb="$1" fw="$2" port="$3" proto="${4:-tcp}"
    if [ "$verb" = open ]; then
        firewall_allow "$fw" "$port" "$proto" && ok "$port/$proto open in $fw"
    else
        firewall_close "$fw" "$port" "$proto" && ok "$port/$proto closed in $fw"
    fi
}

do_restart() {
    $SUDO systemctl restart "$1.service" || return 1
    sleep 2
    $SUDO systemctl is-active --quiet "$1.service" || { printf '    %s did not stay up: sudo journalctl -u %s -n 50\n' "$1" "$1" >&2; return 1; }
    ok "restarted $1"
}

# --- nginx, which the proxy and the origin both need ---------------------------

# Queues what has to exist before a vhost can: nginx installed, running, enabled.
# A running nginx is somebody else's nginx and is never restarted, only reloaded by
# the installers.
plan_nginx() {
    if find_nginx >/dev/null 2>&1; then
        local n
        n="$($SUDO "$(find_nginx)" -T 2>/dev/null | grep -cE '^[[:space:]]*server_name[[:space:]]' || true)"
        plan_note "nginx is already here${n:+, serving $n server block(s)}; this adds to it"
        $SUDO systemctl is-active --quiet nginx 2>/dev/null || act "start nginx" do_nginx_up
    else
        act "install nginx" do_pkg nginx nginx nginx
        act "start nginx and enable it at boot" do_nginx_up
    fi
}

# The public TLS port to offer: 443 unless something that is not nginx holds it.
# nginx already on 443 is the normal case -- a second server block on one port with a
# different name is what SNI is for -- and a game on a high port is the one thing a
# player behind an office firewall cannot reach.
default_tls_port() {
    local holder
    holder="$(port_holder 443)"
    if [ $? -ne 0 ] || [ "$holder" = "nginx" ]; then printf '443'; else printf '6065'; fi
}

# Refuses a public port another process holds. Fatal here rather than at the next nginx
# restart, which could be weeks later and somebody else's problem.
check_tls_port() {
    local holder
    if holder="$(port_holder "$1")"; then
        case "${holder:-unknown}" in
            nginx) return 0 ;;
            unknown) die "something is listening on $1 and this run cannot see what.
    Re-run with sudo, or pick another port." 1 ;;
            *) die "$holder is already listening on $1. nginx cannot have that port as well,
    and a vhost written for it would break the next nginx restart. Pick another." 1 ;;
        esac
    fi
}

# --- Certificates ----------------------------------------------------------------
#
# One request is the C_* globals. cert_ask fills them, offering whatever they already
# hold as the defaults -- which is how modify.sh keeps a certificate's method when
# only its domain changes -- and cert_plan queues the commands. The resulting paths
# are known at plan time, because every source puts its files at a name derived from
# the domain, so a vhost queued after the certificate can name them.

C_SRC=""; C_EMAIL=""; C_METHOD=""; C_WEBROOT=""; C_DNS_PLUGIN=""; C_DNS_CRED=""
C_WILDCARD=0; C_STAGING=0; C_CERT=""; C_KEY=""; C_DOMAIN=""; C_RENEW=0; C_CREATE_CA=0

# The webroot nginx's stock site serves, which is not the same directory everywhere.
# A request against the wrong one is a FAILED validation, which is what the rate limit
# counts.
default_webroot() {
    local d
    for d in /var/www/html /usr/share/nginx/html; do [ -d "$d" ] && { printf '%s' "$d"; return; }; done
    printf '/var/www/html'
}

le_live_name() {
    local n="${1#\*.}"
    [ "$2" -eq 1 ] && n="$n-staging"
    printf '%s' "$n"
}

# cert_ask DOMAIN ALLOW_SELF_SIGNED
cert_ask() {
    local domain="$1" allow_self="${2:-0}" d src_default opts
    C_DOMAIN="$domain"

    src_default="${C_SRC:-letsencrypt}"
    case "$domain" in
        *.test|*.local|*.localhost|*.internal|*.lan|*.home.arpa) [ -z "$C_SRC" ] && src_default="local-ca" ;;
    esac
    opts=(letsencrypt "Let's Encrypt: real, trusted everywhere, renews itself"
          local-ca    "this box's development CA: trusted once per machine"
          files       "a certificate and key you already have")
    [ "$allow_self" -eq 1 ] && opts+=(self-signed "development only: every browser refuses it until trusted")
    C_SRC="$(choose_given "Where does the certificate for $domain come from?" "${G_CERT_SOURCE:-}" "$src_default" "${opts[@]}")"

    case "$C_SRC" in
    letsencrypt)
        C_EMAIL="$(given "Email for expiry warnings (empty registers without one)" "${G_EMAIL:-}" "$C_EMAIL")"
        C_METHOD="$(choose_given "How does Let's Encrypt check you own $domain?" "${G_METHOD:-}" "${C_METHOD:-webroot}" \
            webroot    "HTTP-01 from a directory nginx already serves on :80. Nothing restarts" \
            nginx      "HTTP-01 with certbot driving nginx for the challenge" \
            standalone "HTTP-01 with certbot binding :80 itself (no web server here)" \
            dns        "DNS-01 through your DNS provider's API. Wildcards; :80 may be closed" \
            manual     "DNS-01 by hand: it prints a TXT record and waits. Cannot renew alone")"
        case "$C_METHOD" in
            webroot)
                C_WEBROOT="$(given "Directory nginx serves on :80" "${G_WEBROOT:-}" "${C_WEBROOT:-$(default_webroot)}")" ;;
            dns)
                C_DNS_PLUGIN="$(given "certbot DNS plugin (cloudflare, route53, digitalocean, google, ovh, ...)" "${G_DNS_PLUGIN:-}" "${C_DNS_PLUGIN:-cloudflare}")"
                if [ "$C_DNS_PLUGIN" != "route53" ]; then
                    C_DNS_CRED="$(given "Credentials file for dns-$C_DNS_PLUGIN" "${G_DNS_CRED:-}" "${C_DNS_CRED:-/root/.secrets/certbot/$C_DNS_PLUGIN.ini}")"
                    if ! $SUDO test -f "$C_DNS_CRED" 2>/dev/null; then
                        warn "there is no $C_DNS_CRED yet. Write it before the plan runs, mode 600:
           sudo install -m 600 /dev/null $C_DNS_CRED && sudoedit $C_DNS_CRED
       What goes in it is in the plugin's docs: certbot-dns-$C_DNS_PLUGIN."
                    fi
                fi ;;
        esac
        case "$C_METHOD" in
            dns|manual)
                if [ "${G_WILDCARD:-0}" -eq 1 ]; then C_WILDCARD=1
                elif ask_yn "Also cover *.$domain (a wildcard)?" "$([ "$C_WILDCARD" -eq 1 ] && echo y || echo n)"; then C_WILDCARD=1
                else C_WILDCARD=0; fi ;;
            *)
                [ "${G_WILDCARD:-0}" -eq 1 ] && die "a wildcard needs DNS-01: --method dns or --method manual" 2
                C_WILDCARD=0
                # HTTP-01 is Let's Encrypt reaching this name on :80. A name that does
                # not resolve is a failed validation, and five of those is an hour's
                # lockout, so say it now while it costs nothing.
                if command -v getent >/dev/null 2>&1 && ! getent ahosts "$domain" >/dev/null 2>&1; then
                    warn "$domain does not resolve from here. Point its DNS at this box first,
       or the validation fails (and failures count against the rate limit)."
                fi ;;
        esac
        if [ "${G_STAGING:-0}" -eq 1 ]; then C_STAGING=1
        elif ask_yn "Use the staging CA first (untrusted, but off the rate limits)?" "$([ "$C_STAGING" -eq 1 ] && echo y || echo n)"; then C_STAGING=1
        else C_STAGING=0; fi
        d="$LE_DIR/live/$(le_live_name "$domain" "$C_STAGING")"
        C_CERT="$d/fullchain.pem"; C_KEY="$d/privkey.pem"
        ;;
    local-ca)
        C_CERT="$LOCAL_CERT_DIR/${domain#\*.}.crt"; C_KEY="$LOCAL_CERT_DIR/${domain#\*.}.key"
        C_CREATE_CA=0
        if [ ! -f "$LOCAL_CA_CERT" ]; then
            if [ "${G_CREATE_CA:-0}" -eq 1 ] || ask_yn "There is no development CA at $LOCAL_CA_CERT yet. Create one?" y; then
                C_CREATE_CA=1
            else
                die "a local-ca certificate needs the CA. Create it, or pick another source." 2
            fi
        fi
        ;;
    files)
        C_CERT="$(ask_until is_any "Certificate (full chain, PEM)" "${G_CERT:-}" "$C_CERT")"
        C_KEY="$(ask_until is_any "Private key (PEM)" "${G_KEY:-}" "$C_KEY")"
        $SUDO test -f "$C_CERT" || die "no certificate at $C_CERT" 2
        $SUDO test -f "$C_KEY"  || die "no key at $C_KEY" 2
        if ! $SUDO openssl x509 -in "$C_CERT" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'; then
            warn "$C_CERT does not name $domain. Browsers will refuse it, and a WebSocket
       handshake that fails on a certificate raises no prompt: the game just cannot connect."
        fi
        ;;
    self-signed)
        C_CERT="$LOCAL_CERT_DIR/$domain.crt"; C_KEY="$LOCAL_CERT_DIR/$domain.key"
        ;;
    esac
}

# The flags issue-letsencrypt.sh needs for the request in C_*.
le_args() {
    LE_ARGS=(--domain "$C_DOMAIN" --method "$C_METHOD" --no-next-steps)
    [ -n "$C_EMAIL" ] && LE_ARGS+=(--email "$C_EMAIL")
    [ "$C_METHOD" = webroot ] && LE_ARGS+=(--webroot "$C_WEBROOT")
    [ "$C_METHOD" = dns ] && LE_ARGS+=(--dns-plugin "$C_DNS_PLUGIN")
    [ -n "$C_DNS_CRED" ] && [ "$C_METHOD" = dns ] && LE_ARGS+=(--dns-credentials "$C_DNS_CRED")
    [ "$C_WILDCARD" -eq 1 ] && LE_ARGS+=(--wildcard)
    [ "$C_STAGING" -eq 1 ] && LE_ARGS+=(--staging)
    [ "$C_RENEW" -eq 1 ] && LE_ARGS+=(--force-renewal)
    command -v certbot >/dev/null 2>&1 || LE_ARGS+=(--install-certbot)
}

# Queues the commands that produce C_CERT and C_KEY. self-signed is the game
# origin's own flag and queues nothing here.
cert_plan() {
    case "$C_SRC" in
    letsencrypt)
        if [ "$C_METHOD" = dns ] && ! $SUDO certbot plugins 2>/dev/null | grep -q "dns-$C_DNS_PLUGIN"; then
            act "install certbot's dns-$C_DNS_PLUGIN plugin" do_pkg "python3-certbot-dns-$C_DNS_PLUGIN" "python3-certbot-dns-$C_DNS_PLUGIN" "certbot-dns-$C_DNS_PLUGIN"
        fi
        le_args
        local what="a certificate for $C_DOMAIN"
        [ "$C_WILDCARD" -eq 1 ] && what="$what and *.$C_DOMAIN"
        [ "$C_RENEW" -eq 1 ] && what="a fresh certificate for $C_DOMAIN"
        act "$what from Let's Encrypt over $C_METHOD$([ "$C_STAGING" -eq 1 ] && echo ' (staging)')" \
            $SUDO "$ROOT/deploy/issue-letsencrypt.sh" "${LE_ARGS[@]}"
        ;;
    local-ca)
        local a=()
        [ "$C_CREATE_CA" -eq 1 ] && a+=(--create-ca)
        act "a certificate for $C_DOMAIN from the development CA" \
            $SUDO "$ROOT/deploy/issue-local-cert.sh" "${a[@]}" --out-dir "$(dirname "$C_CERT")" --name "$(basename "$C_CERT" .crt)" "$C_DOMAIN"
        ;;
    files) plan_note "using $C_CERT" ;;
    esac
}

# Fills C_* from a certificate that is already installed, so a change to a vhost can
# ask "same as now?" instead of starting the certificate questions from nothing.
cert_preset_from() {
    local cert="$1" name conf auth
    C_SRC=""; C_EMAIL=""; C_METHOD=""; C_WEBROOT=""; C_DNS_PLUGIN=""; C_DNS_CRED=""
    C_WILDCARD=0; C_STAGING=0; C_CERT="$cert"; C_KEY="$2"; C_RENEW=0; C_CREATE_CA=0
    if name="$(le_lineage "$cert")"; then
        C_SRC=letsencrypt
        conf="$($SUDO cat "$LE_DIR/renewal/$name.conf" 2>/dev/null)"
        auth="$(printf '%s\n' "$conf" | sed -n 's/^authenticator *= *//p' | head -1)"
        case "$auth" in
            webroot)
                C_METHOD=webroot
                C_WEBROOT="$(printf '%s\n' "$conf" | sed -n 's/^webroot_path *= *//p' | head -1)"
                C_WEBROOT="${C_WEBROOT%,}"
                [ -z "$C_WEBROOT" ] && C_WEBROOT="$(printf '%s\n' "$conf" | sed -n '/^\[\[webroot_map\]\]/,/^\[/{s/^[^=]* *= *//p}' | head -1)" ;;
            nginx|standalone|manual) C_METHOD="$auth" ;;
            dns-*)
                C_METHOD=dns; C_DNS_PLUGIN="${auth#dns-}"
                C_DNS_CRED="$(printf '%s\n' "$conf" | sed -n "s/^dns_${C_DNS_PLUGIN//-/_}_credentials *= *//p" | head -1)" ;;
        esac
        # The ACME server, not the word: a lineage named staging.example.com has it in
        # every path of a production renewal file.
        printf '%s\n' "$conf" | grep -q '^server *= *.*acme-staging' && C_STAGING=1
        $SUDO openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:\*\.' && C_WILDCARD=1
    elif cert_is_local_ca "$cert"; then
        C_SRC=local-ca
    else
        C_SRC=files
    fi
}

le_lineage() {
    case "$1" in
        "$LE_DIR"/live/*/*) local n="${1#"$LE_DIR"/live/}"; printf '%s' "${n%%/*}" ;;
        *) return 1 ;;
    esac
}

cert_is_local_ca() {
    $SUDO openssl x509 -in "$1" -noout -issuer 2>/dev/null | grep -q 'TMC Local Development CA'
}

# One line about a certificate: where it is from and when it runs out.
cert_describe() {
    local cert="$1" end src name auth
    if ! $SUDO test -f "$cert" 2>/dev/null; then printf '%smissing: %s%s' "$RED" "$cert" "$OFF"; return; fi
    end="$($SUDO openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    if name="$(le_lineage "$cert")"; then
        auth="$($SUDO sed -n 's/^authenticator *= *//p' "$LE_DIR/renewal/$name.conf" 2>/dev/null | head -1)"
        src="Let's Encrypt${auth:+ ($auth)}"
        case "$name" in *-staging) src="$src, STAGING (untrusted)" ;; esac
    elif cert_is_local_ca "$cert"; then
        src="development CA"
    elif [ "$($SUDO openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//')" = \
           "$($SUDO openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')" ]; then
        src="self-signed"
    else
        src="$($SUDO openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *//p')"
    fi
    if [ -n "$end" ] && ! $SUDO openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
        printf '%s, %sEXPIRED %s%s' "$src" "$RED" "$end" "$OFF"
    elif [ -n "$end" ] && ! $SUDO openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1; then
        printf '%s, %sexpires %s%s' "$src" "$YLW" "$end" "$OFF"
    else
        printf '%s, expires %s' "$src" "${end:-?}"
    fi
}

# --- What is deployed here ------------------------------------------------------
#
# Read out of the rendered vhosts, whose first line each template writes for exactly
# this: install-server-tls.sh's "TLS in front of a dot-server, for D:P -> B", and
# install-game-origin.sh's "D -- THE GAME CONTENT ORIGIN." Anything nginx serves that
# these scripts did not write is somebody else's and is not offered for change.

E_KIND=(); E_DOMAIN=(); E_PORT=(); E_BACKEND=(); E_CERT=(); E_KEY=(); E_FILE=()
E_ENABLED=(); E_ORIGINS=(); E_ROOT=(); E_CROOT=(); E_CACHE=()

entries_scan() {
    local f first rest kind domain port backend
    E_KIND=(); E_DOMAIN=(); E_PORT=(); E_BACKEND=(); E_CERT=(); E_KEY=(); E_FILE=()
    E_ENABLED=(); E_ORIGINS=(); E_ROOT=(); E_CROOT=(); E_CACHE=()
    [ -d "$SITES_DIR" ] || return 0
    for f in "$SITES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        first="$(head -1 "$f" 2>/dev/null)"
        case "$first" in
            '# TLS in front of a dot-server, for '*)
                rest="${first#'# TLS in front of a dot-server, for '}"
                kind=proxy
                domain="${rest%%:*}"; rest="${rest#*:}"
                port="${rest%% *}"; backend="${rest##* }" ;;
            '# '*' -- THE GAME CONTENT ORIGIN.')
                kind=origin
                domain="${first#'# '}"; domain="${domain%' -- THE GAME CONTENT ORIGIN.'}"
                port=443; backend="" ;;
            *) continue ;;
        esac
        E_KIND+=("$kind"); E_DOMAIN+=("$domain"); E_PORT+=("$port"); E_BACKEND+=("$backend")
        E_FILE+=("$f")
        E_CERT+=("$(sed -n 's/^[[:space:]]*ssl_certificate[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$f" | head -1)")
        E_KEY+=("$(sed -n 's/^[[:space:]]*ssl_certificate_key[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$f" | head -1)")
        if [ -e "$ENABLED_DIR/$(basename "$f")" ]; then E_ENABLED+=(1); else E_ENABLED+=(0); fi
        if [ "$kind" = origin ]; then
            # The template's own lines, in its own order: the player's alias comes
            # first, the content's second.
            E_ORIGINS+=("$(sed -n 's/.*frame-ancestors \([^;]*\);.*/\1/p' "$f" | head -1)")
            E_ROOT+=("$(sed -n 's/^[[:space:]]*alias \(.*\)\/;/\1/p' "$f" | sed -n 1p)")
            E_CROOT+=("$(sed -n 's/^[[:space:]]*alias \(.*\)\/;/\1/p' "$f" | sed -n 2p)")
            E_CACHE+=("$(sed -n 's/^[[:space:]]*add_header Cache-Control "\([^"]*\)".*/\1/p' "$f" | head -1)")
        else
            E_ORIGINS+=(""); E_ROOT+=(""); E_CROOT+=(""); E_CACHE+=("")
        fi
    done
}

# The units install-systemd.sh wrote, and which checkout each one runs.
U_NAME=(); U_DIR=(); U_USER=()
units_scan() {
    local f
    U_NAME=(); U_DIR=(); U_USER=()
    [ -d "$SYSTEMD_DIR" ] || return 0
    for f in "$SYSTEMD_DIR"/*.service; do
        [ -f "$f" ] || continue
        grep -q 'Written by dot-server-deploy/deploy/install-systemd.sh' "$f" 2>/dev/null || continue
        U_NAME+=("$(basename "$f" .service)")
        U_DIR+=("$(sed -n 's/^WorkingDirectory=//p' "$f" | head -1)")
        U_USER+=("$(sed -n 's/^User=//p' "$f" | head -1)")
    done
}

# The unit that runs THIS checkout, if there is one.
unit_for_root() {
    local i
    units_scan
    for i in "${!U_NAME[@]}"; do
        [ "${U_DIR[$i]}" = "$ROOT" ] && { printf '%s' "${U_NAME[$i]}"; return 0; }
    done
    return 1
}

# Is this backend the server in this checkout? Loopback, and this cfg/'s port.
backend_is_here() {
    local host="${1%:*}" port="${1##*:}"
    case "$host" in 127.0.0.1|localhost|::1|'[::1]') ;; *) return 1 ;; esac
    [ "$port" = "$(cfg_or cfg/net.yml net_port 6064)" ]
}

entries_print() {
    local i state
    entries_scan
    units_scan
    if [ "${#E_KIND[@]}" -eq 0 ]; then
        note "no vhost written by deploy/ in $SITES_DIR"
    fi
    for i in "${!E_KIND[@]}"; do
        state=""; [ "${E_ENABLED[$i]}" -eq 0 ] && state=" ${YLW}(not enabled)${OFF}"
        if [ "${E_KIND[$i]}" = proxy ]; then
            printf '    %s%2d%s  %swss://%s:%s%s  ->  %s%s%s\n' "$CYN" "$((i + 1))" "$OFF" "$BLD" \
                "${E_DOMAIN[$i]}" "${E_PORT[$i]}" "$OFF" "${E_BACKEND[$i]}" \
                "$(backend_is_here "${E_BACKEND[$i]}" && printf '  %s(this checkout)%s' "$DIM" "$OFF")" "$state"
        else
            printf '    %s%2d%s  %shttps://%s/game/%s  game origin, framed by %s%s\n' "$CYN" "$((i + 1))" "$OFF" "$BLD" \
                "${E_DOMAIN[$i]}" "$OFF" "${E_ORIGINS[$i]}" "$state"
            printf '          %splayer %s, content %s, Cache-Control %s%s\n' "$DIM" "${E_ROOT[$i]}" "${E_CROOT[$i]}" "${E_CACHE[$i]}" "$OFF"
        fi
        printf '          %scertificate: %s%s\n' "$DIM" "$(cert_describe "${E_CERT[$i]}")" "$OFF"
        printf '          %s%s%s\n' "$DIM" "${E_FILE[$i]}" "$OFF"
    done
    for i in "${!U_NAME[@]}"; do
        printf '    %sunit%s  %s%s.service%s  %s, as %s, %s\n' "$CYN" "$OFF" "$BLD" "${U_NAME[$i]}" "$OFF" \
            "${U_DIR[$i]}" "${U_USER[$i]:-root}" \
            "$(systemctl is-active "${U_NAME[$i]}.service" 2>/dev/null || echo unknown)"
    done
}

# find_entry QUERY -> index. A vhost file name, domain:port, or a domain that names
# exactly one entry. Ambiguity is fatal and lists the candidates.
find_entry() {
    local q="$1" i hits=()
    entries_scan
    if is_number "$q" && [ "$q" -ge 1 ] && [ "$q" -le "${#E_KIND[@]}" ]; then printf '%s' "$((q - 1))"; return 0; fi
    for i in "${!E_KIND[@]}"; do
        case "$q" in
            "$(basename "${E_FILE[$i]}")"|"$(basename "${E_FILE[$i]}" .conf)"|"${E_FILE[$i]}") hits+=("$i") ;;
            "${E_DOMAIN[$i]}:${E_PORT[$i]}") hits+=("$i") ;;
            "${E_DOMAIN[$i]}") hits+=("$i") ;;
        esac
    done
    [ "${#hits[@]}" -eq 1 ] && { printf '%s' "${hits[0]}"; return 0; }
    if [ "${#hits[@]}" -eq 0 ]; then
        die "nothing deployed here matches \"$q\". ./deploy.sh list shows what is." 2
    fi
    local names=""
    for i in "${hits[@]}"; do names="$names ${E_DOMAIN[$i]}:${E_PORT[$i]}"; done
    die "\"$q\" matches more than one:$names. Name one with its port." 2
}
