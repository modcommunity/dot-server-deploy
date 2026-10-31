#!/usr/bin/env bash
# Publishes the exported DEV web shell (web/build, from dev-shell.sh) to the dev games bucket and registers
# it on the dev_games site, so games.tmcdev.net frames a shell that trusts the tmc-dev pack key.
#
#   tools/dev-shell-publish.sh [--build ID] [--no-register]      (dev-shell.sh runs it; --no-publish there skips it)
#   tools/dev-shell-publish.sh --register-only --build ID        (deploy-web-shell.sh --dev runs this after its upload)
#
# Dev only: credentials come from ~/godot/.env.dev (the dev bucket), the origin is dev.dotgames.org, the
# app segment is `godot`, and nothing is pinned. Secrets are read by the tools that need them and never printed.
# The WebGameBuild row is inserted on dev01 over ssh into BOTH dev databases: dev_games (games.tmcdev.net) and tmc_dev
# (tmcdev.net, which every app reads its engine from; app 69 "godot" is the shared engine app). Without the tmc_dev row
# every app says "This game has no engine location configured". Both URLs stay on dev01 and are never printed.
# Prod is not touched. For prod, run deploy-web-shell.sh --pin (uploads and pins the build) and insert the WebGameBuild
# row on prod by hand, then restart; see the web-client-fix-not-live-until-uploaded note.
set -euo pipefail
cd "$(dirname "$0")/.."
env_file=${DEV_SHELL_ENV:-$HOME/godot/.env.dev} origin=https://dev.dotgames.org app=godot
host=${DEV_SHELL_HOST:-dev01} remote_envs=${DEV_GAMES_REMOTE_ENVS:-\$HOME/stack/website-city/.env.dev-games \$HOME/stack/website-city/.env}
build= entry= register=1 publish=1
while [ $# -gt 0 ]; do
    case $1 in
        --build) build=${2:?--build needs an id}; shift 2 ;;
        --entry) entry=${2:?--entry needs a file}; shift 2 ;;
        --no-register) register=0; shift ;;
        --register-only) publish=0; shift ;;
        *) echo "usage: dev-shell-publish.sh [--build ID] [--entry FILE] [--no-register | --register-only]" >&2; exit 2 ;;
    esac
done
build=${build:-$(date -u +%Y%m%d-%H%M)}
if [ -z "$entry" ]; then if [ -f web/build/embed.html ]; then entry=embed.html; else entry=index.html; fi; fi
case $build in */*|*..*|*" "*) echo "error: not a single path segment: $build" >&2; exit 1 ;; esac

if [ "$publish" = 1 ]; then
    [ -d web/build ] || { echo "error: no web/build; run tools/dev-shell.sh first" >&2; exit 1; }
    zip=$(mktemp -d)/shell.zip
    # content/ is the games' packs; a shell build is the engine and client only.
    (cd web/build && zip -qr "$zip" . -x 'content/*')
    tools/publish-web-shell.sh --zip "$zip" --env "$env_file" --build "$build" --app "$app" --origin "$origin" \
        --notes "dev shell, tmc-dev key" | grep -v '^INSERT\|^SELECT\|^FROM\|^ON CONFLICT\|^       '
    rm -rf "$(dirname "$zip")"
fi
[ "$register" = 1 ] || exit 0

# The addon API levels the shell carries (export-web's shell-api.json), so the resolver can match it to sv_web_requires.
api=NULL
if [ -f web/build/shell-api.json ]; then
    api=$(python3 - web/build/shell-api.json <<'PY'
import json, sys
s = json.dumps(json.load(open(sys.argv[1])))
print("'" + s.replace("'", "''") + "'::jsonb")
PY
)
fi
sql="INSERT INTO \"WebGameBuild\" (id, \"appId\", build, entry, status, notes, api, \"createdAt\", \"updatedAt\")
SELECT 'wgb' || substr(md5(random()::text), 1, 22), id, '$build', '$entry', 'ACTIVE', 'dev shell, tmc-dev key', $api, now(), now()
FROM \"App\" WHERE url = '$app' ON CONFLICT (\"appId\", build) DO UPDATE SET api = COALESCE(EXCLUDED.api, \"WebGameBuild\".api);"
# .env is not sourceable (a bare AUTH_API_KEY line), so the URL is read with grep, not sourced.
# shellcheck disable=SC2029
for remote_env in $remote_envs; do
    printf '%s\n' "$sql" | ssh "$host" "u=\$(grep '^DATABASE_URL=' $remote_env | cut -d= -f2- | tr -d '\"'); psql \"\${u%%\\?*}\" -v ON_ERROR_STOP=1 -q"
    echo "registered $build in $(basename "$remote_env") (app $app)"
done
