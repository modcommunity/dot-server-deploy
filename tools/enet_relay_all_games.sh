#!/usr/bin/env bash
# A real client on ENet through dot-net's lossy relay, in every delivered game, the control, and the table.
#
#   tools/enet_relay_all_games.sh [--no-control] [game ...]
#
# Runs examples/enet_relay.tscn once per game (one process each: a game boots a whole host), then
# again with --stock-throttle, which puts ENet's packet throttle back as the engine ships it and
# MUST fail: its throttle checks have to see the throttle fall below 32 somewhere, or the pass
# above proved nothing about dot-core's fix. Needs each game's pack in dist/
# (./server pack <id> --source games/<repo>); a game without one is listed as skipped.
# dot-game-template is packaged from its HEAD by the suite itself (needs ../dot-ci).
# Exit 0 when every game that ran held and every control failed, 1 otherwise. About 30 s a run.
set -uo pipefail
cd "$(dirname "$0")/.."
control=1
games=()
for a in "$@"; do
    case "$a" in
        --no-control) control=0 ;;
        *) games+=("$a") ;;
    esac
done
[ ${#games[@]} -eq 0 ] && games=(arena buses deathrun delivery g2gfast hideseek hungry_classic lookatme murdermystery playground prophunt smash wipeout zombiezone dot-game-template)
mkdir -p .godot/test-logs
failed=0
started=$(date +%s)

# One row from a run's RELAY line: inputs and snapshots delivered per window, the lowest throttle
# at either end over the join and each window, and how far the server's player was carried.
row() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if "skipped" in d:
    print("skipped: " + d["skipped"]); sys.exit()
def w(k):
    x = d.get(k)
    if not x: return "-"
    return "in %d/%d snap %d/%d thr %d/%d moved %s" % (x["inputs"][0], x["inputs"][1], x["snapshots"][0], x["snapshots"][1],
        x["throttle"][0], x["throttle"][1], "-" if x["moved"] < 0 else "%.1f (idle %.1f)" % (x["moved"], x["idle"]))
j = d.get("join_throttle", ["-", "-"])
print("%-10s join thr %s/%s | 60ms: %s | 5%%: %s" % (d.get("link", "-"), j[0], j[1], w("w1"), w("w2")))
' "$1"
}

# True when a run's RELAY line saw the throttle below 32 at either end, anywhere.
fell() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
lows = list(d.get("join_throttle", [])) + [t for k in ("w1", "w2") for t in d.get(k, {}).get("throttle", [])]
sys.exit(0 if lows and min(lows) < 32 else 1)
' "$1"
}

printf '%-18s %-8s %s\n' game result detail
for g in "${games[@]}"; do
    log=".godot/test-logs/enet_relay_$g.log"
    timeout 300 godot --headless --path . res://examples/enet_relay.tscn -- --game "$g" >"$log" 2>&1
    rc=$?
    line=$(grep '^RELAY ' "$log" | tail -1 | cut -c7-)
    case $rc in 0) r=ok ;; 3) r=skipped ;; *) r=FAIL; failed=1 ;; esac
    if [ -n "$line" ]; then
        printf '%-18s %-8s %s\n' "$g" "$r" "$(row "$line")"
    else
        printf '%-18s %-8s (no result; see %s)\n' "$g" "$r" "$log"
    fi
    [ "$control" -eq 1 ] && [ "$rc" -ne 3 ] || continue

    clog=".godot/test-logs/enet_relay_${g}_stock.log"
    timeout 300 godot --headless --path . res://examples/enet_relay.tscn -- --game "$g" --stock-throttle >"$clog" 2>&1
    crc=$?
    cline=$(grep '^RELAY ' "$clog" | tail -1 | cut -c7-)
    if [ "$crc" -eq 1 ] && [ -n "$cline" ] && fell "$cline"; then
        cr="fails"
    else
        cr="HELD"; failed=1
    fi
    printf '%-18s %-8s %s\n' "  stock throttle" "$cr" "$([ -n "$cline" ] && row "$cline" || echo "(no result; see $clog)")"
done
echo "$(( $(date +%s) - started )) s"
exit $failed
