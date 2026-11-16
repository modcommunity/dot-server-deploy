#!/usr/bin/env bash
#
# The Gamespice environment names in the shell tools: GS_X is read first, the old DOT_X still works and says so once.
#
#   tools/check_gs_env.sh      exit 0 when it holds, 1 naming each failure
#
# Arm it by deleting the `export "$old=${!gs}"` line in tools/gs-env.sh: the "GS_ wins" case fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
ok()  { printf "  %sok%s   %s\n" "$GRN" "$OFF" "$1"; }
bad() { printf "  %sFAIL%s %s\n" "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
probe() { env -i PATH="$PATH" "$@" bash -c ". tools/gs-env.sh; gs_env_alias SELFTEST; printf \"%s\" \"\${DOT_SELFTEST:-}\"" ; }

out="$(probe 2>&1)"
[ -z "$out" ] && ok "neither set: silent, empty" || bad "neither set printed: $out"
out="$(probe DOT_SELFTEST=old 2>&1)"
case "$out" in *"WARN gs.config: environment variable DOT_SELFTEST is deprecated, set GS_SELFTEST"*old) ok "old name alone: one WARN line, value kept" ;; *) bad "old name alone gave: $out" ;; esac
[ "$(printf "%s" "$out" | grep -c WARN)" = 1 ] && ok "exactly one WARN line" || bad "WARN count is not 1"
out="$(probe GS_SELFTEST=new 2>&1)"
[ "$out" = new ] && ok "GS_ alone is seen under the old name too" || bad "GS_ alone gave: $out"
out="$(probe GS_SELFTEST=new DOT_SELFTEST=old 2>&1)"
[ "$out" = new ] && ok "GS_ wins over DOT_, no warning" || bad "both set gave: $out"
out="$(probe DOT_SELFTEST=old GS_QUIET_DEPRECATION=1 2>&1)"
[ "$out" = old ] && ok "GS_QUIET_DEPRECATION=1 silences the line" || bad "quiet gave: $out"

[ "$fails" = 0 ] && exit 0
exit 1
