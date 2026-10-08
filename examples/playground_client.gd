extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] The playground
# is a delivered pack at `res://dot_cloud/tmc/playground/<version>/…`, and its custom maps are
# a second pack at `res://dot_cloud/tmc/playground_maps/<version>/…`. Everything about the
# game is reached through the module's `game`, the client's `playground` and `describe()`.

## A REAL client, over a REAL socket, in a DELIVERED playground — with its custom maps
## delivered as a `dependencies` pack beside it, mounted on the server AND the client.
##
## [codeblock]
## godot --headless --path . res://examples/playground_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/playground` and `dist/tmc/playground_maps`
## (`./server pack playground_maps --source games/game-playground-maps`, then playground).
##
## [b]What only this can see.[/b] The playground's suites read the maps from a link at
## `res://maps/custom`. Delivered, they are a pack of their own that the CLIENT mounts too
## (`dependencies`, the first game to use them), because a playground map is a document the
## client builds itself: boxes, and props the server puts down. A prefix either end computes
## wrongly is a catalogue with the custom maps silently missing on that end, and a map change
## the client cannot follow. So this asserts the pack is a client dependency, mounted where
## both ends compute, that both catalogues list the maps from that mount, that a change to
## pgc_town is followed by the client with every box built, and that the map's props (doors
## on buttons, buggies) reach the client from the server.

const CONFIG := "res://examples/fixtures/playground"
const CONTENT := "res://content"
const DATA := "user://tmc_playground_client"

const GAME := "playground"
const CONTENT_ID := "tmc/playground"
const MAPS_ID := &"tmc/playground_maps"
const MAPS_VERSION := "0.1.0"
const MAPS_KEY := "tmc/playground_maps@0.1.0"
const MODULE := "playground"
const MAP := &"pgc_town"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 21

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
	print("dot-server-deploy: a real client in a delivered playground, with its maps pack")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/playground")) \
			or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/playground_maps")):
		print("skipped: dist/tmc/playground and dist/tmc/playground_maps are not published here")
		print("  ./server pack playground_maps --source games/game-playground-maps")
		print("  ./server pack playground --source games/game-playground")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			_test_the_packs_mounted()
			await _test_both_catalogues()
			await _test_the_client_follows_a_custom_map()
			await _test_the_maps_props_cross()
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


## The CLIENT's playground: the delivered client scene under the link's `GameRoot`, which
## holds it as `playground`. Found by walking, because nothing here can name its type.
func _client_client() -> Object:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null
	if root == null:
		return null
	for child in root.get_children():
		if child.get("playground") is Object:
			return child
	return null


func _client_world() -> Object:
	var client := _client_client()
	return client.get("playground") as Object if client != null else null


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
	_section("the playground and its maps pack are mounted on both ends")

	var entry := _server().games.current()
	_check(entry != null and String(entry.content_id) == CONTENT_ID, "the current game is the delivered one")

	var module: DotModule = _server().modules.get_module(MODULE)
	var script: Variant = module.get_script() if module != null else null
	var path := String((script as Resource).resource_path) if script != null else ""
	_check(path.begins_with("res://dot_cloud/tmc/playground/"), "its module is the mounted copy", path)

	var deps: PackedStringArray = _server().games.current_dependencies()
	_check(deps.has(MAPS_KEY), "the maps are a CLIENT dependency, not server-only", str(deps))
	_check(_link.content_extra.has(MAPS_KEY), "and the client was told to fetch them", str(_link.content_extra))

	var file := DotCloudClient.mount_prefix_for(MAPS_ID, MAPS_VERSION).path_join("maps/%s.json" % MAP)
	_check(FileAccess.file_exists(file), "mounted where both ends compute they are", file)
	_done()


## Both catalogues list the custom maps, and from the mount, not from a copy inside the game.
func _test_both_catalogues() -> void:
	_section("both catalogues list the custom maps, from the maps pack")

	var prefix := DotCloudClient.mount_prefix_for(MAPS_ID, MAPS_VERSION)
	var ready := await _until(func() -> bool: return _client_world() != null, 30.0)
	_check(ready, "the client built its playground")

	for side: Array in [["the server", _world()], ["the client", _client_world()]]:
		var world: Object = side[1]
		var maps: Object = world.get("maps") if world != null else null
		var catalogue: Object = maps.get("catalogue") if maps != null else null
		var def: Variant = catalogue.call("get_map", MAP) if catalogue != null and catalogue.has_method("get_map") else null
		var doc := str((def as Object).get("meta").get("doc", "")) if def is Object else ""
		_check(doc.begins_with(prefix), "%s lists %s from the pack" % [side[0], MAP], doc if doc != "" else "not listed")
	_done()


func _test_the_client_follows_a_custom_map() -> void:
	_section("a change to a custom map is followed, box for box")

	var changed: Variant = await _world().call("change_map", MAP)
	_check(changed is DotResult and (changed as DotResult).ok, "the server changes to %s" % MAP,
		str((changed as DotResult).error) if changed is DotResult and not (changed as DotResult).ok else "")

	var followed := await _until(
		func() -> bool:
			var world := _client_world()
			var maps: Object = world.get("maps") if world != null else null
			var current: Object = maps.get("current") if maps != null else null
			return current != null and current.get("id") == MAP,
		30.0
	)
	_check(followed, "the client follows it")

	var server_boxes := _boxes(_world())
	var client_boxes := _boxes(_client_world())
	_check(server_boxes > 100 and client_boxes == server_boxes, "and builds every box the server did",
		"%d on the client, %d on the server" % [client_boxes, server_boxes])
	_done()


func _test_the_maps_props_cross() -> void:
	_section("the map's props are the server's, drawn on the client")

	var owner: StringName = _world().get("MAP_OWNER")
	var server_props: Array = (_world().get("props") as Object).call("props_of", owner)
	_check(server_props.size() >= 40, "the server put down the map's props", "%d props" % server_props.size())

	var doors := [0]
	var arrived := await _until(
		func() -> bool:
			doors[0] = 0
			var bridge: Object = _client_client().get("bridge") if _client_client() != null else null
			var nets: Variant = bridge.get("_prop_nets") if bridge != null else null
			if not (nets is Dictionary):
				return false
			for behaviour: Variant in (nets as Dictionary).values():
				var node: Variant = (behaviour as Object).get("prop")
				if node is Node and is_instance_valid(node) and node.get("def") is DotPropDef \
						and (node.get("def") as DotPropDef).id == &"door":
					doors[0] += 1
			return doors[0] >= 5,
		20.0
	)
	_check(arrived, "and the client draws them: five doors", "%d doors" % doors[0])
	var client_owned: Array = (_client_world().get("props") as Object).call("props_of", owner)
	_check(client_owned.is_empty(), "and puts down none of its own")
	_done()


func _test_still_serving() -> void:
	_section("the game's own console still answers")

	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server().console.execute("pg_status", context)
	var said := "\n".join(captured)
	_check(said.contains(String(MAP)), "pg_status says the server is on the custom map", said.left(200))
	_done()


## Every static box a map built under its node: the geometry, which a document map builds
## the same on both ends or the client is walking through a different world.
func _boxes(world: Object) -> int:
	var map: Variant = world.call("current_map_node") if world != null and world.has_method("current_map_node") else null
	if not (map is Node):
		return -1
	var count := 0
	var stack: Array[Node] = [map as Node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is StaticBody3D:
			count += 1
		stack.append_array(node.get_children())
	return count
