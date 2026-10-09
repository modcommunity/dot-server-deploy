extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Wipeout is a
# delivered pack at `res://dot_cloud/tmc/wipeout/<version>/…`, and its courses are a second
# pack at `res://dot_cloud/tmc/wipeout_maps/<version>/…`. Everything about the game is
# reached through the host's module table and `describe()`, as smash_client does.

## A REAL client, over a REAL socket, in a DELIVERED Wipeout — with its courses delivered as
## a server-only pack beside it.
##
## [codeblock]
## godot --headless --path . res://examples/wipeout_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/wipeout` and `dist/tmc/wipeout_maps`
## (`./server pack wipeout --source games/mg-wipeout`, and the same for wipeout_maps).
##
## [b]What only this can see.[/b] mg-wipeout's four suites run inside its own project, where
## its courses are a link at `res://courses`. Delivered, they are not in the game's pack at
## all, and the game does not name them: the server owner's cfg/content.yml does (the
## fixture's), the host lays that over the descriptor's `maps`, and the game fetches each pack
## through dot-game's DotGameContent and reads its `courses/` -- which works only if the
## prefix it computes from the pinned key is where the pack really mounted. A wrong guess is a server that boots, plays
## the one practice course built into the game, and logs an INFO line. So this asserts the
## courses arrived as content, that a round runs on one of them, that the client — which was
## never sent the course files — built the same course from the document the server sent,
## and that a final death crosses the socket with its arena and the weapons on its floor.

const CONFIG := "res://examples/fixtures/wipeout"
const CONTENT := "res://content"
const DATA := "user://tmc_wipeout_client"

const GAME := "wipeout"
const CONTENT_ID := "tmc/wipeout"
const MAPS_KEY := "tmc/wipeout_maps@0.1.0"
const MODULE := "wipeout"

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
	print("dot-server-deploy: a real client in a delivered Wipeout")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/wipeout")) \
			or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/wipeout_maps")):
		print("skipped: dist/tmc/wipeout and dist/tmc/wipeout_maps are not published here")
		print("  ./server pack wipeout_maps --source games/mg-wipeout-maps")
		print("  ./server pack wipeout --source games/mg-wipeout")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			await _test_the_packs_mounted()
			await _test_the_courses_arrived()
			await _test_the_client_builds_the_course()
			await _test_a_final_death_crosses()
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
	_link.player_name = "Runner"
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
	_section("the game and its courses are mounted where the game looks")

	var entry := _server().games.current()
	_check(entry != null and String(entry.content_id) == CONTENT_ID, "the current game is the delivered one")

	var module: DotModule = _server().modules.get_module(MODULE)
	var script: Variant = module.get_script() if module != null else null
	var path := String((script as Resource).resource_path) if script != null else ""
	_check(path.begins_with("res://dot_cloud/tmc/wipeout/"), "its module is the mounted copy", path)

	var named: PackedStringArray = _server().games.current_maps()
	var authored := TmcYaml.parse_file(CONTENT.path_join("wipeout/game.yml"))
	var game_lists := []
	if authored.ok:
		for field in ["maps", "server_dependencies", "dependencies"]:
			game_lists.append_array(TmcYaml.at(authored.value, field, []) as Array)
	_check(named.has(MAPS_KEY) and authored.ok and game_lists.is_empty(),
		"the courses are named by the server's cfg/content.yml, not by the game", str(named))
	_check(_server().games.current_server_dependencies().has(MAPS_KEY),
		"and fetched before the game loaded, because the game asks for maps_delivery: server")

	var file := DotCloudClient.mount_prefix_for(&"tmc/wipeout_maps", "0.1.0").path_join("courses/wo_first_splash.json")
	_check(FileAccess.file_exists(file), "and are mounted where the game computes they are", file)
	_done()


## The courses are content now: ten of them and five arenas, read out of the mount, and the
## practice course built into the game out of the rotation.
func _test_the_courses_arrived() -> void:
	_section("the delivered courses are what the server plays")

	var said := _says(_world())
	_check(int(said.get("courses", 0)) >= 11, "the server read the delivered courses",
		"%s courses" % said.get("courses", 0))
	_check(int(said.get("arenas", 0)) >= 6, "and the arenas", "%s arenas" % said.get("arenas", 0))

	var started := await _until(func() -> bool: return int(_says(_world()).get("round", 0)) > 0, 40.0)
	_check(started, "a round begins")

	var course := str(_says(_world()).get("course", ""))
	_check(course.begins_with("wo_") and course != "wo_practice", "on a delivered course", course)

	var players := int(_says(_world()).get("players", 0))
	_check(players >= 3, "with stand-ins racing the client", "%d players" % players)
	_done()


## The client was never sent a course file. It built the course from the document the server
## sent in STAGE, and it is the same course.
func _test_the_client_builds_the_course() -> void:
	_section("the client builds the course from the document it was sent")

	var arrived := await _until(
		func() -> bool:
			var world := _client_world()
			return world != null and str(_says(world).get("course", "-")) != "-",
		30.0
	)

	if not _check(arrived, "the client's world has a course"):
		_done()
		return

	var server_course := str(_says(_world()).get("course", ""))
	var client_course := str(_says(_client_world()).get("course", ""))
	_check(client_course == server_course, "the same one the server is running", "%s vs %s" % [client_course, server_course])

	var stage: Variant = _client_world().get("stage")
	var pieces := (stage as Object).get("pieces") as Array if stage is Object else []
	var server_stage: Variant = _world().get("stage")
	var server_pieces := (server_stage as Object).get("pieces") as Array if server_stage is Object else []
	_check(not pieces.is_empty() and pieces.size() == server_pieces.size(), "with every piece built",
		"%d of %d" % [pieces.size(), server_pieces.size()])
	_check(_client_world().get("catalogue") == null, "and no course files of its own")
	_done()


## Two sides across the line: the arena, its floor and its gallery cross the socket.
func _test_a_final_death_crosses() -> void:
	_section("a final death crosses the socket")

	var world := _world()
	var on_course := await _until(func() -> bool: return int(_says(world).get("phase_id", 0)) == 2, 30.0)
	_check(on_course, "the course opens")

	# Everybody across, so two or more sides finished and the course closes into a fight.
	var finished := 0

	for key: Variant in (world.get("players") as Dictionary):
		var runner: Object = (world.get("players") as Dictionary)[key]
		runner.set("finished", true)
		finished += 1
		runner.set("place", finished)

	world.set("_finish_count", finished)

	var handover := await _until(func() -> bool: return int(_says(world).get("phase_id", 0)) >= 3, 15.0)
	_check(handover, "the course closes into a final death")

	var arena := str(_says(world).get("arena", "-"))
	_check(arena.begins_with("wo_arena"), "in a delivered arena", arena)

	var client_arena := await _until(
		func() -> bool: return str(_says(_client_world()).get("arena", "-")) == arena, 20.0
	)
	_check(client_arena, "and the client built the same arena")

	var pickups := int(_says(world).get("pickups", 0))
	var client_pickups := await _until(
		func() -> bool: return int(_says(_client_world()).get("pickups", 0)) == pickups, 10.0
	)
	_check(pickups > 0 and client_pickups, "with the same weapons on its floor", "%d" % pickups)
	_check(_refused[0] == "", "and the client still connected", _refused[0])
	_done()


func _test_still_serving() -> void:
	_section("the game's own console still answers")

	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server().console.execute("wo_courses", context)

	var listed := "\n".join(captured)
	_check(listed.contains("wo_grand_tour") and listed.contains("wo_arena_pit"),
		"wo_courses lists the delivered courses and arenas")
	_done()
