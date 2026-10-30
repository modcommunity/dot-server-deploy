#!/usr/bin/env bash
#
# Push a game's stat catalog JSON (stats/stat-defs.json) to the site.
#
#   ./deploy/import-stat-defs.sh --file stats/stat-defs.json --token-file cfg/integration.token
#   ./deploy/import-stat-defs.sh --file ... --token-file ... --preview
#   ./deploy/import-stat-defs.sh --file ... --token-file ... --overwrite
#
# A merge: the owner's own names and visibility survive and stats the file leaves out stay;
# --overwrite replaces the owner's edits too. The token is a file (needs STATS_WRITE, scoped to
# the app) and goes to curl on stdin, so it never appears in argv or ps.
set -euo pipefail

FILE="stats/stat-defs.json"; TOKEN_FILE=""; URL="${TMC_SITE_URL:-https://moddingcommunity.com}"
APPLY=true; OVERWRITE=false

die() { echo "error: $*" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --file) FILE="${2:?}"; shift 2 ;;
        --token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
        --url) URL="${2:?}"; shift 2 ;;
        --preview) APPLY=false; shift ;;
        --overwrite) OVERWRITE=true; shift ;;
        *) die "unknown option $1" 2 ;;
    esac
done

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
[ -r "$FILE" ] || die "$FILE is not readable"
[ -r "$TOKEN_FILE" ] || die "--token-file must name a readable file holding the integration token" 2

body="$(jq -c --argjson o "$OVERWRITE" --argjson a "$APPLY" '{doc: ., overwrite: $o, apply: $a}' "$FILE")" \
    || die "$FILE is not valid JSON"

resp="$(mktemp)"; trap 'rm -f "$resp"' EXIT
code="$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '[:space:]' < "$TOKEN_FILE")" \
    | curl -sS -o "$resp" -w '%{http_code}' -K - -X POST -H 'Content-Type: application/json' \
        --data-binary "$body" "${URL%/}/api/integration/v1/stats/defs-import")" || die "request failed"

if [ "$code" != "200" ]; then
    echo "error: HTTP $code: $(head -c 400 "$resp")" >&2
    exit 1
fi
jq -r '"applied=\(.applied) added=\(.plan.added|length) changed=\(.plan.changed|length) kept_custom=\(.plan.keptCustom|length) unchanged=\(.plan.unchanged|length)"' "$resp"
