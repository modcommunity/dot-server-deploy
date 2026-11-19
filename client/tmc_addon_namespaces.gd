class_name TmcAddonNamespaces
extends RefCounted

## Whose packs may REPLACE this shell's own `addons/<dir>`: the `namespaces` list [DotCloudAddonSet] takes an overlay from. Shell-shared, so every shell build (web, desktop) and the server's addon announcement read one list. An entry ending in `/` is an owner, anything else one exact content id (the matching [DotCloudAddonSet] does). The defaults are first-party. An operator who exports THEIR OWN shell may add owners in `cfg/addons/namespaces.txt` (one per line, `#` comments), which the export presets already include. It is read from the shell build and never from a server: a server that could extend it could replace the player's code.

## The organisation's (both its ids), and the game addons published under their author (the weapons packs, natural-disasters).
## A shell carries none of those (it is dot-* addons only), so these are what it fetches them under when a server announces them.
## `modcommunity/` and `gamemann/arena-weapons` (fc-weapons' old id) stay for servers that still announce the old ids.
const DEFAULTS: PackedStringArray = ["gamespice-platform/", "modcommunity/", "gamemann/zee-dot-weapons", "gamemann/zed-dot-weapons", "gamemann/fc-weapons", "gamemann/arena-weapons", "gamemann/natural-disasters", "gamemann/dot-trail", "gamemann/dot-radio"]

## Old repository names a lock or content list may still use, to the current one (fc-weapons was arena-weapons).
const PUBLISHED_AS := {"arena-weapons": "fc-weapons"}

## The `dot-*` addons that are their author's, not the organisation's: published as `gamemann/<repo>` (the repository name, `dot-` kept), like the weapons packs.
const AUTHOR_DOT_ADDONS: PackedStringArray = ["dot-trail", "dot-radio"]

## Addon directories a repository has renamed, current to legacy. fc-weapons (Fatal Contact's weapons) holds `addons/fc_weapons`; its tags up to [constant LEGACY_LAST] hold the legacy `addons/arena_weapons`. The legacy name is used only where the ref holds it, and every use logs a deprecation warning naming that ref.
## A game naming one while its ref holds the other is an error, never an alias: `res://` paths name the directory.
## `tools/check-pinned.sh` reads the pinned ref's own tree, and `setup.sh` links what the checkout holds; move [constant LEGACY_LAST] only with the tag that first holds `addons/fc_weapons`.
const LEGACY_DIRS := {"fc_weapons": "arena_weapons"}

## The last version of each renamed repository whose tree still holds its legacy directory.
const LEGACY_LAST := {"fc-weapons": "1.4.51"}

## Each legacy use already warned about (`dir@ref`), so a server that announces every join warns once.
static var _warned := {}

## The organisation's packs: `dot-<name>` is published as `gamespice-platform/<name>`.
const ORG := "gamespice-platform"

## Its old owner. `modcommunity/dot-<name>` is a mirrored alias of the new id (website-city `RetiredPackId.mirror`), so it keeps every new version.
const OLD_ORG := "modcommunity"

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


## The repository an addon directory comes from, as setup.sh and addons.lock name it: underscores become dashes, bar the weapons packs
## (`fc_weapons` and its legacy `arena_weapons` are both fc-weapons).
static func lock_repo(dir: String) -> String:
	if dir == "zee_weapons":
		return "zee-dot-weapons"
	if dir == "zed_weapons":
		return "zed-dot-weapons"
	if dir == "fc_weapons" or is_legacy_dir(dir):
		return "fc-weapons"

	return dir.replace("_", "-")


## The addon directory a pack repository (as published or as the lock names it) installs to at [param version]: the inverse of [method lock_repo] and [constant PUBLISHED_AS], so `fc-weapons` is `fc_weapons` and `zee-dot-weapons` is `zee_weapons`. A version at or below the repository's [constant LEGACY_LAST] holds the legacy directory, which is returned with a warning naming the ref. No version means the current name.
static func dir_for(repo: String, version: String = "") -> String:
	var lock := str(PUBLISHED_AS.get(repo, repo))
	var dir := lock.replace("-", "_")

	if lock == "zee-dot-weapons":
		dir = "zee_weapons"
	elif lock == "zed-dot-weapons":
		dir = "zed_weapons"

	if LEGACY_DIRS.has(dir) and holds_legacy(lock, version):
		var legacy := str(LEGACY_DIRS[dir])
		warn_legacy(legacy, "%s@%s" % [repo, version])
		return legacy

	return dir


## Whether [param repo] at [param version] still holds its legacy directory (a renamed repository, at or below [constant LEGACY_LAST]).
static func holds_legacy(repo: String, version: String) -> bool:
	var last := str(LEGACY_LAST.get(str(PUBLISHED_AS.get(repo, repo)), ""))
	return last != "" and version != "" and DotCloudAddonSet.compare_versions(version.trim_prefix("v"), last) <= 0


## [param announced] without a legacy directory its announced version no longer holds. A server-deploy older than
## the host's own skip announces a stale `arena_weapons` left by an older install as `fc-weapons@1.4.52+`, which holds
## only `addons/fc_weapons`: the all-or-nothing overlay then fails ("not an addon pack") and the game is refused.
static func without_stale_legacy(announced: Array) -> Array:
	var out: Array = []

	for raw: Variant in announced:
		if raw is Dictionary:
			var dir := str((raw as Dictionary).get("dir", ""))
			var version := str((raw as Dictionary).get("version", ""))

			if is_legacy_dir(dir) and not holds_legacy(lock_repo(dir), version):
				DotLog.warn("tmc.addons", "the server announced a stale legacy directory; not taken", {
					"dir": dir, "version": version, "holds": dir_for(lock_repo(dir)),
				})
				continue

		out.append(raw)

	return out


## Whether [param dir] is a renamed repository's legacy directory (`arena_weapons`).
static func is_legacy_dir(dir: String) -> bool:
	return LEGACY_DIRS.values().has(dir)


## The deprecation warning for a legacy directory in use at [param ref] (`repo@version`), once per pair.
static func warn_legacy(dir: String, ref: String) -> void:
	var key := "%s@%s" % [dir, ref]

	if _warned.has(key):
		return

	_warned[key] = true
	var current := str(LEGACY_DIRS.find_key(dir))
	DotLog.warn("tmc.addons", "addons/%s is a legacy directory (deprecated): %s still holds it; a newer tag holds addons/%s" % [dir, ref, current],
		{"dir": dir, "ref": ref, "current": current})


## The pack [param dir]'s code is published as: `{repo, id, old_repo, old_id}`, where `repo` is the id's name ([DotCloudAddonSet] refuses any other).
## `dot-*` packs are the organisation's (`gamespice-platform/<name>`, with the `modcommunity/dot-<name>` alias as `old_*`), the game addons their author's (no alias).
static func pack_for(dir: String) -> Dictionary:
	var lock := lock_repo(dir)
	var repo := str(PUBLISHED_AS.get(lock, lock))

	if repo.begins_with("dot-") and not AUTHOR_DOT_ADDONS.has(repo):
		var name := repo.trim_prefix("dot-")
		return {"repo": name, "id": "%s/%s" % [ORG, name], "old_repo": repo, "old_id": "%s/%s" % [OLD_ORG, repo]}

	return {"repo": repo, "id": "gamemann/%s" % repo, "old_repo": "", "old_id": ""}


## The `{repo, id}` a server announces for [param dir]: the old id while it has one. Every shell exported so far takes only `modcommunity/`, and
## [DotCloudAddonSet] compares the version by `repo` against the shell's lock, which names `dot-<name>`; the alias receives every new version.
static func announced_pack_for(dir: String) -> Dictionary:
	var pack := pack_for(dir)

	if str(pack["old_id"]) != "":
		return {"repo": pack["old_repo"], "id": pack["old_id"]}

	return {"repo": pack["repo"], "id": pack["id"]}


## The addon directory a content id installs to: `gamespice-platform/<name>` is `dot_<name>`, anything else [method dir_for] of its name
## (at [param version], which decides a renamed repository's directory).
static func dir_for_id(id: String, version: String = "") -> String:
	if id.begins_with(ORG + "/"):
		return "dot_" + id.get_file().replace("-", "_")

	return dir_for(id.get_file(), version)


## Whether [param id] (`owner/repo`) falls under [param namespaces], as [DotCloudAddonSet] decides.
static func covers(namespaces: PackedStringArray, id: String) -> bool:
	for entry in namespaces:
		if (entry.ends_with("/") and id.begins_with(entry)) or id == entry:
			return true

	return false
