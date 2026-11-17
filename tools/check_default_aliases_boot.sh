#!/usr/bin/env bash
# The host must boot with the DEFAULT aliases (host/aliases.yml) and an operator's `hostname:` in server.yml.
#
#   tools/check_default_aliases_boot.sh      exit 0 when it boots, 1 naming what failed
#
# [b]Why this exists.[/b] The default alias `hostname: sv_name` was reported by TmcAliases.check as
# shadowing the console cvar `hostname` (which is the very cvar `sv_name` sets), counted as an alias
# failure, and tmc_host.gd refused to boot (exit 5) on any such failure: every server with the
# default aliases died at start. The selftest cannot see it (it never runs the host's boot path), so
# this runs the real launcher against a one-game builtin content directory.
set -u
cd "$(dirname "$0")/.." || exit 1
export TMC_AUTO_UPDATE=never

RED=$'\e[31m'; GRN=$'\e[32m'; OFF=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; OFF=""; }
[ -x ./server ] || { printf '  %s--%s   ./server is not built; run ./setup.sh\n' "$RED" "$OFF"; exit 1; }

FIX=".alias_boot_check"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$FIX" "$WORK"; }
trap cleanup EXIT
mkdir -p "$FIX" "$WORK/cfg/server" "$WORK/content/plain" "$WORK/data"

printf '[gd_scene format=3]\n\n[node name="AliasBootCheck" type="Node"]\n' > "$FIX/server.tscn"
printf 'name: Alias boot check\nversion: 0.0.1\nkind: builtin\ndefault: true\nscene: res://%s/server.tscn\n' "$FIX" > "$WORK/content/plain/game.yml"
printf 'hostname: "Zee MiniGames #1 | Party/Random Games!"\nsv_maxplayers: 8\n' > "$WORK/cfg/server/server.yml"

timeout 300 ./server check --no-install --config "$WORK/cfg" --content "$WORK/content" --data "$WORK/data" \
    < /dev/null > "$WORK/boot.log" 2>&1
rc=$?

fails=0
if [ "$rc" -eq 0 ] && grep -q '^selftest ok$' "$WORK/boot.log"; then
    printf '  %sok%s   the host boots with the default aliases and `hostname:` set (exit 0)\n' "$GRN" "$OFF"
else
    printf '  %sFAIL%s the host did not boot (exit %d)\n' "$RED" "$OFF" "$rc"; fails=1
fi
if grep -q 'shadows the console name' "$WORK/boot.log"; then
    printf '  %sFAIL%s a default alias is reported as shadowing a console name\n' "$RED" "$OFF"; fails=1
fi
[ "$fails" -ne 0 ] && grep -E 'ERR|SCRIPT ERROR|ERROR:|alias' "$WORK/boot.log" | head -10 | sed 's/^/       /'
exit "$fails"
