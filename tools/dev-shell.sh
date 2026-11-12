#!/usr/bin/env bash
# Exports the DEV web shell from this checkout and publishes it to the dev site (tools/dev-shell-publish.sh).
#
#   heavy -- tools/dev-shell.sh [--backbone URL] [--no-publish]
#
# Dev only: never publishes, pins or touches production. The shell differs from a published one in two files that
# stay out of git: client/auth.json (backbone_url, default https://tmcdev.net, the dev site; https://games.tmcdev.net
# for the dev_games stack) and client/content.json, which also trusts the tmc-dev pack key so dev-signed packs load.
# Both are restored when the script ends. Then tools/dev-shell-publish.sh uploads the same shell through the dev site's
# web build API (storez) and registers it, so tmcdev.net and games.tmcdev.net frame it (--no-publish skips that and
# leaves the export in web/build). The old dev01:/srv/tmc-game install is gone (nginx no longer serves it);
# --no-install is still accepted and does nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
backbone=https://tmcdev.net publish=1 key=${DEV_PACK_KEY:-$HOME/.config/dot/pack-dev.pub}
while [ $# -gt 0 ]; do
    case $1 in
        --backbone) backbone=${2:?--backbone needs a URL}; shift 2 ;;
        --no-install) shift ;;
        --no-publish) publish=0; shift ;;
        *) echo "usage: dev-shell.sh [--backbone URL] [--no-publish]" >&2; exit 2 ;;
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
# ./server is generated once by setup.sh; a stale one exports without shell-api.json, and the site then cannot match the shell to a game.
if [ ! -x server ] || [ tools/server.in -nt server ]; then
    godot_bin=$(sed -n 's/^GODOT="\${TMC_GODOT:-\(.*\)}"$/\1/p' server 2>/dev/null || true)  # a fresh worktree has no ./server: sed exits 2, and set -e would end the script silently
    sed "s|@GODOT@|${godot_bin:-$(command -v godot)}|g" tools/server.in > server && chmod +x server
fi
./server export-web
echo "dev shell exported with backbone $backbone"
# The export is still in web/build here, and the trap restores the key files only after this line.
if [ "$publish" = 1 ]; then tools/dev-shell-publish.sh; fi
