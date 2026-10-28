#!/usr/bin/env bash
#
# A cfg file always beats the egg's TMC_* variables, and nothing writes the variables into a file.
#
#   tools/check_cfg_precedence.sh      exit 0 when it holds, 1 naming each failure
#
# Drives `./server --dry-run` against a scratch config directory (no engine, no network).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fails=0
good() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then good "$what"; else bad "$what"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
C="$T/cfg"
mkdir -p "$C/server" "$C/content"
printf 'sv_name: "From the file"\nsv_allow_web: 0\n' > "$C/server/server.yml"

FLAGS=()
run() { env TMC_NO_INSTALL=1 TMC_AUTO_UPDATE=never "$@" ./server --config "$C" --dry-run "${FLAGS[@]+"${FLAGS[@]}"}" 2>&1; }
before="$(sha256sum "$C/server/server.yml")"

out="$(run TMC_NAME="From the egg" TMC_ALLOW_WEB=1 TMC_MAX_PLAYERS=12)"
check "a key the file sets beats TMC_NAME" bash -c '! grep -q -- "--name" <<<"$1"' _ "$out"
check "and says which source won (INFO)" grep -q "INFO sv_name: cfg/server/server.yml wins over TMC_NAME" <<<"$out"
check "TMC_ALLOW_WEB loses to sv_allow_web in the file" bash -c '! grep -q -- "+sv_allow_web" <<<"$1"' _ "$out"
check "a key no file sets takes the variable" grep -q -- "--max-players 12" <<<"$out"
FLAGS=(--name Flagged)
out="$(run TMC_NAME=x)"
FLAGS=()
check "a flag beats the file" grep -q -- "--name Flagged" <<<"$out"
printf 'net_port: 28123\n' > "$C/net.yml"
out="$(run TMC_PORT=29999)"
check "net.yml's net_port beats TMC_PORT" bash -c '! grep -q -- "--port" <<<"$1"' _ "$out"
rm -f "$C/net.yml"
# An old egg rewrites the flat cfg/server.yml every start; the host ignores it beside cfg/server/server.yml.
printf 'sv_maxplayers: 99\n' > "$C/server.yml"
out="$(run TMC_MAX_PLAYERS=12)"
check "an ignored flat cfg/server.yml does not drop TMC_MAX_PLAYERS" grep -q -- "--max-players 12" <<<"$out"
rm -f "$C/server.yml"

# The same run again: still the file, so it is every boot and not the first.
out="$(run TMC_NAME="From the egg")"
check "the second boot still lets the file win" bash -c '! grep -q -- "--name" <<<"$1"' _ "$out"
check "the run left the operator's file byte for byte" test "$before" = "$(sha256sum "$C/server/server.yml")"

# A download list in cfg/content/games.yml beats TMC_GAMES; a rotation-only file does not.
printf 'rotation: main\n' > "$C/content/games.yml"
out="$(run TMC_GAMES=arena)"
check "a rotation-only games.yml does not take TMC_GAMES' place" grep -q -- "--games arena" <<<"$out"
printf 'entries: [game-arena]\n' > "$C/content/games.yml"
out="$(run TMC_GAMES=arena)"
check "a games.yml with entries beats TMC_GAMES" bash -c '! grep -q -- "--games" <<<"$1"' _ "$out"

# Updates refresh cfg/addon and cfg/game and never touch cfg/server or cfg/content.
mkdir -p "$C/addon/dot_log" "$C/server/addon/dot_log"
printf 'log_level: edited-by-hand\n' > "$C/addon/dot_log/log.yml"
printf 'log_level: operator\n' > "$C/server/addon/dot_log/log.yml"
cp "$C/content/games.yml" "$T/games.before"
tools/cfg_sync.sh "$PWD" "$C" >/dev/null
check "an update overwrites the shipped default" cmp -s cfg.example/addon/dot_log/log.yml "$C/addon/dot_log/log.yml"
check "an update never touches cfg/server/" grep -q "operator" "$C/server/addon/dot_log/log.yml"
check "nor cfg/content/" cmp -s "$T/games.before" "$C/content/games.yml"
check "nor the operator's server.yml" test "$before" = "$(sha256sum "$C/server/server.yml")"

# The egg and the entrypoint write nothing into cfg/.
check "the egg has no config files to rewrite" python3 -I -c 'import json,sys; sys.exit(json.loads(json.load(open("deploy/pterodactyl-egg.json"))["config"]["files"]) != {})'
check "the entrypoint passes no TMC_* as a flag" bash -c '! grep -qE "ARGS\+=\(--" docker-entrypoint.sh'

echo
[ "$fails" -eq 0 ] && echo "cfg precedence: all ok" || echo "cfg precedence: $fails failed"
[ "$fails" -eq 0 ]
