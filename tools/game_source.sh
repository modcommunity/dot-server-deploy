# Where a game repository is, for every script here that needs one.
#
#   . tools/game_source.sh
#   game_source game-arena && echo "$GAME_SRC"
#
# SOURCED, never executed. It defines two variables and one function and runs nothing.
#
# WHY IT IS A FILE
#
# Four scripts need this answer -- setup.sh publishes packs out of these repositories,
# play.sh decides whether a pack is stale against them, tools/check.sh greps them for
# the two things a delivered game may not contain, and tools/package_check.sh stages
# them. The search order used to be `../$repo`, written out in each of them, and a
# fifth copy of a list is how this project's list bugs start: tools/check.sh named the
# games by their OLD directory names long after they were renamed, reported "no game
# repositories beside this one", and compared nothing, on every run, looking exactly
# like the release-tarball case working correctly.
#
# THE ORDER, AND WHY THE PARENT DIRECTORY IS STILL IN IT
#
#   1. $GAMES_DIR      a shared directory, named with --games-dir or TMC_GAMES_DIR.
#                      A box running several servers keeps one set of checkouts and
#                      says so.
#   2. games/          this project's own, which is where setup.sh clones a missing
#                      one and where it links a sibling. The default, and the answer
#                      for anything that is not a developer checkout.
#   3. ..              beside this project, which is where they all used to go and is
#                      what dot-bootstrap still makes. A developer tree has them right
#                      there and must not grow a second copy of each, so this stays a
#                      fallback rather than becoming a migration.
#
# `game/` rather than the directory itself: an empty directory left behind by an
# interrupted clone is not a game, and reporting it as one produces a publish failure
# three steps later that names the publisher.

# The project root, from this file rather than from the caller's cwd -- play.sh runs
# from the root, tools/check.sh cds to it, and a sourced file that trusted either would
# be a file that works in one of them.
TMC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Already set by setup.sh, which parses --games-dir. Anything else picks up the
# environment variable, so one export covers a whole session.
GAMES_DIR="${GAMES_DIR:-${TMC_GAMES_DIR:-}}"
GAMES_REPOS="${GAMES_REPOS:-$TMC_ROOT/games}"

## Resolve one game repository, setting:
##
##   GAME_SRC   the directory that holds it, resolved through any link
##   GAME_KIND  dir | repos | sibling -- which of the three above it was found in
##
## Returns 1 when this machine does not have it anywhere. That return is what drives
## setup.sh's clone: what is fetched is what is ACTUALLY absent rather than the list of
## games in the abstract, so a box that already has them fetches nothing.
game_source() {
    local repo="$1" dir
    GAME_SRC=""; GAME_KIND=""

    for dir in ${GAMES_DIR:+"$GAMES_DIR"} "$GAMES_REPOS" "$TMC_ROOT/.."; do
        [ -d "$dir/$repo/game" ] || continue
        # Resolved, so games/<repo> -> ../../<repo> and the sibling itself are one
        # answer rather than two. A caller comparing timestamps or greping for a
        # class_name against both would otherwise do it twice.
        GAME_SRC="$(cd "$dir/$repo" && pwd -P)"
        case "$dir" in
            "$GAMES_REPOS")   GAME_KIND="repos" ;;
            "$TMC_ROOT/..")   GAME_KIND="sibling" ;;
            *)                GAME_KIND="dir" ;;
        esac
        return 0
    done

    return 1
}

## The `repo:content directory` list, read out of setup.sh.
##
## [b]setup.sh is the one place that knows what this project is made of.[/b] Three
## hand-kept copies of this list have drifted here already; this is the same read
## tools/check.sh was doing, moved next to the search order it goes with.
game_entries() {
    sed -n '/^GAMES=(/,/^)/p' "$TMC_ROOT/setup.sh" | grep -oE '"[^"]+"' | tr -d '"'
}
