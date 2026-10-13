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
## to everybody. A second player then joins over a WebSocket through a 1 Mbit/s link while the
## first walks: the house (490 KB of JSON) must arrive whole, deflated and a window at a time
## (a browser drops what overflows its 64 KiB inbound buffer between two frames; mg-look-at-me
## docs/design.md, "The house on the wire"), and the first player must keep walking meanwhile.

const CONFIG := "res://examples/fixtures/lookatme"

## The server in a World3D of its own, away from the client in this process. See the helper.
const ServerWorld := preload("res://examples/server_world.gd")
const SlowTcpRelay := preload("res://examples/slow_tcp_relay.gd")

## The second player's link: 1 Mbit/s from the server.
const SLOW_RATE := 125000.0

## A browser's WebSocket inbound buffer (dot-core's `inbound_buffer_exp` 16). The house may have
## at most half of it unacknowledged: the page fills it between frames, and snapshots and chat
## need the rest. Fixed here rather than read from the game, so a widened window fails.
const BROWSER_INBOUND := 65536
const CONTENT := "res://content"
const DATA := "user://tmc_lookatme_client"

const GAME := "lookatme"
const CONTENT_ID := "tmc/lookatme"
const MODULE := "lookatme"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 26

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _client_side: Node = null
var _link: DotClientLink = null
var _relay: SlowTcpRelay = null

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
			await _test_a_second_over_a_slow_websocket()
			await _test_a_command_in_chat()
			_test_still_serving()
			await _test_the_same_guest_in_a_second_tab()

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

func _process(delta: float) -> void:
	if _relay != null:
		_relay.poll(delta)


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
func _client_world(link: DotClientLink = null) -> Object:
	if link == null:
		link = _link

	var root := link.get_node_or_null(^"GameRoot") if link != null else null

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


## A second client, over WebSocket, through a slow link, while the first walks. What the
## server's bridge has sent it and it has not acknowledged is sampled every frame.
func _test_a_second_over_a_slow_websocket() -> void:
	_section("a second player joins over a slow WebSocket while the first walks")
	var bridge: Object = _server().modules.get_module(MODULE).get("bridge")
	var window := BROWSER_INBOUND / 2
	# Both clients in this process are one guest (dot-server's device id is per install), and the
	# house keys progress by account, so the second would take the player and the first would be
	# dropped (that is _test_the_same_guest_in_a_second_tab). Keyed by session for the second's
	# join, as two people on two machines would be.
	var key_fn: Callable = bridge.get("key_fn")
	bridge.set("key_fn", Callable())
	_relay = SlowTcpRelay.new()
	_relay.rate_down = SLOW_RATE
	var port := _relay.start(_host.config.server.port)

	var side := Node.new()
	side.name = "SecondSide"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var second := DotClientLink.new()
	second.name = "Server"
	second.player_name = "Rider"
	second.transport_preference = "ws"
	side.add_child(second)

	# The first player walks back and forth across the lobby the whole time.
	var first := _client_scene()
	var server_first: Node3D = (_world().get("players") as Dictionary).get(StringName(str(first.get("bridge").get("local_key"))))
	var walked := [0.0]
	var last := [server_first.global_position]
	var outstanding := [0]
	var sent_short := [false]
	var longest_frame := [0]
	var frame_at := [Time.get_ticks_usec()]
	var started := Time.get_ticks_msec()
	var spawned_at := [0]
	second.spawned.connect(func() -> void: spawned_at[0] = Time.get_ticks_msec())

	var watch := func() -> void:
		var now := Time.get_ticks_usec()
		longest_frame[0] = maxi(longest_frame[0], now - frame_at[0])
		frame_at[0] = now
		var go := DotFpsCommand.new()
		go.move = Vector2(0, 1)
		go.yaw = 90.0 if (Time.get_ticks_msec() / 700) % 2 == 0 else 270.0
		first.set("command_override", go)
		walked[0] += server_first.global_position.distance_to(last[0])
		last[0] = server_first.global_position
		var peer := second.multiplayer.get_unique_id() if second.multiplayer.has_multiplayer_peer() else 0

		if peer > 0 and bridge.has_method("house_progress"):
			var progress: Dictionary = bridge.call("house_progress", peer)
			outstanding[0] = maxi(outstanding[0], int(progress.get("outstanding", 0)))
			sent_short[0] = sent_short[0] or (not progress.is_empty() and int(progress["sent"]) < int(progress["levels"]))

	get_tree().physics_frame.connect(watch)
	var connecting: DotResult = await second.connect_to_server("127.0.0.1:%d" % port)
	var built := connecting.ok and await _until(func() -> bool: return int(_says(_client_world(second)).get("levels", 0)) == 32, 60.0)
	var built_at := Time.get_ticks_msec()
	get_tree().physics_frame.disconnect(watch)
	first.set("command_override", DotFpsCommand.new())
	bridge.set("key_fn", key_fn)

	print("  note  connect to signon %d ms, signon to 32 levels %d ms, %d bytes down at %d KB/s; longest frame %d ms" % [
		spawned_at[0] - started, built_at - spawned_at[0], _relay.bytes_down, int(SLOW_RATE / 1000.0), longest_frame[0] / 1000])
	_check(connecting.ok and second.transport_used == "websocket", "it is on a WebSocket", second.transport_used)
	_check(built, "and builds all 32 levels through the slow link", "%d" % int(_says(_client_world(second)).get("levels", 0)))
	_check(sent_short[0] and outstanding[0] > 0 and outstanding[0] <= window,
		"and was never sent more of the house than the window ahead of its acks",
		"most outstanding %d bytes, window %d" % [outstanding[0], window])
	_check(walked[0] > 2.0 and _refused[0] == "", "while the first player kept walking", "%.1f m" % walked[0])

	second.disconnect_from_server("test over")
	await get_tree().process_frame
	remove_child(side)
	side.queue_free()
	_relay.stop()
	_relay = null
	_done()


func _client_scene() -> Node:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null

	if root == null:
		return null

	for child in root.get_children():
		if child.get("game") is Object and child.has_method("_act"):
			return child

	return null


## Two browser tabs of one guest share a device id, so one account. The newest connection wins:
## it is given the player and the house, and the first is disconnected with a sentence it shows,
## never left connected with keys that move nothing. Last, because it ends the first client.
func _test_the_same_guest_in_a_second_tab() -> void:
	_section("the same guest in a second tab: the newest wins, the first is told")
	var side := Node.new()
	side.name = "SecondTab"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var tab := DotClientLink.new()
	tab.name = "Server"
	tab.player_name = "Driver"
	side.add_child(tab)
	var first_key := StringName(str(_client_scene().get("bridge").get("local_key")))
	var connecting: DotResult = await tab.connect_to_server("127.0.0.1:%d" % _host.config.server.port)
	var built := connecting.ok and await _until(func() -> bool: return int(_says(_client_world(tab)).get("levels", 0)) == 32, 60.0)
	var told := await _until(func() -> bool: return _refused[0] != "", 10.0)
	_check(String(first_key).begins_with("uid:"), "the house keys the first tab by its account", String(first_key))
	_check(built, "the second tab is sent the house")
	_check(told and _refused[0] == "You joined from another tab or window",
		"and the first tab is disconnected with a reason it can show", _refused[0])
	var bridge: Object = _server().modules.get_module(MODULE).get("bridge")
	var players := _world().get("players") as Dictionary
	var peer := tab.multiplayer.get_unique_id() if tab.multiplayer.has_multiplayer_peer() else 0
	_check(players.size() == 1 and int(bridge.call("peer_of", first_key)) == peer,
		"and the one player is the second tab's", "%d players, held by %d, tab %d" % [players.size(), int(bridge.call("peer_of", first_key)), peer])
	tab.disconnect_from_server("test over")
	await get_tree().process_frame
	remove_child(side)
	side.queue_free()
	_done()


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
