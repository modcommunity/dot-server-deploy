extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Hide & Seek is a
# delivered pack at `res://dot_cloud/tmc/hideseek/<version>/…`, and its maps are a second pack
# at `res://dot_cloud/tmc/hideseek_maps/<version>/…`. Everything about the game is reached
# through the host's module table and `describe()`, as deathrun_client does.

## A REAL client, over a REAL socket, in a DELIVERED Hide & Seek, with its maps delivered as a
## server-only pack beside it.
##
## [codeblock]
## godot --headless --path . res://examples/hideseek_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/hideseek` and `dist/tmc/hideseek_maps`
## (`./server pack hideseek_maps --source games/hide-n-seek-maps`, then hideseek).
##
## [b]What only this can see.[/b] game-hide-n-seek's suites run inside its own project, where its
## maps are a link at `res://maps` and its props, their measured sizes and its taunts are files
## at `res://`. Delivered, every one of those is somewhere else: the game is mounted under a
## versioned prefix and must find its catalogue, its models and its taunt list through
## `HsPaths.rebase`, and the maps are `server_dependencies` mounted on the server alone, found
## only if the prefix the game computes from the pinned key is where the pack really mounted. A
## wrong guess at any of them is silent: a server that plays only the practice house, a
## catalogue of nothing so every map is built bare, a taunt list nobody can play. So this
## asserts each one from the delivered process, and that the client, never sent a map file,
## built the same map, with every prop in it, from the document.

const CONFIG := "res://examples/fixtures/hideseek"
const CONTENT := "res://content"
const DATA := "user://tmc_hideseek_client"

const GAME := "hideseek"
const CONTENT_ID := "tmc/hideseek"
const MAPS_KEY := "tmc/hideseek_maps@0.1.0"
const MODULE := "hideseek"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 22

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
	print("dot-server-deploy: a real client in a delivered Hide & Seek")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/hideseek")) \
			or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/hideseek_maps")):
		print("skipped: dist/tmc/hideseek and dist/tmc/hideseek_maps are not published here")
		print("  ./server pack hideseek_maps --source games/hide-n-seek-maps")
		print("  ./server pack hideseek --source games/game-hide-n-seek")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			await _test_the_packs_mounted()
			await _test_the_maps_arrived()
			await _test_the_client_builds_the_map()
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

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.auto_start = false
	add_child(_host)

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

		remove_child(_host)
		_host.queue_free()
		_host = null

	await get_tree().process_frame


# --- Sections ---------------------------------------------------------------

func _test_connect() -> bool:
	_section("a client connects to a delivered game")

	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Hider"
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
	_check(path.begins_with("res://dot_cloud/tmc/hideseek/"), "its module is the mounted copy", path)

	var server_only: PackedStringArray = _server().games.current_server_dependencies()
	_check(server_only.has(MAPS_KEY), "the maps are its server-only dependency", str(server_only))

	var file := DotCloudClient.mount_prefix_for(&"tmc/hideseek_maps", "0.1.0").path_join("maps/hs_apartments.json")
	_check(FileAccess.file_exists(file), "and are mounted where the game computes they are", file)
	_done()


## The maps are content, the props are the game's: both read out of their mounts.
func _test_the_maps_arrived() -> void:
	_section("the delivered maps, props and taunts are what the server plays with")

	var world := _world()
	var said := _says(world)
	_check(int(said.get("maps", 0)) >= 5, "the server read the delivered maps", "%s maps" % said.get("maps", 0))

	var props: Variant = world.get("props_catalogue") if world != null else null
	var props_said: Dictionary = (props as Object).call("describe") if props is Object else {}
	_check(int(props_said.get("props", 0)) > 100, "and the prop catalogue, from inside its own mount",
		str(props_said))

	var taunts: Variant = world.call("taunt_ids") if world != null else []
	_check((taunts as Array).size() >= 10, "and the taunt list", "%d taunts" % (taunts as Array).size())

	var started := await _until(func() -> bool: return int(_says(_world()).get("round", 0)) > 0, 40.0)
	_check(started, "a round begins")

	var map := str(_says(_world()).get("map", ""))
	_check(map.begins_with("hs_"), "on a map", map)

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
	_check(_refused[0] == "", "and the client is still connected", _refused[0])
	_done()


func _test_still_serving() -> void:
	_section("the game's own console still answers")

	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server().console.execute("hs_maps", context)

	var listed := "\n".join(captured)
	_check(listed.contains("hs_apartments") and listed.contains("hs_park"),
		"hs_maps lists the delivered maps", listed)
	_done()
