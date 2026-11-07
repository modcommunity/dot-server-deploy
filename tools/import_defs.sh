#!/usr/bin/env bash
#
# Push a game's deployment/*.json definition files to the site.
#
#   ./server import-defs --game-dir ../game-arena
#   ./server import-defs --game-dir ../game-arena --dry-run
#
# Posts whichever of these exist in <game-dir>/deployment/ (a missing one is skipped):
#   stat-defs.json         -> /api/integration/v1/stats/defs-import        (STATS_WRITE)
#   achievement-defs.json  -> /api/integration/v1/achievements/defs-import (ACHIEVEMENTS_WRITE)
#   leaderboard-defs.json  -> /api/integration/v1/leaderboard/defs-import  (LEADERBOARD_WRITE)
#   game-listing.json      -> /api/integration/v1/listing/import           (LISTING_WRITE)
#
# --dry-run asks the site to validate and report its plan (apply:false) and writes nothing.
# The token is the "integration_token" key of <data>/listing.json (the same file enrollment writes),
# or a file given with --token-file. It goes to curl on stdin, so it never reaches argv, ps or output.
# The achievement, leaderboard and listing routes want a credential scoped to the game itself.
set -euo pipefail

GAME_DIR=""; DATA_DIR="${TMC_DATA_DIR:-data}"; TOKEN_FILE=""; URL=""; DRY=false

die() { echo "error: $*" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME_DIR="${2:?}"; shift 2 ;;
        --data) DATA_DIR="${2:?}"; shift 2 ;;
        --token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
        --url) URL="${2:?}"; shift 2 ;;
        --dry-run) DRY=true; shift ;;
        *) die "unknown option $1" 2 ;;
    esac
done

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
[ -n "$GAME_DIR" ] || die "--game-dir needs a game repository directory" 2
DEPLOY="$GAME_DIR/deployment"
[ -d "$DEPLOY" ] || die "$DEPLOY does not exist" 2

LISTING="$DATA_DIR/listing.json"
if [ -z "$TOKEN_FILE" ]; then
    [ -r "$LISTING" ] || die "no token: $LISTING is not readable (or give --token-file)" 2
    jq -e '(.integration_token // "") != ""' "$LISTING" >/dev/null 2>&1 || die "no integration_token in $LISTING (or give --token-file)" 2
fi
if [ -z "$URL" ]; then
    URL="${TMC_SITE_URL:-}"
    [ -z "$URL" ] && [ -r "$LISTING" ] && URL="$(jq -r '.backbone_url // ""' "$LISTING" 2>/dev/null || true)"
    URL="${URL:-https://moddingcommunity.com}"
fi

read_token() {
    if [ -n "$TOKEN_FILE" ]; then tr -d '[:space:]' < "$TOKEN_FILE"
    else jq -r '.integration_token' "$LISTING" | tr -d '[:space:]'; fi
}

apply=true; $DRY && apply=false
resp="$(mktemp)"; trap 'rm -f "$resp"' EXIT
sent=0; failed=0

post() { # file path
    local f="$DEPLOY/$1" path="$2" body code
    [ -f "$f" ] || { echo "skip  $1 (not present)"; return 0; }
    if ! body="$(jq -c --argjson a "$apply" '{doc: ., apply: $a}' "$f" 2>/dev/null)"; then
        echo "FAIL  $1: not valid JSON" >&2; failed=$((failed + 1)); return 0
    fi
    sent=$((sent + 1))
    if ! code="$(printf 'header = "Authorization: Bearer %s"\n' "$(read_token)" \
        | curl -sS -o "$resp" -w '%{http_code}' -K - -X POST -H 'Content-Type: application/json' \
            --data-binary "$body" "${URL%/}$path")"; then
        echo "FAIL  $1: request failed" >&2; failed=$((failed + 1)); return 0
    fi
    if [ "$code" != "200" ]; then
        echo "FAIL  $1: HTTP $code: $(head -c 300 "$resp")" >&2; failed=$((failed + 1)); return 0
    fi
    jq -r --arg f "$1" '"ok    \($f): applied=\(.applied) " + ([.plan | to_entries[] | select(.value | type == "array") | "\(.key)=\(.value | length)"] | join(" "))' "$resp"
    jq -r '(.plan.warnings // [])[] | "      warning: \(.)"' "$resp"
    jq -r '(.refused // [])[] | "      refused: \(.)"' "$resp"
}

post stat-defs.json /api/integration/v1/stats/defs-import
post achievement-defs.json /api/integration/v1/achievements/defs-import
post leaderboard-defs.json /api/integration/v1/leaderboard/defs-import
post game-listing.json /api/integration/v1/listing/import

$DRY && echo "dry run: nothing was written on the site"
[ "$failed" -eq 0 ] || exit 1
[ "$sent" -gt 0 ] || echo "nothing to import in $DEPLOY"
