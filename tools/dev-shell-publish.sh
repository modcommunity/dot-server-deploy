#!/usr/bin/env bash
# Publishes the exported DEV web shell (web/build, from dev-shell.sh) to the dev games bucket and registers
# it on the dev_games site, so games.tmcdev.net frames a shell that trusts the tmc-dev pack key.
#
#   tools/dev-shell-publish.sh [--build ID] [--no-register]      (dev-shell.sh runs it; --no-publish there skips it)
#   tools/dev-shell-publish.sh --register-only --build ID        (deploy-web-shell.sh --dev runs this after its upload)
#
# Dev only: credentials come from ~/godot/.env.dev (the dev bucket), the origin is dev.dotgames.org, the
# app segment is `godot`, and nothing is pinned. Secrets are read by the tools that need them and never printed.
# The WebGameBuild row is inserted on dev01 over ssh: the database is on its loopback and its URL stays there.
set -euo pipefail
cd "$(dirname "$0")/.."
env_file=${DEV_SHELL_ENV:-$HOME/godot/.env.dev} origin=https://dev.dotgames.org app=godot
host=${DEV_SHELL_HOST:-dev01} remote_env=${DEV_GAMES_REMOTE_ENV:-\$HOME/stack/website-city/.env.dev-games}
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
# shellcheck disable=SC2029
printf '%s\n' "$sql" | ssh "$host" "set -a; . $remote_env; set +a; psql \"\${DATABASE_URL%%\\?*}\" -v ON_ERROR_STOP=1 -q"
echo "registered $build on dev_games (app $app)"
