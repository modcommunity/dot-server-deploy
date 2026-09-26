extends SceneTree

## Publish the index a server installs games FROM.
##
## [codeblock]
## godot --headless --path . --script res://tools/index.gd -- \
##     --content content --out dist
## [/codeblock]
##
## Driven by `./server index`, which is the way to run it, and which every publish should
## end with — see the note on staleness below.
##
## [b]Why this exists at all: a pack does not contain the descriptor that boots it.[/b]
## `./server pack arena --source games/game-arena` publishes the GAME — 212 files of
## scenes, scripts and art, signed, content-addressed, mountable. What it does not publish
## is `content/arena/game.yml`, which is the file that says which scene the SERVER runs,
## which module drives it, how many players it takes and what its cvars are. The
## descriptor lives beside the pack in this repository and has never left it, so a server
## could download any game in the catalogue and still had no way to learn how to start
## one. Every deployment got the descriptors by cloning this repository, which means every
## deployment got all ten whether it ran one of them or ten.
##
## This writes the missing half:
##
## [codeblock]
## dist/games.json                        the catalogue: id -> content id, version, name
## dist/descriptors/<id>/game.yml         one copy of each descriptor, by id
## [/codeblock]
##
## Both land in `dist/`, which is what already gets uploaded to the content origin, so
## publishing the index is not a second deployment step with a second set of credentials.
##
## [b]Keyed by the directory id, not by the content id, and that is not arbitrary.[/b]
## Five of the ids here — `hungry_classic`, `hungry_frenzy`, `hungry_gauntlet`,
## `hungry_warrens`, `hungry_reef` — are five descriptors over ONE pack, `tmc/hungry`: same
## code, five sets of cvars. Keying descriptors by content id would give those five one
## file, so the last one written would win and four modes would quietly become the fifth. The id is
## what an operator types and is unique by construction, because it is a directory name.
##
## [b]It goes stale silently, which is the failure worth designing against.[/b] An index
## naming version 0.1.0 of a pack that was republished as 0.2.0 sends every installing
## server to a manifest that is not there, and the server reports "could not download"
## about a game that is sitting on the origin. `./server pack --all` therefore runs this
## afterwards, and this reads the version out of the same `game.yml` the publisher read,
## rather than out of anything a human keeps in step.

const EXIT_OK := 0
const EXIT_USAGE := 1
const EXIT_FAILED := 2

## What this index calls itself. Bumped when a consumer would have to change.
const FORMAT_VERSION := 1

## Where the descriptors land under the output directory, and what the index points at.
const DESCRIPTOR_DIR := "descriptors"

## Directories under `content/` that are content but are not games.
##
## The same two `TmcContent.NOT_GAMES` skips, and deliberately a second spelling of them:
## this is a publishing tool that must run without a server, and reaching into the host's
## class to borrow a constant would make `./server index` depend on the host booting.
const NOT_GAMES := ["global", "avatars"]


func _initialize() -> void:
	DotLog.timestamps = false
	DotLog.set_level(DotLog.Level.INFO)

	var opts := _options()
	var content_dir := str(opts.get("content", "content"))
	var out_dir := str(opts.get("out", "dist"))

	var dir := DirAccess.open(content_dir)

	if dir == null:
		printerr("no content directory at %s" % content_dir)
		quit(EXIT_USAGE)
		return

	var made := DirAccess.make_dir_recursive_absolute(
		out_dir.path_join(DESCRIPTOR_DIR)
	)

	if made != OK and made != ERR_ALREADY_EXISTS:
		printerr("could not write into %s" % out_dir)
		quit(EXIT_FAILED)
		return

	var games := {}
	var failed := PackedStringArray()
	var defaults := PackedStringArray()

	var names := dir.get_directories()
	names.sort()

	for id in names:
		if id in NOT_GAMES or id.begins_with("."):
			continue

		var descriptor := content_dir.path_join(id).path_join("game.yml")

		if not FileAccess.file_exists(descriptor):
			continue

		var entry := _entry(id, descriptor)

		if not entry.ok:
			failed.append(id)
			printerr("  %s: %s" % [id, str(entry.error)])
			continue

		var written := _copy_descriptor(descriptor, out_dir, id)

		if not written.ok:
			failed.append(id)
			printerr("  %s: %s" % [id, str(written.error)])
			continue

		var row := entry.value as Dictionary
		games[id] = row

		if bool(row.get("default", false)):
			defaults.append(id)

		print("  %-16s %-14s %s" % [id, row["content_id"], row["version"]])

	if games.is_empty():
		printerr("nothing in %s has a game.yml" % content_dir)
		quit(EXIT_FAILED)
		return

	var index := {
		"format_version": FORMAT_VERSION,
		# [b]No generation time, deliberately.[/b] Two indexes built from the same
		# descriptors are then byte-identical, so an upload that changed nothing is
		# visible as an upload of nothing -- where a run timestamp makes every publish
		# look like a change, which is exactly when people stop diffing it. The versions
		# inside are what say whether an origin is current.
		"games": games,
	}

	var path := out_dir.path_join("games.json")
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		printerr("could not write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		quit(EXIT_FAILED)
		return

	# Sorted and indented, because this file is diffed by whoever is working out why an
	# origin is serving a version nobody published.
	file.store_string(JSON.stringify(index, "\t", true) + "\n")
	file.close()

	print("")
	print("  %d games -> %s" % [games.size(), path])
	print("  descriptors -> %s" % out_dir.path_join(DESCRIPTOR_DIR))

	# [b]Two games both claiming the boot slot is fatal on the server, not here.[/b]
	# `TmcContent.scan` refuses a content directory where two descriptors say
	# `default: true`, with no correct way to resolve it -- so an index that offers two
	# such games is an index from which certain PAIRS of games cannot be installed
	# together, and the operator finds out when their server will not start. Said here
	# because this is the only place that sees all of them at once.
	if defaults.size() > 1:
		print("")
		print("  WARNING: %d games claim `default: true` (%s)." % [
			defaults.size(), ", ".join(defaults)
		])
		print("  A server that installs more than one of those refuses to boot.")

	if not failed.is_empty():
		print("  failed: %s" % ", ".join(failed))

	quit(EXIT_OK if failed.is_empty() else EXIT_FAILED)


## One row of the index, read out of one `game.yml`.
func _entry(id: String, path: String) -> DotResult:
	var parsed := TmcYaml.parse_file(path)

	if not parsed.ok:
		return parsed.wrap("could not read %s" % path)

	var tree := parsed.value as Dictionary
	var content_id := str(TmcYaml.at(tree, "content_id", ""))

	if content_id == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"%s names no content_id" % path,
			"a game that is not delivered cannot be installed from an origin"
		)

	var kind := str(TmcYaml.at(tree, "kind", "builtin"))

	# [b]A `builtin` game is listed and marked, not omitted.[/b] Its code is compiled into
	# a particular build of the client and shell, so installing its descriptor onto a
	# server running a different build produces a game that loads nothing -- but leaving
	# it out of the index instead makes the installer report "no such game", which sends
	# an operator looking for a publishing mistake that did not happen. The kind travels
	# and the installer refuses with the real reason.
	var row := {
		"content_id": content_id,
		"version": str(TmcYaml.at(tree, "version", "0.0.0")),
		"name": str(TmcYaml.at(tree, "name", id)),
		"kind": kind,
		"descriptor": "%s/%s/game.yml" % [DESCRIPTOR_DIR, id],
	}

	var players := int(TmcYaml.at(tree, "max_players", 0))

	if players > 0:
		row["max_players"] = players

	if bool(TmcYaml.at(tree, "default", false)):
		row["default"] = true

	return DotResult.success(row)


## Copy one descriptor into the output tree, byte for byte.
##
## [b]Copied, not regenerated.[/b] `game.yml` carries cvars, comments and the reasoning
## for both, and a version written back out of a parse would lose every line of it --
## which matters because the copy an installing server ends up with is the one its
## operator will read and edit.
func _copy_descriptor(source: String, out_dir: String, id: String) -> DotResult:
	var target_dir := out_dir.path_join(DESCRIPTOR_DIR).path_join(id)
	var made := DirAccess.make_dir_recursive_absolute(target_dir)

	if made != OK and made != ERR_ALREADY_EXISTS:
		return DotResult.fail(
			DotError.CODE_IO, "could not create %s" % target_dir
		)

	var bytes := FileAccess.get_file_as_bytes(source)

	if bytes.is_empty():
		return DotResult.fail(
			DotError.CODE_IO, "could not read %s" % source
		)

	var target := target_dir.path_join("game.yml")
	var file := FileAccess.open(target, FileAccess.WRITE)

	if file == null:
		return DotResult.fail(
			DotError.CODE_IO,
			"could not write %s" % target,
			error_string(FileAccess.get_open_error())
		)

	file.store_buffer(bytes)
	file.close()

	return DotResult.success(target)


## `--key value` pairs after the `--`, exactly as the other tools here read them.
func _options() -> Dictionary:
	var out := {}
	var args := OS.get_cmdline_user_args()
	var i := 0

	while i < args.size():
		var arg := args[i]

		if not arg.begins_with("--"):
			i += 1
			continue

		var key := arg.substr(2)

		if i + 1 < args.size() and not args[i + 1].begins_with("--"):
			out[key] = args[i + 1]
			i += 2
		else:
			out[key] = true
			i += 1

	return out
