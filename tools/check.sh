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
echo "the published games"
# Every game is PUBLISHED now, not copied: setup.sh turns each sibling repository into a
# signed pack in dist/ and this build contains none of them. The staleness that allows is
# the same shape as the one the copy allowed, one layer up -- a game is fixed in its own
# repository, setup.sh is not re-run, and this server keeps serving the old pack. Nothing
# notices, because the game's own suite tests the fix and this one tests the pack, and
# they are different code and both are green.
#
# [b]The list is setup.sh's, and it is READ from setup.sh rather than repeated.[/b] The
# line here used to say "it has to stay setup.sh's" and the two had already drifted: this
# one still named `dot-a-room` and `dot-2d-hungry` long after they were renamed, so
# nothing was checked at all and the line printed looked like the release-tarball case
# working correctly. Two copies of one list is the bug the list was guarding against, one
# level up.
#
# Entries are `repo:content directory`. The content directory is not always the pack's
# name -- hungario is three game ids over one `content_id: hungry` -- so the pack name is
# read from the descriptor, which is the same file the publisher reads it from.
# The read itself is in tools/game_source.sh now, beside the search order that answers
# the other half of the question -- where each of those repositories actually is.
. tools/game_source.sh
mapfile -t GAME_ENTRIES < <(game_entries)

if [ ${#GAME_ENTRIES[@]} -eq 0 ]; then
    printf '  %sFAIL%s could not read the GAMES list out of setup.sh\n' "$RED" "$OFF"
    fails=$((fails + 1))
fi

GAME_REPOS=()
for entry in "${GAME_ENTRIES[@]}"; do GAME_REPOS+=("${entry%%:*}"); done

# [b]What this build deliberately left out.[/b] `./setup.sh --only-games` /
# `--skip-games` writes the repositories it did not build into dist/.skipped-games, and
# without reading it the loop below fails every one of them for having a source and no
# pack -- which on a developer box, where all six repositories are beside this project,
# is five failures for one supported flag. A check that cries wolf on a documented
# option is a check people learn to scroll past.
#
# setup.sh DELETES that file on any run that filtered nothing, so this can never excuse
# a pack that was supposed to exist: an unfiltered build has no marker and every game is
# checked, which is the arrangement every box that never passes the flag is in.
SKIPPED_GAMES=()
[ -f dist/.skipped-games ] && mapfile -t SKIPPED_GAMES < dist/.skipped-games

game_was_skipped() {
    local repo="$1" s
    for s in ${SKIPPED_GAMES[@]+"${SKIPPED_GAMES[@]}"}; do
        [ "$s" = "$repo" ] && return 0
    done
    return 1
}

drift=0
checked_any=0
skipped_note=""

for entry in "${GAME_ENTRIES[@]}"; do
    repo="${entry%%:*}"
    dir="${entry#*:}"

    # games/, a --games-dir, or beside this project -- whichever this machine has. It
    # was `../$repo` and nothing else, so the moment setup.sh started cloning into
    # games/ this check would have gone quiet on a real deployment and said so in the
    # words a release tarball uses, which is the branch nobody looks twice at.
    game_source "$repo" || continue
    src="$GAME_SRC"

    # Before checked_any, on purpose: a build that excluded every game but one must not
    # be able to claim it checked the five it was told to leave alone.
    if game_was_skipped "$repo"; then
        skipped_note="$skipped_note $dir"
        continue
    fi

    checked_any=1

    yml="content/$dir/game.yml"
    if [ ! -f "$yml" ]; then
        printf '  %sFAIL%s setup.sh publishes %s but there is no %s\n' \
            "$RED" "$OFF" "$dir" "$yml"
        drift=$((drift + 1))
        continue
    fi

    # Delivered, or the pack is beside the point.
    if ! grep -qE '^kind: pack$' "$yml"; then
        printf '  %sFAIL%s %s is not kind: pack, but setup.sh publishes it\n' \
            "$RED" "$OFF" "$yml"
        drift=$((drift + 1))
        continue
    fi

    # The pack's name, from the descriptor rather than from the directory.
    cid="$(grep -E '^content_id:' "$yml" | head -1 | sed -E 's/^content_id:[[:space:]]*//' \
        | sed -E 's/[[:space:]]*#.*$//' | tr -d '"')"
    [ -n "$cid" ] || cid="$dir"

    manifest="dist/$cid/manifest.json"
    if [ ! -f "$manifest" ]; then
        printf '  %sFAIL%s %s is not published (no %s); re-run ./setup.sh\n' \
            "$RED" "$OFF" "$dir" "$manifest"
        drift=$((drift + 1))
        continue
    fi

    # [b]Newer source than pack is the whole check.[/b] Comparing CONTENTS would not
    # work: the publisher rewrites every res:// reference in a .tscn onto the mount
    # prefix, so a correctly published file is deliberately not byte-identical to its
    # source. A timestamp says the same thing about staleness and says it about every
    # file type, including the imported ones a byte comparison could not reach either.
    newer="$(find "$src" \
        \( -name .git -o -name .godot -o -name addons -o -name examples \
           -o -name tools -o -name screenshots -o -name imported \) -prune -o \
        -type f \( -name '*.gd' -o -name '*.tscn' -o -name '*.tres' \) \
        -newer "$manifest" -print 2>/dev/null | head -3)"

    if [ -n "$newer" ]; then
        printf '  %sFAIL%s %s is stale; re-run ./setup.sh or ./server pack %s --source %s\n' \
            "$RED" "$OFF" "$manifest" "$dir" "$src"
        printf '%s\n' "$newer" | sed 's|^|         newer: |'
        drift=$((drift + 1))
    fi
done

if [ "$checked_any" -eq 0 ]; then
    # [b]The wording is asserted by tools/package_check.sh.[/b] That check exists because
    # this branch is the one a developer checkout can never reach, and a notice that
    # quietly stops being printed is indistinguishable from a check that quietly stops
    # running -- which is exactly how the old copy-staleness guard went stale.
    printf '  %sok%s   no game repositories on this machine; staleness not checked\n' \
        "$GRN" "$OFF"
elif [ "$drift" -eq 0 ]; then
    printf '  %sok%s   every game is published and its pack is newer than its source\n' \
        "$GRN" "$OFF"
else
    fails=$((fails + drift))
fi

# Printed whatever the verdict was, and printed at all because "every game is published"
# over a build missing two of them is true and misleading in the same line.
[ -n "$skipped_note" ] && printf '  %sok%s   not checked, left out of this build:%s\n' \
    "$GRN" "$OFF" "$skipped_note"

# --- Nothing may be vendored into this build any more ----------------------
#
# The five games used to be copied into one game/ and one scenes/ here. They are not,
# and a directory left behind from a checkout that predates the change is a build that
# still contains a game -- which for `client/shell.gd` means a stale copy could win over
# the delivered one for anybody on this build and not for anybody else.
stray=0
for d in game scenes maps avatars npcs props textures; do
    [ -d "$d" ] || continue
    printf '  %sFAIL%s %s/ is left over from when games were vendored; remove it\n' \
        "$RED" "$OFF" "$d"
    stray=$((stray + 1))
done

if [ "$stray" -eq 0 ]; then
    printf '  %sok%s   no game is vendored into this build\n' "$GRN" "$OFF"
else
    fails=$((fails + stray))
fi

echo
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
        game_source "$repo" || continue
        while read -r hit; do
            printf '  %sFAIL%s %s declares a class_name: %s
' \
                "$RED" "$OFF" "$repo" "$hit"
            globals=$((globals + 1))
        done < <(grep -rn '^class_name ' "$GAME_SRC" --include='*.gd' 2>/dev/null \
            | grep -v '/addons/' | sed "s|^$GAME_SRC/||")
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
        game_source "$repo" || continue

        # The directories this game actually SHIPS. A path whose first segment is not
        # one of them -- `res://audio` in a game with no audio/ -- names the HOST's
        # file and is correct as it stands: rebasing it would point into a pack where
        # nothing exists. Only what would really break is counted.
        owned=" $(cd "$GAME_SRC" && find . -maxdepth 1 -type d \
            ! -name '.' ! -name '.git' ! -name '.godot' ! -name 'addons' \
            ! -name 'examples' ! -name 'tools' ! -name 'screenshots' \
            | sed 's|^\./||' | tr '\n' ' ')"

        n=0
        while IFS= read -r hit; do
            first="${hit#\"res://}"
            first="${first%%/*}"
            first="${first%\"}"
            case "$owned" in *" $first "*) n=$((n + 1)) ;; esac
        done < <(
            # Shipped code only: examples/ and tools/ are harnesses and never travel
            # in a pack. Comments are prose. A reference already wrapped in
            # `XPaths.rebase(...)` is the FIXED form and must not be counted -- doing
            # so made this number rise from 92 to 102 when the fix landed, which reads
            # as a regression and is the exact opposite. A measure that moves the wrong
            # way is worse than no measure.
            find "$GAME_SRC" -name '*.gd' -not -path '*/addons/*' -not -path '*/.godot/*' \
                -not -path '*/examples/*' -not -path '*/tools/*' -print0 2>/dev/null \
            | xargs -0 -r sed -E 's/[A-Za-z0-9_]*Paths\.rebase\("res:\/\/[^"]*"\)//g' \
            | grep -vE '^[[:space:]]*#' \
            | grep -oE '"res://[^"]+"' \
            | sort -u
        )

        absolute=$((absolute + n))
        [ "$n" -gt 0 ] && printf '       %-20s %3d\n' "$repo" "$n"
    done

    if [ "$absolute" -eq 0 ]; then
        printf '  %sok%s   every game resolves its own files relative to its mount\n' \
            "$GRN" "$OFF"
    else
        printf '  %s~~%s   %d reference(s) a delivered game would resolve wrongly\n' \
            "$YLW" "$OFF" "$absolute"
        printf '       Wrap them in <Game>Paths.rebase(), or make an `extends` relative.\n'
        printf '       See CLAUDE.md, "the one constraint that decides what a delivered\n'
        printf '       game may look like".\n'
    fi
fi

# [b]The "is here and no game claims it" check went with the vendoring.[/b] It walked
# game/ and scenes/ looking for a file no sibling owned -- a game removed from the list
# whose files stayed behind, still compiling, still exporting, still loadable by id. Those
# directories do not exist now, and the check that replaced it is stricter: any of them
# existing AT ALL is a failure, reported above, because a vendored copy could win over the
# delivered one for players on this build and for nobody else.

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

# And a real client in a DELIVERED game, which is a different question from a real client
# in the lobby. Everything above connects to a_room, a 2D lobby small enough that a mount
# that half worked would still look right. This one connects to a 3D game whose map is
# rebuilt every round out of a pack: the first boot of it found a path the publisher had
# already rewritten being rebased a second time, a combat manager setting itself up twice,
# and lag compensation reporting as unwired on a server where it works. None of those are
# reachable from inside the game's own project, where its files are at res:// and its
# globals are registered.
echo
echo "a real client in a delivered game"
"$GODOT" --headless --path . res://examples/smash_client.tscn || fails=$((fails + 1))

# And the REAL shell, connected twice. Everything above connects at most once, and a
# second connection in one session put the game on screen with an empty world -- the
# dropped link was still in the tree, so the replacement was renamed and every RPC the
# server sent resolved to the dead one. Nothing errored anywhere.
echo
echo "reconnecting after the server restarts"
"$GODOT" --headless --path . res://examples/reconnect.tscn || fails=$((fails + 1))

# Parties on a real server. The booking chains onto dot_ban_source, and a game's module
# puts dot-moderation there when it loads -- so the first `changelevel` after boot took
# every booking off the seam, in silence, until the host started putting it back. Armed:
# with the rechain disabled, two of its checks fail.
echo
echo "parties, bookings and party chat"
"$GODOT" --headless --path . res://examples/party_live.tscn < /dev/null || fails=$((fails + 1))

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
