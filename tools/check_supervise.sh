#!/usr/bin/env bash
#
# On a Pterodactyl panel the launcher restarts the engine itself when it exits 75
# (dot-cloud auto-update), and passes every other status through.
#
#   tools/check_supervise.sh      exit 0 when it holds, 1 naming each failure
#
# Arm it by deleting the `RC" = "75"` branch in tools/server.in: the 75 case then fails; drop `<&0` and the stdin case fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC="$PWD/tools/server.in"
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }

# The supervise block as its own launcher, "server" re-entering itself like the real one.
{
    printf '#!/usr/bin/env bash\nPROJECT="%s"\nORIG_ARGS=("$@")\n' "$W"
    printf 'note() { echo "note: $1"; }\nwarn() { echo "warn: $1"; }\n'
    printf 'GODOT="%s/godot"; ARGS=()\n' "$W"
    sed -n '/^SUPERVISE=/,/^fi$/p' "$SRC"
    printf 'exec "$GODOT"\n'
} >"$W/server"
chmod +x "$W/server"

# A fake engine: exits with the first line of $W/codes each run, counts runs, and keeps the first line it reads.
printf '#!/usr/bin/env bash\necho x >>"%s/runs"\nIFS= read -r -t 2 l; echo "$l" >"%s/stdin"\nc=$(head -1 "%s/codes"); sed -i 1d "%s/codes"\nexit "${c:-0}"\n' "$W" "$W" "$W" "$W" >"$W/godot"
chmod +x "$W/godot"

run() { # codes... ; env in $RUNENV
    printf '%s\n' "$@" >"$W/codes"; : >"$W/runs"
    env $RUNENV timeout 30 "$W/server" >"$W/out" 2>&1 <<<"quit"; echo $? >"$W/rc"
}
runs() { wc -l <"$W/runs"; }

RUNENV="P_SERVER_UUID=u"
run 75 0
[ "$(cat "$W/rc")" = 0 ] && [ "$(runs)" = 2 ] && ok "panel: 75 restarts, then the clean exit passes through" || bad "panel: 75 then 0 gave rc=$(cat "$W/rc") runs=$(runs)"
run 3
# The panel's stop is `quit` typed into the console; a background job's stdin is /dev/null unless passed on.
[ "$(cat "$W/stdin")" = quit ] && ok "panel: the engine reads the console's stdin" || bad "panel: the engine read '$(cat "$W/stdin")' from stdin, not quit"
[ "$(cat "$W/rc")" = 3 ] && [ "$(runs)" = 1 ] && ok "panel: another status is not restarted" || bad "panel: 3 gave rc=$(cat "$W/rc") runs=$(runs)"
run 75 75 75
[ "$(cat "$W/rc")" = 75 ] && [ "$(runs)" = 2 ] && ok "panel: a second 75 within 20 s stops the loop" || bad "panel: 75 75 gave rc=$(cat "$W/rc") runs=$(runs)"
RUNENV="TMC_NONE=1"
run 75 0
[ "$(cat "$W/rc")" = 75 ] && [ "$(runs)" = 1 ] && ok "no panel: 75 is left to the supervisor" || bad "no panel: gave rc=$(cat "$W/rc") runs=$(runs)"
RUNENV="P_SERVER_UUID=u TMC_SUPERVISE=0"
run 75 0
[ "$(cat "$W/rc")" = 75 ] && [ "$(runs)" = 1 ] && ok "TMC_SUPERVISE=0 turns it off" || bad "TMC_SUPERVISE=0 gave rc=$(cat "$W/rc") runs=$(runs)"

[ "$fails" = 0 ] && echo "supervise: all ok" || echo "supervise: $fails failed"
exit $(( fails > 0 ))
