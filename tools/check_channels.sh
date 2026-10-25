#!/usr/bin/env bash
#
# The update channels and the "host commit moved" trigger of tools/server.in.
#
#   tools/check_channels.sh      exit 0 when they hold, 1 naming each failure
#
# latest follows the branch head: a host-only commit (no lock, no shell change) must make
# lock_moved say yes. stable follows the newest v* tag (sort -V, so v0.10.0 > v0.9.0): commits
# after it are not a move, a new tag is, and self_update lands exactly on the tag.
# Arm it by reverting the HEAD-vs-target comparison in lock_moved: the host-only case fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC="$PWD/tools/server.in"
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }

g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }
eval "$(sed -n '/^clear_for_update() {/,/^}/p;/^fetch_target() {/,/^}/p;/^self_update() {/,/^}/p;/^lock_moved() {/,/^}/p' "$SRC")"
warn() { :; }; note() { :; }
TARGET_REF=""

origin="$W/origin"; mkdir "$origin"
g -C "$origin" init -q -b main
printf '#!/bin/sh\nexit 0\n' >"$origin/setup.sh"; chmod +x "$origin/setup.sh"
echo lock1 >"$origin/addons.lock"; mkdir "$origin/host"; echo 1 >"$origin/host/a.gd"
g -C "$origin" add -A; g -C "$origin" commit -qm c1; g -C "$origin" tag v0.9.0
echo 2 >"$origin/host/a.gd"; g -C "$origin" commit -qam c2; g -C "$origin" tag v0.10.0
v10="$(git -C "$origin" rev-parse HEAD)"
clone() { rm -rf "$W/$1"; git clone -q --depth 1 "file://$origin" "$W/$1"; }

clone box; PROJECT="$W/box"
CHANNEL=latest; lock_moved && bad "latest: up to date reported as moved" || ok "latest: up to date is not a move"
echo 3 >"$origin/host/a.gd"; g -C "$origin" commit -qam "host only"
lock_moved && ok "latest: a host-only commit is a move" || bad "latest: a host-only commit was not a move"
CHANNEL=stable; lock_moved && bad "stable: a commit after the newest tag counted" || ok "stable: a commit after the newest tag is not a move"

# stable box at v0.9.0 moves to v0.10.0 (not v0.9.0 < v0.10.0 by string sort), then stops
rm -rf "$W/box"; git clone -q "file://$origin" "$W/box"; git -C "$W/box" reset -q --hard v0.9.0
CHANNEL=stable; lock_moved && ok "stable: an older release is a move" || bad "stable: an older release was not a move"
self_update
[ "$(git -C "$W/box" rev-parse HEAD)" = "$v10" ] && ok "stable: self_update lands on v0.10.0, not the branch head" || bad "stable: self_update landed on $(git -C "$W/box" rev-parse --short HEAD)"
lock_moved && bad "stable: at the newest tag still moved" || ok "stable: at the newest tag is not a move"
g -C "$origin" tag v0.10.1; echo 4 >"$origin/host/a.gd"; g -C "$origin" commit -qam c4; g -C "$origin" tag -f v0.10.1 >/dev/null
lock_moved && ok "stable: a new tag is a move" || bad "stable: a new tag was not a move"

# latest follows the head, including from a stable box
CHANNEL=latest; self_update
[ "$(git -C "$W/box" rev-parse HEAD)" = "$(git -C "$origin" rev-parse HEAD)" ] && ok "latest: self_update lands on the branch head" || bad "latest: self_update missed the head"

# a stable channel with no tag at all refuses rather than falling back to the head
rm -rf "$origin/.git/refs/tags"/*; : >"$origin/.git/packed-refs"
clone notag; PROJECT="$W/notag"; echo 5 >"$origin/host/a.gd"; g -C "$origin" commit -qam c5
CHANNEL=stable; lock_moved && bad "stable: no tag still moved" || ok "stable: no release tag means no move"

# the launcher accepts and rejects the values (a fresh launcher from server.in, as setup.sh writes it)
L="$PWD/.channels-launcher.$$"; sed "s|@GODOT@|$(command -v godot)|g" "$SRC" >"$L"; chmod +x "$L"; trap 'rm -rf "$W" "$L"' EXIT
for v in latest @latest stable @stable; do
    out="$(TMC_NO_INSTALL=1 TMC_AUTO_UPDATE=never TMC_CHANNEL=$v "$L" --dry-run 2>&1)"; rc=$?
    [ $rc -eq 0 ] && ok "launcher accepts TMC_CHANNEL=$v" || bad "launcher refused TMC_CHANNEL=$v: $(printf '%s' "$out" | tail -1)"
done
out="$(TMC_NO_INSTALL=1 TMC_AUTO_UPDATE=never "$L" --channel beta --dry-run 2>&1)"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$out" | grep -q "latest or stable" && ok "launcher refuses --channel beta" || bad "launcher accepted --channel beta"

[ "$fails" -eq 0 ]
