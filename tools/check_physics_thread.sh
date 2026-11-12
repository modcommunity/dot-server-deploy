#!/usr/bin/env bash
# ./server's sv_physics_thread: off writes nothing, on (server.yml or TMC_PHYSICS_THREAD) writes
# override.cfg with run_on_separate_thread, off again removes only a file the script wrote.
#   tools/check_physics_thread.sh   exit 0 when all hold, 1 otherwise
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fails=0
chk() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

fn="$(sed -n '/^cfg_value() /p;/^abs() /p;/^info() /p;/^warn() /p;/^apply_physics_thread() {/,/^}/p' tools/server.in)"
chk "server.in defines apply_physics_thread" 'grep -q "^apply_physics_thread()" tools/server.in'
run() ( cd "$T" && PROJECT="$T" CONFIG_DIR=cfg OFF= YLW= DIM= && eval "$fn" && apply_physics_thread >/dev/null 2>&1 )
T="$(mktemp -d)"; mkdir -p "$T/cfg/server"
run;                                  chk "default: no override.cfg" '[ ! -e "$T/override.cfg" ]'
echo "sv_physics_thread: 1  # on" > "$T/cfg/server/server.yml"
run;                                  chk "server.yml on: thread setting written" 'grep -q "^3d/run_on_separate_thread=true" "$T/override.cfg"'
echo "sv_physics_thread: 0" > "$T/cfg/server/server.yml"
run;                                  chk "server.yml off: our file removed" '[ ! -e "$T/override.cfg" ]'
rm "$T/cfg/server/server.yml"
TMC_PHYSICS_THREAD=1 run;             chk "env on, no cfg key: written" '[ -f "$T/override.cfg" ]'
echo "sv_physics_thread: 0" > "$T/cfg/server/server.yml"
TMC_PHYSICS_THREAD=1 run;             chk "cfg key wins over the env" '[ ! -e "$T/override.cfg" ]'
rm "$T/cfg/server/server.yml"; echo "[mine]" > "$T/override.cfg"
TMC_PHYSICS_THREAD=1 run;             chk "an operator's own override.cfg is left alone" '[ "$(cat "$T/override.cfg")" = "[mine]" ]'
rm -f "$T/override.cfg"
echo "sv_physics_engine: jolt" > "$T/cfg/server/server.yml"
run;                                  chk "engine jolt: engine written, no thread line" 'grep -q "^3d/physics_engine=\"JoltPhysics3D\"" "$T/override.cfg" && ! grep -q run_on_separate "$T/override.cfg"'
printf 'sv_physics_engine: jolt\nsv_physics_thread: 1\n' > "$T/cfg/server/server.yml"
run;                                  chk "engine and thread together" 'grep -q JoltPhysics3D "$T/override.cfg" && grep -q "^3d/run_on_separate_thread=true" "$T/override.cfg"'
echo "sv_physics_engine: godot" > "$T/cfg/server/server.yml"
run;                                  chk "engine godot: our file removed" '[ ! -e "$T/override.cfg" ]'
rm "$T/cfg/server/server.yml"
chk "the example documents the key" 'grep -q "sv_physics_thread" cfg.example/server/server.yml'
chk "the operator doc documents it" 'grep -q "sv_physics_thread" docs/operator-config.md'
chk "the example documents the engine" 'grep -q "sv_physics_engine" cfg.example/server/server.yml'
chk "the operator doc documents the engine" 'grep -q "sv_physics_engine" docs/operator-config.md'
rm -rf "$T"
[ "$fails" -eq 0 ] && echo "physics thread: all checks passed" || echo "physics thread: $fails failed"
exit $((fails > 0))
