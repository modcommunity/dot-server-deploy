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

## The server in a World3D of its own, away from the client in this process. See the helper.
const ServerWorld := preload("res://examples/server_world.gd")
const CONTENT := "res://content"
const DATA := "user://tmc_deathrun_client"

const GAME := "deathrun"
const CONTENT_ID := "tmc/deathrun"
const MAPS_KEY := "tmc/deathrun_maps@0.1.0"
const MODULE := "deathrun"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 28

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _client_side: Node = null
var _link: DotClientLink = null
## A second real client, on its own multiplayer branch: a HIT sent to everybody would reach it.
var _bystander_side: Node = null
var _bystander: DotClientLink = null

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
			await _test_teammate_cvar_reaches_the_client()
			await _test_a_hit_is_the_shooters()
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

	if _bystander != null and is_instance_valid(_bystander):
		_bystander.disconnect_from_server("test over")

	await get_tree().process_frame

	if _client_side != null and is_instance_valid(_client_side):
		remove_child(_client_side)
		_client_side.queue_free()
		_client_side = null
		_link = null

	if _bystander_side != null and is_instance_valid(_bystander_side):
		remove_child(_bystander_side)
		_bystander_side.queue_free()
		_bystander_side = null
		_bystander = null

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


## [b]A landed shot is HIT to the shooter's client alone, over the socket.[/b] mg-deathrun's
## headless_net proves the bridge's routing over a loopback queue (codec, registry and per-peer
## routing real; no socket, no RPC routing). Here the gun is the delivered client's own: its
## `_firing` goes into the command it sends, the server's weapon fires from that command and
## lag-compensates, `DrGame.hit_landed` names the shooter, and the HIT crosses a real
## DotClientLink to the shooter, while a second real client, connected and playing, hears none.
## Then the owner's magazine, spent on the server, is what the drawn gun shows once quiet
## (`DrClient.correct_drawn`). mg-smash-copter, mg-prop-hunt and mg-wipeout route HIT with the
## same lines of their own bridges (`hit_landed` → `peer_for_player(session_of(id))` → `_tell`).
## Armed with a pack whose bridge sends no HIT (the first check fails) and one that broadcasts
## it (the second fails).
func _test_a_hit_is_the_shooters() -> void:
	_section("a shot from the delivered client lands, and only the shooter is told")

	# The bystander: a second real client, on its own branch, seated and playing.
	_bystander_side = Node.new()
	_bystander_side.name = "BystanderSide"
	add_child(_bystander_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _bystander_side.get_path())
	_bystander = DotClientLink.new()
	_bystander.name = "Server"
	_bystander.player_name = "Bystander"
	_bystander_side.add_child(_bystander)
	var seated := [false]
	_bystander.spawned.connect(func() -> void: seated[0] = true)
	var _going: DotResult = await _bystander.connect_to_server("127.0.0.1:%d" % _host.config.server.port)
	var joined := await _until(func() -> bool: return seated[0] and _scene_of(_bystander) != null \
		and _scene_of(_bystander).get("bridge") != null, 45.0)

	# Running, so somebody reaching the finish calls the activators and is handed a gun.
	var world := _world()
	var running := await _until(func() -> bool: return int(_says(world).get("phase_id", 0)) == _phase(&"RUN"), 60.0)
	var shooter_scene := _scene_of(_link)
	var me_id: StringName = (shooter_scene.get("player") as Node).get("player_id") if shooter_scene != null and shooter_scene.get("player") != null else &""
	var players: Dictionary = world.get("players")
	var server_me: Node = players.get(me_id)
	if not _check(joined and running and server_me != null,
			"a second real client is in, and a round is running",
			"joined %s, phase %s, shooter %s" % [joined, _says(world).get("phase", "?"), me_id]):
		_done()
		return

	# A runner across the finish: the activators are called and sent to the end armed, and the
	# runner who finished is armed there too. The shooter if it is a runner, otherwise a stand-in
	# runner (the shooter is then an activator, called to the end all the same).
	var runners := int((world.get_script() as Script).get_script_constant_map().get("RUNNERS", 1))
	var finisher: Node = server_me
	if int(world.call("team_of", me_id)) != runners:
		for id: StringName in players:
			if bool(players[id].get("is_bot")) and int(world.call("team_of", id)) == runners and bool(players[id].call("is_alive")):
				finisher = players[id]
				break
	var finish: Dictionary = (world.get("course_doc") as Dictionary).get("finish", {})
	finisher.call("place_at", _vec3(finish.get("at")), 0.0)
	var armed := await _until(func() -> bool: return bool(server_me.get("at_end")) and server_me.get("weapons") != null \
		and int(_says(world).get("phase_id", 0)) == _phase(&"SHOWDOWN") and shooter_scene.get("weapons") != null, 15.0)

	# A target three metres down the aim: a stand-in, held still (and alive) long
	# enough that the server's rewind to what this client saw finds it there.
	# On the other side: a team-mate is passed through under the stock mp_teammate_passthrough.
	var target: Node = null
	var my_side := int(world.call("team_of", me_id))
	for id: StringName in players:
		var other: Node = players[id]
		if target == null and other != server_me and bool(other.get("is_bot")) and bool(other.call("is_alive")) \
				and int(world.call("team_of", id)) != my_side:
			target = other
	var combat: Object = world.get("combat")
	var shooter_health: Object = combat.call("health_of", int(server_me.get("entity_id")))
	var target_health: Object = combat.call("health_of", int(target.get("entity_id"))) if target != null else null
	if not _check(armed and target_health != null and shooter_health != null,
			"the shooter reaches the end armed, with a stand-in to shoot",
			"armed %s (at the end %s, gun %s, drawn %s, phase %s), target %s" % [
				armed, server_me.get("at_end"), server_me.get("weapons") != null,
				shooter_scene.get("weapons") != null, _says(world).get("phase", "?"), target]):
		_done()
		return
	shooter_health.set("cannot_die", true)
	target_health.set("cannot_die", true)

	# Straight ahead and fifteen degrees down, so the ray meets the chest 1.8 m away whatever
	# the stand-in is standing on (between the chest and head boxes there is a gap).
	var sampler: Object = shooter_scene.get("_sampler")
	sampler.call("look_at_angles", 0.0, -15.0)
	var aim := DotWeaponCommand.new()
	var spot: Vector3 = (server_me as Node3D).global_position + aim.aim_direction() * 1.8
	var hold := func() -> void: target.call("place_at", spot, 180.0)

	var shooter_heard := [0]
	var bystander_heard := [0]
	var shooter_bridge: Object = shooter_scene.get("bridge")
	var bystander_bridge: Object = _scene_of(_bystander).get("bridge")
	shooter_bridge.connect(&"hit_received", func(_p: Vector3, _k: bool, _h: bool) -> void: shooter_heard[0] += 1)
	bystander_bridge.connect(&"hit_received", func(_p: Vector3, _k: bool, _h: bool) -> void: bystander_heard[0] += 1)
	var landed := [0]
	world.connect(&"hit_landed", func(id: StringName, _p: Vector3, _k: bool, _h: bool) -> void:
		if id == me_id:
			landed[0] += 1)

	var gun: Object = (server_me.get("weapons") as Object).get("arsenal")
	var full := int((gun.call("current") as Object).get("magazine"))
	# Long enough for the new aim to reach the server and the stand-in to settle where it is held.
	await _hold_for(hold, 2.0)
	shooter_scene.set("_firing", true)
	await _hold_for(hold, 0.25)
	shooter_scene.set("_firing", false)
	await _hold_for(hold, 1.5)
	_check(landed[0] > 0 and shooter_heard[0] > 0, "the server judged a hit, and the shooter's client is told",
		"%d landed on the server, %d HIT heard by the shooter" % [landed[0], shooter_heard[0]])
	_check(bystander_heard[0] == 0, "and the other client is told nothing", "%d heard" % bystander_heard[0])

	# The count: what the server spent is what the drawn gun shows once the trigger is quiet. The
	# drawn gun predicted the same shots, so it is put back to full first: only the owner's
	# magazine crossing in the snapshot (`net_magazine`) and `DrClient.correct_drawn` bring it down.
	var server_mag := int((gun.call("current") as Object).get("magazine"))
	var drawn: Object = (shooter_scene.get("weapons") as Object).get("arsenal")
	(drawn.call("current") as Object).set("magazine", full)
	var agreed := await _until(func() -> bool:
		return int((drawn.call("current") as Object).get("magazine")) == int((gun.call("current") as Object).get("magazine")), 5.0)
	_check(server_mag < full and agreed, "the drawn gun takes the server's count once quiet",
		"full %d, server %d, drawn %d" % [full, server_mag, int((drawn.call("current") as Object).get("magazine"))])

	shooter_health.set("cannot_die", false)
	target_health.set("cannot_die", false)
	_check(_refused[0] == "", "and the shooter is still connected", _refused[0])
	_done()


## The delivered client scene under [param link]'s `GameRoot` (the child that has a `game`).
func _scene_of(link: DotClientLink) -> Node:
	var root := link.get_node_or_null(^"GameRoot") if link != null else null
	if root == null:
		return null
	for child in root.get_children():
		if child.get("game") is Object:
			return child
	return null


## DrGame.Phase's value for [param name], read from the server's world (nothing here can name it).
func _phase(name: StringName) -> int:
	var phases: Variant = (_world().get_script() as Script).get_script_constant_map().get("Phase")
	return int((phases as Dictionary).get(name, -1)) if phases is Dictionary else -1


func _vec3(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	return Vector3.ZERO


## Real physics frames for [param seconds], calling [param each] on every one.
func _hold_for(each: Callable, seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		each.call()
		await get_tree().physics_frame


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
