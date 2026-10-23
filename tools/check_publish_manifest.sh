#!/usr/bin/env bash
# Checks the latest.json that publish-web-shell.sh --pin writes: its shape, that it is
# printed by --manifest-only and by a pinned --dry-run, and that an unpinned dry run says nothing.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

mkdir "$T/b"; echo '<html>' > "$T/b/embed.html"; printf 'addons\tabc\n' > "$T/b/shell-inputs.txt"
(cd "$T/b" && python3 -I -c 'import zipfile;z=zipfile.ZipFile("../b.zip","w");[z.write(f) for f in ("embed.html","shell-inputs.txt")]')
want=$(sha256sum "$T/b/shell-inputs.txt" | cut -d' ' -f1)

out=$("$HERE/publish-web-shell.sh" --zip "$T/b.zip" --app godot --build 20261023-0319 --notes "it's a test" --manifest-only)
chk() { python3 -I -c 'import json,sys;d=json.loads(sys.argv[1]);assert d=={"build":"20261023-0319","entry":"embed.html","notes":"it'"'"'s a test","lock":sys.argv[2]},d' "$1" "$2"; }
chk "$out" "$want" && ok "--manifest-only prints build, entry, notes, lock" || bad "--manifest-only shape"

pinned=$("$HERE/publish-web-shell.sh" --zip "$T/b.zip" --app godot --build 20261023-0319 --dry-run --pin --no-push --repo "$T/none" 2>&1 || true)
if echo "$pinned" | grep -q 'is not a git checkout'; then ok "--pin is refused before any write without a checkout"; else bad "pin precheck"; fi

plain=$("$HERE/publish-web-shell.sh" --zip "$T/b.zip" --app godot --build 20261023-0319 --dry-run)
if echo "$plain" | grep -q "would write game"; then bad "unpinned dry run mentions latest.json"; else ok "unpinned dry run writes no manifest"; fi

# A pinned dry run in a real clean checkout, with the lock comparison stubbed out.
git init -q "$T/r"; mkdir "$T/r/tools"; printf '#!/bin/sh\nexit 0\n' > "$T/r/tools/shell-inputs.sh"; chmod +x "$T/r/tools/shell-inputs.sh"
git -C "$T/r" add -A; git -C "$T/r" -c user.name=t -c user.email=t@t commit -qm x
pd=$("$HERE/publish-web-shell.sh" --zip "$T/b.zip" --app godot --build 20261023-0319 --dry-run --pin --no-push --repo "$T/r")
echo "$pd" | grep -q 'would write game/godot/latest.json' && echo "$pd" | grep -q "$want" \
    && ok "pinned dry run prints the manifest it would write" || bad "pinned dry run manifest"
echo "$fail failed"; [ "$fail" = 0 ]
