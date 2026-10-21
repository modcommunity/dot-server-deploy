# shellcheck shell=bash
# Helpers shared by setup.sh, deploy.sh and deploy/modify.sh. Sourced, never run.
#
# One copy because two drifted copies of cfg_set is how a wizard writes a key one way
# and the installer reads it another. The caller defines the colours (RED GRN YLW DIM
# BLD OFF), ASSUME_YES and SUDO before using these: each script prints in its own
# indentation, and these only ask, read and write.

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
        '"'*)
            # Up to the closing quote, reading \" and \\ as DotYaml does: a name with
            # a quote in it is written escaped, and stopping at the first quote reads
            # it back as half a name.
            local out="" c
            v="${v#\"}"
            while [ -n "$v" ]; do
                c="${v:0:1}"; v="${v:1}"
                case "$c" in
                    \\) out+="${v:0:1}"; v="${v:1}" ;;
                    '"') break ;;
                    *) out+="$c" ;;
                esac
            done
            v="$out" ;;
        *)  v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}" ;;
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
# Keys whose value is never printed: a plan, a step's report and a log are all read
# by more people than the config is.
cfg_is_secret() { case "$1" in *password*|*secret*|*token*) return 0 ;; esac; return 1; }

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

    # The value goes through the environment, not `awk -v`, because -v processes
    # backslash escapes: the \" in a quoted name arrives as a bare quote and the line
    # written is `sv_name: "a "b""`, which no YAML reader accepts.
    tmp="$(mktemp)" || return 1
    CFG_SET_VALUE="$value" awk -v k="$key" '
        BEGIN { v = ENVIRON["CFG_SET_VALUE"] }
        !done && index($0, k ":") == 1 {
            rest = substr($0, length(k) + 2)
            c = ""
            if (rest ~ /^[[:space:]]*"/) {
                # The closing quote is the first one not escaped.
                i = index(rest, "\"") + 1
                while (i <= length(rest)) {
                    ch = substr(rest, i, 1)
                    if (ch == "\\") { i += 2; continue }
                    if (ch == "\"") break
                    i++
                }
                tail = substr(rest, i + 1)
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

# One helper, three package managers, and the same shape fetch-godot.sh uses for the
# library the runtime needs. Nothing here builds a distro list beyond the three names
# a package has.
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

# The firewall this box has switched on, if any: ufw, firewalld, or nothing. Only an
# ACTIVE one counts -- opening ports in a firewall nobody enabled is a change with no
# effect that still shows up in somebody's audit.
firewall_active() {
    if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi '^Status: active'; then
        printf 'ufw'
    elif command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state 2>/dev/null | grep -q running; then
        printf 'firewalld'
    else
        return 1
    fi
}

# firewall_allow ufw 443 tcp  /  firewall_close firewalld 6065 tcp. firewalld needs the
# --reload to apply a --permanent rule, so it is done per call: a wizard that opens one
# port and dies before a batched reload has opened nothing.
firewall_allow() {
    case "$1" in
        ufw)       $SUDO ufw allow "$2/${3:-tcp}" >/dev/null 2>&1 ;;
        firewalld) $SUDO firewall-cmd --permanent --add-port="$2/${3:-tcp}" >/dev/null 2>&1 \
                       && $SUDO firewall-cmd --reload >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}
firewall_close() {
    case "$1" in
        ufw)       $SUDO ufw delete allow "$2/${3:-tcp}" >/dev/null 2>&1 ;;
        firewalld) $SUDO firewall-cmd --permanent --remove-port="$2/${3:-tcp}" >/dev/null 2>&1 \
                       && $SUDO firewall-cmd --reload >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}
