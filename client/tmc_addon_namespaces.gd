class_name TmcAddonNamespaces
extends RefCounted

## Whose packs may REPLACE this shell's own `addons/<dir>`: the `namespaces` list [DotCloudAddonSet] takes an overlay from.
## Shell-shared, so every shell build (web, desktop) and the server's addon announcement read one list.
##
## An entry ending in `/` is an owner, anything else one exact content id (the matching [DotCloudAddonSet] does).
## The defaults are first-party. An operator who exports THEIR OWN shell may add owners in
## `cfg/addons/namespaces.txt` (one per line, `#` comments), which the export presets already include.
## It is read from the shell build and never from a server: a server that could extend it could replace the player's code.

## The organisation's, and the one addon that is not theirs (the weapons pack, published under its author).
const DEFAULTS: PackedStringArray = ["modcommunity/", "gamemann/zee-dot-weapons", "gamemann/arena-weapons"]

## Where an operator's additions live in the shell build.
const FILE := "res://cfg/addons/namespaces.txt"


## Defaults plus the operator's additions, with anything malformed dropped (listed in [param rejected] when given).
static func resolve(extra: PackedStringArray, rejected: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out := PackedStringArray(DEFAULTS)

	for raw in extra:
		var entry := raw.strip_edges()

		if not is_valid(entry):
			rejected.append(raw)
			continue

		if not out.has(entry):
			out.append(entry)

	return out


## `owner/` or `owner/repo`: lowercase-ish id characters only, so no wildcard, no empty owner, no path tricks.
static func is_valid(entry: String) -> bool:
	if entry.is_empty() or entry.contains("..") or entry.contains(" "):
		return false

	var parts := entry.split("/")

	if parts.size() != 2:
		return false

	for part in parts:
		for i in part.length():
			var c := part.unicode_at(i)
			var ok := (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 45 or c == 95 or c == 46

			if not ok:
				return false

	# `owner/` is an owner; `/x` and `/` are not.
	return not parts[0].is_empty()


## One entry per line, `#` starts a comment.
static func parse_lines(text: String) -> PackedStringArray:
	var out := PackedStringArray()

	for raw in text.split("\n"):
		var line := raw.get_slice("#", 0).strip_edges()

		if line != "":
			out.append(line)

	return out


## The list this shell uses: [constant DEFAULTS] plus [constant FILE] when the build has it.
static func load_shell() -> PackedStringArray:
	var extra := PackedStringArray()

	if FileAccess.file_exists(FILE):
		extra = parse_lines(FileAccess.get_file_as_string(FILE))

	var rejected := PackedStringArray()
	var out := resolve(extra, rejected)

	if not rejected.is_empty():
		DotLog.warn("tmc.shell", "addon namespaces ignored (not owner/ or owner/repo)", {"entries": rejected})

	return out


## Whether [param id] (`owner/repo`) falls under [param namespaces], as [DotCloudAddonSet] decides.
static func covers(namespaces: PackedStringArray, id: String) -> bool:
	for entry in namespaces:
		if (entry.ends_with("/") and id.begins_with(entry)) or id == entry:
			return true

	return false
