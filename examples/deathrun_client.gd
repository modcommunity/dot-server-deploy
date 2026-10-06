extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Deathrun is a
# delivered pack at `res://dot_cloud/tmc/deathrun/<version>/…`, and its courses are a second
# pack at `res://dot_cloud/tmc/deathrun_maps/<version>/…`. Everything about the game is
# reached through the host's module table and `describe()`, as wipeout_client does.

## A REAL client, over a REAL socket, in a DELIVERED Deathrun — with its courses delivered as
## a server-only pack beside it.
##
## [codeblock]
## godot --headless --path . res://examples/deathrun_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/deathrun` and `dist/tmc/deathrun_maps`
## (`./server pack deathrun_maps --source games/mg-deathrun-maps`, then deathrun).
##
## [b]What only this can see.[/b] mg-deathrun's suites run inside its own project, where its
## courses are a link at `res://courses`. Delivered, they are `server_dependencies`, mounted on
## the server alone, and the game finds them only if the prefix it computes from the pinned key
## is where the pack really mounted; a wrong guess is a server that plays only the practice
## course built into the game. So this asserts the courses arrived, a round runs, the client —
## never sent a course file — built the same course with the same traps from the STAGE
## document, and an activator's press crosses the socket.

const CONFIG := "res://examples/fixtures/deathrun"
const CONTENT := "res://content"
const DATA := "user://tmc_deathrun_client"

const GAME := "deathrun"
const CONTENT_ID := "tmc/deathrun"
const MAPS_KEY := "tmc/deathrun_maps@0.1.0"
const MODULE := "deathrun"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 19

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
	print("dot-server-deploy: a real client in a delivered Deathrun")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/deathrun")) \
			or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/deathrun_maps")):
		print("skipped: dist/tmc/deathrun and dist/tmc/deathrun_maps are not published here")
		print("  ./server pack deathrun_maps --source games/mg-deathrun-maps")
		print("  ./server pack deathrun --source games/mg-deathrun")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			await _test_the_packs_mounted()
			await _test_the_courses_arrived()
			await _test_the_client_builds_the_course()
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
	_check(path.begins_with("res://dot_cloud/tmc/deathrun/"), "its module is the mounted copy", path)

	var server_only: PackedStringArray = _server().games.current_server_dependencies()
	_check(server_only.has(MAPS_KEY), "the courses are its server-only dependency", str(server_only))

	var file := DotCloudClient.mount_prefix_for(&"tmc/deathrun_maps", "0.1.0").path_join("courses/dr_ice_works.json")
	_check(FileAccess.file_exists(file), "and are mounted where the game computes they are", file)
	_done()


## The courses are content: two read out of the mount beside the practice one built in.
func _test_the_courses_arrived() -> void:
	_section("the delivered courses are what the server plays")

	var said := _says(_world())
	_check(int(said.get("courses", 0)) >= 3, "the server read the delivered courses",
		"%s courses" % said.get("courses", 0))

	var started := await _until(func() -> bool: return int(_says(_world()).get("round", 0)) > 0, 40.0)
	_check(started, "a round begins")

	var course := str(_says(_world()).get("course", ""))
	_check(course.begins_with("dr_"), "on a course", course)

	var players := int(_says(_world()).get("players", 0))
	_check(players >= 3, "with stand-ins beside the client", "%d players" % players)
	_done()


## The client was never sent a course file. It built the course from the document the server
## sent, and it is the same course with the same traps.
func _test_the_client_builds_the_course() -> void:
	_section("the client builds the course from the document it was sent")

	var arrived := await _until(
		func() -> bool:
			var world := _client_world()
			return world != null and str(_says(world).get("course", "-")) != "-" \
				and str(_says(world).get("course", "")) == str(_says(_world()).get("course", ""))
				,
		30.0
	)

	_check(arrived, "the client's world has the course the server is running",
		"%s vs %s" % [_says(_client_world()).get("course", "?"), _says(_world()).get("course", "?")])

	var stage: Variant = _client_world().get("stage") if _client_world() != null else null
	var server_stage: Variant = _world().get("stage")
	var traps := int((stage as Object).call("trap_count")) if stage is Object else -1
	var server_traps := int((server_stage as Object).call("trap_count")) if server_stage is Object else -2
	_check(traps > 0 and traps == server_traps, "with every trap built", "%d of %d" % [traps, server_traps])

	var catalogue: Variant = _client_world().get("catalogue") if _client_world() != null else null
	var own := int((catalogue as Object).get("courses").size()) if catalogue is Object else 0
	_check(own <= 1, "and no delivered course files of its own", "%d courses" % own)
	_check(_refused[0] == "", "and the client is still connected", _refused[0])
	_done()


func _test_still_serving() -> void:
	_section("the game's own console still answers")

	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server().console.execute("dr_courses", context)

	var listed := "\n".join(captured)
	_check(listed.contains("dr_ice_works") and listed.contains("dr_foundry"),
		"dr_courses lists the delivered courses", listed)
	_done()
