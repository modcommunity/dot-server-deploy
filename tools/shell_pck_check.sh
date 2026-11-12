#!/usr/bin/env bash
# Proves the client shell's pck does not carry dot-map's surface textures or dot-audio's ambience beds and mood set (they ride in a dot-cloud pack and resolve through
# DotMapSurfaces.fallback_roots / DotAudioStock.fallback_roots; dot-map's examples/surfaces_pack_selftest and dot-audio's
# examples/stock_pack_selftest prove that half), nor any addon that is not a dot-* addon. Also checks the preset text: only the Web preset excludes them, desktop presets ship them. Prints the pck size.
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
# A shell carries the dot-* addons only (tools/check_shell_addons.sh has the why); the game addons are overlay packs.
others="$(grep -oE 'addons/[a-z0-9_]+/' <<<"$paths" | sort -u | grep -v '^addons/dot_' || true)"
[ -z "$others" ] || { echo "FAIL: the shell pck carries addons that are not dot-*: $(echo $others)"; exit 1; }
# The exclusions are the Web preset's alone: every desktop preset must still ship the textures, beds and moods.
python3 - export_presets.example.cfg <<'PY' || exit 1
import re, sys
text = open(sys.argv[1]).read()
need = ["addons/dot_map/surfaces/", "addons/dot_audio/stock/ambience/", "addons/dot_audio/stock/moods/"]
seen = {"Web": 0, "desktop": 0}
bad = []
for block in re.split(r"(?m)^(?=\[preset\.\d+\]$)", text):
    plat = re.search(r'(?m)^platform="([^"]*)"', block)
    exc = re.search(r'(?m)^exclude_filter="([^"]*)"', block)
    inc = re.search(r'(?m)^include_filter="([^"]*)"', block)
    if not plat or not exc:
        continue
    if plat.group(1) == "Web":
        seen["Web"] += 1
        bad += ["Web preset no longer excludes " + n for n in need if n not in exc.group(1)]
        if "*.html" not in (inc.group(1) if inc else ""):
            bad.append("Web preset include_filter lacks *.html")
    else:
        seen["desktop"] += 1
        bad += [plat.group(1) + " preset excludes " + n for n in need if n in exc.group(1)]
if not seen["Web"] or not seen["desktop"]:
    bad.append("expected a Web and a desktop preset, saw %r" % seen)
if bad:
    print("FAIL: " + "; ".join(bad)); sys.exit(1)
PY
echo "OK: surface textures and ambience are out of the Web shell pck only (desktop presets keep them), DotMapSurfaces and DotAudioStock are in, no non-dot addon is"
