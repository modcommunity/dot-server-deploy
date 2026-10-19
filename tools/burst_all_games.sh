#!/usr/bin/env bash
# The most a browser is sent in one frame, in every delivered game: the join, play, seven more
# players joining, eight avatars at once, a full scoreboard, the map vote, map changes.
#
#   tools/burst_all_games.sh [game ...]
#
# Runs examples/burst_probe.tscn once per game (one process each: a game boots a whole host) and
# prints the table. A browser's WebSocket peer drops what overflows its 64 KiB inbound buffer
# between two frames; every window must stay at or under 48 KiB in any 16.7 ms. Needs each game's
# pack in dist/ (./server pack <id> --source games/<repo>); a game without one is listed as skipped.
# Exit 0 when every game that ran held, 1 otherwise. About 90 s a game.
set -uo pipefail
cd "$(dirname "$0")/.."
games=("$@")
[ ${#games[@]} -eq 0 ] && games=(arena buses deathrun delivery g2gfast hideseek hungry_classic lookatme murdermystery playground prophunt smash wipeout zombiezone)
mkdir -p .godot/test-logs
failed=0

row() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if "skipped" in d:
    print("skipped: " + d["skipped"]); sys.exit()
def w(k):
    x = d.get(k)
    if not x: return "-"
    if x.get("frame", 0) < 0: return "-"
    return "%6d" % max(x["frame"], x.get("poll", 0))
m = d.get("maps") or {}
where = (" (%s, %s)" % (m.get("how", ""), m.get("map", ""))) if m.get("frame", -1) >= 0 else ""
print(" | ".join(w(k) for k in ("join", "play", "crowd", "avatars", "board", "vote", "maps")) + where)
' "$1"
}

printf '%-15s %-6s %s\n' game result "most bytes in one 16.7 ms: join | play | crowd | avatars | board | vote | maps (how, worst)"
for g in "${games[@]}"; do
    log=".godot/test-logs/burst_probe_$g.log"
    timeout 480 godot --headless --path . res://examples/burst_probe.tscn -- --game "$g" >"$log" 2>&1
    rc=$?
    line=$(grep '^BURST ' "$log" | tail -1 | cut -c7-)
    case $rc in
        0) result=held ;;
        3) result=skip ;;
        *) result=FAIL; failed=1 ;;
    esac
    if grep -q "SCRIPT ERROR" "$log"; then result=FAIL; failed=1; fi
    if [ -n "$line" ]; then detail=$(row "$line"); else detail="no BURST line (exit $rc), see $log"; fi
    printf '%-15s %-6s %s\n' "$g" "$result" "$detail"
done
exit $failed
