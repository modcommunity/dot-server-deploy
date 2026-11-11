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
fi
exit $((bad > 0))
