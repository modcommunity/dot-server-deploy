class_name TmcAddonsConfig
extends RefCounted

## The extra packs a server OWNER adds to a game, from `cfg/packs.yml`.
##
## [codeblock]
## defaults:                            # every game on this server
##   add: [owner/pack, owner/pack@1.2.0]
## games:
##   game-g2gfast:                      # a game id, or its name half while unambiguous
##     add: [owner/other]
##     remove: [owner/pack]             # drop a default for this game only
## [/codeblock]
##
## [b]A pack is delivered as one more dependency of the game, for this server.[/b] The
## server mounts it before the game loads and every client downloads and mounts it before
## the game, in the one content sync it already gets (`content_extra`). Nothing about the
## game's identity moves: `content.yml` still refuses `dependencies:`, because a
## dependency list there would be the owner rewriting which game this is. Here the owner
## ADDS to what the author listed, after it, and a pack the game already lists is not
## listed twice.
##
## [b]Pinned at install, like every other pack list.[/b] `TmcContent` refuses an unpinned
## dependency, because a version decided per join would hand two players two packs under
## one game. So `./server install-games` (every start) pins each unpinned entry to the
## origin's newest version into `data/content-addons.json`, prefetches it, and drops a pack
## this build's addons cannot run (`requires.json`) from that file with a message. This
## class reads the file; an entry with no version and no cached answer is left out with a
## warning rather than blocking the boot, as an unresolved map is.
##
## [b]A pack may start something.[/b] See [TmcAddonEntry]: a pack whose manifest metadata
## names an `entry` scene has it instantiated on the server, the client or both after the
## game loads. A pack without one is just mounted.

const CHANNEL := "tmc.content"

## The owner's file, under the config directory.
const FILE := "packs.yml"
## The name before the cfg/ move; read through DotCfgLegacy until its cutoff.
const LEGACY_FILE := "addons.yml"

## The installer's answers, under the data directory: `{"packs": {"<owner>/<pack>": "<version>"}}`.
const RESOLVED_FILE := "content-addons.json"

const SECTION_KEYS: PackedStringArray = ["add", "remove"]

## `defaults: add:`, as written (`owner/pack` or `owner/pack@version`).
var defaults_add: PackedStringArray = PackedStringArray()

## `games:`, game key as written -> `{"add": PackedStringArray, "remove": PackedStringArray}`.
var games: Dictionary = {}

## `<owner>/<pack>` -> version, from the installer's cache.
var resolved: Dictionary = {}

## Problems found while applying, for the boot report.
var warnings: PackedStringArray = PackedStringArray()


## Reads `cfg/packs.yml` and the installer's cache. A missing file is no extra packs.
static func load_from(config_dir: String, data_dir: String) -> DotResult:
	var out := TmcAddonsConfig.new()
	var dir := config_dir.rstrip("/")
	var path := DotCfgLegacy.find("%s/%s" % [dir, LEGACY_FILE], "%s/%s" % [dir, FILE])

	if path != "" and FileAccess.file_exists(path):
		var parsed := TmcYaml.parse_file(path)

		if not parsed.ok:
			return parsed

		var read := out.read(parsed.value as Dictionary)

		if not read.ok:
			return read.wrap("%s:" % path)

	var cache := "%s/%s" % [data_dir.rstrip("/"), RESOLVED_FILE]

	if FileAccess.file_exists(cache):
		var body: Variant = JSON.parse_string(FileAccess.get_file_as_string(cache))

		if body is Dictionary and (body as Dictionary).get("packs") is Dictionary:
			out.resolved = (body as Dictionary)["packs"]

	return DotResult.success(out)


## Takes a parsed `packs.yml` apart, refusing what it would otherwise have to guess at.
func read(tree: Dictionary) -> DotResult:
	for key: String in tree:
		if not key in ["defaults", "games"]:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Unknown top-level key '%s'." % key,
				"expected defaults: and games:; see cfg.example/%s" % FILE
			)

	var defaults: Variant = tree.get("defaults", {})

	if defaults != null and not (defaults is String and str(defaults) == ""):
		if not (defaults is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "defaults: must be a mapping with add:.")

		for key: String in (defaults as Dictionary):
			if key != "add":
				return DotResult.fail(
					DotError.CODE_INVALID, "defaults: unknown key '%s'." % key,
					"defaults takes add; remove is per game"
				)

		var added := _read_list("defaults", "add", (defaults as Dictionary).get("add", []))

		if not added.ok:
			return added

		defaults_add = added.value

	var listed: Variant = tree.get("games", {})

	if listed == null or (listed is String and str(listed) == ""):
		listed = {}

	if not (listed is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "games: must map a game id to its packs.")

	for game: String in (listed as Dictionary):
		var section: Variant = (listed as Dictionary)[game]
		var where := "games: " + game
		var entry := {"add": PackedStringArray(), "remove": PackedStringArray()}

		if section is Array:
			section = {"add": section}
		elif section == null or (section is String and str(section) == ""):
			section = {}

		if not (section is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "%s must be a mapping with add: and remove:." % where)

		for key: String in (section as Dictionary):
			if not key in SECTION_KEYS:
				return DotResult.fail(
					DotError.CODE_INVALID, "%s: unknown key '%s'." % [where, key],
					"a game's packs here are add and remove"
				)

		for field in SECTION_KEYS:
			var got := _read_list(where, field, (section as Dictionary).get(field, []))

			if not got.ok:
				return got

			entry[field] = got.value

		games[game] = entry

	return DotResult.success(null)


## The packs [param descriptor] gets, `owner/pack@version` where a version is known and
## `owner/pack` where it is not yet (install-games pins those). Defaults first, then the
## game's own; a pack the game removes is dropped by id whichever list named it; the
## game's own spelling of a pack wins over the default's.
func entries_for(descriptor: DotGameDescriptor) -> PackedStringArray:
	var own: Dictionary = TmcGameConfig.section_in(games, descriptor)
	var removed := PackedStringArray()
	var by_id := {}
	var order := PackedStringArray()

	for id in (own.get("remove", PackedStringArray()) as PackedStringArray):
		removed.append(_id_of(id))

	for list: PackedStringArray in [defaults_add, own.get("add", PackedStringArray())]:
		for entry in list:
			var id := _id_of(entry)

			if id in removed:
				continue

			if not by_id.has(id):
				order.append(id)

			by_id[id] = entry

	var out := PackedStringArray()

	for id in order:
		out.append(by_id[id])

	return out


## Every pack the file asks for across [param content]'s games, one entry per id and
## the pinned spelling when any game pins it: what the installer resolves and prefetches.
func all_entries(content: TmcContent = null) -> PackedStringArray:
	var by_id := {}
	var order := PackedStringArray()
	var sources: Array[PackedStringArray] = []

	if content != null:
		for descriptor in content.games:
			sources.append(entries_for(descriptor))
	else:
		sources.append(defaults_add)

		for section: Dictionary in games.values():
			sources.append(section["add"])

	for list in sources:
		for entry in list:
			var id := _id_of(entry)

			if not by_id.has(id):
				order.append(id)
				by_id[id] = entry
			elif _version_of(by_id[id]) == "":
				by_id[id] = entry

	var out := PackedStringArray()

	for id in order:
		out.append(by_id[id])

	return out


## Appends every game's packs to its dependencies. Returns how many descriptors changed.
func apply_all(content: TmcContent) -> int:
	var changed := 0

	for descriptor in content.games:
		if apply(descriptor):
			changed += 1

	for key: String in games:
		if not TmcGameConfig.key_matches_any(key, content):
			warnings.append("cfg/%s names the game '%s', which is not on this server" % [FILE, key])

	return changed


## Appends [param descriptor]'s packs to `dependencies`, AFTER what the game lists, without
## repeating a content id it already has. True when anything was added.
func apply(descriptor: DotGameDescriptor) -> bool:
	var have := {}

	for key in descriptor.dependencies:
		have[_id_of(key)] = true

	# The server-only list too: a pack the server already mounts for the game is not
	# fetched twice, but it would still never reach a client if it were left there, so it
	# is only counted as present for the dedupe of an entry that names a SERVER pack.
	var added := PackedStringArray()
	var deps := descriptor.dependencies

	for entry in entries_for(descriptor):
		var id := _id_of(entry)
		var version := _version_of(entry)

		if have.has(id):
			continue

		if version == "":
			version = str(resolved.get(id, ""))

		if version == "":
			warnings.append(
				"%s: the pack %s has no version yet; ./server install-games resolves it" % [
					descriptor.game_id, id]
			)
			continue

		deps.append("%s@%s" % [id, version])
		added.append("%s@%s" % [id, version])
		have[id] = true

	if added.is_empty():
		return false

	# Assigned back: a PackedStringArray is a value, and `deps` is a copy of the property.
	descriptor.dependencies = deps
	DotLog.info(CHANNEL, "extra packs added to a game for this server", {
		"game": descriptor.game_id, "packs": ", ".join(added),
	})
	return true


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("defaults: +%d (%s)" % [defaults_add.size(), ", ".join(defaults_add)])

	for key: String in games:
		var section: Dictionary = games[key]
		lines.append("%s: +%d -%d (%s)" % [
			key, (section["add"] as PackedStringArray).size(),
			(section["remove"] as PackedStringArray).size(), ", ".join(section["add"]),
		])

	lines.append("pinned by install-games: %d" % resolved.size())
	return lines


## `<owner>/<pack>` or `<owner>/<pack>@<version>` -> normalised `id[@version]`, or a failure.
static func parse_entry(raw: String) -> DotResult:
	var ref := TmcGameRef.parse(raw)
	var id := str(ref["id"])
	var segments := id.split("/")

	if segments.size() != 2 or "" in segments:
		return DotResult.fail(
			DotError.CODE_INVALID, "'%s' is not <owner>/<pack>." % raw,
			"a pack here is a published content id, e.g. someone/extra-sounds"
		)

	var version := str(ref["version"])
	return DotResult.success(id if version == "" else "%s@%s" % [id, version])


func _read_list(where: String, field: String, value: Variant) -> DotResult:
	var out := PackedStringArray()

	if value == null or (value is String and str(value) == ""):
		return DotResult.success(out)

	if not (value is Array):
		return DotResult.fail(DotError.CODE_INVALID, "%s: %s must be a list." % [where, field])

	for raw in value:
		var one := parse_entry(str(raw))

		if not one.ok:
			return DotResult.fail(
				DotError.CODE_INVALID, "%s: %s: %s" % [where, field, one.error.message],
				str(one.error.detail)
			)

		if not out.has(str(one.value)):
			out.append(str(one.value))

	return DotResult.success(out)


static func _id_of(entry: String) -> String:
	return str(TmcGameRef.parse(entry)["id"])


static func _version_of(entry: String) -> String:
	return str(TmcGameRef.parse(entry)["version"])
