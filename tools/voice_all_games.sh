#!/usr/bin/env bash
# Voice between two real clients over a real socket, in every delivered game, and the table.
#
#   tools/voice_all_games.sh [game ...]
#
# Runs examples/voice_two_clients.tscn once per game (one process each: a game boots a
# whole host) and prints one row per game from its VOICE line. Needs each game's pack in
# dist/ (./server pack <id> --source games/<repo>); a game without one is listed as skipped.
# Exit 0 when every game that ran held, 1 otherwise.
set -uo pipefail
cd "$(dirname "$0")/.."
games=("$@")
[ ${#games[@]} -eq 0 ] && games=(arena buses deathrun delivery g2gfast hideseek hungry_classic lookatme playground prophunt smash wipeout zombiezone)
mkdir -p .godot/test-logs
failed=0
printf '%-15s %-8s %-10s %-8s %-12s %-10s %s\n' game result router voice heard_all rms off_leak
for g in "${games[@]}"; do
    log=".godot/test-logs/voice_$g.log"
    timeout 300 godot --headless --path . res://examples/voice_two_clients.tscn -- --game "$g" >"$log" 2>&1
    rc=$?
    line=$(grep '^VOICE ' "$log" | tail -1 | cut -c7-)
    case $rc in 0) r=ok ;; 3) r=skipped ;; *) r=FAIL; failed=1 ;; esac
    if [ -n "$line" ]; then
        printf '%-15s %-8s %s\n' "$g" "$r" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(" ".join(str(d.get(k,"-")) for k in ("router","client_voice","heard_all","rms","leaked_off","heard_game_channel")))' "$line")"
    else
        printf '%-15s %-8s (no result; see %s)\n' "$g" "$r" "$log"
    fi
done
exit $failed
