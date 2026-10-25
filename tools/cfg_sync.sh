#!/usr/bin/env bash
# Refreshes the SHIPPED config defaults: cfg/addon/** and cfg/game/** are copied from cfg.example/
# over what is there (an update owns them). cfg/server/** and cfg/content/** are the operator's and
# are never written here. Usage: tools/cfg_sync.sh [PROJECT_DIR] [CFG_DIR]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${2:-$ROOT/cfg}"
n=0
for tier in addon game; do
    [ -d "$ROOT/cfg.example/$tier" ] || continue
    while IFS= read -r template; do
        rel="${template#"$ROOT"/cfg.example/}"
        target="$CFG/$rel"
        if [ -f "$target" ] && cmp -s "$template" "$target"; then continue; fi
        mkdir -p "$(dirname "$target")"
        cat "$template" > "$target" && { printf '    ~    %s (shipped default)\n' "cfg/$rel"; n=$((n + 1)); }
    done < <(find "$ROOT/cfg.example/$tier" -type f \( -name '*.yml' -o -name '*.md' \) | sort)
done
exit 0
