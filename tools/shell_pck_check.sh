#!/usr/bin/env bash
# Proves the client shell's pck does not carry dot-map's surface textures or dot-audio's ambience beds and mood set (they ride in a dot-cloud pack and resolve through
# DotMapSurfaces.fallback_roots / DotAudioStock.fallback_roots; dot-map's examples/surfaces_pack_selftest and dot-audio's
# examples/stock_pack_selftest prove that half). Prints the pck size.
#   heavy -- tools/shell_pck_check.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
G="${GODOT:-godot}"
cd "$HERE"
[ -f export_presets.cfg ] || cp export_presets.example.cfg export_presets.cfg
out="$(mktemp -d)/shell.pck"; trap 'rm -rf "$(dirname "$out")"' EXIT
timeout 600 "$G" --headless --path . --import >/dev/null 2>&1 || true
timeout 900 "$G" --headless --path . --export-pack Web "$out" >/dev/null 2>&1
echo "shell pck: $(stat -c %s "$out") bytes"
paths="$(strings -n 12 "$out")"
if grep -Eq 'addons/dot_map/surfaces/[a-z_]+/[^/]+\.(jpg|webp|ctex|import)' <<<"$paths"; then
    echo "FAIL: surface textures are still in the shell pck"; exit 1
fi
grep -q 'addons/dot_map/surfaces/dot_map_surfaces.gd' <<<"$paths" || { echo "FAIL: DotMapSurfaces script missing"; exit 1; }
if grep -Eq 'addons/dot_audio/stock/(ambience|moods)/' <<<"$paths"; then
    echo "FAIL: ambience beds or the mood set are still in the shell pck"; exit 1
fi
grep -q 'addons/dot_audio/core/dot_audio_stock.gd' <<<"$paths" || { echo "FAIL: DotAudioStock script missing"; exit 1; }
grep -q 'addons/dot_audio/stock/footsteps/' <<<"$paths" || { echo "FAIL: footsteps should stay in the shell"; exit 1; }
echo "OK: surface textures and ambience are out of the shell pck, DotMapSurfaces and DotAudioStock are in"
