#!/usr/bin/env bash
# Unpack the native library of every locked addon that has one (dot-sim) into its
# repository: addons/<addon>/bin/<platform>/ and the .gdextension, which addons/<addon>
# (a link into that repository) then shows to Godot.
#
#   tools/fetch-natives.sh                        this machine's platform
#   tools/fetch-natives.sh --platform linux-x86_64 --platform windows-x86_64
#   tools/fetch-natives.sh --no-clone             do not clone dot-bootstrap when it is absent
#
# [b]Not a second copy of the fetcher.[/b] The download, the SHA256SUMS.natives check, the
# stamp and the keep-a-local-build rule are dot-bootstrap's `fetch_natives`; this lifts
# that function (and the helpers it needs) out of bootstrap.sh at run time, the way
# dot-bootstrap's own tests do, and supplies only what is specific to here: the pin comes
# from addons.lock instead of a game's .gitignore. bootstrap.sh is looked for in
# $DOT_BOOTSTRAP, beside this checkout, and in addons/.repos/; a server box that has none
# clones it shallow into addons/.repos/ (unless --no-clone).
#
# [b]Never run for export-web.[/b] A .gdextension in a web build stops every script. The Web
# preset excludes `*.gdextension` and `addons/*/bin/*`, and tools/check.sh checks both.
# DOT_NATIVES=none skips everything; a platform with no zip warns and the GDScript twins run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_REPOS="dot-sim"          # addons that publish a platform zip
PLATFORMS=(); CLONE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORMS+=("$2"); shift 2 ;;
        --no-clone) CLONE=0; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ "${DOT_NATIVES:-}" = none ] && exit 0
[ -n "${TMC_NO_CLONE:-}" ] && CLONE=0

BOOT=""
for c in "${DOT_BOOTSTRAP:-}" "$ROOT/../dot-bootstrap" "$ROOT/addons/.repos/dot-bootstrap"; do
    [ -n "$c" ] && [ -f "$c/bootstrap.sh" ] && { BOOT="$c/bootstrap.sh"; break; }
done
if [ -z "$BOOT" ] && [ "$CLONE" = 1 ] && [ -d "$ROOT/addons" ]; then
    mkdir -p "$ROOT/addons/.repos"; [ -f "$ROOT/addons/.repos/.gdignore" ] || : > "$ROOT/addons/.repos/.gdignore"
    git clone --quiet --depth 1 "${TMC_GIT_BASE:-https://github.com/modcommunity}/dot-bootstrap.git" \
        "$ROOT/addons/.repos/dot-bootstrap" 2>/dev/null && BOOT="$ROOT/addons/.repos/dot-bootstrap/bootstrap.sh"
fi
if [ -z "$BOOT" ]; then
    echo "    !!   dot-sim: native motor=off (dot-bootstrap's bootstrap.sh not found; GDScript runs, slower)"
    exit 0
fi

for f in native_platform native_built_here fetch_natives; do eval "$(sed -n "/^$f() {/,/^}/p" "$BOOT")"; done
declare -F fetch_natives >/dev/null || { echo "    !!   $BOOT has no fetch_natives" >&2; exit 0; }
GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
say()  { printf '    %s--%s   %s\n' "$DIM" "$OFF" "${2:-$1}"; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "${2:-$1}"; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "${2:-$1}"; }
err()  { printf '    %s!!%s   %s\n' "$RED" "$OFF" "${2:-$1}"; RC=1; }
RC=0

# The pin comes from addons.lock; the place is the repository addons/<addon> links into.
natives_for() {
    local repo tag
    for repo in $NATIVE_REPOS; do
        tag="$(awk -F'\t' -v r="$repo" '$1==r{print $2}' "$ROOT/addons.lock")"
        [ -n "$tag" ] && printf '%s\t%s\t%s\tbin\n' "$repo" "$tag" "${repo//-/_}"
    done
}

[ ${#PLATFORMS[@]} -gt 0 ] || PLATFORMS=("$(native_platform)") || exit 0
HOST_PLAT="${PLATFORMS[0]}"
for repo in $NATIVE_REPOS; do
    addon="${repo//-/_}"
    [ -d "$ROOT/addons/$addon" ] || continue
    repo_root="$(cd "$(cd "$ROOT/addons/$addon" && pwd -P)/../.." && pwd -P)"
    PROJECTS_DIR="$(dirname "$repo_root")"
    on_disk() { basename "$repo_root"; }
    for p in "${PLATFORMS[@]}"; do
        native_platform() { echo "$p"; }
        fetch_natives "$ROOT"
    done
    lib="$repo_root/addons/$addon"
    if [ -f "$lib/$addon.gdextension" ] && [ -n "$(ls -A "$lib/bin/$HOST_PLAT" 2>/dev/null)" ]; then
        ok "$repo: native motor=on (${PLATFORMS[*]})"
    else
        warn "$repo: native motor=off (no library for ${PLATFORMS[*]}; GDScript runs, slower)"
    fi
done
exit "$RC"
