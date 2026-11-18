#!/usr/bin/env bash
# What a client shell carries, from the explicit list in tools/shell-addons.list (see there for the owner rule).
#
#   tools/shell_lock.sh lock <addons.lock>   the lock a shell export carries: comments and the listed repositories only
#   tools/shell_lock.sh dirs                 the addon directories a shell carries (dot-x is addons/dot_x), one per line
#   tools/shell_lock.sh check <addons.lock>  only the list's own rules (below); prints nothing when they hold
#
# Fails (exit 3, the reason on stderr) when the list names anything but a dot-* addon, or when the lock names a dot-* addon
# the list does not: the shell would leave out an addon nobody decided to leave out. A non-dot lock line (a game addon such
# as fc-weapons) is for servers and is dropped from the shell's lock. SHELL_ADDONS_LIST names another list (the
# check's own tests).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list="${SHELL_ADDONS_LIST:-$here/shell-addons.list}"

die() { printf 'shell_lock.sh: %s\n' "$1" >&2; exit 3; }

[ -f "$list" ] || die "no $list"
mapfile -t allowed < <(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$list")
[ "${#allowed[@]}" -gt 0 ] || die "$list names no addon"

for repo in "${allowed[@]}"; do
    case "$repo" in
        dot-*) ;;
        *) die "$list names $repo, which is not a dot-* addon. A shell carries no game addon; $repo reaches players as an overlay pack." ;;
    esac
done

listed() {
    local r
    for r in "${allowed[@]}"; do [ "$r" = "$1" ] && return 0; done
    return 1
}

check_lock() {
    local lock="$1" repo missing=""
    [ -f "$lock" ] || die "no $lock"
    while IFS=$'\t' read -r repo _; do
        repo="${repo%%#*}"; repo="${repo//[[:space:]]/}"
        [ -n "$repo" ] || continue
        case "$repo" in dot-*) listed "$repo" || missing="$missing $repo" ;; esac
    done < "$lock"
    [ -z "$missing" ] || die "$lock names dot-* addons that $list does not:$missing. Add each one the shell should carry to $list."
}

case "${1:-}" in
    lock)
        [ $# -eq 2 ] || die "usage: shell_lock.sh lock <addons.lock>"
        check_lock "$2"
        awk -F'\t' -v keep="$(printf '%s\n' "${allowed[@]}")" '
            BEGIN { n = split(keep, k, "\n"); for (i = 1; i <= n; i++) ok[k[i]] = 1 }
            /^[[:space:]]*(#|$)/ || ($1 in ok)
        ' "$2"
        ;;
    dirs)
        for repo in "${allowed[@]}"; do printf '%s\n' "${repo//-/_}"; done
        ;;
    check)
        [ $# -eq 2 ] || die "usage: shell_lock.sh check <addons.lock>"
        check_lock "$2"
        ;;
    *) die "usage: shell_lock.sh lock <addons.lock> | dirs | check <addons.lock>" ;;
esac
