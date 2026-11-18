#!/usr/bin/env bash
# A shell carries the dot-* addons and nothing else. The game addons (the weapons packs,
# natural_disasters) reach a player as dot-cloud overlay packs when they join; baked in,
# fc-weapons (then arena-weapons) v1.4.28's embedded textures took the web pck from 44 MB to 147 MB.
#
# Text only, no Godot: every non-dot repository addons.lock names is excluded by every
# preset in export_presets.example.cfg, the shell takes its overlay (TmcAddonNamespaces),
# and tools/server.in still has the export guards. tools/shell_pck_check.sh proves the
# same thing on an exported pck. Arm it by deleting `addons/zee_weapons/*` from a preset,
# or by adding fc-weapons to tools/shell-addons.list.
#
# The shell's addons are an explicit list, tools/shell-addons.list, and tools/shell_lock.sh
# is what the export runs to cut addons.lock (the servers' lock, game addons included) down
# to it. This runs that script on the real lock and on lists it must refuse.
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
        # Both names: fc-weapons holds fc_weapons, its tags up to v1.4.51 the legacy arena_weapons.
        fc-weapons|arena-weapons) echo fc_weapons arena_weapons ;;
        *) echo "${1//-/_}" ;;
    esac
}

# Game addons: one game's own, never in a shell (the owner's rule; fc-weapons is Fatal Contact's).
GAME_ADDONS="fc-weapons arena-weapons zee-dot-weapons zed-dot-weapons natural-disasters"

[ -f tools/shell-addons.list ] && good "tools/shell-addons.list exists" || bad "no tools/shell-addons.list"
mapfile -t allowed < <(sed 's/#.*//; s/[[:space:]]//g; /^$/d' tools/shell-addons.list 2>/dev/null)
[ "${#allowed[@]}" -gt 0 ] || bad "tools/shell-addons.list names no addon"

for repo in "${allowed[@]}"; do
    case "$repo" in dot-*) ;; *) bad "tools/shell-addons.list names $repo, which is not a dot-* addon" ;; esac
    case " $GAME_ADDONS " in *" $repo "*) bad "tools/shell-addons.list names the game addon $repo" ;; esac
done

is_allowed() {
    local r
    for r in "${allowed[@]}"; do [ "$r" = "$1" ] && return 0; done
    return 1
}

# Every lock repository the list leaves out: what each preset must exclude.
mapfile -t repos < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ { print $1 }' addons.lock | while read -r r; do is_allowed "$r" || echo "$r"; done)
[ "${#repos[@]}" -gt 0 ] || bad "addons.lock names no game addon; this check reads nothing"

for repo in $(awk -F'\t' '!/^[[:space:]]*(#|$)/ && $1 ~ /^dot-/ { print $1 }' addons.lock); do
    is_allowed "$repo" || bad "addons.lock names $repo, which tools/shell-addons.list does not (the export would refuse to run)"
done

# What the export carries: tools/shell_lock.sh on the real lock holds the listed repositories and no other.
if out="$(tools/shell_lock.sh lock addons.lock)"; then
    stray="$(printf '%s\n' "$out" | awk -F'\t' '!/^[[:space:]]*(#|$)/ { print $1 }' | while read -r r; do is_allowed "$r" || echo "$r"; done | tr '\n' ' ')"
    [ -z "$stray" ] && good "the shell's addons.lock holds only listed addons" || bad "the shell's addons.lock holds ${stray% }"
    printf '%s\n' "$out" | grep -qE '^(fc|arena)-weapons'$'\t' && bad "the shell's addons.lock holds fc-weapons" \
        || good "the shell's addons.lock holds no fc-weapons (addons.lock does: it is the servers')"
else
    bad "tools/shell_lock.sh lock addons.lock failed"
fi

# It refuses a list naming a game addon, and a lock naming a dot-* addon the list does not.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
{ cat tools/shell-addons.list; echo fc-weapons; } > "$tmp/game.list"
SHELL_ADDONS_LIST="$tmp/game.list" tools/shell_lock.sh lock addons.lock > /dev/null 2>&1 \
    && bad "tools/shell_lock.sh took a list naming fc-weapons" || good "tools/shell_lock.sh refuses a list naming fc-weapons"
grep -vxF dot-core tools/shell-addons.list > "$tmp/short.list"
SHELL_ADDONS_LIST="$tmp/short.list" tools/shell_lock.sh lock addons.lock > /dev/null 2>&1 \
    && bad "tools/shell_lock.sh took a lock naming dot-core with a list that does not" \
    || good "tools/shell_lock.sh refuses a lock naming a dot-* addon the list does not"

grep -qF 'tools/shell_lock.sh" lock' tools/server.in && good "tools/server.in cuts the shell's lock with tools/shell_lock.sh" \
    || bad "tools/server.in no longer cuts the shell's lock with tools/shell_lock.sh"

presets="$(grep -c '^exclude_filter=' export_presets.example.cfg)"
[ "$presets" -ge 4 ] || bad "export_presets.example.cfg has $presets exclude filters, expected 4"

for repo in "${repos[@]}"; do
    for dir in $(dir_of "$repo"); do
        missing="$(grep '^exclude_filter=' export_presets.example.cfg | grep -cvF "addons/$dir/*")"
        [ "$missing" -eq 0 ] && good "every preset excludes addons/$dir/ ($repo)" \
            || bad "$missing preset(s) in export_presets.example.cfg do not exclude addons/$dir/* ($repo)"
    done

    owner="gamemann/$repo"
    grep -qF "\"$owner\"" client/tmc_addon_namespaces.gd && good "the shell takes $owner as an overlay" \
        || bad "TmcAddonNamespaces.DEFAULTS lacks \"$owner\": the shell would refuse the addon it no longer carries"
done

for fn in ensure_shell_excludes shell_lock_begin check_shell_dot_only check_shell_web_size; do
    n="$(grep -c "^ *$fn\b" tools/server.in)"
    [ "$n" -ge 2 ] && good "tools/server.in defines and calls $fn" || bad "tools/server.in no longer calls $fn"
done

[ "$fails" -eq 0 ]
