#!/usr/bin/env bash
# A shell carries the dot-* addons and nothing else. The game addons (the weapons packs,
# natural_disasters) reach a player as dot-cloud overlay packs when they join; baked in,
# arena-weapons v1.4.28's embedded textures took the web pck from 44 MB to 147 MB.
#
# Text only, no Godot: every non-dot repository addons.lock names is excluded by every
# preset in export_presets.example.cfg, the shell takes its overlay (TmcAddonNamespaces),
# and tools/server.in still has the export guards. tools/shell_pck_check.sh proves the
# same thing on an exported pck. Arm it by deleting `addons/zee_weapons/*` from a preset.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
good() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# The folder setup.sh puts a repository in: addon_repo() run backwards.
dir_of() {
    case "$1" in
        zee-dot-weapons) echo zee_weapons ;;
        zed-dot-weapons) echo zed_weapons ;;
        fc-weapons|arena-weapons) echo arena_weapons ;;
        *) echo "${1//-/_}" ;;
    esac
}

mapfile -t repos < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ && $1 !~ /^dot-/ { print $1 }' addons.lock)
[ "${#repos[@]}" -gt 0 ] || bad "addons.lock names no game addon; this check reads nothing"

presets="$(grep -c '^exclude_filter=' export_presets.example.cfg)"
[ "$presets" -ge 4 ] || bad "export_presets.example.cfg has $presets exclude filters, expected 4"

for repo in "${repos[@]}"; do
    dir="$(dir_of "$repo")"
    missing="$(grep '^exclude_filter=' export_presets.example.cfg | grep -cvF "addons/$dir/*")"
    [ "$missing" -eq 0 ] && good "every preset excludes addons/$dir/ ($repo)" \
        || bad "$missing preset(s) in export_presets.example.cfg do not exclude addons/$dir/* ($repo)"

    owner="gamemann/$repo"
    grep -qF "\"$owner\"" client/tmc_addon_namespaces.gd && good "the shell takes $owner as an overlay" \
        || bad "TmcAddonNamespaces.DEFAULTS lacks \"$owner\": the shell would refuse the addon it no longer carries"
done

for fn in ensure_shell_excludes shell_lock_begin check_shell_dot_only check_shell_web_size; do
    n="$(grep -c "^ *$fn\b" tools/server.in)"
    [ "$n" -ge 2 ] && good "tools/server.in defines and calls $fn" || bad "tools/server.in no longer calls $fn"
done

[ "$fails" -eq 0 ]
