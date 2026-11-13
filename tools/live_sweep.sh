#!/usr/bin/env bash
# Regression sweep of the LIVE web shell, game by game.
#
#   tools/live_sweep.sh [--shell BUILD] [--only repo,repo] [--audit-only] [--quiet] [--no-map] [--local] [--rotate] [--secs N] [--out DIR]
#
# For every game (list below):
#   1. PACK AUDIT (read-only, from the content origin): the newest version's signed manifest must carry a `bundle`
#      block, `provides.runs_code` (a game pack's is computed at publish; absent means it was published by a path
#      that skips the scan, so the shell does not know the pack runs code), and requires.json (or requires.uses.json).
#      A map pack must carry a bundle. A game without requires.json only warns (it then asks nothing of the host's addons
#      beyond their baseline, and older publishers wrote none); the browser run is the verdict on that. A pack with a gap is republished with dot-cloud's tools/publish_pack.sh,
#      never the site's own upload path (dot-cloud docs/cdn-publish.md).
#   2. BROWSER: tools/browser_solo_overlay_check.mjs --state fresh --expect started against the live shell
#      (web/shell-build unless --shell), and again with --map <first map of the game's map pack> for map games.
#      Through dot-bootstrap's gpu.sh cdp-run (a real GPU: dev02's software WebGL gives a black frame), or --local for
#      a plain headless chromium. gpu.sh exit 75 (no box free) is retried with a back-off, three times.
#
# --audit-only --quiet is the cron/CI form: reads the content origin only (no browser, no playwright, no token), prints nothing
# when every pack is sound and one line per game with a problem otherwise, and exits 1 so the scheduler flags it. It catches the
# site's GitHub-release sync (X.Y.Z+rN) re-publishing a pack without bundle/runs_code/requires, which the site does not scan.
#   */30 * * * * sudo -u gamedev /home/gamedev/godot/dot-server-deploy/tools/live_sweep.sh --audit-only --quiet
#
# Writes OUT/table.md (a markdown table, one row per game, ready for the board) and exits 1 on any FAIL.
# Env: CONTENT_ORIGIN, CONTENT_OWNER, GPU_SH, MAP_LOADED (regex of the console line that says a map is up).
# Needs playwright-core (PLAYWRIGHT_CORE, ~/pw or the mcp copy; the check says), python3. Run as the work user:
#   sudo -u gamedev tools/live_sweep.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GPU=${GPU_SH:-$HERE/../dot-bootstrap/tools/gpu.sh}
[ -x "$GPU" ] || GPU=/home/gamedev/godot/dot-bootstrap/tools/gpu.sh
ORIGIN=${CONTENT_ORIGIN:-https://dotgames.org}
OWNER=${CONTENT_OWNER:-gamemann}
# What a game logs once its map is up: the check's own default plus the wording the map games use (zz "world drawn", "map began"; dd "the mountain is ready").
MAPRE=${MAP_LOADED:-'world built|world drawn|map changed|map loaded|map began|round began|round begun|mountain is ready'}
SHELL_BUILD=""; ONLY=""; AUDIT_ONLY=""; QUIET=""; NO_MAP=""; LOCAL=""; ROTATE=""; SECS=240
OUT=${TMPDIR:-/tmp}/live_sweep.$$
while [ $# -gt 0 ]; do
    case $1 in
        --shell) SHELL_BUILD=${2:?}; shift 2 ;;
        --only) ONLY=${2:?}; shift 2 ;;
        --audit-only) AUDIT_ONLY=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --no-map) NO_MAP=1; shift ;;
        --local) LOCAL=1; shift ;;
        --rotate) ROTATE=1; shift ;;
        --secs) SECS=${2:?}; shift 2 ;;
        --out) OUT=${2:?}; shift 2 ;;
        *) echo "live_sweep: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$SHELL_BUILD" ] || SHELL_BUILD=$(tr -d '[:space:]' < "$HERE/web/shell-build")
mkdir -p "$OUT"

# game repo, then its map pack repo ("-" none). Both are content ids under $OWNER/.
GAMES="game-fatal-contact -
game-airdrift -
game-zombie-zone zombie-zone-maps
game-playlot playlot-maps
game-prop-hunt mg-prop-hunt-maps
game-murder-mystery murder-mystery-maps
game-hide-n-seek hide-n-seek-maps
mg-look-at-me -
mg-dangerous-delivery mg-dangerous-delivery-maps
game-hungario -
mg-buses-from-hell -
mg-smash-copter -
mg-wipeout mg-wipeout-maps
game-deathrun mg-deathrun-maps"

# audit REPO: prints "version<TAB>bundle<TAB>runs_code<TAB>requires<TAB>first map id<TAB>problems" (problems "-" when none).
audit() {
    python3 -I - "$ORIGIN/content/$OWNER/$1" <<'PY'
import base64, json, sys, urllib.request
base = sys.argv[1]
def get(u):
    return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "live_sweep/1"}), timeout=30).read()
try:
    ver = json.loads(get(base + "/latest.json"))["version"]
    mf = json.loads(get(f"{base}/{ver}/manifest.json"))
    s = mf["payload"]; s += "=" * (-len(s) % 4)
    p = json.loads(base64.urlsafe_b64decode(s))
except Exception as e:
    print(f"?\t?\t?\t?\t-\tunreadable: {e}"); sys.exit(0)
pr = p.get("provides") or {}
paths = {f["path"] for f in p.get("files", [])}
bundle = bool(p.get("bundle"))
is_game = "game" in (pr.get("kinds") or [])
rc = pr.get("runs_code")
req = [n for n in ("requires.json", "requires.uses.json") if n in paths]
maps = [e["id"] for e in pr.get("entries", []) if e.get("kind") == "map"]
bad = []
if not bundle: bad.append("no bundle")
if is_game and rc is None: bad.append("no runs_code")
if is_game and not req: bad.append("warn: no requires.json")
print("\t".join([ver, "yes" if bundle else "NO", "-" if rc is None else str(rc).lower(), ",".join(req) or "none", maps[0] if maps else "-", "; ".join(bad) or "-"]))
PY
}

# browser LABEL URL [extra args]: runs the check; prints "ok" or "FAIL rc=N (verdict)". Log and shot go to OUT/LABEL.*
browser() {
    local label=$1 url=$2; shift 2
    local log=$OUT/$label.log rc tries=0
    local cmd=(node "$HERE/tools/browser_solo_overlay_check.mjs" --url "$url" --state fresh --expect started --secs "$SECS" --shot "$OUT/$label.png" --map-loaded "$MAPRE" "$@")
    while :; do
        if [ -n "$LOCAL" ]; then timeout $((SECS + 120)) "${cmd[@]}" > "$log" 2>&1; rc=$?
        else timeout $((SECS + 900)) "$GPU" cdp-run -- "${cmd[@]}" > "$log" 2>&1; rc=$?; fi
        if [ $rc = 75 ] && [ $tries -lt 3 ]; then tries=$((tries + 1)); sleep $((60 * tries)); continue; fi
        break
    done
    if [ $rc = 0 ]; then echo ok; else echo "FAIL rc=$rc ($(grep -m1 -E '^verdict|map: .* not seen' "$log" | cut -c1-80))"; fi
}

# --rotate: one page changes maps through a rotation of the biggest ones (FC), the wasm-heap check a single-map load cannot make.
rotate() {
    local log=$OUT/rotate.log rc
    local cmd=(node "$HERE/tools/browser_solo_rotate_check.mjs" --url "$ORIGIN/godot/$SHELL_BUILD/embed.html?solo=$OWNER/game-fatal-contact" --secs "$SECS" --shot "$OUT/rotate.png")
    if [ -n "$LOCAL" ]; then timeout 1500 "${cmd[@]}" > "$log" 2>&1; rc=$?
    else timeout 2400 "$GPU" cdp-run -- "${cmd[@]}" > "$log" 2>&1; rc=$?; fi
    sed -n '/^| #/,$p' "$log" | sed 's/^/rotate: /'
    return $rc
}

fails=0
{
    echo "Live sweep, shell $SHELL_BUILD, $(date -u '+%F %H:%MZ')"
    echo
    echo "| game | version | bundle | runs_code | requires | solo fresh | map | pack problems |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
} > "$OUT/table.md"

while read -r repo maps <&3; do
    [ -n "$repo" ] || continue
    if [ -n "$ONLY" ] && ! [[ ",$ONLY," == *",$repo,"* ]]; then continue; fi
    IFS=$'\t' read -r ver bundle rc req _ problems <<< "$(audit "$repo")"
    solo="-"; mapres="-"
    if [ "$maps" != "-" ]; then
        IFS=$'\t' read -r _ _ _ _ firstmap mproblems <<< "$(audit "$maps")"
        [ "$mproblems" = "-" ] || problems="$problems; $maps: $mproblems"
    fi
    if [ -z "$AUDIT_ONLY" ]; then
        solo=$(browser "$repo" "$ORIGIN/godot/$SHELL_BUILD/embed.html?solo=$OWNER/$repo")
        if [ "$maps" != "-" ] && [ -z "$NO_MAP" ]; then
            if [ "$firstmap" != "-" ]; then
                mapres="$firstmap: $(browser "$repo.map" "$ORIGIN/godot/$SHELL_BUILD/embed.html?solo=$OWNER/$repo" --map "$firstmap")"
            else mapres="no map entry"; fi
        fi
    fi
    problems=${problems#-; }
    case "$solo$mapres$problems" in *FAIL*|*unreadable*|*"no bundle"*|*"no runs_code"*|*"no map entry"*) fails=$((fails + 1)) ;; esac
    echo "| $repo | $ver | $bundle | $rc | $req | $solo | $mapres | $problems |" >> "$OUT/table.md"
    [ -n "$QUIET" ] || tail -1 "$OUT/table.md"
    [ -z "$QUIET" ] || [ "${problems:--}" = "-" ] || echo "live_sweep: $repo $ver: $problems"
done 3<<< "$GAMES"

if [ -n "$ROTATE" ] && [ -z "$AUDIT_ONLY" ]; then
    rotate || fails=$((fails + 1))
fi

if [ -n "$QUIET" ]; then
    [ "$fails" = 0 ] || echo "live_sweep: $fails game(s) with a FAIL or a pack problem"
    [ "$fails" = 0 ]; exit
fi
echo
cat "$OUT/table.md"
echo "logs and screenshots: $OUT"
if [ "$fails" = 0 ]; then echo "live_sweep: all pass"; else echo "live_sweep: $fails game(s) with a FAIL or a pack problem"; fi
[ "$fails" = 0 ]
