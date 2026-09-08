#!/usr/bin/env bash
#
# Is the server answering?
#
# Through its own query listener rather than by looking for a process: a Godot process
# that is up but has not opened its socket is exactly the failure this is for, and a
# `pgrep` cannot tell the two apart. dot-server answers the dot query protocol on the
# game port by default (sv_query), which is also what a server browser asks.
#
# bash's /dev/tcp is used rather than curl or nc so the runtime image needs neither.

set -uo pipefail
PORT="${TMC_PORT:-6064}"
exec 3<>"/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null || exit 1
exec 3<&- 3>&-
exit 0
