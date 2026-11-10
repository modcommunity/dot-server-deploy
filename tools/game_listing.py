#!/usr/bin/env python3
"""Generate a game's deployment/game-listing.json from its game.yml and README.md.

  tools/game_listing.py GAME_DIR...            write the file where it is missing
  tools/game_listing.py --check GAME_DIR...    exit 1 if a file is missing or wrong, write nothing
  tools/game_listing.py --force GAME_DIR...    overwrite an existing (hand-edited) file too

pack.id is game.yml's content_id (what content.lock.json and the published pack carry).
name is game.yml's name. The description is the "In this 3D game, ..." sentence(s) of the README's
opening paragraph, markdown stripped. A repo named mg-* is a MINIGAME, anything else a GAME.
--check accepts a hand-edited file: it needs the format header, pack.id equal to content_id, the
listing's name and a non-empty description. Imported by tools/import_defs.sh (listing route).
"""
import json, os, re, sys

FORMAT = "tmc-game-listing"


def yml_top(path):
    """Top-level scalar keys of game.yml (no PyYAML: the file is flat at the top)."""
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r'^([A-Za-z_][\w-]*):\s*(.*?)\s*(?:#.*)?$', line)
        if m and m.group(2) != "":
            v = m.group(2)
            if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[m.group(1)] = v
    return out


def plain(s):
    s = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', s)
    s = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', s)
    s = re.sub(r'[*_`]+', '', s)
    return re.sub(r'\s+', ' ', s).strip()


def describe(readme):
    if not os.path.isfile(readme):
        return "", "3D"
    for para in re.split(r'\n\s*\n', open(readme, encoding="utf-8").read()):
        m = re.search(r'In this (2D|3D) game,?\s+(.*)', plain(para))
        if not m:
            continue
        sentences = re.split(r'(?<=[.!?])\s+', m.group(2))
        sentences = [x for x in sentences if not x.startswith("This is ")]
        text = " ".join(sentences[:2]).strip()
        return text[:1].upper() + text[1:], m.group(1)
    return "", "3D"


def build(game):
    y = yml_top(os.path.join(game, "game.yml"))
    cid, name = y.get("content_id", ""), y.get("name", "")
    if not cid or not name:
        raise ValueError("game.yml needs content_id and name")
    desc, dim = describe(os.path.join(game, "README.md"))
    if not desc:
        raise ValueError("README.md has no 'In this 3D game, ...' paragraph")
    mini = os.path.basename(os.path.abspath(game)).startswith("mg-")
    tags = [dim.upper(), "Multiplayer"] + (["Minigame"] if mini else [])
    return {"format": FORMAT, "version": 1, "listing": {
        "name": name, "description": desc, "tags": tags, "platforms": ["PLATFORM_WEB"],
        "graphicsType": "TWO_D" if dim == "2D" else "THREE_D",
        "tmcKind": "MINIGAME" if mini else "GAME"}, "pack": {"id": cid}}


def dump(d):
    l = d["listing"]
    f = lambda v: json.dumps(v, ensure_ascii=False)
    return ('{\n  "format": %s,\n  "version": 1,\n  "listing": {\n    "name": %s,\n    "description": %s,\n'
            '    "tags": [%s],\n    "platforms": [%s],\n    "graphicsType": %s,\n    "tmcKind": %s\n  },\n'
            '  "pack": {\n    "id": %s\n  }\n}\n') % (
        f(d["format"]), f(l["name"]), f(l["description"]), ", ".join(map(f, l["tags"])),
        ", ".join(map(f, l["platforms"])), f(l["graphicsType"]), f(l["tmcKind"]), f(d["pack"]["id"]))


def problems(game, path):
    if not os.path.isfile(path):
        return "missing"
    try:
        d = json.load(open(path, encoding="utf-8"))
        want = build(game)
    except (ValueError, OSError) as e:
        return "unreadable: %s" % e
    if d.get("format") != FORMAT:
        return "format is not %s" % FORMAT
    if d.get("pack", {}).get("id") != want["pack"]["id"]:
        return "pack.id %r is not game.yml content_id %r" % (d.get("pack", {}).get("id"), want["pack"]["id"])
    l = d.get("listing", {})
    if not l.get("name") or not l.get("description"):
        return "listing needs a name and a description"
    return ""


def main(argv):
    check, force = "--check" in argv, "--force" in argv
    games = [a for a in argv if not a.startswith("--")]
    if not games:
        print(__doc__); return 2
    rc = 0
    for g in games:
        path = os.path.join(g, "deployment", "game-listing.json")
        try:
            if check:
                p = problems(g, path)
                print("%s %s%s" % ("FAIL" if p else "ok  ", path, ": " + p if p else ""))
                rc |= 1 if p else 0
            elif os.path.exists(path) and not force:
                print("keep %s" % path)
            else:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, "w", encoding="utf-8").write(dump(build(g)))
                print("wrote %s" % path)
        except ValueError as e:
            print("FAIL %s: %s" % (g, e)); rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
