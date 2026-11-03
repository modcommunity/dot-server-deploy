#!/usr/bin/env bash
# Every game's scripts must parse against the addons.lock tags, not the linked working trees.
# Addons a game links beyond the lock are added at their newest v* tag (else HEAD) and listed.
#   tools/check_pinned_parse.sh [GAME...]   default: every games/<dir> that is a git repo with a project.godot
# A lock older than a game's main fails to compile on the server, and ./server check only
# sees it at boot (2026-11-03: dot-weapon v0.1.36 under arena calling a v0.1.37 method).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
SIB="${TMC_SIBLINGS:-$ROOT/..}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
bash "$ROOT/tools/check-pinned.sh" "$W/addons" || { echo "FAIL the pinned set did not build" >&2; exit 1; }
games=("$@")
[ ${#games[@]} -gt 0 ] || while read -r g; do games+=("$(basename "$g")"); done < <(ls -d "$ROOT"/games/*/ 2>/dev/null)
fails=0
for g in "${games[@]}"; do
    src="$SIB/$g"; [ -d "$src/.git" ] && [ -f "$src/project.godot" ] || continue
    p="$W/$g"; mkdir -p "$p"
    git -C "$src" archive HEAD | tar -x -C "$p"
    mkdir -p "$p/addons"; for a in "$W"/addons/*; do ln -sfn "$a" "$p/addons/$(basename "$a")"; done
    # Addons the game links but addons.lock does not pin (weapon packs, natural-disasters) are their own
    # repos: take the newest v* tag, else HEAD, and print which; an unavailable one is reported, not hidden.
    extra=""
    for l in "$src"/addons/*; do
        [ -L "$l" ] || continue; d="$(basename "$l")"; [ -e "$p/addons/$d" ] && continue
        repo="$(basename "$(dirname "$(dirname "$(readlink -f "$l")")")")"
        ref="$(git -C "$SIB/$repo" tag -l 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -1)"
        if [ -z "$ref" ]; then ref=HEAD; echo "WARN $g: $repo has no v* tag, using HEAD"; fi
        if [ -d "$SIB/$repo/.git" ] && git -C "$SIB/$repo" archive "$ref" "addons/$d" 2>/dev/null | tar -x -C "$p"; then
            extra="$extra $repo@$ref"
        else
            echo "FAIL $g: needs $repo ($d) which is not available at $ref"; fails=$((fails+1)); continue 2
        fi
    done
    [ -z "$extra" ] || echo "     $g also pins:$extra"
    tool="$p/addons/dot_core/tools/dot_parse_all.gd"; [ -f "$tool" ] || { echo "FAIL $g: no dot_parse_all in the pinned dot-core"; fails=$((fails+1)); continue; }
    # A crash or hang during import leaves a half-built class cache, so say so rather than parse on.
    timeout 600 "$GODOT" --headless --path "$p" --import >"$W/$g.import.log" 2>&1; irc=$?
    if [ "$irc" -ge 124 ] || grep -aqE 'handle_crash|Program crashed|Segmentation fault' "$W/$g.import.log"; then
        echo "FAIL $g: --import died (exit $irc; 124 = timeout, 139 = SIGSEGV)"
        grep -aE -A12 'handle_crash|Program crashed' "$W/$g.import.log" | head -20
        fails=$((fails+1)); continue
    fi
    (cd "$p" && find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | sed 's|^\./||' > "$W/$g.list")
    PARSE_LIST="$W/$g.list" timeout 900 "$GODOT" --headless --path "$p" --script res://addons/dot_core/tools/dot_parse_all.gd >"$W/$g.log" 2>&1
    bad="$(grep -aE 'PARSE_FAIL|SCRIPT ERROR|Parse Error|not declared|Could not find' "$W/$g.log" | head -5)"
    if ! grep -aq '^PARSED ' "$W/$g.log"; then bad="the parse tool did not finish"; fi
    if [ -n "$bad" ]; then echo "FAIL $g against the pinned addons:"; echo "$bad"; fails=$((fails+1)); else echo "ok   $g"; fi
done
exit $((fails > 0))
