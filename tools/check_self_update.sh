#!/usr/bin/env bash
#
# self_update (tools/server.in) never resets a checkout that has commits origin lacks.
#
#   tools/check_self_update.sh      exit 0 when it holds, 1 naming each failure
#
# Arm it by reverting the --shallow-since deepening or the ancestor check in self_update:
# a shallow developer checkout with an unpushed commit is then reset and its work lost.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC="$PWD/tools/server.in"
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }

g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }
# self_update and clear_for_update, without the rest of the launcher.
eval "$(sed -n '/^clear_for_update() {/,/^}/p;/^self_update() {/,/^}/p' "$SRC")"
warn() { :; }; note() { :; }

origin="$W/origin"; mkdir "$origin"
g -C "$origin" init -q -b main
printf '#!/bin/sh\nexit 0\n' >"$origin/setup.sh"; chmod +x "$origin/setup.sh"
for i in 1 2 3; do echo $i >"$origin/f"; g -C "$origin" add -A; g -C "$origin" commit -qm "c$i"; done

clone() { rm -rf "$W/$1"; git clone -q --depth 1 "file://$origin" "$W/$1"; }

# Deployment: shallow, behind origin -> updates.
clone dep; g -C "$W/dep" fetch -q --depth 1 origin main
echo 4 >"$origin/f"; g -C "$origin" commit -qam c4
echo 5 >"$origin/f"; g -C "$origin" commit -qam c5
PROJECT="$W/dep"; self_update
[ "$(git -C "$W/dep" rev-parse HEAD)" = "$(git -C "$origin" rev-parse HEAD)" ] \
    && ok "shallow deployment behind origin is updated" || bad "shallow deployment behind origin was not updated"

# Developer: shallow, one unpushed commit -> untouched.
clone dev; echo mine >"$W/dev/mine"; g -C "$W/dev" add -A; g -C "$W/dev" commit -qm mine
before="$(git -C "$W/dev" rev-parse HEAD)"
echo 6 >"$origin/f"; g -C "$origin" commit -qam c6
PROJECT="$W/dev"; self_update
[ "$(git -C "$W/dev" rev-parse HEAD)" = "$before" ] \
    && ok "shallow checkout with an unpushed commit is not reset" || bad "shallow checkout with an unpushed commit was reset"

# Developer: full clone, unpushed commit -> untouched.
rm -rf "$W/full"; git clone -q "file://$origin" "$W/full"
echo mine >"$W/full/mine"; g -C "$W/full" add -A; g -C "$W/full" commit -qm mine
before="$(git -C "$W/full" rev-parse HEAD)"
PROJECT="$W/full"; self_update
[ "$(git -C "$W/full" rev-parse HEAD)" = "$before" ] \
    && ok "full checkout with an unpushed commit is not reset" || bad "full checkout with an unpushed commit was reset"

[ "$fails" -eq 0 ]
