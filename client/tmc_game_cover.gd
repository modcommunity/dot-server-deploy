class_name TmcGameCover
extends Node

## Keeps the shell's loading screen over a game until it is ready to be seen, then draws its
## materials once under it so their shaders compile there and not in the middle of play.
##
## Three kinds of game, best first:
##
## [b]1. A game with a [DotLoadGate][/b] (dot-core). The shell claims the covering job by
## putting [constant HOST_META] on its game root; a gate entering the tree under it calls
## [method adopt_load_gate], shows no cover of its own, and from then on the gate decides:
## its [code]closed[/code] puts the screen up, its [code]progress_changed[/code] is the
## screen's line and bar, its [code]ready_to_show[/code] starts the warm-up here (the tree's
## materials plus the gate's [code]warm_items()[/code]), and [code]host_finished()[/code]
## tells it the screen is down. The gate is reached by name only (signals and methods), so a
## gate from a newer dot-core overlay works with this shell.
##
## [b]2. The duck-typed root contract[/b] ([code]signal ready_to_show[/code],
## [code]is_ready_to_show()[/code], [code]warm_up_items()[/code]) a game built before the gate
## offers. Covered until the signal, for at most [member warm_wait_sec].
##
## [b]3. Anything else.[/b] Covered until a current camera inside the game exists and
## [constant FALLBACK_SETTLE_FRAMES] physics frames have run with it, at most
## [constant FALLBACK_MAX_SEC], then warmed and shown. A game that integrates nothing still
## never shows its first, empty frames.

const CHANNEL := "tmc.game_cover"

## The metadata a [DotLoadGate] looks for on an ancestor; spelled out so this file does not
## depend on the gate's class being present (dot-core's own constant is the same string,
## and the suite checks they agree).
const HOST_META := &"dot_load_gate_host"
## The metadata a gate puts on its parent.
const GATE_META := &"dot_load_gate"

## Physics frames a game with no gate and no contract runs, after its camera appears, before
## it is shown: enough for a body spawned in the air to land and a level built that frame to
## have its collision.
const FALLBACK_SETTLE_FRAMES := 10
## The most a game with no gate is covered for, camera or not.
const FALLBACK_MAX_SEC := 5.0
## The most the material warm-up may take before the screen drops anyway; the web build
## has stalled on it with the match already running underneath.
const DRAW_MAX_SEC := 6.0

## Seconds a game on the root contract has, after it is on screen, to say it is ready.
var warm_wait_sec: float = 20.0

var loading: TmcLoadingScreen = null
var game_root: Node = null

## gate instance id -> gate
var _gates: Dictionary = {}
## gate instance id -> true while this side is drawing its materials
var _warming: Dictionary = {}
## game instance id -> {"game": Node, "since": msec, "settled": frames}
var _fallback: Dictionary = {}


## Claims the covering job for every gate that enters [param root].
func claim(root: Node) -> void:
	game_root = root
	root.set_meta(HOST_META, self)


## Starts covering every game under [member game_root] not seen before. Called once a game
## is on screen.
func watch() -> void:
	if game_root == null:
		return
	for game in game_root.get_children():
		if game.has_meta(&"tmc_warm_watched"):
			continue
		game.set_meta(&"tmc_warm_watched", true)
		var gate := _gate_in(game)
		if gate != null:
			_watch_gate(gate)
		elif game.has_signal(&"ready_to_show"):
			_watch_contract(game)
		else:
			_watch_fallback(game)


## What [method watch] chose for each game: "gate", "contract", "fallback" or "".
func mode_of(game: Node) -> String:
	if _gate_in(game) != null:
		return "gate"
	if _fallback.has(game.get_instance_id()):
		return "fallback"
	if game.has_meta(&"tmc_warm_watched") and game.has_signal(&"ready_to_show"):
		return "contract"
	return ""


# --- 1. A gate --------------------------------------------------------------------------

## Called by a [DotLoadGate] entering the tree under [method claim]'s root.
func adopt_load_gate(gate: Object) -> void:
	var id := gate.get_instance_id()
	if _gates.has(id):
		return
	_gates[id] = gate
	gate.connect(&"closed", _on_gate_closed.bind(gate))
	gate.connect(&"ready_to_show", _on_gate_ready.bind(gate))
	gate.connect(&"progress_changed", _on_gate_progress)
	gate.connect(&"opened", _on_gate_opened.bind(gate))
	if gate is Node:
		(gate as Node).tree_exited.connect(_on_gate_gone.bind(id), CONNECT_ONE_SHOT)
	# A gate made after the game was already on the fallback takes over from it.
	for gid: int in _fallback.keys():
		var game: Node = (_fallback[gid] as Dictionary)["game"]
		if is_instance_valid(game) and gate is Node and game.is_ancestor_of(gate as Node):
			_fallback.erase(gid)
			_watch_gate(gate)


func _gate_in(game: Node) -> Object:
	for id: int in _gates:
		var g: Object = _gates[id]
		if is_instance_valid(g) and g is Node and (game == g or game.is_ancestor_of(g as Node)):
			return g
	# A gate made before the shell claimed the root (an older order, a test).
	if game.has_meta(GATE_META):
		var g: Variant = game.get_meta(GATE_META)
		if g is Object and is_instance_valid(g) and (g as Object).has_method(&"hosted_by"):
			(g as Object).call(&"hosted_by", self)
			return g
	return null


func _watch_gate(gate: Object) -> void:
	if bool(gate.call(&"is_open")):
		return
	loading.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
	loading.set_progress(float(gate.call(&"progress")), str(gate.call(&"status_text")))
	# Already past its holds: the ready_to_show went before anyone listened.
	if int(gate.call(&"state")) == 1:
		_on_gate_ready(gate)


func _on_gate_closed(gate: Object) -> void:
	loading.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
	if is_instance_valid(gate):
		loading.set_progress(float(gate.call(&"progress")), str(gate.call(&"status_text")))


func _on_gate_progress(fraction: float, text: String) -> void:
	if loading.is_showing():
		loading.set_progress(fraction, text)


func _on_gate_ready(gate: Object) -> void:
	var id := gate.get_instance_id()
	if _warming.has(id):
		return
	_warming[id] = true
	loading.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
	var game: Variant = gate.get(&"game_root")
	var items: Array = []
	if game is Node and is_instance_valid(game):
		items = DotRenderWarmup.collect(game)
	var extra: Variant = gate.call(&"warm_items")
	if extra is Array:
		items.append_array(extra)
	await _draw_once(items)
	_warming.erase(id)
	if not is_instance_valid(gate):
		loading.end(TmcLoadingScreen.REASON_WARM)
		return
	# Held again while the materials were drawn: the next ready_to_show comes, and the
	# screen stays up until then.
	if int(gate.call(&"state")) != 1:
		return
	loading.end(TmcLoadingScreen.REASON_WARM)
	gate.call(&"host_finished")


## The gate opens on its own after its host time-out; the screen must not outlive that.
func _on_gate_opened(gate: Object) -> void:
	_warming.erase(gate.get_instance_id())
	if loading.is_showing():
		DotLog.warn(CHANNEL, "the gate opened while the screen was still up; dropping it", {
			"step": "warm-up", "status": str(gate.call(&"status_text"))})
		loading.end(TmcLoadingScreen.REASON_WARM)


func _on_gate_gone(id: int) -> void:
	_gates.erase(id)
	_warming.erase(id)
	if _gates.is_empty() and _fallback.is_empty():
		loading.end(TmcLoadingScreen.REASON_WARM)


# --- 2. The root contract ---------------------------------------------------------------

func _watch_contract(game: Node) -> void:
	game.connect(&"ready_to_show", _on_contract_ready.bind(game))
	var ready := game.has_method(&"is_ready_to_show") and bool(game.call(&"is_ready_to_show"))
	if ready:
		_warm_up(game, true)
	else:
		loading.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
		# A game that never says so must not leave the player behind a picture. The
		# loading screen's own staleness check is 90 s; this is the game's budget.
		get_tree().create_timer(warm_wait_sec).timeout.connect(_contract_wait_over.bind(game))


func _contract_wait_over(game: Node) -> void:
	if is_instance_valid(game) and not game.has_meta(&"tmc_warmed"):
		DotLog.warn(CHANNEL, "the game did not say it was ready to show in time; showing it", {"seconds": warm_wait_sec})
		loading.end(TmcLoadingScreen.REASON_WARM)


## Each later ready_to_show (a map change) warms again without the cover: the content
## screen has usually just lifted, and a second screen over a two-frame warm-up would be a
## flash.
func _on_contract_ready(game: Node) -> void:
	_warm_up(game, not game.has_meta(&"tmc_warmed"))


# --- 3. Nothing at all ------------------------------------------------------------------

func _watch_fallback(game: Node) -> void:
	_fallback[game.get_instance_id()] = {"game": game, "since": Time.get_ticks_msec(), "settled": 0}
	loading.begin(TmcLoadingScreen.REASON_WARM, "", "", true)


func _physics_process(_delta: float) -> void:
	for gid: int in _fallback.keys():
		var entry: Dictionary = _fallback[gid]
		# A Variant: a freed game assigned to a typed `Node` is a script error, and a freed game
		# is exactly the case this test exists for (a solo game replaced by another).
		var game: Variant = entry["game"]
		if not is_instance_valid(game):
			_fallback.erase(gid)
			if _fallback.is_empty() and _gates.is_empty():
				loading.end(TmcLoadingScreen.REASON_WARM)
			continue
		if has_camera_in(game):
			entry["settled"] = int(entry["settled"]) + 1
		var waited := Time.get_ticks_msec() - int(entry["since"])
		if int(entry["settled"]) >= FALLBACK_SETTLE_FRAMES or waited > int(FALLBACK_MAX_SEC * 1000.0):
			_fallback.erase(gid)
			DotLog.debug(CHANNEL, "a game with no load gate is shown", {
				"ms": waited, "camera": int(entry["settled"]) > 0})
			_warm_up(game, true)


## True when the viewport's current camera (3D, else 2D) is inside [param game].
func has_camera_in(game: Node) -> bool:
	if not is_inside_tree():
		return false
	var vp := get_viewport()
	var c3 := vp.get_camera_3d()
	if c3 != null and game.is_ancestor_of(c3):
		return true
	var c2 := vp.get_camera_2d()
	return c2 != null and game.is_ancestor_of(c2)


# --- Warming ----------------------------------------------------------------------------

func _warm_up(game: Node, covered: bool) -> void:
	if not is_instance_valid(game):
		loading.end(TmcLoadingScreen.REASON_WARM)
		return
	game.set_meta(&"tmc_warmed", true)
	if covered:
		loading.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
	var items := DotRenderWarmup.collect(game)
	if game.has_method(&"warm_up_items"):
		var extra: Variant = game.call(&"warm_up_items")
		if extra is Array:
			items.append_array(extra)
	await _draw_once(items)
	loading.end(TmcLoadingScreen.REASON_WARM)


## Draws [param items] once in front of the current 3D camera; returns at once without one.
func _draw_once(items: Array) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var warm := DotRenderWarmup.new()
	warm.name = "Warmup"
	# The camera is often under a body a load gate froze; a disabled warm-up never ends.
	warm.process_mode = Node.PROCESS_MODE_ALWAYS
	warm.add_items(items)
	var count := warm.item_count()
	var started := Time.get_ticks_msec()
	cam.add_child(warm)
	warm.start()
	var done := [false]
	warm.finished.connect(func(_n: int) -> void: done[0] = true)
	while not done[0] and Time.get_ticks_msec() - started < int(DRAW_MAX_SEC * 1000.0):
		await get_tree().process_frame
	if not done[0]:
		DotLog.warn(CHANNEL, "the material warm-up did not finish in time; moving on", {
			"step": "warm-up", "items": count, "seconds": DRAW_MAX_SEC})
		warm.queue_free()
		return
	DotLog.info(CHANNEL, "drew the game's materials once under the loading screen", {
		"items": count, "ms": Time.get_ticks_msec() - started})


func describe() -> Dictionary:
	return {"gates": _gates.size(), "warming": _warming.size(), "fallback": _fallback.size()}
