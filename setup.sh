#!/usr/bin/env bash
#
# One command to go from a clone to a server you can start.
#
#   ./setup.sh                  set everything up and write ./server
#   ./setup.sh --check          set up, then boot the server once and shut it down
#   ./setup.sh --no-import      skip the Godot import pass (fast, for a re-run)
#   ./setup.sh --godot PATH     use a specific runtime
#   ./setup.sh --no-download    never fetch a runtime; fail if there is none
#   ./setup.sh --no-clone       never git clone anything; fail if one is missing
#   ./setup.sh --update         git pull every addon and game repository first
#   ./setup.sh --vendor         COPY the addons instead of linking them
#   ./setup.sh --addons-dir DIR take the addons from a directory you already have
#                               them in, rather than from this project's own clones
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
#      They go INSIDE this project: a missing one is cloned into addons/.repos/ and
#      addons/<name> is a relative link into it, so the whole build is one directory
#      with nothing pointing out of it -- which is what a tarball, a `cp -r` and a
#      container image's final stage each need. `--addons-dir DIR` takes them from a
#      directory you already have instead, and links out to it; `--vendor` copies.
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

# Where the dot-* addons come from.
#
# [b]Empty is the default, and it means "inside this project".[/b] An addon that is not
# here is cloned into addons/.repos/<repo> and addons/<name> becomes a RELATIVE link
# into it, so the finished build is one directory with nothing pointing out of it: it
# can be moved, tarred, `cp -r`d or COPYed into a container's final stage and still
# resolve. The old shape -- fifty repositories in the PARENT directory -- wrote into a
# directory this project does not own, which on a box running several servers is one
# clone shared by all of them with nothing saying so.
#
# A directory named here is used instead, and may be either shape: a directory OF
# addons (`DIR/dot_core`, which is what somebody's hand-kept library or another Godot
# project's addons/ looks like) or a directory of the REPOSITORIES
# (`DIR/dot-core/addons/dot_core`, which is what dot-bootstrap and a developer checkout
# look like). Found there, it is linked; not found there, it is cloned there. That is
# the point of a shared directory: `--addons-dir ..` is exactly what this script used
# to do, and one directory serves every server on the box.
ADDONS_DIR="${TMC_ADDONS_DIR:-}"

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
        --addons-dir) ADDONS_DIR="${2:?--addons-dir needs a value}"; shift 2 ;;
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
        # 2..62 is the comment block at the top of this file, printed as help so
        # there is one copy of it rather than two that drift. The range moves when
        # that block grows; it ends at the last line of step 8.
        -h|--help)   sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

## Fast-forward every named repository that is already on this machine.
##
## [b]It is given DIRECTORIES, not names, and that is what makes one pull find them.[/b]
## An addon can be in this project's own addons/.repos/, in a --addons-dir somebody
## shares between servers, or beside this repository because an older setup.sh wired it
## there -- and a checkout that is pulled only when it happens to be in the layout this
## script was written for is a fix that is installed and still not running.
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

    for dir in "$@"; do
        repo="$(basename "$dir")"

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


## Clone every named repository that is not already in the given directory.
##
## The destination is an argument because there are three of them now: this project's
## own addons/.repos/, a shared --addons-dir, and the parent directory, which is still
## where the GAMES go -- they are content that gets published into dist/ rather than
## code this project compiles, and a game repository under addons/ would be imported as
## part of this project, which is the arrangement the flip to packs removed.
##
## Never touches a checkout that exists -- not even to pull. A setup script that
## silently updated somebody's working tree would be a setup script that can lose work.
clone_repos() {
    local dest="$1"; shift

    command -v git >/dev/null 2>&1 || die "cloning needs git, and this machine has none." 4

    local wanted=("$@") missing=() repo failed=()

    for repo in "${wanted[@]}"; do
        [ -d "$dest/$repo" ] || missing+=("$repo")
    done

    [ ${#missing[@]} -gt 0 ] || return 0

    mkdir -p "$dest" || die "could not create $dest" 4

    printf '    %scloning %d repositories into %s%s\n' \
        "$DIM" "${#missing[@]}" "$(cd "$dest" && pwd)" "$OFF"

    # [b]Shallow by default.[/b] This path exists to stand a SERVER up: fifty repositories
    # of history is bandwidth and disk nobody on that box will ever read, and it is most
    # of what the clone costs. `dot-bootstrap` is the developer tool and clones in full.
    # TMC_GIT_DEPTH=0 turns this off; `git fetch --unshallow` fixes one after the fact.
    local depth=()
    [ "${TMC_GIT_DEPTH:-1}" = "0" ] || depth=(--depth "${TMC_GIT_DEPTH:-1}")

    for repo in "${missing[@]}"; do
        if git clone --quiet "${depth[@]}" "$GIT_BASE/$repo.git" "$dest/$repo" 2>/dev/null; then
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
ADDONS=(dot_core dot_net dot_game dot_server dot_server_query dot_server_security dot_2d dot_ui dot_auth dot_cloud dot_user
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

# This project's own clones, and the default home of every addon.
#
# [b]Under addons/, and hidden.[/b] Each of these is a whole repository with its own
# addons/<name> inside it, so it must not be walked as part of this project: a leading
# dot is skipped by Godot's scanner, and a .gdignore is written into it as well because
# that is the documented switch and the other is a behaviour. Without either, every
# script arrives twice -- once here and once through the link beside it -- and the
# import pass fails on class_name globals that are somehow already declared.
ADDONS_REPOS="$ROOT/addons/.repos"

if [ -n "$ADDONS_DIR" ]; then
    # Through a second variable, because the assignment happens before the `||` is
    # reached: writing straight into ADDONS_DIR empties it on the failing path and the
    # message then names no directory at all.
    ADDONS_DIR_ABS="$(cd "$ADDONS_DIR" 2>/dev/null && pwd)" \
        || die "--addons-dir: no such directory: $ADDONS_DIR" 2
    ADDONS_DIR="$ADDONS_DIR_ABS"
fi

# Where a MISSING addon is cloned to. A shared directory was asked for by name, so it
# is also where the missing ones are put -- otherwise the first run fills it and every
# run after it quietly starts a second copy inside the project.
ADDONS_CLONE_DEST="${ADDONS_DIR:-$ADDONS_REPOS}"

## Resolve one addon, setting:
##
##   SRC       the directory that holds it (its plugin.cfg and all)
##   SRC_LINK  what addons/<name> should point AT, or empty for "leave the link alone"
##
## Returns 1 when this machine does not have it anywhere, which is what drives the
## clone: the list of what to fetch is what is ACTUALLY absent rather than the list of
## addons in the abstract, so a vendored tree with no network fetches nothing.
addon_source() {
    local name="$1" repo="${1//_/-}"
    SRC=""; SRC_LINK=""; SRC_KIND=""

    if [ -n "$ADDONS_DIR" ]; then
        # Both shapes of a shared directory: a directory of addons, and a directory of
        # the repositories they live in. Guessing wrong is a silent re-clone of fifty
        # repositories the box already has, so it checks for both rather than
        # documenting which one it wanted.
        if [ -d "$ADDONS_DIR/$name" ]; then
            SRC="$ADDONS_DIR/$name"
        elif [ -d "$ADDONS_DIR/$repo/addons/$name" ]; then
            SRC="$ADDONS_DIR/$repo/addons/$name"
        fi

        # Absolute, deliberately. A shared directory is outside this project by
        # definition -- there is no relative path to it that survives the project being
        # moved, and an absolute one at least SAYS where it went when it dangles.
        if [ -n "$SRC" ]; then SRC_LINK="$SRC"; SRC_KIND="dir"; return 0; fi
    fi

    if [ -d "$ADDONS_REPOS/$repo/addons/$name" ]; then
        SRC="$ADDONS_REPOS/$repo/addons/$name"
        # Relative, and pointing INSIDE addons/, which is the whole point of the
        # default: nothing in the finished tree points out of it.
        SRC_LINK=".repos/$repo/addons/$name"
        SRC_KIND="repos"
        return 0
    fi

    # A link this machine already has that still resolves -- addons/<name> ->
    # ../../<repo>/addons/<name>, which is every checkout wired by an earlier setup.sh
    # and every developer tree dot-bootstrap made. [b]Kept exactly as it is.[/b] Cloning
    # fifty repositories a box already has, into a second copy, on the run where
    # somebody typed the usual upgrade command, is the one thing a setup script must not
    # do -- and two copies of dot-cloud on one machine is the bug where the fix is
    # installed, pulled and still not running. `--addons-dir` repoints them on purpose;
    # nothing else does.
    if [ -L "$ROOT/addons/$name" ] && [ -d "$ROOT/addons/$name" ]; then
        SRC="$(cd "$ROOT/addons/$name" && pwd -P)"
        SRC_LINK=""
        SRC_KIND="link"
        return 0
    fi

    return 1
}

## The git checkout an addon came out of, or nothing. Walks up rather than assuming the
## layout, because there are three of them and a flat directory of addons is not a
## repository at all.
git_root_of() {
    local dir="$1"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        [ -d "$dir/.git" ] && { printf '%s\n' "$dir"; return 0; }
        dir="$(dirname "$dir")"
    done
    return 1
}

## Link, copy or record-as-missing every addon. Run twice: once to find out what is
## absent, and once more after cloning it.
##
## A vendored addon is not missing and is never cloned -- that is the release tarball,
## which has no clones, no network and nothing wrong with it.
resolve_addons() {
    MISSING=()
    FROM_DIR=0; FROM_REPOS=0; FROM_LINK=0; FROM_VENDOR=0
    local name repo link
    for name in "${ADDONS[@]}"; do
        repo="${name//_/-}"
        link="addons/$name"

        if addon_source "$name"; then
            if [ "$VENDOR" -eq 1 ]; then
                # Copied, not linked. A symlink is fine where the thing it points at
                # stays put and breaks the moment the directory is moved somewhere it
                # is not -- a release tarball, or a container image whose final stage
                # copies only this project. The symptom is every dot-* class_name
                # unresolved at once, which reads as a broken project rather than as a
                # dangling link.
                rm -rf "$link"
                cp -rL "$SRC" "$link"
            elif [ -n "$SRC_LINK" ] && { [ -L "$link" ] || [ ! -e "$link" ]; }; then
                ln -sfn "$SRC_LINK" "$link"
            fi
            case "$SRC_KIND" in
                dir)   FROM_DIR=$((FROM_DIR + 1)) ;;
                repos) FROM_REPOS=$((FROM_REPOS + 1)) ;;
                link)  FROM_LINK=$((FROM_LINK + 1)) ;;
            esac
        elif [ -d "$link" ]; then
            # already vendored, which is what a release tarball looks like
            FROM_VENDOR=$((FROM_VENDOR + 1))
        else
            MISSING+=("$repo")
        fi
    done
}

resolve_addons

if [ ${#MISSING[@]} -gt 0 ] && [ "$DO_CLONE" -eq 1 ]; then
    if [ "$ADDONS_CLONE_DEST" = "$ADDONS_REPOS" ]; then
        mkdir -p "$ADDONS_REPOS"
        # Written before the first clone, not after: a run interrupted between the two
        # leaves repositories in a directory Godot would then walk.
        [ -f "$ADDONS_REPOS/.gdignore" ] || : > "$ADDONS_REPOS/.gdignore"
    fi
    clone_repos "$ADDONS_CLONE_DEST" "${MISSING[@]}"
    resolve_addons
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    die "These addon repositories are not on this machine:

        ${MISSING[*]}

    Each dot-* project is a separate repository and there is no way to clone the
    tree at once.

    They are normally cloned for you into ./addons/.repos/, from $GIT_BASE
    over HTTPS; this run could not, or --no-clone was given.

    --addons-dir DIR takes them from a directory you already have them in -- either
    a directory of addons (DIR/dot_core) or a directory of the repositories
    (DIR/dot-core/addons/dot_core) -- and links them from there. --addons-dir .. is
    a developer checkout, which is what dot-bootstrap makes.

    Or vendor their addons/<name> folders into ./addons/, which is what a release
    tarball looks like." 4
fi

# `--update` runs AFTER the addons have been resolved, not before, because the
# directories to pull are wherever they actually turned out to be -- which is the whole
# reason an addon in a shared directory or in an old sibling checkout gets pulled at all
# instead of being silently skipped for not being where this script expected it.
if [ "$DO_UPDATE" -eq 1 ]; then
    UPDATE_DIRS=()
    for name in "${ADDONS[@]}"; do
        addon_source "$name" || continue
        root_dir="$(git_root_of "$SRC")" || continue
        UPDATE_DIRS+=("$root_dir")
    done
    # One repository can hold more than one of them -- a shared directory is allowed to
    # be another project's addons/ -- and pulling it twice prints it twice.
    if [ ${#UPDATE_DIRS[@]} -gt 0 ]; then
        mapfile -t UPDATE_DIRS < <(printf '%s\n' "${UPDATE_DIRS[@]}" | sort -u)
        update_repos "${UPDATE_DIRS[@]}"
    fi
fi

# [b]--vendor throws the clones away once they have been copied.[/b] Vendoring says this
# tree is to carry CONTENT rather than checkouts: a container's final stage and a
# release tarball copy the project directory whole, and fifty repositories under
# addons/.repos/ would travel with it -- every one of them a second copy of what was
# just vendored beside it. Nothing is lost that a re-run cannot fetch again, and a
# re-run finds the vendored directories and fetches nothing at all.
if [ "$VENDOR" -eq 1 ] && [ -d "$ADDONS_REPOS" ]; then
    rm -rf "$ADDONS_REPOS"
    ok "addons/.repos/ removed -- --vendor means this tree carries content, not clones"
fi

# Where they came from, rather than where the default would have put them. A tree that
# was wired by an older setup.sh keeps its links, and a run that says "linked from
# addons/.repos/" over fifty links into the parent directory is a run that would have
# somebody looking for a directory that does not exist.
if [ "$VENDOR" -eq 1 ]; then
    ok "${#ADDONS[@]} addons copied into addons/"
else
    WHERE=()
    [ "$FROM_DIR"    -gt 0 ] && WHERE+=("$FROM_DIR from $ADDONS_DIR")
    [ "$FROM_REPOS"  -gt 0 ] && WHERE+=("$FROM_REPOS from addons/.repos/")
    [ "$FROM_LINK"   -gt 0 ] && WHERE+=("$FROM_LINK already linked elsewhere")
    [ "$FROM_VENDOR" -gt 0 ] && WHERE+=("$FROM_VENDOR already vendored")
    ok "${#ADDONS[@]} addons in addons/ ($(IFS=', '; echo "${WHERE[*]}"))"
fi

# --- 3. Leftovers from when the games were vendored ------------------------
#
# [b]A vendored game left over from before the flip POISONS the class registry, and
# only an upgraded box has one.[/b] These directories are where the five games used to
# be copied, they are gitignored so `git pull` never removes them, and nothing here
# creates them any more -- so a machine that was set up before the flip keeps a
# pre-conversion copy of every game for ever. Those copies still declare `class_name`,
# the import registers them as globals, and then a DELIVERED game's scripts resolve the
# same names to the host's stale copy rather than to their own:
#
#     Parse Error: Value of type "res://dot_cloud/g2gfast/0.1.0/game/g2g_identity.gd"
#     cannot be assigned to a variable of type "G2GIdentity".
#     Parse Error: argument 1 should be "G2GCamera.Mode" but is "g2g_camera.gd.Mode".
#
# Two scripts, one name, and the type check is right to refuse. Nothing about the
# message says "delete a directory you have not thought about since August".
#
# The previous setup.sh removed these before copying into them; the copy went and the
# removal went with it. `tools/check.sh` fails when one exists, which catches a
# developer and not the box that was upgraded last night.
#
# Only the directories this project once vendored, and only when they are not tracked --
# a fork that legitimately keeps sources at one of these paths says so by committing
# them, and this must not delete somebody's work on the strength of a name.
VENDORED_DIRS=(game scenes maps avatars npcs props textures)
stale_vendored=()

for d in "${VENDORED_DIRS[@]}"; do
    [ -d "$ROOT/$d" ] || continue

    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
            && [ -n "$(git -C "$ROOT" ls-files "$d")" ]; then
        warn "$d/ is tracked by git, so it is yours; leaving it alone"
        continue
    fi

    rm -rf "${ROOT:?}/$d"
    stale_vendored+=("$d")
done

if [ ${#stale_vendored[@]} -gt 0 ]; then
    ok "removed the vendored game directories this build no longer uses: ${stale_vendored[*]}"
    # [b]Removing the files is half of it.[/b] The class cache still holds their
    # class_name entries, pointing at paths that no longer exist:
    #
    #     Could not parse global class "G2GIdentity" from "res://game/g2g_identity.gd"
    #
    # and a global that resolves to nothing is no better than one that resolves to the
    # wrong script. The import below is what rewrites that file, so this run needs one
    # whatever the flags say.
    FORCE_IMPORT=1
fi


# --- 3b. Import -------------------------------------------------------------
#
# [b]Before the games, and that ordering is now load-bearing.[/b] It used to run after
# them, which was right while the games were COPIED in: the copy added scripts and the
# import registered their class_name globals. Nothing is copied now, and the games step
# runs Godot scripts of its own -- the keygen and the publisher -- against a project whose
# addons have just been dropped in and never imported. Every one of them failed to
# compile, and the whole install died on "could not generate a content signing key",
# naming the last thing it tried rather than the reason.

# [b]`--no-import` may not skip this when the cache is STALE, and that is not a
# convenience.[/b] `.godot/global_script_class_cache.cfg` is what registers every
# `class_name` in the project, and a DELIVERED game's scripts are parsed against it at
# runtime -- so an addon linked or updated after the cache was last built is a class the
# pack cannot see. The host's own scripts are already cached, so the server boots, loads
# the game, and looks healthy; what fails is the pack:
#
#     SCRIPT ERROR: Parse Error: Could not find type "DotTimerRun" in the current scope.
#     ERROR: Failed to load script "res://dot_cloud/g2gfast/0.1.0/game/g2g_game.gd"
#            with error "Parse error".
#
# and three layers up that surfaces as "No G2GGame is registered", a game with no map
# command, and a grey screen. Reproduced exactly by removing one addon's entries from
# the cache.
#
# `--no-import` exists so an upgrade does not pay for a full reimport it does not need,
# and that was right while every game was compiled in: nothing was parsed from a mount,
# so a stale cache could only affect scripts that were already cached. The flip to packs
# changed what the import is FOR.
#
# The test is the cache against the newest file under addons/ -- one `find`, and it is
# exactly the question "was anything linked or pulled since this was built".
import_is_stale() {
    local cache="$ROOT/.godot/global_script_class_cache.cfg"

    [ -f "$cache" ] || return 0
    [ -d "$ROOT/addons" ] || return 1

    # -L: addons/ is symlinks, and the mtime that matters is the file in the checkout
    # rather than the link. .repos/ is pruned because every file under it is reachable
    # through the link beside it, and walking both halves the answer costs twice.
    [ -n "$(find -L "$ROOT/addons" -path "$ROOT/addons/.repos" -prune -o \
            -newer "$cache" -name '*.gd' -print -quit 2>/dev/null)" ]
}

if [ "$DO_IMPORT" -eq 1 ]; then
    step "importing"
    # Re-run after ANY script with a new class_name is added. Without it the
    # identifier does not resolve, the scene fails to load, and the process HANGS
    # rather than exiting, because nothing ever reaches get_tree().quit().
    "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1
    ok "class_name globals registered"
elif [ "${FORCE_IMPORT:-0}" -eq 1 ]; then
    step "importing"
    warn "a vendored game directory was removed, so --no-import is being overridden"
    printf '       its class_name entries are still in the class cache, pointing at\n'
    printf '       files that are gone. Only an import rewrites that.\n'
    "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1
    ok "class_name globals registered"
elif import_is_stale; then
    step "importing"
    warn "an addon is newer than the class cache, so --no-import is being overridden"
    printf '       a delivered game parses against that cache; leaving it stale breaks
'
    printf '       the pack and nothing else, which reads as a broken game.
'
    "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1
    ok "class_name globals registered"
fi

# --- 4. The games -----------------------------------------------------------
#
# Every game is PUBLISHED here, not copied in. This build ships no game at all.
#
# It used to copy all five into one `game/` and one `scenes/` at this project's root,
# because a .tscn stores its script reference as an absolute res:// path and there is
# no relative form -- so a game's own `maps/` had to become THIS project's `maps/`.
# That worked, and it meant a new game was a new build of the engine: an export, an
# upload, and every player on the old build unable to join.
#
# The games reference their own files relatively now and rebase their own res://
# strings, so each one is correct wherever it is mounted. `./server pack <id>
# --source <repo>` turns a game repository into a signed pack in `dist/`, the server
# finds it there without any URL, and a client downloads it on connect. Adding a game
# to a server is publishing a pack and writing a `game.yml`.
#
# THE SIGNING KEY IS WHAT MAKES THIS SAFE AND IT IS ALSO WHAT MAKES IT WORK. A pack
# contains scripts, so every client refuses an unsigned manifest -- which means a box
# with no key publishes nothing at all rather than publishing something that mounts
# nowhere. One is generated below if there is not one already.

step "games"

# repository:content id
#
# The repository name is the DIRECTORY beside this one and it is not the game's name:
# `dot-a-room` and `dot-2d-hungry` were renamed to `game-simple-lobby` and
# `game-hungario` and this list was not, so every run skipped both games. A stale name
# here is a hard failure rather than a warning: "skipping the lobby" scrolls past and a
# server with no games does not.
#
# The second field is the CONTENT directory whose `game.yml` and `pack.json` describe
# the pack -- which is not always the pack's name, and deliberately: hungario is three
# game ids over one `content_id: hungry`, so any one of its three directories publishes
# the one pack. What each pack excludes is in its `pack.json`, beside the game.yml,
# because that is a property of the game rather than of this script.
GAMES=(
    "game-simple-lobby:lobby"
    "game-hungario:hungry_classic"
    "game-g2gfast:g2gfast"
    "game-playground:playground"
    "game-arena:arena"
    "game-buses-from-hell:buses"
)

resolve_games() {
    MISSING_GAMES=()
    for entry in "${GAMES[@]}"; do
        repo="${entry%%:*}"
        [ -d "$ROOT/../$repo/game" ] || MISSING_GAMES+=("$repo")
    done
}

if [ "$DO_UPDATE" -eq 1 ]; then
    UPDATE_GAMES=()
    for entry in "${GAMES[@]}"; do UPDATE_GAMES+=("$ROOT/../${entry%%:*}"); done
    update_repos "${UPDATE_GAMES[@]}"
fi

resolve_games

if [ ${#MISSING_GAMES[@]} -gt 0 ] && [ "$DO_CLONE" -eq 1 ]; then
    clone_repos "$ROOT/.." "${MISSING_GAMES[@]}"
    resolve_games
fi

# [b]Packs already in dist/ are the release-tarball case and are kept.[/b] A box with
# no game repositories beside it and a published dist/ is a deployment, not a broken
# developer machine -- and re-publishing would need the signing key, which a
# deployment should not have. Only when there is nothing to run does this refuse.
if [ ${#MISSING_GAMES[@]} -gt 0 ]; then
    if [ -n "$(ls -A "$ROOT/dist" 2>/dev/null)" ]; then
        ok "no game repositories beside this one; keeping the packs in dist/"
        PUBLISHED_GAMES=1
    else
        die "These game repositories are not beside this one:

        ${MISSING_GAMES[*]}

    Each game is a separate repository and there is no way to clone the tree at
    once. They are normally cloned for you; this run could not, or --no-clone was
    given. A deployment that only serves published packs needs dist/ instead.

    If one was RENAMED, fix the GAMES list in this script." 4
    fi
fi

# The signing key. Generated rather than demanded, because a first run on a fresh box
# has no reason to have one -- and without it `./server pack` correctly refuses, which
# would make the whole install fail on a step the operator was never told about.
#
# [b]The private half never leaves this machine and is gitignored before it exists.[/b]
# Anyone holding it can publish content that every client trusting this key will mount
# and RUN. The public half goes in client/content.json, which is shipped on purpose.
if [ "${PUBLISHED_GAMES:-0}" -ne 1 ] && [ ! -f "$ROOT/keys/content.key" ]; then
    mkdir -p "$ROOT/keys"
    "$GODOT" --headless --path "$ROOT" \
        --script res://addons/dot_cloud/publish/dot_cloud_cli.gd -- \
        keygen --private keys/content.key --public keys/content.pub >/dev/null 2>&1 \
        || die "could not generate a content signing key" 4
    chmod 600 "$ROOT/keys/content.key"
    ok "content signing key generated (keys/content.key -- keep it)"
fi

# content/avatars/ is NOT copied from a game any more, and the difference is worth
# naming. HungryContentSource reads it through the game's own rebase helper, so for a
# delivered game it resolves inside the mount and the pack carries it. What is left
# here is this server's own publishable avatar set -- `./server pack avatars` -- which
# is the pack that OVERRIDES the built-in one. Copying a game's copy on top of it made
# the two the same file by construction, which is the one arrangement in which an
# override cannot be tested.

# [b]Imported BEFORE publishing, and that ordering is the whole of it.[/b] A .glb or a
# .png is not a loadable resource: the editor imports it into .godot/imported/ and the
# .import marker beside it redirects every load there. Nothing imports at runtime, on
# any platform -- so a pack published from a project that has never been imported ships
# the bytes of an asset that no load() can open, and reports nothing, because the file
# is right there.
#
# [b]NOT gated on --no-import, and that is not an oversight.[/b] `--no-import` is the
# documented upgrade command -- `git pull && ./setup.sh --no-import` -- and it exists to
# skip re-importing THIS project, which is slow and unchanged on a pull. A game
# repository that gained an asset since the last run is a different question: skipping it
# publishes a pack carrying bytes no load() can open, silently, on the one command an
# operator runs most. The import is what makes the pack it is about to build correct, so
# it belongs to the publish rather than to the import flag.
if [ "${PUBLISHED_GAMES:-0}" -ne 1 ]; then
    for entry in "${GAMES[@]}"; do
        src="$ROOT/../${entry%%:*}"
        [ -d "$src/game" ] || continue
        "$GODOT" --headless --path "$src" --import >/dev/null 2>&1 || true
    done
    ok "game assets imported"
fi

published_any=0
[ "${PUBLISHED_GAMES:-0}" -eq 1 ] && published_any=1

for entry in "${GAMES[@]}"; do
    [ "${PUBLISHED_GAMES:-0}" -eq 1 ] && break

    repo="${entry%%:*}"
    id="${entry#*:}"

    # tools/pack.gd directly rather than through `./server`: the launcher is generated
    # in step 7, after this one, and moving that step earlier would put a script naming
    # the runtime before the step that finds the runtime.
    pack_args=(--headless --path "$ROOT" --script res://tools/pack.gd --
               --content "$ROOT/content" --out "$ROOT/dist"
               --key "$ROOT/keys/content.key" --key-id local
               --id "$id" --source "$ROOT/../$repo")

    if "$GODOT" "${pack_args[@]}" >/dev/null 2>&1; then
        ok "$id"
        published_any=1
    else
        # Shown rather than swallowed: the run above is quiet so the install reads as
        # a list of steps, and a failure with no output is the one thing worse than
        # noise.
        "$GODOT" "${pack_args[@]}" || true
        die "could not publish $id from $repo" 4
    fi
done

if [ "$published_any" -eq 0 ]; then
    die "No games were published and none are in dist/." 4
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

# [b]And the key THIS box publishes with, or it cannot read what it just wrote.[/b]
#
# The step above copies the trust that ships with this repository -- our public key --
# and the games step generates a signing key of its own on a box that has none, then
# publishes every pack with it. Those are two different keys, so a fresh install found
# its own manifest on disk, failed the signature, fell through to the network, and died
# on
#
#     [forbidden] Could not get lobby's content. … <Code>AccessDenied</Code>
#
# an S3 error, on a server that had every byte it needed in dist/. Nothing about that
# message points at the key, and the packs verify perfectly against the key that made
# them.
#
# Merged rather than written, and run on every setup rather than only the first: an
# upgrade keeps the cfg/content.json it has, and a key added only on a first run would
# be missing from every box that already existed. Under its own id, beside ours, so the
# two coexist and neither replaces the other.
if [ -f keys/content.pub ] && [ -f cfg/content.json ] \
        && command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,io,sys
pub = io.open("keys/content.pub", encoding="utf-8").read().strip()
doc = json.load(io.open("cfg/content.json", encoding="utf-8"))
keys = doc.setdefault("trusted_keys", {})
if keys.get("local") == pub:
    sys.exit(1)
keys["local"] = pub
io.open("cfg/content.json", "w", encoding="utf-8").write(json.dumps(doc, indent=4) + "\n")'
    then
        ok "the signing key on this box is trusted by its server (cfg/content.json)"
        note "a BROWSER client needs it too: add keys/content.pub to client/content.json
    under trusted_keys before ./server export-web, or players get our packs only"
    fi
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
