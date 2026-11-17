#!/usr/bin/env bash
# The phone presets (Android, iOS) and `./server export-native --platform android|ios`:
# what the presets carry, that `all` stays desktop, the iOS refusal off macOS, and the
# pinned SDK fetcher. Offline; the live run needs no Godot.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
GRN=$'\033[32m'; RED=$'\033[31m'; OFF=$'\033[0m'
bad=0
t() { if [ "$2" = 0 ]; then printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; else printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; bad=$((bad+1)); fi; }

ex=export_presets.example.cfg
preset() { awk -v n="name=\"$1\"" '/^\[preset\.[0-9]+\]$/ {p=0; w=0} $0 == n {p=1; w=1} /^\[preset\.[0-9]+\.options\]$/ {p=w; w=0} p' "$ex"; }
and="$(preset Android)"; ios="$(preset iOS)"

grep -qx 'platform="Android"' <<<"$and" && grep -qx 'export_path="build/android/tmc.apk"' <<<"$and"
t "the Android preset exports build/android/tmc.apk" $?
grep -qx 'gradle_build/use_gradle_build=false' <<<"$and" && grep -qx 'architectures/arm64-v8a=true' <<<"$and" \
    && [ "$(grep -c '^architectures/.*=true$' <<<"$and")" = 1 ] && grep -qx 'package/unique_name="net.dotgames.tmc"' <<<"$and"
t "Android: arm64-v8a only, gradle build off, package net.dotgames.tmc" $?
grep -qx 'keystore/debug=""' <<<"$and" && grep -qx 'keystore/release=""' <<<"$and"
t "Android: no keystore in the tracked preset (editor setting or GODOT_ANDROID_KEYSTORE_*)" $?
grep -qx 'platform="iOS"' <<<"$ios" && grep -qx 'export_path="build/ios/tmc.ipa"' <<<"$ios" \
    && grep -qx 'architectures/arm64=true' <<<"$ios" && grep -qx 'application/app_store_team_id=""' <<<"$ios"
t "the iOS preset exports build/ios/tmc.ipa, arm64, team id left empty" $?
for p in Android iOS; do
    f="$(preset "$p")"
    grep -q '^include_filter=".*addons\.lock' <<<"$f" && grep -q '^exclude_filter=".*\*\.gdextension, addons/\*/bin/\*' <<<"$f" \
        && grep -q '^exclude_filter=".*host/\*.*maps/imported/\*' <<<"$f"
    t "$p: includes addons.lock, excludes host/, maps/imported/ and every native library" $?
done
# The non-dot excludes are the same list the desktop presets carry.
nd() { preset "$1" | sed -n 's/^exclude_filter=".*screenshots\/\*, //p' | sed 's/^\*\.gdextension, addons\/\*\/bin\/\*, //'; }
[ -n "$(nd "Linux x86_64")" ] && [ "$(nd Android)" = "$(nd "Linux x86_64")" ] && [ "$(nd iOS)" = "$(nd "Linux x86_64")" ]
t "the phone presets exclude the same non-dot addons as the desktop ones" $?

for f in tools/server.in tools/server.ps1.in; do
    grep -q 'android' "$f" && grep -q 'ios' "$f" && grep -q 'linux, windows, macos, all, android or ios' "$f"
    t "$f takes --platform android and ios" $?
done
grep -q "all)                        targets=(linux windows macos) ;;" tools/server.in \
    && grep -q "'^(all)\$'                     { @('linux', 'windows', 'macos'); break }" tools/server.ps1.in
t "--platform all stays the desktop three" $?
grep -q 'ensure_preset_from_example "$preset"' tools/server.in && grep -q 'Add-PresetFromExample $presetFile' tools/server.ps1.in
t "export-native copies a missing preset in from export_presets.example.cfg" $?
grep -q 'IsMacOS' tools/server.ps1.in
t "server.ps1 refuses an iOS export off macOS" $?

f=tools/fetch-android-sdk.sh
[ -x "$f" ] && bash -n "$f"
t "$f is executable and parses" $?
[ "$(grep -cE '^ *"[^|]+\.zip\|[0-9a-f]{64}\|' "$f")" = 6 ]
t "$f pins build-tools, platform-tools and cmdline-tools by sha256 for linux and mac" $?
grep -q 'export/android/android_sdk_path' "$f" && grep -q 'export/android/java_sdk_path' "$f"
t "$f names the SDK and the JDK to the editor" $?
# A saved key, even an empty one, beats ANDROID_HOME/JAVA_HOME, so the env alone fails.
grep -q 'TMC_GODOT_VERSION="$VERSION" "$fetch" --editor-settings' tools/server.in \
    && grep -q 'export/android/java_sdk_path = ' tools/server.ps1.in
t "both launchers write the SDK and JDK paths into the exporting Godot's editor settings" $?

# Live: the refusal comes before any fetch or write, so it runs without Godot.
if [ "$(uname -s)" != "Darwin" ]; then
    T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
    # The launcher wants an engine, a project, cfg/ and content/ before any command runs.
    printf '#!/bin/sh\necho 4.7.2.stable\n' > "$T/godot"; chmod +x "$T/godot"
    touch "$T/project.godot"; mkdir -p "$T/cfg" "$T/content"
    sed "s|@GODOT@|$T/godot|g" tools/server.in > "$T/server"
    out="$(cd "$T" && bash ./server export-native --platform ios 2>&1)"; rc=$?
    [ "$rc" = 3 ] && grep -q 'an iOS export needs a Mac with Xcode' <<<"$out" && [ ! -e "$T/build" ] && [ ! -e "$T/export_presets.cfg" ]
    t "export-native --platform ios off macOS exits 3, says why, builds nothing" $?
    out="$(cd "$T" && bash ./server export-native --platform tvos 2>&1)"; rc=$?
    [ "$rc" = 2 ] && grep -q 'android or ios' <<<"$out"
    t "export-native --platform with an unknown name exits 2 and lists android and ios" $?
fi
exit $((bad > 0))
