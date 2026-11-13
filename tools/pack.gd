extends SceneTree

## Publish a content directory as a signed dot-cloud pack. Driven by `./server pack <id>`, which is
## the way to run it.

const EXIT_OK := 0
const EXIT_USAGE := 1
const EXIT_FAILED := 2

## Where an assembled pack is built before it is published. `user://` rather than beside `dist/`, so
## an interrupted run cannot leave a directory that looks like a published content id, and so this
## works on a read-only checkout.
const STAGING := "user://pack_staging"

## Directories under `content/` that are not content anybody publishes. `global` IS publishable --
## it is content every game loads and is exactly the sort of thing a server delivers rather than
## bakes in -- so it is deliberately not here.
const NEVER := ["cache", "tmp"]

## dot-core's deriver, run inside the SOURCE project (its own addons, its own class list).
const REQUIRES_TOOL := "res://addons/dot_core/tools/dot_requires.gd"

## How long one run of the deriver, or the source's import, may take before it is killed.
const REQUIRES_TIMEOUT_S := 600


## [b]A publisher that adds one file the source tree does not have: requires.json.[/b]
## `DotCloudPublisher` publishes a directory, and a game's directory is its repository -- on a
## developer box a link to a checkout other people are working in.
static func publisher_for(requires_file: String) -> DotCloudPublisher:
	var pub := DotCloudPublisher.new()
	if requires_file != "":
		pub.extra_files = {DotAddonApi.REQUIREMENTS_FILE: requires_file}
	return pub


## The pack paths a side must get, from the source's `game.yml`: the descriptor for both
## (install-games reads it on a server, the shell on a client), its `scene` and `module` for
## the server, its `client_scene` for the client. Empty for a source with no descriptor.
static func needs_for(source: String) -> DotResult:
	var out := {}
	var yml := source.path_join("game.yml")
	if not FileAccess.file_exists(yml):
		return DotResult.success(out)
	var read := TmcYaml.parse_file(yml)
	if not read.ok:
		return read.wrap("could not read %s" % yml)
	var tree: Dictionary = read.value
	out["game.yml"] = "both"
	for key in ["scene", "module"]:
		var path := str(TmcYaml.at(tree, key, ""))
		if path != "":
			out[path] = "server"
	var client_scene := str(TmcYaml.at(tree, "client_scene", ""))
	if client_scene != "":
		out[client_scene] = "both" if out.has(client_scene) else "client"
	return DotResult.success(out)


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



## Publish one id.
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

	# [b]A builtin game has nothing to publish, and publishing it anyway is worse than refusing.[/b] a
	# builtin game's `content/<id>/` is a `game.yml` and some cvars -- the game's code is compiled into
	# the build -- so this produced a signed, verifiable pack containing one configuration file.
	if str(meta["kind"]) == "builtin" \
			and not opts.has("source") \
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
	var given := str(opts.get("source", ""))

	if given != "":
		# [b]A game's pack source is its own repository, not this project's tree.[/b] setup.sh vendors all
		# five games into ONE `game/` and one `scenes/`, so there is no directory here that is any single
		# game -- the files are separable only by their name prefix.
		if not DirAccess.dir_exists_absolute(given):
			return DotResult.fail(
				DotError.CODE_STATE,
				"no directory at %s" % given,
				"--source names the tree to publish as this pack"
			)

		source = given
	elif not (meta["include"] as Array).is_empty():
		var staged := STAGING.path_join(id)
		var built := _assemble(meta, staged)

		if not built.ok:
			return built

		source = staged
	elif DirAccess.dir_exists_absolute(dir.path_join("pack")):
		source = dir.path_join("pack")
	else:
		source = dir

	# [b]A `kind: pack` game's source is its own repository, and `--all` has no way to know that.[/b]
	# Without an `include` list, a `pack/` directory or an explicit `--source`, the fallback below is
	# the DESCRIPTOR directory.
	if str(meta["kind"]) == "pack" and not opts.has("source") \
			and (meta["include"] as Array).is_empty() \
			and not DirAccess.dir_exists_absolute(dir.path_join("pack")):
		var why := DotResult.fail(
			DotError.CODE_INVALID,
			"%s is delivered and its source is not in %s" % [id, content_dir],
			"publish it from the game's own repository: "
				+ "./server pack %s --source ../<repo>" % id
		)

		# Named and skipped when sweeping, refused when asked for by name -- the same
		# split the builtin guard makes, and for the same reason: "the set you asked for
		# contains some that cannot" is a skip, "you asked for this one" is an error.
		return why if strict else DotResult.success(false)

	# [b]A pack whose scripts declare `class_name` is dead before it is written.[/b] A mounted pack's
	# globals are not registered in the host, so every cross-file type reference in it fails to compile
	# -- and NOTHING says so at any point a person is looking: the pack publishes, uploads.
	var globals := _class_names_in(source)

	if not globals.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"%s declares class_name and cannot be delivered: %s" % [
				id, ", ".join(globals)
			],
			"a mounted pack's globals are not registered in the host, so every script "
			+ "in it would fail to compile. This is usually a STALE checkout of the "
			+ "game -- run ./upgrade.sh, or pull it in games/, and publish again"
		)

	# An empty pack publishes a manifest that mounts and contains nothing, which is
	# indistinguishable from one whose files failed to upload.
	if _count_files(source) == 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"there is nothing to publish in %s" % source,
			"an empty pack mounts and contains nothing, which reads as a broken upload"
		)

	# [b]What the pack needs of the host's addons, as requires.json at its root.[/b] dot-ci's
	# `package.sh --pack` has always written it; this path never did, so every pack a box published for
	# itself (setup.sh, `./server pack --source`) carried none.
	var requires := derive_requires(source, STAGING.path_join("requires").path_join(str(meta["id"]).replace("/", "_") + ".json"))

	if not requires.ok:
		return requires

	var requires_file := str(requires.value)

	var pub := publisher_for(requires_file)
	pub.content_id = str(meta["id"])
	pub.version = str(meta["version"])
	pub.display_name = str(meta["name"])
	pub.entry_scene = str(meta["entry"])

	# [b]What this host's loader opens can never be one side's file[/b] (dot-cloud API 8): a
	# game's `sides.json` that caught `game.yml`, its server scene or its module would publish
	# a pack install-games refuses or a server cannot start. The publisher refuses it instead.
	var needed := needs_for(source)
	if not needed.ok:
		return needed
	for path: String in needed.value:
		pub.need_on_side(path, str(needed.value[path]))

	if str(meta["mount_root"]) != "":
		pub.mount_root = str(meta["mount_root"])

	# [b]On the publisher rather than on the staged tree.[/b] `exclude` is applied during assembly and
	# so reaches only packs built from an `include` list -- a pack published from `pack/` or from
	# `--source` never sees it.
	for name in (meta["exclude_dirs"] as Array):
		pub.exclude_dirs.append(str(name))

	for m in (meta["mirrors"] as Array):
		pub.mirrors.append(str(m))

	if opts.has("mirror"):
		pub.mirrors.append(str(opts["mirror"]))

	for prefix in (meta["optional"] as Array):
		pub.optional_prefixes.append(str(prefix))

	for key in (meta["addon"] as Dictionary):
		pub.metadata[key] = str(meta["addon"][key])

	for prefix in (meta["groups"] as Dictionary):
		pub.group_rules[prefix] = str((meta["groups"] as Dictionary)[prefix])

	var key_path := str(opts.get("key", ""))

	# [b]Refused, not published unsigned.[/b] `client/content.json` ships `require_signed_manifests:
	# true` because a pack can contain scripts, so an unsigned pack is one that every client declines
	# to mount -- and the operator would have a directory that looks finished.
	if key_path == "" or not FileAccess.file_exists(key_path):
		return DotResult.fail(
			DotError.CODE_STATE,
			"no signing key at %s" % (key_path if key_path != "" else "(none given)"),
			"dot-cloud refuses unsigned manifests, so this pack would mount nowhere"
		)

	pub.signing_key_pem = FileAccess.get_file_as_string(key_path)
	pub.signing_key_id = str(opts.get("key-id", "default"))

	# [b]Named for the CONTENT id, not for the directory.[/b] Those are the same thing almost
	# everywhere -- a directory with no `game.yml` takes its own name -- and where they differ it is
	# load-bearing: hungario is three game ids over one `content_id: hungry`.
	var out_name := str(meta["id"])

	print("")
	print("  %s  %s -> %s" % [
		meta["id"],
		"assembled from pack.json" if not (meta["include"] as Array).is_empty() else source,
		out_dir.path_join(out_name),
	])

	var published := pub.publish(source, out_dir.path_join(out_name))

	if published.ok and requires_file != "" and not _lists(published.value, DotAddonApi.REQUIREMENTS_FILE):
		return DotResult.fail(
			DotError.CODE_STATE,
			"%s was published without its requires.json" % meta["id"],
			"the file was derived but dot-cloud's publisher did not take it "
			+ "(tools/pack.gd's publisher_for hands it over as extra_files)"
		)

	return published


## Whether the manifest a publish returned lists [param path].
static func _lists(result: Variant, path: String) -> bool:
	var manifest: Variant = (result as Dictionary).get("manifest") if result is Dictionary else null

	if not manifest is DotCloudManifest:
		return false

	for f: Variant in (manifest as DotCloudManifest).files:
		if str(f.path) == path:
			return true

	return false



## Derive [param source]'s requires.json into [param out_path], the way dot-ci's `package.sh --pack`
## does: dot-core's `tools/dot_requires.gd`, run with `--path` the source project.
static func derive_requires(source: String, out_path: String) -> DotResult:
	var src := ProjectSettings.globalize_path(source)

	if not FileAccess.file_exists(src.path_join("project.godot")):
		return DotResult.success("")

	if not FileAccess.file_exists(src.path_join("addons/dot_core/tools/dot_requires.gd")):
		print("  note: %s has no addons/dot_core/tools/dot_requires.gd; the pack ships without requires.json" % src)
		return DotResult.success("")

	if FileAccess.file_exists(src.path_join(DotAddonApi.REQUIREMENTS_FILE)):
		var audit := _run_requires(src, ["--check", DotAddonApi.REQUIREMENTS_FILE])

		if int(audit["code"]) != 0:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"%s/requires.json does not cover what the game uses" % src,
				str(audit["output"]).strip_edges()
			)

		return DotResult.success("")

	var out_abs := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
	DirAccess.remove_absolute(out_abs)

	var run := _run_requires(src, ["--out", out_abs])

	# A source never imported has no class cache: dot_requires.gd then fails to PARSE (its DotAddonApi
	# is unknown) before it can print its own "import the project first" and exit 2 -- the case on a
	# GPU box, where a game sibling is staged from its files alone.
	var unimported := int(run["code"]) != 0 and str(run["output"]).contains("Identifier \"DotAddonApi\" not declared")
	if unimported or (int(run["code"]) == 2 and str(run["output"]).contains("import the project first")):
		_godot(["--headless", "--path", src, "--import"])
		run = _run_requires(src, ["--out", out_abs])

	if int(run["code"]) != 0:
		return DotResult.fail(
			DotError.CODE_STATE,
			"could not derive requires.json for %s" % src,
			str(run["output"]).strip_edges()
		)

	var parsed := DotAddonApi.parse(FileAccess.get_file_as_string(out_abs))

	# Empty is allowed, as package.sh allows it: a map repository that is a project and names
	# no addon class needs nothing, and saying so is still a file.
	if not parsed.ok:
		return DotResult.fail(
			DotError.CODE_STATE,
			"requires.json for %s came out unreadable" % src,
			str(run["output"]).strip_edges()
		)

	var said := PackedStringArray()
	for addon: String in (parsed.value as Dictionary):
		said.append("%s %d" % [addon, int((parsed.value as Dictionary)[addon])])
	said.sort()
	print("  requires.json: %s" % ", ".join(said))
	return DotResult.success(out_abs)


static func _run_requires(src: String, args: Array) -> Dictionary:
	return _godot(["--headless", "--path", src, "--script", REQUIRES_TOOL, "--"] + args)


## Runs this same engine, capped by `timeout` where there is one, and returns
## {code, output} with stderr folded in.
static func _godot(args: Array) -> Dictionary:
	var exe := OS.get_executable_path()
	var argv := PackedStringArray()
	var program := exe

	if OS.get_name() != "Windows" and FileAccess.file_exists("/usr/bin/timeout"):
		program = "/usr/bin/timeout"
		argv.append(str(REQUIRES_TIMEOUT_S))
		argv.append(exe)

	for a: Variant in args:
		argv.append(str(a))

	var output := []
	var code := OS.execute(program, argv, output, true)
	return {"code": code, "output": "\n".join(PackedStringArray(output))}



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
		"exclude_dirs": [],
		"optional": [],
		"groups": {},
		"mirrors": [],
		# A server-owner extra pack that starts something: {"entry": "scene.tscn", "side":
		# "server|client|both"}.
		"addon": {},
	}

	# Not a pack.json key: it is the GAME's nature, and a pack descriptor claiming to be
	# builtin would be claiming something about code it does not contain.
	var kind := ""

	# A game that is also delivered names its version and its client scene in the file it
	# already has, read through the server's own YAML reader rather than a second one.
	var game_yml := dir.path_join("game.yml")

	if FileAccess.file_exists(game_yml):
		# [b]`parse` returns a DotResult, not the tree.[/b] The first version of this read it as `var
		# tree: Variant = TmcYaml.parse(...)` and then asked `tree is Dictionary`, which is never true.
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

	for key in ["include", "exclude", "exclude_dirs", "optional", "mirrors"]:
		if not (meta[key] is Array):
			return DotResult.fail(
				DotError.CODE_INVALID, "%s: '%s' must be a list" % [pack_json, key]
			)

	if not (meta["groups"] is Dictionary):
		return DotResult.fail(
			DotError.CODE_INVALID, "%s: 'groups' must be an object" % pack_json
		)

	if not (meta["addon"] is Dictionary):
		return DotResult.fail(
			DotError.CODE_INVALID, "%s: 'addon' must be an object" % pack_json
		)

	for key in (meta["addon"] as Dictionary):
		if not key in ["entry", "side"]:
			return DotResult.fail(
				DotError.CODE_INVALID, "%s: addon: unknown key '%s'" % [pack_json, key],
				"expected entry and side"
			)

	if (meta["addon"] as Dictionary).has("side") \
			and not str(meta["addon"]["side"]) in ["server", "client", "both"]:
		return DotResult.fail(
			DotError.CODE_INVALID, "%s: addon: side must be server, client or both" % pack_json
		)

	meta["kind"] = kind

	return DotResult.success(meta)



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



## Every `class_name` declared under [param root], up to a handful worth naming. Text search rather
## than a parse: this runs over a tree that is about to be published and the question is only
## whether the declaration is there.
func _class_names_in(root: String) -> PackedStringArray:
	var out := PackedStringArray()

	for rel in DotPaths.list_files_recursive(root):
		if not rel.ends_with(".gd"):
			continue
		# The host's own addons legitimately declare globals; they are not in the pack.
		if rel.begins_with("addons/") or rel.contains("/addons/"):
			continue
		# A linked git worktree inside the source (a `.git` file) is not part of the game.
		if rel.contains("/") and FileAccess.file_exists(root.path_join(rel.get_slice("/", 0)).path_join(".git")):
			continue

		for line in FileAccess.get_file_as_string(root.path_join(rel)).split("\n"):
			if not line.begins_with("class_name "):
				continue

			var name := line.substr(11).strip_edges().split(" ")[0]

			if name != "" and not out.has(name):
				out.append("%s (%s)" % [name, rel])

			if out.size() >= 6:
				return out

	return out


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
