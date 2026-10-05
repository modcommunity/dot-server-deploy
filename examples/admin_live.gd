extends Node

## `/admin` and the loading screen on the REAL shell, against a real server, over a socket.
##
## [codeblock]
## godot --headless --path . res://examples/admin_live.tscn
## [/codeblock]
##
## `admin_loading_selftest` checks each half against stand-ins. This is the only place the
## halves meet: a chat line becomes a console command becomes a notice the shell routes to
## its panel; a choice goes back as a silent chat line; a confirmed `changelevel` runs as
## the admin; and while the game changes under the player, the loading screen goes up with
## the picture the server's `loading.yml` named — served here, fetched by the shell ahead of
## time — and comes down when the new game has spawned.

const CONFIG := "res://examples/fixtures/admin_live"
const CONTENT := "res://content"
const DATA := "user://tmc_admin_live"
const SHELL := "res://client/shell.tscn"

## Where fixtures/admin_live/loading.yml says the picture is.
const MEDIA_PORT := 27109

const TARGET_GAME := "hungry_classic"

const CHECKS := 22

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _shell: Node = null
var _port := 0

var _media: TCPServer = null
var _media_peers: Array[StreamPeerTCP] = []
var _media_served := 0
var _png := PackedByteArray()


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: the admin menu and the loading screen, live")

	DotPaths.remove_tree(DATA)
	_serve_media()

	if await _boot():
		if await _test_connect():
			await _test_menu()
			await _test_change_under_the_player()

	await _teardown()
	DotPaths.remove_tree(DATA)
	if _media != null:
		_media.stop()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
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


func _panel() -> TmcAdminMenuPanel:
	return _shell.admin_menu as TmcAdminMenuPanel


func _screen() -> TmcLoadingScreen:
	return _shell.loading as TmcLoadingScreen


func _row(label_prefix: String) -> Dictionary:
	for row in _panel().rows():
		if str(row["label"]).begins_with(label_prefix):
			return row
	return {}


func _labels() -> String:
	return str(_panel().rows().map(func(r: Dictionary) -> String: return str(r["label"])))


# --- The picture -----------------------------------------------------------------

func _serve_media() -> void:
	var image := Image.create(32, 18, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.4, 0.9))
	_png = image.save_png_to_buffer()
	_media = TCPServer.new()
	if _media.listen(MEDIA_PORT, "127.0.0.1") != OK:
		_media = null


func _process(_delta: float) -> void:
	if _media == null:
		return
	if _media.is_connection_available():
		_media_peers.append(_media.take_connection())
	for peer in _media_peers.duplicate():
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_media_peers.erase(peer)
			continue
		if peer.get_available_bytes() == 0:
			continue
		var request: String = peer.get_utf8_string(peer.get_available_bytes())
		var ok := request.begins_with("GET /bg.png")
		var body := _png if ok else "nope".to_utf8_buffer()
		peer.put_data(("HTTP/1.1 %s\r\nContent-Type: image/png\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
			% ["200 OK" if ok else "404 Not Found", body.size()]).to_utf8_buffer())
		peer.put_data(body)
		_media_served += 1
		_media_peers.erase(peer)
		peer.disconnect_from_host()


# --- Boot ------------------------------------------------------------------------

func _boot() -> bool:
	_section("booting")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.name = "Host"
	_host.auto_start = false
	add_child(_host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)
	if not _check(started.ok, "the host boots", str(started.error) if not started.ok else ""):
		_done()
		return false
	_port = int(_host.config.server.port)

	_check(_host.admin_menu != null and _host.loading != null and _media != null,
		"with the admin menu, the loading screen and a picture to serve")

	_shell = (load(SHELL) as PackedScene).instantiate()
	_shell.name = "Shell"
	add_child(_shell)
	await get_tree().process_frame
	await get_tree().process_frame

	# res://dist, for the reason reconnect gives: there is no web server here.
	_shell._ensure_cloud()
	_shell._cloud.http_base_urls = PackedStringArray([ProjectSettings.globalize_path("res://dist")])
	_done()
	return true


func _teardown() -> void:
	if _shell != null and is_instance_valid(_shell):
		if _shell.link != null and is_instance_valid(_shell.link):
			_shell.link.disconnect_from_server()
		remove_child(_shell)
		_shell.queue_free()
		_shell = null
		await get_tree().process_frame

	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("done")
		remove_child(_host)
		_host.free()
		_host = null
		await get_tree().physics_frame
		await get_tree().physics_frame


func _me() -> DotClientSession:
	var srv := _server()
	if srv == null:
		return null
	for session in srv.sessions():
		if session.state == DotClientSession.State.SPAWNED:
			return session
	return null


# --- Sections --------------------------------------------------------------------

func _test_connect() -> bool:
	_section("a player joins")

	_shell._connect_to("127.0.0.1:%d" % _port)
	if not _check(await _until(func() -> bool: return _me() != null, 30.0), "the server spawns them"):
		_done()
		return false

	_check(await _until(func() -> bool: return _screen().has_document(), 10.0),
		"and sends the loading screen on spawn")
	_check(await _until(func() -> bool: return _screen().describe()["media"]["ready"] == 1, 10.0),
		"whose picture the shell fetches while they play (%d served)" % _media_served,
		str(_screen().describe()["media"]))
	_check(not _screen().is_showing(), "and does not show on the first join")
	_done()
	return true


func _test_menu() -> void:
	_section("/admin")

	_shell.link.send_chat("/admin")
	await get_tree().create_timer(1.0).timeout
	_check(not _panel().is_open(), "a player with no flags gets no menu")

	# Root, granted here rather than through auth: what is under test is the menu, and a
	# guest's permissions are exactly as settable as an account's once resolved.
	var me := _me()
	me.permissions = PackedStringArray(["root"])
	me.immunity = 99

	_shell.link.send_chat("/admin")
	_check(await _until(func() -> bool: return _panel().is_open(), 10.0),
		"an admin's /admin opens the menu on their screen")
	_check(not _row("Player commands").is_empty() and not _row("Server commands").is_empty() and not _row("Other").is_empty(),
		"listing the categories, and the owner's own item under Other", _labels())

	_panel().choose(_row("Player commands"))
	await _until(func() -> bool: return _panel().title_text() == "Player commands", 10.0)
	_panel().choose(_row("Player info"))
	await _until(func() -> bool: return not _row(me.display_name).is_empty(), 10.0)
	_panel().choose(_row(me.display_name))
	_check(await _until(func() -> bool: return _panel().title_text() == me.display_name, 10.0)
			and not _row("User id: #%d" % me.userid).is_empty(),
		"a choice is a round trip: player info on themselves", _labels())

	_panel().back()
	_panel().back()
	_check(await _until(func() -> bool: return _panel().title_text() == "Player commands", 10.0),
		"Back walks the pages back, by asking for them again", _panel().title_text())

	_panel().press(0)
	_check(not _panel().is_open(), "0 closes it")
	_done()


func _test_change_under_the_player() -> void:
	_section("a game change from the menu, under the loading screen")

	_shell.link.send_chat("/admin")
	await _until(func() -> bool: return _panel().is_open(), 10.0)
	_panel().choose(_row("Server commands"))
	await _until(func() -> bool: return not _row("Change game").is_empty(), 10.0)
	_panel().choose(_row("Change game"))

	# A holder, because a lambda captures a local by value and assigning to it inside the
	# lambda changes nothing out here.
	var found := [{}]
	await _until(func() -> bool:
		for row in _panel().rows():
			if str(row.get("go", "")).ends_with(" " + TARGET_GAME):
				found[0] = row
				return true
		return false, 10.0)
	var target: Dictionary = found[0]
	_check(not target.is_empty(), "Change game lists %s" % TARGET_GAME, _labels())
	if target.is_empty():
		_done()
		return
	_panel().choose(target)
	_check(await _until(func() -> bool: return not _row("Yes, do it").is_empty(), 10.0),
		"and asks first", _labels())

	var showed := [false]
	var pictured := [false]
	var tipped := [false]
	var watch := func() -> void:
		if _screen().is_showing():
			showed[0] = true
			pictured[0] = pictured[0] or _screen().describe()["image"]
			tipped[0] = tipped[0] or _screen().current_entry().get("tips", []) == ["Eat the small ones."]
	get_tree().process_frame.connect(watch)

	_panel().choose(_row("Yes, do it"))
	_check(await _until(func() -> bool: return not _panel().is_open(), 10.0), "yes closes the menu")

	var changed := await _until(func() -> bool:
		var srv := _server()
		return srv != null and srv.games.current() != null and srv.games.current().game_id == TARGET_GAME \
			and _me() != null and not _screen().is_showing(), 90.0)
	get_tree().process_frame.disconnect(watch)

	_check(changed, "the change ran as the admin, and the player spawned in the new game",
		"%s, showing=%s" % [_server().games.current().game_id if _server() else "-", _screen().is_showing()])
	_check(showed[0], "the loading screen was up while it changed")
	_check(pictured[0], "with the server's picture on it")
	_check(tipped[0], "and the new game's own tip over the default's")
	_check(not _screen().is_showing(), "and it is gone once the game is on screen")
	_done()
