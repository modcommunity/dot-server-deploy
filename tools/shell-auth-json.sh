#!/usr/bin/env bash
# Writes client/auth.json, the web shell's sign-in config (gitignored: a deployment's answer).
#
#   tools/shell-auth-json.sh BACKBONE_URL [AUDIENCES] > client/auth.json
#
# AUDIENCES is an optional comma list of `server:<id>` / `app:<id>`, used only when the site
# cannot answer `play/first-party` at sign-in; normally leave it empty and let the site decide.
set -euo pipefail
url=${1:?usage: shell-auth-json.sh BACKBONE_URL [AUDIENCES]}
list=()
IFS=',' read -ra raw <<< "${2:-}"
for a in "${raw[@]}"; do
    a=$(printf '%s' "$a" | tr -d '[:space:]')
    [ -z "$a" ] && continue
    [[ "$a" =~ ^(server|app):[1-9][0-9]*$ ]] || { echo "error: '$a' is not server:<id> or app:<id>" >&2; exit 2; }
    list+=("\"$a\"")
done
joined=$(IFS=','; echo "${list[*]:-}")
printf '{\n  "backbone_url": "%s",\n  "first_party_audiences": [%s]\n}\n' "$url" "$joined"
