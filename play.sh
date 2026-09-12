#!/usr/bin/env bash
#
# play.sh -- a game server and the browser client, on this machine, in one command.
#
#   ./play.sh                 start both and print the link
#   ./play.sh playground      start on that game instead of the default
#   ./play.sh down            stop what this started
#   ./play.sh status          what is running
#   ./play.sh games           what can be played
#
# WHY THIS EXISTS, BESIDE demo.sh
#
# `demo.sh` is the DEPLOYMENT: five servers, nginx terminating TLS, a public host, a
# separate registrable domain for the game, and a sudo step to install a listener. All
# of that is right for showing the platform to somebody and wrong for a developer who
# has just changed a line and wants to see it in a browser.
#
# There was no second path. The README carried the two commands as an example under
# `browser_check.mjs` and nothing ran them, so "check it in a browser" meant
# remembering a static file server, a port, and which of the two URLs takes `?server=`.
# This is those commands, with the three things that are easy to get wrong done for you.
#
# WHAT IT DOES NOT DO, deliberately
#
# It does not touch `../../../dev.sh`, which is the WEBSITE stack — website-city and
# friends on :3002. The two are independent: this serves the game from its own origin
# on :8099 and the site is not involved in `embed.html?server=`. Running both at once
# is the normal case and neither knows about the other.
#
# It serves plain HTTP on the loopback. That is fine here and is NOT fine anywhere
# else: an HTTPS page may not open a `ws://` socket, and the game needs its own
# registrable domain the moment it is framed by the site. See web/README.md.

set -uo pipefail
set -m

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

WEB_PORT="${TMC_PLAY_WEB_PORT:-8099}"
GAME_PORT="${TMC_PLAY_GAME_PORT:-6074}"
RUN_DIR="$ROOT/.play"
LOG_DIR="$RUN_DIR/logs"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'

say()  { printf '  %s\n' "$1"; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '    %swarn%s %s\n' "$YLW" "$OFF" "$1"; }
err()  { printf '    %sERR%s  %s\n' "$RED" "$OFF" "$1"; }
step() { printf '\n%s==>%s %s\n' "$BLD" "$OFF" "$1"; }
die()  { printf '\n  %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-2}"; }

port_busy() { ss -lnt 2>/dev/null | grep -q ":$1 "; }

# A port already held by a previous run of THIS script is not a conflict; one held by
# anything else is. Distinguishing them is what stops a second run reporting "busy" and
# leaving the user hunting for a process that is their own.
mine() {
    local f="$RUN_DIR/$1.pid"
    [ -f "$f" ] || return 1
    local p; p="$(cat "$f" 2>/dev/null)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

stop_one() {
    local name="$1" f="$RUN_DIR/$1.pid"
    [ -f "$f" ] || return 0
    local p; p="$(cat "$f" 2>/dev/null)"

    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        # The whole process group. `./server` is a wrapper around a Godot invocation,
        # so killing the wrapper alone leaves the engine holding the port — which is
        # the exact failure dev.sh's own notes describe for `npm run dev`.
        kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null
        sleep 1
        kill -9 -- "-$p" 2>/dev/null
        ok "stopped $name"
    fi

    rm -f "$f"
}

# --- down / status ---------------------------------------------------------

if [ "${1:-}" = "down" ] || [ "${1:-}" = "--stop" ]; then
    step "stopping"
    stop_one server
    stop_one web
    say ""
    exit 0
fi

if [ "${1:-}" = "status" ]; then
    step "status"
    mine server && ok "game server  pid $(cat "$RUN_DIR/server.pid")  ws://127.0.0.1:$GAME_PORT" \
                || warn "game server  not running"
    mine web    && ok "client       pid $(cat "$RUN_DIR/web.pid")     http://127.0.0.1:$WEB_PORT" \
                || warn "client       not running"
    say ""
    exit 0
fi

if [ "${1:-}" = "games" ]; then
    exec ./server games
fi

case "${1:-}" in
    -h|--help) sed -n '2,32p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
esac

GAME="${1:-}"

# --- the export ------------------------------------------------------------

step "the browser client"

mkdir -p "$LOG_DIR"

if [ ! -d game ] || [ -z "$(ls -A game 2>/dev/null)" ]; then
    die "No vendored games. Run ./setup.sh first." 4
fi

# [b]The vendored copy against the repositories it came from.[/b] setup.sh COPIES each
# game's game/ directory into this one; the addons beside it are symlinks and stay live,
# so it is only ever the game code that goes stale — and a stale copy exports cleanly,
# runs, and is last week's game. That is the single most expensive way to waste an hour
# here, so it is checked rather than remembered.
stale=""
for repo in game-simple-lobby game-hungario game-g2gfast game-playground game-arena; do
    [ -d "../$repo/game" ] || continue
    newer="$(find "../$repo/game" -newer game -type f -print -quit 2>/dev/null)"
    [ -n "$newer" ] && stale="$stale $repo"
done

if [ -n "$stale" ]; then
    warn "these game repositories are newer than the vendored copy:$stale"
    say "      ${DIM}./setup.sh    re-vendor them${OFF}"
fi

# The export is rebuilt when the game is newer than it. Same rule demo.sh uses, and the
# same exclusions: .godot/ and data/ change on every run and would rebuild a 110 MB
# export every time.
rebuild=0

if [ ! -f web/build/index.wasm ]; then
    warn "no export yet"
    rebuild=1
else
    newest="$(find game scenes maps npcs props client host addons \
                   -newer web/build/index.wasm -type f -print -quit 2>/dev/null)"
    [ -n "$newest" ] && { warn "the game is newer than the export ($newest)"; rebuild=1; }
fi

if [ "$rebuild" = "1" ]; then
    say "      building — this takes a minute"
    ./server export-web --base "http://127.0.0.1:$WEB_PORT/" >"$LOG_DIR/export.log" 2>&1 \
        || { err "the export failed; see $LOG_DIR/export.log"; exit 1; }
    ok "exported"
else
    ok "up to date"
fi

# [b]The loader's base, every run, rebuilt or not.[/b] The staleness test above compares
# the game against the WASM and the base is part of neither — so an export `demo.sh` built
# for the public game origin is "up to date" by that test and would serve a loader here
# pointing at a host this machine cannot reach. `stamp-loader` rewrites `tmc-loader.js`
# and nothing else, and is idempotent; `demo.sh` re-stamps for the same reason in the
# other direction.
#
# It matters less here than there — `embed.html?server=` does not go through the loader
# at all — but a build directory whose loader disagrees with the port it is served on is
# a trap for whoever opens `loader-test.html` next.
./server stamp-loader --base "http://127.0.0.1:$WEB_PORT/" >/dev/null 2>&1 \
    && ok "loader stamped for http://127.0.0.1:$WEB_PORT/"

# embed.html is the page that takes ?server= from the query string. Godot's own
# index.html does not, and one export has to serve every server.
cp -f web/embed.html web/build/embed.html
ok "embed.html in place"

# --- serving it ------------------------------------------------------------

step "serving"

if mine web; then
    ok "already serving on :$WEB_PORT"
elif port_busy "$WEB_PORT"; then
    die "Port $WEB_PORT is busy and it is not ours. Set TMC_PLAY_WEB_PORT." 3
else
    ( cd web/build && exec python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 ) \
        >"$LOG_DIR/web.log" 2>&1 &
    echo $! > "$RUN_DIR/web.pid"
    sleep 1
    mine web && ok "http://127.0.0.1:$WEB_PORT" || { err "the file server did not start"; exit 1; }
fi

# --- the server ------------------------------------------------------------

step "the game server"

if mine server; then
    ok "already running on :$GAME_PORT"
    say "      ${DIM}./play.sh down    to restart it on another game${OFF}"
elif port_busy "$GAME_PORT"; then
    die "Port $GAME_PORT is busy and it is not ours. Set TMC_PLAY_GAME_PORT." 3
else
    args=(--port "$GAME_PORT" --bind 127.0.0.1)
    [ -n "$GAME" ] && args+=(--game "$GAME")

    ./server "${args[@]}" >"$LOG_DIR/server.log" 2>&1 &
    echo $! > "$RUN_DIR/server.pid"

    # Waited on by the transport's own log line rather than by a fixed sleep: how long a
    # boot takes depends on the game and the machine, and a fixed wait is a check that
    # passes on an idle box and fails on a busy one.
    for _ in $(seq 1 60); do
        grep -q 'transport listening' "$LOG_DIR/server.log" 2>/dev/null && break
        mine server || break
        sleep 1
    done

    if ! grep -q 'transport listening' "$LOG_DIR/server.log" 2>/dev/null; then
        err "the server did not come up; last lines:"
        tail -12 "$LOG_DIR/server.log" | sed 's/^/      /'
        stop_one server
        exit 1
    fi

    # The game's name is logged AFTER the listener opens, so reading it on the same
    # line as the readiness check reads an empty string. Given a moment, and falling
    # back to what was asked for rather than printing nothing.
    running=""
    for _ in $(seq 1 20); do
        running="$(grep -oE 'game loaded game=[a-z_]+' "$LOG_DIR/server.log" \
                   | tail -1 | cut -d= -f2)"
        [ -n "$running" ] && break
        sleep 1
    done

    ok "ws://127.0.0.1:$GAME_PORT  (${running:-${GAME:-the default game}})"
fi

# --- where to go -----------------------------------------------------------

printf '\n%s  Ready.%s\n\n' "$BLD" "$OFF"
say "  http://127.0.0.1:$WEB_PORT/embed.html?server=ws://127.0.0.1:$GAME_PORT"
say ""
say "  ${DIM}./play.sh games     what else this server can run${OFF}"
say "  ${DIM}./play.sh status    what is up${OFF}"
say "  ${DIM}./play.sh down      stop both${OFF}"
say "  ${DIM}$LOG_DIR/server.log${OFF}"
say ""
