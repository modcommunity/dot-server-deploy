extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Smash Copter
# is a delivered pack: its files are at `res://dot_cloud/tmc/smash/<version>/…` and this
# file cannot name that path, because the version is the game's. Everything about the game
# is reached through the host's own module table, which is where a host is supposed to reach
# it.

## A REAL client, over a REAL socket, in a DELIVERED game.
##
## [codeblock]
## godot --headless --path . res://examples/smash_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]Why this exists when the game already has three suites and 280 checks.[/b] All three
## run inside the game's own project, where its files are at `res://` and its `class_name`
## globals are registered — which is the one condition a delivered pack never has. Two of
## them do not open a socket at all, and the third replaces the RPC with a [Callable] so
## that it can run both halves in one process: it exercises the encoders, the seal, the
## prediction and the reconciliation, and it cannot see Godot's own RPC routing, the mount,
## the publisher's path rewriting, or the host.
##
## Every bug this file is here to catch has the same shape: the game is correct, the pack is
## correct, and the two do not meet. The first boot of this game against a real server found
## a path the publisher had already rewritten being rebased a second time, a combat manager
## setting itself up twice, and lag compensation reporting as unwired on a server where it
## works — none of which any of the 280 checks could reach.
##
## Two [MultiplayerAPI] instances in one process, scoped by
## [method SceneTree.set_multiplayer], because there is one [member SceneTree.multiplayer]
## and two peers here want it. RPCs are routed by node path relative to each API root, so
## both link nodes are named `Server` — the name is the routing, not a description.

const CONFIG := "res://examples/fixtures/smash"
const CONTENT := "res://content"
const DATA := "user://tmc_smash_client"

const GAME := "smash"
const CONTENT_ID := "tmc/smash"
const MODULE := "smash"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _client_side: Node = null
var _link: DotClientLink = null

# Captured through Arrays: GDScript lambdas capture locals by value, so a flag set inside a
# handler stays false outside it and the suite reports a failure for a signal that fired
# perfectly. live_switch.gd learned this the same way.
var _spawned := [false]
var _refused := [""]
var _games_seen: Array[String] = []


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: a real client in a delivered Smash Copter")

	DotPaths.remove_tree(DATA)

	if await _boot():
		if await _test_connect():
			await _test_the_pack_mounted()
			await _test_the_world_is_there()
			await _test_a_round_runs()
			await _test_the_client_sees_the_field()
			await _test_still_serving()

	await _teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
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


## The game's world node, found by duck typing rather than by class.
##
## [b]Nothing in this build can name a type the pack declares.[/b] The module is a
## [DotModule] the host loaded out of the mount, and what hangs off it is the game's own
## scene — so everything below asks for a PROPERTY by name and checks what came back. That
## is the same bargain the game's own module makes with dot-game, and it is why the game
## exposes `describe()` at all.
func _world() -> Node:
	var module: DotModule = _server().modules.get_module(MODULE)

	if module == null:
		return null

	# [b]`game`, and it is [DotGameModule]'s own name for it.[/b] The module calls its local
	# `world` because that is what this game's world is; the property every module in the
	# family exposes is `game`, typed [Object] so the base never names a game's type.
	var world: Variant = module.get("game")
	return world as Node


func _world_says() -> Dictionary:
	var world := _world()

	if world == null or not world.has_method("describe"):
		return {}

	var said: Variant = world.call("describe")
	return said as Dictionary


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

	if not _check(reached, "and reaches the delivered game", "acquiring content takes a moment"):
		return false

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _client_side.get_path()
	)

	_check(
		get_tree().get_multiplayer(_host.get_path())
			!= get_tree().get_multiplayer(_client_side.get_path()),
		"the two halves have separate MultiplayerAPI instances"
	)
	return true


## [b]The client first, and then a frame, and then the host.[/b] The client is what holds
## the delivered game's SCENE — the arena, the platforms, every mesh and material the pack
## carries — under the `GameRoot` the link created. Freeing the host first leaves all of it
## alive with nothing referencing it, and the process exits reporting a couple of hundred
## leaked objects and resources still in use. That is only ever a warning, because the
## process is ending either way; it is also indistinguishable at a glance from a game that
## leaks a world per round, which this one rebuilds twenty times an hour.
##
## The awaits are not decoration. A [Node] taken out of the tree is freed at the end of the
## frame, and the game's own world clears itself the same way for the same reason — so a
## teardown with no frame between its two halves frees the host while the client's copy is
## still queued.
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
	# "Server", the same as DotServer. The name is the routing.
	_link.name = "Server"
	_link.player_name = "Faller"
	_client_side.add_child(_link)

	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _refused[0] = reason)
	_link.game_changed.connect(
		func(game_id: String, _content_id: String, _name: String) -> void:
			_games_seen.append(game_id)
	)

	var address := "127.0.0.1:%d" % _host.config.server.port
	var connecting: DotResult = await _link.connect_to_server(address)

	if not _check(connecting.ok, "it starts connecting", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(
		func() -> bool: return _spawned[0] or _refused[0] != "", 45.0
	)

	if not _check(admitted, "and finishes signon", "refused: %s" % _refused[0]):
		_done()
		return false

	_check(_server().sessions().size() == 1, "the server has one session")
	_check(
		_games_seen.size() >= 1 and _games_seen[_games_seen.size() - 1] == GAME,
		"and it was told which game it is in (%s)" % [_games_seen]
	)
	_done()
	return true


## [b]The mount, which is the one thing every delivery bug has in common.[/b] A pack that
## did not mount is a game that is not there; a pack that mounted at the wrong prefix is a
## game whose every file resolves against the host.
func _test_the_pack_mounted() -> void:
	_section("the pack is mounted where the game thinks it is")

	var entry := _server().games.current()

	if not _check(entry != null, "the server has a current game"):
		_done()
		return

	_check(
		String(entry.content_id) == CONTENT_ID,
		"and it is the delivered one (%s)" % entry.content_id
	)

	var module: DotModule = _server().modules.get_module(MODULE)

	if not _check(module != null, "the game's module loaded out of the mount"):
		_done()
		return

	# Form one, from the other side. A `class_name` in a game repository is a global the
	# host does not register, so a delivered game that used one mounts with every script in
	# it dead — and a module whose script failed to parse is null above, not broken here.
	var script: Variant = module.get_script()
	var path := String((script as Resource).resource_path) if script != null else ""

	_check(
		path.begins_with("res://dot_cloud/"),
		"and its script is the mounted copy, not a built-in one",
		path
	)
	_check(
		module.net != null and module.net.is_running(),
		"with its netcode running"
	)
	_done()


## [b]The world, and the art it loads by path.[/b] The seventh form of the delivery
## constraint was a prop whose model path had been rebased twice: the prop spawned, fell,
## landed and damaged a platform while being invisible, and the only report anywhere was one
## warning per prop. So this asks the world what it has rather than trusting that it booted.
func _test_the_world_is_there() -> void:
	_section("the delivered world built itself")

	var said := _world_says()

	if not _check(not said.is_empty(), "the module has a world that can describe itself"):
		_done()
		return

	_check(
		int(said.get("platforms", 0)) > 0,
		"with platforms in it (%s)" % said.get("platforms", 0)
	)
	_check(
		String(said.get("layout", "")) != "",
		"laid out to one of its layouts (%s)" % said.get("layout", "")
	)
	_check(
		String(said.get("gravity", "")) != "",
		"under its own gravity rather than the project's (%s)" % said.get("gravity", "")
	)
	_done()


## A round, end to end, on the far side of a socket.
##
## [b]The props are the point.[/b] Nothing the cannon throws exists until a round is
## running, and loading a prop's model is the exact line the first delivered boot died on.
## A round that reaches a non-zero prop count is a round in which that path was walked.
func _test_a_round_runs() -> void:
	_section("a round runs, and the cannon fires")

	var started := await _until(
		func() -> bool: return int(_world_says().get("round", 0)) > 0, 30.0
	)

	if not _check(started, "a round begins"):
		_done()
		return

	var threw := await _until(
		func() -> bool: return int(_world_says().get("props", 0)) > 0, 30.0
	)

	_check(
		threw,
		"and something is in the air (%s props)" % _world_says().get("props", 0),
		"a prop whose model would not load is the seventh delivery form"
	)

	_check(
		_refused[0] == "",
		"with the client still connected",
		"got '%s'" % _refused[0]
	)
	_done()


## [b]What the CLIENT has, which is a different question from what the server has.[/b] The
## field crosses the wire as a layout document and the client rebuilds it; a client that
## rebuilt nothing is a player standing on a floor only the server can see, and every check
## above would still pass.
func _test_the_client_sees_the_field() -> void:
	_section("the client has a field of its own")

	# [b]`GameRoot`, by name, because the link does not expose it.[/b]
	# [member DotClientLink.game_root_ref] defaults to `DotNodeRef.of_created(&"GameRoot")`,
	# so the node exists as a child of the link and the reference to it is private. The
	# shell's own suites reach the equivalent the same way.
	var root := await _until(
		func() -> bool:
			var found := _link.get_node_or_null(^"GameRoot")
			return found != null and found.get_child_count() > 0,
		25.0
	)

	var game_root := _link.get_node_or_null(^"GameRoot")

	if not _check(root and game_root != null, "the client loaded the game the server sent"):
		_done()
		return

	_check(
		game_root.get_child_count() > 0,
		"and it is on screen (%d children)" % game_root.get_child_count()
	)

	# Counted by walking, because this build cannot name the game's platform type. A
	# delivered client's field is nodes under the game root; zero of them is a client that
	# was told about a map and built none of it.
	var nodes := _count_nodes(game_root)
	_check(
		nodes > 10,
		"with a world under it rather than an empty scene (%d nodes)" % nodes
	)
	_done()


func _count_nodes(from: Node) -> int:
	var total := 1

	for child in from.get_children():
		total += _count_nodes(child)

	return total


## Whatever the round did to the server, it can still be asked.
##
## The check a crash cannot pass by accident: a process that has segfaulted answers nothing,
## and one that survived with its listener in pieces answers nothing either.
func _test_still_serving() -> void:
	_section("still serving")

	_check(_server().console.execute("status").ok, "the console answers")
	_check(
		_server().state == DotServer.State.RUNNING,
		"the server is still running"
	)

	# The game's own console command, registered by a module that came out of a pack. A
	# command that is registered and answers is the whole delivery path proved from the
	# operator's end.
	var status := _server().console.execute("sc_status")
	_check(status.ok, "and so does the delivered game's own command", str(status.error))

	# Counted from the content directory rather than written down: a literal here goes stale
	# the moment another game.yml is added, and a failing check that is only out of date is
	# the one somebody edits to match rather than reads.
	var expected: int = _host.content.games.size()
	_check(
		_server().games.game_ids().size() == expected,
		"every game in content/ is still registered (%d of %d)"
			% [_server().games.game_ids().size(), expected]
	)
	_done()
