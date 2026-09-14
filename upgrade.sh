#!/usr/bin/env bash
#
# Bring a deployed server up to date, in the order that actually works.
#
#   ./upgrade.sh                pull everything, rebuild, verify
#   ./upgrade.sh --check        ...and boot the server once before you restart it
#   ./upgrade.sh --clean-cache  also drop the downloaded content cache
#   ./upgrade.sh --dry-run      say what would be pulled and change nothing
#
# WHY THIS EXISTS AND IS NOT A LINE IN THE README
#
# It was a line in the README -- `git pull && ./setup.sh --no-import` -- and that line
# was wrong in three separate ways once the games became delivered packs, each of which
# cost a production evening and none of which reported an error:
#
#   * It pulled `../dot-*` and never `../game-*`. The games are separate clones and
#     setup.sh republishes a pack from each one on every run, so the documented upgrade
#     published whatever commit those happened to be on. A stale game still declares
#     `class_name`, and a pack whose scripts do that mounts and is DEAD -- the scene
#     loads, the script does not attach, and the operator gets "No G2GGame is
#     registered" against a module that is fine.
#   * `--no-import` left `.godot/global_script_class_cache.cfg` stale. A delivered
#     game's scripts are parsed against that cache AT RUNTIME, so an addon pulled after
#     it was built is a class the pack cannot see: `Could not find type "DotTimerRun"`
#     inside a mounted script, a module that will not load, a server with no `map`
#     command, and a grey screen. The host's own scripts are already cached, so the
#     server boots and looks healthy.
#   * A `git pull` that stops -- a conflicting `.uid`, a local edit -- is a repository
#     left behind while the rest move. The loop reported nothing.
#
# All three are handled here. The point of a script rather than a longer README section
# is that an operator reaches for the shortest thing that looks right, and on a bad
# evening that is whatever they remember.
#
# IT DOES NOT RESTART THE SERVER. This repository does not know how yours is
# supervised -- systemd, demo.sh, a terminal, a container -- and a script that guesses
# is a script that kills the wrong thing. It says what to do and stops.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$PWD"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; OFF=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$BLD" "$OFF" "$1"; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$1"; }
die()  { printf '\n    %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }

DO_CHECK=0
CLEAN_CACHE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check)       DO_CHECK=1; shift ;;
        --clean-cache) CLEAN_CACHE=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        *)             die "unknown argument: $1

  ./upgrade.sh [--check] [--clean-cache] [--dry-run]" 2 ;;
    esac
done

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || die "this is not a git checkout, so there is nothing to pull.

  A release tarball upgrades by being replaced." 2

# --- 1. Every repository this build is made of -----------------------------
#
# [b]Reported by name, not counted.[/b] A pull that stops leaves one repository behind
# while the rest move, which is the worst of both: the build is neither the old one nor
# the new one, and the failure surfaces later as something unrelated.

step "pulling"

FAILED=()
PULLED=()

## Fast-forward one checkout, with or without tracking configured.
##
## [b]These clones have no upstream.[/b] `bootstrap.sh` clones them and `push-github.sh`
## pushes the CURRENT branch by name rather than relying on tracking -- deliberately,
## because several sit on a task branch and `git push origin main` from one of those
## pushes a stale ref. The cost is that a bare `git pull --ff-only` answers
##
##     There is no tracking information for the current branch.
##
## for every repository in the tree, which a loop that only checks the exit status reads
## as fifty failures. Naming the remote and the branch is the same thing push-github.sh
## does and works either way.
_pull_ff() {
    local dir="$1" branch

    git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 1

    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] || return 1

    git -C "$dir" pull --ff-only --quiet origin "$branch" >/dev/null 2>&1
}


# Every checkout pull_one has already been given, so one repository reached by two
# names -- games/<repo> is a link to ../<repo> in a developer tree -- is pulled once
# rather than twice over the network.
SEEN=()

pull_one() {
    local dir="$1" name before after seen
    name="$(basename "$dir")"

    [ -d "$dir/.git" ] || return 0

    for seen in ${SEEN[@]+"${SEEN[@]}"}; do
        [ "$seen" = "$dir" ] && return 0
    done
    SEEN+=("$dir")

    before="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    %s--%s   %s (at %s)\n' "$YLW" "$OFF" "$name" "$before"
        return 0
    fi

    if ! _pull_ff "$dir"; then
        FAILED+=("$name")
        return 0
    fi

    after="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
    [ "$before" != "$after" ] && PULLED+=("$name $before..$after")
    return 0
}

# The siblings first, this repository last. Pulling ourselves changes the script that
# is running -- bash reads a script as it goes, so a pull mid-run can resume at a byte
# offset that means something else now -- so the rest of the work happens in a fresh
# process, below.
# Both homes of an addon: this project's own clones, which is where setup.sh puts them
# by default, and the parent directory, which is a developer checkout and every box set
# up before that default changed. A machine has one or the other and the glob that
# matches nothing expands to a name no directory has, which pull_one skips.
#
# An addon linked out of a --addons-dir somewhere else is NOT pulled here, and that is
# the point of sharing one: it is updated once, by hand, for every server that links to
# it -- `./setup.sh --update` pulls whatever the addons actually resolved to.
#
# The games have the same two homes and a third: games/ is where setup.sh clones or
# links them now, the parent directory is where they used to go, and a --games-dir
# somewhere else is not pulled here for the same reason a shared addons directory is
# not. games/<repo> is a LINK to the sibling in a developer checkout, so `-d` matches
# both names for one repository -- pull_one is given the resolved path, and pulling the
# same checkout twice would print it twice and do nothing the second time.
for d in "$ROOT"/addons/.repos/dot-* "$ROOT"/../dot-* \
         "$ROOT"/games/game-* "$ROOT"/../game-*; do
    [ -d "$d" ] && pull_one "$(cd "$d" && pwd -P)"
done

if [ ${#FAILED[@]} -gt 0 ]; then
    warn "${#FAILED[@]} repository(ies) would not fast-forward:"
    printf '           %s\n' "${FAILED[@]}"
    printf '
       Usually a local edit, or a .uid Godot reminted. Look, then either
       `git -C ../<repo> stash` or `git -C ../<repo> checkout -- .` and re-run.
       A build made of two vintages is the thing this refuses to produce.\n'
    die "refusing to rebuild from a partial pull" 4
fi

if [ "$DRY_RUN" -eq 0 ]; then
    if [ ${#PULLED[@]} -gt 0 ]; then
        printf '    %sok%s   %d sibling(s) updated:\n' "$GRN" "$OFF" "${#PULLED[@]}"
        printf '           %s\n' "${PULLED[@]}"
    else
        ok "every sibling was already up to date"
    fi
fi

# --- 2. This repository, and then start again ------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    printf '    %s--%s   %s (at %s)\n' "$YLW" "$OFF" "dot-server-deploy" \
        "$(git -C "$ROOT" rev-parse --short HEAD)"
    printf '\n  dry run: nothing was pulled, rebuilt or verified\n\n'
    exit 0
fi

if [ "${TMC_UPGRADE_REEXEC:-0}" -ne 1 ]; then
    before="$(git -C "$ROOT" rev-parse --short HEAD)"

    if ! _pull_ff "$ROOT"; then
        warn "this repository would not fast-forward; leaving it where it is"
        printf '           %s\n' "git -C $ROOT status"
        die "refusing to rebuild from a partial pull" 4
    fi

    after="$(git -C "$ROOT" rev-parse --short HEAD)"

    if [ "$before" != "$after" ]; then
        ok "dot-server-deploy $before..$after"
        # [b]Re-exec, because this script has just been rewritten under itself.[/b]
        # Everything below runs from the version that was pulled, which is also the
        # version that knows what the new setup.sh needs.
        export TMC_UPGRADE_REEXEC=1
        exec "$ROOT/upgrade.sh" \
            $([ "$DO_CHECK" -eq 1 ] && echo --check) \
            $([ "$CLEAN_CACHE" -eq 1 ] && echo --clean-cache)
    fi

    ok "dot-server-deploy was already up to date"
fi

# --- 3. Rebuild -------------------------------------------------------------
#
# `--no-import` is safe here BECAUSE setup.sh overrides it when the class cache is
# older than the addons -- which is exactly the case a pull creates. Without that
# override this flag is the grey-screen bug above, and the flag would have to go.

step "rebuilding"

"$ROOT/setup.sh" --no-import --no-clone || die "setup.sh failed" 5

# --- 4. The downloaded content cache ----------------------------------------
#
# Not cleared by default, and that is a change from the advice that was going round
# during the incident this script came out of. The assembled pack is keyed on a
# fingerprint of its file list now, so republishing one version with different files
# produces a different pack and the stale one is simply never reached. Clearing costs a
# re-download of everything the server serves.
#
# `--clean-cache` is still here for the case where you want to be certain, and for a
# box that was running the version where the key was only id and version.

if [ "$CLEAN_CACHE" -eq 1 ]; then
    step "content cache"
    rm -rf "$ROOT/data/content_cache"
    ok "cleared; the next boot re-downloads what it needs"
fi

# --- 5. Prove it before you restart anything --------------------------------

if [ "$DO_CHECK" -eq 1 ]; then
    step "verifying"

    # [b]Capped, and with stdin closed.[/b] A verification step that can hang forever is
    # worse than no verification: the operator is left staring at a silent terminal with
    # a server they have not restarted, which is the one moment they are least able to
    # judge whether waiting is right. `./server check` boots a real server, and a real
    # server has a stdin console -- give it a terminal and it sits waiting for a command
    # that is never typed. `</dev/null` is the EOF that turns it off.
    #
    # Five minutes is far more than the forty seconds this takes, because the first run
    # after an upgrade may be downloading content it has not got.
    if timeout 300 "$ROOT/server" check >/dev/null 2>&1 </dev/null; then
        ok "the server boots, loads its game and shuts down"
    elif [ $? -eq 124 ]; then
        die "./server check did not finish within five minutes.

  Run it directly and watch where it stops:
      ./server check" 6
    else
        die "./server check failed -- run it directly to see why:

      ./server check" 6
    fi
fi

printf '\n  %sUpgraded.%s Restart the server however you run it -- this script does not,\n' \
    "$BLD" "$OFF"
printf '  because it cannot know whether that is systemd, demo.sh, a container or a\n'
printf '  terminal, and stopping the wrong thing is worse than stopping nothing.\n\n'
