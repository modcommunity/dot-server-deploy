#!/usr/bin/env bash
# Is a game's pack publishable against the shell players run? Judges every requires.floor.json level against the addon
# levels origin/main's addons.lock pins, and says exactly what moves each one that is not:
#
#   tools/pack_ready.sh <game-dir>              report; exit 0 when every floor is at or below the lock, 1 otherwise
#   tools/pack_ready.sh <game-dir> --prepare    also commit the lock bump (addons.lock + content-lists/addons.yml) on a
#                                               worktree branch lockbump/<game>-<stamp>, push the branch, print the steps
#   --no-fetch                                  use the tags and origin/main already fetched (tests, offline)
#   --no-push                                   --prepare without the push
#
# A floor above the lock is OK once a tag reaches it (the lock moves to that tag), NEEDS_TAG when only origin/main does (the
# exact tag command is printed for the supervisor; agents never tag), and WRONG when not even origin/main has the level. A
# floor for an addon the lock does not carry is STALE: the host never checks it, so it only blocks. The lock is read from
# origin/main, never the checkout's, which may lag. The family directory holding the addon repositories is GS_FAMILY_DIR,
# else the one holding this repository's main checkout.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME="" PREPARE=0 FETCH=1 PUSH=1
for a in "$@"; do
    case $a in
        --prepare) PREPARE=1 ;; --no-fetch) FETCH=0 ;; --no-push) PUSH=0 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        -*) echo "pack_ready: unknown option $a" >&2; exit 2 ;;
        *) [ -z "$GAME" ] || { echo "pack_ready: one game directory, got $GAME and $a" >&2; exit 2; }; GAME=$a ;;
    esac
done
[ -n "$GAME" ] && [ -f "$GAME/project.godot" ] || { echo "usage: tools/pack_ready.sh <game-dir> [--prepare] [--no-fetch] [--no-push]" >&2; exit 2; }
GAME="$(cd "$GAME" && pwd)"
FAM="${GS_FAMILY_DIR:-$(dirname "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)")/..}"
FAM="$(cd "$FAM" && pwd)"
if [ "$FETCH" = 1 ]; then
    git -C "$ROOT" fetch -q origin main || { echo "pack_ready: cannot fetch dot-server-deploy origin main" >&2; exit 2; }
fi
git -C "$ROOT" cat-file -e origin/main:addons.lock 2>/dev/null || { echo "pack_ready: no origin/main:addons.lock in $ROOT" >&2; exit 2; }
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
python3 -I - "$ROOT" "$FAM" "$GAME" "$FETCH" "$OUT" <<'PY'
import json, os, re, subprocess, sys
root, fam, game, fetch, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5]
def git(d, *a):
    r = subprocess.run(["git", "-C", d, *a], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None
lock = {}
for l in git(root, "show", "origin/main:addons.lock").splitlines():
    if "\t" in l and not l.startswith("#"):
        r, ref = l.split("\t")[:2]; lock[r] = ref.strip()
if os.path.isfile(root + "/addons.lock"):
    local = {l.split("\t")[0]: l.split("\t")[1].strip() for l in open(root + "/addons.lock") if "\t" in l and not l.startswith("#")}
    if local != lock:
        print("pack_ready: note: this checkout's addons.lock differs from origin/main's; judging against origin/main (pull it)")
def level(d, ref, a):
    # None: the ref has no addons/<a> (pinned before a rename, or another addon's repo); else LEVEL, 1 without an api file.
    if not git(d, "ls-tree", ref, "addons/" + a): return None
    m = re.search(r"^const\s+LEVEL\s*:?=\s*(\d+)", git(d, "show", "%s:addons/%s/%s_api.gd" % (ref, a, a)) or "", re.M)
    return int(m[1]) if m else 1
def ver(t):
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", t); return tuple(map(int, m.groups())) if m else None
floor_path = game + "/requires.floor.json"
floors = json.load(open(floor_path)).get("addons", {}) if os.path.isfile(floor_path) else {}
gname = os.path.basename(game)
bumps, tags, actions, rows = {}, [], [], []
for a, want in sorted(floors.items()):
    want = int(want); link = game + "/addons/" + a; repo = None
    if os.path.islink(link) or os.path.isdir(link):
        t = os.path.realpath(link)
        if t.endswith("/addons/" + a): repo = os.path.basename(t[:-len("/addons/" + a)])
    if repo not in lock:
        repo = next((r for r in lock if r.replace("-", "_") == a), None)
    if repo is None:
        rows.append("STALE      %s floor %d: the shell's lock carries no %s, so the host never checks it; remove it from %s" % (a, want, a, floor_path))
        actions.append("remove %s from %s" % (a, floor_path)); continue
    d = fam + "/" + repo
    if not os.path.isdir(d + "/.git") and not os.path.isfile(d + "/.git"):
        rows.append("UNKNOWN    %s: no checkout %s to read levels from" % (a, d)); actions.append("clone %s into %s" % (repo, fam)); continue
    if fetch: git(d, "fetch", "-q", "--tags", "origin")
    have = level(d, lock[repo], a)
    if have is not None and want <= have:
        rows.append("OK         %s floor %d <= %d (lock %s %s)" % (a, want, have, repo, lock[repo])); continue
    why = ("the lock's %s %s has no addons/%s (pinned before a rename)" % (repo, lock[repo], a)) if have is None else ("the lock's %s %s is level %d" % (repo, lock[repo], have))
    vt = sorted((v, t) for t in (git(d, "tag", "-l", "v*") or "").split() if (v := ver(t)))
    newest = vt[-1][1] if vt else None
    nl = level(d, newest, a) if newest else None
    if nl is not None and nl >= want:
        bumps[repo] = newest
        rows.append("LOCKABLE   %s floor %d: %s; tag %s has %d -> lock bump to %s" % (a, want, why, newest, nl, newest)); continue
    main = git(d, "rev-parse", "origin/main")
    ml = level(d, "origin/main", a) if main else None
    if ml is not None and ml >= want:
        v = vt[-1][0] if vt else (0, 1, 0); tag = "v%d.%d.%d" % (v[0], v[1], v[2] + 1)
        bumps[repo] = tag; tags.append("git -C %s tag %s %s && git -C %s push origin %s" % (d, tag, main.strip(), d, tag))
        rows.append("NEEDS_TAG  %s floor %d: %s; newest tag %s has %s, origin/main has %d -> tag %s, then lock bump" % (a, want, why, newest, nl, ml, tag)); continue
    rows.append("WRONG      %s floor %d: %s and origin/main has %s; the floor names a level no commit has. Lower it in %s" % (a, want, why, ml, floor_path))
    actions.append("lower %s in %s to at most %s" % (a, floor_path, ml if ml is not None else "the lock's level"))
print("pack_ready: %s: %d floor(s) against origin/main's addons.lock" % (gname, len(floors)))
for r in rows: print("  " + r)
json.dump({"game": gname, "bumps": bumps, "tags": tags, "actions": actions}, open(out, "w"))
PY
[ $? -eq 0 ] || exit 2
read -r NB NA < <(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["bumps"]), len(d["actions"]))' "$OUT")
if [ "$NB" = 0 ] && [ "$NA" = 0 ]; then echo "pack_ready: ready: every floor is within the shell's lock"; exit 0; fi
[ "$NA" = 0 ] || python3 -I -c 'import json,sys; [print("pack_ready: fix in the game: " + a) for a in json.load(open(sys.argv[1]))["actions"]]' "$OUT"
[ "$NB" = 0 ] && exit 1
if [ "$PREPARE" = 0 ]; then echo "pack_ready: run again with --prepare to push the lock bump branch"; exit 1; fi
STAMP="$(date -u +%Y%m%d%H%M%S)"; G="$(basename "$GAME")"; BR="lockbump/$G-$STAMP"
WT="${WT_DIR:-$HOME/wt}/dot-server-deploy-lockbump-$G-$STAMP"
git -C "$ROOT" worktree add -q -b "$BR" "$WT" origin/main || { echo "pack_ready: could not add worktree $WT" >&2; exit 2; }
python3 -I - "$WT" "$OUT" <<'PY' || exit 2
import json, re, sys
wt, bumps = sys.argv[1], json.load(open(sys.argv[2]))["bumps"]
p = wt + "/addons.lock"; lines = open(p).read().splitlines(True)
open(p, "w").writelines(("%s\t%s\n" % (l.split("\t")[0], bumps[l.split("\t")[0]])) if "\t" in l and l.split("\t")[0] in bumps else l for l in lines)
p = wt + "/content-lists/addons.yml"; src = open(p).read().splitlines(True); repo = None; res = []
for l in src:
    m = re.match(r"\s*-\s*repo:\s*(\S+)", l)
    if m: repo = m[1]
    elif repo in bumps and re.match(r"\s*pin:", l): l = re.sub(r"pin:.*", "pin: " + bumps[repo], l); repo = None
    res.append(l)
open(p, "w").writelines(res)
PY
MSG="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("Lock bump for %s: %s" % (d["game"], ", ".join("%s %s" % kv for kv in sorted(d["bumps"].items()))))' "$OUT")"
git -C "$WT" commit -qam "$MSG" -m "Prepared by tools/pack_ready.sh: the game's requires.floor.json asks levels the old lock lacks." || { echo "pack_ready: commit failed in $WT" >&2; exit 2; }
if [ "$PUSH" = 1 ]; then git -C "$WT" push -q origin "$BR" || { echo "pack_ready: push of $BR failed; the commit is in $WT" >&2; exit 2; }; fi
echo "pack_ready: lock bump committed on $BR ($(git -C "$WT" rev-parse --short HEAD)) in $WT$([ "$PUSH" = 1 ] && echo ', pushed')"
echo "pack_ready: supervisor steps, in order:"
python3 -I -c 'import json,sys; [print("  tag:   " + t) for t in json.load(open(sys.argv[1]))["tags"]]' "$OUT"
echo "  merge: git -C $ROOT fetch origin && git -C $ROOT push origin origin/$BR:main   (fast-forward only)"
echo "  shell: the lock push triggers the web-shell CI (export, pin, tag); if it cannot, tools/publish-web-shell.sh --env <prod env> --api"
echo "  then:  rerun tools/pack_ready.sh $GAME (exit 0) and publish the pack"
exit 1
