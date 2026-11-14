extends Node

## Subscribed packs in solo play, through the REAL client shell: a solo start mounts what the player
## subscribed to and the game's map catalogue sees it; an online start of the same game never asks
## and sees none of it. A game whose accepts name `addon` takes a subscribed addon pack into its solo overlay,
## and an online join drops that overlay.

const WORK := "user://tmc_workshop_solo"
const SHELL := "res://client/shell.tscn"
const GAME := "gamemann/ws-game"
const CHECKS := 88
const ACCEPTS := {"kinds": ["map", "script"], "map_kinds": ["sandbox"]}
const ADDON_GAME := "gamemann/ws-addgame"
const ADDON_ACCEPTS := {"kinds": ["map", "addon"], "map_kinds": ["sandbox"]}
const HttpServer := preload("res://examples/fixtures/ws_http_server.gd")
const Backbone := preload("res://examples/fixtures/ws_backbone.gd")

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _key_pem := ""
var _content: Node = null
var _bb: Node = null
var _shell: Node = null
var _cloud: DotCloudClient = null
var _ws: DotCloudWorkshop = null
var _index: DotContentIndex = null
var _token := ""
var _items: Array = []
var _packs := {}
var _restarts := [0]
var _site_game := GAME
var _accepts: Dictionary = ACCEPTS


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: subscribed packs in solo play")
	DotPaths.remove_tree(WORK)
	DotCloudAddonSet.forget()

	if await _boot():
		await _test_guest()
		await _test_solo_with_subscription()
		await _test_the_panel()
		await _test_suggested_after_start()
		await _test_online_never_syncs()
		await _test_code_pack_restarts_first()
		await _test_subscribed_addon()
		await _test_addon_refused_without_opt_in()
		_test_subscription_marks()

	await _teardown()
	DotPaths.remove_tree(WORK)
	DotCloudAddonSet.forget()

	print("")
	print("%d sections, %d completed" % [_entered, _completed])
	_check(_completed == _entered, "every section ran to its last line (%d of %d)" % [_completed, _entered])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)

	var expected := CHECKS if _shots_dir() != "" else CHECKS - 1  # the cover check runs only with --shots
	if _passed + _failed != expected:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, expected])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)



func _boot() -> bool:
	_section("a shell, a content host, a fake site and four packs")

	var keys := DotCloudSignature.generate_keypair(2048)
	_check(keys.ok, "a signing key pair is generated")
	if not keys.ok:
		return false
	_key_pem = str((keys.value as Dictionary)["private"])

	_content = HttpServer.new()
	add_child(_content)
	_content.root = WORK.path_join("pub")
	_content.start(0)

	_bb = Backbone.new()
	add_child(_bb)
	_bb.handler = _site
	_bb.start()

	_make_game()
	_make_game(ADDON_GAME, "", ADDON_ACCEPTS)
	_make_pack("ws_map", "map")
	_make_pack("ws_prop", "prop")
	_make_pack("ws_code", "script", true)
	_make_pack("ws_quake", "addon", true)

	_index = DotContentIndex.shared()

	# The shell is configured BEFORE it enters the tree, so the cloud client and the Workshop
	# it places are not yet running when their folders and keys are set.
	_shell = (load(SHELL) as PackedScene).instantiate()
	_shell.set("workshop_backbone_url", _bb.base_url())
	_shell.call("_ensure_cloud")
	_cloud = _shell.get("_cloud")
	_cloud.config.cache_dir = WORK.path_join("cache")
	_cloud.config_file = ""
	_cloud.http_base_urls = PackedStringArray([_content.base_url()])
	var pub: String = str((keys.value as Dictionary)["public"])
	_cloud.config.trusted_keys = {"tmc": {"key": pub, "content_ids": ["ws_*", "gamemann/ws-*"]}}

	_ws = _shell.call("_ensure_workshop")
	_ws.config_file = ""
	_ws.config.workshop_timeout_sec = 8.0
	_ws.cache_dir = WORK.path_join("workshop")
	_ws.force_metered = 0
	_shell.set("restart_fn", func() -> void: _restarts[0] += 1)

	add_child(_shell)
	await get_tree().process_frame
	await get_tree().process_frame

	_check(_shell.get("_workshop") == _ws and _ws.cloud == _cloud, "the shell placed one Workshop beside its content client")
	_check(_ws.token_fn.is_valid() and _ws.ask_fn.is_valid(), "its bearer and its download question are the shell's")
	_check(_shell.call("_workshop_token") == "", "the shell's bearer is empty for a build with no sign-in")
	_check(_index.session() == DotContentIndex.SESSION_SOLO, "the index starts in the solo session")

	# The bearer the fake site knows, in place of a sign-in this process cannot perform.
	_ws.token_fn = func() -> String: return _token

	_done()
	return true


func _site(method: String, path: String, query: Dictionary, headers: Dictionary, _body: String) -> Dictionary:
	if method != "GET" or path != "/api/app/v1/workshop":
		return {"status": 404, "json": {}}
	return {"status": 200, "json": {
		"game": {"contentId": _site_game, "accepts": _accepts}, "account": "acct-alice",
		"revision": "w1:" + str(_items.size()), "unchanged": false, "full": true,
		"items": _items, "removed": [],
	}}


func _make_game(id: String = GAME, extra: String = "", accepts: Dictionary = ACCEPTS) -> void:
	var dir := WORK.path_join("src_" + id.replace("/", "_"))
	DotPaths.write_text(dir.path_join("game.yml"),
		"name: Workshop Game\ncontent_id: %s\nversion: 1.0.0\nclient_scene: game.tscn\n%s" % [id, extra])
	DotPaths.write_text(dir.path_join("game.tscn"),
		"[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://examples/workshop_solo_game.gd\" id=\"1\"]\n\n"
		+ "[node name=\"Game\" type=\"Node3D\"]\nscript = ExtResource(\"1\")\n")
	DotPaths.write_text(dir.path_join("provides.json"), JSON.stringify({
		"schema": 1, "title": "Workshop Game", "kinds": [], "accepts": accepts, "entries": []}))
	_publish(dir, id, "tmc")


func _make_pack(id: String, kind: String, code: bool = false) -> void:
	var dir := WORK.path_join("src_" + id)
	var entries: Array = []
	match kind:
		"map":
			DotPaths.write_text(dir.path_join("maps/m.tscn"), "[gd_scene format=3]\n\n[node name=\"M\" type=\"Node3D\"]\n")
			entries.append({"kind": "map", "id": "m", "name": id + " map", "scene": "maps/m.tscn", "map_kind": "sandbox"})
		"prop":
			DotPaths.write_text(dir.path_join("props/p.tscn"), "[gd_scene format=3]\n\n[node name=\"P\" type=\"Node3D\"]\n")
			entries.append({"kind": "prop", "id": "p", "name": id + " prop", "scene": "props/p.tscn"})
		"addon":
			# Laid out as a game addon released inside its project, as Zee's Natural Disasters is.
			DotPaths.write_text(dir.path_join("addons/%s/plugin.cfg" % id),
				"[plugin]\n\nname=\"%s\"\ndescription=\"\"\nauthor=\"test\"\nversion=\"1.0.0\"\nscript=\"\"\n" % id)
			DotPaths.write_text(dir.path_join("addons/%s/quake.gd" % id), "extends Node\n")
			entries.append({"kind": "addon", "id": id, "name": id, "dir": "addons/" + id})
		"script":
			DotPaths.write_text(dir.path_join("hooks/h.gd"), "extends Node\n")
			entries.append({"kind": "script", "id": "h", "name": id + " hook", "script": "hooks/h.gd", "hook": "playground"})
	DotPaths.write_text(dir.path_join("provides.json"), JSON.stringify({
		"schema": 1, "title": id, "kinds": [kind], "games": "*", "entries": entries}))
	_publish(dir, id, "tmc")
	_packs[id] = {"kind": kind, "code": code}


func _publish(dir: String, id: String, key_id: String) -> void:
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = "1.0.0"
	pub.signing_key_pem = _key_pem
	pub.signing_key_id = key_id
	var res := pub.publish(dir, str(_content.root).path_join(id))
	_check(res.ok, "fixture pack %s publishes" % id, str(res.error) if not res.ok else "")


## What the site would send as the asset's title.
func _title_of(id: String) -> String:
	match id:
		"ws_map":
			return "Harbour Blitz"
		"ws_prop":
			return "Crate Pack Deluxe"
	return id


func _item(id: String) -> Dictionary:
	var p: Dictionary = _packs[id]
	return {
		"subscriptionId": "sub-" + id, "assetId": 1, "name": _title_of(id), "scope": "all", "autoUpdate": true,
		"pack": {
			"contentId": id, "version": "1.0.0",
			"manifestUrl": "%s/%s/manifest.json" % [_content.base_url(), id],
			"bytes": 100, "kinds": [p["kind"]], "runsCode": p["code"], "approved": true, "keyId": "tmc",
		},
	}


func _requests() -> int:
	var n := 0
	for r in _bb.requests:
		if r["path"] == "/api/app/v1/workshop":
			n += 1
	return n


func _game_node() -> Node:
	return get_tree().get_first_node_in_group(&"ws_test_game")


func _session() -> TmcSoloSession:
	return _shell.get("_solo_session")



func _test_guest() -> void:
	_section("a guest plays solo with nothing subscribed")

	_token = ""
	_items = [_item("ws_map")]
	await _shell.call("_start_solo", GAME, "1.0.0")

	var session := _session()
	_check(session != null, "the game started")
	if session == null:
		_done()
		return
	_check(session.takes_subscriptions, "the game's provides.json says it takes subscriptions")
	_check(bool(session.workshop_summary.get("guest", false)), "the Workshop answered a guest")
	_check(_game_node() != null and _game_node().catalogue.size() == 0, "the game's catalogue holds no pack map")
	_check(not _cloud.is_mounted(&"ws_map", "1.0.0"), "the pack was not downloaded or mounted")
	_check(_cloud.is_mounted(StringName(GAME), "1.0.0"), "the game's own pack is mounted")

	_done()


func _test_solo_with_subscription() -> void:
	_section("a signed-in player's solo start mounts the subscribed map")

	_token = "tok-alice"
	_items = [_item("ws_map"), _item("ws_prop")]
	var asked := _requests()
	await _shell.call("_start_solo", GAME, "1.0.0")

	var session := _session()
	_check(session != null and _game_node() != null, "the game started")
	if session == null or _game_node() == null:
		_done()
		return
	var summary: Dictionary = session.workshop_summary
	var mounted: Array = []
	for m in summary.get("mounted", []):
		mounted.append(str(m["content_id"]))
	_check(_requests() == asked + 1, "the start asked the site once", str(_requests() - asked))
	_check(mounted == ["ws_map"], "only the pack the game accepts mounted", str(mounted))
	_check(_cloud.is_mounted(&"ws_map", "1.0.0"), "the map pack is mounted")
	_check(not _cloud.is_mounted(&"ws_prop", "1.0.0"), "the pack of a kind the game does not take is not")
	_check(_index.session() == DotContentIndex.SESSION_SOLO and _cloud.session_tag == DotContentIndex.SESSION_SOLO,
		"the index and the content client are in the solo session")
	var entry := _index.entry("ws_map@1.0.0:map/m")
	_check(entry != null and entry.source == &"subscription", "the index holds the map, as a subscription")
	var maps := _index.entries(&"map")
	_check(maps.size() == 1, "and the solo session offers it", str(maps.size()))
	var catalogue: DotMapCatalogue = _game_node().catalogue
	_check(catalogue.has(&"m"), "the game's catalogue lists the subscribed map")
	var def := catalogue.get_map(&"m")
	_check(def != null and def.content_id == &"ws_map" and FileAccess.file_exists(def.scene_path),
		"as a map whose scene is in the mounted pack", def.scene_path if def != null else "")
	_check(not session.workshop_summary.get("guest", true), "the summary says signed in")
	_check(not _ws.requires_restart_before_online(), "data packs need no restart before an online join")
	await _wait_cover_gone()
	await _shot("solo_with_pack_map")

	# A game that states no accepts is not asked at all.
	_check(_shell.call("_game_accepts", "res://nowhere").is_empty(), "a mount with no provides.json accepts nothing")

	_done()


func _test_the_panel() -> void:
	_section("the Subscriptions page on this state")

	var panel: TmcWorkshopPanel = _shell.call("_make_workshop_panel")
	add_child(panel)
	await get_tree().process_frame
	_check(panel.takes_subscriptions and panel.workshop == _ws, "the shell hands the page its Workshop and the game's state")
	var toggles := _toggles(panel)
	_check(toggles == 6, "two subscriptions, three switches each", str(toggles))
	_check(panel.find_child("Item_ws_map", true, false) != null, "a card for the mounted pack")
	var on := panel.item_state(_ws.last_list().items()[0])
	_check(str(on.get("id", "")) == "on", "the mounted pack reads as on", str(on))
	var off := panel.item_state(_ws.last_list().items()[1])
	_check(str(off.get("id", "")) != "on", "the pack the game does not take does not", str(off))
	await _panel_shot(panel, "panel")
	panel.queue_free()

	var sg := TmcWorkshopPanel.new()
	sg.workshop = _ws
	sg.takes_subscriptions = true
	add_child(sg)
	await get_tree().process_frame
	_check(sg.find_child("SuggestedMode", true, false) == null, "a game that suggests nothing gets no suggested switch")
	sg.queue_free()
	var kept_suggested: Array[Dictionary] = _ws.suggested
	_ws.suggested = DotCloudSuggested.from_ids("maps", PackedStringArray(["gamemann/x-maps"]))
	var sp := TmcWorkshopPanel.new()
	sp.workshop = _ws
	sp.takes_subscriptions = true
	sp.summary = {"guest": true, "mounted": []}
	add_child(sp)
	await get_tree().process_frame
	var pick: OptionButton = sp.find_child("SuggestedMode", true, false)
	_check(pick != null and pick.item_count == 2 and pick.selected == 0,
		"a game with suggested packs shows the switch, one map at a time by default, even for a guest")
	pick.item_selected.emit(1)
	_check(_ws.device.suggested_mode() == "all", "Download all in the background is the device mode all")
	await get_tree().process_frame
	pick = sp.find_child("SuggestedMode", true, false)
	_check(pick != null and pick.selected == 1, "and the page shows it after redrawing")
	pick.item_selected.emit(0)
	_check(_ws.device.suggested_mode() == "", "When a map is picked clears the device mode again")
	_check(not TmcWorkshopPanel.suggested_in_background("") and not TmcWorkshopPanel.suggested_in_background("none")
		and not TmcWorkshopPanel.suggested_in_background("ask") and TmcWorkshopPanel.suggested_in_background("maps"),
		"an old off or ask reads as one map at a time, a group list as background")
	sp.queue_free()
	_ws.suggested = kept_suggested

	# A guest's page, on a build with no sign-in at all (every native build today).
	var guest := TmcWorkshopPanel.new()
	guest.workshop = _ws
	guest.takes_subscriptions = true
	guest.summary = {"guest": true, "mounted": []}
	guest.no_sign_in = true
	add_child(guest)
	await get_tree().process_frame
	_check(_has_text(guest, "Sign in to use your subscriptions"), "a guest is told to sign in")
	_check(_has_text(guest, "cannot sign in yet"), "and on a build that cannot, that is said")
	_check(_toggles(guest) == 0, "and offered no switches")
	await _panel_shot(guest, "panel_guest")
	guest.queue_free()

	var none := TmcWorkshopPanel.new()
	none.workshop = _ws
	none.takes_subscriptions = false
	add_child(none)
	await get_tree().process_frame
	_check(_has_text(none, "takes no subscriptions"), "a game that takes none says so")
	none.queue_free()

	_done()


func _test_suggested_after_start() -> void:
	_section("a solo start never bulk-fetches or asks about the game's suggested packs")

	const GAME2 := "gamemann/ws-game2"
	_make_game(GAME2, "suggested:\n  - gamemann/ws-nope\n")
	_token = "tok-alice"
	_items = [_item("ws_map")]
	_ws.suggested = []
	_ws.device.set_suggested_mode("")
	var at_ready: Array[int] = [-1]
	Engine.set_meta(&"ws_ready_probe", func() -> void:
		at_ready[0] = _ws.suggested.size())
	await _shell.call("_start_solo", GAME2, "1.0.0")
	Engine.remove_meta(&"ws_ready_probe")

	_check(_session() != null and _game_node() != null, "the game started")
	_check(at_ready[0] == 0, "the game's scene came up before any suggested pack was declared", str(at_ready[0]))
	var asked := _requests()
	var late_seen := false
	for i in 30:
		late_seen = late_seen or bool(_shell.get("_late_sync"))
		await get_tree().process_frame
	_check(_ws.suggested.size() == 1, "the game's suggested packs are declared for the Subscriptions page", str(_ws.suggested.size()))
	_check(not late_seen and _requests() == asked and _shell.find_children("*", "ConfirmationDialog", true, false).is_empty(),
		"and by default nothing is fetched in bulk and nothing is asked: the game fetches each map when picked",
		str(_requests() - asked))

	const NONE := DotCloudSuggested.MODE_NONE
	var shell_script: GDScript = _shell.get_script()
	var groups := PackedStringArray(["maps"])
	_check(shell_script.late_suggested_mode("", PackedStringArray(), groups) == NONE
		and shell_script.late_suggested_mode("ask", PackedStringArray(), groups) == NONE
		and shell_script.late_suggested_mode("", PackedStringArray(["--suggested=ask"]), groups) == NONE,
		"no device choice, or ask, is one map at a time once a game runs")
	_check(shell_script.late_suggested_mode("all", PackedStringArray(), groups) == "all"
		and shell_script.late_suggested_mode("", PackedStringArray(["--suggested=all"]), groups) == "all"
		and shell_script.late_suggested_mode("all", PackedStringArray(["--no-suggested"]), groups) == NONE,
		"a device or command line all fetches in the background, --no-suggested still wins")

	# A device that chose "all": the background sync runs, never with a dialog, and leaves the config as it was.
	var kept_config: String = _ws.config.workshop_suggested
	_ws.device.set_suggested_mode("all")
	asked = _requests()
	await _shell.call("_sync_suggested_later", GAME2, PackedStringArray(["gamemann/ws-nope"]))
	_check(_requests() == asked + 1 and not bool(_shell.get("_late_sync")) and _ws.config.workshop_suggested == kept_config,
		"a device that chose all syncs in the background once and restores the config", str(_requests() - asked))
	_shell.set("_late_sync", true)
	var yes: bool = await _shell.call("_ask_download", {"bytes": 1 << 30, "metered": false})
	var no: bool = await _shell.call("_ask_download", {"bytes": 1 << 30, "metered": true})
	_shell.set("_late_sync", false)
	_check(yes and not no and _shell.find_children("*", "ConfirmationDialog", true, false).is_empty(),
		"a late sync opens no dialog over the game: it goes on, except on a metered link")
	_ws.device.set_suggested_mode("")

	_ws.suggested = []
	_done()


func _test_online_never_syncs() -> void:
	_section("an online start of the same game")

	var asked := _requests()
	_shell.call("_connect_to", "127.0.0.1:1")
	await get_tree().process_frame

	_check(_index.session() == DotContentIndex.SESSION_ONLINE and _cloud.session_tag == DotContentIndex.SESSION_ONLINE,
		"the index and the content client went to the online session")
	_check(_requests() == asked, "and the site was not asked", str(_requests() - asked))
	_check(_index.entries(&"map").is_empty(), "the index offers no map to the online session")

	# What the server's game does next: mounts the same game pack, now tagged online.
	var got: DotResult = await _cloud.ensure(StringName(GAME), "1.0.0")
	_check(got.ok, "the game's pack is reused for the join")
	var online_ids := PackedStringArray()
	for p in _index.packs(DotContentIndex.SESSION_ONLINE):
		online_ids.append(str(p["content_id"]))
	_check(online_ids.has(GAME) and not online_ids.has("ws_map"), "the game is online and the subscribed map pack is not", str(online_ids))

	var online_catalogue := DotMapCatalogue.new()
	online_catalogue.follow_content(_index, PackedStringArray(["sandbox"]))
	_check(not online_catalogue.has(&"m"), "a catalogue built for the online game does not list it")
	_index.set_session(DotContentIndex.SESSION_SOLO)
	online_catalogue.refresh_content()
	_check(online_catalogue.has(&"m"), "armed: the same catalogue lists it in the solo session")
	online_catalogue.unfollow_content()
	_index.set_session(DotContentIndex.SESSION_ONLINE)

	# The same game, started online: its scene built now, in the online session.
	if _shots_dir() != "":
		var online_game: Node = load("res://examples/workshop_solo_game.gd").new()
		add_child(online_game)
		await _shot("online_without")
		online_game.queue_free()

	_shell.call("_drop_link")
	await get_tree().process_frame
	_check(_shell.get("link") == null, "the failed join was dropped")

	_done()


func _test_code_pack_restarts_first() -> void:
	_section("a subscribed pack that runs code: restart before an online join")

	_token = "tok-alice"
	_items = [_item("ws_code")]
	await _shell.call("_start_solo", GAME, "1.0.0")
	_check(_ws.requires_restart_before_online(), "a mounted code pack asks for a restart")
	var session := _session()
	_check(session != null and (session.workshop_summary.get("mounted", []) as Array).size() == 1, "and it was mounted for solo play")

	var asked := _requests()
	_restarts[0] = 0
	_shell.call("_connect_to", "10.9.8.7:6064")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_restarts[0] == 1, "the shell restarted instead of joining", str(_restarts[0]))
	_check(_shell.get("link") == null, "no link was made")
	_check(_requests() == asked, "and nothing was synced")
	var plan := DotCloudAddonSet.read_plan()
	var resume: Variant = plan.get("resume", {})
	_check(resume is Dictionary and str((resume as Dictionary).get("server", "")) == "10.9.8.7:6064",
		"the restart carries the join, for the next start to take", str(resume))
	_check(_index.session() == DotContentIndex.SESSION_SOLO, "and no online session was entered with the code resident")

	# The next start takes it, once.
	var taken: Dictionary = _shell.call("_take_resume")
	_check(str(taken.get("server", "")) == "10.9.8.7:6064", "the next start reads where to go")
	_check((_shell.call("_take_resume") as Dictionary).is_empty(), "and only once")

	_done()


func _test_subscribed_addon() -> void:
	_section("a game that accepts addon packs: a subscribed addon joins the solo overlay")

	_token = "tok-alice"
	_site_game = ADDON_GAME
	_accepts = ADDON_ACCEPTS
	_items = [_item("ws_quake")]
	DotCloudAddonSet.forget()
	_restarts[0] = 0
	await _shell.call("_start_solo", ADDON_GAME, "1.0.0")

	_check(_restarts[0] == 1, "the solo start restarted into an overlay with the addon", str(_restarts[0]))
	var plan := DotCloudAddonSet.read_plan()
	var held: Variant = (plan.get("addons", {}) as Dictionary).get("ws_quake")
	_check(held is Dictionary and str((held as Dictionary).get("id", "")) == "ws_quake"
		and str((held as Dictionary).get("source", "")) == "subscription",
		"the plan holds the addon, marked as a subscription", str(plan.get("addons", {})))
	var shell_script: Script = _shell.get_script()
	_check(shell_script.call("plan_holds_subscription", plan), "so the plan holds a subscription")
	var resume: Variant = plan.get("resume", {})
	_check(resume is Dictionary and str((resume as Dictionary).get("solo", "")) == ADDON_GAME,
		"and the restart comes back into the same game", str(resume))

	# The next process booted on it; an online join from there drops the overlay instead of taking it along.
	# Data and code packs are out of the picture here: only the plan asks for this restart.
	_ws.set("_ran_code", false)
	_check(not _ws.requires_restart_before_online(), "no code pack asks for a restart")
	_restarts[0] = 0
	_shell.call("_connect_to", "10.9.8.7:6064")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_restarts[0] == 1 and _shell.get("link") == null, "the join restarted instead of joining", str(_restarts[0]))
	plan = DotCloudAddonSet.read_plan()
	_check(str(plan.get("state", "")) == "dropped" and not plan.has("addons") and not shell_script.call("plan_holds_subscription", plan),
		"the plan is dropped: the next start boots on the build alone", str(plan))
	resume = plan.get("resume", {})
	_check(resume is Dictionary and str((resume as Dictionary).get("server", "")) == "10.9.8.7:6064",
		"and still carries the join", str(resume))
	_shell.call("_take_resume")

	_site_game = GAME
	_accepts = ACCEPTS
	_done()


func _test_addon_refused_without_opt_in() -> void:
	_section("a game that does not accept addon packs refuses one and starts on its own")

	_token = "tok-alice"
	_items = [_item("ws_quake"), _item("ws_map")]
	DotCloudAddonSet.forget()
	_restarts[0] = 0
	await _shell.call("_start_solo", GAME, "1.0.0")

	_check(_restarts[0] == 0, "no restart", str(_restarts[0]))
	var session := _session()
	_check(session != null and _game_node() != null, "the game started")
	var refused := false
	if session != null:
		for f: Dictionary in session.workshop_summary.get("failed", []):
			refused = refused or (str(f.get("content_id", "")) == "ws_quake" and str(f.get("code", "")) == DotError.CODE_FORBIDDEN)
	_check(refused, "the addon pack is refused as forbidden",
		str(session.workshop_summary.get("failed", [])) if session != null else "")
	var shell_script: Script = _shell.get_script()
	_check(not shell_script.call("plan_holds_subscription", DotCloudAddonSet.read_plan()), "and no overlay holds it")

	_done()


func _test_subscription_marks() -> void:
	_section("the plan's subscription mark")

	var shell_script: Script = _shell.get_script()
	var wanted := {"a": {"id": "x/a"}, "b": {"id": "y/b"}}
	shell_script.call("mark_subscribed", wanted, {"a": "x/a", "b": "z/b"})
	_check(str(wanted["a"].get("source", "")) == "subscription", "an entry the subscription named is marked")
	_check(not (wanted["b"] as Dictionary).has("source"), "one whose id differs (the game's own requirement) is not")
	_check(not shell_script.call("plan_holds_subscription", {}) and not shell_script.call("plan_holds_subscription", {"addons": wanted["b"]}),
		"an empty or unmarked plan holds none")

	_done()



func _toggles(node: Node) -> int:
	var n := 0
	for child in node.find_children("*", "CheckButton", true, false):
		n += 1
	return n


func _has_text(node: Node, needle: String) -> bool:
	for l in node.find_children("*", "Label", true, false):
		if (l as Label).text.contains(needle):
			return true
	for b in node.find_children("*", "Button", true, false):
		if (b as Button).text.contains(needle):
			return true
	return false


## Pictures, only under `--shots <dir>` and a real renderer (see tools/workshop_shots.sh).
func _shots_dir() -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--shots")
	return args[at + 1] if at >= 0 and at + 1 < args.size() else ""


## The window, not the stretched viewport: the project stretches to 1280x720, so the viewport reads the same at any window width.
func image_size_of_window() -> Vector2i:
	return DisplayServer.window_get_size()


## Until the shell's loading screen is down (the cover keeps a game with no camera for up to
## 5 s), so the picture shows the game and not the screen over it. A suite without --shots
## does not wait.
func _wait_cover_gone() -> void:
	if _shots_dir() == "":
		return
	var loading: Variant = _shell.get("loading")
	var until := Time.get_ticks_msec() + 12000
	# The cover starts watching a game a frame or so after the start returns, so "no reason is
	# up" is true before it is up: wait for the game to be watched first.
	while is_instance_valid(_game_node()) and not _game_node().has_meta(&"tmc_warm_watched") \
			and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	while loading != null and is_instance_valid(loading) \
			and (loading.is_showing() or not (loading.describe().get("reasons", []) as Array).is_empty()) \
			and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	# It fades out: is_showing() is false from the first frame of the fade.
	var root: Variant = loading.get("_root") if loading != null else null
	while root is Control and is_instance_valid(root) and (root as Control).visible \
			and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	_check(loading == null or not loading.is_showing(), "the cover was gone before the picture")


func _shot(label: String) -> void:
	var dir := _shots_dir()
	if dir == "":
		return
	for i in 4:
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(dir)
	var size := Vector2(image_size_of_window())
	var image := get_viewport().get_texture().get_image()
	if image != null:
		image.save_png(dir.path_join("%s_%dx%d.png" % [label, int(size.x), int(size.y)]))


## The panel alone on an opaque page, scrolled the way the in-game menu scrolls it.
func _panel_shot(panel: Control, label: String) -> void:
	if _shots_dir() == "":
		return
	var layer := CanvasLayer.new()
	layer.layer = 100
	var back := ColorRect.new()
	back.color = Color(0.1, 0.11, 0.14)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(back)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	layer.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	panel.get_parent().remove_child(panel)
	scroll.add_child(panel)
	add_child(layer)
	await _shot(label)
	scroll.remove_child(panel)
	layer.queue_free()
	add_child(panel)


func _teardown() -> void:
	if _shell != null and is_instance_valid(_shell):
		_shell.queue_free()
	if _content != null:
		_content.stop()
	if _bb != null:
		_bb.stop()
	await get_tree().process_frame


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		_failures.append(label + (" (%s)" % detail if detail != "" else ""))
		print("  FAIL  %s%s" % [label, " -- " + detail if detail != "" else ""])
