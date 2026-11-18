#!/usr/bin/env bash
#
# The seeded cfg/server/content/overrides.yml names only the games on the server.
#
#   tools/check_overrides_seed.sh      exit 0 when it does, 1 naming each failure
#
# tools/server.in seeds the file from cfg.example/server/content/overrides.yml, which holds a section
# per shipped game. A server with one game used to get all of them and warned about each one it lacks.
# Arm it by making overrides_seed_filter print every section.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
good() { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

eval "$(sed -n '/^# overrides_seed_begin/,/^# overrides_seed_end/p' tools/server.in)"
abs() { printf '%s\n' "$1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
SRC=cfg.example/server/content/overrides.yml
sections() { awk '/^games:/{g=1;next} g&&/^[A-Za-z_]/{g=0} g&&/^  [A-Za-z0-9_.-]+:[[:space:]]*$/{k=$1;sub(/:$/,"",k);print k}'; }

CONTENT_DIR="$T/content"; mkdir -p "$T/content/gamemann/game-airdrift" "$T/content/mg-deathrun"
: > "$T/content/gamemann/game-airdrift/pack.json"

OPT_GAMES="gamemann/game-fatal-contact@0.1.70,gamemann/game-playlot"
got="$(overrides_seed_filter "$(overrides_seed_games)" < "$SRC" | sections | sort | tr '\n' ' ')"
[ "$got" = "game-airdrift game-fatal-contact game-playlot " ] && good "install list plus installed packs" || bad "sections kept: $got"

OPT_GAMES="gamemann/game-playlot"
out="$(overrides_seed_filter "$(overrides_seed_games)" < "$SRC")"
grep -qE '^  mg-' <<< "$out" && bad "a game not on the server was kept" || good "games not on the server dropped"
grep -q '^defaults:' <<< "$out" && grep -q '^games:' <<< "$out" && good "defaults: and games: kept" || bad "defaults:/games: lost"

OPT_GAMES=""; CONTENT_DIR="$T/none"
[ "$(overrides_seed_filter "$(overrides_seed_games)" < "$SRC" | sections | wc -l)" = "$(sections < "$SRC" | wc -l)" ] \
    && good "empty list keeps every game" || bad "empty list dropped sections"

# No section under a retired id (mg-deathrun and mg-prop-hunt are published as game-*).
for k in $(sections < "$SRC"); do
    case "$k" in mg-deathrun|mg-prop-hunt) bad "section $k is a retired game id" ;; esac
done
good "no section under a retired game id"

[ "$fails" -eq 0 ]
