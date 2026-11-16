#!/usr/bin/env bash
# setup.sh wires fc-weapons in under the directory its checkout holds (settle_renamed_dirs):
# addons/fc_weapons, or the deprecated legacy addons/arena_weapons at tags up to v1.4.51, with
# a warning naming the ref. A game naming the other side than its checkout is an error.
# Text and git only, on throwaway checkouts. Arm it by making settle_renamed_dirs a no-op.
set -uo pipefail
cd "$(dirname "$0")/.."
S=setup.sh; T="$(mktemp -d)"; pass=0; fail=0
eval "$(sed -n '/^addon_repo() {/,/^}/p;/^repo_alias() {/,/^}/p;/^addon_source() {/,/^}/p;/^git_root_of() {/,/^}/p;/^renamed_dir_other() {/,/^}/p;/^settle_renamed_dirs() {/,/^}/p' "$S")"
warn() { echo "WARN $1"; }
die() { echo "DIE $1"; exit "${2:-1}"; }
mk() { # dir tag holds
    mkdir -p "$1/addons/$3"; git -C "$1" init -q; touch "$1/addons/$3/plugin.cfg"
    git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=christianmdeacon@gmail.com commit -qm x; git -C "$1" tag "$2"; }
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }
ROOT="$T/p"; mkdir -p "$ROOT/addons"; ADDONS_DIR=""; ADDONS_REPOS="$T/repos"
mk "$T/repos/fc-weapons" v1.4.51 arena_weapons
out="$(ADDONS=(dot_core fc_weapons); settle_renamed_dirs; echo "LIST ${ADDONS[*]}")"
check "legacy ref swaps list name to arena_weapons" '[[ "$out" == *"LIST dot_core arena_weapons"* ]]'
check "legacy use warns naming the ref" '[[ "$out" == *"WARN addons/arena_weapons is a legacy directory (deprecated): fc-weapons at v1.4.51"* ]]'
out="$(ADDONS_FROM_GAMES=1; ADDONS=(fc_weapons); settle_renamed_dirs; echo "LIST ${ADDONS[*]}")"
check "game naming fc_weapons on legacy ref dies" '[[ "$out" == *"DIE A game here declares addons/fc_weapons, but fc-weapons at v1.4.51 holds addons/arena_weapons"* && "$out" != *LIST* ]]'
out="$(ADDONS_FROM_GAMES=1; ADDONS=(arena_weapons); settle_renamed_dirs; echo "LIST ${ADDONS[*]}")"
check "game naming legacy on legacy ref keeps and warns" '[[ "$out" == *"LIST arena_weapons"* && "$out" == *WARN* ]]'
rm -rf "$T/repos/fc-weapons"; mk "$T/repos/fc-weapons" v1.5.0 fc_weapons
out="$(ADDONS=(fc_weapons); settle_renamed_dirs; echo "LIST ${ADDONS[*]}")"
check "renamed ref keeps fc_weapons quietly" '[[ "$out" == "LIST fc_weapons" ]]'
out="$(ADDONS_FROM_GAMES=1; ADDONS=(arena_weapons); settle_renamed_dirs; echo "LIST ${ADDONS[*]}")"
check "game naming legacy on renamed ref dies" '[[ "$out" == *"DIE A game here declares addons/arena_weapons, but fc-weapons at v1.5.0 holds addons/fc_weapons"* ]]'
rm -rf "$T/repos/fc-weapons"
out="$(ADDONS=(fc_weapons); settle_renamed_dirs; echo "LIST ${ADDONS[*]}")"
check "absent checkout left for the clone step" '[[ "$out" == "LIST fc_weapons" ]]'
rm -rf "$T"; echo "  renamed addon dirs: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
