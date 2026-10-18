#!/bin/bash
# The pictures of the Subscriptions page and of solo/online, from examples/workshop_solo.
# A real renderer, not --headless (that saves empty frames): xvfb-run. Desktop and phone width.
#   heavy -- ./tools/workshop_shots.sh
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
out="screenshots/workshop"
mkdir -p "$out"
for res in 1000x760 390x780; do
	timeout 240 xvfb-run -a "$GODOT" --path . --resolution "$res" res://examples/workshop_solo.tscn -- --shots "$out" > ".godot/workshop-shots-$res.log" 2>&1
	echo "$res: exit $?"
	grep -E "passed|ERROR|SCRIPT ERROR" ".godot/workshop-shots-$res.log" | head -5
done
ls "$out"
