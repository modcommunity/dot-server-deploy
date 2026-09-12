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

exec ./server "$@" "${ARGS[@]}"
