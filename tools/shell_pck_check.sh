#!/usr/bin/env bash
# Proves the client shell's pck does not carry dot-map's surface textures (they ride in a dot-cloud pack and resolve through
# DotMapSurfaces.fallback_roots; dot-map's examples/surfaces_pack_selftest proves that half). Prints the pck size.
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
echo "OK: surface textures are out of the shell pck, DotMapSurfaces is in"
