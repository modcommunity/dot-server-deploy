#!/usr/bin/env bash
# Exports the DEV web shell from this checkout and installs it on dev01:/srv/tmc-game (tmcdevgames.net).
#
#   heavy -- tools/dev-shell.sh [--backbone URL] [--no-install]
#
# Dev only: never publishes, pins or touches the production bucket. The shell differs from a published one
# in two files that stay out of git: client/auth.json (backbone_url, default https://tmcdev.net, the dev
# site; https://games.tmcdev.net for the dev_games stack) and client/content.json, which also trusts the
# tmc-dev pack key so dev-signed packs load. Both are restored when the script ends. The previous
# /srv/tmc-game is copied to dev01 ~/backups/tmc-game-<timestamp> first.
set -euo pipefail
cd "$(dirname "$0")/.."
backbone=https://tmcdev.net install=1 key=${DEV_PACK_KEY:-$HOME/.config/dot/pack-dev.pub} host=${DEV_SHELL_HOST:-dev01}
while [ $# -gt 0 ]; do
    case $1 in
        --backbone) backbone=${2:?--backbone needs a URL}; shift 2 ;;
        --no-install) install=0; shift ;;
        *) echo "usage: dev-shell.sh [--backbone URL] [--no-install]" >&2; exit 2 ;;
    esac
done
[ -f "$key" ] || { echo "error: dev pack key $key missing" >&2; exit 1; }
case $backbone in *moddingcommunity.com*) echo "error: refusing the production site in a dev shell" >&2; exit 1 ;; esac

keep=$(mktemp -d)
cp client/content.json "$keep/content.json"
if [ -f client/auth.json ]; then cp client/auth.json "$keep/auth.json"; fi
restore() {
    cp "$keep/content.json" client/content.json
    if [ -f "$keep/auth.json" ]; then cp "$keep/auth.json" client/auth.json; else rm -f client/auth.json; fi
    rm -rf "$keep"
}
trap restore EXIT

python3 - "$key" <<'PY'
import json, sys
p = "client/content.json"
d = json.load(open(p))
d["trusted_keys"]["tmc-dev"] = open(sys.argv[1]).read().strip()
json.dump(d, open(p, "w"), indent=4)
PY
tools/shell-auth-json.sh "$backbone" > client/auth.json
./server export-web
echo "dev shell exported with backbone $backbone"
[ "$install" = 1 ] || exit 0

ts=$(date +%Y%m%d-%H%M%S)
ssh "$host" "mkdir -p ~/backups && cp -a /srv/tmc-game ~/backups/tmc-game-$ts"
rsync -a --delete web/build/ "$host:/srv/tmc-game/"
echo "installed on $host:/srv/tmc-game (backup ~/backups/tmc-game-$ts)"
