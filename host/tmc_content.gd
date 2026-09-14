class_name TmcContent
extends RefCounted

## The `content/` directory, read into [DotGameDescriptor]s.
##
## One subdirectory per game, each with a `game.yml` that names it. The directory name is
## the id an operator types at the console, which is why it is the directory name and not a
## field: two places to write the same thing is one place to write it differently.
##
## [codeblock]
## content/
##   global/          loaded by every game. No game.yml; it is not a game.
##   lobby/
##     game.yml
##   arena/
##     game.yml
##     pack/          what gets published, when kind is `pack`
## [/codeblock]
##
## [b]Two kinds, and the difference is not cosmetic.[/b]
##
## `builtin` — the game's code is compiled into this build. The scene is an absolute
## `res://` path and the client scene is deliberately **empty**, because
## [method DotClientLink._resolve_scene] refuses every absolute path outside dot-cloud's
## mount. A server that named one would have every client refuse it, never report loaded,
## and be timed out in `LOADING` with no other symptom.
##
## `pack` — the game is delivered through dot-cloud. Paths are relative and resolve under
## the version-namespaced mount, so a client that has never heard of this game downloads it
## and instantiates the scene named here.
##
## [b]A pack's scripts may not use `class_name`.[/b] Measured, not assumed: a mounted pack's
## globals are not registered in the host, so every cross-file type reference inside it
## fails to compile — the pack mounts, the scene loads, and every script in it is dead.
## `preload("res://path.gd")` and `extends "res://path.gd"` both work. That is the whole
## constraint and it is why the lobby is `builtin`: it is the shell's home screen and is
## written in the family's ordinary style.

const CHANNEL := "tmc.content"

## Directories under `content/` that are deliberately not games.
##
## `global` is content every game loads on top of its own. `avatars` is where a game looks
## for cosmetic parts that shipped in the build — `HungryContentSource` reads
## `res://content/avatars/` — and it lands here because `res://content/` is this project's
## content root and a game cannot be asked to look somewhere else without re-authoring it.
##
## Skipped silently rather than reported. A directory with no `game.yml` that nobody meant
## as a game is reported once and then ignored for ever, which trains an operator to ignore
## the report — and the report exists for the half-finished upload, which is the case worth
## seeing.
const NOT_GAMES := ["global", "avatars"]

## The file that makes a directory a game.
const DESCRIPTOR := "game.yml"

## Descriptors, in directory order.
var games: Array[DotGameDescriptor] = []

## The one to load at boot. Empty when nothing claimed it.
var default_game: String = ""

## Directories skipped, and why. Reported at boot rather than silently ignored.
var skipped: PackedStringArray = PackedStringArray()

## Absolute path of the content root, for publishing.
var root: String = ""


## Scans a content directory.
##
## A directory with no `game.yml` is skipped and reported — it is what a half-finished
## upload looks like, and also what `README.md` sitting in `content/` looks like, and an
## operator should be able to tell which.
static func scan(directory: String) -> DotResult:
	var index := TmcContent.new()
	index.root = directory.rstrip("/")

	var dir := DirAccess.open(index.root)

	if dir == null:
		return DotResult.fail(
			DotError.CODE_IO,
			"No content directory at %s." % index.root,
			"a server with no content is legitimate; a missing directory is a typo"
		)

	var names := dir.get_directories()
	names.sort()

	for name in names:
		if name in NOT_GAMES or name.begins_with("."):
			continue

		var path := "%s/%s/%s" % [index.root, name, DESCRIPTOR]

		if not FileAccess.file_exists(path):
			index.skipped.append("%s (no %s)" % [name, DESCRIPTOR])
			continue

		var parsed := TmcYaml.parse_file(path)

		if not parsed.ok:
			return parsed.wrap("Could not read %s" % path)

		var built := index._build(name, parsed.value as Dictionary)

		if not built.ok:
			return built.wrap("%s is not a usable game" % path)

		var descriptor := built.value as DotGameDescriptor
		index.games.append(descriptor)

		if bool(TmcYaml.at(parsed.value as Dictionary, "default", false)):
			if index.default_game != "":
				# Refused rather than resolved by order. Two games both claiming the boot
				# slot is an operator mistake with no correct answer, and picking one
				# alphabetically means a server that boots into a different game after a
				# rename.
				return DotResult.fail(
					DotError.CODE_INVALID,
					"Both '%s' and '%s' are marked default." % [index.default_game, name]
				)

			index.default_game = descriptor.game_id

	if index.default_game == "" and not index.games.is_empty():
		index.default_game = index.games[0].game_id

	DotLog.info(CHANNEL, "content scanned", {
		"games": index.games.size(),
		"default": index.default_game,
		"skipped": index.skipped.size(),
	})

	return DotResult.success(index)


func _build(name: String, tree: Dictionary) -> DotResult:
	var descriptor := DotGameDescriptor.new()

	# The directory name is the id. A `game.yml` that disagreed would give the same game
	# two names, and the console would take one and the content path the other.
	descriptor.game_id = name
	descriptor.display_name = String(TmcYaml.at(tree, "name", name))
	descriptor.version = String(TmcYaml.at(tree, "version", "0.0.0"))
	descriptor.max_players = int(TmcYaml.at(tree, "max_players", 0))

	var kind := String(TmcYaml.at(tree, "kind", "builtin"))
	var scene := String(TmcYaml.at(tree, "scene", ""))
	var client_scene := String(TmcYaml.at(tree, "client_scene", ""))

	# [b]What the game is made of, as opposed to what this server calls it.[/b] The id is
	# the directory name — an operator's choice, and what they type at the console — but a
	# client holds a table of the games built into it and cannot be keyed on that: renaming
	# `content/lobby` to `content/foyer` would leave every client unable to find the scene
	# for a game it has. It is also how two game ids share one client: hungry's two modes
	# are one `hungry`.
	#
	# Defaults to the directory name, so a game that does not care never mentions it.
	descriptor.content_id = String(TmcYaml.at(tree, "content_id", name))

	match kind:
		"builtin":
			descriptor.manifest_url = ""
			descriptor.scene = scene

			if client_scene != "":
				# Not silently dropped. An operator who wrote one meant something by it,
				# and the failure it causes — a client stuck in LOADING until it is timed
				# out — gives no hint at all about where it came from.
				return DotResult.fail(
					DotError.CODE_INVALID,
					"A builtin game must not name a client_scene.",
					"DotClientLink refuses every absolute path outside dot-cloud's mount, "
					+ "so the client would refuse it and be timed out in LOADING"
				)
		"pack":
			# [b]Optional, and it used to be required.[/b] A pack is found by its content
			# id: `content/` and `dist/` on this box are searched first, then every
			# `content_urls` entry in order. Requiring an address here meant writing a
			# per-DEPLOYMENT fact into a per-GAME file -- a server that published its own
			# packs had to spell out a path that was true on one box, and every version
			# bump meant editing it again in a file that is otherwise pure description.
			#
			# Set it when the content lives somewhere this server has no base for. Leave
			# it out and `./server pack <id>` is the whole of the setup.
			descriptor.manifest_url = String(TmcYaml.at(tree, "manifest_url", ""))
			descriptor.scene = scene
			descriptor.client_scene = client_scene

			if scene == "" and client_scene == "":
				return DotResult.fail(
					DotError.CODE_INVALID,
					"A pack game names no scene.",
					"set scene: to the server scene inside the pack, relative to its root"
				)

			if scene.contains("://") and descriptor.manifest_url == "":
				# An absolute scene in a pack game is the builtin spelling in the wrong
				# file: nothing would ever be fetched, and the game would silently run
				# out of the build while claiming to be delivered.
				return DotResult.fail(
					DotError.CODE_INVALID,
					"A pack game's scene must be relative to the pack root.",
					"got '%s' -- drop the res:// prefix, or use kind: builtin" % scene
				)
		_:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Unknown kind '%s'; expected builtin or pack." % kind
			)

	var cvars: Variant = TmcYaml.at(tree, "cvars", {})

	if cvars is Dictionary:
		descriptor.cvars = _flatten_cvars(cvars as Dictionary)

	# The module is named rather than derived from the id. A module is a script path and a
	# guessed one produces a load failure that reads as a missing game — and a game with no
	# server-side behaviour at all is legitimate, so "absent" has to be expressible.
	# [b]A pack game's module is inside the mount, and nothing was resolving it.[/b]
	# `TmcHost._on_game_loaded` hands this string straight to `load_module`, so a relative
	# path -- the only kind a pack can honestly write, because the version segment of the
	# mount prefix is not knowable when the file is authored -- was loaded as a path
	# relative to the project root and found nothing. The alternative an operator would
	# have reached for is worse: an absolute `res://dot_cloud/<id>/<version>/…` spelled out
	# in `game.yml` is a path that has to be edited by hand on every version bump, and a
	# stale one loads the PREVIOUS version's module against the new version's scene.
	#
	# Resolved the same way [method DotGameDescriptor._resolve] resolves the scene, and
	# against the same id and version, so the module and the scene cannot disagree about
	# which mount they are in.
	var module := String(TmcYaml.at(tree, "module", ""))

	if kind == "pack" and module != "" and not module.contains("://"):
		module = "res://dot_cloud/%s/%s/%s" % [
			descriptor.effective_content_id(),
			descriptor.version if descriptor.version != "" else "0.0.0",
			module,
		]

	descriptor.metadata = {
		"kind": kind,
		"module": module,
		"directory": "%s/%s" % [root, name],
	}

	var valid := descriptor.validate()

	if not valid.ok:
		return valid

	return DotResult.success(descriptor)


## A `cvars:` block with its list values joined, because a cvar's value is a string.
##
## [b]A console cvar is a line of text, and YAML is not.[/b] dot-server applies a
## descriptor's cvars by handing each value to the console, so an Array arrives through
## `str()` as `["surf_mesa", "surf_beginner2"]` — brackets, quotes and commas included —
## and the cvar is set to that, verbatim and wrong. Nothing errors: it is a valid string.
##
## Written as a list where a list is what it is:
##
## [codeblock]
## cvars:
##   sv_content_maps:
##     - surf_mesa
##     - surf_beginner2
## [/codeblock]
##
## Joined with spaces rather than commas because that is what a console line looks like,
## and every list-shaped cvar in this family splits on either. The cost is that an
## element containing a space cannot be expressed — which is equally true of typing the
## cvar at the console, so the YAML is not promising anything the console would keep.
func _flatten_cvars(cvars: Dictionary) -> Dictionary:
	var out := {}

	for name: Variant in cvars:
		var value: Variant = cvars[name]

		if value is Array:
			var parts := PackedStringArray()
			for item: Variant in (value as Array):
				parts.append(str(item))
			out[name] = " ".join(parts)
		else:
			out[name] = value

	return out


func find(game_id: String) -> DotGameDescriptor:
	for descriptor in games:
		if descriptor.game_id == game_id:
			return descriptor

	return null


func ids() -> PackedStringArray:
	var out := PackedStringArray()

	for descriptor in games:
		out.append(descriptor.game_id)

	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if games.is_empty():
		out.append("no games in %s" % root)

	for descriptor in games:
		out.append("%-14s %-24s %-8s %s%s" % [
			descriptor.game_id,
			descriptor.display_name,
			descriptor.version,
			str(descriptor.metadata.get("kind", "?")),
			"  (default)" if descriptor.game_id == default_game else "",
		])

	for entry in skipped:
		out.append("skipped %s" % entry)

	return out
