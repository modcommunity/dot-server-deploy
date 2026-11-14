class_name TmcGameRef
extends RefCounted

## What one entry of the games list means. [b]One rule, two readers, and they must not drift.[/b]
## `tools/install_games.gd` decides what to FETCH and `TmcHost` decides what to OFFER, and both are
## handed the same `TMC_GAMES` string.

## Ids a game or pack was configured under before it was renamed, and the id it is published as now.
## [b]Here, not only on the origin[/b]: a renamed id that was never published (game-final-contact) has
## no `latest.json` to carry `moved_to`, and the host's filter must agree with the installer's
## directory, or the game is installed and then hidden. Exact `<owner>/<name>` ids only: a bare name
## is a local directory on a developer's box and is left alone.
const RETIRED_IDS := {
	"gamemann/game-final-contact": "gamemann/game-fatal-contact",
	"gamemann/game-arena": "gamemann/game-fatal-contact",
	"gamemann/arena-weapons": "gamemann/fc-weapons",
	"gamemann/arena-dm-maps": "gamemann/fc-dm-maps",
	"gamemann/arena-surf-dm-maps": "gamemann/fc-surf-dm-maps",
	"gamemann/game-g2gfast": "gamemann/game-airdrift",
	"gamemann/game-g2gfast01": "gamemann/game-airdrift",
	"gamemann/game-playground": "gamemann/game-playlot",
	"gamemann/playground-maps": "gamemann/playlot-maps",
}


## The id [param id] is published as now: itself, or what [constant RETIRED_IDS] maps it to.
static func current_id(id: String) -> String:
	return str(RETIRED_IDS.get(id.strip_edges(), id.strip_edges()))


## One entry of the games list, taken apart. A retired id comes back as its current one, with
## `retired` naming what was asked for (empty otherwise) so a caller can say so once.
static func parse(raw: String) -> Dictionary:
	var name := raw.strip_edges()
	var version := ""
	var at := name.rfind("@")

	if at > 0:
		version = name.substr(at + 1).strip_edges()
		name = name.substr(0, at).strip_edges()

	# `@latest` is spelled out rather than being the absence of a version, because a panel field that
	# says what it means is worth the four characters -- and because "no version" and "the newest one"
	# are the same request here but are not the same sentence.
	if version == "latest":
		version = ""

	# `@v1.2.0` is the RELEASE TAG and `1.2.0` is the pack's version: the site publishes a tag's pack
	# under the version with the `v` taken off, so a list written from the releases page asked the
	# origin for a `v1.2.0/` directory nothing had written.
	if version.length() > 1 and (version[0] == "v" or version[0] == "V") \
			and version[1].is_valid_int():
		version = version.substr(1)

	var is_pack := name.contains("/")
	var retired := ""

	if RETIRED_IDS.has(name):
		retired = name
		name = current_id(name)
		# A pin on a retired id names a version of a pack that is not published under it (the old
		# id 404s, and the new id's versions are its own), so it can only fail: the newest is taken.
		version = ""

	return {
		"raw": raw.strip_edges(),
		"id": name,
		"retired": retired,
		# The game's id, and where its descriptor lands: `content/<owner>/<name>/`. The WHOLE content id,
		# owner included, so a fork and its original -- or two people's games that share a name -- are two
		# games on one server rather than one overwriting the other.
		"dir": name,
		"version": version,
		"from_origin": is_pack,
	}

## Just the content directory an entry names. What `TmcHost` needs: a filter is over directories,
## and the id, the version and the owner are all somebody else's business by then.
static func dir_of(raw: String) -> String:
	return str(parse(raw)["dir"])


## Every directory a comma-separated list names, in order, without duplicates.
static func dirs_in(raw: String) -> PackedStringArray:
	var out := PackedStringArray()

	for entry in raw.split(",", false):
		var one := entry.strip_edges()

		if one == "":
			continue

		var dir := dir_of(one)

		if dir != "" and not dir in out:
			out.append(dir)

	return out


## A map entry of `cfg/server/content/overrides.yml`, qualified with [param owner] when it is bare.
static func qualify_map(raw: String, owner: String) -> Dictionary:
	var trimmed := raw.strip_edges()

	# A whole collection: `<owner>/<collection>/*`, exactly. Nothing is guessed about a partial glob
	# (`a/b/bhop_*`, `a/*/*`, `*`): the site publishes one list per collection and a pattern over it
	# would be a second query language to keep in step.
	if trimmed.contains("*"):
		var parts := trimmed.split("/")

		if "@" in trimmed:
			return {"ok": false, "id": "", "version": "", "wildcard": false,
				"why": "pins a wildcard; a collection cannot take @version (pin a map beside it: owner/map@1.0.0)"}

		if parts.size() != 3 or parts[2] != "*" or parts[0] == "" or parts[1] == "" \
				or parts[0].contains("*") or parts[1].contains("*"):
			return {"ok": false, "id": "", "version": "", "wildcard": false,
				"why": "is not a map or exactly <owner>/<collection>/*"}

		var collection := current_id("%s/%s" % [parts[0], parts[1]])

		return {"ok": true, "id": collection + "/*", "version": "", "wildcard": true, "why": "",
			"collection": collection}

	var ref := parse(raw)
	var id := str(ref["id"])
	var segments := id.split("/")

	if id == "" or segments.size() > 2 or "" in segments:
		return {"ok": false, "id": "", "version": "", "wildcard": false,
			"why": "is not <map>, <owner>/<map> or <owner>/<collection>/*"}

	if segments.size() == 2:
		return {"ok": true, "id": id, "version": str(ref["version"]), "wildcard": false, "why": ""}

	if owner == "":
		return {"ok": false, "id": "", "version": "", "wildcard": false,
			"why": "has no owner: set map_owner: for the game or in defaults:"}

	return {"ok": true, "id": "%s/%s" % [owner, id], "version": str(ref["version"]),
		"wildcard": false, "why": ""}


## Whether [param entry] (an `add` or `remove` spelling) names a whole collection.
static func is_wildcard(entry: String) -> bool:
	return entry.strip_edges().ends_with("/*")