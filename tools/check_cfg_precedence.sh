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

# Every startup variable is also a server.yml key (docs/configuration.md has the table). Flag > file > TMC_* variable, for all of them.
D="$T/cfg2"
mkdir -p "$D/server" "$D/content"
cp examples/fixtures/zee_minigames/cfg/server/server.yml "$D/server/server.yml"
# The dry run shell-escapes the commas of a list (`a\,b`); the checks below read it unescaped.
runD() { env TMC_NO_INSTALL=1 TMC_AUTO_UPDATE=never "$@" ./server --config "$D" --dry-run 2>&1 | tr -d '\\'; }
out="$(runD TMC_NAME=egg TMC_MAX_PLAYERS=12 TMC_GAME=other TMC_GAMES=egg/one)"
check "the MiniGames file: hostname: beats TMC_NAME (an alias of sv_name)" bash -c '! grep -q -- "--name" <<<"$1"' _ "$out"
check "  and says so" grep -q "INFO sv_name: cfg/server/server.yml wins over TMC_NAME" <<<"$out"
check "  sv_maxplayers: beats TMC_MAX_PLAYERS" bash -c '! grep -q -- "--max-players" <<<"$1"' _ "$out"
check "  game: beats TMC_GAME" bash -c '! grep -q -- "--game other" <<<"$1"' _ "$out"
check "  games: beats TMC_GAMES" bash -c '! grep -q -- "--games egg/one" <<<"$1"' _ "$out"
check "  the games list is passed on, mg-deathrun once" bash -c 'grep -o -- "--games [^ ]*" <<<"$1" | grep -q "^--games gamemann/mg-look-at-me,gamemann/mg-deathrun,gamemann/game-prop-hunt,gamemann/mg-smash-copter,gamemann/mg-buses-of-hell,gamemann/mg-dangerous-delivery,gamemann/mg-wipeout$"' _ "$out"
check "  no warning that game: is missing from games:" bash -c '! grep -q "matches no entry" <<<"$1"' _ "$out"
printf 'game: nowhere\ngames: [a/b]\n' > "$D/server/server.yml"
out="$(runD)"
check "a bare game: the list lacks is warned about" grep -q "game: nowhere matches no entry of games" <<<"$out"
printf 'game: c/d\ngames: [a/b]\n' > "$D/server/server.yml"
out="$(runD)"
check "an owner/repo game: the list lacks is added to it" grep -q -- "--games a/b,c/d" <<<"$out"
printf 'games: gamemann/mg-one\ngame: mg-one\n' > "$D/server/server.yml"
out="$(runD)"
check "one id and a bare game: that matches it" grep -q -- "--games gamemann/mg-one" <<<"$out"
printf 'sv_games: [x/y, x/y]\n' > "$D/server/server.yml"
out="$(runD)"
check "the old sv_games: spelling feeds the install list, deduped" grep -q -- "--games x/y\( \|$\)" <<<"$out"
printf 'sv_name: "a"\n' > "$D/server/server.yml"
for pair in "net_port:28000:TMC_PORT:--port" "net_bind_ip:10.0.0.1:TMC_BIND:--bind" "map:de_x:TMC_MAP:--map" "query_port:28001:TMC_QUERY_PORT:--query-port" \
        "a2s_port:28002:TMC_A2S_PORT:--a2s-port" "query_bind_ip:10.0.0.2:TMC_QUERY_BIND:--query-bind" "sv_web_loader:v1:TMC_WEB_LOADER:--web-loader" "sv_web_build:b1:TMC_WEB_BUILD:--web-build"; do
    IFS=: read -r key val envname flag <<<"$pair"
    printf '%s: %s\n' "$key" "$val" > "$D/server/server.yml"
    out="$(runD "$envname=other")"
    check "$key: in the file beats $envname" bash -c '! grep -q -- "$2 other" <<<"$1"' _ "$out" "$flag"
    printf 'sv_name: "a"\n' > "$D/server/server.yml"
    out="$(runD "$envname=other")"
    check "$envname applies when no file sets $key" grep -q -- "$flag other" <<<"$out"
done
# cache_bytes: flag > file > TMC_CACHE_BYTES like the rest; unset is unlimited (no flag at all); a value that is not a byte count stops the launcher.
printf 'cache_bytes: 20G\n' > "$D/server/server.yml"
out="$(runD TMC_CACHE_BYTES=1G)"
check "cache_bytes: in the file beats TMC_CACHE_BYTES" bash -c '! grep -q -- "--cache-bytes 1G" <<<"$1"' _ "$out"
check "  and says so" grep -q "INFO cache_bytes: cfg/server/server.yml wins over TMC_CACHE_BYTES" <<<"$out"
printf 'sv_name: "a"\n' > "$D/server/server.yml"
out="$(runD TMC_CACHE_BYTES=512M)"
check "TMC_CACHE_BYTES applies when no file sets cache_bytes" grep -q -- "--cache-bytes 512M" <<<"$out"
out="$(runD)"
check "nothing set passes no ceiling (the host's default, unlimited)" bash -c '! grep -q -- "--cache-bytes" <<<"$1"' _ "$out"
out="$(env TMC_NO_INSTALL=1 TMC_AUTO_UPDATE=never ./server --config "$D" --dry-run --cache-bytes 0 2>&1)"
check "--cache-bytes 0 on the command line is passed on" grep -q -- "--cache-bytes 0" <<<"$out"
for badv in lots -5 1.5G; do
    out="$(runD TMC_CACHE_BYTES="$badv")"
    check "a bad cache_bytes ($badv) fails loudly" grep -q "cache_bytes.*'$badv', not a whole number of bytes" <<<"$out"
done
check "the host summary names it" grep -q '"cache    : %s"' host/tmc_config.gd
check "the configuration table documents it" grep -q '`TMC_CACHE_BYTES` | `cache_bytes:`' docs/configuration.md

# The launcher's own settings: auto_update, channel, games_mode, no_install, verbose. A bad value is refused naming where it came from.
printf 'channel: stable\n' > "$D/server/server.yml"
out="$(runD TMC_CHANNEL=latest)"
check "channel: in the file beats TMC_CHANNEL" grep -q "INFO channel: cfg/server/server.yml wins over TMC_CHANNEL" <<<"$out"
printf 'channel: sideways\n' > "$D/server/server.yml"
out="$(runD)"
check "a bad channel: fails loudly" grep -q "channel.*latest or stable, not 'sideways'" <<<"$out"
printf 'auto_update: sometimes\n' > "$D/server/server.yml"
out="$(env TMC_NO_INSTALL=1 ./server --config "$D" --dry-run 2>&1)"
check "a bad auto_update: fails loudly" grep -q "when-needed, always or never, not 'sometimes'" <<<"$out"
printf 'games_mode: purge\n' > "$D/server/server.yml"
out="$(runD)"
check "a bad games_mode: fails loudly" grep -q "hide, remove or keep, not 'purge'" <<<"$out"
printf 'verbose: maybe\n' > "$D/server/server.yml"
out="$(runD)"
check "a bad verbose: fails loudly" grep -q "verbose is 'maybe', not true or false" <<<"$out"
printf 'verbose: false\nno_install: true\n' > "$D/server/server.yml"
out="$(env TMC_VERBOSE=1 TMC_AUTO_UPDATE=never ./server --config "$D" --dry-run 2>&1)"
check "verbose: false in the file beats TMC_VERBOSE=1" bash -c '! grep -q -- "--verbose" <<<"$1"' _ "$out"
check "and says so" grep -q "INFO verbose: cfg/server/server.yml wins over TMC_VERBOSE" <<<"$out"
printf 'no_install: perhaps\n' > "$D/server/server.yml"
out="$(runD)"
check "a bad no_install: fails loudly" grep -q "no_install is 'perhaps', not true or false" <<<"$out"

# The egg and the entrypoint write nothing into cfg/.
check "the egg has no config files to rewrite" python3 -I -c 'import json,sys; sys.exit(json.loads(json.load(open("deploy/pterodactyl-egg.json"))["config"]["files"]) != {})'
check "the entrypoint passes no TMC_* as a flag" bash -c '! grep -qE "ARGS\+=\(--" docker-entrypoint.sh'

echo
[ "$fails" -eq 0 ] && echo "cfg precedence: all ok" || echo "cfg precedence: $fails failed"
[ "$fails" -eq 0 ]
