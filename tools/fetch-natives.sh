#!/usr/bin/env bash
#
# Install the native libraries (GDExtensions) of the addons this tree carries, verified.
#
#   tools/fetch-natives.sh                        this machine's platform
#   tools/fetch-natives.sh --platform windows-x86_64,linux-x86_64
#   tools/fetch-natives.sh --platform all         every platform natives.lock pins
#   tools/fetch-natives.sh --pin                  rewrite natives.lock from the releases
#   tools/fetch-natives.sh --root DIR             another project (default: this one)
#
# Prints on stdout how many libraries it installed (setup.sh re-imports when that is not
# 0); everything said to a person goes to stderr.
#
# WHY THIS EXISTS
#
# dot-sim's motor, snapshot codec and bot sight scan are Rust, and its release zips carry
# the library (addons/dot_sim/bin/<platform>/) and the .gdextension that names it. Neither
# is in git, so a clone or a --vendor copy of the addon has only the GDScript twins: the
# same results, slower, and nothing says so. A 32-player server with bots is where the
# difference is paid, so the server installs the library rather than inheriting
# whichever copy happened to be beside it.
#
# THE DIGESTS ARE IN natives.lock, in git, the way fetch-godot.sh keeps Godot's. The
# release's SHA256SUMS.natives is only read by --pin, for a person to review in the diff;
# an install never trusts a sums file served beside the zip it checks. A mismatch deletes
# the download and fails.
#
# A library is kept when it is already there: a stamp (bin/.natives, "tag platform" per
# line, the format dot-bootstrap writes) says which release it came from, and a bin/
# without a stamp is a local build (ci/install.sh), which is never replaced. No pin for a
# platform, or a pin for another tag than addons.lock's: a warning, and the GDScript twins
# run. Godot loads a GDExtension only once an import has listed it in
# .godot/extension_list.cfg, which is why the caller re-imports after an install.
#
# The web build never carries these: export_presets' Web preset excludes them, because a
# .gdextension in a plain web export stops every script (dot-sim docs/web.md).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORMS=""
PIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT="$(cd "${2:?--root needs a directory}" && pwd)" || exit 2; shift 2 ;;
        --platform) PLATFORMS="${2:?--platform needs a value}"; shift 2 ;;
        --pin)      PIN=1; shift ;;
        -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# repo<TAB>addon directory. One row per addon that ships a native library.
NATIVE_ADDONS="dot-sim	dot_sim"

LOCK="$ROOT/addons.lock"
PINS="$ROOT/natives.lock"
BASE="${DOT_NATIVES_BASE:-https://github.com/modcommunity}"

RED=$'\033[31m'; YLW=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1" >&2; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }
note() { printf '    %s--   %s%s\n' "$DIM" "$1" "$OFF" >&2; }
err()  { printf '    %sXX%s   %s\n' "$RED" "$OFF" "$1" >&2; }

host_platform() {
    local os arch
    case "$(uname -s)" in
        Linux) os=linux ;; Darwin) os=macos ;; MINGW*|MSYS*|CYGWIN*) os=windows ;; *) return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;;
    esac
    echo "$os-$arch"
}

lock_tag() { awk -F'\t' -v r="$1" '$1 == r {print $2; exit}' "$LOCK" 2>/dev/null; }

sha256_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }

# --- --pin: natives.lock from each release's SHA256SUMS.natives ----------------
if [ "$PIN" -eq 1 ]; then
    out="$(mktemp "$ROOT/.natives.lock.XXXXXX")" || exit 1
    printf '# The native libraries tools/fetch-natives.sh installs, and their digests.\n# Written by tools/fetch-natives.sh --pin from each release'"'"'s SHA256SUMS.natives;\n# review the diff. repo<TAB>tag<TAB>platform<TAB>sha256(zip).\n' > "$out"
    while IFS=$'\t' read -r repo _addon; do
        tag="$(lock_tag "$repo")"
        [ -n "$tag" ] || { warn "$repo is not in addons.lock"; continue; }
        sums="$(curl -fsSL "$BASE/$repo/releases/download/$tag/SHA256SUMS.natives")" \
            || { err "$repo $tag has no SHA256SUMS.natives"; rm -f "$out"; exit 1; }
        awk -v r="$repo" -v t="$tag" '
            match($2, /-(linux|windows|macos)-[a-z0-9_]+\.zip$/) {
                p = substr($2, RSTART + 1, RLENGTH - 5); print r "\t" t "\t" p "\t" $1 }' \
            <<< "$sums" | sort >> "$out"
        ok "$repo $tag: $(awk -F'\t' -v r="$repo" '$1 == r {printf "%s ", $3}' "$out")"
    done <<< "$NATIVE_ADDONS"
    mv "$out" "$PINS"
    exit 0
fi

[ "${DOT_NATIVES:-}" = none ] && { echo 0; exit 0; }
[ -f "$PINS" ] || { warn "no natives.lock, so no native libraries (GDScript runs, slower)"; echo 0; exit 0; }

installed=0
failed=0

# Replace or add each `key = value` of <new>'s [libraries] in <dest>, keeping the rest.
merge_gdextension() {
    local dest="$1" new="$2" tmp
    if [ ! -f "$dest" ]; then cp "$new" "$dest"; return; fi
    tmp="$(mktemp "$dest.XXXXXX")" || return 1
    awk '
        FNR == NR { if ($0 ~ /^\[/) nsec = $0; else if (nsec == "[libraries]" && $0 ~ /=/) { k = $1; add[k] = $0; order[++n] = k }; next }
        /^\[/ { if (sec == "[libraries]") flush(); sec = $0; print; next }
        sec == "[libraries]" && /=/ { k = $1; if (k in add) { print add[k]; done[k] = 1 } else print; next }
        { print }
        END { if (sec == "[libraries]") flush() }
        function flush(  i) { for (i = 1; i <= n; i++) if (!(order[i] in done)) { print add[order[i]]; done[order[i]] = 1 } }
    ' "$new" "$dest" > "$tmp" && mv "$tmp" "$dest"
}

install_one() {
    local repo="$1" addon="$2" tag="$3" plat="$4" want="$5"
    local dir="$ROOT/addons/$addon" lib stamp work file got ext
    lib="$dir/bin"
    stamp="$lib/.natives"

    if [ -f "$stamp" ] && grep -qx "$tag $plat" "$stamp"; then
        note "$addon: $tag $plat already installed"; return 0
    fi
    if [ ! -f "$stamp" ] && [ -n "$(ls -A "$lib/$plat" 2>/dev/null)" ]; then
        note "$addon: keeps the $plat library built here (no stamp)"; return 0
    fi

    file="${addon}-${tag#v}-${plat}.zip"
    # Staged beside the destination, not in /tmp: a different filesystem makes the move
    # a copy, and a full /tmp leaves half a library behind.
    work="$(mktemp -d "$ROOT/.natives-fetch.XXXXXX")" || return 1
    if ! curl -fsSL -o "$work/$file" "$BASE/$repo/releases/download/$tag/$file"; then
        warn "$addon: could not download $file (GDScript runs, slower)"; rm -rf "$work"; return 0
    fi
    got="$(sha256_of "$work/$file")"
    if [ "$got" != "$want" ]; then
        err "$addon: $file does not match natives.lock ($got), deleted, not installed"
        rm -rf "$work"; failed=$((failed + 1)); return 1
    fi
    if command -v unzip >/dev/null 2>&1; then unzip -qo "$work/$file" -d "$work/x"
    else python3 -m zipfile -e "$work/$file" "$work/x"; fi \
        || { err "$addon: could not unpack $file"; rm -rf "$work"; failed=$((failed + 1)); return 1; }
    [ -d "$work/x/addons/$addon/bin/$plat" ] \
        || { err "$addon: $file has no addons/$addon/bin/$plat"; rm -rf "$work"; failed=$((failed + 1)); return 1; }

    # Another tag's libraries go first: one .gdextension names one release.
    if [ -f "$stamp" ] && grep -qv "^$tag " "$stamp"; then
        rm -rf "${lib:?}"/* "$stamp" "$dir"/*.gdextension
    fi
    mkdir -p "$lib"
    rm -rf "${lib:?}/$plat"
    mv "$work/x/addons/$addon/bin/$plat" "$lib/$plat"
    chmod +x "$lib/$plat"/* 2>/dev/null
    for ext in "$work/x/addons/$addon"/*.gdextension; do
        [ -f "$ext" ] && merge_gdextension "$dir/$(basename "$ext")" "$ext"
    done
    echo "$tag $plat" >> "$stamp"
    rm -rf "$work"
    ok "$addon: $repo $tag ($plat) installed"
    installed=$((installed + 1))
}

while IFS=$'\t' read -r repo addon; do
    [ -d "$ROOT/addons/$addon" ] || continue      # this build does not carry it
    tag="$(lock_tag "$repo")"
    [ -n "$tag" ] || { warn "$addon: $repo is not in addons.lock"; continue; }
    pinned_tag="$(awk -F'\t' -v r="$repo" '$1 == r {print $2; exit}' "$PINS")"
    if [ "$pinned_tag" != "$tag" ]; then
        warn "$addon: natives.lock pins ${pinned_tag:-nothing} but addons.lock says $tag (GDScript runs, slower)"
        printf '           tools/fetch-natives.sh --pin, then review the digests\n' >&2
        continue
    fi
    case "${PLATFORMS:-host}" in
        host) plats="$(host_platform)" || { warn "$addon: no native platform for $(uname -sm)"; continue; } ;;
        all)  plats="$(awk -F'\t' -v r="$repo" '$1 == r {print $3}' "$PINS")" ;;
        *)    plats="${PLATFORMS//,/ }" ;;
    esac
    for plat in $plats; do
        want="$(awk -F'\t' -v r="$repo" -v p="$plat" '$1 == r && $3 == p {print $4; exit}' "$PINS")"
        if [ -z "$want" ]; then
            warn "$addon: $repo $tag has no $plat library pinned (GDScript runs there, slower)"; continue
        fi
        install_one "$repo" "$addon" "$tag" "$plat" "$want"
    done
done <<< "$NATIVE_ADDONS"

echo "$installed"
[ "$failed" -eq 0 ]
