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
## 60 Hz browser frame) and in any one poll. Seven windows, in this order:
## - [b]join[/b]: connect to seated plus [constant JOIN_SECONDS];
## - [b]play[/b]: [constant PLAY_SECONDS] with the game's own stand-ins;
## - [b]crowd[/b]: [constant CROWD] - 1 more real clients (each with the game's own client scene,
##   connected straight to the server, not through the relay) join one after another, each as
##   soon as the last has its scene, so the measured browser hears seven JOINs, seven faces and
##   seven chat lines inside a second or two;
## - [b]avatars[/b]: every player's platform avatar changes at once to a document with every slot
##   of the game's schema filled and coloured, and `player_avatar_changed` fires for each, the
##   path a site avatar takes when the profile store answers after the seat;
## - [b]board[/b]: the browser holds its scoreboard open with [constant CROWD] players in;
## - [b]vote[/b]: the game's map vote opened (`revote`, the ballot a round end opens, to every
##   player), [constant VOTE_SECONDS] open, closed (`endvote`), and what the close applies;
## - [b]maps[/b]: a change to each other map, through the server world's `change_*_now` where it
##   has one, otherwise through the client's map menu as a player uses it on M: `/mapmenu` in
##   chat (the list, in notices), then `/mapmenu <id>` (with `sv_map_menu_flag` emptied, so the
##   browser may change rather than start a vote). [constant MAP_SECONDS] each.
## Each window must stay at or under
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
## Players in the crowd windows, the measured browser included: a full game here.
const CROWD := 8
const VOTE_SECONDS := 5.0
const AVATAR_SECONDS := 3.0
const BOARD_SECONDS := 3.0
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

const SECTIONS := 8
const CHECKS := 2 + 1 + 1 + 1 + 1 + 1 + 1 + 1

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
## The other players: {side, link, spawned}.
var _crowd: Array = []
## Every notice the browser was sent, by topic, and the map menu's rows and results.
var _topics: Dictionary = {}
var _menu_rows: Array = []
var _menu_parts := [0, 0]
var _menu_results: Array = []
## The longest frame inside the current window: a frame that runs long lets the server's ticks
## pile up in one poll, so a window's peak is read beside it.
var _longest_frame := 0
var _frame_at := 0

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
	var now := Time.get_ticks_usec()
	if _frame_at > 0:
		_longest_frame = maxi(_longest_frame, now - _frame_at)
	_frame_at = now
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
		await _join_crowd()
		await _avatars()
		await _board()
		await _vote()
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


## Starts a window: the relay's peaks and the longest frame from now.
func _open_window() -> int:
	_relay.reset_peaks()
	_longest_frame = 0
	return _relay.bytes_down


## The window's peaks, recorded under [param key], and checked against [constant LIMIT].
func _window(key: String, what: String, since: int = -1, also: bool = true, why: String = "") -> void:
	var row := {"frame": _relay.peak_window, "poll": _relay.peak_poll,
		"bytes": _relay.bytes_down - since if since >= 0 else _relay.bytes_down,
		"longest_frame_ms": _longest_frame / 1000}
	_result[key] = row
	_check(also and maxi(_relay.peak_window, _relay.peak_poll) <= _limit, what,
		"most in one 16.7 ms %d bytes, in one poll %d, limit %d, longest frame %d ms%s" % [_relay.peak_window,
			_relay.peak_poll, _limit, _longest_frame / 1000, "" if why == "" else "; " + why])


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
	_link.notice_received.connect(_on_notice)

	var _from := _open_window()
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
	var before := _open_window()
	await _seconds(PLAY_SECONDS)
	_window("play", "play stays under the limit in every frame", before)
	_done()


func _on_notice(notice: DotNotice) -> void:
	var topic := String(notice.topic) if notice.topic != &"" else "(line)"
	_topics[topic] = int(_topics.get(topic, 0)) + 1
	if notice.topic != &"map_menu":
		return
	if notice.data.has("maps"):
		_menu_rows.append_array(notice.data["maps"] as Array)
		_menu_parts[0] = int(notice.data.get("part", 1))
		_menu_parts[1] = int(notice.data.get("parts", 1))
	elif notice.data.has("result"):
		_menu_results.append(notice.data["result"])


## The house's own key for a player is the account in two games (look-at-me, delivery), and every
## client in this process is one guest (one device id per install), so seven joiners would be one
## player taking over from the next. Keyed by session for the probe, as eight people are.
func _key_by_session() -> void:
	for name in _server().modules.loaded_names():
		var module: DotModule = _server().modules.get_module(name)
		var bridge: Variant = module.get("bridge") if module != null else null
		if bridge is Object and "key_fn" in (bridge as Object):
			(bridge as Object).set("key_fn", Callable())


func _join_crowd() -> void:
	_section("%d more players join, %d in all" % [CROWD - 1, CROWD])
	_key_by_session()
	var before := _open_window()
	var t0 := Time.get_ticks_msec()
	var all_in := true
	# One after another, each as soon as the last has its game scene: a client scene finds its
	# link through DotRegistry's `dot_client_link`, which is last-wins and shared by every client
	# in this process, so seven links made at once leave six scenes on the seventh's link.
	for i in range(CROWD - 1):
		var side := Node.new()
		side.name = "Crowd%d" % i
		add_child(side)
		get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
		var link := DotClientLink.new()
		link.name = "Server"
		link.player_name = "Player %d" % (i + 2)
		link.transport_preference = "ws"
		side.add_child(link)
		var spawned := [false]
		link.spawned.connect(func() -> void: spawned[0] = true)
		_crowd.append({"side": side, "link": link, "spawned": spawned})
		var _connecting: Variant = link.call("connect_to_server", "127.0.0.1:%d" % PORT)
		var scene_up := await _until(func() -> bool:
			var root := link.get_node_or_null(^"GameRoot")
			return spawned[0] and root != null and root.get_child_count() > 0, 30.0)
		all_in = all_in and scene_up
		await get_tree().process_frame
	_result["crowd_seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
	await _seconds(JOIN_SECONDS)
	var playing := _server().playing_sessions().size()
	_result["crowd_players"] = playing
	_window("crowd", "%d more players joining stay under the limit in every frame" % (CROWD - 1), before,
		all_in and playing == CROWD, "%d of %d playing" % [playing, CROWD])
	_done()


## A document with every slot of the game's schema filled, the [param n]th part of each, and
## every colour channel set: the most a site avatar can be in this game.
func _full_avatar(schema: DotAvatarSchema, n: int) -> DotAvatar:
	var avatar := schema.default_avatar()
	for slot in schema.ordered_slots():
		var parts: Array = []
		for part: DotAvatarPart in schema.parts_for(slot.id):
			if not part.retired:
				parts.append(part)
		if parts.is_empty():
			continue
		avatar.set_part(slot.id, (parts[(n + 1) % parts.size()] as DotAvatarPart).id)
		for channel in range(DotAvatar.MAX_CHANNELS):
			var _set := avatar.set_colour(slot.id, channel, Color.from_hsv(fmod(0.13 * n + 0.21 * channel, 1.0), 0.7, 0.8))
	return avatar


func _avatars() -> void:
	_section("every player's avatar arrives at once")
	var manager: Object = DotRegistry.get_service(&"dot_avatar_manager")
	var schema: DotAvatarSchema = manager.get("schema") as DotAvatarSchema if manager != null else null
	var platform: DotModule = _server().modules.get_module("platform")
	if schema == null or platform == null or not platform.has_method("player_for"):
		_result["avatars"] = {"frame": -1, "poll": -1, "bytes": 0, "why": "no avatar schema or platform"}
		_check(true, "avatars: this game has no avatar schema")
		_done()
		return
	var before := _open_window()
	var changed := 0
	var largest := 0
	for session in _server().playing_sessions():
		var player: Variant = platform.call("player_for", session)
		if not (player is Object):
			continue
		var avatar := _full_avatar(schema, changed)
		largest = maxi(largest, JSON.stringify(avatar.to_dict()).length())
		(player as Object).set("avatar", avatar)
		_server().events.notify("player_avatar_changed", {"userid": session.userid, "peer_id": session.peer_id})
		changed += 1
	await _seconds(AVATAR_SECONDS)
	_window("avatars", "%d avatars arriving at once stay under the limit in every frame" % changed, before,
		changed == CROWD, "%d changed, the largest document %d bytes of JSON" % [changed, largest])
	_result["avatars"]["players"] = changed
	_result["avatars"]["document"] = largest
	_done()


func _board() -> void:
	_section("the scoreboard held open with %d players in" % CROWD)
	var before := _open_window()
	var _held := _link.want_scoreboard(true)
	await _seconds(BOARD_SECONDS)
	var rows: Variant = _link.scoreboard.get("players", [])
	var count := (rows as Array).size() if rows is Array else int(rows)
	_window("board", "a full scoreboard stays under the limit in every frame", before,
		count >= CROWD, "%d rows on the board" % count)
	_result["board"]["rows"] = count
	var _closed := _link.want_scoreboard(false)
	_done()


func _console(line: String) -> String:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	var _ran := _server().console.execute(line, context)
	return " / ".join(captured)


## Every dot-vote director in the server's half of the tree: the game's map vote, and the host's
## game vote (off here, so never voting).
func _directors() -> Array:
	var out: Array = []
	var stack: Array[Node] = [_host]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is DotVoteDirector:
			out.append(node)
		stack.append_array(node.get_children())
	return out


func _voting() -> bool:
	for director: DotVoteDirector in _directors():
		if director.is_voting():
			return true
	return false


## The ballot a round end opens, to every player. `revote` is dot-vote's "open a vote now" in every
## game (DotVoteCommands): the director's countdown, the ballot, the tally and the close are the
## messages a round end sends, without the probe having to end each game's round its own way.
func _vote() -> void:
	_section("the map vote: opened to %d players, %d s, closed" % [CROWD, int(VOTE_SECONDS)])
	var topics_before := _topics.duplicate()
	var before := _open_window()
	var opened := _console("revote")
	var open := await _until(_voting, 30.0)
	await _seconds(VOTE_SECONDS)
	var closed := _console("endvote") if _voting() else "(closed by itself)"
	await _seconds(MAP_SECONDS)
	# A close with no votes may extend, or open a runoff: wait it out, so the maps that follow
	# are not refused by an open ballot.
	var _settled := await _until(func() -> bool: return not _voting(), 30.0)
	var heard: Array = []
	for topic: String in _topics:
		if int(_topics[topic]) > int(topics_before.get(topic, 0)):
			heard.append(topic)
	_result["vote_said"] = [opened, closed]
	_window("vote", "the map vote stays under the limit in every frame", before,
		open, "revote: %s; endvote: %s; notices %s" % [opened, closed, heard])
	_result["vote"]["notices"] = heard
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
		await _maps_by_menu()
		_done()
		return
	var world: Object = menu[0]
	var rows: Array = world.call(menu[1])
	var worst := {"frame": 0, "poll": 0, "bytes": 0, "map": "", "visited": 0, "how": "server change_*_now"}
	for row: Dictionary in rows:
		if bool(row.get("current", false)) or int(worst["visited"]) >= MAX_MAPS:
			continue
		var before := _open_window()
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


## The map menu as a player uses it (dot-menu's M, over dot-vote's DotVoteMapMenu): `/mapmenu` in
## chat, the list back in notices, then `/mapmenu <id>` for each map. The owner's flag emptied,
## so this guest may change the map rather than start a vote for it.
func _maps_by_menu() -> void:
	var flag := _console("sv_map_menu_flag \"\"")
	_menu_rows.clear()
	_menu_results.clear()
	_menu_parts[0] = 0
	_menu_parts[1] = 0
	var before := _open_window()
	_link.send_chat("/mapmenu")
	var listed := await _until(func() -> bool: return _menu_parts[1] > 0 and _menu_parts[0] == _menu_parts[1], 10.0)
	await _seconds(1.0)
	var worst := {"frame": _relay.peak_window, "poll": _relay.peak_poll, "bytes": _relay.bytes_down - before,
		"map": "(the list)", "visited": 0, "how": "client map menu", "rows": _menu_rows.size()}
	print("  note  the list: %d rows in %d notices, most in a frame %d, in a poll %d" % [
		_menu_rows.size(), _menu_parts[1], _relay.peak_window, _relay.peak_poll])
	if not listed:
		_result["maps"] = worst
		_check(false, "every map change through the client's map menu stays under the limit in every frame",
			"no map_menu list came back to /mapmenu (sv_map_menu_flag: %s)" % flag)
		return
	var how := ""
	for row: Dictionary in _menu_rows:
		if bool(row.get("current", false)) or int(worst["visited"]) >= MAX_MAPS:
			continue
		var results := _menu_results.size()
		var from := _open_window()
		_link.send_chat("/mapmenu %s" % str(row.get("id", "")))
		await _seconds(MAP_SECONDS)
		var answer: Dictionary = _menu_results[results] if _menu_results.size() > results else {}
		how = "%s (%s)" % [str(answer.get("how", "no answer")), str(answer.get("text", ""))]
		worst["visited"] = int(worst["visited"]) + 1
		if maxi(_relay.peak_window, _relay.peak_poll) > maxi(int(worst["frame"]), int(worst["poll"])):
			worst["frame"] = _relay.peak_window
			worst["poll"] = _relay.peak_poll
			worst["bytes"] = _relay.bytes_down - from
			worst["map"] = str(row.get("id", ""))
		print("  note  %s: %s; most in a frame %d, in a poll %d, %d bytes, longest frame %d ms" % [
			str(row.get("id", "")), how, _relay.peak_window, _relay.peak_poll, _relay.bytes_down - from, _longest_frame / 1000])
	worst["answer"] = how
	_result["maps"] = worst
	_check(int(worst["visited"]) > 0 and maxi(int(worst["frame"]), int(worst["poll"])) <= _limit,
		"every map change through the client's map menu stays under the limit in every frame",
		"worst %s: %d bytes in one 16.7 ms, %d visited, the last answer '%s'" % [worst["map"], int(worst["frame"]), int(worst["visited"]), how])


func _teardown() -> void:
	for one: Dictionary in _crowd:
		var link: DotClientLink = one["link"]
		if is_instance_valid(link):
			link.disconnect_from_server("probe over")
	await get_tree().process_frame
	for one: Dictionary in _crowd:
		var side: Node = one["side"]
		if is_instance_valid(side):
			remove_child(side)
			side.queue_free()
	_crowd.clear()
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
