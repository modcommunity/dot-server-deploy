#!/usr/bin/env bash
# Every game's scripts must parse against the addons.lock tags, not the linked working trees.
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
    tool="$p/addons/dot_core/tools/dot_parse_all.gd"; [ -f "$tool" ] || { echo "FAIL $g: no dot_parse_all in the pinned dot-core"; fails=$((fails+1)); continue; }
    timeout 600 "$GODOT" --headless --path "$p" --import >/dev/null 2>&1
    (cd "$p" && find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | sed 's|^\./||' > "$W/$g.list")
    PARSE_LIST="$W/$g.list" timeout 900 "$GODOT" --headless --path "$p" --script res://addons/dot_core/tools/dot_parse_all.gd >"$W/$g.log" 2>&1
    bad="$(grep -aE 'PARSE_FAIL|SCRIPT ERROR|Parse Error|not declared|Could not find' "$W/$g.log" | head -5)"
    if ! grep -aq '^PARSED ' "$W/$g.log"; then bad="the parse tool did not finish"; fi
    if [ -n "$bad" ]; then echo "FAIL $g against the pinned addons:"; echo "$bad"; fails=$((fails+1)); else echo "ok   $g"; fi
done
exit $((fails > 0))
