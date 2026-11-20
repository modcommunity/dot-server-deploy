#!/usr/bin/env bash
# Every game's PUBLISHED pack must still boot on the host a lock builds. Run it before pushing an addons.lock bump.
#
#   tools/published_packs_boot.sh [--lock FILE] [--origin URL]... [--only id,id] [--keep DIR]
#     --lock     the lock to judge (default: this checkout's addons.lock); it must sit in a dot-server-deploy checkout
#     --origin   content roots to read latest.json from (default: prod https://content.gamespice.net/content and
#                dev https://tmcdevgames.net/content); each origin's latest version of each game is booted once
#     --only     content ids (without the owner) instead of every game-*/mg-* repo in content-lists/games.yml
#     --keep     keep the fetched packs and logs under DIR (default: a temp dir, removed)
#   Env: CONTENT_OWNER (default gamemann), GS_FAMILY_DIR (the checkouts' parent; default this checkout's parent), GODOT.
# Exit 0 when every pack booted, 1 when one did not (each listed), 2 on a fetch or setup failure or when nothing was booted.
#
# [b]Why.[/b] Servers re-install their addons at the lock on every restart (TMC_AUTO_UPDATE), but a pack is only checked
# against the lock of the day it was published. dot-net v0.1.36 (2026-11-17) typed DotNetBehaviour.identity as Node; the
# lock took it the same day, and Hungario 0.1.19 (published 11-16 against v0.1.35, `var net_id := behaviour.identity.net_id`)
# stopped compiling: "A game has to supply the bridge between itself and the netcode", the server hibernates. Nothing booted
# the packs already out there against the new lock. This does, with dot-cloud's tools/pack_fetch.py (what the CDN serves,
# hash-checked) and tools/pack_boot_test.sh (mounted under res://dot_cloud/, every script compiled, game.yml's module made
# and asked for its bridge). Run it through hv: it builds a host per lock (cached) and boots one engine per pack.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAMILY="${GS_FAMILY_DIR:-$(cd "$HERE/.." && pwd)}"
CLOUD="$FAMILY/dot-cloud/tools"
OWNER="${CONTENT_OWNER:-gamemann}"
LOCK="$HERE/addons.lock"; ORIGINS=(); ONLY=""; KEEP=""
while [ $# -gt 0 ]; do
    case $1 in
        --lock) LOCK="${2:?}"; shift 2 ;;
        --origin) ORIGINS+=("${2:?}"); shift 2 ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        --keep) KEEP="${2:?}"; shift 2 ;;
        *) echo "published_packs_boot: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ ${#ORIGINS[@]} -gt 0 ] || ORIGINS=(https://content.gamespice.net/content https://tmcdevgames.net/content)
[ -x "$CLOUD/pack_boot_test.sh" ] && [ -f "$CLOUD/pack_fetch.py" ] \
    || { echo "published_packs_boot: $CLOUD has no pack_boot_test.sh / pack_fetch.py (pull dot-cloud)" >&2; exit 2; }
if [ -n "$ONLY" ]; then IDS="$(tr ',' '\n' <<<"$ONLY")"; else
    IDS="$(sed -n 's/^ *- repo: *\(\(game\|mg\)-[^ ]*\) *$/\1/p' "$HERE/content-lists/games.yml" | grep -v -- '-maps$')"
fi
[ -n "$IDS" ] || { echo "published_packs_boot: no games listed" >&2; exit 2; }
if [ -n "$KEEP" ]; then W="$KEEP"; mkdir -p "$W"; else W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; fi
# Each origin's pack is booted on its own, even at a version the other origin also has: dev and prod publish separately, so
# one version string can carry different content. Only a 404 for latest.json is "not published"; any other answer (an
# outage, a TLS failure, a 5xx, a page that is not the JSON) is a fetch failure, so an unreachable origin cannot pass.
fails=0; errs=0; booted=0; rows=()
for id in $IDS; do
    for o in "${ORIGINS[@]}"; do
        tag="$(sed -E 's#^https?://##; s#/.*##' <<<"$o")"
        mkdir -p "$W/$tag"; base="$W/$tag/$id"
        code="$(curl -sS --max-time 30 -o "$base.latest.json" -w '%{http_code}' "$o/$OWNER/$id/latest.json" 2>"$base.fetch.log")"
        if [ "$code" = 404 ]; then rows+=("$id	-	$tag	not published"); continue; fi
        v=""
        [ "$code" = 200 ] && v="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' <"$base.latest.json" 2>>"$base.fetch.log")"
        if [ -z "$v" ]; then errs=$((errs+1)); rows+=("$id	-	$tag	LATEST-FAILED (http ${code:-none}; $base.fetch.log)"); continue; fi
        d="$base@$v"; rm -rf "$d"
        if ! python3 -I "$CLOUD/pack_fetch.py" "$o" "$OWNER/$id" "$d" --version "$v" >/dev/null 2>"$d.fetch.log"; then
            errs=$((errs+1)); rows+=("$id	$v	$tag	FETCH-FAILED ($d.fetch.log)"); continue
        fi
        booted=$((booted+1))
        if "$CLOUD/pack_boot_test.sh" "$d" "$LOCK" >"$d.boot.log" 2>&1; then
            rows+=("$id	$v	$tag	ok")
        else
            fails=$((fails+1))
            why="$(grep -m3 -E '^pack_boot: FAIL|pack_boot: .*(could not|did not)' "$d.boot.log" | sed 's/^pack_boot: //' | paste -sd ';' -)"
            rows+=("$id	$v	$tag	FAIL: ${why:-see $d.boot.log}")
        fi
    done
done
printf '%s\n' "${rows[@]}" | column -t -s $'\t' 2>/dev/null || printf '%s\n' "${rows[@]}"
echo "published_packs_boot: lock $LOCK: $booted pack(s) booted, $fails do not boot, $errs fetch failure(s)"
[ $fails -eq 0 ] || exit 1
[ $errs -eq 0 ] || exit 2
[ $booted -gt 0 ] || { echo "published_packs_boot: no pack was booted; nothing was judged" >&2; exit 2; }
