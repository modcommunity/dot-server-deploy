extends SceneTree

## Publish a content directory as a signed dot-cloud pack.
##
## [codeblock]
## godot --headless --path . --script res://tools/pack.gd -- \
##     --id avatars --content content --out dist --key keys/content.key
##
## godot --headless --path . --script res://tools/pack.gd -- --all ...
## [/codeblock]
##
## Driven by `./server pack <id>`, which is the way to run it. It exists because that
## command named `res://tools/publish.tscn` for a long time and no such file was ever
## written: Godot printed "Cannot open file" and the launcher exited **0**, so every
## caller -- including `export-web`, which refuses to build when a map is unpublished and
## names this command as the fix -- was told the publish had worked.
##
## [b]What goes in a pack is declared, not inferred.[/b] A pack made of whatever happens
## to sit in one folder forces a developer to duplicate files into `content/` to ship
## them, so the avatars a game loads from `res://avatars/` and the avatars it delivers
## would be two copies that drift. `content/<id>/pack.json` says what to put in and where
## it lands:
##
## [codeblock]
## {
##     "version": "1.0.0",
##     "name": "Stock avatars",
##     "include": [
##         "avatars/kenney",
##         { "from": "avatars/head_stock.tscn", "to": "heads/stock.tscn" }
##     ],
##     "exclude": ["*.import", "*.uid"]
## }
## [/codeblock]
##
## [b]JSON, and not another YAML file.[/b] `game.yml` is YAML because an operator edits it
## on a live server; this is a build instruction a developer writes once, and JSON needs
## no parser that this repository has to own -- the shell that used to do this was growing
## an awk state machine for a one-level list, which is a second parser in a third language
## for something `JSON.parse_string` does in a line. Same reasoning that makes dot-map's
## catalogue and dot-cloud's own manifests JSON.
##
## With no `pack.json`, a directory is published whole -- and a game's `game.yml` still
## supplies its version, name, `content_id` and `client_scene`, read through `TmcYaml`,
## which is the server's own reader rather than a second one.
##
## Exit codes: 0 published, 1 called wrong, 2 nothing was published.

const EXIT_OK := 0
const EXIT_USAGE := 1
const EXIT_FAILED := 2

## Where an assembled pack is built before it is published.
##
## `user://` rather than beside `dist/`, so an interrupted run cannot leave a directory
## that looks like a published content id, and so this works on a read-only checkout.
const STAGING := "user://pack_staging"

## Directories under `content/` that are not content anybody publishes.
##
## `global` IS publishable -- it is content every game loads and is exactly the sort of
## thing a server delivers rather than bakes in -- so it is deliberately not here.
const NEVER := ["cache", "tmp"]


func _initialize() -> void:
	DotLog.timestamps = false
	DotLog.set_level(DotLog.Level.INFO)

	var opts := _options()

	var content_dir: String = str(opts.get("content", ""))
	var out_dir: String = str(opts.get("out", ""))

	if content_dir == "" or out_dir == "":
		printerr("pack needs --content <dir> --out <dir>, and --id <id> or --all")
		quit(EXIT_USAGE)
		return

	var ids := PackedStringArray()

	if opts.has("all"):
		ids = _publishable(content_dir)

		if ids.is_empty():
			printerr("nothing under %s to publish" % content_dir)
			quit(EXIT_FAILED)
			return
	elif opts.has("id"):
		ids.append(str(opts["id"]))
	else:
		printerr("pack needs --id <id> or --all")
		quit(EXIT_USAGE)
		return

	var strict := not opts.has("all")
	var published := 0
	var skipped := PackedStringArray()
	var failed := PackedStringArray()

	for id in ids:
		var res := _publish_one(id, content_dir, out_dir, opts, strict)

		if not res.ok:
			failed.append(id)
			printerr("  %s: %s" % [id, str(res.error)])
		elif res.value is bool and not bool(res.value):
			skipped.append(id)
		else:
			published += 1

	print("")
	print("  %d published, %d skipped, %d failed" % [
		published, skipped.size(), failed.size()
	])

	# Named, not just counted. "5 skipped" invites the reader to assume they know which
	# five, and the one time they are wrong is the time it matters.
	if not skipped.is_empty():
		print("  skipped (nothing to pack): %s" % ", ".join(skipped))

	if not failed.is_empty():
		print("  failed: %s" % ", ".join(failed))

	# Cleaned unconditionally, including after a failure: a half-assembled tree left in
	# user:// is picked up by nothing and understood by nobody.
	DotPaths.remove_tree(STAGING)

	quit(EXIT_OK if failed.is_empty() and published > 0 else EXIT_FAILED)


# --- One pack ---------------------------------------------------------------

## Publish one id. Returns success carrying `false` when there is deliberately nothing
## to publish and [param strict] is off — which is what `--all` wants, and what an
## explicitly named id must NOT get: "you asked for this one and it cannot be packed" is
## an error, and "the set you asked for includes some that cannot" is a skip.
func _publish_one(
	id: String, content_dir: String, out_dir: String, opts: Dictionary, strict: bool
) -> DotResult:
	var dir := content_dir.path_join(id)

	if not DirAccess.dir_exists_absolute(dir):
		return DotResult.fail(DotError.CODE_STATE, "no content at %s" % dir)

	var spec := _read_spec(dir, id)

	if not spec.ok:
		return spec

	var meta: Dictionary = spec.value

	# [b]A builtin game has nothing to publish, and publishing it anyway is worse than
	# refusing.[/b] `content/lobby/` is a `game.yml` and some cvars -- the game's code is
	# compiled into the build -- so this produced a signed, verifiable pack containing one
	# configuration file. It mounts, it contains no game, and every symptom of using it
	# points somewhere else. Found by running `--all`, which cheerfully published five of
	# them.
	#
	# `pack/` or a `pack.json` overrides this: a game that is builtin here and also
	# delivers content has said so explicitly.
	if str(meta["kind"]) == "builtin" \
			and (meta["include"] as Array).is_empty() \
			and not DirAccess.dir_exists_absolute(dir.path_join("pack")):
		if not strict:
			return DotResult.success(false)

		return DotResult.fail(
			DotError.CODE_INVALID,
			"%s is a builtin game: its code is in the build, not in a pack" % id,
			"publishing it would produce a pack containing only its game.yml. "
			+ "Give it a pack/ directory or a pack.json if it has content to deliver"
		)

	# Assembled from an include list, or the directory as it stands. `pack/` is checked
	# before the directory itself because that is the layout a game with `kind: pack`
	# uses and `tmc_content.gd` documents.
	var source := ""

	if not (meta["include"] as Array).is_empty():
		var staged := STAGING.path_join(id)
		var built := _assemble(meta, staged)

		if not built.ok:
			return built

		source = staged
	elif DirAccess.dir_exists_absolute(dir.path_join("pack")):
		source = dir.path_join("pack")
	else:
		source = dir

	# An empty pack publishes a manifest that mounts and contains nothing, which is
	# indistinguishable from one whose files failed to upload.
	if _count_files(source) == 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"there is nothing to publish in %s" % source,
			"an empty pack mounts and contains nothing, which reads as a broken upload"
		)

	var pub := DotCloudPublisher.new()
	pub.content_id = str(meta["id"])
	pub.version = str(meta["version"])
	pub.display_name = str(meta["name"])
	pub.entry_scene = str(meta["entry"])

	if str(meta["mount_root"]) != "":
		pub.mount_root = str(meta["mount_root"])

	for m in (meta["mirrors"] as Array):
		pub.mirrors.append(str(m))

	if opts.has("mirror"):
		pub.mirrors.append(str(opts["mirror"]))

	for prefix in (meta["optional"] as Array):
		pub.optional_prefixes.append(str(prefix))

	for prefix in (meta["groups"] as Dictionary):
		pub.group_rules[prefix] = str((meta["groups"] as Dictionary)[prefix])

	var key_path := str(opts.get("key", ""))

	# [b]Refused, not published unsigned.[/b] `client/content.json` ships
	# `require_signed_manifests: true` because a pack can contain scripts, so an unsigned
	# pack is one that every client declines to mount -- and the operator would have a
	# directory that looks finished, serves cleanly and works nowhere.
	if key_path == "" or not FileAccess.file_exists(key_path):
		return DotResult.fail(
			DotError.CODE_STATE,
			"no signing key at %s" % (key_path if key_path != "" else "(none given)"),
			"dot-cloud refuses unsigned manifests, so this pack would mount nowhere"
		)

	pub.signing_key_pem = FileAccess.get_file_as_string(key_path)
	pub.signing_key_id = str(opts.get("key-id", "default"))

	print("")
	print("  %s  %s -> %s" % [
		meta["id"],
		"assembled from pack.json" if not (meta["include"] as Array).is_empty() else source,
		out_dir.path_join(id),
	])

	return pub.publish(source, out_dir.path_join(id))


# --- The descriptor ---------------------------------------------------------

## Everything the publisher needs, from `pack.json`, then `game.yml`, then defaults.
func _read_spec(dir: String, id: String) -> DotResult:
	var meta := {
		"id": id,
		"version": "0.0.0",
		"name": "",
		"entry": "",
		"mount_root": "",
		"include": [],
		"exclude": [],
		"optional": [],
		"groups": {},
		"mirrors": [],
	}

	# Not a pack.json key: it is the GAME's nature, and a pack descriptor claiming to be
	# builtin would be claiming something about code it does not contain.
	var kind := ""

	# A game that is also delivered names its version and its client scene in the file it
	# already has, read through the server's own YAML reader rather than a second one.
	var game_yml := dir.path_join("game.yml")

	if FileAccess.file_exists(game_yml):
		# [b]`parse` returns a DotResult, not the tree.[/b] The first version of this read
		# it as `var tree: Variant = TmcYaml.parse(...)` and then asked `tree is
		# Dictionary`, which is never true — so every field below silently kept its
		# default and every game published as `0.0.0` with no name and no entry scene. A
		# pack with the wrong version in it is not a pack that fails; it is one that
		# mounts at the wrong path forever. Fallible operations return DotResult in this
		# family precisely so that ignoring one is visible, and this ignored it by
		# type-testing the wrapper.
		var read := TmcYaml.parse_file(game_yml)

		if not read.ok:
			return read.wrap("could not read %s" % game_yml)

		var tree: Dictionary = read.value

		meta["id"] = str(TmcYaml.at(tree, "content_id", id))
		meta["version"] = str(TmcYaml.at(tree, "version", "0.0.0"))
		meta["name"] = str(TmcYaml.at(tree, "name", ""))
		meta["entry"] = str(TmcYaml.at(tree, "client_scene", ""))
		kind = str(TmcYaml.at(tree, "kind", "builtin"))

	var pack_json := dir.path_join("pack.json")

	if not FileAccess.file_exists(pack_json):
		meta["kind"] = kind
		return DotResult.success(meta)

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(pack_json))

	if not (parsed is Dictionary):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"%s is not a JSON object" % pack_json,
			"a pack descriptor is { \"version\": ..., \"include\": [...] }"
		)

	var doc: Dictionary = parsed

	# [b]Unknown keys are refused rather than ignored.[/b] A misspelled "exclude" that is
	# silently dropped produces a pack with files in it that the author believed were
	# excluded, and nothing anywhere says so.
	for key in doc:
		if not meta.has(key):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"%s: unknown key '%s'" % [pack_json, key],
				"expected one of: %s" % ", ".join(PackedStringArray(meta.keys()))
			)

	for key in doc:
		meta[key] = doc[key]

	for key in ["include", "exclude", "optional", "mirrors"]:
		if not (meta[key] is Array):
			return DotResult.fail(
				DotError.CODE_INVALID, "%s: '%s' must be a list" % [pack_json, key]
			)

	if not (meta["groups"] is Dictionary):
		return DotResult.fail(
			DotError.CODE_INVALID, "%s: 'groups' must be an object" % pack_json
		)

	meta["kind"] = kind

	return DotResult.success(meta)


# --- Assembly ---------------------------------------------------------------

## Copy everything `include` names into [param staged], then drop what `exclude` matches.
func _assemble(meta: Dictionary, staged: String) -> DotResult:
	DotPaths.remove_tree(staged)

	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(staged)) != OK:
		return DotResult.fail(DotError.CODE_IO, "could not create %s" % staged)

	for raw in (meta["include"] as Array):
		var from := ""
		var to := ""

		if raw is Dictionary:
			from = str((raw as Dictionary).get("from", ""))
			to = str((raw as Dictionary).get("to", ""))
		else:
			from = str(raw)

		if from == "":
			return DotResult.fail(
				DotError.CODE_INVALID,
				"an include entry names no source",
				"either \"path\" or { \"from\": \"path\", \"to\": \"where\" }"
			)

		# Written as `res://` everywhere else in this project, so accepted here.
		var source := from if from.begins_with("res://") else "res://" + from.lstrip("/")

		if to == "":
			to = source.get_file()

		var copied := _copy_into(source, staged.path_join(to))

		if not copied.ok:
			return copied

	# Excludes run over the STAGED tree, so a pattern matches where the file landed
	# rather than where it came from.
	for pattern in (meta["exclude"] as Array):
		_drop_matching(staged, str(pattern))

	return DotResult.success(null)


func _copy_into(source: String, dest: String) -> DotResult:
	var abs_source := ProjectSettings.globalize_path(source)
	var abs_dest := ProjectSettings.globalize_path(dest)

	if FileAccess.file_exists(abs_source):
		DirAccess.make_dir_recursive_absolute(abs_dest.get_base_dir())

		if DirAccess.copy_absolute(abs_source, abs_dest) != OK:
			return DotResult.fail(DotError.CODE_IO, "could not copy %s" % source)

		return DotResult.success(null)

	if not DirAccess.dir_exists_absolute(abs_source):
		return DotResult.fail(
			DotError.CODE_STATE,
			"include: nothing at %s" % source,
			"paths are relative to the project root"
		)

	DirAccess.make_dir_recursive_absolute(abs_dest)

	var dir := DirAccess.open(abs_source)

	if dir == null:
		return DotResult.fail(DotError.CODE_IO, "could not read %s" % source)

	dir.list_dir_begin()
	var name := dir.get_next()

	while name != "":
		if name != "." and name != "..":
			var res := _copy_into(source.path_join(name), dest.path_join(name))

			if not res.ok:
				dir.list_dir_end()
				return res

		name = dir.get_next()

	dir.list_dir_end()

	return DotResult.success(null)


func _drop_matching(root: String, pattern: String) -> void:
	if pattern == "":
		return

	var abs_root := ProjectSettings.globalize_path(root)
	var dir := DirAccess.open(abs_root)

	if dir == null:
		return

	dir.list_dir_begin()
	var name := dir.get_next()

	while name != "":
		if name != "." and name != "..":
			var child := root.path_join(name)

			if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(child)):
				_drop_matching(child, pattern)
			elif name.match(pattern):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(child))

		name = dir.get_next()

	dir.list_dir_end()


# --- Odds and ends ----------------------------------------------------------

func _count_files(root: String) -> int:
	var abs_root := ProjectSettings.globalize_path(root)
	var dir := DirAccess.open(abs_root)

	if dir == null:
		return 0

	var count := 0

	dir.list_dir_begin()
	var name := dir.get_next()

	while name != "":
		if name != "." and name != "..":
			var child := root.path_join(name)

			if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(child)):
				count += _count_files(child)
			else:
				count += 1

		name = dir.get_next()

	dir.list_dir_end()

	return count


## Every directory under `content/` that could be a pack.
func _publishable(content_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(content_dir)

	if dir == null:
		return out

	dir.list_dir_begin()
	var name := dir.get_next()

	while name != "":
		if dir.current_is_dir() and not name.begins_with(".") and not NEVER.has(name):
			out.append(name)

		name = dir.get_next()

	dir.list_dir_end()
	out.sort()

	return out


func _options() -> Dictionary:
	var out := {}
	var args := OS.get_cmdline_user_args()
	var i := 0

	while i < args.size():
		var a: String = args[i]

		if not a.begins_with("--"):
			i += 1
			continue

		var key := a.substr(2)

		if i + 1 < args.size() and not args[i + 1].begins_with("--"):
			out[key] = args[i + 1]
			i += 2
		else:
			out[key] = true
			i += 1

	return out
