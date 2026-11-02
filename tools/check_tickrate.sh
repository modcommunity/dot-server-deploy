#!/usr/bin/env bash
# Every game's installer default equals its engine rate (project.godot), and a fresh install
# offers it rather than a stale example value.
#   tools/check_tickrate.sh   exit 0 when all hold, 1 otherwise
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fails=0
chk() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

fn="$(sed -n '/^game_tickrate() {/,/^}/p' setup.sh)"
cfn="$(sed -n '/^cfg_get() {/,/^}/p;/^cfg_or() {/,/^}/p' setup.sh)"
chk "setup.sh defines game_tickrate" '[ -n "$fn" ]'

# The table path (no sibling checkout): run from a directory with no ../game-*.
tbl() ( cd "$(mktemp -d)" && eval "$fn" && game_tickrate "$1" )
chk "table: arena 66"      '[ "$(tbl arena)" = 66 ]'
chk "table: g2gfast 128"   '[ "$(tbl g2gfast)" = 128 ]'
chk "table: playground 128" '[ "$(tbl playground)" = 128 ]'
chk "table: unknown 60"    '[ "$(tbl hungario)" = 60 ]'

# Against the real engine rates, when the sibling repositories are checked out.
root="$(cd .. && pwd)"
for proj in "$root"/game-*/project.godot "$root"/mg-*/project.godot; do
    [ -f "$proj" ] || continue
    d="$(basename "$(dirname "$proj")")"
    case "$d" in *-maps) continue ;; esac
    want="$(sed -n 's/^common\/physics_ticks_per_second=\([0-9][0-9]*\).*/\1/p' "$proj" | head -1)"
    want="${want:-60}"
    chk "$d default equals its project.godot ($want)" '[ "$(tbl "${d#game-}")" = "$want" ]'
    chk "$d table-free (checkout) default equals $want" '[ "$(eval "$fn"; game_tickrate "$d")" = "$want" ]'
done

# Fresh install: the example must not carry a value that cfg_or would return first.
chk "server.yml template sets no sv_tickrate" '! grep -qE "^sv_tickrate:" cfg.example/server/server.yml'
fresh() ( eval "$cfn"; eval "$fn"; cfg_or cfg.example/server/server.yml sv_tickrate "$(game_tickrate "$1")" )
chk "fresh install offers 66 for arena"    '[ "$(fresh arena)" = 66 ]'
chk "fresh install offers 128 for g2gfast" '[ "$(fresh g2gfast)" = 128 ]'
chk "the installer prompt uses it" 'grep -q "sv_tickrate \"\$(game_tickrate" setup.sh'
chk "demo arena server runs 66" 'grep -q "GAME5_TICKRATE:-66" demo.sh'
[ "$fails" -eq 0 ] && echo "tickrate: ok" || echo "tickrate: $fails failed"
exit $((fails > 0))
