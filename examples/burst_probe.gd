extends Node
# [b]Nothing preloaded out of a game, because no game is in this build.[/b] Every game is a
# delivered pack; its world is found through the host's module table, by the methods the map
# menu calls.

## How much a delivered game sends a browser in one frame: at the join, in play, and on a map
## change.
##
## [codeblock]
## godot --headless --path . res://examples/burst_probe.tscn -- --game deathrun
## tools/burst_all_games.sh                 # every delivered game, and the table
## [/codeblock]
##
## [b]Why.[/b] Godot's web WebSocket peer copies every message the page receives into a 64 KiB
## inbound buffer as it arrives and drains it once a frame; whatever overflows between two
## frames is dropped ("Buffer payload full! Dropping data.") and a reliable message is simply
## gone. A native client never shows it: it reads its socket only when polled. mg-look-at-me
## lost 5 of its 32 levels in Chromium that way. So the question for every game is the most the
## server puts on a browser's socket inside one frame.
##
## [b]What it does.[/b] Boots the host on the game, puts [code]slow_tcp_relay.gd[/code] in front
## of its TCP port with the rate unlimited, and joins a real [DotClientLink] on WebSocket through
## it. The relay is polled once a frame and records the most it carried inside any 16.7 ms (a
## 60 Hz browser frame) and in any one poll. Three windows: the join (connect to seated plus
## [constant JOIN_SECONDS]), play ([constant PLAY_SECONDS] with the game's own stand-ins), and
## a change to each other map the game's map menu offers ([constant MAP_SECONDS] each; games
## whose server has no `change_*_now` are reported "-"). Each window must stay at or under
## [constant LIMIT], three quarters of the browser's buffer: a frame that runs long (a level
## being built) lets more than one server frame's worth pile up, which is why the bound is not
## the buffer itself.
##
## Prints one `BURST {json}` line for the table. Exit 0 every window held, 1 one did not, 3 the
## game's pack is not published here.

const ServerWorld := preload("res://examples/server_world.gd")
const SlowTcpRelay := preload("res://examples/slow_tcp_relay.gd")

const CONTENT := "res://content"
const PORT := 27320

## The browser's inbound buffer (dot-core's inbound_buffer_exp 16), and the most one frame may
## carry towards it.
const BROWSER_INBOUND := 65536
const LIMIT := 49152

const JOIN_SECONDS := 6.0
const PLAY_SECONDS := 10.0
const MAP_SECONDS := 3.0
## The most other maps visited: the largest documents are what is being looked for, and a game
## with thirty maps would take minutes.
const MAX_MAPS := 6

## game id (sv_game) -> the packs it needs in dist/. As examples/enet_relay.gd has it.
const PACKS := {
	"arena": ["tmc/arena"],
	"buses": ["tmc/buses"],
	"deathrun": ["tmc/deathrun", "tmc/deathrun_maps"],
	"delivery": ["tmc/delivery"],
	"g2gfast": ["tmc/g2gfast"],
	"hideseek": ["tmc/hideseek", "tmc/hideseek_maps"],
	"hungry_classic": ["tmc/hungry"],
	"lookatme": ["tmc/lookatme"],
	"playground": ["tmc/playground"],
	"prophunt": ["tmc/prophunt", "tmc/prophunt_maps"],
	"smash": ["tmc/smash"],
	"wipeout": ["tmc/wipeout", "tmc/wipeout_maps"],
	"zombiezone": ["tmc/zombiezone", "tmc/zombiezone_maps"],
}

## The map menu's two calls on a game's server world, by game: rows, then the change.
const MAP_CALLS := [
	["course_rows", "change_course_now"],
	["map_rows", "change_map_now"],
	["layout_rows", "change_layout_now"],
	["bowl_rows", "change_bowl_now"],
]

const SECTIONS := 4
const CHECKS := 2 + 1 + 1 + 1

var _game := "buses"
## [constant LIMIT], or `--limit N`: how the probe is armed (a limit under a game's signon must fail).
var _limit := LIMIT
var _verbose := false
var _root := "user://tmc_burst_probe"
var _host: Node = null
var _relay: SlowTcpRelay = null
var _client_side: Node = null
var _link: DotClientLink = null
var _spawned := [false]
var _gone := [""]

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _finished := 0
var _result := {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_verbose = "--verbose" in args
	for i in range(args.size() - 1):
		if args[i] == "--game":
			_game = args[i + 1]
		elif args[i] == "--limit":
			_limit = int(args[i + 1])
	DotLog.set_level(DotLog.Level.DEBUG if _verbose else DotLog.Level.ERROR)
	_root += "_" + _game.replace("-", "_")
	_result = {"game": _game, "limit": _limit}
	_run.call_deferred()


func _process(_delta: float) -> void:
	if _relay != null:
		_relay.poll(_delta)


func _run() -> void:
	print("%s: the most a browser is sent in one frame" % _game)
	DotPaths.remove_tree(_root)

	if not PACKS.has(_game):
		push_error("unknown game %s" % _game)
		get_tree().quit(2)
		return

	for pack in PACKS[_game]:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/" + pack)):
			print("skipped: dist/%s is not published here" % pack)
			_result["skipped"] = "dist/%s is not published here" % pack
			print("BURST " + JSON.stringify(_result))
			get_tree().quit(3)
			return

	_write_config()

	if await _boot() and await _join():
		await _play()
		await _maps()

	await _teardown()
	DotPaths.remove_tree(_root)

	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	var code := 1 if _failed > 0 else 0
	if _entered != SECTIONS or _finished != SECTIONS:
		print("  FAIL  %d of %d sections finished, %d declared" % [_finished, _entered, SECTIONS])
		code = 1
	if _passed + _failed != CHECKS:
		print("  FAIL  %d checks ran, %d declared" % [_passed + _failed, CHECKS])
		code = 1
	_result["passed"] = _passed
	_result["failed"] = _failed
	print("BURST " + JSON.stringify(_result))
	get_tree().quit(code)


# --- Harness ------------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s: %s" % [what, detail])
	print("  %s  %s%s" % ["ok  " if ok else "FAIL", what, "" if detail == "" else "  (%s)" % detail])
	return ok


func _cannot(n: int, why: String) -> void:
	for i in range(n):
		_check(false, "(not reached)", why)


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _seconds(s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


## The window's peaks, recorded under [param key], and checked against [constant LIMIT].
func _window(key: String, what: String) -> void:
	var row := {"frame": _relay.peak_window, "poll": _relay.peak_poll, "bytes": _relay.bytes_down}
	_result[key] = row
	_check(maxi(_relay.peak_window, _relay.peak_poll) <= _limit, what,
		"most in one 16.7 ms %d bytes, in one poll %d, limit %d" % [_relay.peak_window, _relay.peak_poll, _limit])


# --- Config -------------------------------------------------------------------

## As examples/enet_relay.gd writes it: the shared fixtures with this game, the vote off, a port
## of this probe's own, the server awake.
func _write_config() -> void:
	var cfg := _root.path_join("cfg")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cfg))
	for name in DirAccess.get_files_at("res://examples/fixtures"):
		if not name.ends_with(".yml"):
			continue
		var text := FileAccess.get_file_as_string("res://examples/fixtures/" + name)
		if name == "server.yml":
			var lines := PackedStringArray()
			for line in text.split("\n"):
				if line.begins_with("sv_game:") or line.begins_with("sv_map:") or line.begins_with("sv_tickrate:"):
					continue
				lines.append(line)
			lines.append("sv_game: \"%s\"" % _game)
			lines.append("sv_stdin_console: false")
			lines.append("sv_hibernate_when_empty: false")
			text = "\n".join(lines)
		elif name == "net.yml":
			text = "net_bind_ip: \"127.0.0.1\"\nnet_port: %d\n" % PORT
		elif name == "vote.yml":
			text = "enabled: false\n"
		elif name == "log.yml":
			text = "log_level: warn\nlog_file: false\n"
		DotPaths.write_text(cfg.path_join(name), text)
	# The course pack wipeout plays from (the shared fixtures name none), as game_vote_all has it.
	DotPaths.write_text(cfg.path_join("content.yml"),
		FileAccess.get_file_as_string("res://examples/fixtures/game_vote_all/content.yml"))


# --- Sections -----------------------------------------------------------------

func _server() -> DotServer:
	return _host.server as DotServer


func _boot() -> bool:
	_section("the host on the delivered game, and a measuring relay in front of its TCP port")
	_host = (load("res://host/host.tscn") as PackedScene).instantiate()
	_host.auto_start = false
	ServerWorld.add(self, _host)
	var started: DotResult = await _host.start(_root.path_join("cfg"), CONTENT, _root.path_join("data"))
	if not _check(started.ok, "the host boots", "" if started.ok else str(started.error)):
		_cannot(1, "no host")
		_done()
		return false
	var reached := await _until(func() -> bool:
		var current := _server().games.current()
		return current != null and current.game_id == _game and _server().games.phase == DotGameManager.Phase.IDLE, 60.0)
	_check(reached, "and reaches the delivered game")
	_relay = SlowTcpRelay.new()
	_relay.rate_down = SlowTcpRelay.UNLIMITED
	var _port := _relay.start(PORT)
	_done()
	return reached


func _join() -> bool:
	_section("a browser's join: connect, seated, and %d s after" % int(JOIN_SECONDS))
	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Browser"
	_link.transport_preference = "ws"
	_client_side.add_child(_link)
	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _gone[0] = reason)

	_relay.reset_peaks()
	var t0 := Time.get_ticks_msec()
	var _connecting: Variant = _link.call("connect_to_server", "127.0.0.1:%d" % _relay.port())
	var seated := await _until(func() -> bool:
		return _spawned[0] or _gone[0] != "" or _link.phase == DotClientLink.Phase.FAILED, 60.0)
	if not seated or not _spawned[0] or _link.transport_used != "websocket":
		_check(false, "the join stays under the limit in every frame",
			"not seated on a WebSocket: transport %s, %.1f s%s" % [_link.transport_used,
				(Time.get_ticks_msec() - t0) / 1000.0, "" if _gone[0] == "" else ", " + _gone[0]])
		_done()
		return false
	await _seconds(JOIN_SECONDS)
	# What the client built: a join measured before the game's own scene asked for its world
	# measures only the shell's signon.
	var root := _link.get_node_or_null(^"GameRoot")
	_result["client_scene"] = root != null and root.get_child_count() > 0
	_window("join", "the join stays under the limit in every frame")
	_done()
	return true


func _play() -> void:
	_section("%d s of play" % int(PLAY_SECONDS))
	_relay.reset_peaks()
	var before := _relay.bytes_down
	await _seconds(PLAY_SECONDS)
	_window("play", "play stays under the limit in every frame")
	_result["play"]["bytes"] = _relay.bytes_down - before
	_done()


## The server's world and the map menu's two methods on it, or [].
func _map_menu() -> Array:
	for name in _server().modules.loaded_names():
		var module: DotModule = _server().modules.get_module(name)
		var world: Variant = module.get("game") if module != null else null
		if not (world is Object):
			continue
		for calls: Array in MAP_CALLS:
			if (world as Object).has_method(calls[0]) and (world as Object).has_method(calls[1]):
				return [world, calls[0], calls[1]]
	return []


func _maps() -> void:
	_section("a change to each other map, %d s each" % int(MAP_SECONDS))
	var menu := _map_menu()
	if menu.is_empty():
		_result["maps"] = {"frame": -1, "poll": -1, "bytes": 0, "why": "no change_*_now on the server"}
		_check(true, "map changes: none offered by this game's server")
		_done()
		return
	var world: Object = menu[0]
	var rows: Array = world.call(menu[1])
	var worst := {"frame": 0, "poll": 0, "bytes": 0, "map": "", "visited": 0}
	for row: Dictionary in rows:
		if bool(row.get("current", false)) or int(worst["visited"]) >= MAX_MAPS:
			continue
		_relay.reset_peaks()
		var before := _relay.bytes_down
		var changed: DotResult = world.call(menu[2], StringName(str(row.get("id", ""))))
		if changed == null or not changed.ok:
			continue
		await _seconds(MAP_SECONDS)
		worst["visited"] = int(worst["visited"]) + 1
		if _relay.peak_window > int(worst["frame"]):
			worst["frame"] = _relay.peak_window
			worst["poll"] = _relay.peak_poll
			worst["bytes"] = _relay.bytes_down - before
			worst["map"] = str(row.get("id", ""))
		print("  note  %s: most in a frame %d, in a poll %d, %d bytes" % [
			str(row.get("id", "")), _relay.peak_window, _relay.peak_poll, _relay.bytes_down - before])
	_result["maps"] = worst
	_check(maxi(int(worst["frame"]), int(worst["poll"])) <= _limit, "every map change stays under the limit in every frame",
		"worst %s: %d bytes in one 16.7 ms, %d visited" % [worst["map"], int(worst["frame"]), int(worst["visited"])])
	_done()


func _teardown() -> void:
	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("probe over")
	await get_tree().process_frame
	if _client_side != null and is_instance_valid(_client_side):
		remove_child(_client_side)
		_client_side.queue_free()
		_client_side = null
		_link = null
	await get_tree().process_frame
	if _relay != null:
		_relay.stop()
		_relay = null
	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("probe over")
		ServerWorld.remove(_host)
		_host.queue_free()
		_host = null
	await get_tree().process_frame
