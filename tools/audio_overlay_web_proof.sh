#!/usr/bin/env bash
# Web half of audio_overlay_proof.sh: an exported web build whose dot-audio predates the stock sounds, behind dot_audio_ceiling.js,
# builds the site's modcommunity/dot-audio overlay in the browser, reloads onto it and plays a stock footstep and bed in headless Chromium.
# Local only: serves the export and /content (cached from the real content origin) on 127.0.0.1; deploys and pins nothing.
#   heavy -- tools/audio_overlay_web_proof.sh [--content-url URL] [--version 0.1.14] [--port 8791]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAM="$(cd "$HERE/.." && pwd)"
base=https://dotgames.org/content version=0.1.14 port=8791
while [ $# -gt 0 ]; do case $1 in
    --content-url) base=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --port) port=${2:?}; shift 2 ;;
    *) echo "usage: audio_overlay_web_proof.sh [--content-url URL] [--version V] [--port N]" >&2; exit 2 ;;
esac; done
G="${GODOT:-godot}"
T="$HERE/tools/audio_overlay"
W="$(mktemp -d "$HOME/wt/audio-overlay-web-XXXXXX")"; trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$W"' EXIT
mkdir -p "$W/proj/addons" "$W/out" "$W/cache"
cp "$T"/web/{main.tscn,run.tscn,run.gd} "$W/proj/"
cp "$HERE/client/content.json" "$W/proj/content.json"
echo "$version" > "$W/proj/version.txt"
ln -s "$FAM/dot-core/addons/dot_core" "$W/proj/addons/dot_core"
ln -s "$FAM/dot-cloud/addons/dot_cloud" "$W/proj/addons/dot_cloud"
git -C "$FAM/dot-audio" archive "$(git -C "$FAM/dot-audio" rev-parse 392f118~1):addons/dot_audio" | tar -x -C "$W/proj"
printf 'dot-audio\tv0.1.0\n' > "$W/proj/addons.lock"
cat > "$W/proj/project.godot" <<'P'
config_version=5

[application]

config/name="audio-overlay-web-proof"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.7")
P
cat > "$W/proj/export_presets.cfg" <<'P'
[preset.0]

name="Web"
platform="Web"
runnable=true
export_filter="all_resources"
include_filter="addons.lock, version.txt"
exclude_filter=""
export_path="../out/index.html"
script_export_mode=2

[preset.0.options]

variant/extensions_support=false
variant/thread_support=false
vram_texture_compression/for_desktop=true
vram_texture_compression/for_mobile=false
html/export_icon=false
P
cd "$W/proj"
timeout 240 "$G" --headless --path . --import >/dev/null 2>&1 || true
echo "== export web"
timeout 300 "$G" --headless --path . --export-release Web 2>&1 | grep -vE "^(Godot Engine|$)" | tail -8 || true
[ -f "$W/out/index.wasm" ] || { echo "FAIL no web export"; exit 1; }
# The same page edits ./server export-web makes: DotWeb's page side and the ceiling, ahead of the engine script.
# The pack is the OLD dot-audio's, so the ceiling file comes from the current checkout.
cp "$FAM/dot-core/addons/dot_core/web/dot_web.js" "$FAM/dot-audio/addons/dot_audio/web/dot_audio_ceiling.js" "$W/out/"
sed -i 's#<head>#<head>\n<script src="dot_web.js"></script>\n<script src="dot_audio_ceiling.js"></script>#' "$W/out/index.html"
python3 "$T/web/serve.py" "$W/out" "$W/cache" "$base" "$port" &
sleep 1
echo "== Chromium"
node "$T/web/check.mjs" "http://127.0.0.1:$port/index.html"
