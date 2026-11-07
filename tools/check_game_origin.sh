#!/usr/bin/env bash
#
# The game origin revalidates the engine (no-cache, not no-store), compresses the .pck, and serves
# dot-cloud bundles/<hash>.zip as immutable content beside objects/ while manifest.json stays no-cache.
#
#   tools/check_game_origin.sh      exit 0 when it holds, 1 naming each failure
#
# Arm it by setting the default in install-game-origin.sh back to no-store: the first case fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T=deploy/game-origin.nginx.template
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

grep -q 'TMC_GAME_CACHE_CONTROL:-no-cache}' deploy/install-game-origin.sh \
    && ok "the engine's default Cache-Control is no-cache" || bad "the engine's default Cache-Control is not no-cache"
grep -q '^#TMC_GAME_CACHE_CONTROL=no-cache' deploy/env.example \
    && ok "env.example documents the same default" || bad "env.example disagrees with install-game-origin.sh"
grep -E '^\s*gzip_types' "$T" | grep -q application/octet-stream \
    && ok ".pck (octet-stream) is gzipped" || bad "gzip_types lacks application/octet-stream"
awk '/location \/content\//{c=1} c&&/immutable/{i=1} c&&/manifest\\\.json/{m=1} m&&/no-cache/{n=1} END{exit !(i&&m&&n)}' "$T" \
    && ok "/content/ is immutable (objects and bundles) and manifest.json is no-cache" \
    || bad "/content/ lost its immutable block or the manifest.json no-cache exception"
grep -q '\*\.zip)' deploy/publish-web-s3.sh \
    && ok "the S3 publisher types bundles/<hash>.zip" || bad "publish-web-s3.sh does not type .zip"
[ "$fails" = 0 ]
