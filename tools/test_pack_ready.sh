#!/usr/bin/env bash
# Runs tools/pack_ready.sh against a throwaway family (no network): an addon renamed after the locked tag, a floor a tag
# reaches, one only main reaches, one no commit reaches, a stale floor, and --prepare pushing the lock bump branch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; PASS=0; FAIL=0
chk() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; sed 's/^/    /' "$W/out"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GS_FAMILY_DIR="$W/fam" WT_DIR="$W/wt"
g() { git -C "$@" >/dev/null 2>&1; }
mkdir -p "$W/fam" "$W/bare" "$W/wt"; cd "$W" || exit 2
# addon-x: v0.1.0 ships addons/old_x (before the rename), v0.1.1 addons/addon_x at level 3, main (untagged) level 5.
git init -q -b main "$W/fam/addon-x"; X="$W/fam/addon-x"
mkdir -p "$X/addons/old_x"; echo 'const LEVEL := 2' > "$X/addons/old_x/old_x_api.gd"; g "$X" add -A; g "$X" commit -m a; g "$X" tag v0.1.0
g "$X" mv addons/old_x addons/addon_x; g "$X" mv addons/addon_x/old_x_api.gd addons/addon_x/addon_x_api.gd
echo 'const LEVEL := 3' > "$X/addons/addon_x/addon_x_api.gd"; g "$X" commit -am b; g "$X" tag v0.1.1
echo 'const LEVEL := 5' > "$X/addons/addon_x/addon_x_api.gd"; g "$X" commit -am c
git init -q --bare "$W/bare/addon-x.git"; g "$X" remote add origin "$W/bare/addon-x.git"; g "$X" push -q origin main --tags
# dot-server-deploy with the lock at the pre-rename tag, and its bare origin.
D="$W/fam/dot-server-deploy"; git init -q -b main "$D"; mkdir -p "$D/tools" "$D/content-lists"
printf '# lock\naddon-x\tv0.1.0\n' > "$D/addons.lock"; printf 'entries:\n  - repo: addon-x\n    pin: v0.1.0\n' > "$D/content-lists/addons.yml"
cp "$HERE/pack_ready.sh" "$D/tools/"; g "$D" add -A; g "$D" commit -m lock
git init -q --bare "$W/bare/dsd.git"; g "$D" remote add origin "$W/bare/dsd.git"; g "$D" push -q origin main
G="$W/fam/game-x"; mkdir -p "$G/addons"; echo 'config_version=5' > "$G/project.godot"; ln -s ../../addon-x/addons/addon_x "$G/addons/addon_x"
fl() { printf '{"format": 1, "addons": {%s}}\n' "$1" > "$G/requires.floor.json"; }
pr() { "$D/tools/pack_ready.sh" "$G" --no-fetch "$@" > "$W/out" 2>&1; }
fl '"addon_x": 3'; pr
chk "floor past a rename: LOCKABLE to the newest tag, names the rename, exit 1" "[ $? -eq 1 ] && grep -q 'LOCKABLE   addon_x floor 3' out && grep -q 'pinned before a rename' out && grep -q 'v0.1.1 has 3' out"
fl '"addon_x": 5'; pr
chk "floor only main reaches: NEEDS_TAG with the exact next tag command" "[ $? -eq 1 ] && grep -q 'NEEDS_TAG' out && grep -q 'tag v0.1.2' out"
fl '"addon_x": 9'; pr
chk "floor no commit reaches: WRONG, lower it" "[ $? -eq 1 ] && grep -q 'WRONG' out && grep -q 'lower addon_x' out"
fl '"addon_x": 3, "gone_y": 2'; pr
chk "floor for an addon the lock lacks: STALE, remove it" "[ $? -eq 1 ] && grep -q 'STALE      gone_y' out && grep -q 'remove gone_y' out"
fl '"addon_x": 5'; pr --prepare
chk "--prepare pushes lockbump/game-x-* with the lock line and yml pin moved, main untouched" "[ $? -eq 1 ] \
    && B=\$(git -C bare/dsd.git for-each-ref --format='%(refname:short)' 'refs/heads/lockbump/*') && [ -n \"\$B\" ] \
    && git -C bare/dsd.git show \"\$B:addons.lock\" | grep -qP '^addon-x\tv0.1.2$' && git -C bare/dsd.git show \"\$B:content-lists/addons.yml\" | grep -q 'pin: v0.1.2' \
    && git -C bare/dsd.git show main:addons.lock | grep -qP '^addon-x\tv0.1.0$' && grep -q 'tag:   git -C .*tag v0.1.2' out && grep -q 'merge:' out"
printf '# lock\naddon-x\tv0.1.1\n' > "$D/addons.lock"; g "$D" commit -am bump; g "$D" push -q origin main
fl '"addon_x": 3'; pr
chk "floor within the lock: ready, exit 0" "[ $? -eq 0 ] && grep -q 'OK         addon_x floor 3 <= 3' out && grep -q 'ready' out"
printf '# lock\naddon-x\tv0.1.0\n' > "$D/addons.lock"; pr
chk "a checkout lock behind origin/main is noted, origin/main judged" "[ $? -eq 0 ] && grep -q 'differs from origin/main' out"
"$D/tools/pack_ready.sh" "$W" > "$W/out" 2>&1
chk "not a game directory: usage, exit 2" "[ $? -eq 2 ] && grep -q usage out"
echo "test_pack_ready: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
