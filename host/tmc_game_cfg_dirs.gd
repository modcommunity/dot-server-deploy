class_name TmcGameCfgDirs
extends RefCounted

## The directories under `cfg/game/` and `cfg/server/game/`: moving the ones a renamed game left behind, and writing the base file a game starts with. The settings themselves are read by [TmcGameConfig].

## Directory names under `cfg/game/` and `cfg/server/game/` a game was configured under before it was renamed, and the name it has now. [method migrate_retired_dirs] moves them on boot, and `tools/cfg_sync.sh` does the same before the first boot of an update (the selftest checks that the two lists agree). Exact directory names, no owner.
const RETIRED_DIRS := {
	"game-arena": "game-fatal-contact",
	"game-final-contact": "game-fatal-contact",
	"arena": "game-fatal-contact",
	# legacy id: the names these games had before the rename; a directory under one is moved.
	"game-g2gfast": "game-airdrift",
	"game-g2gfast01": "game-airdrift",
	"g2gfast": "game-airdrift",
	"game-playground": "game-playlot",
	"playground": "game-playlot",
}


## Moves a directory kept under a retired game name (see [constant RETIRED_DIRS]) to the current name, in both tiers (`cfg/game/` and `cfg/server/game/`), without losing a file: a directory with no successor is renamed, and into one that exists only the files it lacks are moved. A file in both that differs is kept as `<file>.from-<old name>` beside the current one (never read, never deleted) and named in the line returned; an identical one is dropped. Returns one line per directory handled; nothing to do returns nothing.
static func migrate_retired_dirs(config_dir: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var base := config_dir.rstrip("/")

	for tier in ["game", "server/game"]:
		for old: String in RETIRED_DIRS:
			var from := "%s/%s/%s" % [base, tier, old]

			if not DirAccess.dir_exists_absolute(from):
				continue

			var into := "%s/%s/%s" % [base, tier, RETIRED_DIRS[old]]
			var kept := PackedStringArray()

			if not DirAccess.dir_exists_absolute(into):
				var moved := DirAccess.rename_absolute(from, into)

				if moved == OK:
					lines.append("cfg/%s/%s is now cfg/%s/%s (the game's id changed); nothing was lost" % [tier, old, tier, RETIRED_DIRS[old]])
				else:
					lines.append("cfg/%s/%s could not be moved to cfg/%s/%s (error %d); it is still read" % [tier, old, tier, RETIRED_DIRS[old], moved])

				continue

			_merge_dir(from, into, old, kept)

			DirAccess.remove_absolute(from)
			lines.append("cfg/%s/%s merged into cfg/%s/%s%s" % [
				tier, old, tier, RETIRED_DIRS[old],
				"" if kept.is_empty() else "; differing files kept as " + ", ".join(kept),
			])

	return lines


static func _merge_dir(from: String, into: String, old: String, kept: PackedStringArray) -> void:
	for sub in DirAccess.get_directories_at(from):
		if not DirAccess.dir_exists_absolute("%s/%s" % [into, sub]):
			DirAccess.rename_absolute("%s/%s" % [from, sub], "%s/%s" % [into, sub])
		else:
			_merge_dir("%s/%s" % [from, sub], "%s/%s" % [into, sub], old, kept)
			DirAccess.remove_absolute("%s/%s" % [from, sub])

	for file in DirAccess.get_files_at(from):
		var source := "%s/%s" % [from, file]
		var target := "%s/%s" % [into, file]

		if not FileAccess.file_exists(target):
			DirAccess.rename_absolute(source, target)
		elif FileAccess.get_file_as_bytes(source) == FileAccess.get_file_as_bytes(target):
			DirAccess.remove_absolute(source)
		else:
			var aside := "%s.from-%s" % [target, old]
			DirAccess.rename_absolute(source, aside)
			kept.append("%s.from-%s" % [file, old])


## Writes a commented `cfg/game/<game>/server.yml` for every game in [param content] that has no file for the game in either tier, from what the game declares in its own `game.yml` (name, player count, cvars with the comment above each, the maps it offers), so the folder an owner looks in is never empty. Every setting line is commented out: the file is documentation, and a default the game later changes is not held at the old value. An existing file is left alone. Returns the paths written (relative to [param config_dir]); a directory that cannot be written is a warning, not an error, because a read-only cfg/ is a legitimate way to run.
static func write_base_configs(config_dir: String, content: TmcContent) -> PackedStringArray:
	var written := PackedStringArray()
	var base := config_dir.rstrip("/")

	for descriptor in content.games:
		var name := TmcGameConfig.cfg_id(descriptor)

		if name == "" or name.contains(".."):
			continue

		var present := false

		for spelling in TmcGameConfig.spellings(descriptor):
			var dirname := TmcGameConfig.name_half(str(spelling))

			for root in ["%s/game" % base, "%s/server/game" % base]:
				if FileAccess.file_exists("%s/%s/%s" % [root, dirname, TmcGameConfig.GAME_FILE]):
					present = true

		if present:
			continue

		var dir := "%s/game/%s" % [base, name]

		if DirAccess.make_dir_recursive_absolute(dir) != OK:
			DotLog.warn(TmcGameConfig.CHANNEL, "cfg/game/%s could not be created; no base config written" % name)
			continue

		var file := FileAccess.open("%s/%s" % [dir, TmcGameConfig.GAME_FILE], FileAccess.WRITE)

		if file == null:
			DotLog.warn(TmcGameConfig.CHANNEL, "cfg/game/%s/%s could not be written; no base config written" % [name, TmcGameConfig.GAME_FILE])
			continue

		file.store_string(base_config_text(descriptor, content.root))
		file.close()
		written.append("game/%s/%s" % [name, TmcGameConfig.GAME_FILE])

	return written


## The text [method write_base_configs] writes for one game; a game's `game.yml` is read from
## `<content_root>/<id>/game.yml` for the comment above each cvar.
static func base_config_text(descriptor: DotGameDescriptor, content_root: String) -> String:
	var notes := _cvar_notes("%s/%s/game.yml" % [content_root.rstrip("/"), descriptor.game_id])
	var out := PackedStringArray()
	out.append("# %s: this server's settings for this game (cfg/game/%s/server.yml)." % [descriptor.display_name, TmcGameConfig.cfg_id(descriptor)])
	out.append("# Written once, on first boot, from the game's own defaults; it is never overwritten. Every line below is")
	out.append("# commented out, so the game's defaults apply until you uncomment one. Remove the # and change the value")
	out.append("# to set it. An update refreshes only files it ships; put changes you want kept in cfg/server/game/%s/server.yml." % TmcGameConfig.cfg_id(descriptor))
	out.append("# Keys: name, max_players (sv_name and sv_maxplayers also work), cvars, metadata, maps, map_owner, suggested_maps.")
	out.append("")
	out.append("# name: \"%s\"" % descriptor.display_name.replace("\"", "'"))
	out.append("# max_players: %d" % descriptor.max_players)
	out.append("")

	if descriptor.cvars.is_empty():
		out.append("# cvars: {}   # this game declares none; any console variable can be set here")
	else:
		out.append("# cvars:")
		var names := descriptor.cvars.keys()
		names.sort()

		for key: String in names:
			var note := str(notes.get(key, ""))

			if note != "":
				out.append("#   # %s" % note)

			out.append("#   %s: %s" % [key, _yaml_scalar(descriptor.cvars[key])])

	out.append("")
	out.append("# Maps: add published map packs (one gamemann/<map id> each), remove ones the game ships, or set")
	out.append("# game_maps: false to drop the game's own list.")
	out.append("# maps:")
	out.append("#   add: []")
	out.append("#   remove: []")
	return "\n".join(out) + "\n"


static func _yaml_scalar(value: Variant) -> String:
	var text := str(value)
	var plain := (text != "" and text.is_valid_float()) or text in ["true", "false"]
	return text if plain else "\"%s\"" % text.replace("\\", "\\\\").replace("\"", "\\\"")


## `cvar -> first line of the comment directly above it` in a game.yml's `cvars:` block.
static func _cvar_notes(path: String) -> Dictionary:
	var notes := {}

	if not FileAccess.file_exists(path):
		return notes

	var in_block := false
	var pending := ""

	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw.strip_edges(false, true)

		if line.begins_with("cvars:"):
			in_block = true
			pending = ""
			continue

		if not in_block:
			continue

		if line != "" and not line.begins_with(" ") and not line.begins_with("#"):
			break

		var trimmed := line.strip_edges()

		if trimmed.begins_with("#"):
			pending = trimmed.trim_prefix("#").strip_edges() if pending == "" else pending
			continue

		if trimmed == "":
			pending = ""
			continue

		var key := trimmed.get_slice(":", 0).strip_edges().trim_prefix("\"").trim_suffix("\"")

		if pending != "" and not notes.has(key):
			notes[key] = pending

		pending = ""

	return notes
