extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Dangerous
# Delivery is a delivered pack at `res://dot_cloud/tmc/delivery/<version>/…`; everything about
# it is reached through the host's module table, `describe()` and duck typing.

## A REAL client, over a REAL socket, in a DELIVERED Dangerous Delivery.
##
## [codeblock]
## godot --headless --path . res://examples/delivery_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/delivery`
## (`./server pack delivery --source games/mg-dangerous-delivery`).
##
## [b]What only this can see.[/b] mg-dangerous-delivery's suites run inside its own project,
## where `res://routes` and `res://assets` are its own. Delivered, the routes and the truck
## models are wherever the pack mounted, and a game that named `res://routes` would boot a
## server with no routes and a client with box trucks. This asserts the server read every
## route out of the mount, that the client built them from the hello, and that a truck the
## client sets off in is driven by the client's own input across the socket.

const CONFIG := "res://examples/fixtures/delivery"
const CONTENT := "res://content"
const DATA := "user://tmc_delivery_client"

const GAME := "delivery"
const CONTENT_ID := "tmc/delivery"
const MODULE := "delivery"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 20

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
	print("dot-server-deploy: a real client in a delivered Dangerous Delivery")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/delivery")):
		print("skipped: dist/tmc/delivery is not published here")
		print("  ./server pack delivery --source games/mg-dangerous-delivery")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			_test_the_pack_mounted()
			await _test_the_routes_arrived()
			await _test_driving_across_the_socket()
			await _test_chat_crosses()
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
	_link.player_name = "Driver"
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


func _test_the_pack_mounted() -> void:
	_section("the game is mounted where it looks")

	var entry := _server().games.current()
	_check(entry != null and String(entry.content_id) == CONTENT_ID, "the current game is the delivered one")

	var module: DotModule = _server().modules.get_module(MODULE)
	var script: Variant = module.get_script() if module != null else null
	var path := String((script as Resource).resource_path) if script != null else ""
	_check(path.begins_with("res://dot_cloud/tmc/delivery/"), "its module is the mounted copy", path)
	_done()


## The routes are read out of the mount on the server, and built from the hello on the client.
func _test_the_routes_arrived() -> void:
	_section("every route, on both ends")

	var said := _says(_world())
	_check(int(said.get("routes", 0)) == 5, "the server read every route out of the mount", "%s" % said.get("routes", 0))

	var built := await _until(func() -> bool: return int(_says(_client_world()).get("routes", 0)) == 5, 30.0)
	_check(built, "and the client built them from the documents it was sent")

	var client := _client_scene()
	var garage: Variant = client.get("bridge").get("garage_view") if client != null and client.get("bridge") != null else {}
	_check(garage is Dictionary and ((garage as Dictionary).get("routes", []) as Array).size() == 5, "and has its garage")
	_done()


## The client sets off and drives: its keys (an override here) reach the server's truck, and
## the truck comes back to the client as the snapshot says.
func _test_driving_across_the_socket() -> void:
	_section("driving across the socket")
	var client := _client_scene()

	if not _check(client != null, "the delivered client scene is up"):
		_done()
		return

	client.call("_act", "start", {"route": "dd_foothills"})
	var key := StringName(str(client.get("bridge").get("local_key")))
	var world := _world()
	var on_road := await _until(func() -> bool:
		var driver: Variant = (world.get("drivers") as Dictionary).get(key)
		return driver != null and (driver as Object).call("on_road"), 15.0)
	_check(on_road, "the server set the client off", String(key))

	var go := DotVehicleCommand.new()
	go.throttle = 1.0
	client.set("command_override", go)
	var server_truck: Node3D = ((world.get("drivers") as Dictionary)[key] as Object).get("truck") if on_road else null
	var start := server_truck.global_position if server_truck != null else Vector3.ZERO
	var moved := await _until(func() -> bool:
		return server_truck != null and server_truck.global_position.distance_to(start) > 15.0, 20.0)
	_check(moved, "the client's throttle drives the server's truck",
		"%.1f m" % (server_truck.global_position.distance_to(start) if server_truck != null else 0.0))

	var client_world: Object = _client_world()
	var mirror: Variant = ((client_world.get("drivers") as Dictionary).get(key) as Object).get("truck") if client_world != null and (client_world.get("drivers") as Dictionary).has(key) else null
	var gap := (mirror as Node3D).global_position.distance_to(server_truck.global_position) if mirror is Node3D and server_truck != null else INF
	_check(gap < 4.0, "and the client's copy follows it", "%.2f m" % gap)

	# Waited for: the module seats stand-ins on its own two-second roster check, and a fast
	# drive can finish before the first one. The first version read 0 one run in three.
	var others := [0]
	var _seated := await _until(func() -> bool:
		others[0] = 0
		for other: Variant in (client_world.get("drivers") as Dictionary).keys():
			if StringName(str(other)) != key:
				others[0] += 1
		return others[0] == 1, 10.0)
	_check(others[0] == 1, "the client sees the stand-in, one less for the person who came", "%d" % others[0])
	_check(_refused[0] == "", "and is still connected", _refused[0])
	client.set("command_override", null)
	_done()


## A line typed in the client's box goes to the server's chat router and comes back to the
## client as the router addressed it: the wire, the services and the box, end to end.
func _test_chat_crosses() -> void:
	_section("chat crosses the socket")
	var client := _client_scene()
	var heard := [""]
	client.get("bridge").connect("chat_received", func(wire: Dictionary) -> void:
		heard[0] = str(wire.get("m", "")))
	client.get("chat").call("_on_submitted", "anyone on the pass?", &"all")
	var arrived := await _until(func() -> bool: return heard[0] == "anyone on the pass?", 10.0)
	_check(arrived, "a line the client typed comes back through the server's chat", heard[0])
	_check(int(client.get("chat").call("describe").get("lines", 0)) >= 1, "and is in the client's box")
	_done()


func _client_scene() -> Node:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null

	if root == null:
		return null

	for child in root.get_children():
		if child.get("game") is Object and child.has_method("_act"):
			return child

	return null


func _test_still_serving() -> void:
	_section("the game's own console still answers")

	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server().console.execute("dd_status", context)
	_check("\n".join(captured).contains("dd_snowline"), "dd_status lists the delivered routes")
	_done()
