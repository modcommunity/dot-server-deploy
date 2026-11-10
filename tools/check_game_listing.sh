#!/usr/bin/env bash
#
# tools/game_listing.py: writes the file from game.yml + README, keeps a hand-edited one, --check
# catches a missing file and a pack.id that is not game.yml's content_id.
#
#   tools/check_game_listing.sh      exit 0 when they hold, 1 naming each failure
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TOOL="$PWD/tools/game_listing.py"
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }

command -v python3 >/dev/null || { echo "  skip game_listing (python3 missing)"; exit 0; }
G="$W/mg-demo"; mkdir -p "$G"
printf 'content_id: gamemann/game-demo  # differs from the repo name on purpose\nname: Demo Run\nkind: pack\n' >"$G/game.yml"
printf '# Demo\n\nIntro [**Dot**](https://x.invalid) built on Godot. In this 3D game, players **race** on [tracks](https://x.invalid). Second one. This is inspired by tv. Third.\n' >"$G/README.md"

python3 -I "$TOOL" --check "$G" >/dev/null 2>&1 && bad "--check passes with no file" || ok "--check fails when the file is missing"
python3 -I "$TOOL" "$G" >/dev/null 2>&1 && [ -f "$G/deployment/game-listing.json" ] && ok "writes the file" || bad "did not write the file"
f="$G/deployment/game-listing.json"
if command -v jq >/dev/null; then
    [ "$(jq -r .pack.id "$f")" = gamemann/game-demo ] && ok "pack.id is content_id" || bad "pack.id wrong"
    [ "$(jq -r .listing.description "$f")" = "Players race on tracks. Second one." ] && ok "description from README, markdown stripped" || bad "description: $(jq -r .listing.description "$f")"
    [ "$(jq -c '.listing|[.tmcKind,.graphicsType,.tags]' "$f")" = '["MINIGAME","THREE_D",["3D","Multiplayer","Minigame"]]' ] && ok "mg-* is a 3D minigame" || bad "kind/tags wrong"
fi
python3 -I "$TOOL" --check "$G" >/dev/null 2>&1 && ok "--check passes on its own output" || bad "--check fails on its own output"
sed -i 's/"description": "[^"]*"/"description": "Hand edited."/' "$f"
python3 -I "$TOOL" "$G" >/dev/null 2>&1; grep -q 'Hand edited' "$f" && ok "an existing file is kept" || bad "an existing file was overwritten"
python3 -I "$TOOL" --check "$G" >/dev/null 2>&1 && ok "--check accepts a hand-edited description" || bad "--check rejects a hand edit"
sed -i 's#gamemann/game-demo#gamemann/mg-demo#' "$f"
python3 -I "$TOOL" --check "$G" >/dev/null 2>&1 && bad "--check passes a wrong pack.id" || ok "--check fails on a pack.id that is not content_id"
python3 -I "$TOOL" --force "$G" >/dev/null 2>&1; python3 -I "$TOOL" --check "$G" >/dev/null 2>&1 && ok "--force rewrites it" || bad "--force did not repair"

[ "$fails" -eq 0 ] && exit 0
exit 1
