extends Node
# [b]Nothing preloaded out of a game, because no game is in this build.[/b] The lobby is
# a delivered pack: its files are at `res://dot_cloud/a_room/<version>/…` and this file
# cannot name that path, because the version is the game's. The module is reached through
# the host's own module table instead, which is where a host is supposed to reach it.

## Changing the game with a REAL client attached, over a real socket.
##
## [codeblock]
## godot --headless --path . res://examples/live_switch.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]Why this exists when `examples/multigame.tscn` already switches games.[/b] That one
## switches with an occupant seated in the world, and an occupant is not a socket. A real
## client is a [DotClientSession] in a state machine, a peer in a [DotNetManager], a set of
## RPCs routed by node path, and a scene the server told it to load — and a game change
## puts all four back through `LOADING` at once.
##
## Switching under a browser segfaulted the server, and nothing headless could see it:
## `multigame` passed the same switch with an occupant, and with an occupant who had left
## before it. This is the shape that reaches it.
##
## Two `MultiplayerAPI` instances in one process, scoped by
## [method SceneTree.set_multiplayer], because there is one [member SceneTree.multiplayer]
## and two peers here want it. RPCs are routed by node path relative to each API root, so
## both link nodes are named `Server` — the name is the routing, not a description.

const CONFIG := "res://examples/fixtures/multigame"
const CONTENT := "res://content"
const DATA := "user://tmc_live_switch"

## Every check this suite runs, including the one that compares against it. The section
## counter cannot see a section that aborted after announcing itself — its remaining checks
## simply never run — and a total can. See docs/testing.md.
const CHECKS := 23

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _client_side: Node = null
var _link: DotClientLink = null

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
	print("dot-server-deploy: changing games under a live client")

	DotPaths.remove_tree(DATA)

	if await _boot():
		if await _test_connect():
			await _test_switch()
			await _test_switch_back()
			await _test_still_serving()

	_teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
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


func _until(condition: Callable, seconds: float = 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _at_game(game_id: String) -> bool:
	var current := _server().games.current()
	return current != null and current.game_id == game_id \
		and _server().games.phase == DotGameManager.Phase.IDLE


# --- Boot ------------------------------------------------------------------

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


func _teardown() -> void:
	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("test over")

	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")

		remove_child(_host)
		_host.free()


# --- Sections --------------------------------------------------------------

func _test_connect() -> bool:
	_section("a client connects")

	_link = DotClientLink.new()
	# "Server", the same as DotServer. The name is the routing.
	_link.name = "Server"
	_link.player_name = "Switcher"
	_client_side.add_child(_link)

	# Captured through Arrays: GDScript lambdas capture locals by value, so a flag set
	# inside a handler stays false outside it and the test reports a failure for a signal
	# that fired perfectly.
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
		func() -> bool: return _spawned[0] or _refused[0] != ""
	)

	if not _check(admitted, "and finishes signon", "refused: %s" % _refused[0]):
		_done()
		return false

	_check(_server().sessions().size() == 1, "the server has one session")
	_check(
		_games_seen.size() == 1 and _games_seen[0] == "lobby",
		"and it was told which game it is in (%s)" % [_games_seen]
	)
	_done()
	return true


## The switch that crashed the server.
func _test_switch() -> void:
	_section("changelevel, with that client attached")

	var result := _server().console.execute("changelevel hungry_classic")
	_check(result.ok, "the command is accepted", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("hungry_classic"), 25.0)

	if not _check(arrived, "the server reaches hungry"):
		_done()
		return

	# The whole point: it is still here to be asked.
	_check(
		_server().state == DotServer.State.RUNNING,
		"and is still running",
		"switching under a live client used to segfault it"
	)
	_check(
		_server().modules.has_module("hungry")
			and not _server().modules.has_module("room"),
		"with hungry's module in place of the lobby's"
	)

	var told := await _until(func() -> bool: return _games_seen.size() >= 2)

	_check(told, "the client was told about the change")
	_check(
		told and _games_seen[_games_seen.size() - 1] == "hungry_classic",
		"and told which game (%s)" % [_games_seen]
	)
	_check(
		_refused[0] == "",
		"without being disconnected",
		"a game change is SPAWNED -> DOWNLOADING -> LOADING, not a kick: got '%s'"
			% _refused[0]
	)
	_check(
		_server().sessions().size() == 1,
		"and the session survives (%d)" % _server().sessions().size()
	)
	_done()


func _test_switch_back() -> void:
	_section("and back again")

	_server().console.execute("changelevel lobby")

	var arrived := await _until(func() -> bool: return _at_game("lobby"), 25.0)

	_check(arrived, "the lobby comes back")
	_check(_server().state == DotServer.State.RUNNING, "the server is still running")
	_check(
		_server().modules.has_module("room"),
		"with its module"
	)
	_check(_refused[0] == "", "and the client is still connected")
	_done()


## Whatever the switch did to the server, it can still take a new player.
##
## The check that a crash cannot pass by accident: a process that has segfaulted answers
## nothing, and one that survived but left its listener in pieces answers nothing either.
func _test_still_serving() -> void:
	_section("still serving")

	_check(
		_server().console.execute("status").ok,
		"the console answers"
	)
	# Counted from the content directory rather than written down. The literal `3` here
	# went stale the moment a fourth game.yml was added, and a failing check that is
	# only out of date is the one somebody edits to match rather than reads.
	# Annotated, not inferred: `_host` is a plain Node, so this expression is Variant
	# and `var x := <Variant>` is a parse ERROR under these projects' warning settings.
	var expected: int = _host.content.games.size()
	_check(
		_server().games.game_ids().size() == expected,
		"every game in content/ is still registered (%d of %d): %s"
			% [
				_server().games.game_ids().size(), expected,
				str(_server().games.game_ids()),
			]
	)

	var module: DotModule = _server().modules.get_module("room")
	_check(
		module != null and module.net != null and module.net.is_running(),
		"and the current game's netcode is running"
	)
	_done()
