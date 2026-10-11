extends Node
# [b]Nothing preloaded out of a game, because no game is in this build.[/b] Every game here is a
# delivered pack. Its RPC link is found by what it carries (the counters every game's link keeps),
# not by its script, so this suite names no game's code.

## Returning to a game already played in this server process: its netcode must still work, for
## the client that followed the changes AND for a client that joins afterwards.
##
## [codeblock]
## godot --headless --path . res://examples/return_to_game.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs smash, hungry, playground and zombiezone (with its maps)
## published in `dist/`; with no `dist/` at all it says "skipped".
##
## [b]The bug this exists for.[/b] Every game parents its RPC link under `Server` on both ends
## (the node path is the routing), and before dot-server 39cecc5 no game change freed it. The
## next time the SAME game loaded, its link collided with the leftover's name and Godot renamed
## it `@Node@<n>`: the client that came back had every request dropped, and a fresh joiner got a
## game whose server end it could not address. In production that was a server whose rotation
## came back to a game. Every suite passed, because each asked only whether the client was "in"
## the game (told of it, its scene loaded, its session playing), and all of that is the
## framework's link, not the game's.
##
## [b]So this asks the game's own link.[/b] Every game's link counts the inputs it received and
## the snapshots it received, and those counters move only when an RPC really went through that
## node on the far end. A return is checked by both directions for the client that followed
## (its inputs reach the server's link, the server's snapshots reach its link) and then for a
## fresh shell that joins (snapshots reach it; once the first client has left, the server's
## inputs are its alone). The first load of the first game is checked the same way, so a probe
## that fails on a return fails because of the return.
##
## Four games of different shapes: a 3D round-based minigame (smash), a 2D game (hungario), a
## sandbox with vehicles and props (playground) and a co-operative shooter whose maps are a
## second pack (zombiezone). Each returned to after another game ran in between.

const CONFIG := "res://examples/fixtures/return_to_game"

## The server in a World3D of its own, away from the clients in this process. See the helper.
const ServerWorld := preload("res://examples/server_world.gd")

## The engine's "RPC to a node this end does not have" errors, counted for the whole run.
const RpcPathWatch := preload("res://examples/rpc_path_watch.gd")
const CONTENT := "res://content"
const DATA := "user://tmc_return_to_game"
const SHELL := "res://client/shell.tscn"

## The games played, in order, and whether the netcode is probed there. Every probe but the
## first is a return to a game this process already ran, with another game in between.
const PLAN := [
	["smash", true],
	["hungry_classic", false],
	["smash", true],
	["playground", false],
	["zombiezone", false],
	["playground", true],
	["zombiezone", true],
	["hungry_classic", true],
]

## Checks per step: a change the suite only passes through, and one it probes.
const PER_CHANGE := 2
const PER_PROBE := 10

## How far each counter must move inside [constant WINDOW_SEC] to count as traffic. Every game
## sends an input per client tick and a snapshot per server tick or two, so this is a fraction
## of a second of either.
const MIN_TRAFFIC := 10
const WINDOW_SEC := 10.0

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null

## The client that followed every change so far.
var _shell: Node = null
var _shells_made := 0

## One row per probe for the table at the end.
var _rows: Array[Dictionary] = []


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _expected_checks() -> int:
	var total := 2 + 3
	for i in PLAN.size():
		if i == 0:
			# The join is the change: one check where a return has two.
			total += PER_PROBE - 1
		elif PLAN[i][1]:
			total += PER_PROBE
		else:
			total += PER_CHANGE
	return total


func _run() -> void:
	print("dot-server-deploy: returning to a game, its netcode for the client and a fresh joiner")

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc")):
		print("skipped: nothing is published in dist/ here")
		get_tree().quit(0)
		return

	DotPaths.remove_tree(DATA)

	var rpc_watch := RpcPathWatch.new()
	OS.add_logger(rpc_watch)

	if await _boot():
		for i in PLAN.size():
			if _server() == null or _shell == null:
				break
			var game: String = PLAN[i][0]
			if i == 0:
				await _probe(game, "first load", true)
			elif PLAN[i][1]:
				await _probe(game, "returned to", false)
			else:
				await _pass_through(game)

	await _teardown()
	DotPaths.remove_tree(DATA)
	OS.remove_logger(rpc_watch)

	_print_table()

	print("")
	_check(
		rpc_watch.count() == 0,
		"no RPC was addressed to a node the other end does not have (%d)" % rpc_watch.count(),
		rpc_watch.summary()
	)
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered]
	)
	_check(
		_passed + _failed + 1 == _expected_checks(),
		"every check ran (%d of %d)" % [_passed + _failed + 1, _expected_checks()],
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


func _skip(count: int, why: String) -> void:
	for i in count:
		_check(false, "skipped: %s" % why)


func _server() -> DotServer:
	if _host == null or not is_instance_valid(_host):
		return null
	return _host.server as DotServer


func _until(condition: Callable, seconds: float = 20.0) -> bool:
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


func _link_of(shell: Node) -> DotClientLink:
	if shell == null or not is_instance_valid(shell):
		return null
	var link: Variant = shell.link
	return link as DotClientLink if link != null and is_instance_valid(link) else null


## [param shell] is in [param game_id]: told of it, its scene loaded, playing.
func _client_in(shell: Node, game_id: String) -> bool:
	var link := _link_of(shell)
	return (
		link != null and link.server_game_id == game_id
		and link.phase == DotClientLink.Phase.PLAYING
		and link._scene_instance != null and is_instance_valid(link._scene_instance)
	)


## The game RPC links under [param parent]: every child that keeps a link's counters and has not
## been retired by a game change. A game's link is the one thing a game puts under `Server`.
func _game_links(parent: Node, counter: String) -> Array[Node]:
	var found: Array[Node] = []
	if parent == null or not is_instance_valid(parent):
		return found
	for child in parent.get_children():
		if counter in child and not String(child.name).contains("_retired_"):
			found.append(child)
	return found


func _names(nodes: Array[Node]) -> String:
	var names := PackedStringArray()
	for node in nodes:
		names.append(String(node.name))
	return ", ".join(names)


## The newest of [param nodes], which is the running game's when there is more than one.
func _newest(nodes: Array[Node]) -> Node:
	return nodes[nodes.size() - 1] if not nodes.is_empty() else null


## How far [param counter] on [param node] moves in at most [constant WINDOW_SEC]; returns as soon
## as it has moved [constant MIN_TRAFFIC].
func _traffic(node: Node, counter: String) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var start := int(node.get(counter))
	await _until(
		func() -> bool:
			return is_instance_valid(node) and int(node.get(counter)) - start >= MIN_TRAFFIC,
		WINDOW_SEC
	)
	return int(node.get(counter)) - start if is_instance_valid(node) else 0


## A shell of its own, content from this project's `dist/`, connecting to the server.
func _new_shell() -> Node:
	_shells_made += 1
	var shell: Node = (load(SHELL) as PackedScene).instantiate()
	# Each shell scopes its own MultiplayerAPI to its own path, so two can be connected at once.
	shell.name = "Shell%d" % _shells_made
	add_child(shell)

	await get_tree().process_frame
	await get_tree().process_frame

	shell._ensure_cloud()
	shell._cloud.http_base_urls = PackedStringArray([
		ProjectSettings.globalize_path("res://dist"),
		ProjectSettings.globalize_path("res://dist/maps"),
	])
	shell._connect_to("127.0.0.1:%d" % int(_host.config.server.port))
	return shell


func _drop_shell(shell: Node) -> void:
	if shell == null or not is_instance_valid(shell):
		return
	var link := _link_of(shell)
	if link != null:
		link.disconnect_from_server()
	remove_child(shell)
	shell.queue_free()
	await get_tree().process_frame


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	_section("booting")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.name = "Host"
	_host.auto_start = false
	ServerWorld.add(self, _host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not _check(started.ok, "the host boots", str(started.error)):
		_skip(1, "the host did not boot")
		_done()
		return false

	var missing := PackedStringArray()
	for step in PLAN:
		var descriptor := _server().games.find_game(step[0])
		if descriptor == null or not FileAccess.file_exists(
			"res://dist/%s/manifest.json" % descriptor.content_id
		):
			if not missing.has(step[0]):
				missing.append(step[0])
	if not _check(missing.is_empty(), "every game it plays is in content/ and published in dist/", "missing: %s" % [missing]):
		_done()
		return false

	_shell = await _new_shell()
	_done()
	return true


func _teardown() -> void:
	await _drop_shell(_shell)
	_shell = null

	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")

		ServerWorld.remove(_host)
		_host.free()
		_host = null

		await get_tree().physics_frame
		await get_tree().physics_frame


# --- Steps ------------------------------------------------------------------

func _change_to(game_id: String) -> void:
	if not _at_game(game_id):
		var _ran := _server().console.execute("changelevel %s" % game_id)


## A game the suite only passes through, so that the next return has something in between.
func _pass_through(game_id: String) -> void:
	_section("%s, passed through" % game_id)
	_change_to(game_id)
	_check(await _until(func() -> bool: return _at_game(game_id), 60.0), "the server is running %s" % game_id)
	_check(
		await _until(func() -> bool: return _client_in(_shell, game_id), 60.0),
		"and the client followed",
		"phase %s, game '%s'" % [_link_of(_shell).phase, _link_of(_shell).server_game_id]
			if _link_of(_shell) != null else "no link"
	)
	_done()


## The netcode of [param game_id] after the change into it: both directions for the client that
## was already here, then for a fresh shell that joins, which then stays as the client for the
## next step. On the first load the change is the join itself, so the two "is running" checks
## are not repeated.
func _probe(game_id: String, why: String, first: bool) -> void:
	_section("%s, %s" % [game_id, why])

	var row := {
		"game": game_id, "why": why, "link": "-", "in": 0, "out": 0, "fresh_out": 0, "fresh_in": 0,
	}
	_rows.append(row)

	if not first:
		_change_to(game_id)
		_check(await _until(func() -> bool: return _at_game(game_id), 60.0), "the server is running %s" % game_id)
	var followed := await _until(func() -> bool: return _client_in(_shell, game_id), 60.0)
	if not first:
		_check(followed, "and the client followed")
	elif not _check(followed and _at_game(game_id), "a real shell joins %s" % game_id):
		_skip(PER_PROBE - 2, "the client is not in %s" % game_id)
		_done()
		return
	if not followed:
		_skip(PER_PROBE - 2, "the client is not in %s" % game_id)
		_done()
		return

	# The game's link comes up a moment after the scene (the bridge attaches it once it has the
	# server or client link it was given). Wait for both ends to have one.
	await _until(
		func() -> bool:
			return not _game_links(_server(), "inputs_received").is_empty() \
				and not _game_links(_link_of(_shell), "snapshots_received").is_empty(),
		10.0
	)

	var server_links := _game_links(_server(), "inputs_received")
	var server_link := _newest(server_links)
	var link_name := String(server_link.name) if server_link != null else ""
	row["link"] = link_name
	_check(
		server_links.size() == 1 and link_name != "" and not link_name.begins_with("@"),
		"the server has one link for the game, under its own name (%s)" % _names(server_links),
		"a leftover link from the last time took the name; this one was renamed by Godot"
	)

	var client_links := _game_links(_link_of(_shell), "snapshots_received")
	var client_link := _newest(client_links)
	_check(
		client_links.size() == 1 and client_link != null and String(client_link.name) == link_name,
		"the client's is the same path (%s)" % _names(client_links),
		"RPCs are routed by node path: Server/%s on the server" % link_name
	)

	var inputs := await _traffic(server_link, "inputs_received")
	row["in"] = inputs
	_check(
		inputs >= MIN_TRAFFIC,
		"the client's inputs reach the server's link (%d in %d s)" % [inputs, int(WINDOW_SEC)]
	)

	var snapshots := await _traffic(client_link, "snapshots_received")
	row["out"] = snapshots
	_check(
		snapshots >= MIN_TRAFFIC,
		"the server's snapshots reach the client's link (%d)" % snapshots
	)

	# --- A client that was not here for any of it.
	var fresh := await _new_shell()
	var joined := await _until(func() -> bool: return _client_in(fresh, game_id), 60.0)
	_check(joined, "a fresh shell joins %s" % game_id)

	await _until(func() -> bool: return not _game_links(_link_of(fresh), "snapshots_received").is_empty(), 10.0)
	var fresh_links := _game_links(_link_of(fresh), "snapshots_received")
	var fresh_link := _newest(fresh_links)
	_check(
		fresh_links.size() == 1 and fresh_link != null and String(fresh_link.name) == link_name,
		"with its link at the server's path (%s)" % _names(fresh_links)
	)

	var fresh_out := await _traffic(fresh_link, "snapshots_received")
	row["fresh_out"] = fresh_out
	_check(fresh_out >= MIN_TRAFFIC, "the server's snapshots reach it (%d)" % fresh_out)

	# The old client leaves, so whatever the server's link receives from here is the fresh one's.
	await _drop_shell(_shell)
	_shell = fresh
	await _until(func() -> bool: return _server().sessions().size() == 1, 10.0)

	var fresh_in := await _traffic(_newest(_game_links(_server(), "inputs_received")), "inputs_received")
	row["fresh_in"] = fresh_in
	_check(
		_server().sessions().size() == 1 and fresh_in >= MIN_TRAFFIC,
		"and its inputs reach the server's link, alone on the server (%d)" % fresh_in,
		"%d sessions" % _server().sessions().size()
	)
	_done()


func _print_table() -> void:
	print("")
	print("%-15s %-12s %-12s %-10s %-10s %-10s %s" % [
		"game", "probe", "link", "inputs", "snapshots", "fresh snap", "fresh in",
	])
	for row in _rows:
		print("%-15s %-12s %-12s %-10s %-10s %-10s %s" % [
			row["game"], row["why"], row["link"], row["in"], row["out"], row["fresh_out"],
			row["fresh_in"],
		])
