#!/usr/bin/env bash
# Every game's installer default equals its engine rate (project.godot), and the installer's table
# fallback; a fresh install offers the template's 66.
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
chk "table: fatalcontact 66" '[ "$(tbl fatalcontact)" = 66 ]'
chk "table: arena (its former id) 66" '[ "$(tbl arena)" = 66 ]'
chk "table: airdrift 128"  '[ "$(tbl airdrift)" = 128 ]'
chk "table: g2gfast (its former id) 128" '[ "$(tbl g2gfast)" = 128 ]'
chk "table: playlot 128" '[ "$(tbl playlot)" = 128 ]'
chk "table: playground (its former id) 128" '[ "$(tbl playground)" = 128 ]'
chk "table: unknown 60"    '[ "$(tbl hungario)" = 60 ]'

# Against the real engine rates, when the sibling repositories are checked out.
root="$(cd .. && pwd)"
for proj in "$root"/game-*/project.godot "$root"/mg-*/project.godot; do
    [ -f "$proj" ] || continue
    d="$(basename "$(dirname "$proj")")"
    case "$d" in *-maps) continue ;; esac
    # A linked worktree (.git is a file) is a branch copy named game-<repo>-<task>, not a
    # game: its name is no installer id, so the table cannot answer for it. Only the repo itself.
    [ -d "$root/$d/.git" ] || continue
    want="$(sed -n 's/^common\/physics_ticks_per_second=\([0-9][0-9]*\).*/\1/p' "$proj" | head -1)"
    want="${want:-60}"
    chk "$d default equals its project.godot ($want)" '[ "$(tbl "${d#game-}")" = "$want" ]'
    chk "$d table-free (checkout) default equals $want" '[ "$(eval "$fn"; game_tickrate "$d")" = "$want" ]'
done

# Fresh install: the example must not carry a value that cfg_or would return first.
chk "server.yml template sets sv_tickrate: 66" 'grep -qE "^sv_tickrate: 66\$" cfg.example/server/server.yml'
fresh() ( eval "$cfn"; eval "$fn"; cfg_or cfg.example/server/server.yml sv_tickrate "$(game_tickrate "$1")" )
chk "fresh install offers 66 (template default)" '[ "$(fresh airdrift)" = 66 ]'
chk "the installer prompt uses it" 'grep -q "sv_tickrate \"\$(game_tickrate" setup.sh'
chk "demo fatalcontact server runs 66" 'grep -q "GAME5_TICKRATE:-66" demo.sh'
[ "$fails" -eq 0 ] && echo "tickrate: ok" || echo "tickrate: $fails failed"
exit $((fails > 0))
