#!/usr/bin/env bash
#
# One command to go from a clone to a server you can start.
#
#   ./setup.sh                  set everything up and write ./server
#   ./setup.sh --check          set up, then boot the server once and shut it down
#   ./setup.sh --no-import      skip the Godot import pass (fast, for a re-run)
#   ./setup.sh --godot PATH     use a specific runtime
#   ./setup.sh --no-download    never fetch a runtime; fail if there is none
#   ./setup.sh --no-clone       never git clone a sibling; fail if one is missing
#   ./setup.sh --update         git pull every sibling repository first
#   ./setup.sh --vendor         COPY the addons instead of linking them
#
#   ./setup.sh --letsencrypt --domain demo.example.com --email ops@example.com
#                               ...and then get a real certificate for it
#
#   ./setup.sh --full           THE GUIDED INSTALL. A vanilla Linux box to a server
#                               somebody can connect to, asking one question at a
#                               time with an answer already in the brackets
#   ./setup.sh --full --yes     the same install, every default taken, nobody typing
#
# WHAT IT DOES, AND WHY EACH STEP IS HERE
#
#   1. Finds a Godot 4.7+ runtime, and DOWNLOADS the pinned one when the machine has
#      none. That download is tools/fetch-godot.sh and the verification is the whole
#      of it: one pinned version, the sha512 checked into git rather than fetched
#      from beside the binary, and no path through it that installs something
#      unverified. `--no-download` keeps the old behaviour of refusing to fetch.
#   2. Wires in the dot-* addons. Each one is a separate repository and there is no
#      way to clone the tree at once, so this is the one place that knowledge lives.
#      Symlinks when the sibling repositories are there, which is a developer
#      checkout; a copy otherwise, which is what a release tarball needs.
#   3. Copies every built-in game into the build. They are `kind: builtin`, and the
#      reason is measured rather than assumed -- see content/lobby/game.yml.
#   4. Runs Godot's import pass. Without it every class_name global is unresolved,
#      every cross-file type reference fails, and the whole thing looks like dozens
#      of unrelated errors.
#   5. Copies cfg.example/ into cfg/, file by file, for every file cfg/ does not
#      already have -- generating an RCON password ONCE if it writes cfg/rcon.yml at
#      all, and printing it once. cfg/ is NOT in this repository: it is what one
#      deployment decided, so tracking it made `git pull` on a running box stop on
#      the operator's own edits. It never overwrites a config file that exists --
#      your edits are the configuration, and regenerating on upgrade throws them away
#      on the one run nobody is watching -- so it finishes by NAMING any setting the
#      templates have gained that your files do not mention.
#   6. Copies export_presets.example.cfg into export_presets.cfg when there is none,
#      for the same reason and with the same rule: the editor rewrites that file, so
#      it is not tracked either -- and an export preset nobody has is what made
#      `./server export-web` fail on a fresh machine for a preset that existed only
#      where somebody had made one by hand.
#   7. Writes ./server.
#   8. ONLY WITH --letsencrypt: runs deploy/issue-letsencrypt.sh for a real
#      certificate. Opt-in and never implied, because it is the one step here that
#      needs root, needs the internet, and can be RATE LIMITED -- five failed
#      validations on one hostname locks that name out for an hour, so a setup that
#      tried it on every run would punish the re-run that is otherwise free. Every
#      argument after `--` goes to that script untouched.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

GODOT_ARG=""
DO_IMPORT=1
# A box with no network, or a policy that says binaries arrive one way and it is not
# this one. TMC_NO_DOWNLOAD is the same switch for a unit file or a CI job, which
# cannot add an argument to a line somebody else wrote.
DO_DOWNLOAD=1
[ -n "${TMC_NO_DOWNLOAD:-}" ] && DO_DOWNLOAD=0

# Clone the siblings this project needs.
#
# [b]On by default, and it only ever runs when the alternative is failing.[/b] Nothing is
# cloned for a repository that is already beside this one, and nothing is cloned for an
# addon already vendored into ./addons/ -- which is what a release tarball is, and it
# must keep working with no network at all. So the only run that writes anything into
# the parent directory is the run that would otherwise have stopped and printed fifty
# names at somebody.
DO_CLONE=1

# Pull every sibling repository before wiring them in.
#
# OFF by default: `git pull` on somebody's checkout is not a thing to do because they
# typed the usual command, and a developer's tree is often mid-change on purpose.
DO_UPDATE=0
[ -n "${TMC_NO_CLONE:-}" ] && DO_CLONE=0
DO_CHECK=0
VENDOR=0

# The guided install. Everything it decides is asked for, and everything it asks has
# a default, so --full --yes is the same install with nobody typing.
DO_FULL=0
ASSUME_YES=0

# TLS. Nothing here happens without --letsencrypt; the rest only says what.
DO_LETSENCRYPT=0
LE_DOMAINS=()
LE_EMAIL="${TMC_LE_EMAIL:-}"
LE_METHOD="${TMC_LE_METHOD:-}"
LE_STAGING=0
LE_EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --godot)     GODOT_ARG="${2:-}"; shift 2 ;;
        --no-import) DO_IMPORT=0; shift ;;
        --no-download) DO_DOWNLOAD=0; shift ;;
        --no-clone)    DO_CLONE=0; shift ;;
        --update)      DO_UPDATE=1; shift ;;
        --check)     DO_CHECK=1; shift ;;
        --vendor)    VENDOR=1; shift ;;
        --letsencrypt) DO_LETSENCRYPT=1; shift ;;
        --domain)    LE_DOMAINS+=("${2:?--domain needs a value}"); shift 2 ;;
        --email)     LE_EMAIL="${2:?--email needs a value}"; shift 2 ;;
        --tls-method) LE_METHOD="${2:?--tls-method needs a value}"; shift 2 ;;
        --staging)   LE_STAGING=1; shift ;;
        --full)      DO_FULL=1; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        # Everything after a bare `--` belongs to issue-letsencrypt.sh. That script
        # has twenty options and this one is not going to grow a copy of each: a
        # wrapper that re-declares the arguments it forwards is a second list to keep
        # in step, and the half that drifts is always the one nobody uses often.
        --)          shift; LE_EXTRA=("$@"); break ;;
        -h|--help)   sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'

step() { printf '\n%s==>%s %s\n' "$BLD" "$OFF" "$1"; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$1"; }
die()  { printf '\n    %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }

# --- Asking, and the rules it follows --------------------------------------
#
# Three of them, and they are what separates an installer from a script that runs
# commands at you:
#
#   Every question has a DEFAULT, and the default is what is already true -- the
#   value in cfg/ if this box has one, the hostname if it has one of those. Pressing
#   return through the whole thing is a supported way to install this.
#
#   NOTHING IS DONE UNTIL EVERY QUESTION IS ANSWERED. The answers are collected, the
#   plan is printed, and one confirmation covers the lot. An installer that acts on
#   answer three while asking answer four cannot be stopped at answer five, and half
#   an install is worse than none.
#
#   --yes takes every default and asks nothing, so the same install runs from a
#   provisioning script. A prompt read with no terminal attached is a hang, not a
#   question, which is why this is a flag and not a guess about stdin.

# The prompt goes to STDERR because the answer comes back through a command
# substitution, and a prompt printed on stdout would be captured as part of it.
ask() {
    local q="$1" d="$2" a=""
    if [ "$ASSUME_YES" -eq 1 ]; then printf '%s' "$d"; return 0; fi
    printf '    %s%s%s %s[%s]%s ' "$BLD" "$q" "$OFF" "$DIM" "$d" "$OFF" >&2
    IFS= read -r a || a=""
    printf '%s' "${a:-$d}"
}

# ask_yn "Question" y   ->  0 for yes, 1 for no. The capital in the brackets is the
# default, the way every package manager has shown it for twenty years.
ask_yn() {
    local q="$1" d="$2" a="" hint
    case "$d" in [Yy]*) hint="Y/n" ;; *) hint="y/N" ;; esac
    if [ "$ASSUME_YES" -eq 1 ]; then
        case "$d" in [Yy]*) return 0 ;; *) return 1 ;; esac
    fi
    while :; do
        printf '    %s%s%s %s[%s]%s ' "$BLD" "$q" "$OFF" "$DIM" "$hint" "$OFF" >&2
        IFS= read -r a || a=""
        [ -z "$a" ] && a="$d"
        case "$a" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) printf '    %sanswer y or n%s\n' "$YLW" "$OFF" >&2 ;;
        esac
    done
}

PLAN=()
plan() { PLAN+=("$1"); }

# Read a value out of a YAML file so a question can offer what is already there.
# The comment is stripped AFTER the quoted value rather than at the first `#`,
# because `sv_name: "Server #1"` is a legal name and the naive version renames it.
cfg_get() {
    local file="$1" key="$2" line v
    [ -f "$file" ] || return 1
    line="$(grep -m1 -E "^${key}:" "$file" 2>/dev/null)" || return 1
    v="${line#*:}"
    v="${v#"${v%%[![:space:]]*}"}"
    case "$v" in
        '"'*) v="${v#\"}"; v="${v%%\"*}" ;;
        *)    v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}" ;;
    esac
    printf '%s' "$v"
}

# What cfg/ already says, or a default when it says nothing. Every question in the
# guided install is built on this: the answer in the brackets is the answer that is
# already true, so a re-run changes nothing unless somebody types something.
cfg_or() {
    local v
    v="$(cfg_get "$1" "$2" 2>/dev/null)"
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$3"
}

# Write one key back, keeping the line's comment and the file's mode. `cat >` rather
# than `mv`, because cfg/rcon.yml is 0600 and mv would give it the temporary file's
# permissions -- which is how a password becomes world-readable.
cfg_set() {
    local file="$1" key="$2" value="$3" tmp
    [ -f "$file" ] || return 1

    # A key the file has never heard of is APPENDED, not refused. cfg/ is written
    # once and then belongs to the operator, so a server set up a year ago has the
    # keys of a year ago -- and this box's cfg/server.yml really is missing
    # sv_tickrate, which step 5 reports and nobody has acted on. Refusing there
    # means the installer asked a question, was answered, and then quietly did
    # nothing with it, which is worse than either doing it or not asking.
    if ! grep -qE "^${key}:" "$file"; then
        # A file whose last line has no newline -- cfg.example/net.yml ends in a bare
        # "# Performance" comment and this is not hypothetical -- would otherwise get
        # the new key glued onto the end of that line, where it is a comment and does
        # nothing. In command substitution a trailing newline is stripped, so this
        # test is empty exactly when the last byte IS one.
        [ -n "$(tail -c 1 "$file")" ] && printf '\n' >> "$file"
        printf '%s: %s\n' "$key" "$value" >> "$file" || return 1
        return 0
    fi

    tmp="$(mktemp)" || return 1
    awk -v k="$key" -v v="$value" '
        !done && index($0, k ":") == 1 {
            rest = substr($0, length(k) + 2)
            c = ""
            if (rest ~ /^[[:space:]]*"/) {
                q = index(substr(rest, index(rest, "\"") + 1), "\"")
                tail = substr(rest, index(rest, "\"") + q + 1)
                if (index(tail, "#") > 0) c = "  " substr(tail, index(tail, "#"))
            } else if (index(rest, "#") > 0) {
                c = "  " substr(rest, index(rest, "#"))
            }
            print k ": " v c
            done = 1
            next
        }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Who is listening on a port, if anybody. Two questions rather than one: `ss` prints
# the process column only to root, so an unprivileged look finds nothing on a port
# that is very much taken -- and answering "free" there is how an installer writes a
# vhost that stops nginx from starting.
#
# Prints the holder's name, or nothing. Returns 0 when something is listening even if
# it could not be named, so a caller can tell "free" from "busy, unknown".
port_holder() {
    local port="$1" listening="" holder=""
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {found=1} END {exit !found}' && listening=1
        holder="$($SUDO ss -ltnpH 2>/dev/null \
            | awk -v p=":$port\$" '$4 ~ p && match($0, /users:\(\("[^"]+"/) {
                       print substr($0, RSTART + 9, RLENGTH - 10); exit }')"
    elif command -v lsof >/dev/null 2>&1; then
        holder="$($SUDO lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | head -1)"
        [ -n "$holder" ] && listening=1
    fi
    [ -n "$holder" ] && printf '%s' "$holder"
    [ -n "$listening" ]
}

# /usr/sbin is not on a normal user's PATH, so `command -v nginx` answers "not
# installed" for the very user who is about to install a second copy of it.
find_nginx() {
    local c
    for c in nginx /usr/sbin/nginx /sbin/nginx /usr/local/sbin/nginx; do
        command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
    done
    return 1
}

# Root, and how much of it this box will give us. Everything the guided install does
# outside this directory -- packages, nginx, a certificate, a unit file, a firewall
# rule -- needs it, and finding that out at the end is finding it out too late.
SUDO=""
CAN_ROOT=1
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo"
elif command -v sudo >/dev/null 2>&1 && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    # sudo WITHOUT -n sits waiting for a password. That is a prompt when somebody is
    # here to answer it and a hang when nobody is, so it is allowed only in the first
    # case -- which is the one --full is for.
    SUDO="sudo"
else
    CAN_ROOT=0
fi

# --- 0. The TLS arguments, checked here and used at the end ----------------
#
# Checked BEFORE the first step rather than beside the step that uses them, because
# the certificate is the LAST thing this script does and everything before it takes
# minutes: a download, fifty repositories, an import pass. `--letsencrypt` with a
# misspelled flag and no --domain should cost a second, not a coffee, and the
# version of this that validated in place told people so four minutes in.

LE_SCRIPT="$ROOT/deploy/issue-letsencrypt.sh"

# --full answers these itself, and anything given on the command line becomes the
# default it offers rather than a contradiction.
if [ "$DO_LETSENCRYPT" -eq 0 ] && [ "$DO_FULL" -eq 0 ]; then
    if [ "${#LE_DOMAINS[@]}" -gt 0 ] || [ -n "$LE_METHOD" ] || [ "$LE_STAGING" -eq 1 ] \
            || [ "${#LE_EXTRA[@]}" -gt 0 ]; then
        die "--domain, --email, --tls-method, --staging and -- are for --letsencrypt,
    and it was not given. Add --letsencrypt (or --full), or drop them." 2
    fi
elif [ "$DO_LETSENCRYPT" -eq 1 ]; then
    [ -x "$LE_SCRIPT" ] || die "--letsencrypt needs deploy/issue-letsencrypt.sh, and it is
    not here (or not executable). This is not a complete checkout." 1
    [ "${#LE_DOMAINS[@]}" -gt 0 ] || die "--letsencrypt needs at least one --domain" 2
fi

if [ "$DO_FULL" -eq 1 ]; then
    for f in deploy/issue-letsencrypt.sh deploy/install-server-tls.sh deploy/install-systemd.sh; do
        [ -x "$ROOT/$f" ] || die "--full needs $f, and it is not here (or not executable).
    This is not a complete checkout." 1
    done
fi

# --- 0b. The guided install, which is all questions and no actions ---------

if [ "$DO_FULL" -eq 1 ]; then
    if [ ! -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
        die "--full asks questions and stdin is not a terminal.
    Run it from a terminal, or add --yes to take every default." 2
    fi

    printf '\n%s  A server on this machine, in about ten questions.%s\n' "$BLD" "$OFF"
    printf '  %sReturn takes the answer in the brackets. Nothing happens until the end.%s\n\n' "$DIM" "$OFF"

    # --- what the server is ---
    FULL_NAME="$(ask       "Server name" "$(cfg_or cfg/server.yml sv_name 'TMC Test Server')")"

    # The games are copied out of the sibling repositories in step 3, so on a first
    # run this directory holds the lobby and nothing else. Offering what is here is
    # therefore a hint rather than the list -- and the answer is checked again after
    # the copy, where the real list exists.
    installed_games=""
    for gy in content/*/game.yml; do
        [ -f "$gy" ] || continue
        gid="${gy#content/}"; gid="${gid%/game.yml}"
        installed_games="$installed_games $gid"
    done
    [ -n "$installed_games" ] && printf '    %sgames here now:%s%s\n' "$DIM" "$OFF" "$installed_games" >&2

    FULL_GAME="$(ask       "Game to boot" "$(cfg_or cfg/server.yml sv_game lobby)")"
    FULL_MAXPLAYERS="$(ask "Player slots" "$(cfg_or cfg/server.yml sv_maxplayers 64)")"
    FULL_TICKRATE="$(ask   "Tickrate" "$(cfg_or cfg/server.yml sv_tickrate 60)")"
    FULL_PORT="$(ask       "Port the server listens on" "$(cfg_or cfg/net.yml net_port 6064)")"

    case "$FULL_MAXPLAYERS" in ''|*[!0-9]*) die "player slots must be a number: $FULL_MAXPLAYERS" 2 ;; esac
    case "$FULL_TICKRATE"   in ''|*[!0-9]*) die "tickrate must be a number: $FULL_TICKRATE" 2 ;; esac
    case "$FULL_PORT"       in ''|*[!0-9]*) die "port must be a number: $FULL_PORT" 2 ;; esac

    # --- nginx, TLS, and why they are one question ---
    #
    # A browser on an HTTPS page may not open a plain ws:// socket, so a web client
    # needs wss://, which needs a certificate, which needs something in front of the
    # server to terminate it. That is one decision, not three, and asking it as three
    # is how somebody ends up with a certificate and nothing using it.
    FULL_NGINX=0
    FULL_PUBLIC_PORT=""
    if [ "$CAN_ROOT" -eq 0 ]; then
        warn "no root on this box, so nginx, a certificate, a service and the firewall
       are all out of reach. Setting the project up only."
    else
        printf '\n'
        if ask_yn "Put nginx in front of it, so browsers can connect over wss://?" y; then
            FULL_NGINX=1
            DO_LETSENCRYPT=1

            guess=""
            if command -v hostname >/dev/null 2>&1; then
                guess="$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
            fi
            case "$guess" in
                ''|localhost|*.local|*.localdomain|*[!a-zA-Z0-9.-]*) guess="" ;;
                *.*) ;;
                *) guess="" ;;
            esac

            if [ "${#LE_DOMAINS[@]}" -eq 0 ]; then
                d="$(ask "Public hostname clients will connect to" "${guess:-demo.example.com}")"
                LE_DOMAINS=("$d")
            fi
            [ -n "$LE_EMAIL" ] || LE_EMAIL="$(ask "Email for the certificate (expiry warnings)" "")"
            [ -n "$LE_METHOD" ] || LE_METHOD="$(ask "Certificate method (webroot, nginx, standalone, dns, manual)" webroot)"

            # 443 unless something that is not nginx already has it. It is the port
            # that survives a corporate firewall, and a game on a high port is the one
            # thing a player on an office network cannot reach.
            #
            # nginx ALREADY being on 443 is not a reason to avoid it: a second server
            # block on the same port with a different name is exactly what SNI is
            # for, and a box that already serves a website over HTTPS is the common
            # case rather than the awkward one. Anything else holding it is a
            # different matter, because nginx cannot have it at all.
            # The three cases have to be the same three the check below uses. An
            # earlier version asked only whether a NAME came back, so a port that was
            # busy but unnameable -- which is every port when this run cannot see the
            # process column -- looked free, 443 was offered as the default, and the
            # check two lines down then refused the answer the script had just
            # suggested. A default that its own validator rejects is worse than no
            # default at all.
            pp_default=6065
            pp_holder="$(port_holder 443)"
            if [ $? -ne 0 ] || [ "$pp_holder" = "nginx" ]; then
                pp_default=443
            fi
            FULL_PUBLIC_PORT="$(ask "Public TLS port" "$pp_default")"
            case "$FULL_PUBLIC_PORT" in ''|*[!0-9]*) die "public port must be a number: $FULL_PUBLIC_PORT" 2 ;; esac
            [ "$FULL_PUBLIC_PORT" = "$FULL_PORT" ] && die "the public TLS port and the server's own port cannot both be $FULL_PORT.
    nginx listens on the first and forwards to the second." 2

            # [b]This box may already be doing something, and this is where that stops
            # being a surprise.[/b] A vhost written for a port another PROCESS holds
            # does not fail when it is written -- it fails the next time nginx is
            # restarted, which can be weeks later and by somebody else entirely. nginx
            # holding it is fine and normal: a second server block on the same port
            # with a different name is what SNI is for.
            # And the one way sharing a port goes wrong: the same NAME twice. Two
            # server blocks with one server_name on one port is a "conflicting server
            # name" warning from nginx, after which the first one wins and the new one
            # is silently never used -- a vhost that was installed, tested, reloaded
            # and does nothing.
            if nginx_bin="$(find_nginx)" \
                    && $SUDO "$nginx_bin" -T 2>/dev/null \
                       | grep -qE "^[[:space:]]*server_name[^;]*[[:space:]]${LE_DOMAINS[0]}([[:space:];]|$)"; then
                warn "nginx already has a server block naming ${LE_DOMAINS[0]}.
       If it is on the same port, nginx keeps the first and ignores the new one.
       A name of its own for the game -- play.yourdomain, say -- avoids the whole
       question."
            fi

            FULL_PORT_SHARED=""
            if holder="$(port_holder "$FULL_PUBLIC_PORT")"; then
                case "${holder:-unknown}" in
                    nginx) FULL_PORT_SHARED=1 ;;
                    unknown) die "something is already listening on $FULL_PUBLIC_PORT and this run
    cannot see what. Re-run with sudo, or pick another port." 1 ;;
                    *) die "$holder is already listening on $FULL_PUBLIC_PORT.
    nginx cannot have that port as well, and a vhost written for it would break the
    next nginx restart rather than this run. Pick another public port." 1 ;;
                esac
            fi
        fi

        # --- the service ---
        printf '\n'
        FULL_SYSTEMD=0
        if command -v systemctl >/dev/null 2>&1; then
            if ask_yn "Install a systemd service, so it starts on boot?" y; then
                FULL_SYSTEMD=1
                FULL_UNIT="$(ask "Unit name" "dot-server")"
                FULL_RUN_USER="$(ask "Run the server as" "$(stat -c '%U' "$ROOT" 2>/dev/null || echo root)")"
                id "$FULL_RUN_USER" >/dev/null 2>&1 || die "no such user: $FULL_RUN_USER" 2
            fi
        fi

        # --- the firewall ---
        #
        # Only offered when this box HAS one that is switched on. Asking about ufw on
        # a machine with no ufw is a question whose every answer is wrong, and
        # opening ports in a firewall nobody enabled is a change with no effect that
        # still shows up in somebody's audit.
        FULL_FIREWALL=""
        if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi '^Status: active'; then
            FULL_FIREWALL=ufw
        elif command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state 2>/dev/null | grep -q running; then
            FULL_FIREWALL=firewalld
        fi
        if [ -n "$FULL_FIREWALL" ]; then
            printf '\n'
            ask_yn "Open the ports in $FULL_FIREWALL?" y || FULL_FIREWALL=""
        fi
    fi

    # --- the plan ---
    #
    # Printed in full and confirmed once. This is the last moment at which nothing
    # has happened, and it is the only screen in the install that matters.
    plan "set up the project: runtime, addons, games, cfg/, ./server"
    plan "cfg/server.yml: $FULL_NAME, game $FULL_GAME, $FULL_MAXPLAYERS slots, $FULL_TICKRATE tick"
    if [ "$FULL_NGINX" -eq 1 ]; then
        plan "cfg/net.yml: port $FULL_PORT, bound to 127.0.0.1 (nginx is the way in)"
        if find_nginx >/dev/null 2>&1; then
            plan "use the nginx that is already on this box, adding one server block to it"
        else
            plan "install nginx"
        fi
        command -v certbot >/dev/null 2>&1 || plan "install certbot"
        [ -n "$FULL_FIREWALL" ] && plan "open 80 and $FULL_PUBLIC_PORT in $FULL_FIREWALL"
        # `${LE_STAGING:+...}` is wrong here and read right for a whole test run:
        # LE_STAGING is 0 or 1, and :+ fires on a value being SET rather than being
        # true -- so "0" took the branch and the plan promised a staging certificate
        # for every install.
        staging_note=""
        [ "$LE_STAGING" -eq 1 ] && staging_note=" (staging)"
        plan "get a certificate for ${LE_DOMAINS[*]} over ${LE_METHOD:-webroot}$staging_note"
        if [ -n "$FULL_PORT_SHARED" ]; then
            plan "nginx: wss://${LE_DOMAINS[0]}:$FULL_PUBLIC_PORT -> 127.0.0.1:$FULL_PORT (nginx is already on that port; this adds a name to it)"
        else
            plan "nginx: wss://${LE_DOMAINS[0]}:$FULL_PUBLIC_PORT -> 127.0.0.1:$FULL_PORT"
        fi
    else
        plan "cfg/net.yml: port $FULL_PORT, bound to 0.0.0.0"
        [ -n "$FULL_FIREWALL" ] && plan "open $FULL_PORT in $FULL_FIREWALL"
    fi
    [ "${FULL_SYSTEMD:-0}" -eq 1 ] && plan "install and start the ${FULL_UNIT}.service unit, running as $FULL_RUN_USER"

    printf '\n%s  This is the whole of it:%s\n\n' "$BLD" "$OFF"
    for line in "${PLAN[@]}"; do printf '    %s-%s %s\n' "$GRN" "$OFF" "$line"; done
    printf '\n'
    if ! ask_yn "Go ahead?" y; then
        printf '\n  nothing was done.\n\n'
        exit 0
    fi
fi

# --- 1. The runtime --------------------------------------------------------

step "Godot runtime"

# The pinned version lives in tools/fetch-godot.sh, with the digest that proves it.
PINNED="$(tools/fetch-godot.sh --version 2>/dev/null)"
PINNED_CACHE="${TMC_GODOT_CACHE:-${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}/tmc/godot}/${PINNED:-none}/godot"

# Is this thing a runtime new enough to build with? Prints the version when it is,
# nothing when it is not -- so a caller can test one candidate without dying on it.
godot_version_ok() {
    local v
    v="$("$1" --version 2>/dev/null | head -1)"
    case "$v" in
        4.[7-9]*|4.[1-9][0-9]*|5.*) printf '%s' "$v" ;;
        *) return 1 ;;
    esac
}

# An explicit --godot is not a suggestion. A wrong one that silently became a
# download would be a script quietly ignoring the argument it was given, and the
# operator would never learn that the runtime they meant to test was not the one
# that ran.
if [ -n "$GODOT_ARG" ]; then
    if command -v "$GODOT_ARG" >/dev/null 2>&1; then GODOT="$(command -v "$GODOT_ARG")"
    elif [ -x "$GODOT_ARG" ]; then GODOT="$GODOT_ARG"
    else die "no runtime at $GODOT_ARG" 3
    fi
    VERSION="$(godot_version_ok "$GODOT")" \
        || die "Godot 4.7 or newer is required; $GODOT is $("$GODOT" --version 2>&1 | head -1)" 3
    ok "$GODOT ($VERSION)"
else
    # The cache first, then PATH. The downloaded one is checked BEFORE `godot` on
    # PATH because it is the version this project is pinned to and the one on PATH
    # is whatever the box happens to have -- and if the box's is fine, it was found
    # on the first run and no download ever happened.
    GODOT=""
    VERSION=""
    for candidate in "$PINNED_CACHE" "$ROOT/.godot-runtime/${PINNED:-none}/godot" godot godot4 Godot; do
        [ -n "$candidate" ] || continue
        resolved=""
        if command -v "$candidate" >/dev/null 2>&1; then resolved="$(command -v "$candidate")"
        elif [ -x "$candidate" ]; then resolved="$candidate"
        fi
        [ -n "$resolved" ] || continue
        if VERSION="$(godot_version_ok "$resolved")"; then GODOT="$resolved"; break; fi
        # Found and too old. Remembered rather than reported now: it only matters if
        # nothing better turns up, and "4.4 is too old" above "downloaded 4.7.2" is
        # an error message about a thing that did not go wrong.
        TOO_OLD="$resolved ($("$resolved" --version 2>&1 | head -1))"
    done

    if [ -n "$GODOT" ]; then
        ok "$GODOT ($VERSION)"
    elif [ "$DO_DOWNLOAD" -eq 0 ]; then
        die "No Godot 4.7+ runtime found${TOO_OLD:+ ($TOO_OLD is too old)}, and downloading is off (--no-download / TMC_NO_DOWNLOAD).

    Install Godot 4.7 or newer and put it on PATH, or:
        ./setup.sh --godot /path/to/godot" 3
    else
        # [b]This used to be where setup.sh gave up[/b], on the grounds that fetching a
        # binary means verifying it and that is a different program with different
        # risks. The reasoning was right and the conclusion was backwards: it made
        # every fresh box a manual download before anything could be tried, and the
        # verification it was avoiding is thirty lines. tools/fetch-godot.sh IS that
        # different program -- one pinned version, digests checked into git rather
        # than fetched beside the binary, and no path through it that installs
        # something unverified.
        [ -n "${TOO_OLD:-}" ] && warn "$TOO_OLD is too old"
        [ -x tools/fetch-godot.sh ] || die "tools/fetch-godot.sh is missing or not executable" 3

        warn "no Godot 4.7 or newer on this machine; fetching the pinned ${PINNED:-runtime}"
        GODOT="$(tools/fetch-godot.sh)" || exit 3
        VERSION="$(godot_version_ok "$GODOT")" || die "the fetched runtime does not report a usable version" 3
        ok "$GODOT ($VERSION)"
    fi
fi

# --- Cloning the siblings --------------------------------------------------
#
# [b]Every dot-* project is its own repository and there is no way to clone the tree at
# once.[/b] That is a deliberate shape -- an addon is installable on its own -- and it
# means a fresh machine that has cloned only THIS repository is fifty clones away from a
# build. The message that used to end the run listed all fifty names and offered no way
# to act on it.
#
# [b]This invents no list.[/b] The repository name is the addon name with underscores
# turned into hyphens, which this script already relies on to find them, and the games
# are already named by repository. A second list is this tree's most repeated bug; there
# is not one here.
#
# HTTPS, not SSH. `dot-bootstrap` defaults to `git@github.com:` because it runs on a
# developer's machine with a key loaded; the machine this flag is for is a fresh server
# where that is the one thing not configured. These repositories are public, so HTTPS
# needs no credential at all.
GIT_BASE="${TMC_GIT_BASE:-https://github.com/modcommunity}"

## Fast-forward every named repository that is already beside this one.
##
## [b]Each addon is its own clone, and `git pull` here pulls only this one.[/b] That is
## the shape of the family -- fifty-odd repositories, installable separately -- and on a
## server it is a trap: an operator pulls the deploy repo, re-runs setup, and is still
## running last week's dot-cloud, because nothing told them the fix was in a sibling.
## The symptom is a bug that is fixed upstream, fixed in the tree they pulled, and still
## happening, with a stack trace whose line numbers no longer match any file they can
## see. It cost a real afternoon.
##
## `--ff-only`, never a merge: this is a deploy box, and a setup script that can produce
## a conflicted working tree is a setup script that can take a server down. A repository
## with local changes or a diverged branch is reported and skipped, because on the one
## machine where somebody HAS edited an addon in place, quietly discarding it would be
## the worse failure.
update_repos() {
    command -v git >/dev/null 2>&1 || die "--update needs git, and this machine has none." 4

    local repo dir behind=() failed=()

    for repo in "$@"; do
        dir="$ROOT/../$repo"

        [ -d "$dir/.git" ] || continue

        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
            printf '    %s..%s   %s (local changes; left alone)\n' "$YLW" "$OFF" "$repo"
            continue
        fi

        # [b]Most of these repositories have no upstream configured.[/b] `git pull`
        # with no tracking branch fails with "no upstream configured for branch
        # 'main'", which is not a failure to update -- it is a clone that was never
        # told where it came from, which is most of them here. So the remote and
        # branch are named explicitly, exactly as `push-github.sh` names the current
        # branch rather than assuming main.
        local branch
        branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"

        if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
            failed+=("$repo")
            continue
        fi

        if git -C "$dir" pull --ff-only --quiet origin "$branch" 2>/dev/null; then
            behind+=("$repo")
        else
            failed+=("$repo")
        fi
    done

    ok "${#behind[@]} up to date"

    if [ ${#failed[@]} -gt 0 ]; then
        warn "could not fast-forward: ${failed[*]}"
        warn "a diverged branch or no upstream; pull those by hand"
    fi
}


## Clone every named repository that is not already beside this one.
##
## Never touches a checkout that exists -- not even to pull. A setup script that
## silently updated somebody's working tree would be a setup script that can lose work.
clone_repos() {
    command -v git >/dev/null 2>&1 || die "--clone needs git, and this machine has none." 4

    local wanted=("$@") missing=() repo failed=()

    for repo in "${wanted[@]}"; do
        [ -d "$ROOT/../$repo" ] || missing+=("$repo")
    done

    [ ${#missing[@]} -gt 0 ] || return 0

    printf '    %scloning %d repositories into %s%s\n' \
        "$DIM" "${#missing[@]}" "$(cd "$ROOT/.." && pwd)" "$OFF"

    # [b]Shallow by default.[/b] This path exists to stand a SERVER up: fifty repositories
    # of history is bandwidth and disk nobody on that box will ever read, and it is most
    # of what the clone costs. `dot-bootstrap` is the developer tool and clones in full.
    # TMC_GIT_DEPTH=0 turns this off; `git fetch --unshallow` fixes one after the fact.
    local depth=()
    [ "${TMC_GIT_DEPTH:-1}" = "0" ] || depth=(--depth "${TMC_GIT_DEPTH:-1}")

    for repo in "${missing[@]}"; do
        if git clone --quiet "${depth[@]}" "$GIT_BASE/$repo.git" "$ROOT/../$repo" 2>/dev/null; then
            printf '    %s+%s    %s\n' "$GRN" "$OFF" "$repo"
        else
            # Collected rather than fatal. One repository that is not published yet --
            # which happens, because this list is edited when an addon is written and
            # pushed some time after -- should not stop the other forty-nine.
            failed+=("$repo")
            printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$repo"
        fi
    done

    if [ ${#failed[@]} -gt 0 ]; then
        warn "could not clone: ${failed[*]}"
        warn "check the names, or that they are published, then re-run"
    fi
}

# --- 2. The addons ---------------------------------------------------------
#
# name:repository. The repository is the name with underscores turned into hyphens,
# which holds for every one of them and is asserted rather than assumed below.

# dot_stats is here because hungry's module declares its statistics through
# DotStatsSchema. It was missing, and could not be noticed: the vendored copy of
# hungry predated that code by nine days, and the guard against a stale copy --
# tools/check.sh -- named the game repositories by their OLD names too, so it reported
# "no game repositories beside this one" on a machine where all of them were and
# compared nothing. The first `setup.sh` that copied the current hungry turned every
# type reference in its module into a parse error, and a module that will not parse is
# a module that does not load: `changelevel hungry_classic` swapped the world and left
# the lobby's module driving it.
# Every addon any vendored game names. A game that gains a dependency and is not added
# here vendors, imports, and then fails to compile every script that names the missing
# class — dozens of "not declared in the current scope" errors in files nobody touched,
# which reads as a broken project rather than as one missing folder.
ADDONS=(dot_core dot_net dot_server dot_server_query dot_server_security dot_2d dot_ui dot_auth dot_cloud dot_user
        dot_user_avatar dot_platform dot_loadout dot_match
        dot_player_controller dot_timer dot_map dot_leaderboard dot_stats
        dot_props dot_vote dot_combat dot_chat dot_voice dot_moderation
        dot_browser dot_npc dot_npc_ai dot_npc_ai_director dot_vehicle
        dot_achievements dot_objective dot_effects dot_spectate dot_economy
        dot_settings dot_console dot_audio dot_fx dot_lighting
        dot_procedural_generation dot_inventory dot_peer_to_peer dot_weapon
        dot_physics dot_spawn dot_team dot_player dot_player_class
        dot_player_char)

step "dot-* addons"
mkdir -p addons

## Link, copy or record-as-missing every addon. Run twice: once to find out what is
## absent, and once more after cloning it, so the clone is driven by what is ACTUALLY
## needed rather than by the list in the abstract.
##
## A vendored addon is not missing and is never cloned -- that is the release tarball,
## which has no siblings, no network and nothing wrong with it.
resolve_addons() {
    MISSING=()
    for name in "${ADDONS[@]}"; do
        repo="${name//_/-}"
        source_dir="$ROOT/../$repo/addons/$name"

        if [ -d "$source_dir" ]; then
            if [ "$VENDOR" -eq 1 ]; then
                # Copied, not linked. A symlink out of this directory is fine on a
                # developer's machine and breaks the moment the directory is moved
                # somewhere the siblings are not -- a release tarball, or a container
                # image whose final stage copies only this project. The symptom is
                # every dot-* class_name unresolved at once, which reads as a broken
                # project rather than as a dangling link.
                rm -rf "addons/$name"
                cp -rL "$source_dir" "addons/$name"
            elif [ -L "addons/$name" ] || [ ! -e "addons/$name" ]; then
                ln -sfn "../../$repo/addons/$name" "addons/$name"
            fi
        elif [ -d "addons/$name" ]; then
            : # already vendored, which is what a release tarball looks like
        else
            MISSING+=("$repo")
        fi
    done
}

if [ "$DO_UPDATE" -eq 1 ]; then
    UPDATE_REPOS=()
    for name in "${ADDONS[@]}"; do UPDATE_REPOS+=("${name//_/-}"); done
    update_repos "${UPDATE_REPOS[@]}"
fi

resolve_addons

if [ ${#MISSING[@]} -gt 0 ] && [ "$DO_CLONE" -eq 1 ]; then
    clone_repos "${MISSING[@]}"
    resolve_addons
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    die "These addon repositories are not beside this one:

        ${MISSING[*]}

    Each dot-* project is a separate repository and there is no way to clone the
    tree at once.

    They are normally cloned for you from $GIT_BASE over HTTPS; this run could not,
    or --no-clone was given.

    Or vendor their addons/<name> folders into ./addons/, which is what a release
    tarball looks like; or use dot-bootstrap, which clones the whole family and is
    the right tool on a development machine." 4
fi
ok "${#ADDONS[@]} addons $([ "$VENDOR" -eq 1 ] && echo copied || echo linked)"

# --- 3. The games ----------------------------------------------------------
#
# Every game that ships INSIDE this build is copied in here, and they all land in
# one game/ directory on purpose.
#
# A game's scenes name their scripts by absolute res:// path -- that is how a .tscn
# stores a script reference and there is no relative form -- so game-simple-lobby's
# res://game/room_world.gd and game-hungario's res://game/modes/hungry_mode.gd only
# resolve if each project's game/ becomes THIS project's game/. Moving either into a
# subdirectory of its own would mean re-authoring every scene it owns.
#
# That works because no two of them share a filename: every file is prefixed with
# its own game's name, which is the family's class_name rule paying off somewhere it
# was not aimed at. The check below asserts it rather than trusting it, because the
# failure -- one game silently overwriting a file of another's -- is invisible until
# something loads.
#
# WHY BUILT IN AND NOT DELIVERED: a mounted dot-cloud pack's class_name globals are
# not registered in the host, so every cross-file type reference inside a pack fails
# to compile -- the pack mounts, its scenes load, and every script in it is dead.
# See content/lobby/game.yml.

step "games"

# repository:label[:extra directories]
#
# The repository name is the DIRECTORY beside this one, and it is not the game's
# name: `dot-a-room` and `dot-2d-hungry` were renamed to `game-simple-lobby` and
# `game-hungario` and this list was not, so every run skipped both games -- after
# the `rm -rf` below had already deleted the vendored copies. See the ordering note
# there. A stale name here is now a hard failure rather than a warning, for the same
# reason: "skipping the lobby" scrolls past and a build with no games does not.
#
# The extra field is the top-level directories a game owns beyond game/ and scenes/.
# Same reason those two are flattened into this project: a .tscn stores its script
# reference as an absolute res:// path and there is no relative form, so
# game-g2gfast's res://maps/surf_g2g_intro.gd only resolves if its maps/ becomes
# THIS project's maps/.
#
# [b]A game that grows a top-level directory has to be added here, and nothing
# reports it if it is not.[/b] game-arena and game-g2gfast both gained npcs/ and
# props/ when the NPC and prop layers landed; a build vendored without them mounts,
# loads every scene, and refuses every spawn with "that NPC's content is not loaded on
# this server" -- which is dot-npc answering correctly a question nobody meant to ask.
# The refusal is a legitimate answer, so nothing errors.
#
# Filenames are prefixed per game (`arena_grunt.tscn`, `g2g_stalker.tscn`) so the two
# can share one flattened directory, which is the collision check below.
#
# g2gfast's `textures/` is the newest of these and is the same shape of omission:
# `G2GTextures` looks its prototype set up at the fixed path `res://textures/prototype`
# and falls back to a generated grid when it is not there, so a build without it draws
# every map -- imported ones included, which is most of what that server runs -- in a
# different texture set from the one the developer looked at, and reports nothing.
GAMES=(
    "game-simple-lobby:the lobby"
    "game-hungario:hungry"
    "game-g2gfast:g2gfast:maps avatars npcs props textures"
    "game-playground:playground:maps"
    "game-arena:arena:maps avatars npcs props"
)

# --- Resolve before destroying ---------------------------------------------
#
# [b]The wipe below used to come first, and that made a stale repository name
# destructive.[/b] Both entries had been renamed, so setup.sh deleted game/ and
# scenes/, warned twice, and died with "No games were found beside this repository,
# and none are vendored" -- having just made that true. A vendored tarball, which is
# exactly the case the message is about, lost its games to the run that reported
# them missing.
#
# So: find every source first, refuse the whole run if one is missing, and only then
# remove anything.

resolve_games() {
    GAME_DIRS=()
    MISSING_GAMES=()
    for entry in "${GAMES[@]}"; do
        repo="${entry%%:*}"
        rest="${entry#*:}"
        extra=""
        [ "$rest" != "${rest%%:*}" ] && extra="${rest#*:}"

        if [ -d "$ROOT/../$repo/game" ]; then
            GAME_DIRS+=("$extra")
        else
            MISSING_GAMES+=("$repo")
        fi
    done
}

if [ "$DO_UPDATE" -eq 1 ]; then
    UPDATE_GAMES=()
    for entry in "${GAMES[@]}"; do UPDATE_GAMES+=("${entry%%:*}"); done
    update_repos "${UPDATE_GAMES[@]}"
fi

resolve_games

# [b]Only when SOME are missing.[/b] All of them missing with a vendored game/ already
# here is the release tarball, and the branch below keeps what it has -- cloning five
# game repositories onto a box that already has the games would be pure download.
if [ ${#MISSING_GAMES[@]} -gt 0 ] && [ "$DO_CLONE" -eq 1 ] \
        && ! { [ ${#MISSING_GAMES[@]} -eq ${#GAMES[@]} ] && [ -n "$(ls -A "$ROOT/game" 2>/dev/null)" ]; }; then
    clone_repos "${MISSING_GAMES[@]}"
    resolve_games
fi

# Three cases, and only three. Every game beside this one is a developer's machine
# and the copy runs; none of them beside it, with a game/ already here, is a release
# tarball and the copy is skipped whole. Anything in between -- which is what a
# rename produces -- is refused, because copying the games that are still there over
# a vendored set of the ones that are not gives one build made of two vintages.
if [ ${#MISSING_GAMES[@]} -eq 0 ]; then
    # Only the directories this list declares, so a typo cannot remove anything the
    # script did not put there.
    rm -rf game scenes
    for extra in "${GAME_DIRS[@]}"; do
        for dir in $extra; do rm -rf "${ROOT:?}/$dir"; done
    done
    mkdir -p game scenes
elif [ ${#MISSING_GAMES[@]} -eq ${#GAMES[@]} ] && [ -n "$(ls -A "$ROOT/game" 2>/dev/null)" ]; then
    ok "no game repositories beside this one; keeping the vendored games"
    VENDORED_GAMES=1
else
    die "These game repositories are not beside this one:

        ${MISSING_GAMES[*]}

    Each game is a separate repository and there is no way to clone the tree at
    once. They are normally cloned for you; this run could not, or --no-clone was
    given. Or vendor their game/ folders.

    If one was RENAMED, fix the GAMES list in this script. A name here that no
    longer exists is how this step silently stopped copying a game -- and it used
    to delete game/ before finding out, so the run that reported the games missing
    was the run that made them missing." 4
fi

copied_any=0
[ "${VENDORED_GAMES:-0}" -eq 1 ] && copied_any=1
for entry in "${GAMES[@]}"; do
    [ "${VENDORED_GAMES:-0}" -eq 1 ] && break

    repo="${entry%%:*}"
    rest="${entry#*:}"
    label="${rest%%:*}"
    extra=""
    [ "$rest" != "$label" ] && extra="${rest#*:}"
    src="$ROOT/../$repo"

    # Refuse a collision rather than let cp resolve it. Two games contributing the
    # same filename means one of them silently loses a script, and the symptom is a
    # parse error in a file nobody edited.
    for sub in game $extra; do
        [ -d "$src/$sub" ] || continue
        while read -r f; do
            rel="${f#"$src"/}"
            if [ -e "$ROOT/$rel" ]; then
                # Byte-identical is not a collision. Two games legitimately ship the
                # same third-party asset -- both arena and g2gfast use Kenney's
                # character GLBs, copied from one source -- and vendoring them into
                # the shared tree would otherwise be refused, or force a per-game copy
                # of every byte. The rule this guards is "one of them silently loses a
                # script", and a file that is the same file loses nothing.
                if cmp -s "$f" "$ROOT/$rel"; then
                    continue
                fi
                # Godot regenerates these for THIS project on the --import below, and
                # mints a fresh uid per project while doing it -- so two games' copies
                # of the same asset always differ here and never mean anything. The
                # asset itself is compared above; this is its bookkeeping.
                case "$rel" in
                    *.import|*.uid) continue ;;
                esac
                die "$repo and an earlier game both provide $rel, with different contents.

    Every built-in game shares one game/ directory, because a .tscn names its
    scripts by absolute res:// path. Rename one of them." 4
            fi
        done < <(find "$src/$sub" -type f)
    done

    # -a preserves timestamps. Without it every setup.sh gives identical files a fresh
    # mtime, so anything that asks "is the build older than the source" -- demo.sh does,
    # to catch a stale web export -- rebuilds on every run for no reason.
    cp -a "$src/game/." game/
    [ -d "$src/scenes" ] && cp -a "$src"/scenes/*.tscn scenes/ 2>/dev/null

    for dir in $extra; do
        [ -d "$src/$dir" ] || continue
        mkdir -p "$ROOT/$dir"
        cp -a "$src/$dir/." "$ROOT/$dir/"
    done

    # Cosmetic parts a game looks for in its own build. HungryContentSource reads
    # res://content/avatars/, and content/ here is the operator's game directory --
    # so this lands beside the games and TmcContent knows it is not one.
    if [ -d "$src/content/avatars" ]; then
        mkdir -p content/avatars
        cp -a "$src/content/avatars/." content/avatars/
    fi

    ok "$label"
    copied_any=1
done

# The .uid files are Godot's own and are regenerated by --import. Copying one from a
# source project pins this build's script to that project's uid, and two games whose
# uids were generated separately can then collide.
UID_DIRS=(game scenes content/avatars)
for extra in "${GAME_DIRS[@]}"; do
    for dir in $extra; do UID_DIRS+=("$dir"); done
done
# [b]Except the ones this repository owns.[/b] The rule above is about files COPIED
# from a sibling: their uid belongs to that project and must be reminted here. But
# `content/avatars/part.gd` is ours, tracked in git, and sitting in a directory that
# also receives vendored content -- so deleting its uid meant `--import` generated a
# new random one and rewrote a tracked file on EVERY setup run. A dirty working tree
# after a command whose whole job is to be re-runnable, and a uid that changes under
# any scene referencing it by uid rather than by path.
#
# Ask git which files are its own. Without git -- a release tarball, the container's
# final stage -- there are no tracked files to protect and the old behaviour is right.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r uid; do
        git -C "$ROOT" ls-files --error-unmatch "$uid" >/dev/null 2>&1 && continue
        rm -f "$uid"
    done < <(find "${UID_DIRS[@]}" -name '*.uid' 2>/dev/null)
else
    find "${UID_DIRS[@]}" -name '*.uid' -delete 2>/dev/null
fi

if [ "$copied_any" -eq 0 ]; then
    die "No games were found beside this repository, and none are vendored." 4
fi

# --- 4. Import -------------------------------------------------------------

if [ "$DO_IMPORT" -eq 1 ]; then
    step "importing"
    # Re-run after ANY script with a new class_name is added. Without it the
    # identifier does not resolve, the scene fails to load, and the process HANGS
    # rather than exiting, because nothing ever reaches get_tree().quit().
    "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1
    ok "class_name globals registered"
fi

# --- 5. Configuration ------------------------------------------------------
#
# [b]cfg/ is not in the repository, and that is the whole design of this step.[/b]
#
# It used to be: the seven files were committed, and setup.sh carried a second copy
# of each one in a heredoc for a tarball that had no checkout. So a running server's
# configuration was a tracked file an operator edits in place, and `git pull` on the
# box stopped with "your local changes would be overwritten by merge" -- on the one
# file that is nobody's but that deployment's. The two copies had drifted apart by
# then as well: the committed groups.yml carried the real dot-server flag names and
# the heredoc still had the three that were silently not flags, vote.yml existed only
# in the checkout so a tarball got none of it, and the committed rcon.yml had a live
# generated password in it, public, because a first run wrote one where git was
# watching.
#
# One copy now, in cfg.example/, which is a template directory and is never read by a
# running server. This copies what is missing and touches nothing that exists.

step "configuration"
mkdir -p cfg cfg/content content/global data

[ -d cfg.example ] || die "cfg.example/ is missing; this is not a complete checkout" 1

if [ -f cfg/server.yml ]; then
    NEW_CONFIG=0
else
    NEW_CONFIG=1
fi

# Written before anything goes into it, so the password is never briefly readable.
umask_old="$(umask)"
umask 077

# `cat >` rather than `cp`, deliberately: cp copies the template's own mode bits and
# would publish a 644 rcon.yml. A redirect creates through the umask above.
while IFS= read -r template; do
    rel="${template#cfg.example/}"
    target="cfg/$rel"
    [ -f "$target" ] && continue
    mkdir -p "$(dirname "$target")"

    if [ "$rel" = "rcon.yml" ]; then
        RCON_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
        # The password is substituted into a file that is never tracked. The template
        # holds a placeholder, so a checkout has nothing to leak and a half-finished
        # run leaves no password anybody else also has.
        sed "s|@RCON_PASSWORD@|$RCON_PASSWORD|" "$template" > "$target"
        NEW_RCON=1
    else
        cat "$template" > "$target"
    fi

    printf '    %s+%s    %s\n' "$GRN" "$OFF" "$target"
done < <(find cfg.example -type f \( -name '*.yml' -o -name '*.md' \) | sort)

# [b]The server's own content trust, derived from the client's.[/b]
#
# `DotCloudClient` reads `cfg/content.json` and refuses every unsigned manifest --
# correctly, since a pack can contain scripts. With no such file it starts with
# `require_signed_manifests: true` and NO keys, so every fetch fails with "no
# trusted_keys are configured" and a server that was told where to download its maps
# still cannot download one.
#
# It is generated rather than templated because it is not a setting: the client's half
# (`client/content.json`) is committed and carries the public key, and this writes the
# same trust where the server reads it, so the two halves cannot disagree about what
# they will mount.
if [ ! -f cfg/content.json ] && [ -f client/content.json ] && command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,io
src = json.load(io.open("client/content.json", encoding="utf-8"))
io.open("cfg/content.json", "w", encoding="utf-8").write(json.dumps({
    "require_signed_manifests": src.get("require_signed_manifests", True),
    "trusted_keys": src.get("trusted_keys", {}),
}, indent=4) + "\n")' && printf '    %s+%s    %s\n' "$GRN" "$OFF" "cfg/content.json"
fi

umask "$umask_old"

# [b]What an upgrade added, named rather than skipped.[/b]
#
# Never overwriting a file that exists is the rule, and the cost of that rule is that
# a release which ADDS a setting is invisible: the template grows `content_urls`, the
# box keeps the file it has, and the server looks like it is ignoring documentation
# that describes a key nobody's config contains. So say so. A key that is present but
# COMMENTED OUT counts as answered -- an operator who deleted a setting on purpose is
# not asking to be reminded of it every run.
for template in cfg.example/*.yml; do
    target="cfg/$(basename "$template")"
    [ -f "$target" ] || continue
    added=""
    while IFS= read -r key; do
        grep -qE "^[[:space:]]*#?[[:space:]]*${key}:" "$target" || added="$added $key"
    done < <(grep -oE '^[a-z_][a-z0-9_]*:' "$template" | tr -d ':')
    [ -n "$added" ] && printf '    %s~%s    %s has no%s (see %s)\n' \
        "$YLW" "$OFF" "$target" "$added" "$template"
done

if [ "$NEW_CONFIG" -eq 1 ]; then
    ok "cfg/ written from cfg.example/"
else
    ok "cfg/ already exists and was not touched"
fi

# --- 6. export_presets.cfg -------------------------------------------------
#
# [b]An export preset nobody has is a build command that cannot run.[/b] Godot's editor
# writes and rewrites `export_presets.cfg`, so it is gitignored for the same reason
# `cfg/` is -- and the consequence was that `./server export-web` on a machine that had
# never opened this project in an editor failed on a preset named "Web" that existed
# only on the machine where somebody had made one by hand. `export-native` would have
# inherited the same hole, three times over.
#
# Copied, never overwritten, exactly like cfg/: a preset file is something an operator
# may have adjusted -- a different icon, an encryption key, an extra platform -- and an
# upgrade that regenerated it would throw that away on the one run nobody is watching.
#
# It lands at the project ROOT and not in cfg/ with the other templates, because Godot
# reads it from exactly one place: "This project doesn't have an `export_presets.cfg`
# file at its root." The two files therefore sit side by side and differ only in the
# word `.example`.

step "export presets"

if [ -f export_presets.cfg ]; then
    ok "export_presets.cfg already exists and was not touched"
elif [ -f export_presets.example.cfg ]; then
    cp export_presets.example.cfg export_presets.cfg
    ok "export_presets.cfg written from export_presets.example.cfg"
else
    warn "export_presets.example.cfg is missing; ./server export-web and export-native will have no presets"
fi

# --- 7. ./server -----------------------------------------------------------

step "./server"

[ -f tools/server.in ] || die "tools/server.in is missing" 1
sed "s|@GODOT@|$GODOT|g" tools/server.in > server
chmod +x server
ok "written, using $GODOT"

# --- 8. What the answers said -----------------------------------------------
#
# Applied here rather than in step 5, and the difference matters: step 5 writes
# cfg/ from cfg.example/ ONLY for files that do not exist, because a config file is
# what one deployment decided and regenerating it on upgrade throws that away. So
# this runs after it, sets the handful of keys somebody was asked about, and leaves
# every other line -- including the comments, which are half of what those files are
# for -- exactly where it found it.

if [ "$DO_FULL" -eq 1 ]; then
    step "what you answered"

    cfg_changed=0
    set_and_say() {
        local file="$1" key="$2" value="$3" shown="$4" current
        current="$(cfg_get "$file" "$key" 2>/dev/null)"
        [ "$current" = "$shown" ] && return 0
        if cfg_set "$file" "$key" "$value"; then
            printf '    %s~%s    %s %s -> %s\n' "$GRN" "$OFF" "$key" "${current:-unset}" "$shown"
            cfg_changed=1
        else
            warn "could not set $key in $file"
        fi
    }

    set_and_say cfg/server.yml sv_name       "\"$FULL_NAME\""    "$FULL_NAME"
    set_and_say cfg/server.yml sv_game       "\"$FULL_GAME\""    "$FULL_GAME"
    set_and_say cfg/server.yml sv_maxplayers "$FULL_MAXPLAYERS"  "$FULL_MAXPLAYERS"
    set_and_say cfg/server.yml sv_tickrate   "$FULL_TICKRATE"    "$FULL_TICKRATE"
    set_and_say cfg/net.yml    net_port      "$FULL_PORT"        "$FULL_PORT"

    # Loopback when nginx is in front, and this is the line that makes the proxy a
    # boundary instead of a decoration. Left on 0.0.0.0, the game port stays open to
    # the internet beside the TLS one, and every client that finds it connects in
    # plaintext past everything nginx is there to do.
    if [ "$FULL_NGINX" -eq 1 ]; then
        set_and_say cfg/net.yml net_bind_ip "\"127.0.0.1\"" "127.0.0.1"
        set_and_say cfg/net.yml net_public_ip "\"${LE_DOMAINS[0]}\"" "${LE_DOMAINS[0]}"
    fi

    [ "$cfg_changed" -eq 0 ] && ok "cfg/ already said all of that"

    # The game list is real now -- step 3 copied them -- so the answer given before
    # any of that existed can finally be checked. A server whose sv_game names
    # nothing boots into the lobby and says so in one line of a log nobody has opened
    # yet, which looks like the setting being ignored.
    if [ -n "$FULL_GAME" ] && [ ! -f "content/$FULL_GAME/game.yml" ]; then
        have=""
        for gy in content/*/game.yml; do
            [ -f "$gy" ] || continue
            gid="${gy#content/}"; have="$have ${gid%/game.yml}"
        done
        warn "no content/$FULL_GAME/game.yml, so the server will fall back to the lobby.
       This build has:$have
       Fix it with: sed -i 's/^sv_game:.*/sv_game: \"<one of those>\"/' cfg/server.yml"
    fi
fi

# --- 9. nginx, and the packages it needs ------------------------------------
#
# The proxy is what makes a browser client possible at all: a page served over
# HTTPS may not open a plain ws:// socket, and the engine's web export therefore
# needs wss:// -- which is nginx terminating TLS on a public port and forwarding to
# the game on the loopback. deploy/install-server-tls.sh writes that vhost and is
# not duplicated here; this step is only about the things that have to exist first.

if [ "${FULL_NGINX:-0}" -eq 1 ]; then
    step "nginx"

    # One helper, three package managers, and the same shape fetch-godot.sh uses for
    # the library the runtime needs. Nothing here builds a distro list beyond the
    # three names a package has.
    pkg_install() {
        local deb="$1" rpm="$2" arch="$3"
        if command -v apt-get >/dev/null 2>&1 && [ -n "$deb" ]; then
            $SUDO apt-get update -qq >/dev/null 2>&1
            $SUDO apt-get install -y -qq --no-install-recommends $deb >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1 && [ -n "$rpm" ]; then
            $SUDO dnf install -y -q $rpm >/dev/null 2>&1
        elif command -v pacman >/dev/null 2>&1 && [ -n "$arch" ]; then
            $SUDO pacman -S --needed --noconfirm $arch >/dev/null 2>&1
        else
            return 1
        fi
    }

    # [b]An nginx that is already here is somebody else's nginx.[/b] It may be serving a
    # website, it is certainly serving something if it is running, and the difference
    # between installing one and joining one decides what this step may do: a fresh
    # install can be started and enabled freely, and a running one must be left
    # working. So find out which this is, and say so -- an operator who is told
    # "installed nginx" about a box that was already serving their site has been told
    # something false about the thing they are most worried about.
    NGINX_PREEXISTING=""
    if NGINX_BIN="$(find_nginx)"; then
        NGINX_PREEXISTING=1
        vhosts="$($SUDO "$NGINX_BIN" -T 2>/dev/null | grep -cE '^[[:space:]]*server_name[[:space:]]' || true)"
        if [ "${vhosts:-0}" -gt 0 ]; then
            ok "nginx was already here, serving ${vhosts} server block(s); this adds one"
        else
            ok "nginx was already here"
        fi
    elif pkg_install nginx nginx nginx && NGINX_BIN="$(find_nginx)"; then
        ok "installed nginx"
    else
        die "could not install nginx. Install it and re-run:
    Debian/Ubuntu:  sudo apt-get install -y nginx
    Fedora/RHEL:    sudo dnf install -y nginx
    Arch:           sudo pacman -S nginx" 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        # Started and enabled are two different things and a box can be either without
        # the other. Reporting them apart is the difference between "I started your
        # web server" and "it was already running", which is the sentence an operator
        # reads to find out whether this run touched their site.
        if $SUDO systemctl is-active --quiet nginx; then
            ok "nginx is already running; not restarting it"
        else
            $SUDO systemctl start nginx >/dev/null 2>&1
            if $SUDO systemctl is-active --quiet nginx; then
                ok "started nginx"
            else
                die "nginx is installed but will not start. Its own configuration is the
    first place to look, and this run has not written any of it yet:
        sudo nginx -t
        sudo systemctl status nginx" 1
            fi
        fi

        if $SUDO systemctl is-enabled --quiet nginx 2>/dev/null; then
            ok "nginx starts at boot"
        else
            $SUDO systemctl enable nginx >/dev/null 2>&1 && ok "enabled nginx at boot"
        fi
    fi

    # A vhost this installer wrote before. install-server-tls.sh overwrites its own
    # file and tests the configuration before reloading, so a re-run is safe -- but
    # somebody watching should be told it is a replacement rather than an addition.
    if [ -n "$NGINX_PREEXISTING" ] \
            && $SUDO "$NGINX_BIN" -T 2>/dev/null | grep -q "server-tls-${LE_DOMAINS[0]}-"; then
        ok "a TLS vhost for ${LE_DOMAINS[0]} is already installed; it will be rewritten"
    fi

    # The webroot the stock vhost actually serves, which is not the same directory on
    # every distribution -- and a certificate request against the wrong one is a
    # FAILED validation, which is what the rate limit counts.
    case " ${LE_EXTRA[*]} " in
        *' --webroot '*|*' -w '*) ;;
        *)
            if [ -d /var/www/html ]; then
                LE_EXTRA+=(--webroot /var/www/html)
            elif [ -d /usr/share/nginx/html ]; then
                LE_EXTRA+=(--webroot /usr/share/nginx/html)
            fi
            ;;
    esac

    if ! command -v certbot >/dev/null 2>&1; then
        if pkg_install certbot certbot certbot; then
            ok "installed certbot"
        else
            warn "could not install certbot; the certificate step will say so"
        fi
    fi
    [ "${LE_METHOD:-}" = "dns" ] && [ -n "${TMC_LE_DNS_PLUGIN:-}" ] \
        && pkg_install "python3-certbot-dns-${TMC_LE_DNS_PLUGIN}" "" "" \
        && ok "installed the dns-${TMC_LE_DNS_PLUGIN} plugin"
fi

# --- 10. The firewall --------------------------------------------------------
#
# Before the certificate rather than after it. HTTP-01 is Let's Encrypt reaching
# this box on :80, so a closed firewall is a failed validation -- and five of those
# on one hostname is an hour's lockout.

if [ -n "${FULL_FIREWALL:-}" ]; then
    step "firewall"

    fw_allow() {
        case "$FULL_FIREWALL" in
            ufw)       $SUDO ufw allow "$1/tcp" >/dev/null 2>&1 ;;
            firewalld) $SUDO firewall-cmd --permanent --add-port="$1/tcp" >/dev/null 2>&1 ;;
        esac
    }

    if [ "${FULL_NGINX:-0}" -eq 1 ]; then
        fw_allow 80 && ok "80/tcp open (the certificate is issued through it)"
        fw_allow "$FULL_PUBLIC_PORT" && ok "$FULL_PUBLIC_PORT/tcp open (wss)"
    else
        fw_allow "$FULL_PORT" && ok "$FULL_PORT/tcp open"
    fi

    [ "$FULL_FIREWALL" = "firewalld" ] && $SUDO firewall-cmd --reload >/dev/null 2>&1
fi

# --- 11. A certificate ------------------------------------------------------
#
# Last, and after ./server exists, so that a failure here leaves a project that is
# set up and a server that starts. TLS is what a browser client needs in FRONT of
# this server, not something the server itself cannot boot without.

if [ "$DO_LETSENCRYPT" -eq 1 ]; then
    step "TLS certificate"

    le_args=()
    for d in "${LE_DOMAINS[@]}"; do le_args+=(--domain "$d"); done
    [ -n "$LE_EMAIL" ]  && le_args+=(--email "$LE_EMAIL")
    [ -n "$LE_METHOD" ] && le_args+=(--method "$LE_METHOD")
    [ "$LE_STAGING" -eq 1 ] && le_args+=(--staging)
    [ "${#LE_EXTRA[@]}" -gt 0 ] && le_args+=("${LE_EXTRA[@]}")

    # In the guided install the next step is the very next thing this script does,
    # with the ports somebody actually gave -- so the certificate script's own
    # suggestion is not just noise, it names a backend port it had to invent.
    [ "$DO_FULL" -eq 1 ] && le_args+=(--no-next-steps)

    if "$LE_SCRIPT" "${le_args[@]}"; then
        LE_OK=1
    else
        # Not `die`: everything above this line worked, and saying otherwise would
        # send somebody back to re-run a setup that has nothing left to do. The exit
        # code is still non-zero, because a run that was asked for a certificate and
        # has none did not do what it was told.
        # The suggestion is for a person to paste, so the flag this script passes for
        # its own convenience has no business in it.
        shown_args=()
        for a in "${le_args[@]}"; do [ "$a" = "--no-next-steps" ] || shown_args+=("$a"); done
        warn "no certificate was issued. The project is set up and ./server works;
       re-run just the certificate with:
           sudo ./deploy/issue-letsencrypt.sh ${shown_args[*]}"
        LE_OK=0
    fi
fi

# --- 12. The proxy -----------------------------------------------------------
#
# deploy/install-server-tls.sh writes the vhost: a TLS listener on the public port
# that forwards to the game on the loopback, and the `$http_upgrade` map a WebSocket
# handshake needs. It is called rather than copied -- that script already knows
# which nginx directories this distribution uses and which map may only appear once
# in a configuration, and a second copy of that knowledge here is a second copy to
# get wrong.

if [ "${FULL_NGINX:-0}" -eq 1 ]; then
    step "nginx -> the server"

    if [ "${LE_OK:-0}" -ne 1 ]; then
        warn "no certificate, so the TLS vhost was not installed -- nginx would refuse
       to start with an ssl_certificate that is not there. Fix the certificate and
       then run:
           sudo ./deploy/install-server-tls.sh --domain ${LE_DOMAINS[0]} \\
                --port $FULL_PUBLIC_PORT --backend 127.0.0.1:$FULL_PORT"
    else
        TLS_NAME="${LE_DOMAINS[0]}"
        [ "$LE_STAGING" -eq 1 ] && TLS_NAME="$TLS_NAME-staging"
        TLS_CERT="/etc/letsencrypt/live/$TLS_NAME/fullchain.pem"
        TLS_KEY="/etc/letsencrypt/live/$TLS_NAME/privkey.pem"

        if $SUDO test -f "$TLS_CERT"; then
            if $SUDO "$ROOT/deploy/install-server-tls.sh" \
                    --domain "${LE_DOMAINS[0]}" \
                    --port "$FULL_PUBLIC_PORT" \
                    --backend "127.0.0.1:$FULL_PORT" \
                    --cert "$TLS_CERT" --key "$TLS_KEY"; then
                FULL_PROXY_OK=1
            else
                warn "the TLS vhost was not installed. The certificate is fine; re-run:
           sudo ./deploy/install-server-tls.sh --domain ${LE_DOMAINS[0]} \\
                --port $FULL_PUBLIC_PORT --backend 127.0.0.1:$FULL_PORT \\
                --cert $TLS_CERT --key $TLS_KEY"
            fi
        else
            warn "expected the certificate at $TLS_CERT and it is not there"
        fi
    fi
fi

# --- 13. The service ---------------------------------------------------------
#
# Last, because a unit that starts the server should start a server that is
# configured: the game, the port, the bind address and the certificate are all
# already what the answers said by the time this runs.

if [ "${FULL_SYSTEMD:-0}" -eq 1 ]; then
    step "systemd"

    if $SUDO "$ROOT/deploy/install-systemd.sh" --name "$FULL_UNIT" --user "$FULL_RUN_USER"; then
        FULL_SERVICE_OK=1
    else
        warn "the service did not come up. ./server still starts it by hand."
    fi
fi

# --- Done ------------------------------------------------------------------

if [ "${NEW_RCON:-0}" -eq 1 ]; then
    printf '\n%s  RCON password (printed once, it is in cfg/rcon.yml):%s\n' "$BLD" "$OFF"
    printf '      %s\n' "$RCON_PASSWORD"
fi

if [ "$DO_CHECK" -eq 1 ]; then
    step "checking"
    if ./server check; then
        ok "the server boots, loads the lobby, and shuts down"
    else
        die "the server did not come up. Run ./server check --verbose" 1
    fi
fi

if [ "$DO_FULL" -eq 1 ]; then
    printf '\n%s  Ready.%s  %s\n\n' "$BLD" "$OFF" "$FULL_NAME"

    if [ "${FULL_SERVICE_OK:-0}" -eq 1 ]; then
        printf '    %srunning as %s.service%s\n' "$GRN" "$FULL_UNIT" "$OFF"
        printf '      sudo systemctl status %s\n' "$FULL_UNIT"
        printf '      sudo journalctl -u %s -f\n\n' "$FULL_UNIT"
    else
        printf '    ./server                 start it\n'
        printf '    ./server check           boot once and exit, for CI\n\n'
    fi

    if [ "${FULL_PROXY_OK:-0}" -eq 1 ]; then
        printf '    %sa client connects to%s\n' "$BLD" "$OFF"
        printf '      wss://%s:%s\n\n' "${LE_DOMAINS[0]}" "$FULL_PUBLIC_PORT"
        printf '    %sthe game port itself is on 127.0.0.1:%s and is not reachable from\n' "$DIM" "$FULL_PORT"
        printf '    outside this machine, which is the point of the proxy.%s\n\n' "$OFF"
    fi

    printf '    ./server config          what your YAML became\n'
    printf '    ./server --help          every option\n\n'
else

cat <<DONE

$BLD  Ready.$OFF

    ./server                 start it
    ./server check           boot once and exit, for CI
    ./server config          what your YAML became
    ./server --help          every option

    docker compose up -d     the same thing in a container

DONE

fi

if [ "$DO_FULL" -eq 1 ]; then
    :
elif [ "$DO_LETSENCRYPT" -eq 0 ]; then
    cat <<TLS
    A browser client needs TLS in front of this, because a page on HTTPS may not
    open a plain ws:// socket:

    ./setup.sh --full                        the guided install: nginx, TLS, a service
    ./deploy/issue-letsencrypt.sh --help     every certificate method

TLS
fi

# A run that was asked for a certificate and has none did not do what it was told,
# whatever else went right.
if [ "$DO_LETSENCRYPT" -eq 1 ] && [ "${LE_OK:-0}" -eq 0 ]; then
    exit 1
fi
