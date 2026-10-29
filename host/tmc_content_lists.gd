class_name TmcContentLists
extends RefCounted

## The download lists a server operator owns: `addons.yml` (repositories) and `games.yml` (games and packs).
##
## [codeblock]
## merge: true            # absent or false: this file REPLACES the list below it
## remove: [dot-voice]    # ids dropped after the lists below are merged in
## entries:
##   - dot-core                      # a git repository, shorthand
##   - dot-vote@v0.2.1               # pinned to a tag or commit
##   - repo: game-arena              # long form
##     pin: v1.0.0
##     content: arena                # games.yml only: the content directory
##   - pack: gamemann/surf_mesa      # a dot-cloud pack id; `@1.2.0` or `pin:` pins it
##   - repo: game-arena              # games.yml only, both optional:
##     maps: [dm_one, dm_two]        #   the maps to rotate, in this order (absent: every installed map, sorted)
##     rotation: random              #   sequential (default), random or vote
## [/codeblock]
##
## Layers, weakest first: the shipped default (`content-lists/` in this project), the operator's
## `<cfg>/content/<file>`, then `<cfg>/server/content/<file>`. A list is replaced by the strongest layer
## that does not say `merge: true`, so an operator who wants exactly three games writes three. Packs are
## still verified by dot-cloud's signature check; this only says what to fetch.

const DEFAULT_DIR := "res://content-lists"
const KINDS := ["addons", "games"]

const ROTATIONS := ["sequential", "random", "vote"]

const _ID_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
const _PIN_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"


## Value: an Array of {kind: "repo"|"pack", id, pin, content, maps, rotation}, in list order (`maps` is a
## PackedStringArray, `rotation` "" when the entry does not say). Fails with CODE_PARSE for
## a file that is not yml and CODE_INVALID naming the file and entry for a bad one.
static func load_list(kind: String, config_dir: String, default_dir: String = DEFAULT_DIR) -> DotResult:
	if not KINDS.has(kind):
		return DotResult.fail(DotError.CODE_INVALID, "Unknown content list '%s'." % kind)
	var file := kind + ".yml"
	var base := config_dir.rstrip("/")
	var paths: Array[String] = [default_dir.path_join(file), base + "/content/" + file, base + "/server/content/" + file]
	var docs: Array[Dictionary] = []
	for path in paths:
		if not FileAccess.file_exists(path):
			continue
		var parsed := TmcYaml.parse_file(path)
		if not parsed.ok:
			return parsed.wrap("Could not read %s" % path)
		if parsed.value == null:
			continue
		if not (parsed.value is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "%s must hold a mapping at the top level." % path)
		# A file with neither key is the rotation or pack settings that share its name, not a list.
		if not ((parsed.value as Dictionary).has("entries") or (parsed.value as Dictionary).has("remove")):
			continue
		var entries := _entries_of(parsed.value as Dictionary, kind, path)
		if not entries.ok:
			return entries
		docs.append({"path": path, "merge": (parsed.value as Dictionary).get("merge") == true,
			"remove": _ids(parsed.value.get("remove")), "entries": entries.value})
	var start := 0
	for i in range(docs.size() - 1, -1, -1):
		if not docs[i]["merge"]:
			start = i
			break
	var out: Array = []
	for i in range(start, docs.size()):
		var removed: PackedStringArray = docs[i]["remove"]
		out = out.filter(func(e: Dictionary) -> bool: return not removed.has(e["id"]))
		for e in docs[i]["entries"]:
			var at := _index_of(out, e["id"])
			if at >= 0:
				out[at] = e
			else:
				out.append(e)
	return DotResult.success(out)


## The pin of [param id] in [param entries], or "" when it is unpinned or absent.
static func pin_for(entries: Array, id: String) -> String:
	var at := _index_of(entries, id)
	return String(entries[at]["pin"]) if at >= 0 else ""


## The order games rotate in: the games.yml entries that are in [param installed] (by content directory, else
## id), in list order, then any installed game the list does not name, sorted. One game is a list of one, so
## the caller does no game rotation. Fails with CODE_NOT_FOUND-style CODE_INVALID naming an id in
## [param wanted] (an explicit order an operator wrote elsewhere) that is neither listed nor installed.
static func game_order(entries: Array, installed: PackedStringArray, wanted: PackedStringArray = PackedStringArray()) -> DotResult:
	var known := PackedStringArray()
	for e: Dictionary in entries:
		known.append(_game_id(e))
	for id in wanted:
		if not known.has(id) and not installed.has(id):
			return DotResult.fail(DotError.CODE_INVALID, "Unknown game '%s': not in games.yml (%s) and not installed (%s)." % [id, ", ".join(known), ", ".join(installed)])
	var out := PackedStringArray()
	var order: PackedStringArray = wanted if not wanted.is_empty() else known
	for id in order:
		if installed.has(id) and not out.has(id):
			out.append(id)
	var rest := PackedStringArray()
	for id in installed:
		if not out.has(id):
			rest.append(id)
	rest.sort()
	out.append_array(rest)
	return DotResult.success(out)


## The map rotation of one game: Value {maps: PackedStringArray, rotation: String}. The entry's `maps:` list
## is the order; absent means [param installed_maps] sorted. A map the entry names that is not installed, or a
## [param game_id] the list does not hold, fails with CODE_INVALID naming it and what is available.
static func map_rotation(entries: Array, game_id: String, installed_maps: PackedStringArray) -> DotResult:
	var maps := PackedStringArray(installed_maps)
	maps.sort()
	var mode := "sequential"
	var found := false
	for e: Dictionary in entries:
		if _game_id(e) != game_id and e["id"] != game_id:
			continue
		found = true
		var listed: PackedStringArray = e.get("maps", PackedStringArray())
		for m in listed:
			if not installed_maps.has(m):
				return DotResult.fail(DotError.CODE_INVALID, "games.yml: game '%s' lists map '%s', which is not installed (installed: %s)." % [game_id, m, ", ".join(maps)])
		if not listed.is_empty():
			maps = listed
		if String(e.get("rotation", "")) != "":
			mode = String(e["rotation"])
		break
	if not found:
		return DotResult.fail(DotError.CODE_INVALID, "Unknown game '%s': games.yml does not list it." % game_id)
	return DotResult.success({"maps": maps, "rotation": mode})


static func _game_id(e: Dictionary) -> String:
	return String(e["content"]) if String(e["content"]) != "" else String(e["id"])


static func _index_of(entries: Array, id: String) -> int:
	for i in entries.size():
		if entries[i]["id"] == id:
			return i
	return -1


static func _ids(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for v in value:
			out.append(String(v).split("@")[0])
	return out


static func _entries_of(doc: Dictionary, kind: String, path: String) -> DotResult:
	var raw: Variant = doc.get("entries", [])
	if raw == null:
		raw = []
	if not (raw is Array):
		return DotResult.fail(DotError.CODE_INVALID, "%s: entries must be a list." % path)
	var out: Array = []
	for i in (raw as Array).size():
		var built := _entry(raw[i], kind)
		if not built.ok:
			return built.wrap("%s entry %d" % [path, i + 1])
		out.append(built.value)
	return DotResult.success(out)


static func _entry(raw: Variant, kind: String) -> DotResult:
	var repo := ""
	var pack := ""
	var pin := ""
	var content := ""
	var maps := PackedStringArray()
	var rotation := ""
	if raw is String:
		var parts := (raw as String).split("@", true, 1)
		pin = parts[1] if parts.size() > 1 else ""
		if parts[0].contains("/"):
			pack = parts[0]
		else:
			repo = parts[0]
	elif raw is Dictionary:
		var d: Dictionary = raw
		for key in d:
			if not ["repo", "pack", "pin", "content", "maps", "rotation"].has(String(key)):
				return DotResult.fail(DotError.CODE_INVALID, "unknown key '%s'" % key)
		repo = String(d.get("repo", ""))
		pack = String(d.get("pack", ""))
		pin = String(d.get("pin", ""))
		content = String(d.get("content", ""))
		rotation = String(d.get("rotation", ""))
		if "maps" in d:
			if not (d["maps"] is Array):
				return DotResult.fail(DotError.CODE_INVALID, "maps: is a list of map ids")
			for m in d["maps"]:
				if String(m) == "" or not _all_in(String(m), _ID_CHARS):
					return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a map id" % m)
				maps.append(String(m))
		for part in ["repo", "pack"]:
			if String(d.get(part, "")).contains("@"):
				if pin != "":
					return DotResult.fail(DotError.CODE_INVALID, "give the version once, as pin: or after @")
				var split := String(d[part]).split("@", true, 1)
				pin = split[1]
				if part == "repo":
					repo = split[0]
				else:
					pack = split[0]
		if "pin" in d and not (d["pin"] is String or d["pin"] is int or d["pin"] is float):
			return DotResult.fail(DotError.CODE_INVALID, "pin must be text")
	else:
		return DotResult.fail(DotError.CODE_INVALID, "an entry is a name or a mapping")
	if (repo == "") == (pack == ""):
		return DotResult.fail(DotError.CODE_INVALID, "give exactly one of repo and pack")
	var id := repo if repo != "" else pack
	if not _all_in(id.replace("/", ""), _ID_CHARS) or id.begins_with("/") or id.ends_with("/") or id.contains("//") or id.contains(".."):
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a repository name or an owner/pack id" % id)
	if pack != "" and pack.count("/") != 1:
		return DotResult.fail(DotError.CODE_INVALID, "a pack id is owner/name, got '%s'" % pack)
	if repo != "" and repo.contains("/"):
		return DotResult.fail(DotError.CODE_INVALID, "a repository is a bare name, got '%s'" % repo)
	if pin != "" and not _all_in(pin, _PIN_CHARS):
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a version, tag or commit" % pin)
	if content != "" and (kind != "games" or repo == "" or not _all_in(content, _ID_CHARS)):
		return DotResult.fail(DotError.CODE_INVALID, "content: is a directory name, for a games.yml repository")
	if (not maps.is_empty() or rotation != "") and kind != "games":
		return DotResult.fail(DotError.CODE_INVALID, "maps: and rotation: belong in games.yml")
	if rotation != "" and not ROTATIONS.has(rotation):
		return DotResult.fail(DotError.CODE_INVALID, "rotation: is %s, got '%s'" % [" | ".join(ROTATIONS), rotation])
	return DotResult.success({"kind": "repo" if repo != "" else "pack", "id": id, "pin": pin, "content": content, "maps": maps, "rotation": rotation})


static func _all_in(text: String, allowed: String) -> bool:
	for c in text:
		if not allowed.contains(c):
			return false
	return true
