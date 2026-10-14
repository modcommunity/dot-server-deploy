class_name TmcSolo
extends RefCounted

## Solo play: a delivered game run entirely in this process, with no server and no link.
##
## [b]Why the shell can do this at all.[/b] Every game's client scene already has an
## offline mode: it looks for a client link in [DotRegistry], finds none, and simulates its
## own rules in-process (bots, map changes, its console, everything a `godot --path .` run
## of the repository has). The only thing a delivered copy lacks is somebody to fetch and
## mount it, and a join is what normally does that. So solo is a join with the server taken
## out: fetch, verify and mount the pack exactly as [DotClientLink] does for a server (by id
## and version, signed, through the same [DotCloudClient]), then instantiate the game's
## `client_scene` out of the mount and register no link.
##
## [b]What names the game.[/b] `--solo <owner>/<repo>` on the command line, or `?solo=` in
## the page's query string (the site's direct Play, through the loader and `embed.html`).
## The version is `--solo-version` / `?solo_version=`, and empty means the newest published
## one, read from `latest.json` beside the versions -- the pointer a publish writes, which
## the server's installer reads the same way.
##
## [b]Nothing here is trusted because the page said it.[/b] The id picks which signed pack
## to ask for; the manifest still has to verify against a key built into this export, and
## its own id and version have to match what was asked for, or [method DotCloudClient.ensure]
## refuses it. A crafted link can start a different published game and nothing else.
##
## [b]The map packs.[/b] A server names its games' map packs in its own configuration
## (`cfg/content.yml`), which a tab with no server does not have. `client/solo.json` is the
## shell's copy of the stock list (`cfg.example/content.yml`), and `tools/check.sh` fails
## when the two drift. Each pack in it is fetched and mounted before the game starts, and
## its roots are published in [DotRegistry] under [constant MAPS_SERVICE] for a game whose
## offline catalogue reads delivered maps.

const CHANNEL := "tmc.solo"

## Where the shell publishes the solo session: the map roots it mounted and the way back to
## the menu. A game looks it up by this name, duck-typed; nothing in a pack may name a
## shell class.
const MAPS_SERVICE := &"dot_solo"

## The shell's copy of the stock per-game map packs. See the class description.
const SOLO_CONFIG := "res://client/solo.json"

## The pointer a publish writes beside a pack's versions.
const LATEST_FILE := "latest.json"

## `<owner>/<name>`, each a slug. The same shape `DotCloudManifest.validate_shape()` and the
## site's `BuildPackId` require; anything else is not a pack id and is refused before a
## request is made for it.
const ID_PATTERN := "^[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_-]{0,63}$"

## A version is one path component in a mount path.
const VERSION_PATTERN := "^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$"


## Whether [param id] is a pack id this shell will ask for.
static func valid_id(id: String) -> bool:
	var re := RegEx.new()
	re.compile(ID_PATTERN)
	return re.search(id) != null


## Whether [param version] can be a pack version. Empty is allowed: it means the newest.
static func valid_version(version: String) -> bool:
	if version == "":
		return true
	if version.contains(".."):
		return false
	var re := RegEx.new()
	re.compile(VERSION_PATTERN)
	return re.search(version) != null


## The solo request, `{"id", "version"}`, or an empty id when none was made.
##
## The command line first (a desktop launch, a suite), then the page's query string. The
## page goes through `embed.html`, which forwards `?solo=` as `--solo`, so the query string
## here is the belt-and-braces for a host that serves the export without that page -- the
## same pair `--connect` and `?server=` are.
static func requested() -> Dictionary:
	var args := OS.get_cmdline_user_args()
	var id := _arg(args, "--solo")
	var version := _arg(args, "--solo-version")

	if id == "" and DotPlatform.is_web():
		id = DotWeb.query_param("solo")
		version = DotWeb.query_param("solo_version")

	id = id.strip_edges().to_lower()
	version = version.strip_edges()

	if id == "":
		return {"id": "", "version": ""}

	if not valid_id(id) or not valid_version(version):
		DotLog.warn(CHANNEL, "refusing a solo request that is not a pack id", {
			"id": id, "version": version,
		})
		return {"id": "", "version": "", "refused": id}

	return {"id": id, "version": version}


static func _arg(args: PackedStringArray, name: String) -> String:
	for i in args.size():
		if args[i] == name and i + 1 < args.size():
			return args[i + 1]
		if args[i].begins_with(name + "="):
			return args[i].substr(name.length() + 1)
	return ""


## The newest published version of [param id], from `latest.json` under each base in turn.
static func resolve_latest(host: Node, id: String, bases: PackedStringArray) -> DotResult:
	var http := DotHttp.new()
	http.name = "SoloLatest"
	host.add_child(http)

	var last := "no content address is configured"

	for base in bases:
		var url := "%s/%s/%s" % [DotCloudClient.resolve_base_url(base).rstrip("/"), id, LATEST_FILE]
		var res: DotResult = await http.get_json(url)

		if not res.ok:
			last = "%s: %s" % [url, str(res.error)]
			continue

		var body: Variant = res.value
		var version := str((body as Dictionary).get("version", "")) if body is Dictionary else ""

		if version != "" and valid_version(version):
			http.queue_free()
			return DotResult.success(version)

		last = "%s named no version" % url

	http.queue_free()

	return DotResult.fail(
		DotError.CODE_IO,
		"%s has no published version." % id,
		last
	)


## The fields of a pack's `game.yml` that solo needs, read out of the mount.
##
## [b]A reader for the subset, not a YAML parser.[/b] `host/` (and [TmcYaml]) are not in the
## client build, and the descriptor fields read here are flat: scalars and lists of
## scalars at the top level. Nested blocks (`cvars:`, `metadata:`) are skipped whole.
## `examples/solo_check.gd` reads every game's `game.yml` through both this and [TmcYaml]
## and fails when they disagree about any field here.
static func read_descriptor(mount: String) -> DotResult:
	var path := mount.path_join("game.yml")

	if not FileAccess.file_exists(path):
		return DotResult.fail(
			DotError.CODE_IO,
			"This pack has no game.yml, so it is not a game that can be played solo.",
			path
		)

	return DotResult.success(parse_descriptor(FileAccess.get_file_as_string(path)))


## The flat fields of a `game.yml` text: `client_scene`, `name`, `content_id`, `version`,
## and the `dependencies` and `server_dependencies` lists.
static func parse_descriptor(text: String) -> Dictionary:
	var out := {
		"name": "", "content_id": "", "version": "", "client_scene": "",
		"dependencies": PackedStringArray(), "server_dependencies": PackedStringArray(),
	}
	var list_key := ""

	for raw in text.split("\n"):
		var line := _strip_comment(raw).rstrip(" \t\r")

		if line.strip_edges() == "":
			continue

		var indented := line.begins_with(" ") or line.begins_with("\t")

		if indented:
			var item := line.strip_edges()
			if list_key != "" and item.begins_with("- "):
				# Reassigned, not appended in place: a PackedStringArray read out of a
				# Dictionary is a copy, and appending to the copy changes nothing.
				var grown: PackedStringArray = out[list_key]
				grown.append(_unquote(item.substr(2).strip_edges()))
				out[list_key] = grown
			continue

		list_key = ""
		var colon := line.find(":")
		if colon <= 0:
			continue

		var key := line.substr(0, colon).strip_edges()
		var value := line.substr(colon + 1).strip_edges()

		if not out.has(key):
			continue

		if out[key] is PackedStringArray:
			if value == "":
				list_key = key
			elif value.begins_with("[") and value.ends_with("]"):
				var inline := PackedStringArray()
				for part in value.substr(1, value.length() - 2).split(",", false):
					var one := _unquote(part.strip_edges())
					if one != "":
						inline.append(one)
				out[key] = inline
			continue

		out[key] = _unquote(value)

	return out


static func _strip_comment(line: String) -> String:
	var quote := ""
	for i in line.length():
		var c := line[i]
		if quote != "":
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == "#" and (i == 0 or line[i - 1] == " " or line[i - 1] == "\t"):
			return line.substr(0, i)
	return line


static func _unquote(value: String) -> String:
	if value.length() >= 2 and (
		(value.begins_with("\"") and value.ends_with("\""))
		or (value.begins_with("'") and value.ends_with("'"))
	):
		return value.substr(1, value.length() - 2)
	return value


## The stock map packs for [param content_id] from `client/solo.json`: pack ids, each with
## an optional `@version` (none means the newest).
static func map_packs(content_id: String) -> PackedStringArray:
	var out := PackedStringArray()

	if not FileAccess.file_exists(SOLO_CONFIG):
		return out

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SOLO_CONFIG))
	if not (parsed is Dictionary):
		return out

	var games: Variant = (parsed as Dictionary).get("maps", {})
	if not (games is Dictionary):
		return out

	var list: Variant = (games as Dictionary).get(content_id, [])
	if list is Array:
		for one in list:
			var key := str(one).strip_edges()
			if key != "":
				out.append(key)

	return out


## `<id>@<version>` split, version "" when there is none.
static func split_key(key: String) -> Dictionary:
	var at := key.rfind("@")
	if at > 0:
		return {"id": key.substr(0, at), "version": key.substr(at + 1)}
	return {"id": key, "version": ""}
