#!/usr/bin/env bash
# arena's dedicated rate is 66 (game-arena 7c65a5b) and the one knob is sv_tickrate.
#   tools/check_tickrate.sh   exit 0 when the installer and demo default to it, 1 otherwise
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fails=0
chk() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

# Run the real function, so a rewritten case arm is caught rather than a grep of its text.
fn="$(sed -n '/^game_tickrate() {/,/^}/p' setup.sh)"
chk "setup.sh defines game_tickrate" '[ -n "$fn" ]'
chk "arena defaults to 66"  '[ "$(eval "$fn"; game_tickrate arena)" = 66 ]'
chk "other games keep 60"   '[ "$(eval "$fn"; game_tickrate g2gfast)" = 60 ]'
chk "the installer prompt uses it" 'grep -q "sv_tickrate \"\$(game_tickrate" setup.sh'
chk "demo arena server runs 66" 'grep -q "GAME5_TICKRATE:-66" demo.sh'
chk "server.yml template keeps the sv_tickrate key" 'grep -qE "^sv_tickrate: [0-9]+" cfg.example/server/server.yml'
[ "$fails" -eq 0 ] && echo "tickrate: ok" || echo "tickrate: $fails failed"
exit $((fails > 0))
