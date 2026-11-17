class_name AdminLoadingCover
extends RefCounted

## The loading screen's cover: its gate, its draw budget, its contract with a game and its fallback. Run by `admin_loading_selftest.gd`, which keeps the counters: every check goes through its `_check`.

var t: Node


func _init(p_test: Node) -> void:
	t = p_test


func _section(title: String) -> void:
	t._section(title)


func _done() -> void:
	t._done()


func _check(condition: bool, what: String, detail: String = "") -> bool:
	return t._check(condition, what, detail)


func add_child(node: Node) -> void:
	t.add_child(node)


func get_tree() -> SceneTree:
	return t.get_tree()


## A loading screen, a cover that claims a game root, and the root, as the shell builds them.
func _cover_rig() -> Array:
	var screen := TmcLoadingScreen.new()
	screen.in_game_fn = func() -> bool: return true
	add_child(screen)
	var root := Node.new()
	root.name = "CoverGames"
	var cover := TmcGameCover.new()
	cover.loading = screen
	cover.claim(root)
	add_child(cover)
	add_child(root)
	return [screen, cover, root]


func _cover_free(rig: Array) -> void:
	for n: Node in rig:
		n.free()


func _until_ms(condition: Callable, ms: int) -> int:
	var t0 := Time.get_ticks_msec()
	while not bool(condition.call()) and Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame
	return Time.get_ticks_msec() - t0


func _test_cover_gate() -> void:
	_section("a game's load gate drives the loading screen")
	var rig := _cover_rig()
	var screen: TmcLoadingScreen = rig[0]
	var cover: TmcGameCover = rig[1]
	var root: Node = rig[2]
	_check(TmcGameCover.HOST_META == DotLoadGate.HOST_META and TmcGameCover.GATE_META == DotLoadGate.META,
		"the cover spells the gate's metadata as dot-core does")

	var game := Node3D.new()
	var gate := DotLoadGate.new()
	gate.require_camera = false
	gate.register_service = false
	gate.hold(&"map", "Loading the map")
	game.add_child(gate)
	root.add_child(game)
	_check(gate.is_hosted() and not gate.is_cover_showing(), "a gate made under the claimed root is hosted, with no cover of its own")
	cover.watch()
	_check(screen.is_showing() and cover.mode_of(game) == "gate", "the loading screen is up over it at once", cover.mode_of(game))
	_check(screen._status.text == "Loading the map", "with the gate's line", screen._status.text)
	gate.set_progress(0.4, "Building the level")
	_check(is_equal_approx(screen._bar.value, 40.0) and screen._status.text == "Building the level",
		"and the gate's progress", "%s %s" % [screen._bar.value, screen._status.text])

	var cam := Camera3D.new()
	game.add_child(cam)
	cam.make_current()
	var at_open: Array = []
	gate.opened.connect(func() -> void: at_open.append(screen.is_showing()))
	gate.release(&"map")
	await _until_ms(func() -> bool: return gate.is_open(), 8000)
	_check(gate.is_open() and at_open == [false], "released: warmed here, screen down, then the gate opens", str(at_open))
	_check(not cam.has_node("Warmup") or cam.get_node("Warmup").is_queued_for_deletion(), "the shell's warm-up ran on the camera and went")

	gate.hold(&"map", "Changing map")
	_check(screen.is_showing() and screen._status.text == "Changing map", "a second hold puts the screen back with its line")
	gate.release(&"map")
	await _until_ms(func() -> bool: return gate.is_open(), 8000)
	_check(gate.is_open() and not screen.is_showing(), "and it lifts again")

	# The gate opened by its own host time-out while the shell's warm-up hung: the screen goes.
	screen.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
	_check(screen.is_showing(), "the screen is up as a hung warm-up leaves it")
	gate.opened.emit()
	_check(not screen.is_showing(), "an opened gate drops a screen its warm-up never lifted")

	gate.hold(&"map")
	_check(screen.is_showing(), "held once more")
	root.remove_child(game)
	game.free()
	_check(not screen.is_showing(), "a game freed under its own gate takes the screen with it")

	# A gate made before the root was claimed is found and hosted by watch().
	var root2 := Node.new()
	add_child(root2)
	var game2 := Node3D.new()
	var gate2 := DotLoadGate.new()
	gate2.require_camera = false
	gate2.register_service = false
	gate2.hold(&"x")
	game2.add_child(gate2)
	root2.add_child(game2)
	_check(not gate2.is_hosted() and gate2.is_cover_showing(), "unclaimed, a gate covers by itself")
	cover.claim(root2)
	cover.watch()
	_check(gate2.is_hosted() and not gate2.is_cover_showing() and screen.is_showing(),
		"watch() finds it by its metadata and takes the job over")
	root2.free()
	_cover_free(rig)
	_done()


## The shell's warm-up goes up in budgeted rounds, so its time-out can cut it between frames. Unbudgeted, PLAYLOT's
## 184 items went up in one round: one 12 s frame of shader compiles that no time-out could cut (2026-11-15).
func _test_cover_draw_budget() -> void:
	_section("the shell's warm-up is budgeted, and its time-out is a setting")
	var rig := _cover_rig()
	var cover: TmcGameCover = rig[1]
	var root: Node = rig[2]
	_check(cover.draw_budget_msec > 0.0, "the warm-up is budgeted by default", str(cover.draw_budget_msec))
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	var budgets: Array = []
	cam.child_entered_tree.connect(func(n: Node) -> void:
		if n is DotRenderWarmup:
			budgets.append((n as DotRenderWarmup).budget_msec))
	var mats: Array = []
	for i in 3:
		mats.append(StandardMaterial3D.new())
	cover.draw_budget_msec = 25.0
	cover.draw_max_sec = 0.0
	await cover._draw_once(mats)
	_check(budgets == [25.0], "the warm-up gets the cover's budget", str(budgets))
	_check(not cam.has_node("Warmup") or cam.get_node("Warmup").is_queued_for_deletion(), "with no time-out (0) it still ends when the warm-up does")

	# Headless draws no frame, so a warm-up only ends at its own 5 s: a 0.2 s limit must end it first.
	cover.draw_max_sec = 0.2
	var t0 := Time.get_ticks_msec()
	await cover._draw_once(mats)
	var took := Time.get_ticks_msec() - t0
	_check(took < 2000, "a time-out lifts the screen between frames", "%d ms" % took)
	# What it did not reach is deferred, not skipped: the warm-up keeps drawing in play.
	var left := cam.get_node_or_null("Warmup") as DotRenderWarmup
	_check(left != null and not left.is_queued_for_deletion(), "and leaves the warm-up drawing the rest in play")
	if left != null:
		left.queue_free()
		await get_tree().process_frame
	_cover_free(rig)
	_done()


func _test_cover_contract() -> void:
	_section("a game on the older root contract")
	var rig := _cover_rig()
	var screen: TmcLoadingScreen = rig[0]
	var cover: TmcGameCover = rig[1]
	var root: Node = rig[2]
	var game: Node3D = preload("res://examples/game_cover_contract_game.gd").new()
	root.add_child(game)
	cover.watch()
	_check(screen.is_showing() and cover.mode_of(game) == "contract", "covered until it says it is ready", cover.mode_of(game))
	game.ready_now = true
	game.ready_to_show.emit()
	await _until_ms(func() -> bool: return not screen.is_showing(), 2000)
	_check(not screen.is_showing(), "and shown when it does")
	_cover_free(rig)
	_done()


func _test_cover_fallback() -> void:
	_section("a game with no gate and no contract is covered anyway")
	var rig := _cover_rig()
	var screen: TmcLoadingScreen = rig[0]
	var cover: TmcGameCover = rig[1]
	var root: Node = rig[2]
	var game := Node3D.new()
	root.add_child(game)
	cover.watch()
	_check(screen.is_showing() and cover.mode_of(game) == "fallback", "covered at spawn", cover.mode_of(game))
	for i in 20:
		await get_tree().physics_frame
	_check(screen.is_showing(), "still covered with no camera after 20 physics frames")
	var cam := Camera3D.new()
	game.add_child(cam)
	cam.make_current()
	var took := await _until_ms(func() -> bool: return not screen.is_showing(), 4000)
	_check(not screen.is_showing() and took < int(TmcGameCover.FALLBACK_MAX_SEC * 1000.0) - 500,
		"shown once its camera has settled, well before the cap", "%d ms" % took)
	_check(cover.mode_of(game) == "", "and no longer on the fallback")

	var bare := Node.new()
	root.add_child(bare)
	var t0 := Time.get_ticks_msec()
	cover.watch()
	_check(screen.is_showing(), "a game that never makes a camera is covered too")
	await _until_ms(func() -> bool: return not screen.is_showing(), 9000)
	var waited := Time.get_ticks_msec() - t0
	_check(not screen.is_showing() and waited >= int(TmcGameCover.FALLBACK_MAX_SEC * 1000.0) - 100,
		"and shown at the cap, never held for ever", "%d ms" % waited)
	_cover_free(rig)
	_done()
