extends Node

## Reconnecting to a server that went down and came back, through the REAL shell.
##
## [codeblock]
## godot --headless --path . res://examples/reconnect.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The bug this exists for.[/b] A player was connected, the server restarted under them,
## they were dropped to the menu, and pressing Connect signed them on to a working server
## and left them looking at an empty screen. Nothing errored on either end, nothing was
## downloaded (the pack was still mounted from the first connection), and a page refresh
## made it work — so it read as a browser problem and was none.
##
## [member DotClientLink.name] is "Server" and that name is the RPC routing. The shell
## never freed the dropped link, so the replacement was added beside it and Godot renamed
## it "Server2". From then on the server's calls resolved to the OLD node and
## [DotRegistry] handed the NEW one to the game, which parents its own RPC node under the
## link it was given — under a name the server has never heard of. Two objects, each doing
## half the job, neither of them wrong enough to report anything.
##
## [b]What is checked is the shape, not the symptom.[/b] An empty screen needs a game with
## art in it; "the node the server's RPCs resolve to is the node the registry hands out"
## is the same bug one layer up, and it is checkable with nothing on screen at all. This
## is the only suite that connects the shell twice — `live_switch` connects a bare link
## once and `multigame` connects nothing — which is why nothing caught it.

const CONFIG := "res://examples/fixtures/multigame"
const CONTENT := "res://content"
const DATA := "user://tmc_reconnect"
const SHELL := "res://client/shell.tscn"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _shell: Node = null
var _port := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: reconnecting after the server restarts")

	DotPaths.remove_tree(DATA)

	if await _boot():
		if await _test_first_connection():
			if await _test_server_goes_down():
				await _test_reconnect()

	_teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
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


## Waiting on the server's session count is not enough: it counts a socket that has
## connected, and everything this suite is about happens during the signon that follows.
func _playing() -> bool:
	return _shell != null and is_instance_valid(_shell) \
		and _shell.link != null and is_instance_valid(_shell.link) \
		and _shell.link.phase == DotClientLink.Phase.PLAYING


func _sessions() -> int:
	var srv := _server()
	return srv.sessions().size() if srv != null else 0


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


## Every [DotClientLink] the shell is holding, however it is named.
##
## By type rather than by name, because the failure renames the second one — counting
## children called "Server" finds exactly one in both the broken and the fixed shell.
func _links() -> Array[Node]:
	var out: Array[Node] = []

	if _shell == null or not is_instance_valid(_shell):
		return out

	for child in _shell.get_children():
		if child is DotClientLink:
			out.append(child)

	return out


func _link_names() -> String:
	var names := PackedStringArray()
	for node in _links():
		names.append(String(node.name))
	return str(names)


# --- Boot ------------------------------------------------------------------

## Starts a server. Called twice: the restart is a second one on the same address, which
## is what a restarted process is.
func _start_host(node_name: String) -> bool:
	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.name = node_name
	_host.auto_start = false
	add_child(_host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not started.ok:
		_check(false, "the host boots", str(started.error))
		return false

	_port = int(_host.config.server.port)
	return true


func _stop_host() -> void:
	if _host == null or not is_instance_valid(_host):
		return

	if _host.server != null and is_instance_valid(_host.server):
		_host.server.shutdown("restarting")

	remove_child(_host)
	_host.free()
	_host = null

	# The listener is released when the node goes, and the next one binds the same port.
	# Two frames rather than none, because the peer is closed on a poll and the bind that
	# follows in the same frame gets "address already in use" on Linux.
	await get_tree().physics_frame
	await get_tree().physics_frame


func _boot() -> bool:
	_section("booting")

	if not await _start_host("Host"):
		_done()
		return false

	_check(true, "the host boots")

	var packed: Variant = load(SHELL)
	_shell = (packed as PackedScene).instantiate()
	_shell.name = "Shell"
	add_child(_shell)

	# The shell scopes its own MultiplayerAPI to itself in `_ready` and signs in before it
	# will dial anything, so it is given a frame to finish both.
	await get_tree().process_frame
	await get_tree().process_frame

	# [b]Where this shell fetches the game from, because there is no web server here.[/b]
	# A base that is not a URL is searched as a directory, and `res://dist` is where
	# [DotCloudPublisher] writes -- the same directory the host itself searches before it
	# asks the network. The export ships `client/content.json` naming the page's own
	# origin, which is right in a browser and unreachable from a headless run.
	#
	# Built here rather than at the first connect so the second connect finds it already
	# made, which is what a real session does: the shell keeps one content client for its
	# whole life, and the pack it mounted the first time is still mounted the second --
	# that is why the player saw no download and assumed nothing had happened.
	_shell._ensure_cloud()
	_shell._cloud.http_base_urls = PackedStringArray([
		ProjectSettings.globalize_path("res://dist")
	])

	_check(
		get_tree().get_multiplayer(_host.get_path())
			!= get_tree().get_multiplayer(_shell.get_path()),
		"and the two halves have separate MultiplayerAPI instances"
	)
	_done()
	return true


func _teardown() -> void:
	if _shell != null and is_instance_valid(_shell):
		remove_child(_shell)
		_shell.free()
		_shell = null

	await _stop_host()


# --- Sections --------------------------------------------------------------

func _test_first_connection() -> bool:
	_section("a player connects")

	_shell._connect_to("127.0.0.1:%d" % _port)

	var admitted := await _until(_playing)

	if not _check(
		admitted,
		"the server admits them and signon finishes",
		"sessions=%d phase=%s" % [_sessions(), _shell.link.phase if _shell.link else "-"]
	):
		_done()
		return false

	_check(_links().size() == 1, "the shell holds one link (%s)" % _link_names())
	_check(
		_shell.get_node_or_null("Server") == _shell.link,
		"named 'Server', which is what the server's RPCs are addressed to"
	)
	_done()
	return true


func _test_server_goes_down() -> bool:
	_section("the server goes down under them")

	await _stop_host()

	var dropped := await _until(
		func() -> bool: return _shell.link == null, 10.0
	)

	if not _check(
		dropped,
		"the shell lets go of the dropped link",
		"it is still holding %s; the next connect is added beside it and renamed"
			% _link_names()
	):
		_done()
		return false

	_check(
		_links().is_empty(),
		"with nothing left in the tree under that name (%s)" % _link_names()
	)
	_check(
		DotRegistry.get_service(&"dot_client_link") == null,
		"and nothing left in the registry for a game to find"
	)
	_done()
	return true


## The whole bug: pressing Connect after the server comes back.
func _test_reconnect() -> void:
	_section("the server comes back and they press Connect")

	if not _check(await _start_host("Host"), "the server restarts on the same address"):
		_done()
		return

	_shell._connect_to("127.0.0.1:%d" % _port)

	var admitted := await _until(_playing)

	if not _check(
		admitted,
		"the server admits them a second time and signon finishes",
		"sessions=%d phase=%s" % [_sessions(), _shell.link.phase if _shell.link else "-"]
	):
		_done()
		return

	var links := _links()

	_check(
		links.size() == 1,
		"the shell holds ONE link, not two (%s)" % _link_names(),
		"a second link beside the first is renamed 'Server2' and stops being addressable"
	)

	# [b]The check that would have caught the empty screen.[/b] The server addresses its
	# calls to "Server"; a delivered game asks the registry for its link and hangs its own
	# RPC node under whatever it is handed. Those have to be the same object, or the
	# handshake lands on one and the game's snapshots are addressed to the other.
	_check(
		_shell.get_node_or_null("Server") == _shell.link,
		"the node the server's RPCs resolve to is the shell's live link"
	)
	_check(
		DotRegistry.get_service(&"dot_client_link") == _shell.link,
		"and it is the one the registry hands a delivered game",
		"a game that parents its RPC node under any other link renders an empty world"
	)
	_check(
		_shell.get_node(^"Game").get_child_count() > 0,
		"and the game the server sent is on screen (%d children)"
			% _shell.get_node(^"Game").get_child_count(),
		"the pack is still mounted from the first connection, so nothing is downloaded "
			+ "and an empty Game node is exactly what the player was looking at"
	)
	_done()
