extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] Prop Hunt is a
# delivered pack at `res://dot_cloud/tmc/prophunt/<version>/…`, and its maps are a second pack
# at `res://dot_cloud/tmc/prophunt_maps/<version>/…`. Everything about the game is reached
# through the host's module table and `describe()`, as deathrun_client does.

## A REAL client, over a REAL socket, in a DELIVERED Prop Hunt, with its maps delivered as a
## server-only pack beside it.
##
## [codeblock]
## godot --headless --path . res://examples/prophunt_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/prophunt` and `dist/tmc/prophunt_maps`
## (`./server pack prophunt_maps --source games/mg-prop-hunt-maps`, then prophunt).
##
## [b]What only this can see.[/b] mg-prop-hunt's suites run inside its own project, where its
## maps are a link at `res://maps` and its props, their measured sizes and its taunts are files
## at `res://`. Delivered, every one of those is somewhere else: the game is mounted under a
## versioned prefix and must find its catalogue, its models and its taunt list through
## `PhPaths.rebase`, and the maps are `server_dependencies` mounted on the server alone, found
## only if the prefix the game computes from the pinned key is where the pack really mounted. A
## wrong guess at any of them is silent: a server that plays only the practice house, a
## catalogue of nothing so every map is built bare, a taunt list nobody can play. So this
## asserts each one from the delivered process, and that the client, never sent a map file,
## built the same map, with every prop in it, from the document.

const CONFIG := "res://examples/fixtures/prophunt"

## The server in a World3D of its own, away from the client in this process. See the helper.
const ServerWorld := preload("res://examples/server_world.gd")
const CONTENT := "res://content"
const DATA := "user://tmc_prophunt_client"

const GAME := "prophunt"
const CONTENT_ID := "tmc/prophunt"
const MAPS_KEY := "tmc/prophunt_maps@0.1.0"
const MODULE := "prophunt"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 34

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
	print("dot-server-deploy: a real client in a delivered Prop Hunt")

	DotPaths.remove_tree(DATA)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/prophunt")) \
			or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc/prophunt_maps")):
		print("skipped: dist/tmc/prophunt and dist/tmc/prophunt_maps are not published here")
		print("  ./server pack prophunt_maps --source games/mg-prop-hunt-maps")
		print("  ./server pack prophunt --source games/mg-prop-hunt")
		get_tree().quit(0)
		return

	if await _boot():
		if await _test_connect():
			await _test_the_packs_mounted()
			await _test_the_maps_arrived()
			await _test_the_client_builds_the_map()
			await _test_a_broken_prop_reaches_the_client()
			await _test_a_leant_prop_is_drawn_on_the_floor()
			await _test_teammate_cvar_reaches_the_client()
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
	_check(path.begins_with("res://dot_cloud/tmc/prophunt/"), "its module is the mounted copy", path)

	var server_only: PackedStringArray = _server().games.current_server_dependencies()
	_check(server_only.has(MAPS_KEY), "the maps are its server-only dependency", str(server_only))

	var file := DotCloudClient.mount_prefix_for(&"tmc/prophunt_maps", "0.1.0").path_join("maps/ph_school.json")
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
	_check(map.begins_with("ph_"), "on a map", map)

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


## [b]The BROKEN event, which a shell parses only if it has the game's newest event table.[/b]
## A prop the server breaks is broken on the delivered client and throws its pieces there. The
## server end is the two lines the game's own shot path runs (`break_prop`, then
## `prop_broken`), so what is measured is the bridge's broadcast and the client's decoding of
## an event appended last to `PhEvents.Kind`; the game's own suites never see it cross a mount.
func _test_a_broken_prop_reaches_the_client() -> void:
	_section("a prop the server breaks is broken on the delivered client")

	var server_game := _world()
	var client_game := _client_world()
	var server_map: Object = server_game.get("map") if server_game != null else null
	var client_map: Object = client_game.get("map") if client_game != null else null
	var catalogue: Object = server_game.get("props_catalogue") if server_game != null else null
	var index := -1

	if server_map != null and catalogue != null:
		var props: Array = server_map.get("props")
		for i in range(props.size()):
			var prop: Dictionary = props[i]
			if not bool(prop["broken"]) and float(catalogue.call("breaks", prop["id"])) > 0.0:
				index = i
				break

	if not _check(index >= 0 and client_map != null, "the running map has a prop that breaks"):
		_done()
		return

	var _broke: bool = server_map.call("break_prop", index)
	server_game.emit_signal("prop_broken", index, Vector3.FORWARD)

	var seen := await _until(
		func() -> bool:
			var props: Array = client_map.get("props")
			return index < props.size() and bool((props[index] as Dictionary)["broken"]),
		10.0
	)
	_check(seen, "and the client has it broken too", "prop %d (%s)" % [index, server_map.call("prop_id", index)])
	_check(client_game.get_node_or_null(NodePath("Debris_%d" % index)) != null,
		"and throws its pieces where it stood")
	_done()


## [b]dot-props API level 4, drawn by the delivered client.[/b] A stand-in hides as the
## tallest Food or Survival kit piece (models whose texture is an external `Textures/colormap.png`
## beside them, which must load from inside the mount) and is turned on its nose, twelve steps of
## fifteen degrees. The client must draw the model, not the box stand-in for one that would not
## load, with its texture, upside down, its lowest point on the floor: turned about its foot, as
## the first version did, the whole bottle was under it.
func _test_a_leant_prop_is_drawn_on_the_floor() -> void:
	_section("a leant prop is drawn on the floor by the delivered client")

	var server_game := _world()
	var client_game := _client_world()
	var catalogue: Object = server_game.get("props_catalogue") if server_game != null else null
	var rules: Variant = server_game.get("rules") if server_game != null else null
	var kit := &""
	var tallest := 0.0

	if catalogue != null and rules is DotPropDisguiseRules:
		for key: Variant in (catalogue.get("props") as Dictionary).keys():
			var id := StringName(str(key))
			var name := String(id)
			# Only pieces still drawn from the kit's atlas: barrels, boxes, bottles and the food pieces
			# were rebuilt with flat colours of their own and carry no texture to look for.
			if name not in ["survival_chest", "survival_workbench", "survival_signpost", "survival_bedroll",
					"survival_barrel_open", "survival_box_open"]:
				continue
			var size: Vector3 = catalogue.call("size_of", id)
			if bool(catalogue.call("may_disguise", id)) and size.y > tallest \
					and DotPropDisguise.may_take(size, rules as DotPropDisguiseRules).ok:
				kit = id
				tallest = size.y

	# A hunter's client is told nothing of what anybody became while the props hide (the
	# bridge holds every DISGUISE back until the seek), and this client may be a hunter. So the
	# lean is put on once the hunters are let go, when every client is told.
	var seeking := await _until(func() -> bool: return int(server_game.get("phase")) == 2, 45.0)  # Phase.SEEK

	var who := &""
	var players: Dictionary = server_game.get("players") if server_game != null else {}

	for key: Variant in players.keys():
		var id := StringName(str(key))
		var player: Object = players[key]
		if int(server_game.call("team_of", id)) == 1 and bool(player.get("is_bot")) and bool(player.call("is_alive")):
			who = id
			break

	if not _check(seeking and kit != &"" and who != &"" and client_game != null,
			"the seek begins, with a kit piece to hide as and a stand-in on the props",
			"seeking %s, kit %s, stand-in %s" % [seeking, kit, who]):
		_done()
		return

	var worn: bool = server_game.call("disguise_as", who, kit)
	for _step in range(12):
		var _turned: bool = server_game.call("turn", who, 1)  # Turn.TILT_FORWARD

	var leant: DotPropDisguise = (players[who] as Object).get("disguise") if players.has(who) \
		else DotPropDisguise.new()
	_check(worn and absf(absf(leant.pitch) - 180.0) < 0.5, "the server dresses it and turns it on its nose",
		"worn %s, pitch %.1f" % [worn, leant.pitch])

	# Sampled in the frame the client shows it leant: a stand-in's own brain may straighten it
	# later, and the drawing is only checked against the lean it was drawn with.
	var sample := {}
	var drawn := await _until(
		func() -> bool:
			var mine: Object = (client_game.get("players") as Dictionary).get(who)
			if mine == null:
				sample["seen"] = "no such player on the client: %s" % [(client_game.get("players") as Dictionary).keys()]
				return false
			var d: DotPropDisguise = mine.get("disguise")
			var model: Node3D = mine.get("prop_model")
			sample["seen"] = "%s pitch %.0f, model %s" % [d.prop_id if d != null else &"-",
				d.pitch if d != null else 0.0, "none" if model == null else "shown" if model.visible else "hidden"]
			if d == null or d.prop_id != kit or absf(d.pitch) < 90.0 or model == null \
					or not model.is_inside_tree() or not model.visible:
				return false
			sample["floor"] = float((mine.get("controller") as Object).get("state").get("position").y)
			sample["low"] = INF
			sample["high"] = -INF
			sample["boxes"] = 0
			sample["textured"] = 0
			for node in model.find_children("*", "MeshInstance3D", true, false):
				var mesh := (node as MeshInstance3D).mesh
				if mesh == null:
					continue
				if mesh is BoxMesh:
					sample["boxes"] = int(sample["boxes"]) + 1
				var box := (node as MeshInstance3D).global_transform * mesh.get_aabb()
				sample["low"] = minf(float(sample["low"]), box.position.y)
				sample["high"] = maxf(float(sample["high"]), box.end.y)
				for surface in range(mesh.get_surface_count()):
					var material := (node as MeshInstance3D).get_active_material(surface) as BaseMaterial3D
					if material != null and material.albedo_texture != null:
						sample["textured"] = int(sample["textured"]) + 1
					else:
						sample["bare"] = "%s %s" % [(node as MeshInstance3D).get_active_material(surface), model.get_path()]
			return float(sample["high"]) > float(sample["low"]),
		15.0
	)

	_check(drawn, "the client draws the stand-in as that piece, leant", str(sample))

	var low := float(sample.get("low", INF)) - float(sample.get("floor", 0.0))
	var high := float(sample.get("high", -INF)) - float(sample.get("floor", 0.0))
	_check(drawn and absf(low) < 0.05 and high > tallest * 0.8,
		"with its lowest point on the floor and the rest of it above", "low %+.3f, high %+.3f of %.3f" % [low, high, tallest])
	_check(drawn and int(sample.get("boxes", 1)) == 0, "as the model, not the box that stands in for one that would not load")
	_check(drawn and int(sample.get("textured", 0)) > 0,
		"with the kit's external texture, loaded from inside the mount", str(sample))
	_done()


func _test_still_serving() -> void:
	_section("the game's own console still answers")

	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server().console.execute("ph_maps", context)

	var listed := "\n".join(captured)
	_check(listed.contains("ph_school") and listed.contains("ph_woods"),
		"ph_maps lists the delivered maps", listed)
	_done()


## [b]dot-combat's `mp_teammate_passthrough` on the delivered client.[/b] The client traces its
## own shots for tracers and impacts; on its default 1 against a server on 0 or 2 they ended in,
## or went through, a team-mate where the server's shot did the opposite. The game's client
## calls `game.combat.follow_cvars(link)`, and this is the only place that call runs out of a
## mount against a real server: the game's own suites only see the cvar flagged replicated.
func _test_teammate_cvar_reaches_the_client() -> void:
	_section("the server's mp_teammate_passthrough reaches the client's combat, live")

	var cvar: DotConVar = _server().console.find_cvar("mp_teammate_passthrough")
	var held := cvar.get_string() if cvar != null else ""
	_check(cvar != null and cvar.has_flag(DotConVar.FLAG_REPLICATED)
		and await _until(func() -> bool: return _client_pass_through() == int(held), 10.0),
		"the delivered game's cvar is replicated and the client joined on its level",
		"server %s, client %d" % [held, _client_pass_through()])

	var _two := _server().console.set_cvar("mp_teammate_passthrough", "2")
	_check(await _until(func() -> bool: return _client_pass_through() == 2, 10.0),
		"the server goes to 2 and the client's combat rules follow", "client %d" % _client_pass_through())

	var _zero := _server().console.set_cvar("mp_teammate_passthrough", "0")
	_check(await _until(func() -> bool: return _client_pass_through() == 0, 10.0),
		"and to 0", "client %d" % _client_pass_through())

	if held != "":
		var _back := _server().console.set_cvar("mp_teammate_passthrough", held)
	_done()


## The client's `game.combat.rules.pass_through_level()`, found by walking the link's
## `GameRoot` (nothing here can name the game's types); -1 when there is none.
func _client_pass_through() -> int:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null

	if root == null:
		return -1

	for child in root.get_children():
		var world: Variant = child.get("game")
		var combat: Variant = (world as Object).get("combat") if world is Object else null
		var rules: Variant = (combat as Object).get("rules") if combat is Object else null

		if rules is Object and (rules as Object).has_method("pass_through_level"):
			return int((rules as Object).call("pass_through_level"))

	return -1
