#!/usr/bin/env bash
# The dot-sim platform zip is unpacked by setup.sh and export-native (tools/fetch-natives.sh,
# which reuses dot-bootstrap's fetcher) and never reaches export-web. Offline.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; OFF=$'\033[0m'
bad=0
t() { if [ "$2" = 0 ]; then printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; else printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; bad=$((bad+1)); fi; }

grep -q 'tools/fetch-natives.sh' setup.sh;               t "setup.sh runs tools/fetch-natives.sh" $?
grep -q 'tools/fetch-natives.sh' tools/server.in;        t "export-native runs tools/fetch-natives.sh" $?
# the call sits in do_export_native, not in the export-web branch
awk '/^do_export_native\(\)/{in_n=1} in_n&&/fetch-natives.sh/{f=1} /^    export-web\)/{in_n=0; w=1} w&&/fetch-natives.sh/{bad=1} END{exit !(f&&!bad)}' tools/server.in
t "fetch-natives.sh is called from do_export_native and not from export-web" $?
web="$(awk '/^\[preset\.[0-9]+\]$/{p=0} /^name="Web"/{p=1} p&&/^exclude_filter=/' export_presets.example.cfg)"
{ grep -qF '*.gdextension' <<<"$web" && grep -qF 'addons/*/bin/*' <<<"$web"; }
t "the Web preset excludes *.gdextension and addons/*/bin/*" $?
grep -q 'carries a .gdextension' tools/server.in;        t "export-web refuses a pck that carries a .gdextension" $?
grep -qP '^dot-sim\tv' addons.lock;                      t "addons.lock pins dot-sim" $?

# The Windows twins: setup.ps1 and server.ps1.in run tools/fetch-natives.ps1 (export-native for
# the platforms being built, never export-web), which lifts dot-bootstrap's Fetch-Natives.
grep -q 'tools/fetch-natives.ps1' setup.ps1;             t "setup.ps1 runs tools/fetch-natives.ps1" $?
grep -q 'fetch-natives.ps1' tools/server.ps1.in;         t "server.ps1 export-native runs tools\\fetch-natives.ps1" $?
awk '/^function Invoke-ExportNative/{p=1} p&&/fetch-natives.ps1/{f=1} /^function Get-Tail/{p=0} END{exit !f}' tools/server.ps1.in
t "the ps1 call sits in Invoke-ExportNative" $?
awk '/^    .export-web. \{/{p=1} /^    .export-native. \{/{p=0} p&&/fetch-natives/{f=1} END{exit f}' tools/server.ps1.in
t "export-web (ps1) does not call fetch-natives" $?
grep -q 'carries a .gdextension' tools/server.ps1.in;    t "export-web (ps1) refuses a pck that carries a .gdextension" $?
grep -q 'addons.lock' tools/fetch-natives.ps1;           t "fetch-natives.ps1 takes the pin from addons.lock" $?
grep -q 'Fetch-Natives' tools/fetch-natives.ps1 && ! grep -q 'Invoke-WebRequest' tools/fetch-natives.ps1
t "fetch-natives.ps1 reuses bootstrap.ps1's Fetch-Natives (no download code of its own)" $?
grep -q '\.natives-' tools/fetch-natives.sh && grep -q '\.natives-' tools/fetch-natives.ps1
t "per-platform stamps in both fetchers (macOS arm64 + x86_64 do not undo each other)" $?
if command -v pwsh >/dev/null 2>&1; then
    for f in setup.ps1 tools/server.ps1.in tools/fetch-natives.ps1; do
        PSFILE="$f" pwsh -NoProfile -Command '$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:PSFILE,[ref]$null,[ref]$e); if($e){$e|%{$_.ToString()}; exit 1}' >/dev/null
        t "pwsh parses $f" $?
    done
else
    printf '  %sSKIP%s pwsh syntax check: pwsh is not installed (static greps above stand in)\n' "$YLW" "$OFF"
fi

# A fake release unpacks, is checksum-verified, and the library lands in the addon's repository.
boot=""
for c in "${DOT_BOOTSTRAP:-}" ../dot-bootstrap; do [ -n "$c" ] && [ -f "$c/bootstrap.sh" ] && { boot="$c"; break; }; done
if [ -z "$boot" ]; then
    printf '  %sSKIP%s the unpack run: no dot-bootstrap beside this checkout (DOT_BOOTSTRAP=)\n' "$YLW" "$OFF"
else
    T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
    plat="$(eval "$(sed -n '/^native_platform() {/,/^}/p' "$boot/bootstrap.sh")"; native_platform)"
    mkdir -p "$T/p/dot-sim/addons/dot_sim" "$T/p/srv/tools" "$T/p/srv/addons" "$T/z/addons/dot_sim/bin/$plat"
    cp tools/fetch-natives.sh "$T/p/srv/tools/"; printf 'dot-sim\tv9.9.9\n' > "$T/p/srv/addons.lock"
    ln -s ../../dot-sim/addons/dot_sim "$T/p/srv/addons/dot_sim"
    echo lib > "$T/z/addons/dot_sim/bin/$plat/libdot_sim.so"; echo ext > "$T/z/addons/dot_sim/dot_sim.gdextension"
    R="$T/rel/dot-sim/releases/download/v9.9.9"; mkdir -p "$R"
    (cd "$T/z" && python3 -m zipfile -c "$R/dot_sim-9.9.9-$plat.zip" addons)
    (cd "$R" && sha256sum "dot_sim-9.9.9-$plat.zip" > SHA256SUMS.natives)
    out="$(DOT_BOOTSTRAP="$boot" DOT_NATIVES_BASE="file://$T/rel" bash "$T/p/srv/tools/fetch-natives.sh" 2>&1)"
    [ -f "$T/p/dot-sim/addons/dot_sim/bin/$plat/libdot_sim.so" ] && [ -f "$T/p/dot-sim/addons/dot_sim/dot_sim.gdextension" ]
    t "the platform zip unpacks into the addon's repository" $?
    grep -q 'dot-sim: native motor=on' <<<"$out"; t "it logs 'dot-sim: native motor=on'" $?
    rm -rf "$T/p/dot-sim/addons/dot_sim/bin" "$T/p/dot-sim/addons/dot_sim/dot_sim.gdextension"
    echo bad > "$R/dot_sim-9.9.9-$plat.zip"
    out="$(DOT_BOOTSTRAP="$boot" DOT_NATIVES_BASE="file://$T/rel" bash "$T/p/srv/tools/fetch-natives.sh" 2>&1)"
    [ ! -e "$T/p/dot-sim/addons/dot_sim/bin/$plat" ] && grep -q 'native motor=off' <<<"$out"
    t "a checksum mismatch installs nothing and falls back to GDScript" $?

    # Two macOS architectures, fetched together twice: the second run downloads nothing.
    for a in arm64 x86_64; do
        mp="macos-$a"; mkdir -p "$T/m/$mp/addons/dot_sim/bin/$mp"; echo lib > "$T/m/$mp/addons/dot_sim/bin/$mp/libdot_sim.dylib"
        echo ext > "$T/m/$mp/addons/dot_sim/dot_sim.gdextension"
        (cd "$T/m/$mp" && python3 -m zipfile -c "$R/dot_sim-9.9.9-$mp.zip" addons)
    done
    (cd "$R" && sha256sum dot_sim-9.9.9-macos-*.zip > SHA256SUMS.natives)
    natrun() { DOT_BOOTSTRAP="$boot" DOT_NATIVES_BASE="file://$T/rel" bash "$T/p/srv/tools/fetch-natives.sh" --platform macos-arm64 --platform macos-x86_64 2>&1; }
    natrun >/dev/null
    out="$(natrun)"
    ! grep -q 'installed into' <<<"$out" && [ -f "$T/p/dot-sim/addons/dot_sim/bin/.natives-macos-arm64" ] && [ -f "$T/p/dot-sim/addons/dot_sim/bin/.natives-macos-x86_64" ]
    t "macOS arm64 + x86_64 together: the second run downloads nothing (per-arch stamps)" $?
    # Each zip's .gdextension names only its own platform; after both, it must name both
    # (export-native --platform all shipped linux and windows without their entry).
    mkdir -p "$T/p/dot-sim/ci"
    printf '# platform\ttarget\trunner\tfile\tkey\nmacos-arm64\ta\tr\tlib{crate}.dylib\tmacos.arm64\nmacos-x86_64\tx\tr\tlib{crate}.dylib\tmacos.x86_64\nwindows-x86_64\tw\tr\t{crate}.dll\twindows.x86_64\n' > "$T/p/dot-sim/ci/targets.tsv"
    printf '[configuration]\nentry_symbol = "e"\n\n[libraries]\nmacos.x86_64 = "x"\n' > "$T/p/dot-sim/addons/dot_sim/dot_sim.gdextension"
    natrun >/dev/null
    g="$T/p/dot-sim/addons/dot_sim/dot_sim.gdextension"
    grep -qF 'macos.arm64 = "res://addons/dot_sim/bin/macos-arm64/libdot_sim.dylib"' "$g" \
        && grep -qF 'macos.x86_64 = "res://addons/dot_sim/bin/macos-x86_64/libdot_sim.dylib"' "$g" \
        && ! grep -q windows "$g" && grep -q 'entry_symbol = "e"' "$g"
    t "the .gdextension names every platform whose library is present, and keeps [configuration]" $?
fi
exit $((bad > 0))
