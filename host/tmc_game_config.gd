class_name TmcGameConfig
extends RefCounted

## What a server OWNER says about each game, from `cfg/content.yml`, laid over the game's
## own `game.yml`.
##
## [codeblock]
## defaults:                            # every game on this server
##   cvars:
##     sv_alltalk: "1"
## games:
##   game-g2gfast:                      # a game id, or its name half while unambiguous
##     name: "Surf & Bhop"
##     max_players: 24
##     cvars:
##       sv_airaccelerate: "150"
##     metadata:                        # merged key by key into the game's metadata:
##       map_vote:
##         duration_sec: 1800
##     map_owner: gamemann              # who a bare map name belongs to (see below)
##     maps:
##       game_maps: true                # keep the maps the game's own game.yml lists
##       add:
##         - gamemann/surf_mesa         # the newest on the origin, re-checked every start
##         - gamemann/bhop_grove@1.2.0  # held at that version
##         - bhop_pit                   # bare: the owner comes from map_owner (below)
##       remove:
##         - gamemann/bhop_pit
## [/codeblock]
##
## [b]Two owners, two files.[/b] A game's `game.yml` travels inside its pack: it is what the
## GAME's author thinks a server should run, and the installer replaces the server's copy
## with each new version's. Before this, the only place a server owner could change a
## cvar, a player count, a map vote's timing or the map list was that copy, and the next
## game update undid it -- kept as `game.yml.prev`, read by nobody. This file is never
## written by anything but the owner, so the owner's answer survives every update and the
## author's defaults still arrive for everything the owner did not mention.
##
## [b]What may be overridden is what a server owner tunes; what the game IS may not be.[/b]
## `scene`, `client_scene`, `module`, `kind`, `content_id` and `version` decide which code
## runs and from which mount; a server that changed them would be running a different game
## under this one's name, and a client would be sent a scene its pack does not have. Those
## keys here are refused with the reason rather than applied.
##
## [b]Order:[/b] the game's `game.yml` < `defaults:` < `games: <game>:`. Cvars and metadata
## merge key by key (metadata recursively, so `map_vote: duration_sec` keeps the game's
## other `map_vote` settings); a list replaces a list. The host's own metadata keys --
## `kind`, `module`, `directory` -- win over both, as they do over `game.yml`.
##
## [b]A bare map name gets its owner from, in order:[/b] the game's `map_owner:`, then
## `defaults: map_owner:`, then the game's own `sv_map_content_owner` cvar (as the effective
## descriptor has it, this file's cvars included), then the owner half of the game's content
## id. None of them: [member errors] names the entry. [method map_owner_for] and
## [method qualified_rule] are the only code that decides this, and `install-games` goes
## through [method all_map_entries], so it pins the ids the host will look up.
##
## [b]Unpinned maps are resolved by the installer, not here.[/b] `TmcContent` refuses a
## map with no version because a server that resolved `@latest` per join would hand two
## players two different packs under one map. So `./server install-games` (every start)
## asks the origin for each unpinned map's `latest.json` and writes the answers to
## `data/content-maps.json`, which this reads. A new upload of a map reaches a server on
## its next restart; an origin that is down keeps the cached version; an unpinned map with
## no cached version is left out with a warning rather than blocking the boot.

const CHANNEL := "tmc.content"

## The owner's file, under the config directory.
const FILE := "content.yml"

## The installer's answers for every unpinned map, under the data directory:
## `{"maps": {"<owner>/<map>": "<version>"}}`.
const RESOLVED_FILE := "content-maps.json"

## The newest `collection.json` format this build reads.
const COLLECTION_FORMAT := 1

## Keys a game section may carry.
const KEYS: PackedStringArray = ["name", "max_players", "cvars", "metadata", "maps", "map_owner"]

## Keys that say what the game IS. Refused, with the reason.
const IDENTITY: PackedStringArray = [
	"scene", "client_scene", "module", "kind", "content_id", "version", "manifest_url",
	"dependencies", "server_dependencies",
]

## The descriptor metadata keys the host sets, which nothing may replace.
const HOST_METADATA: PackedStringArray = ["kind", "module", "directory"]

## `defaults:`, normalised (see [method _read_section]). Starts as an empty section rather
## than `{}`: a server with no file still applies it, and `{}` has no `cvars` to read.
var defaults: Dictionary = {}

## `games:`, game key as written -> normalised section.
var games: Dictionary = {}

## `<owner>/<map>` -> version, from the installer's cache.
var resolved: Dictionary = {}

## `owner/collection` -> the `owner/map` ids it published when the installer last reached the
## origin (`data/content-maps.json`, key `collections`); what an `owner/collection/*` entry in
## `maps:` expands to. The last good expansion is kept, so a start during an outage still
## has the maps it had.
var collections: Dictionary = {}

## Problems found while applying, for the boot report.
var warnings: PackedStringArray = PackedStringArray()

## Entries that cannot be used at all (a bare map name no rule can give an owner). Unlike a
## warning these stop the host: a server that quietly offered fewer maps than its owner
## wrote is the failure this file replaced.
var errors: PackedStringArray = PackedStringArray()


func _init() -> void:
	defaults = _read_section("defaults", {}).value


## Reads `cfg/content.yml` and the installer's cache. A missing file is no overrides, not
## an error: a server that takes every game as its author shipped it needs nothing here.
static func load_from(config_dir: String, data_dir: String) -> DotResult:
	var out := TmcGameConfig.new()
	var path := "%s/%s" % [config_dir.rstrip("/"), FILE]

	if FileAccess.file_exists(path):
		var parsed := TmcYaml.parse_file(path)

		if not parsed.ok:
			return parsed

		var read := out.read(parsed.value as Dictionary)

		if not read.ok:
			return read.wrap("%s:" % path)

	var cache := "%s/%s" % [data_dir.rstrip("/"), RESOLVED_FILE]

	if FileAccess.file_exists(cache):
		var body: Variant = JSON.parse_string(FileAccess.get_file_as_string(cache))

		if body is Dictionary and (body as Dictionary).get("maps") is Dictionary:
			out.resolved = (body as Dictionary)["maps"]

		if body is Dictionary and (body as Dictionary).get("collections") is Dictionary:
			out.collections = (body as Dictionary)["collections"]

	return DotResult.success(out)


## Takes a parsed `content.yml` apart. Refuses anything it would otherwise have to guess
## about, naming the key: an override that is silently ignored is the bug this replaces.
func read(tree: Dictionary) -> DotResult:
	for key: String in tree:
		if not key in ["defaults", "games"]:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Unknown top-level key '%s'." % key,
				"expected defaults: and games:; see cfg.example/%s" % FILE
			)

	var got := _read_section("defaults", tree.get("defaults", {}))

	if not got.ok:
		return got

	defaults = got.value

	var listed: Variant = tree.get("games", {})

	if listed == null or (listed is String and str(listed) == ""):
		listed = {}

	if not (listed is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "games: must map a game id to its settings.")

	for game: String in (listed as Dictionary):
		var section := _read_section("games: " + game, (listed as Dictionary)[game])

		if not section.ok:
			return section

		games[game] = section.value

	return DotResult.success(null)


## Every map entry the file names for the games in [param content], qualified: what the
## installer resolves. The installer and the host read the same rule here
## ([method qualified_rule]), so the id `install-games` pins is the id [method apply] looks
## up. A bare name of a section no game in [param content] matches cannot be given an
## owner and is skipped (the host reports the section); an unusable entry lands in
## [member errors] and the rest still resolve.
func all_map_entries(content: TmcContent = null) -> PackedStringArray:
	var out := PackedStringArray()

	if content != null:
		for descriptor in content.games:
			var owner := map_owner_for(descriptor)

			for section: Dictionary in [defaults, _section_for(descriptor)]:
				if section.is_empty():
					continue

				var rule := qualified_rule(descriptor.game_id, section["maps"], owner)

				for entry in (rule["add"] as PackedStringArray):
					if not out.has(entry):
						out.append(entry)

	# Sections no descriptor claimed (or no content given): only the spellings that need
	# no owner.
	for section: Dictionary in [defaults] + games.values():
		for entry in (section["maps"]["add"] as PackedStringArray):
			if bool(TmcGameRef.qualify_map(entry, "")["ok"]) and not out.has(_spelled(entry, "")):
				out.append(_spelled(entry, ""))

	return out


## The maps of one collection from its published `collection.json` body:
## `{"format": 1, "id": "<owner>/<collection>", "version": "...", "packs": ["<owner>/<map>"]}`.
## Returns a DotResult of a PackedStringArray of `owner/map` ids. A `format` newer than this
## build reads is an error naming the collection (guessing at a newer shape would offer the
## wrong maps), as is a body for another id or a pack that is not exactly `owner/map`.
static func parse_collection(collection: String, body: Variant) -> DotResult:
	if not (body is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "collection %s: collection.json is not an object." % collection)

	var doc := body as Dictionary
	var format := int(doc.get("format", 0)) if (doc.get("format") is int or doc.get("format") is float) else 0

	if format < 1 or format > COLLECTION_FORMAT:
		return DotResult.fail(
			DotError.CODE_INVALID, "collection %s: collection.json format %s is not one this build reads." % [collection, str(doc.get("format"))],
			"this build reads format %d; update the server" % COLLECTION_FORMAT)

	if str(doc.get("id", collection)) != collection:
		return DotResult.fail(DotError.CODE_INVALID, "collection %s: collection.json says it is %s." % [collection, str(doc.get("id"))])

	if not (doc.get("packs") is Array):
		return DotResult.fail(DotError.CODE_INVALID, "collection %s: collection.json has no packs list." % collection)

	var out := PackedStringArray()

	for pack in (doc["packs"] as Array):
		var parts := str(pack).split("/")

		if not (pack is String) or parts.size() != 2 or "" in parts or str(pack).contains("@") or str(pack).contains("*"):
			return DotResult.fail(DotError.CODE_INVALID, "collection %s: '%s' is not an owner/map pack id." % [collection, str(pack)])

		if not out.has(str(pack)):
			out.append(str(pack))

	return DotResult.success(out)


## Who a bare map name belongs to for [param descriptor]; "" when nothing says. The order
## is in the class comment. The cvar is read as the game will run with it: its
## `game.yml` value, then `defaults:`, then the game's section.
func map_owner_for(descriptor: DotGameDescriptor) -> String:
	var own := _section_for(descriptor)

	if str(own.get("map_owner", "")) != "":
		return str(own["map_owner"])

	if str(defaults.get("map_owner", "")) != "":
		return str(defaults["map_owner"])

	var cvars := descriptor.cvars.duplicate()
	cvars.merge(defaults["cvars"], true)
	cvars.merge(own.get("cvars", {}), true)
	var cvar := str(cvars.get("sv_map_content_owner", "")).strip_edges()

	if cvar != "":
		return cvar

	return descriptor.content_id.get_slice("/", 0) if descriptor.content_id.contains("/") else ""


## [param rule] (a normalised `maps:` block) with every entry qualified for [param owner].
## `add` entries keep their `@version`; `remove` entries are ids, or a bare name when
## [param owner] is "" (then [method _maps] matches it on the name half, because removing
## needs no owner to be unambiguous). An `add` that cannot be qualified is dropped and
## recorded in [member errors] with [param game] and the entry.
func qualified_rule(game: String, rule: Dictionary, owner: String) -> Dictionary:
	var add := PackedStringArray()
	var remove := PackedStringArray()

	for entry in (rule["add"] as PackedStringArray):
		var q := TmcGameRef.qualify_map(entry, owner)

		if not bool(q["ok"]):
			var line := "%s: maps: add: '%s' %s" % [game, entry, q["why"]]

			if not errors.has(line):
				errors.append(line)

			continue

		add.append(_spelled(entry, owner))

	for entry in (rule["remove"] as PackedStringArray):
		var q := TmcGameRef.qualify_map(entry, owner)
		remove.append(str(q["id"]) if bool(q["ok"]) else entry)

	return {"add": add, "remove": remove, "game_maps": rule["game_maps"]}


## `owner/map[@version]` for an entry written as [param raw].
static func _spelled(raw: String, owner: String) -> String:
	var q := TmcGameRef.qualify_map(raw, owner)
	var out := str(q["id"])
	return out if str(q["version"]) == "" else "%s@%s" % [out, q["version"]]


## Lays the file over every descriptor in [param content]. Returns how many changed.
func apply_all(content: TmcContent) -> int:
	var changed := 0

	for descriptor in content.games:
		if apply(descriptor):
			changed += 1

	for key: String in games:
		if _matching(content, key).is_empty():
			warnings.append("cfg/%s names the game '%s', which is not on this server" % [FILE, key])

	return changed


## Lays `defaults:` and then the game's own section over [param descriptor]. True when
## anything changed.
func apply(descriptor: DotGameDescriptor) -> bool:
	var before := [descriptor.display_name, descriptor.max_players,
		descriptor.cvars.duplicate(true), descriptor.metadata.duplicate(true), descriptor.maps,
		descriptor.dependencies, descriptor.server_dependencies]

	var owner := map_owner_for(descriptor)

	_apply_section(descriptor, defaults, owner)

	var own := _section_for(descriptor)

	if not own.is_empty():
		_apply_section(descriptor, own, owner)

	_maps_to_clients(descriptor)

	var after := [descriptor.display_name, descriptor.max_players,
		descriptor.cvars, descriptor.metadata, descriptor.maps, descriptor.dependencies,
		descriptor.server_dependencies]

	if str(before) == str(after):
		return false

	DotLog.info(CHANNEL, "the server's settings for a game override its own", {
		"game": descriptor.game_id,
		"maps": descriptor.maps.size(),
		"cvars": descriptor.cvars.size(),
	})
	return true


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()

	for key: String in ["defaults"] + games.keys():
		var section: Dictionary = defaults if key == "defaults" else games[key]
		var maps: Dictionary = section["maps"]
		lines.append("%s: %d cvars, %d metadata keys, maps +%d -%d%s%s%s" % [
			key,
			(section["cvars"] as Dictionary).size(),
			(section["metadata"] as Dictionary).size(),
			(maps["add"] as PackedStringArray).size(),
			(maps["remove"] as PackedStringArray).size(),
			"" if bool(maps["game_maps"]) else " (game's dropped)",
			", name" if section.has("name") else "",
			", max_players" if section.has("max_players") else "",
		])

		if section.has("map_owner"):
			lines[lines.size() - 1] += ", map_owner " + str(section["map_owner"])

	return lines


# --- Reading --------------------------------------------------------------------


## One section, normalised: `cvars` and `metadata` always Dictionaries, `maps` always
## `{"add", "remove", "game_maps"}`, `name` and `max_players` only when written.
func _read_section(where: String, value: Variant) -> DotResult:
	var out := {
		"cvars": {},
		"metadata": {},
		"maps": {"add": PackedStringArray(), "remove": PackedStringArray(), "game_maps": true},
	}

	if value == null or (value is String and str(value) == ""):
		return DotResult.success(out)

	if not (value is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "%s must be a mapping." % where)

	var section := value as Dictionary

	for key: String in section:
		if key in IDENTITY:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"%s: '%s' cannot be overridden by a server." % [where, key],
				"it says which game this is; a different value is a different game"
			)

		if not key in KEYS:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"%s: unknown key '%s'." % [where, key],
				"a game's settings here are %s" % ", ".join(KEYS)
			)

	if section.has("name"):
		out["name"] = str(section["name"])

	if section.has("max_players"):
		if not str(section["max_players"]).is_valid_int():
			return DotResult.fail(DotError.CODE_INVALID, "%s: max_players must be a number." % where)
		out["max_players"] = int(section["max_players"])

	for key in ["cvars", "metadata"]:
		var block: Variant = section.get(key, {})

		if block == null or (block is String and str(block) == ""):
			continue

		if not (block is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "%s: %s must be a mapping." % [where, key])

		out[key] = TmcContent.flatten_cvars(block) if key == "cvars" else block

	if section.has("map_owner"):
		var who := str(section["map_owner"]).strip_edges()

		if who == "" or who.contains("/") or who.contains("@") or who.contains(" "):
			return DotResult.fail(
				DotError.CODE_INVALID, "%s: map_owner must be one owner name, e.g. gamemann." % where
			)

		out["map_owner"] = who

	var maps := _read_maps(where, section.get("maps", {}))

	if not maps.ok:
		return maps

	out["maps"] = maps.value
	return DotResult.success(out)


func _read_maps(where: String, value: Variant) -> DotResult:
	# Built here and assigned once: a PackedStringArray is a value, so appending through
	# `rule[field] as PackedStringArray` appends to a copy nobody keeps.
	var add := PackedStringArray()
	var remove := PackedStringArray()
	var game_maps := true

	if value is Array:
		value = {"add": value}
	elif value == null or (value is String and str(value) == ""):
		value = {}

	if not (value is Dictionary):
		return DotResult.fail(
			DotError.CODE_INVALID, "%s: maps must be a list, or add/remove/game_maps." % where
		)

	for key: String in (value as Dictionary):
		if not key in ["add", "remove", "game_maps"]:
			return DotResult.fail(
				DotError.CODE_INVALID, "%s: maps: unknown key '%s'." % [where, key],
				"maps takes add, remove and game_maps"
			)

	for field in ["add", "remove"]:
		var listed: Variant = (value as Dictionary).get(field, [])

		if listed == null or (listed is String and str(listed) == ""):
			continue

		if not (listed is Array):
			return DotResult.fail(
				DotError.CODE_INVALID, "%s: maps: %s must be a list." % [where, field]
			)

		for entry in listed:
			# Only the SHAPE is checked here; the owner of a bare name depends on the game,
			# which a section does not know. qualify_map with a placeholder owner is the
			# same parser the resolution uses.
			var shape := TmcGameRef.qualify_map(str(entry), "x")

			if not bool(shape["ok"]):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"%s: maps: '%s' %s." % [where, str(entry), shape["why"]],
					"a map here is a published pack: gamemann/surf_mesa, or surf_mesa with a map_owner"
				)

			var ref := TmcGameRef.parse(str(entry))
			var spelled := str(ref["id"])

			if field == "add" and str(ref["version"]) != "":
				spelled += "@" + str(ref["version"])

			if field == "add":
				add.append(spelled)
			else:
				remove.append(str(ref["id"]))

	game_maps = bool((value as Dictionary).get("game_maps", true))
	return DotResult.success({"add": add, "remove": remove, "game_maps": game_maps})


# --- Applying -------------------------------------------------------------------


func _apply_section(descriptor: DotGameDescriptor, section: Dictionary, owner: String) -> void:
	if section.has("name"):
		descriptor.display_name = str(section["name"])

	if section.has("max_players"):
		descriptor.max_players = int(section["max_players"])

	var cvars: Dictionary = section["cvars"]

	for name: Variant in cvars:
		descriptor.cvars[name] = cvars[name]

	var metadata: Dictionary = section["metadata"]

	for key: Variant in metadata:
		if str(key) in HOST_METADATA:
			warnings.append("%s: metadata '%s' is the host's and was not changed" % [
				descriptor.game_id, str(key)])
			continue

		descriptor.metadata[key] = _merged(descriptor.metadata.get(key), metadata[key])

	descriptor.maps = _maps(descriptor, qualified_rule(descriptor.game_id, section["maps"], owner))


## When a game's maps are fetched, which only the game can say: `metadata: maps_delivery:`
## in its game.yml.
##
## - `lazy` (or absent): only in `maps`, fetched when the server changes to one. For a game
##   whose maps are large scenes, one pack each -- a gigabyte before boot otherwise.
## - `server`: also in `server_dependencies`, which dot-server fetches and mounts BEFORE the
##   game loads, on the server only. For a game whose maps are small documents the server
##   sends each client itself. Without it the game fetched them during its own module load,
##   which dot-server does not wait for: the first players were admitted to a server playing
##   only the game's built-in course (dot-server-deploy's wipeout_client found that).
## - `client`: also in `dependencies`, fetched before load and sent to every client in the
##   content sync, for a game whose client builds a map from its pack itself.
func _maps_to_clients(descriptor: DotGameDescriptor) -> void:
	var mode := str(descriptor.metadata.get("maps_delivery", "lazy"))
	var into: PackedStringArray

	match mode:
		"server":
			into = descriptor.server_dependencies
		"client":
			into = descriptor.dependencies
		"lazy":
			return
		_:
			warnings.append("%s: maps_delivery '%s' is not lazy, server or client; treated as lazy" % [
				descriptor.game_id, mode])
			return

	var have := {}

	for key in into:
		have[_content_id(key)] = true

	for key in descriptor.maps:
		if not have.has(_content_id(key)):
			into.append(key)
			have[_content_id(key)] = true

	# Assigned back: a PackedStringArray is a value, and `into` is a copy of the property.
	if mode == "server":
		descriptor.server_dependencies = into
	else:
		descriptor.dependencies = into


## [param over] laid over [param base]: dictionaries merge key by key, anything else
## replaces. Never modifies either.
static func _merged(base: Variant, over: Variant) -> Variant:
	if not (base is Dictionary and over is Dictionary):
		return over.duplicate(true) if (over is Dictionary or over is Array) else over

	var out := (base as Dictionary).duplicate(true)

	for key: Variant in (over as Dictionary):
		out[key] = _merged(out.get(key), (over as Dictionary)[key])

	return out


func _maps(descriptor: DotGameDescriptor, rule: Dictionary) -> PackedStringArray:
	var by_id := {}
	var order := PackedStringArray()

	if bool(rule["game_maps"]):
		for key in descriptor.maps:
			var id := _content_id(key)
			by_id[id] = key
			order.append(id)

	# A wildcard in `remove` is every map its collection published; one map in `remove`
	# takes that map out of a wildcard in `add` (below) the same way.
	var removed := PackedStringArray()

	for entry in (rule["remove"] as PackedStringArray):
		if TmcGameRef.is_wildcard(entry):
			for member in _members_of(entry):
				removed.append(member)
		else:
			removed.append(entry)

	for entry in removed:
		var id := _content_id(entry)

		# A bare name that no owner could be found for matches every map of that name.
		var doomed := PackedStringArray([id])

		if not id.contains("/"):
			doomed.clear()

			for have in order:
				if _name_half(have) == id:
					doomed.append(have)

		for gone in doomed:
			by_id.erase(gone)
			var at := order.find(gone)
			if at >= 0:
				order.remove_at(at)

	# What `add` means once collections are expanded: an explicit entry always wins over
	# the same map arriving through a wildcard (it carries the pin), and `remove` takes a
	# map out of a wildcard but never out of an explicit entry. Explicit entries are
	# collected first so a wildcard before them cannot claim their ids.
	var explicit := {}

	for entry in (rule["add"] as PackedStringArray):
		if not TmcGameRef.is_wildcard(entry):
			explicit[str(TmcGameRef.parse(entry)["id"])] = true

	var adds := PackedStringArray()

	for entry in (rule["add"] as PackedStringArray):
		if not TmcGameRef.is_wildcard(entry):
			adds.append(entry)
			continue

		var members := _members_of(entry)

		if members.is_empty():
			warnings.append(
				"%s: the collection %s has no maps yet; ./server install-games resolves it"
				% [descriptor.game_id, entry.trim_suffix("/*")]
			)

		for member in members:
			if not explicit.has(member) and not removed.has(member) and not adds.has(member):
				adds.append(member)

	for entry in adds:
		var ref := TmcGameRef.parse(entry)
		var id := str(ref["id"])
		var version := str(ref["version"])

		if version == "":
			version = str(resolved.get(id, ""))

		if version == "":
			warnings.append(
				"%s: the map %s has no version yet; ./server install-games resolves it"
				% [descriptor.game_id, id]
			)
			continue

		# An owner's entry wins over the game's own pin of the same map: that is how a
		# server takes a newer map than the game was released with.
		if not by_id.has(id):
			order.append(id)
		by_id[id] = "%s@%s" % [id, version]

	var maps := PackedStringArray()

	for id in order:
		if by_id.has(id):
			maps.append(by_id[id])

	return maps


## The `owner/map` ids an `owner/collection/*` entry last expanded to; empty until the
## installer has reached the origin once.
func _members_of(wildcard: String) -> PackedStringArray:
	var out := PackedStringArray()

	for member in (collections.get(wildcard.trim_suffix("/*"), []) as Array):
		out.append(str(member))

	return out


## The section for a descriptor: by its whole id, by its content id, then by its name half.
func _section_for(descriptor: DotGameDescriptor) -> Dictionary:
	return section_in(games, descriptor)


## [method _section_for] over any `games:` map, because `cfg/addons.yml` keys its games the
## same way and a second copy of the lookup would let the two files disagree about which
## game `g2gfast` means.
static func section_in(sections: Dictionary, descriptor: DotGameDescriptor) -> Dictionary:
	for key in [descriptor.game_id, descriptor.content_id, _name_half(descriptor.game_id)]:
		if key != "" and sections.has(key):
			return sections[key]

	return {}


func _matching(content: TmcContent, key: String) -> Array:
	var out := []

	for descriptor in content.games:
		if key in [descriptor.game_id, descriptor.content_id, _name_half(descriptor.game_id)]:
			out.append(descriptor)

	return out


## Whether a `games:` key names any game on this server, by the same three spellings.
static func key_matches_any(key: String, content: TmcContent) -> bool:
	for descriptor in content.games:
		if key in [descriptor.game_id, descriptor.content_id, _name_half(descriptor.game_id)]:
			return true

	return false


static func _name_half(id: String) -> String:
	return id.get_slice("/", id.get_slice_count("/") - 1)


static func _content_id(key: String) -> String:
	return str(TmcGameRef.parse(key)["id"])
