#!/usr/bin/env bash
#
# tools/import_defs.sh against a fake curl: which routes are hit, that --dry-run sends apply:false,
# that a missing file is skipped, and that the token never reaches argv (curl gets it on stdin).
#
#   tools/check_import_defs.sh      exit 0 when they hold, 1 naming each failure
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TOOL="$PWD/tools/import_defs.sh"
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null || { echo "  skip import_defs (jq missing)"; exit 0; }
mkdir -p "$W/bin" "$W/game/deployment" "$W/data"
echo '{"integration_token":"SECRET-TOKEN-123","backbone_url":"https://site.invalid"}' >"$W/data/listing.json"
echo '{"version":1,"stats":[]}' >"$W/game/deployment/stat-defs.json"
echo '{"version":1,"listing":{}}' >"$W/game/deployment/game-listing.json"
cat >"$W/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""; url=""; body=""; stdin="$(cat)"
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;; -w|-X|-H) shift 2 ;; --data-binary) body="$2"; shift 2 ;;
        -*) shift ;; *) url="$1"; shift ;;
    esac
done
echo "$url $body" >>"$LOG"
echo "ARGV: $*" >>"$LOG"
case "$stdin" in *SECRET-TOKEN-123*) echo STDIN_HAS_TOKEN >>"$LOG" ;; esac
echo '{"ok":true,"applied":false,"plan":{"create":[1,2],"warnings":["w1"]}}' >"$out"
printf 200
FAKE
chmod +x "$W/bin/curl"
export LOG="$W/log" PATH="$W/bin:$PATH"

out="$(bash "$TOOL" --game-dir "$W/game" --data "$W/data" --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "dry run exits 0" || bad "dry run exit $rc: $out"
grep -q 'https://site.invalid/api/integration/v1/stats/defs-import ' "$W/log" && ok "stats route hit with the listing.json backbone_url" || bad "stats route missing"
grep -q '/api/integration/v1/listing/import ' "$W/log" && ok "listing route hit" || bad "listing route missing"
[ "$(grep -c 'defs-import \|listing/import ' "$W/log")" -eq 2 ] && ok "absent files skipped (2 posts)" || bad "wrong number of posts"
grep -q '"apply":false' "$W/log" && ok "--dry-run sends apply:false" || bad "dry run did not send apply:false"
grep -q STDIN_HAS_TOKEN "$W/log" && ok "token reached curl on stdin" || bad "token not on stdin"
grep -q 'SECRET-TOKEN' "$W/log" && bad "token leaked into argv or body" || ok "token not in argv"
echo "$out" | grep -q SECRET && bad "token printed" || ok "token not printed"

: >"$W/log"
bash "$TOOL" --game-dir "$W/game" --data "$W/data" >/dev/null 2>&1
grep -q '"apply":true' "$W/log" && ok "real run sends apply:true" || bad "real run did not send apply:true"

bash "$TOOL" --game-dir "$W/game" --data "$W/nodata" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing token refused" || bad "missing token exit $rc"

[ "$fails" -eq 0 ]
