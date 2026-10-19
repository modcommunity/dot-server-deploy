extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Zombie Zone is a
# delivered pack at `res://dot_cloud/tmc/zombiezone/<version>/…`, and its maps are a second pack
# at `res://dot_cloud/tmc/zombiezone_maps/<version>/…`. Everything about the game is reached
# through the host's module table and `describe()`, as hideseek_client does.

## A REAL client, over a REAL socket, in a DELIVERED Zombie Zone, with its maps delivered as a
## server-only pack beside it.
##
## [codeblock]
## godot --headless --path . res://examples/zombiezone_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/zombiezone` and `dist/tmc/zombiezone_maps`
## (`./server pack zombiezone_maps --source games/zombie-zone-maps`, then zombiezone), and an
## `addons/zed_weapons` beside `addons/zee_weapons`: the game carries both weapon packs.
##
## [b]What only this can see.[/b] game-zombie-zone's suites run inside its own project, where its
## maps are a link at `res://maps` and its props, zombie bodies, sounds and box file are files at
## `res://`. Delivered, every one is somewhere else, found through `ZzPaths.rebase`, and the
## maps are `server_dependencies` found only if the prefix the game computes from the pinned key
## is where the pack really mounted. A wrong guess is silent: a server that plays only the
## practice street, a box file of nothing, a map built bare. And the zombies are the server's
## alone, so a client that draws none is a client the replication never reached. So this asserts
## each one from the delivered process, and that the client, never sent a map file, built the
## same map with every prop in it and draws the server's zombies.

const CONFIG := "res://examples/fixtures/zombiezone"

## The server in a World3D of its own, away from the client in this process. See the helper.
const ServerWorld := preload("res://examples/server_world.gd")
const CONTENT := "res://content"
const DATA := "user://tmc_zombiezone_client"

const GAME := "zombiezone"
const CONTENT_ID := "tmc/zombiezone"
const MAPS_KEY := "tmc/zombiezone_maps@0.1.0"
const MODULE := "zombiezone"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 27

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _client_side: Node = null
var _link: DotClientLink = null

# Through Arrays: a GDScript lambda captures locals by value.
var _spawned := [false]
var _refused := [""]


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: a real client in a delivered Zombie Zone")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/zombiezone")) \
			or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/zombiezone_maps")) \
			or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://addons/zed_weapons")):
		print("skipped: dist/tmc/zombiezone, dist/tmc/zombiezone_maps or addons/zed_weapons is not here")
		print("  ./server pack zombiezone_maps --source games/zombie-zone-maps")
		print("  ./server pack zombiezone --source games/game-zombie-zone")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			await _test_the_packs_mounted()
			await _test_the_maps_arrived()
			await _test_the_client_builds_the_map()
			await _test_teammate_cvar_reaches_the_client()
			_test_still_serving()

	await _teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered]
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a section that aborted part-way stops adding checks, and only a total can show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- The harness ------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _server() -> DotServer:
	return _host.server as DotServer


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


## The server's world, through the module's `game` — dot-game's own name for it.
func _world() -> Node:
	var module: DotModule = _server().modules.get_module(MODULE)
	return module.get("game") as Node if module != null else null


func _says(world: Object) -> Dictionary:
	if world == null or not world.has_method("describe"):
		return {}

	return world.call("describe") as Dictionary


## The CLIENT's world: the delivered client scene under the link's `GameRoot`, whose `game`
## property is the world it built. Found by walking, because nothing here can name its type.
func _client_world() -> Object:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null

	if root == null:
		return null

	for child in root.get_children():
		var world: Variant = child.get("game")

		if world is Object and (world as Object).has_method("describe"):
			return world

	return null


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	print("")
	print("booting")

	# Pinned to the hand-built maps: the imported ones (ze_*, zs_*) have no props, and this suite
	# checks props. Without the pin the server picks any shipped map, so the result depended on
	# which one came up. Layered env var of the game's own config (ZzConfig.map_ids).
	OS.set_environment("ZZ_MAP_IDS", "zz_blackout_1,zz_blackout_2,zz_blackout_3,zz_chapel,zz_high_school,zz_lot,zz_mall,zz_relief_camp,zz_stadium")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.auto_start = false
	ServerWorld.add(self, _host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not _check(started.ok, "the host boots", str(started.error)):
		return false

	var reached := await _until(
		func() -> bool:
			var current := _server().games.current()
			return current != null and current.game_id == GAME \
				and _server().games.phase == DotGameManager.Phase.IDLE,
		45.0
	)

	if not _check(reached, "and reaches the delivered game"):
		return false

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())
	return true


## The client first, a frame, then the host: the client holds the delivered scene, and
## freeing the host first leaves it alive and reported as leaked. See smash_client.
func _teardown() -> void:
	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("test over")

	await get_tree().process_frame

	if _client_side != null and is_instance_valid(_client_side):
		remove_child(_client_side)
		_client_side.queue_free()
		_client_side = null
		_link = null

	await get_tree().process_frame

	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")

		ServerWorld.remove(_host)
		_host.queue_free()
		_host = null

	await get_tree().process_frame


# --- Sections ---------------------------------------------------------------

func _test_connect() -> bool:
	_section("a client connects to a delivered game")

	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Survivor"
	_client_side.add_child(_link)

	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _refused[0] = reason)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % _host.config.server.port)

	if not _check(connecting.ok, "it starts connecting", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(func() -> bool: return _spawned[0] or _refused[0] != "", 45.0)

	if not _check(admitted and _spawned[0], "and finishes signon", "refused: %s" % _refused[0]):
		_done()
		return false

	_done()
	return true


func _test_the_packs_mounted() -> void:
	_section("the game and its maps are mounted where the game looks")

	var entry := _server().games.current()
	_check(entry != null and String(entry.content_id) == CONTENT_ID, "the current game is the delivered one")

	var module: DotModule = _server().modules.get_module(MODULE)
	var script: Variant = module.get_script() if module != null else null
	var path := String((script as Resource).resource_path) if script != null else ""
	_check(path.begins_with("res://dot_cloud/tmc/zombiezone/"), "its module is the mounted copy", path)

	var server_only: PackedStringArray = _server().games.current_server_dependencies()
	_check(server_only.has(MAPS_KEY), "the maps are its server-only dependency", str(server_only))

	var file := DotCloudClient.mount_prefix_for(&"tmc/zombiezone_maps", "0.1.0").path_join("maps/zz_blackout_1.json")
	_check(FileAccess.file_exists(file), "and are mounted where the game computes they are", file)
	_done()


## The maps are content, the props, the boxes and both weapon packs are the game's: all read
## out of their mounts.
func _test_the_maps_arrived() -> void:
	_section("the delivered maps, props, boxes and weapons are what the server plays with")

	var world := _world()
	var said := _says(world)
	_check(int(said.get("maps", 0)) >= 6, "the server read the delivered maps", "%s maps" % said.get("maps", 0))

	var props: Variant = world.get("props_catalogue") if world != null else null
	var props_said: Dictionary = (props as Object).call("describe") if props is Object else {}
	_check(int(props_said.get("props", 0)) > 200, "and the prop catalogue, from inside its own mount",
		str(props_said))

	var boxes: Variant = world.get("boxes") if world != null else null
	var boxes_said: Dictionary = (boxes as Object).call("describe") if boxes is Object else {}
	_check(int(boxes_said.get("types", 0)) >= 8, "and the box file", str(boxes_said))

	_check(ZeeWeaponPack.table().has(&"pump_shotgun") and ZeeWeaponPack.table().has(&"pistol"),
		"and both weapon packs, the second installed by the delivered game")

	var started := await _until(func() -> bool: return int(_says(_world()).get("round", 0)) > 0, 40.0)
	_check(started, "a map begins")

	var map := str(_says(_world()).get("map", ""))
	_check(map.begins_with("zz_") and map != "zz_practice", "a delivered one, not the practice street", map)

	var players := int(_says(_world()).get("players", 0))
	_check(players >= 3, "with stand-ins beside the client", "%d players" % players)
	_done()


## The client was never sent a map file. It built the map from the document the server sent,
## and it is the same map with every prop in it: the client's prop catalogue, read from the
## mounted game, knows every id the delivered map names.
func _test_the_client_builds_the_map() -> void:
	_section("the client builds the map from the document it was sent")

	var arrived := await _until(
		func() -> bool:
			var world := _client_world()
			return world != null and str(_says(world).get("map", "-")) != "-" \
				and str(_says(world).get("map", "")) == str(_says(_world()).get("map", ""))
				,
		30.0
	)

	_check(arrived, "the client's world has the map the server is running",
		"%s vs %s" % [_says(_client_world()).get("map", "?"), _says(_world()).get("map", "?")])

	var client_map: Variant = _client_world().get("map") if _client_world() != null else null
	var server_map: Variant = _world().get("map")
	var built := int((client_map as Object).get("props").size()) if client_map is Object else -1
	var server_built := int((server_map as Object).get("props").size()) if server_map is Object else -2
	_check(built > 0 and built == server_built, "with every prop built", "%d of %d" % [built, server_built])

	var missing: Variant = (client_map as Object).get("_missing") if client_map is Object else null
	_check(missing is PackedStringArray and (missing as PackedStringArray).is_empty(),
		"and none of them missing from the client's catalogue", str(missing))

	var catalogue: Variant = _client_world().get("catalogue") if _client_world() != null else null
	_check(catalogue == null or int((catalogue as Object).get("maps").size()) <= 1,
		"and no delivered map files of its own")
	var zombies := await _until(func() -> bool: return _client_zombies() > 0, 30.0)
	_check(zombies, "and draws the server's zombies", "%d drawn" % _client_zombies())
	_check(_refused[0] == "", "and the client is still connected", _refused[0])
	_done()


## How many zombies the client's bridge draws: the server's, replicated.
func _client_zombies() -> int:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null

	if root == null:
		return 0

	for child in root.get_children():
		var bridge: Variant = child.get("bridge")

		if bridge is Object and (bridge as Object).has_method("zombie_count"):
			return int((bridge as Object).call("zombie_count"))

	return 0


func _test_still_serving() -> void:
	_section("the game's own console still answers")

	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server().console.execute("zz_maps", context)

	var listed := "\n".join(captured)
	_check(listed.contains("zz_blackout_1") and listed.contains("zz_lot"),
		"zz_maps lists the delivered maps", listed)
	_done()


## [b]dot-combat's `mp_teammate_passthrough` on the delivered client.[/b] The client traces its
## own shots for tracers and impacts; on its default 1 against a server on 0 or 2 they ended in,
## or went through, a team-mate where the server's shot did the opposite. The game's client
## calls `game.combat.follow_cvars(link)`, and this is the only place that call runs out of a
## mount against a real server: the game's own suites only see the cvar flagged replicated.
func _test_teammate_cvar_reaches_the_client() -> void:
	_section("the server's mp_teammate_passthrough reaches the client's combat, live")

	var cvar: DotConVar = _server().console.find_cvar("mp_teammate_passthrough")
	var held := cvar.get_string() if cvar != null else ""
	_check(cvar != null and cvar.has_flag(DotConVar.FLAG_REPLICATED)
		and await _until(func() -> bool: return _client_pass_through() == int(held), 10.0),
		"the delivered game's cvar is replicated and the client joined on its level",
		"server %s, client %d" % [held, _client_pass_through()])

	var _two := _server().console.set_cvar("mp_teammate_passthrough", "2")
	_check(await _until(func() -> bool: return _client_pass_through() == 2, 10.0),
		"the server goes to 2 and the client's combat rules follow", "client %d" % _client_pass_through())

	var _zero := _server().console.set_cvar("mp_teammate_passthrough", "0")
	_check(await _until(func() -> bool: return _client_pass_through() == 0, 10.0),
		"and to 0", "client %d" % _client_pass_through())

	if held != "":
		var _back := _server().console.set_cvar("mp_teammate_passthrough", held)
	_done()


## The client's `game.combat.rules.pass_through_level()`, found by walking the link's
## `GameRoot` (nothing here can name the game's types); -1 when there is none.
func _client_pass_through() -> int:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null

	if root == null:
		return -1

	for child in root.get_children():
		var world: Variant = child.get("game")
		var combat: Variant = (world as Object).get("combat") if world is Object else null
		var rules: Variant = (combat as Object).get("rules") if combat is Object else null

		if rules is Object and (rules as Object).has_method("pass_through_level"):
			return int((rules as Object).call("pass_through_level"))

	return -1
