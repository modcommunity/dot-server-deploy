#!/usr/bin/env bash
# Writes or checks addons.lock: the addon commits a server installs, and the ones the
# published client shell has to be exported from.
#
#   tools/addons-lock.sh write           newest release tag (v*) of every addon
#   tools/addons-lock.sh write v0.1.2    that tag for all of them
#   tools/addons-lock.sh check           the linked addons are at the lock, and clean
#
# [b]Why a lock at all.[/b] A server's addons used to be whatever each repository's main
# was on the day it was installed, and the shell a player connects with is whatever was
# exported last. Those drift, and a server ahead of the shell refuses the join with "This
# server needs a different build of the game client". setup.sh clones at the locked ref
# and moves its own clones there on --update; `check` is the other half, run before
# `./server export-web` / `export-native`, so the shell that gets published was built
# from the same commits the servers will install.
#
# The list of addons is setup.sh's ADDONS_ALL, read rather than repeated -- the rule
# package_check.sh learned the hard way.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/addons.lock"

mapfile -t REPOS < <(
    sed -n '/^ADDONS_ALL=(/,/)/p' "$ROOT/setup.sh" | grep -oE '(dot|zee)_[a-z0-9_]+' \
        | sed 's/^zee_weapons$/zee-dot-weapons/' | tr '_' '-' | sort -u
)

[ ${#REPOS[@]} -gt 0 ] || { echo "could not read ADDONS_ALL out of setup.sh" >&2; exit 2; }

# The same owner rule as setup.sh's repo_url: the addons are the organisation's, the one
# pack that is not is its author's.
url_of() {
    case "$1" in
        dot-*) printf 'https://github.com/modcommunity/%s.git\n' "$1" ;;
        *)     printf 'https://github.com/gamemann/%s.git\n' "$1" ;;
    esac
}

export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo

cmd_write() {
    local pin="${1:-}" repo tag failed=() tmp
    tmp="$(mktemp "$ROOT/.addons.lock.XXXXXX")"

    {
        echo "# The addon commits servers install and the client shell is exported from."
        echo "# Written by tools/addons-lock.sh write; read by setup.sh. repo<TAB>ref."
    } > "$tmp"

    for repo in "${REPOS[@]}"; do
        if [ -n "$pin" ]; then
            tag="$(git ls-remote --tags --refs "$(url_of "$repo")" "refs/tags/$pin" 2>/dev/null \
                | awk '{ sub("refs/tags/", "", $2); print $2 }')"
        else
            # Highest version, not most recent: sort -V puts v0.10.0 after v0.9.0.
            tag="$(git ls-remote --tags --refs "$(url_of "$repo")" 'v*' 2>/dev/null \
                | awk '{ sub("refs/tags/", "", $2); print $2 }' | sort -V | tail -1)"
        fi

        if [ -z "$tag" ]; then
            failed+=("$repo")
            continue
        fi

        printf '%s\t%s\n' "$repo" "$tag" >> "$tmp"
    done

    if [ ${#failed[@]} -gt 0 ]; then
        rm -f "$tmp"
        echo "no ${pin:-release} tag for: ${failed[*]}" >&2
        echo "addons.lock left as it was; a lock with holes would install those at main" >&2
        exit 1
    fi

    mv "$tmp" "$LOCK"
    echo "addons.lock: ${#REPOS[@]} repositories"
    awk '!/^#/ { print $2 }' "$LOCK" | sort | uniq -c | sed 's/^/  /'
}

cmd_check() {
    [ -f "$LOCK" ] || { echo "no addons.lock; run: tools/addons-lock.sh write" >&2; exit 2; }

    local repo name ref dir root want have bad=0

    for repo in "${REPOS[@]}"; do
        ref="$(awk -v r="$repo" '$1 == r { print $2 }' "$LOCK")"
        name="${repo//-/_}"
        [ "$repo" = "zee-dot-weapons" ] && name="zee_weapons"
        dir="$ROOT/addons/$name"

        if [ -z "$ref" ]; then
            echo "  --    $repo is not in the lock"
            bad=1
            continue
        fi

        if [ ! -e "$dir" ]; then
            echo "  --    $repo: addons/$name is not here"
            bad=1
            continue
        fi

        root="$(git -C "$(cd -P "$dir" && pwd)" rev-parse --show-toplevel 2>/dev/null)" || {
            # A vendored copy has no history to compare; say so rather than guess.
            echo "  ??    $repo: addons/$name is not a checkout (vendored?)"
            continue
        }

        have="$(git -C "$root" rev-parse HEAD)"
        # The COMMIT a tag names. An annotated tag lists twice -- the tag object, then
        # `^{}` for the commit it peels to -- and the tag object's hash is never what a
        # checkout's HEAD is, so taking the first line reported every clone as wrong.
        want="$(git -C "$root" rev-parse -q --verify "refs/tags/$ref^{commit}" 2>/dev/null \
            || git ls-remote "$(url_of "$repo")" "refs/tags/$ref" "refs/tags/$ref^{}" 2>/dev/null \
                | awk '/\^\{\}$/ { peeled = $1 } !first { first = $1 } END { print (peeled != "" ? peeled : first) }')"

        if [ -z "$want" ]; then
            echo "  !!    $repo: $ref does not exist"
            bad=1
        elif [ "$have" != "$want" ]; then
            echo "  !!    $repo is at ${have:0:9}, the lock says $ref (${want:0:9})"
            bad=1
        elif [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
            echo "  !!    $repo is at $ref with uncommitted changes"
            bad=1
        fi
    done

    if [ "$bad" -eq 0 ]; then
        echo "every addon is at its locked ref"
    else
        echo
        echo "a shell exported from this tree would not match what servers install."
        echo "check out the locked refs, or re-lock with: tools/addons-lock.sh write"
    fi

    exit "$bad"
}

case "${1:-}" in
    write) shift; cmd_write "${1:-}" ;;
    check) cmd_check ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
