#!/usr/bin/env bash
#
# Generates a configuration on first run, then execs the server.
#
# cfg/ is a volume, so it is empty the first time and populated every time after. That
# is exactly setup.sh's "never overwrite a config file that exists" rule, reached from
# the direction a container reaches it: an image rebuild must not throw away the
# settings and the RCON password an operator has been using.
#
# What it is populated FROM is cfg.example/, which is in the image because it is in the
# repository. cfg/ is not in either: it is one deployment's answers, and the volume is
# where they live.

set -uo pipefail
cd /srv/tmc || exit 1

if [ ! -f cfg/server.yml ]; then
    printf '\n  First run: writing cfg/ into the mounted volume.\n'
    # --no-import because the image was imported at build time, and --no-check because
    # a first boot is what is about to happen anyway.
    ./setup.sh --godot /usr/local/bin/godot --no-import
fi

# Environment overrides, for the compose file. Deliberately only the three that a
# container genuinely has to decide from outside -- a port mapping and a name are
# properties of the deployment, not of the game.
#
# There is no TMC_RCON_PASSWORD and there will not be: an environment variable is
# readable by every other process in the container and shows up in `docker inspect`,
# which is exactly why DotConfig refuses secrets from the environment.
ARGS=()
[ -n "${TMC_PORT:-}" ]        && ARGS+=(--port "$TMC_PORT")
[ -n "${TMC_NAME:-}" ]        && ARGS+=(--name "$TMC_NAME")
[ -n "${TMC_MAX_PLAYERS:-}" ] && ARGS+=(--max-players "$TMC_MAX_PLAYERS")
[ -n "${TMC_GAME:-}" ]        && ARGS+=(--game "$TMC_GAME")

# --- Saying goodbye on `docker stop` -------------------------------------------------
#
# `docker stop` sends SIGTERM, and headless Godot answers it by dying: DotServer.shutdown
# never runs, so session reporting (auth.yml session_report_url) never posts its closing
# report and the issuer holds every player for the lease. The container has no stdin for
# the `quit` console command to arrive on, so this script makes one: a FIFO this shell
# holds open for writing (fd 3, read-write so opening it cannot block), fed to the server
# as stdin with sv_stdin_console_pipes on. TERM/INT become `quit` down it.
#
# fd 3 is CLOSED straight after the `quit`. A pipe reader that is never woken makes the
# process hang inside its own exit (see dot_stdin_console.gd, read_pipes); closing the
# last writer is what ends the read. The server is a child here, not exec'd, so this
# script is PID 1 and forwards the signal -- and returns the server's own status.
FIFO=$(mktemp -u /tmp/tmc-stdin.XXXXXX)
mkfifo "$FIFO" || exec ./server "$@" "${ARGS[@]}"
exec 3<>"$FIFO"

# The environment layer of DotServerConfig, not a `+sv_stdin_console_pipes` console line:
# the line runs after the stdin reader has already decided, and it is too late. Exported
# only for the child, and only on this path (see the mkfifo fallback above).
DOT_SERVER_STDIN_CONSOLE_PIPES=1 ./server "$@" "${ARGS[@]}" <"$FIFO" 3>&- &
CHILD=$!

goodbye() {
    printf 'quit\n' >&3
    exec 3>&-
}
trap goodbye TERM INT

# wait returns early (128+signal) when the trap fires, so loop until the child is gone.
STATUS=0
while kill -0 "$CHILD" 2>/dev/null; do
    wait "$CHILD"
    STATUS=$?
done
rm -f "$FIFO"
exit "$STATUS"
