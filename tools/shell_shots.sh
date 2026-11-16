#!/bin/bash
# The shell's menu and loading cover at desktop (1280x720) and phone sizes (390x844 upright,
# 844x390 on its side), from tools/progress_shot.gd. A real renderer, not --headless (that
# saves empty frames): xvfb-run.
#   heavy -- ./tools/shell_shots.sh
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
out="${SHOT_DIR:-.}/screenshots/shell"
mkdir -p "$out" .godot
status=0
for size in 1280x720 390x844 844x390; do
	for stage in menu loading; do
		log=".godot/shell-shot-$stage-$size.log"
		timeout 120 xvfb-run -a "$GODOT" --path . --resolution "$size" --script res://tools/progress_shot.gd \
			-- --stage "$stage" --size "$size" --out "$out/${stage}_$size.png" > "$log" 2>&1
		rc=$?
		echo "$stage $size: exit $rc"
		[ "$rc" -eq 0 ] || status=1
		grep -E "wrote|ERROR|Parse Error" "$log" | head -5
	done
done
exit "$status"
