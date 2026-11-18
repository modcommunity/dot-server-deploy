class_name TmcShellSolo
extends RefCounted

## Playing one game with no server: fetch, mount and start it, and the addon overlay it may need first.

## The shell this works for. Its state stays there.
var shell: Node = null


func _init(owner_shell: Node) -> void:
	shell = owner_shell


## What [method _solo_overlay] did: nothing was missing, a restart into the addons is under way, they are missing and cannot be had now,
## or the content store publishes no pack that holds one of them ([member _unpublished] says which).
enum SoloOverlay { NONE, RESTARTING, BLOCKED, UNPUBLISHED }

## Why [constant SoloOverlay.UNPUBLISHED]: dir -> the sentence [method pack_holds_dir] gave, from the last [method _collect_solo_announce].
var _unpublished: Dictionary = {}


## Runs [param content_id] here, with no server: fetch, verify and mount it as a join does,
## then start its client scene, which finds no link and plays offline. See [TmcSolo].
func _start_solo(content_id: String, version: String = "", map: String = "") -> void:
	if content_id == "" or not TmcSolo.valid_id(content_id):
		return

	shell._drop_link()
	shell._end_solo_session()
	shell._clear_game()
	shell._leave_game_ui()

	shell._solo_id = content_id
	shell._solo_version = version
	shell._solo_map = map if TmcSolo.valid_map(map) else ""
	shell._solo_retry = ""
	shell._refresh_solo_maps_check()
	shell._set_busy(true)
	shell._join.text = "Connect"
	shell._show_connect_form(false)
	if shell._solo_button != null:
		shell._solo_button.disabled = true
	shell._say("Finding %s…" % content_id)

	shell._ensure_cloud()
	# The solo game's server runs here as well: it needs the server-only files (API 8).
	shell._cloud.config.side = "both"
	shell._adopt_content_url_arg()
	shell._enter_solo_session()

	var started := await _load_solo(content_id, version)

	if shell._solo_button != null:
		shell._solo_button.disabled = false

	if not started.ok:
		shell._end_solo_session()
		shell._fail(shell._text("shell.solo.failed", {"reason": shell._explain(started.error)},
			"Could not start %s: %s" % [content_id, shell._explain(started.error)]))
		if shell._solo_retry != "" and shell._solo_button != null:
			shell._solo_button.text = shell._text("shell.solo.retry", {}, "Retry")
			shell._solo_button.visible = true
			shell._primary(shell._solo_button)
		return


## The solo button: Retry after [method _solo_overlay] was blocked, which forgets that set's restarts and a failed mark first, so the overlay is built again.
func _on_solo_pressed() -> void:
	_forget_solo_retry()
	_start_solo(shell._solo_id, shell._solo_version, shell._solo_map)


## What Retry clears: the blocked set's restarts and a failed mark, so [method _overlay_blocked] lets the overlay be built again.
func _forget_solo_retry() -> void:
	if shell._solo_retry == "":
		return
	DotLog.info(shell.CHANNEL, "retrying this solo game's addons", {"attempt": shell._solo_retry})
	shell._forget_update_attempt(shell._solo_retry)
	if DotValue.same(DotCloudAddonSet.read_plan().get("state", ""), DotCloudAddonSet.STATE_FAILED):
		DotCloudAddonSet.forget()
	shell._solo_retry = ""


## Everything [method _start_solo] does that can fail, so it has one way out.
func _load_solo(content_id: String, version: String) -> DotResult:
	shell._cloud.begin_job("launch")
	shell._launch_job = true
	shell._solo_key_cache = {}
	shell._solo_map_packs_memo = null
	shell._deferred_workshop = false
	var res: DotResult = await _load_solo_inner(content_id, version)
	shell._launch_job = false
	shell._job = {}
	shell._solo_pack_label = ""
	shell._cloud.end_job()
	return res


## The id and version a solo start uses: the newest when none was asked for, and the newest
## published when the pinned one has no manifest. Fails with the resolver's result.
func _pin_solo_version(content_id: String, version: String) -> DotResult:
	var wanted := version

	if wanted == "":
		var latest: DotResult = await TmcSolo.resolve_latest(shell, content_id, shell._cloud.http_base_urls)
		if not latest.ok:
			return latest
		# A retired id resolves to the one it moved to; use that from here on.
		content_id = str(latest.value["id"])
		wanted = str(latest.value["version"])

	elif not (await shell._cloud.resolve_manifest(StringName(content_id), wanted)).ok:
		# The site pins the newest READY upload; the CDN may only hold a later one.
		var newest: DotResult = await TmcSolo.resolve_latest(shell, content_id, shell._cloud.http_base_urls)
		if newest.ok and TmcSolo.falls_back(wanted, str(newest.value["version"])):
			DotLog.warn(shell.CHANNEL, "pinned solo version has no manifest; using the newest published",
				{"content": content_id, "pinned": wanted, "using": newest.value["version"]})
			content_id = str(newest.value["id"])
			wanted = str(newest.value["version"])
	return DotResult.success({"id": content_id, "version": wanted})


func _load_solo_inner(content_id: String, version: String) -> DotResult:
	var pinned := await _pin_solo_version(content_id, version)
	if not pinned.ok:
		return pinned
	content_id = str(pinned.value["id"])
	var wanted := str(pinned.value["version"])

	shell._solo_id = content_id
	shell._solo_version = wanted
	DotLog.info(shell.CHANNEL, "starting solo", {"content": content_id, "version": wanted})

	# The game addons its pack requires (zee_weapons for Prop Hunt, fc_weapons for Fatal Contact; arena_weapons up to fc-weapons v1.4.51) are not in this shell: fetched as the overlay a server would announce, then a restart into it. Asked of the store before the pack is fetched, because the pack's own requirement check refuses it while one is missing. Returns only when nothing is missing or it cannot be had. Subscriptions are asked first (their downloads only registered): a game that accepts addon packs gets the subscribed ones in the same overlay, so one restart covers both.
	var subscribed: Array = await shell._solo_packs._solo_workshop_plan(content_id, wanted)
	var overlay: int = await _solo_overlay(content_id, await _solo_needs(content_id, wanted), subscribed)
	if overlay == SoloOverlay.RESTARTING:
		return DotResult.success(null)
	if overlay == SoloOverlay.BLOCKED:
		return DotResult.fail(DotError.CODE_STATE, shell._text("shell.solo.addons_blocked", {},
			"this game's addons did not start in this tab, so it was not started without them. Retry fetches them again."))
	if overlay == SoloOverlay.UNPUBLISHED:
		# Not the "needs a newer client" panel dot-cloud's requirement check would show next: no shell build can carry a game
		# addon (only dot-* addons), so the fix is a publish of that addon's pack, never a newer client.
		var why := "; ".join(PackedStringArray(_unpublished.values()))
		DotLog.error(shell.CHANNEL, "a game addon this solo game needs is not published in a pack that holds it", {
			"content": content_id, "version": wanted, "unpublished": _unpublished,
		})
		return DotResult.fail(DotError.CODE_STATE, shell._text("shell.solo.addon_unpublished", {"why": why},
			"this game needs an addon that is not published yet ({why}). Nothing was downloaded.".format({"why": why})))

	# Everything is registered and fetched first, so the total is fixed before a byte moves; mounting follows.
	await shell._solo_packs._prefetch_solo(content_id, wanted)
	shell._cloud.job_begin_unpack()

	# "*" asks for every download group (dot-cloud 22): a solo host serves any map. Older dot-cloud reads it as
	# a group no file has, which is what an empty list already fetched there.
	var got: DotResult = await shell._cloud.ensure(StringName(content_id), wanted, PackedStringArray(["*"]))
	if not got.ok:
		return got

	var mount := DotCloudClient.mount_prefix_for(StringName(content_id), wanted)
	var read := TmcSolo.read_descriptor(mount)
	if not read.ok:
		return read

	var desc: Dictionary = read.value
	var scene_rel := str(desc.get("client_scene", ""))

	if scene_rel == "":
		return DotResult.fail(DotError.CODE_INVALID,
			"This game names no client scene, so it cannot be played here.", mount)

	var safe := DotPaths.safe_relative(scene_rel)
	if not safe.ok:
		return DotResult.fail(DotError.CODE_INVALID, "This game's client scene is not a safe path.", scene_rel)

	var deps := await _fetch_solo_dependencies(desc)
	if not deps.ok:
		return deps
	var dep_keys: PackedStringArray = deps.value

	var session := _new_solo_session(content_id, wanted, mount, desc, dep_keys)

	var slice_keys := _solo_slice_keys(content_id, wanted, desc)
	await _add_solo_map_packs(session, content_id)
	shell._solo_pack_label = ""
	await _add_solo_subscriptions(session, content_id, mount)

	var path := mount.path_join(safe.value)
	shell._warm_hold = await shell._solo_packs._warm_pack(slice_keys)
	var packed: Variant = load(path)

	if not (packed is PackedScene):
		return DotResult.fail(DotError.CODE_IO, "The game's client scene would not load.", path)

	return _enter_solo_game(session, packed as PackedScene, desc, path)


## Puts the loaded solo session and its client scene into the tree and tells the shell the
## game is running.
func _enter_solo_game(session: TmcSoloSession, packed: PackedScene, desc: Dictionary, path: String) -> DotResult:
	var content_id := session.content_id
	shell.add_child(session)
	shell._solo_session = session
	DotRegistry.register(TmcSolo.MAPS_SERVICE, session)

	if not shell.get_tree().node_added.is_connected(shell._on_solo_node_added):
		shell.get_tree().node_added.connect(shell._on_solo_node_added)

	var instance := packed.instantiate()

	# A client that announces Leave rather than acting on it (`leave_requested`: "what leave
	# means belongs to whatever loaded this client") is answered here, as a server's game is
	# answered by its disconnect.
	if instance.has_signal(&"leave_requested"):
		instance.connect(&"leave_requested", shell._leave_solo, CONNECT_DEFERRED)

	shell._game_root.add_child(instance)

	shell._set_busy(false)
	shell._menu.visible = false
	shell._has_spawned = true
	shell.loading.end(TmcLoadingScreen.REASON_GAME)
	shell.loading.end(TmcLoadingScreen.REASON_CONTENT)
	shell._say("")
	shell._watch_game_ready()
	if session.takes_subscriptions:
		shell._sync_suggested_later(content_id, desc["suggested"] as PackedStringArray)

	var shown := session.display_name if session.display_name != "" else content_id
	if shell._solo_button != null:
		shell._solo_button.text = "Play %s solo" % shown
	if shell._friends != null:
		shell._friends.on_game_changed(shown, "")

	DotLog.info(shell.CHANNEL, "solo game started", {
		"content": "%s@%s" % [content_id, session.version], "scene": path, "maps": session.map_keys.size(),
	})
	return DotResult.success(instance)


## The session node for a solo game whose pack is mounted at [param mount].
func _new_solo_session(content_id: String, wanted: String, mount: String, desc: Dictionary, dep_keys: PackedStringArray) -> TmcSoloSession:
	var session := TmcSoloSession.new()
	session.name = "Solo"
	session.content_id = content_id
	session.version = wanted
	session.mount_root = mount
	session.display_name = str(desc.get("name", ""))
	session.start_map = StringName(shell._solo_map)
	session.leave_fn = shell._leave_solo
	session.pack_keys = dep_keys
	session.cache_dir = shell._cloud.config.cache_dir
	session.content_url = shell._user_arg("--content-url").strip_edges()
	return session


## The packs the game needs beside its own, by the rule a join fetches them: a key with
## no version is not one a server would send, and here it is resolved to the newest
## rather than refused, because nobody pinned it. The value is the fetched keys.
func _fetch_solo_dependencies(desc: Dictionary) -> DotResult:
	var dep_keys := PackedStringArray()
	for key in (desc["dependencies"] as PackedStringArray) + (desc["server_dependencies"] as PackedStringArray):
		var dep = await shell._solo_packs._ensure_solo_pack(key)
		if not dep.ok:
			return DotResult.fail(dep.error.code,
				"This game needs %s, which could not be downloaded." % key, str(dep.error))
		dep_keys.append(str(dep.value))
	return DotResult.success(dep_keys)


## The content keys the warm-up slices load: the game's own and each pinned dependency.
func _solo_slice_keys(content_id: String, wanted: String, desc: Dictionary) -> Array[String]:
	var slice_keys: Array[String] = [DotCloudClient.content_key_for(StringName(content_id), wanted)]
	for key in (desc["dependencies"] as PackedStringArray) + (desc["server_dependencies"] as PackedStringArray):
		var parts := TmcSolo.split_key(key)
		if str(parts["version"]) != "":
			slice_keys.append(DotCloudClient.content_key_for(StringName(parts["id"]), str(parts["version"])))
	return slice_keys


## The map packs a server owner would name, from the stock list. One that will not
## fetch is a map nobody can change to, not a game that will not start.
func _add_solo_map_packs(session: TmcSoloSession, content_id: String) -> void:
	var skip_maps := TmcSolo.skip_maps(content_id)
	if skip_maps:
		DotLog.info(shell.CHANNEL, "the player skips this game's maps pack", {"content": content_id})
	for key in (PackedStringArray() if skip_maps else await shell._solo_packs._solo_map_packs(content_id)):
		var maps = await shell._solo_packs._ensure_solo_pack(key, true, TmcSolo.map_groups(DotPlatform.is_web(), shell._solo_map))
		if not maps.ok:
			DotLog.warn(shell.CHANNEL, "a solo map pack could not be fetched", {
				"pack": key, "why": str(maps.error),
			})
			continue
		session.map_keys.append(str(maps.value))
		var parts := TmcSolo.split_key(str(maps.value))
		session.map_roots.append(DotCloudClient.mount_prefix_for(StringName(parts["id"]), parts["version"]))


## Subscribed packs, after the game's own and before its scene exists, so the scene's
## catalogues find every entry already in the index. A game that states no `accepts`
## takes none and is not asked about them.
func _add_solo_subscriptions(session: TmcSoloSession, content_id: String, mount: String) -> void:
	session.takes_subscriptions = not shell._game_accepts(mount).is_empty()
	if not session.takes_subscriptions:
		return
	if shell._deferred_workshop:
		var mounted: DotResult = await shell._ensure_workshop().mount_pending()
		session.workshop_summary = mounted.value as Dictionary if mounted.ok and mounted.value is Dictionary else {}
	else:
		# Subscribed content only: the suggested map packs are fetched after the scene is up.
		session.workshop_summary = await shell._sync_workshop(content_id)


## The server process a solo game started for itself ([method TmcSoloSession.sim_child_args]): the packs the shell that started it mounted, from the same cache, the session registered as that shell registers it, and the game's client scene, which hands over to its server. A failure quits with 1, and the game that started it plays in-process.
func _start_sim_child() -> void:
	# The overlay mounted at boot is the parent's: an unconfirmed boot would count against it.
	DotCloudAddonSet.confirm_boot()
	var started := await _load_sim_child()
	if not started.ok:
		DotLog.error(shell.CHANNEL, "the solo server process could not start its game", {"why": str(started.error)})
		shell.get_tree().quit(1)


func _load_sim_child() -> DotResult:
	var asked := TmcSolo.requested()
	var content_id := str(asked["id"])
	var version := str(asked["version"])
	if content_id == "" or version == "":
		return DotResult.fail(DotError.CODE_INVALID, "A solo server process needs --solo and --solo-version.")

	shell._cloud = shell._new_cloud()
	shell._cloud.config.side = "both"
	shell.add_child(shell._cloud)
	shell._adopt_content_url_arg()

	var got: DotResult = await shell._cloud.ensure(StringName(content_id), version, PackedStringArray(["*"]))
	if not got.ok:
		return got

	var session := TmcSoloSession.new()
	session.name = "Solo"
	session.content_id = content_id
	session.version = version
	session.mount_root = DotCloudClient.mount_prefix_for(StringName(content_id), version)
	session.cache_dir = shell._cloud.config.cache_dir
	session.start_map = StringName(str(asked.get("map", "")))

	for flag in [TmcSolo.PACKS_FLAG, TmcSolo.MAPS_FLAG]:
		for key in TmcSolo.child_keys(str(flag)):
			var parts := TmcSolo.split_key(key)
			if str(parts["version"]) == "" or not TmcSolo.valid_id(str(parts["id"])) or not TmcSolo.valid_version(str(parts["version"])):
				return DotResult.fail(DotError.CODE_INVALID, "Not a pinned pack key.", key)
			var pack: DotResult = await shell._cloud.ensure(StringName(parts["id"]), str(parts["version"]), PackedStringArray(["*"]))
			if not pack.ok:
				return pack
			if str(flag) == TmcSolo.MAPS_FLAG:
				session.map_keys.append(key)
				session.map_roots.append(DotCloudClient.mount_prefix_for(StringName(parts["id"]), str(parts["version"])))
			else:
				session.pack_keys.append(key)

	var read := TmcSolo.read_descriptor(session.mount_root)
	if not read.ok:
		return read
	var desc: Dictionary = read.value
	session.display_name = str(desc.get("name", ""))
	var safe := DotPaths.safe_relative(str(desc.get("client_scene", "")))
	if not safe.ok:
		return DotResult.fail(DotError.CODE_INVALID, "This game names no usable client scene.", session.mount_root)
	var path := session.mount_root.path_join(safe.value)
	var packed: Variant = load(path)
	if not (packed is PackedScene):
		return DotResult.fail(DotError.CODE_IO, "The game's client scene would not load.", path)

	shell.add_child(session)
	shell._solo_session = session
	DotRegistry.register(TmcSolo.MAPS_SERVICE, session)
	shell._game_root.add_child((packed as PackedScene).instantiate())
	DotLog.info(shell.CHANNEL, "solo server process started its game", {
		"content": "%s@%s" % [content_id, version], "packs": session.pack_keys.size(), "maps": session.map_keys.size(),
	})
	return DotResult.success(null)


## The addons a game's pack names (`addons` in its `requires.json` and `requires.floor.json`),
## read from the store before the pack is fetched: dir -> level. Empty when the pack has neither.
func _solo_needs(content_id: String, version: String) -> Dictionary:
	var needs := {}
	var game: DotResult = await shell._cloud.resolve_manifest(StringName(content_id), version)
	if not game.ok:
		return needs
	for file in SOLO_REQUIRE_FILES:
		var read: DotResult = await shell._cloud.read_pack_file(game.value as DotCloudManifest, file)
		if read.ok:
			needs.merge(solo_addons_in((read.value as PackedByteArray).get_string_from_utf8()))
	return needs


## The `addons` map of a requires file's text (dir -> level); empty for anything else.
static func solo_addons_in(text: String) -> Dictionary:
	var json := JSON.new()
	var out := {}
	if json.parse(text) != OK or not (json.data is Dictionary):
		return out
	var addons: Variant = (json.data as Dictionary).get("addons", {})
	if addons is Dictionary:
		for dir: Variant in addons:
			if dir is String and str(dir).is_valid_filename() and not str(dir).contains("."):
				out[dir] = addons[dir]
	return out


## The addons a solo game needs that this shell does not carry, as the announce a server would send (`announce`), which of them the player's subscription
## supplied (`from_subscription`: dir -> id), and which no published pack holds (`unpublished`: dir -> why, see [method pack_holds_dir]).
func _collect_solo_announce(content_id: String, needs: Dictionary, subscribed: Array) -> Dictionary:
	var announce: Array = []
	var from_subscription := {}
	var unpublished := {}
	for entry: Variant in subscribed:
		if not (entry is Dictionary):
			continue
		var dir := str(entry.get("dir", ""))
		if dir == "" or bool(entry.get("running", false)) or DirAccess.dir_exists_absolute("res://addons/%s" % dir):
			continue
		from_subscription[dir] = str(entry.get("id", ""))
		announce.append({"dir": dir, "repo": str(entry.get("repo", "")), "id": from_subscription[dir],
			"version": str(entry.get("version", ""))})
	for dir: String in needs:
		if from_subscription.has(dir):
			# The game needs what the player subscribed to; the subscription's checked version serves both.
			continue
		if DirAccess.dir_exists_absolute("res://addons/%s" % dir):
			continue
		var pack := TmcAddonNamespaces.pack_for(dir)
		var latest: DotResult = await TmcSolo.resolve_latest(shell, str(pack["id"]), shell._cloud.http_base_urls)
		if not latest.ok and str(pack["old_id"]) != "":
			# Before the site renamed the organisation's packs only the old id is published.
			latest = await TmcSolo.resolve_latest(shell, str(pack["old_id"]), shell._cloud.http_base_urls)
		if not latest.ok:
			DotLog.warn(shell.CHANNEL, "a game addon this solo game needs is not published", {
				"content": content_id, "dir": dir, "id": pack["id"], "why": str(latest.error),
			})
			continue
		# A retired id resolves to the one it moved to, whose name is the repo [DotCloudAddonSet] checks.
		var id := str(latest.value["id"])
		var version := str(latest.value["version"])
		# The newest published version must hold `addons/<dir>`: fc-weapons up to v1.4.51 holds the legacy arena_weapons, so
		# Fatal Contact 0.1.70 (fc_weapons 32) fetched 1.4.50, which [DotCloudAddonSet] refused as "not an addon pack".
		var manifest: DotResult = await shell._cloud.resolve_manifest(StringName(id), version)
		if manifest.ok:
			var why := pack_holds_dir(dir, id, version, manifest_paths(manifest.value as DotCloudManifest))
			if why != "":
				unpublished[dir] = why
				continue
		announce.append({"dir": dir, "repo": id.get_file(), "id": id, "version": version})
	_unpublished = unpublished
	return {"announce": announce, "from_subscription": from_subscription, "unpublished": unpublished}


## Every path [param manifest] lists.
static func manifest_paths(manifest: DotCloudManifest) -> PackedStringArray:
	var out := PackedStringArray()
	if manifest != null:
		for f in manifest.files:
			out.append(f.path)
	return out


## Why the pack [param id] at [param version], whose files are [param paths], cannot supply `addons/<dir>`; empty when it can.
## It can when it is the addon itself (a `plugin.cfg` at its root) or holds `addons/<dir>/plugin.cfg`, which is what
## [DotCloudAddonSet] mounts; a pack that holds the addon under another directory (a renamed repository's older tags) cannot.
static func pack_holds_dir(dir: String, id: String, version: String, paths: PackedStringArray) -> String:
	if paths.has("plugin.cfg") or paths.has("addons/%s/plugin.cfg" % dir):
		return ""
	var holds := PackedStringArray()
	for path in paths:
		var parts := path.split("/")
		if parts.size() == 3 and parts[0] == "addons" and parts[2] == "plugin.cfg":
			holds.append("addons/" + parts[1])
	if holds.is_empty():
		return "%s %s, the newest published, holds no addon, and this game needs addons/%s" % [id, version, dir]
	return "%s %s, the newest published, holds %s, and this game needs addons/%s" % [id, version, ", ".join(holds), dir]


## The addons in [param needs] (from [method _solo_needs]) that this shell neither carries nor has mounted, fetched as the overlay a server would announce. When it only adds addons to this process (a first visit, a new shell build) it is mounted here and the game starts ([method _mount_in_place]); otherwise it is restarted into, as [method _update_addons] does for a join. [constant SoloOverlay.RESTARTING] when a restart is under way (the caller stops there); [constant SoloOverlay.NONE] when nothing is missing or it is mounted here; [constant SoloOverlay.BLOCKED] when the addons are missing and cannot be had now: after a failed start on the same overlay in this shell build, after [constant MAX_UPDATE_RESTARTS] restarts for it, or when building it failed. Blocked never plays on: the game's scripts do not parse without its addons, which leaves PLAYLOT on a black screen. The caller fails the start and the solo button becomes Retry ([member _solo_retry]). [param subscribed] are the Workshop's `summary.addons` (dot-cloud 28): approved addon packs of a game whose `accepts.kinds` has `addon`, already checked against the build's own addons. They join the overlay under their exact ids and are marked `source: "subscription"` in the plan, which [method _restart_for_online] drops.
func _solo_overlay(content_id: String, needs: Dictionary, subscribed: Array = []) -> SoloOverlay:
	var found := await _collect_solo_announce(content_id, needs, subscribed)
	var announce: Array = found["announce"]
	var from_subscription: Dictionary = found["from_subscription"]
	if not (found["unpublished"] as Dictionary).is_empty():
		return SoloOverlay.UNPUBLISHED
	if announce.is_empty():
		return SoloOverlay.NONE

	var addons := DotCloudAddonSet.new(shell._cloud)
	addons.namespaces = TmcAddonNamespaces.load_shell()
	for dir: String in from_subscription:
		# The site approved this exact pack for this player; that, not a namespace, is why it is taken.
		addons.namespaces.append(str(from_subscription[dir]))
	var decided := addons.plan_for(announce)
	var wanted: Dictionary = decided["wanted"]
	mark_subscribed(wanted, from_subscription)

	if not (decided["refused"] as Dictionary).is_empty():
		DotLog.warn(shell.CHANNEL, "solo game addons not taken", {"content": content_id, "refused": decided["refused"]})

	var target := "solo:%s" % content_id

	if wanted.is_empty():
		shell._clear_update_attempts(target)
		return SoloOverlay.NONE

	var attempt = shell._attempt_key(target, wanted)
	if shell._overlay_blocked(attempt, wanted):
		DotLog.warn(shell.CHANNEL, "this solo game's addons did not start here; not starting it without them", {
			"content": content_id, "addons": wanted.keys(), "failed": shell._overlay_failed_here(wanted),
			"restarts": shell._update_attempts(attempt),
		})
		shell._solo_retry = attempt
		return SoloOverlay.BLOCKED

	DotLog.info(shell.CHANNEL, "this solo game needs addons the shell does not carry; fetching them", {
		"content": content_id, "addons": wanted.keys(),
	})
	shell._say(shell._text("shell.addons.updating_solo", {}, "Adding this game's addons…"))
	shell.loading.set_progress(-1.0, shell._text("shell.addons.updating_solo", {}, "Adding this game's addons…"))

	# Where to come back to: the page's `?solo=` names the game too, but a menu launch has no address.
	var resume := {"solo": content_id, "solo_version": shell._solo_version, "solo_map": shell._solo_map}
	if shell._auth != null and shell._auth.is_signed_in() and shell._auth.identity() != null:
		resume["member"] = shell._auth.identity().uid

	var built: DotResult = await addons.build(wanted, resume)
	if not built.ok and plan_holds_subscription({"addons": wanted}):
		# A subscription is optional: one broken pack must not stop solo play. Retry once with the game's own needs.
		var dropped: Array = []
		for dir: Variant in wanted:
			if wanted[dir] is Dictionary and str((wanted[dir] as Dictionary).get("source", "")) == SUBSCRIPTION_SOURCE:
				dropped.append(str((wanted[dir] as Dictionary).get("id", dir)))
		DotLog.warn(shell.CHANNEL, "a subscribed addon could not be fetched; playing without the subscribed addons", {
			"content": content_id, "dropped": dropped, "why": str(built.error),
		})
		wanted = without_subscribed(wanted)
		if wanted.is_empty():
			shell._clear_update_attempts(target)
			return SoloOverlay.NONE
		attempt = shell._attempt_key(target, wanted)
		built = await addons.build(wanted, resume)
	if not built.ok:
		DotLog.error(shell.CHANNEL, "could not fetch this solo game's addons", {"content": content_id, "why": str(built.error)})
		shell._solo_retry = attempt
		return SoloOverlay.BLOCKED

	shell._stamp_plan()

	# A first visit, or the first start on a new shell build, has none of these addons in this process: mount them here and play on, rather than reload the page and fetch the shell again. A restart stays for an overlay that would replace a mounted addon: a compiled script is never read again. It also stays for a workshop subscription (never on a first visit): an online join drops that overlay, and only a restart unmounts it.
	if shell._overlay_additive(built.value) and not plan_holds_subscription(built.value) \
			and not plan_holds_subscription({"addons": wanted}):
		match shell._mount_in_place():
			shell.InPlace.RUNNING:
				shell._clear_update_attempts(target)
				return SoloOverlay.NONE
			shell.InPlace.STALE:
				shell._solo_retry = attempt
				return SoloOverlay.BLOCKED

	shell._note_update_attempt(attempt)
	return await _restart_for_solo_addons(built.value, resume)

## Restarts into the overlay that carries a solo game's addons, keeping the files [param plan] names and the sign-in token.
func _restart_for_solo_addons(plan: Dictionary, resume: Dictionary) -> SoloOverlay:
	var keep := DotCloudAddonSet.plan_files(plan)
	if resume.has("member"):
		var tokens = shell._auth.config.token_store_path
		for token in [tokens, tokens + ".salt"]:
			if FileAccess.file_exists(token):
				keep.append(token)

	shell._say(shell._text("shell.addons.restarting", {}, "Restarting to finish the update…"))
	if await shell._restart(keep):
		return SoloOverlay.RESTARTING
	# Without its addons the game's scripts do not parse: say so rather than start a grey screen.
	# A browser that cannot store the overlay (a full quota; before dot-cloud 0.1.47 any overlay over 127 MiB) stops here.
	shell.loading.set_progress(-1.0, shell._text("shell.addons.unsaved_solo", {}, "This browser could not keep the addons this game needs, so it cannot start here yet."))
	return SoloOverlay.RESTARTING


## Marks each entry of a [method DotCloudAddonSet.plan_for] `wanted` that came from a subscription ([param from_subscription]:
## dir -> id) with `source: "subscription"`, which [method DotCloudAddonSet.build] keeps in the plan.
static func mark_subscribed(wanted: Dictionary, from_subscription: Dictionary) -> void:
	for dir: Variant in wanted:
		var entry: Variant = wanted[dir]
		if entry is Dictionary and from_subscription.get(dir, "") == str((entry as Dictionary).get("id", "")) and str(from_subscription.get(dir, "")) != "":
			(entry as Dictionary)["source"] = SUBSCRIPTION_SOURCE


## [param wanted] without the entries a subscription put there (marked by [method mark_subscribed]); a new Dictionary, the entries are shared.
static func without_subscribed(wanted: Dictionary) -> Dictionary:
	var kept := {}
	for dir: Variant in wanted:
		var entry: Variant = wanted[dir]
		if not (entry is Dictionary and str((entry as Dictionary).get("source", "")) == SUBSCRIPTION_SOURCE):
			kept[dir] = entry
	return kept


## Whether an overlay plan holds an addon a player's subscription put there: such a plan never boots into an online session.
static func plan_holds_subscription(plan: Dictionary) -> bool:
	var addons: Variant = plan.get("addons", {})
	if addons is Dictionary:
		for dir: Variant in addons:
			var entry: Variant = (addons as Dictionary)[dir]
			if entry is Dictionary and str((entry as Dictionary).get("source", "")) == SUBSCRIPTION_SOURCE:
				return true
	return false


const SUBSCRIPTION_SOURCE := "subscription"


## Where a game's pack names the addons it needs (and their API floors): the hard requirements
## dot-cloud checks before mounting, and the floors it was built against.
const SOLO_REQUIRE_FILES: PackedStringArray = ["requires.json", "requires.floor.json"]
