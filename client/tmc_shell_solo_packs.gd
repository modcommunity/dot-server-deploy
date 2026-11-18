class_name TmcShellSoloPacks
extends RefCounted

## The packs a solo game is made of: resolving, fetching, sizing and warming them.

## The shell this works for. Its state stays there.
var shell: Node = null


func _init(owner_shell: Node) -> void:
	shell = owner_shell


## Where downloads go when the player keeps none. Separate from the normal cache so a
## player switching the setting off does not have their kept games deleted, and back on
## finds them still there.
const SLICE_EXTENSIONS := ["tscn", "scn", "tres", "res"]


## The newest version of a pack named without one, resolved once per launch so the prefetch and the mount pass agree.
func _resolve_solo_key(key: String) -> DotResult:
	if shell._solo_key_cache.has(key):
		return DotResult.success(shell._solo_key_cache[key])
	var latest: DotResult = await TmcSolo.resolve_latest(shell, str(TmcSolo.split_key(key)["id"]), shell._cloud.http_base_urls)
	if latest.ok:
		shell._solo_key_cache[key] = latest.value
	return latest


## The map packs this launch fetches: `client/solo.json`'s, except that a start map with a one-map
## pack of its own ([method TmcSolo.per_map_key]) fetches only that, not the whole set.
func _solo_map_packs(content_id: String) -> PackedStringArray:
	if shell._solo_map_packs_memo is PackedStringArray:
		return shell._solo_map_packs_memo
	var out := PackedStringArray()
	for key in TmcSolo.map_packs(content_id):
		var one := TmcSolo.per_map_key(key, shell._solo_map)
		if one != "" and (await _resolve_solo_key(one)).ok:
			DotLog.info(shell.CHANNEL, "fetching only the start map's pack", {"map": shell._solo_map, "pack": one, "instead_of": key})
			out.append(one)
		else:
			out.append(key)
	shell._solo_map_packs_memo = out
	return out


## The Workshop sync for a solo launch, before its overlay is decided: a game whose `provides.json` states `accepts` has its subscribed packs planned and registered with the launch job (mounted after [method _prefetch_solo] downloads them, by [method DotCloudWorkshop.mount_pending]). The value is the summary's `addons` (dot-cloud 28), the subscribed addon packs for [method _solo_overlay]; empty for any other game.
func _solo_workshop_plan(content_id: String, version: String) -> Array:
	var game: DotResult = await shell._cloud.resolve_manifest(StringName(content_id), version)
	if not game.ok:
		return []
	var provides: DotResult = await shell._cloud.read_pack_file(game.value as DotCloudManifest, "provides.json")
	if not provides.ok or shell._accepts_from_text((provides.value as PackedByteArray).get_string_from_utf8()).is_empty():
		return []
	var workshop = shell._ensure_workshop()
	workshop.defer_mount = true
	var summary = await shell._sync_workshop(content_id)
	workshop.defer_mount = false
	shell._deferred_workshop = true
	var addons: Variant = summary.get("addons", [])
	return addons if addons is Array else []


## Registers the game, its dependencies and map packs with the launch job (subscribed packs were registered by
## [method _solo_workshop_plan]) and downloads them all, mounting none.
## Nothing here is fatal: a pack that cannot be fetched now is reported by the mount pass that follows, as it was before.
func _prefetch_solo(content_id: String, version: String) -> void:
	var game: DotResult = await shell._cloud.resolve_manifest(StringName(content_id), version)
	if not game.ok:
		return
	var manifest := game.value as DotCloudManifest
	var all_groups := PackedStringArray(["*"]) # solo has no server to say which map, so total every group
	var takes_groups := DotAddonApi.build_level("dot_cloud") >= 23
	if takes_groups:
		await shell._cloud.job_register_manifest(manifest, all_groups)
	else:
		await shell._cloud.job_register_manifest(manifest)

	var keys := PackedStringArray()
	var map_keys := PackedStringArray()
	var yml: DotResult = await shell._cloud.read_pack_file(manifest, "game.yml")
	if yml.ok:
		var desc := TmcSolo.parse_descriptor((yml.value as PackedByteArray).get_string_from_utf8())
		keys.append_array(desc["dependencies"] as PackedStringArray)
		keys.append_array(desc["server_dependencies"] as PackedStringArray)
		if not TmcSolo.skip_maps(content_id):
			map_keys = await _solo_map_packs(content_id)

	# Map packs take the groups the mount pass will ask for (TmcSolo.map_groups), so the total is what moves.
	var passes: Array = [[await _solo_refs(keys), all_groups],
		[await _solo_refs(map_keys), TmcSolo.map_groups(DotPlatform.is_web(), shell._solo_map)]]
	for pass_refs: Array in passes:
		var refs: Array = pass_refs[0]
		if refs.is_empty():
			continue
		if takes_groups:
			await shell._cloud.job_register(refs, pass_refs[1] as PackedStringArray)
		else:
			await shell._cloud.job_register(refs)

	await shell._cloud.job_download()


## `{id, version}` for each valid key of [param keys], a missing version resolved to the newest; a key that will not resolve is left out.
func _solo_refs(keys: PackedStringArray) -> Array:
	var refs: Array = []
	for key in keys:
		var parts := TmcSolo.split_key(key)
		if not TmcSolo.valid_id(str(parts["id"])) or not TmcSolo.valid_version(str(parts["version"])):
			continue
		var id := str(parts["id"])
		var ver := str(parts["version"])
		if ver == "":
			var latest: DotResult = await _resolve_solo_key(key)
			if not latest.ok:
				continue
			id = str(latest.value["id"])
			ver = str(latest.value["version"])
		refs.append({"id": id, "version": ver})
	return refs


## Fetches and mounts one pack by `<id>[@<version>]`, resolving a missing version to the newest; returns the `<id>@<version>` mounted.
## [param announce] names what is fetched and its size in the status line, so a download the player did not ask for is named.
## [param groups] are the download groups asked: every one by default, a map pack's from [method TmcSolo.map_groups].
func _ensure_solo_pack(key: String, announce: bool = false, groups: PackedStringArray = PackedStringArray(["*"])) -> DotResult:
	var parts := TmcSolo.split_key(key)
	var id := str(parts["id"])
	var version := str(parts["version"])

	if not TmcSolo.valid_id(id) or not TmcSolo.valid_version(version):
		return DotResult.fail(DotError.CODE_INVALID, "Not a pack id.", key)

	if version == "":
		var latest: DotResult = await _resolve_solo_key(key)
		if not latest.ok:
			return latest
		id = str(latest.value["id"])
		version = str(latest.value["version"])

	if announce and not shell._launch_job:
		shell._solo_pack_label = await _describe_solo_pack(id, version, groups)
		shell._say(shell._solo_pack_label)

	var got: DotResult = await shell._cloud.ensure(StringName(id), version, groups)
	if not got.ok:
		shell._solo_pack_label = ""
		return got

	return DotResult.success("%s@%s" % [id, version])


## "Fetching maps: <name> (<size>)…". The size is what is still to download (a pack already
## on the disk is "already downloaded"), from the manifest alone. A manifest that will not
## resolve here only costs the size: [method DotCloudClient.ensure] reports the real failure.
func _describe_solo_pack(id: String, version: String, groups: PackedStringArray = PackedStringArray(["*"])) -> String:
	var pack_name := id.get_slice("/", 1)
	var resolved: DotResult = await shell._cloud.resolve_manifest(StringName(id), version)
	if not resolved.ok:
		return shell._text("shell.solo.fetching", {"name": pack_name}, "Fetching maps: %s…" % pack_name)

	var manifest := resolved.value as DotCloudManifest
	if manifest.display_name != "":
		pack_name = manifest.display_name

	var plan = shell._cloud.plan_for(manifest, groups)
	if int(plan.get("missing_bytes", 0)) <= 0:
		return shell._text("shell.solo.have", {"name": pack_name}, "Maps: %s (already downloaded)" % pack_name)
	var size = shell._size_text(int(plan["missing_bytes"]))
	return shell._text("shell.solo.fetching_size", {"name": pack_name, "size": size}, "Fetching maps: %s (%s)…" % [pack_name, size])


## Code and scenes of the mounted packs [param keys], in the order that lets a scene find its
## scripts already cached.
func _pack_script_paths(keys: Array[String]) -> PackedStringArray:
	var scripts := PackedStringArray()
	var others := PackedStringArray()

	for key in keys:
		var manifest = shell._cloud.manifest_for(key)
		if manifest == null:
			continue

		for file in manifest.files:
			# Tooling scenes (tools/, examples/, tests/, ci/) are never played and their scripts preload paths a pack does not ship.
			if _in_tooling_dir(file.path):
				continue
			var res_path = manifest.resource_path(file)
			var ext = res_path.get_extension()
			if ext == "gd":
				scripts.append(res_path)
			elif ext in SLICE_EXTENSIONS:
				others.append(res_path)

	return scripts + others


## True for a file under a directory the warm-up skips at any depth (the list dot-cloud's script warm uses).
static func _in_tooling_dir(path: String) -> bool:
	var parts := path.split("/")
	for i in parts.size() - 1:
		if DotCloudClient.WARM_SKIP_DIRS.has(parts[i]):
			return true
	return false


## Compiles a delivered pack's scripts a slice per frame with dot-cloud's warm_content, then slice-loads its scenes and resources. An addon without warm_content falls back to [method _slice_load] for everything. Both are no-ops natively. On the web they run on the main thread even on the threaded engine: a [method ResourceLoader.load_threaded_request] there never finished (FC's 326 scripts at 0 % for minutes, no frame drawn; web-mt-shell-unpack-hang-1), so warm_content is forced past its own "threads exist" skip.
func _warm_pack(keys: Array[String]) -> Variant:
	if shell._cloud == null or not shell._cloud.has_method("warm_content") or not DotPlatform.is_web():
		await _slice_load(_pack_script_paths(keys))
		return null

	if shell.loading != null:
		shell.loading.set_progress(0.0, shell._text("shell.loading.scripts", {}, "Preparing the game…"))
	var on_progress := func(done: int, total: int) -> void:
		var fraction := float(done) / float(maxi(total, 1))
		if shell._progress != null:
			shell._progress.visible = true
			shell._progress.value = fraction * 100.0
		if shell.loading != null:
			shell.loading.set_progress(fraction, shell._text("shell.loading.scripts", {}, "Preparing the game…"))
	var warmed: Variant = await shell._cloud.call("warm_content", shell.get_tree(), PackedStringArray(keys), true, on_progress)
	if warmed != null:
		shell.slice_frames_yielded = warmed.frames_yielded

	var rest := PackedStringArray()
	for res_path in _pack_script_paths(keys):
		if res_path.get_extension() != "gd":
			rest.append(res_path)
	await _slice_load(rest)
	return warmed


## What a scene in this build pulls in, scripts first.
static func _scene_dependency_paths(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for dep in ResourceLoader.get_dependencies(path):
		var dep_path := dep.get_slice("::", 2) if "::" in dep else dep
		if dep_path.get_extension() in SLICE_EXTENSIONS or dep_path.get_extension() == "gd":
			out.append(dep_path)
	out.sort()
	return out


## Fills the resource cache across frames so the following [code]load()[/code] is a hit and the cover keeps animating (a browser without threads compiles every script in one frame).
## Native builds skip it unless [param force]; a failure only means the plain load() does the work.
func _slice_load(paths: PackedStringArray, force: bool = false) -> void:
	if paths.is_empty() or not (force or DotPlatform.is_web()):
		return

	var loader := DotCloudSliceLoader.new()
	loader.progress.connect(func(done: int, total: int, _path: String) -> void:
		var fraction := float(done) / float(maxi(total, 1))
		if shell._progress != null:
			shell._progress.visible = true
			shell._progress.value = fraction * 100.0
		if shell.loading != null:
			shell.loading.set_progress(fraction, shell._text("shell.loading.scripts", {}, "Preparing the game…")))

	# Never threaded on the web: see [method _warm_pack].
	var res: DotResult = await loader.load_all(shell.get_tree(), paths, not DotPlatform.is_web())
	shell.slice_frames_yielded = loader.frames_yielded

	if not res.ok:
		DotLog.warn(shell.CHANNEL, "slice preload stopped early", {"why": str(res.error)})
