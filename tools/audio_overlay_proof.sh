#!/usr/bin/env bash
# Proves a site-published dot-audio pack works as a shell overlay: a build with a dot-audio older than the stock-sound
# work (392f118~1, no DotAudioSinkGodot.stream_at) takes modcommunity/dot-audio from the content origin, restarts onto
# it, and plays a stock footstep and bed. The control start without the overlay must NOT have stream_at.
#   heavy -- tools/audio_overlay_proof.sh [--content-url URL] [--version 0.1.14]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAM="$(cd "$HERE/.." && pwd)"
base=https://dotgames.org/content version=0.1.14
while [ $# -gt 0 ]; do case $1 in
    --content-url) base=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    *) echo "usage: audio_overlay_proof.sh [--content-url URL] [--version V]" >&2; exit 2 ;;
esac; done
G="${GODOT:-godot}"
W="$(mktemp -d "$HOME/wt/audio-overlay-XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/proj/addons" "$W/home"
cp "$HERE"/tools/audio_overlay/{build,check,boot}.* "$W/proj/"
cp "$HERE/client/content.json" "$W/proj/content.json"
ln -s "$FAM/dot-core/addons/dot_core" "$W/proj/addons/dot_core"
ln -s "$FAM/dot-cloud/addons/dot_cloud" "$W/proj/addons/dot_cloud"
git -C "$FAM/dot-audio" archive "$(git -C "$FAM/dot-audio" rev-parse 392f118~1):addons/dot_audio" | tar -x -C "$W/proj" 
printf 'dot-audio\tv0.1.0\n' > "$W/proj/addons.lock"
cat > "$W/proj/project.godot" <<'P'
config_version=5

[application]

config/name="audio-overlay-proof"
run/main_scene="res://boot.tscn"
config/features=PackedStringArray("4.7")
P
export XDG_DATA_HOME="$W/home" XDG_CONFIG_HOME="$W/home"
cd "$W/proj"
timeout 240 "$G" --headless --path . --import >/dev/null 2>&1 || true
run() { timeout 120 "$G" --headless --audio-driver Dummy --path . "$@" 2>&1; }
fail=0
echo "== control: the build's own dot-audio"
control=$(run res://boot.tscn | grep '^CHECK ' || true); echo "$control"
echo "$control" | grep -q '"has_stream_at":false' || { echo "FAIL control has stream_at"; fail=1; }
echo "== build the overlay from $base (dot-audio $version)"
b=$(run res://build.tscn -- "$base" "$version" | grep -E '^BUILD' || true); echo "$b"
echo "$b" | grep -q 'BUILD ok=true' || { echo "FAIL overlay build"; fail=1; }
echo "== restart onto the overlay"
over=$(run res://boot.tscn | grep '^CHECK ' || true); echo "$over"
for k in '"has_stream_at":true' '"footstep_carpet_0.ogg":true' '"amb_indoor.ogg":true' '"advanced":true'; do
    echo "$over" | grep -q "$k" || { echo "FAIL missing $k"; fail=1; }
done
echo "$over" | grep -q '"overlay":""' && { echo "FAIL overlay not mounted"; fail=1; }
[ $fail = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
