#!/usr/bin/env bash
# Refreshes the SHIPPED config defaults: cfg/addon/** and cfg/game/** are copied from cfg.example/
# over what is there (an update owns them). cfg/server/** and cfg/content/** are the operator's and
# are never written here. Usage: tools/cfg_sync.sh [PROJECT_DIR] [CFG_DIR]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${2:-$ROOT/cfg}"
n=0
# A game renamed since the directory was made keeps what is in it: the old directory is renamed when the current
# one does not exist yet, before the shipped default is written there. (The host merges the rest on boot;
# TmcGameCfgDirs.RETIRED_DIRS is the same list, and the selftest compares them.)
for tier in game; do
    for pair in game-arena:game-fatal-contact game-final-contact:game-fatal-contact arena:game-fatal-contact \
        game-g2gfast:game-airdrift game-g2gfast01:game-airdrift g2gfast:game-airdrift \
        game-playground:game-playlot playground:game-playlot; do
        old="${pair%%:*}"; new="${pair##*:}"
        if [ -d "$CFG/$tier/$old" ] && [ ! -e "$CFG/$tier/$new" ]; then
            mv "$CFG/$tier/$old" "$CFG/$tier/$new" && printf '    ~    cfg/%s/%s is now cfg/%s/%s (the game was renamed)\n' "$tier" "$old" "$tier" "$new"
        fi
    done
done
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
