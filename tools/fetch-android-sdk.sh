#!/usr/bin/env bash
#
# Install the pinned Android SDK pieces an Android export needs, verify them, find JDK 17,
# and tell Godot where both are.
#
#   tools/fetch-android-sdk.sh                  install if missing, print the env lines
#   tools/fetch-android-sdk.sh --check          say whether SDK and JDK are ready, and exit
#   tools/fetch-android-sdk.sh --dest DIR       install somewhere other than the default
#   tools/fetch-android-sdk.sh --force          reinstall even if it is there
#   tools/fetch-android-sdk.sh --editor-settings
#                                               also write the two paths into the editor
#                                               settings file the export reads
#
# Stdout is `export ANDROID_HOME=...` and `export JAVA_HOME=...`, so `eval "$(...)"`
# works; everything said to a person goes to stderr.
#
# WHY THESE THREE
#
# The Android preset builds from the stock template APK (gradle build off), so Godot
# needs no NDK, no platform jar and no Gradle: it needs `apksigner` and `zipalign` from
# build-tools, `adb` from platform-tools (the exporter refuses an SDK path without it),
# and a JDK for apksigner and keytool. cmdline-tools is pinned too so `sdkmanager` is
# there for anyone who wants a gradle build later. Nothing here runs sdkmanager: it
# would fetch whatever Google lists that day, which is the thing a pin is for.
#
# The digest doctrine is fetch-godot.sh's: one version, the digests IN THIS FILE, a
# mismatch is fatal and the file is deleted. Google's repository manifest publishes only
# sha1, so the sha256 below were taken once from the downloaded archives after their
# sha1 matched the manifest:
#
#   curl -fsSL https://dl.google.com/android/repository/repository2-3.xml
#
# To move a pin: change the file name, check its sha1 against that manifest by eye,
# then paste the archive's sha256 here.

set -uo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; DIM=$'\e[2m'; OFF=$'\e[0m'
say()  { printf '    %s%s%s\n' "$DIM" "$1" "$OFF" >&2; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1" >&2; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }
die()  { printf '\n    %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }

BASE_URL="https://dl.google.com/android/repository"

BUILD_TOOLS_VERSION="35.0.1"
PLATFORM_TOOLS_VERSION="37.0.3"
CMDLINE_TOOLS_BUILD="13114758"   # cmdline-tools 19.0
JDK_MAJOR="17"

# name|sha256|top directory in the zip|where it goes under the SDK
PKG_linux=(
    "build-tools_r35.0.1_linux.zip|5993499f3229a021b89f87088c57242aeefaa62316bf3d69da7de40bfd5350f1|android-15|build-tools/$BUILD_TOOLS_VERSION"
    "platform-tools_r37.0.3-linux.zip|214548146cadb2ca3508143d8a1d4be4c59de5bb837253e3ede89ed74cf450d1|platform-tools|platform-tools"
    "commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip|7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee|cmdline-tools|cmdline-tools/latest"
)
PKG_macos=(
    "build-tools_r35.0.1_macosx.zip|c01e4b763da96ae5ef67e8bdf2abc94fb6cb3e73a42209581feb6a7019a51b9c|android-15|build-tools/$BUILD_TOOLS_VERSION"
    "platform-tools_r37.0.3-darwin.zip|f89baeb829903ceaf3ac92a78a2d25152728049d6316ebeaaca06d716e64842d|platform-tools|platform-tools"
    "commandlinetools-mac-${CMDLINE_TOOLS_BUILD}_latest.zip|5673201e6f3869f418eeed3b5cb6c4be7401502bd0aae1b12a29d164d647a54e|cmdline-tools|cmdline-tools/latest"
)

DEST="${TMC_ANDROID_SDK:-${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}/godot/android-sdk}"
CHECK_ONLY=0
FORCE=0
EDITOR_SETTINGS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check)           CHECK_ONLY=1; shift ;;
        --force)           FORCE=1; shift ;;
        --dest)            DEST="${2:?--dest needs a value}"; shift 2 ;;
        --editor-settings) EDITOR_SETTINGS=1; shift ;;
        -h|--help)         sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                 die "unknown argument: $1" 2 ;;
    esac
done

case "$(uname -s)" in
    Linux)  PKGS=("${PKG_linux[@]}") ;;
    Darwin) PKGS=("${PKG_macos[@]}") ;;
    *)      die "no pinned Android SDK archives for $(uname -s). On Windows use Android Studio's SDK manager and set the two editor settings by hand." 3 ;;
esac

# --- JDK 17 ------------------------------------------------------------------
#
# TMC_JAVA_HOME, then JAVA_HOME, then the usual install places, then `java` on PATH.
# Only 17 is accepted: it is the JDK Godot documents for Android, and a different one
# is a failure somebody meets later in Gradle or keytool with a worse message.
jdk_major() {
    local v
    v="$("$1/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
    v="${v#1.}"
    printf '%s\n' "${v%%[.+-]*}"
}

find_jdk() {
    local c cands=()

    [ -n "${TMC_JAVA_HOME:-}" ] && cands+=("$TMC_JAVA_HOME")
    [ -n "${JAVA_HOME:-}" ] && cands+=("$JAVA_HOME")
    [ -x /usr/libexec/java_home ] && c="$(/usr/libexec/java_home -v "$JDK_MAJOR" 2>/dev/null)" && cands+=("$c")
    for c in /usr/lib/jvm/*"$JDK_MAJOR"* /opt/*jdk*"$JDK_MAJOR"* "$HOME"/.local/share/*jdk*"$JDK_MAJOR"*; do
        [ -d "$c" ] && cands+=("$c")
    done
    if command -v java >/dev/null 2>&1; then
        c="$(readlink -f "$(command -v java)" 2>/dev/null)" && cands+=("${c%/bin/java}")
    fi

    [ ${#cands[@]} -gt 0 ] || return 1
    for c in "${cands[@]}"; do
        [ -x "$c/bin/java" ] && [ -x "$c/bin/keytool" ] || continue
        [ "$(jdk_major "$c")" = "$JDK_MAJOR" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

JDK="$(find_jdk)" || JDK=""

sdk_present() {
    [ -x "$DEST/build-tools/$BUILD_TOOLS_VERSION/apksigner" ] \
        && [ -x "$DEST/build-tools/$BUILD_TOOLS_VERSION/zipalign" ] \
        && [ -x "$DEST/platform-tools/adb" ] \
        && [ -x "$DEST/cmdline-tools/latest/bin/sdkmanager" ]
}

NO_JDK_MSG="no JDK $JDK_MAJOR found (TMC_JAVA_HOME, JAVA_HOME, /usr/lib/jvm, java on PATH).

    Install one -- Debian/Ubuntu: apt install openjdk-$JDK_MAJOR-jdk-headless; macOS:
    brew install openjdk@$JDK_MAJOR -- or point TMC_JAVA_HOME at an unpacked JDK $JDK_MAJOR
    (Adoptium Temurin works). It needs bin/java and bin/keytool."

if [ "$CHECK_ONLY" -eq 1 ]; then
    rc=0
    if sdk_present; then ok "Android SDK at $DEST"; else warn "no pinned Android SDK at $DEST"; rc=1; fi
    if [ -n "$JDK" ]; then ok "JDK $JDK_MAJOR at $JDK"; else warn "no JDK $JDK_MAJOR"; rc=1; fi
    exit "$rc"
fi

[ -n "$JDK" ] || die "$NO_JDK_MSG" 3

# --- Install -------------------------------------------------------------------

if ! sdk_present || [ "$FORCE" -eq 1 ]; then
    if   command -v curl >/dev/null 2>&1; then FETCH=curl
    elif command -v wget >/dev/null 2>&1; then FETCH=wget
    else die "need curl or wget to download the Android SDK" 3
    fi
    if   command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
    elif command -v shasum    >/dev/null 2>&1; then SHA="shasum -a 256"
    else die "need sha256sum or shasum to verify the download; nothing unverified is installed" 3
    fi
    command -v unzip >/dev/null 2>&1 || die "need unzip to unpack the Android SDK (it keeps the mode bits apksigner needs)" 3

    mkdir -p "$DEST" || die "could not create $DEST" 1
    # Staged beside the destination for the reason fetch-export-templates.sh gives: a
    # container's /tmp can be a small tmpfs, and the install is then a rename.
    TMP="$(mktemp -d "${TMPDIR:-$DEST}/android-sdk.XXXXXX")" || die "could not make a temporary directory" 1
    trap 'rm -rf "$TMP"' EXIT

    for row in "${PKGS[@]}"; do
        IFS='|' read -r name want top into <<<"$row"
        say "downloading $name"
        case "$FETCH" in
            curl) curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -s -o "$TMP/$name" "$BASE_URL/$name" ;;
            wget) wget -q --tries=3 --timeout=20 -O "$TMP/$name" "$BASE_URL/$name" ;;
        esac
        [ $? -eq 0 ] && [ -s "$TMP/$name" ] || die "could not download $BASE_URL/$name" 3

        got="$($SHA "$TMP/$name" | awk '{print $1}')"
        if [ "$got" != "$want" ]; then
            rm -f "$TMP/$name"
            die "CHECKSUM MISMATCH on $name -- the file has been deleted.

    expected  $want
    got       $got

    A corrupted download, or not the file this script was pinned to. Re-run once;
    if it happens again, do NOT work around it." 4
        fi
        ok "sha256 verified: $name"

        rm -rf "$TMP/x"
        unzip -q -o "$TMP/$name" -d "$TMP/x" < /dev/null || die "could not unpack $name (out of space?)" 3
        [ -d "$TMP/x/$top" ] || die "$name did not contain $top/" 3
        rm -rf "${DEST:?}/$into"
        mkdir -p "$(dirname "$DEST/$into")" || die "could not create $(dirname "$DEST/$into")" 1
        mv "$TMP/x/$top" "$DEST/$into" || die "could not install $into" 1
        rm -f "$TMP/$name"
    done

    sdk_present || die "installed into $DEST but apksigner, zipalign, adb or sdkmanager is missing" 3
    ok "Android SDK installed at $DEST"
else
    ok "Android SDK at $DEST"
fi
ok "JDK $JDK_MAJOR at $JDK"

# --- Tell Godot ----------------------------------------------------------------
#
# Godot falls back to ANDROID_HOME and JAVA_HOME for export/android/android_sdk_path and
# java_sdk_path only when its editor settings file has no such key. Any editor that has
# ever saved its settings has them (empty ones included), and then the env is ignored:
# a headless export fails with "A valid Java SDK path is required in Editor Settings".
# --editor-settings writes both keys into that file, which is what
# `./server export-native --platform android` uses. TMC_GODOT_VERSION names the Godot
# whose file to edit (the settings file is per major.minor); the default is the pin.
if [ "$EDITOR_SETTINGS" -eq 1 ]; then
    GODOT_VERSION="${TMC_GODOT_VERSION:-$("$(dirname "${BASH_SOURCE[0]}")/fetch-godot.sh" --version 2>/dev/null)}"
    [ -n "$GODOT_VERSION" ] || die "could not read the pinned Godot version from tools/fetch-godot.sh" 1
    mm="${GODOT_VERSION%%-*}"; mm="$(printf '%s' "$mm" | cut -d. -f1-2)"
    case "$mm" in [0-9]*.[0-9]*) ;; *) die "cannot tell a Godot major.minor from '$GODOT_VERSION'" 1 ;; esac
    case "$(uname -s)" in
        Darwin) cfgdir="$HOME/Library/Application Support/Godot" ;;
        *)      cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/godot" ;;
    esac
    es="$cfgdir/editor_settings-$mm.tres"
    mkdir -p "$cfgdir" || die "could not create $cfgdir" 1
    [ -f "$es" ] || printf '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n' > "$es" \
        || die "could not write $es" 1
    tmp="$(mktemp "$cfgdir/.editor_settings.XXXXXX")" || die "could not write in $cfgdir" 1
    awk -v sdk="$DEST" -v jdk="$JDK" '
        /^export\/android\/android_sdk_path *=/ || /^export\/android\/java_sdk_path *=/ { next }
        { print }
        /^\[resource\]$/ {
            print "export/android/android_sdk_path = \"" sdk "\""
            print "export/android/java_sdk_path = \"" jdk "\""
            done = 1
        }
        END { exit done ? 0 : 3 }
    ' "$es" > "$tmp" && mv "$tmp" "$es" || { rm -f "$tmp"; die "$es has no [resource] section; not editing it" 3; }
    ok "wrote export/android/android_sdk_path and java_sdk_path into $es"
else
    say "editor settings: export/android/android_sdk_path = $DEST"
    say "                 export/android/java_sdk_path    = $JDK"
fi

printf 'export ANDROID_HOME=%q\n' "$DEST"
printf 'export JAVA_HOME=%q\n' "$JDK"
