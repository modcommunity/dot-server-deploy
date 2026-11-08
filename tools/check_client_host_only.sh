#!/usr/bin/env bash
#
# client/ never names a host-only class.
#
#   tools/check_client_host_only.sh      exit 0 when it holds, 1 naming each failure
#
# The web shell is exported from client/ alone; host/ (and the server addons it pulls in) is not
# in that export, so a client script that names a class_name declared under host/ parses on a
# dev box and fails to parse in the exported shell (a grey view). Comments and strings are
# ignored. Arm it by adding `var t: TmcYaml` to any client/*.gd: it fails naming file and line.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
mapfile -t classes < <(sed -n 's/^class_name[[:space:]]\+\([A-Za-z0-9_]\+\).*/\1/p' host/*.gd | sort -u)
[ "${#classes[@]}" -gt 0 ] || { printf '  %sFAIL%s no host class_name found; the check is blind\n' "$RED" "$OFF"; exit 1; }
for f in client/*.gd; do
    # Drop double-quoted strings and comments before matching.
    code="$(sed -E 's/"([^"\\]|\\.)*"//g; s/#.*$//' "$f")"
    for c in "${classes[@]}"; do
        hits="$(printf '%s\n' "$code" | grep -nE "(^|[^A-Za-z0-9_])$c([^A-Za-z0-9_]|$)" | head -3)"
        if [ -n "$hits" ]; then
            printf '  %sFAIL%s %s names host-only %s\n%s\n' "$RED" "$OFF" "$f" "$c" "$hits"
            fails=$((fails + 1))
        fi
    done
done
[ "$fails" -eq 0 ] && printf '  %sok%s   client/ names none of the %d host classes\n' "$GRN" "$OFF" "${#classes[@]}"
exit $((fails > 0))
