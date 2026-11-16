#!/bin/bash
# Fetch what this repository's content.lock.json names from the CDN (hash-checked, once; present files skipped).
# Thin wrapper: the one fetcher is dot-bootstrap/tools/fetch_lock.sh, whose header lists every option (--only/--except ITEM,
# --cdn URL, --list). The CDN URL comes from --cdn, $GS_CDN_URL (old name DOT_CDN_URL), or GS_CDN_URL in dot-bootstrap/.env (one edit for every repo).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/tools/gs-env.sh"; gs_env_alias BOOTSTRAP CDN_URL PACKS_FROM PACKS_TOKEN_FILE ORIGIN_ALIASES
for tool in "${DOT_BOOTSTRAP:-$HERE/../dot-bootstrap}/tools/fetch_lock.sh" "$HERE/tools/fetch_lock.sh"; do
    [ -x "$tool" ] && exec "$tool" "$HERE/content.lock.json" --root "$HERE" --packs "$HERE/content/packs" "$@"
done
echo "fetch-content: dot-bootstrap is not beside this checkout; clone it or set GS_BOOTSTRAP" >&2; exit 2
