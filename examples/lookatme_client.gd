extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Dangerous
# Delivery is a delivered pack at `res://dot_cloud/tmc/lookatme/<version>/…`; everything about
# it is reached through the host's module table, `describe()` and duck typing.

## A REAL client, over a REAL socket, in a DELIVERED Look At Me.
##
## [codeblock]
## godot --headless --path . res://examples/lookatme_client.tscn
## [/codeblock]
##
## Needs `dist/tmc/lookatme` (`./server pack lookatme --source games/mg-look-at-me`).
##
## [b]What only this can see.[/b] The game's own suites never run it from a mount and never
## over a WebSocket: the levels are read out of the mount on the server and arrive at the
## client one per message (all of them together are past a WebSocket's buffer), the player is
## predicted against a real clock, and a /command typed in chat goes to the house rather than
## to everybody.

const CONFIG := "res://examples/fixtures/lookatme"
const CONTENT := "res://content"
const DATA := "user://tmc_lookatme_client"

const GAME := "lookatme"
const CONTENT_ID := "tmc/lookatme"
const MODULE := "lookatme"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 18

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
	print("dot-server-deploy: a real client in a delivered Look At Me")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/lookatme")):
		print("skipped: dist/tmc/lookatme is not published here")
		print("  ./server pack lookatme --source games/mg-look-at-me")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			_test_the_pack_mounted()
			await _test_the_levels_arrived()
			await _test_walking_across_the_socket()
			await _test_a_command_in_chat()
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
	_check(path.begins_with("res://dot_cloud/tmc/lookatme/"), "its module is the mounted copy", path)
	_done()


func _test_the_levels_arrived() -> void:
	_section("every level, on both ends")
	_check(int(_says(_world()).get("levels", 0)) == 32, "the server read all 32 levels out of the mount")
	var built := await _until(func() -> bool: return int(_says(_client_world()).get("levels", 0)) == 32, 30.0)
	_check(built, "and the client built them, one message each")
	var client := _client_scene()
	var arrived := await _until(func() -> bool: return client != null and client.get("player") != null, 15.0)
	_check(arrived, "and stands in the lobby")
	_done()


func _test_walking_across_the_socket() -> void:
	_section("walking across the socket")
	var client := _client_scene()
	var key := StringName(str(client.get("bridge").get("local_key")))
	var server_player: Node3D = (_world().get("players") as Dictionary).get(key)

	if not _check(server_player != null, "the server has the client's player", String(key)):
		_done()
		return

	var start := server_player.global_position
	var go := DotFpsCommand.new()
	go.move = Vector2(0, 1)
	go.yaw = 90.0
	client.set("command_override", go)
	var moved := await _until(func() -> bool: return server_player.global_position.distance_to(start) > 3.0, 15.0)
	_check(moved, "the client's keys walk the server's player", "%.1f m" % server_player.global_position.distance_to(start))
	client.set("command_override", DotFpsCommand.new())
	await _until(func() -> bool: return false, 1.0)
	var mine: Node3D = client.get("player")
	var gap: float = (mine.get("controller").get("state").get("position") as Vector3).distance_to(server_player.get("controller").get("state").get("position"))
	_check(gap < 0.5, "and the client's prediction stands where the server does", "%.3f m" % gap)
	_check(_refused[0] == "", "and is still connected", _refused[0])
	_done()


## /r typed in the chat box goes to the house, not to everybody: the reply comes back to one
## player as a notice.
func _test_a_command_in_chat() -> void:
	_section("a command in chat")
	var client := _client_scene()
	var heard := [""]
	client.get("bridge").connect("notice_received", func(text: String) -> void: heard[0] = text)
	client.get("chat").call("_on_submitted", "/r", &"all")
	var replied := await _until(func() -> bool: return heard[0] != "", 10.0)
	_check(replied and heard[0] == "Back to the lobby", "/r is answered by the house", heard[0])
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
	_server().console.execute("lm_status", context)
	_check("\n".join(captured).contains("levels"), "lm_status describes the house")
	captured.clear()
	_server().console.execute("lm_house", context)
	_check("\n".join(captured).contains("asylum"), "and the Asylum, a second house, was found inside the mount")
	_done()
