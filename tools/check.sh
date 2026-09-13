#!/usr/bin/env bash
#
# Every script parses, the selftest runs, then the server boots for real.
#
#   tools/check.sh            everything
#   tools/check.sh --parse    the parse pass on its own
#
# The --import pass registers class_name globals. Without it every cross-file type
# reference fails and it looks like dozens of unrelated errors — and after adding any
# script with a NEW class_name it has to be re-run, or the identifier does not
# resolve, the scene fails to load, and the process HANGS rather than exiting.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

GODOT="${GODOT:-godot}"
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
fails=0

echo "importing"
"$GODOT" --headless --path . --import >/dev/null 2>&1

# This treats ANY unfiltered output as a parse failure, so the filter below is load
# bearing: shutdown noise that is not a parse error has to be matched exactly, and the
# engine is free to reword it. Godot 4.7 did -- "ObjectDB instances leaked at exit"
# became "5 ObjectDB instances were leaked at exit" -- and the guard then reported two
# clean scripts as parse failures, which is the way a guard stops being read.
# Hence ( were )? rather than the literal 4.4 wording.
echo "parsing"
while read -r f; do
    out="$("$GODOT" --headless --path . --check-only --script "res://${f#./}" 2>&1 \
        | grep -Ev '^(Godot Engine v|$)' \
        | grep -Eiv 'ObjectDB instances( were)? leaked|resources still in use|Pages in use exist at exit|at: (cleanup|clear|~PagedAllocator)')"
    if [ -n "$out" ]; then
        printf '  %sFAIL%s %s\n%s\n' "$RED" "$OFF" "$f" "$out"
        fails=$((fails + 1))
    fi
done < <(find host client examples -name '*.gd' 2>/dev/null | sort)

[ "$fails" -eq 0 ] && printf '  %sok%s   every script parses\n' "$GRN" "$OFF"

echo
echo "shell scripts"
for f in setup.sh tools/server.in docker-entrypoint.sh docker-healthcheck.sh tools/check.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then
        printf '  %sok%s   %s\n' "$GRN" "$OFF" "$f"
    else
        printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$f"; bash -n "$f"
        fails=$((fails + 1))
    fi
done

echo
echo "the copied games"
# setup.sh COPIES each built-in game's game/ and scenes/ out of its sibling repository
# rather than linking them -- they are compiled into this build, and
# content/lobby/game.yml says why. Both directories are gitignored here, so the only
# record of what they should contain is the siblings.
#
# The failure that allows is a stale copy: a game is fixed in its own repository,
# setup.sh is not re-run, and this project boots the old one. Nothing notices, because
# each repository's suite tests the copy it has -- the game's passes on the fix and this
# one passes on the code an operator actually deploys. They are different code and both
# are green.
#
# This is NOT the family's deliberate duplication. That rule is about a small check two
# addons both need being written twice so neither has to depend on the other. This is one
# game in two places that must be the same game, and the copy is generated.
#
# [b]The list is setup.sh's, and it is now READ from setup.sh rather than repeated.[/b]
# The line above said "it has to stay setup.sh's" and the two had already drifted: this
# one still named `dot-a-room` and `dot-2d-hungry` long after they were renamed to
# `game-simple-lobby` and `game-hungario`, so `checked_any` was 0, the staleness check
# reported "no game repositories beside this one" on a machine where all of them were,
# and every copied file went unchecked while the line printed looked like the
# release-tarball case working correctly. Two copies of one list is the bug the list was
# guarding against, one level up.
#
# Entries are `repo:label[:extra directories]`; the extra directories are top-level ones
# a game owns beyond game/ and scenes/ -- g2gfast's maps/ and avatars/ -- and they are
# copied by setup.sh, so they go stale exactly the same way.
mapfile -t GAME_ENTRIES < <(
    sed -n '/^GAMES=(/,/^)/p' setup.sh | grep -oE '"[^"]+"' | tr -d '"'
)

if [ ${#GAME_ENTRIES[@]} -eq 0 ]; then
    printf '  %sFAIL%s could not read the GAMES list out of setup.sh\n' "$RED" "$OFF"
    fails=$((fails + 1))
fi

GAME_REPOS=()
ALL_DIRS=(game scenes)
for entry in "${GAME_ENTRIES[@]}"; do
    GAME_REPOS+=("${entry%%:*}")
    rest="${entry#*:}"
    if [ "$rest" != "${rest%%:*}" ]; then
        for d in ${rest#*:}; do
            case " ${ALL_DIRS[*]} " in *" $d "*) ;; *) ALL_DIRS+=("$d") ;; esac
        done
    fi
done

drift=0
copied=0
checked_any=0

# Every file the siblings say should be here, and identical.
for repo in "${GAME_REPOS[@]}"; do
    src="../$repo"
    [ -d "$src/game" ] || continue
    checked_any=1

    for dir in "${ALL_DIRS[@]}"; do
        [ -d "$src/$dir" ] || continue

        # .uid files are deleted by setup.sh and regenerated per project, so they are
        # expected to differ and are not compared.
        while read -r rel; do
            copied=$((copied + 1))
            if [ ! -f "$dir/$rel" ]; then
                printf '  %sFAIL%s %s/%s is in %s and not here\n' \
                    "$RED" "$OFF" "$dir" "$rel" "$repo"
                drift=$((drift + 1))
            elif ! cmp -s "$src/$dir/$rel" "$dir/$rel"; then
                printf '  %sFAIL%s %s/%s is stale; re-run ./setup.sh\n' \
                    "$RED" "$OFF" "$dir" "$rel"
                drift=$((drift + 1))
            fi
        done < <(cd "$src/$dir" && find . \( -name '*.gd' -o -name '*.tscn' \) \
            | sed 's|^\./||' | sort)
    done
done

# --- No game may declare a class_name -------------------------------------
#
# [b]A mounted dot-cloud pack's globals are NOT registered in the host.[/b] So a game
# that is delivered rather than compiled in has every cross-file type reference fail --
# and fail the way that costs the most to find: the pack mounts, its scenes load, and
# nothing says a word until something tries to run one of its scripts.
#
# Every game here was converted to `const X := preload("relative/path.gd")` for exactly
# that reason. Nothing stops the next file from declaring a global again: it would
# compile, pass every suite, export, run, and break only once that game is delivered --
# which is a different deployment shape from the one anybody tests in, and this tree's
# most repeated bug.
#
# Checked against the SIBLING repositories rather than the vendored copies, so a game
# is told off in the repository where the line was written.
if [ "$checked_any" -eq 1 ]; then
    globals=0
    for repo in "${GAME_REPOS[@]}"; do
        [ -d "../$repo" ] || continue
        while read -r hit; do
            printf '  %sFAIL%s %s declares a class_name: %s
' \
                "$RED" "$OFF" "$repo" "$hit"
            globals=$((globals + 1))
        done < <(grep -rn '^class_name ' "../$repo" --include='*.gd' 2>/dev/null \
            | grep -v '/addons/' | sed "s|^../$repo/||")
    done

    if [ "$globals" -eq 0 ]; then
        printf '  %sok%s   no game declares a class_name, so all of them can be delivered
' \
            "$GRN" "$OFF"
    else
        printf '       a delivered game must reference its own files by path; see
'
        printf '       CLAUDE.md, "the one constraint that decides what a delivered game may look like"
'
        fails=$((fails + globals))
    fi
fi

# --- Absolute res:// references into a game's own files --------------------
#
# [b]The third form of the same bug, and the one still open.[/b] A delivered game
# mounts at `res://dot_cloud/<id>/<version>/`, so any reference it makes to its own
# content by an ABSOLUTE path resolves against the host project root instead -- which
# holds either somebody else's file or nothing at all.
#
#   script -> script by class_name    fixed: relative preloads
#   scene  -> script by ext_resource  fixed: DotCloudPublisher rewrites on publish
#   script -> anything by "res://…"   THIS. Not fixed.
#
# Reported rather than failed, because these are harmless while every game is
# builtin, and because a hard failure on work that has not been scheduled is a check
# people learn to skip. It is here so the number is visible and shrinks on purpose.
#
# `screenshots` is a tool's output directory and never shipped; `dot_cloud` is the
# mount prefix itself, which is a delivered game reading delivered content correctly.
if [ "$checked_any" -eq 1 ]; then
    absolute=0
    for repo in "${GAME_REPOS[@]}"; do
        [ -d "../$repo" ] || continue
        n=$(grep -rhoE '"res://[^"]+"' "../$repo" --include='*.gd' 2>/dev/null \
            | grep -v 'res://addons/' \
            | grep -v 'res://screenshots' \
            | grep -v 'res://dot_cloud' \
            | sort -u | wc -l)
        absolute=$((absolute + n))
        [ "$n" -gt 0 ] && printf '       %-20s %3d
' "$repo" "$n"
    done

    if [ "$absolute" -eq 0 ]; then
        printf '  %sok%s   no game names its own files by absolute path
' "$GRN" "$OFF"
    else
        printf '  %s~~%s   %d absolute res:// reference(s) into games own files
' \
            "$YLW" "$OFF" "$absolute"
        printf '       A DELIVERED game resolves these against the host project root, not
'
        printf '       its mount. Harmless while every game is kind: builtin. See CLAUDE.md,
'
        printf '       "the one constraint that decides what a delivered game may look like".
'
    fi
fi

# And nothing here that no sibling claims. A file left behind by a game that was removed
# from the list still compiles, still exports, and is still loadable by id -- so the
# server would happily serve a game this project no longer believes it has.
if [ "$checked_any" -eq 1 ]; then
    for dir in "${ALL_DIRS[@]}"; do
        [ -d "$dir" ] || continue

        while read -r rel; do
            found=0
            for repo in "${GAME_REPOS[@]}"; do
                [ -f "../$repo/$dir/$rel" ] && { found=1; break; }
            done
            if [ "$found" -eq 0 ]; then
                printf '  %sFAIL%s %s/%s is here and no game claims it\n' \
                    "$RED" "$OFF" "$dir" "$rel"
                drift=$((drift + 1))
            fi
        done < <(cd "$dir" && find . \( -name '*.gd' -o -name '*.tscn' \) \
            | sed 's|^\./||' | sort)
    done

    if [ "$drift" -eq 0 ]; then
        printf '  %sok%s   %d files match their game repositories\n' \
            "$GRN" "$OFF" "$copied"
    else
        fails=$((fails + drift))
    fi
else
    # A release tarball or the container's final stage has no siblings, and the copy it
    # was built with is the only one there will ever be. Nothing to compare against.
    printf '  %s--%s   no game repositories beside this one; staleness not checked\n' \
        "$RED" "$OFF"
fi

if [ "${1:-}" = "--parse" ]; then
    exit $((fails > 0))
fi

echo
echo "the selftest"
"$GODOT" --headless --path . res://examples/selftest.tscn || fails=$((fails + 1))

# The other suite: a real DotServer, and an admin changing the game under it. It is the
# only place the module swap runs -- dot-server changes the scene and tells the modules
# already loaded, it does not load one, so a multi-game server that got this wrong would
# boot perfectly and have no netcode on its second game.
echo
echo "changing games"
"$GODOT" --headless --path . res://examples/multigame.tscn || fails=$((fails + 1))

# And again with a REAL client attached over a real socket. An occupant is not a
# socket: multigame passes the same switch with one seated, and switching under a
# live client segfaulted the server -- twice over, once on the way in and once on
# the way out.
echo
echo "changing games under a live client"
"$GODOT" --headless --path . res://examples/live_switch.tscn || fails=$((fails + 1))

# The other half: a real DotServer, a real listener, the lobby loaded and a module in
# it. Everything the selftest cannot reach without starting one.
if [ -x ./server ]; then
    echo
    echo "booting"
    ./server check >/dev/null 2>&1 \
        && printf '  %sok%s   the server boots, loads the lobby, and shuts down\n' "$GRN" "$OFF" \
        || { printf '  %sFAIL%s ./server check\n' "$RED" "$OFF"; fails=$((fails + 1)); }
else
    printf '  %s--%s   ./server is not built; run ./setup.sh\n' "$RED" "$OFF"
fi

echo
if [ "$fails" -eq 0 ]; then
    printf '%sall checks passed%s\n' "$GRN" "$OFF"
else
    printf '%s%d failed%s\n' "$RED" "$fails" "$OFF"
fi
exit $((fails > 0))
