#!/usr/bin/env bash
# `./server check` must FAIL a boot in which a script did not load.
#
#   tools/check_boot_failures.sh        exit 0 when every broken boot below was refused
#
# [b]Why this exists.[/b] On a fresh clone `./setup.sh --only-games <one game>` left
# `addons/dot_game` unlinked, and `./server check` logged
# `Could not find base class "DotGameModule"` and then printed `selftest ok`. A script
# that fails to parse takes no exit path: Godot logs it, hands back a script nothing can
# instantiate, and the boot carries on to the end. Nothing else here ever builds a boot
# that is broken this way, so nothing noticed.
#
# Each case is a one-game content directory whose game cannot compile, booted by the real
# launcher. The broken scripts are written into `res://.boot_check/` for the length of the
# run (gitignored, and a dot-directory so the editor never imports them) because a builtin
# game's scene must be a res:// path -- and not kept under examples/, where every script
# is required to parse.
#
#   scene   the server scene's own script extends a class nobody registered. The module
#           loads; ONLY the host's script watch (host/tmc_script_watch.gd) can see this.
#   module  the game's module does -- the reported case, an addon that was never linked.

set -u
cd "$(dirname "$0")/.." || exit 1

RED=$'\e[31m'; GRN=$'\e[32m'; OFF=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; OFF=""; }

[ -x ./server ] || { printf '  %s--%s   ./server is not built; run ./setup.sh\n' "$RED" "$OFF"; exit 1; }

FIX=".boot_check"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$FIX" "$WORK"; }
trap cleanup EXIT

mkdir -p "$FIX"

cat > "$FIX/scene.gd" <<'GD'
extends DotNoSuchBootCheckBase
GD

cat > "$FIX/module.gd" <<'GD'
extends DotNoSuchBootCheckModule
GD

cat > "$FIX/server.tscn" <<'TSCN'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://.boot_check/scene.gd" id="1"]

[node name="BootCheck" type="Node"]
script = ExtResource("1")
TSCN

cat > "$FIX/plain.tscn" <<'TSCN'
[gd_scene format=3]

[node name="BootCheck" type="Node"]
TSCN

# case <name> <scene> <module> <what>
fails=0
case_() {
    local name="$1" scene="$2" module="$3" what="$4"
    local content="$WORK/$name/content" log="$WORK/$name.log"

    mkdir -p "$content/broken" "$WORK/$name/data"
    {
        printf 'name: Boot check (%s)\nversion: 0.0.1\nkind: builtin\ndefault: true\n' "$name"
        printf 'scene: %s\n' "$scene"
        [ -n "$module" ] && printf 'module: %s\n' "$module"
    } > "$content/broken/game.yml"

    # Capped: a boot that hangs is a failure too, not a check that never returns.
    timeout 300 ./server check --no-install --content "$content" --data "$WORK/$name/data" \
        < /dev/null > "$log" 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && ! grep -q '^selftest ok$' "$log"; then
        printf '  %sok%s   %s: refused (exit %d)\n' "$GRN" "$OFF" "$what" "$rc"
    else
        printf '  %sFAIL%s %s: exit %d%s\n' "$RED" "$OFF" "$what" "$rc" \
            "$(grep -q '^selftest ok$' "$log" && echo ', and it printed "selftest ok"')"
        sed 's/^/       /' "$log" | grep -E 'SCRIPT ERROR|ERROR:|selftest' | head -8
        fails=$((fails + 1))
    fi
}

case_ scene  "res://$FIX/server.tscn" ""                  "a server scene whose script does not compile"
case_ module "res://$FIX/plain.tscn"  "res://$FIX/module.gd" "a game module whose base class is unlinked"

exit $((fails > 0))
