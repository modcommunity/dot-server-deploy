class_name TmcAddonSet
extends RefCounted

## The addon versions a server announces to joining clients: built from the lock, server.yml's `addons:` list and the owner's overlays.
## Pure functions, so the selftest drives them without a host.


## [param entries] with a `groups` list on each entry whose dir [param groups] names: the download groups (dot-cloud's `groups.json`) a client
## needs of that pack for this game. An entry the game does not name gets no field, which a client reads as everything.
static func with_groups(entries: Array, groups: Dictionary) -> Array:
	var out: Array = []

	for entry: Dictionary in entries:
		var copy := entry.duplicate(true)
		var dir := str(copy.get("dir", ""))

		if groups.has(dir):
			copy["groups"] = (groups[dir] as Array).duplicate()

		out.append(copy)

	return out


## The module's `addon_groups()` as `{dir: [group, ...]}` of strings, or nothing. Duck-typed, because a game's module is not this shell's class;
## anything malformed for a dir drops that dir (its clients then take the whole pack) rather than the game.
static func sanitize_groups(raw: Variant) -> Dictionary:
	var out := {}

	if not (raw is Dictionary):
		return out

	for key: Variant in raw:
		var value: Variant = raw[key]

		if not (key is String or key is StringName) or not (value is Array or value is PackedStringArray):
			continue

		var names: Array = []
		var ok := true

		for group: Variant in value:
			if not (group is String or group is StringName) or str(group) == "":
				ok = false
				break

			names.append(str(group))

		if ok and not names.is_empty():
			out[str(key)] = names

	return out


## The announcement for server.yml's `addons:` entries: `{entries: [{dir, repo, id, version}], errors: [String]}`. An id nothing on this box can install (unknown owner,
## no version, a directory that is not under addons/) is an error line each, never silently dropped and never guessed at.
static func addons_from_list(listed: PackedStringArray, namespaces: PackedStringArray, lock_text: String, dirs: PackedStringArray) -> Dictionary:
	var versions := {}

	for raw in lock_text.split("\n"):
		var parts := raw.strip_edges().split("\t", false)

		if parts.size() >= 2 and not parts[0].begins_with("#"):
			versions[parts[0]] = parts[1]

	var entries: Array = []
	var errors := PackedStringArray()

	for text in listed:
		var one := TmcAddonsConfig.addon_ref(text, namespaces, versions)

		if not one.ok:
			errors.append("%s (%s)" % [one.error.message, str(one.error.detail)])
		elif not dirs.has(str((one.value as Dictionary)["dir"])):
			errors.append("%s: addons/%s is not installed; run ./setup.sh" % [text, (one.value as Dictionary)["dir"]])
		else:
			entries.append(one.value)

	return {"entries": entries, "errors": errors}


## [param base] with [param extra] laid over it by `dir`.
static func merge_overlays(base: Array, extra: Array) -> Array:
	var out: Array = []

	for entry: Dictionary in base:
		var replaced := false

		for over: Dictionary in extra:
			if over["dir"] == entry["dir"]:
				replaced = true

		if not replaced:
			out.append(entry)

	out.append_array(extra)
	return out


## One `{dir, repo, id, version}` per installed addon the lock names. A game addon's pack (fc-weapons, the zee/zed weapons) carries its code at
## `addons/<dir>/`, which [DotCloudAddonSet] (dot-cloud 0.1.46+) overlays like a dot-* pack, so every one is announced.
static func addon_set_from(lock_text: String, dirs: PackedStringArray) -> Array:
	var versions := {}

	for raw in lock_text.split("\n"):
		var line := raw.strip_edges()

		if line == "" or line.begins_with("#"):
			continue

		var parts := line.split("\t", false)

		if parts.size() >= 2:
			versions[parts[0].strip_edges()] = parts[1].strip_edges().trim_prefix("v")

	var out: Array = []

	for dir in dirs:
		if dir.begins_with("."):
			continue

		var repo := addon_repo(dir)

		# An older lock may still name a renamed repository by its old name (fc-weapons was arena-weapons).
		for old: String in TmcAddonNamespaces.PUBLISHED_AS:
			if TmcAddonNamespaces.PUBLISHED_AS[old] == repo and not versions.has(repo) and versions.has(old):
				repo = old

		if not versions.has(repo):
			continue

		# The directory is what the installed ref holds; the legacy one (arena_weapons) is announced as it is, and said so.
		if TmcAddonNamespaces.is_legacy_dir(dir):
			TmcAddonNamespaces.warn_legacy(dir, "%s@%s" % [repo, versions[repo]])

		var pack := TmcAddonNamespaces.announced_pack_for(dir)

		out.append({
			"dir": dir,
			"repo": pack["repo"],
			"id": pack["id"],
			"version": versions[repo],
		})

	return out


## The repository an addon directory comes from. setup.sh's `addon_repo`, and the two
## must agree: one exception, and otherwise underscores become dashes.
static func addon_repo(dir: String) -> String:
	return TmcAddonNamespaces.lock_repo(dir)


## Whose namespace a repository's packs are published under. setup.sh's `repo_url`: the
## `dot-*` addons are the organisation's, everything else (the weapons pack) Christian's.
static func content_owner(repo: String) -> String:
	return TmcAddonNamespaces.ORG if repo.begins_with("dot-") and not TmcAddonNamespaces.AUTHOR_DOT_ADDONS.has(repo) else "gamemann"


## `{content id: version}` as compact JSON, from the announced addon set (`addon_set_from` entries) and the mounted packs. Empty string when nothing is pinned.
## A mounted pack wins over the addon entry for the same id: it is what is actually loaded. Keys are sorted, so the value only changes when a version does.
static func pack_pins_json(addon_set: Array, mounted: Dictionary) -> String:
	var pins := {}

	for entry in addon_set:
		var id := str(entry.get("id", ""))
		var version := str(entry.get("version", ""))

		if id != "" and version != "":
			pins[id] = version

			# Both trees hold the version, and the sweep must spare it in whichever one a client fetches.
			var pack := TmcAddonNamespaces.pack_for(str(entry.get("dir", "")))

			if id == str(pack["old_id"]):
				pins[str(pack["id"])] = version

	for id in mounted:
		var version := str(mounted[id])

		if str(id) != "" and version != "":
			pins[str(id)] = version

	if pins.is_empty():
		return ""

	return JSON.stringify(pins, "", true)
