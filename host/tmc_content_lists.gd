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
## [/codeblock]
##
## Layers, weakest first: the shipped default (`content-lists/` in this project), the operator's
## `<cfg>/content/<file>`, then `<cfg>/server/content/<file>`. A list is replaced by the strongest layer
## that does not say `merge: true`, so an operator who wants exactly three games writes three. Packs are
## still verified by dot-cloud's signature check; this only says what to fetch.

const CHANNEL := "tmc.content_lists"
const DEFAULT_DIR := "res://content-lists"
const KINDS := ["addons", "games"]

const _ID_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
const _PIN_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"


## Value: an Array of {kind: "repo"|"pack", id, pin, content}, in list order. Fails with CODE_PARSE for
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
			if not ["repo", "pack", "pin", "content"].has(String(key)):
				return DotResult.fail(DotError.CODE_INVALID, "unknown key '%s'" % key)
		repo = String(d.get("repo", ""))
		pack = String(d.get("pack", ""))
		pin = String(d.get("pin", ""))
		content = String(d.get("content", ""))
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
	return DotResult.success({"kind": "repo" if repo != "" else "pack", "id": id, "pin": pin, "content": content})


static func _all_in(text: String, allowed: String) -> bool:
	for c in text:
		if not allowed.contains(c):
			return false
	return true
