extends Node
# [b]Nothing preloaded out of a game, because no game is in this build.[/b] Every game is a
# delivered pack; its RPC link is found by the counters every game's link keeps, its player by
# dot-net's registry, and dot-game-template (whose link keeps no counters) by dot-net's own.

## A real client on ENet, through dot-net's lossy UDP relay, in a DELIVERED game: do its commands
## reach the server, do the server's snapshots reach it, and does ENet's packet throttle leave
## both alone?
##
## [codeblock]
## godot --headless --path . res://examples/enet_relay.tscn -- --game arena
## godot --headless --path . res://examples/enet_relay.tscn -- --game arena --stock-throttle
## tools/enet_relay_all_games.sh            # every delivered game, the control, and the table
## [/codeblock]
##
## [b]Why here.[/b] ENet's packet throttle drops unreliable packets at the SENDER when a reliable
## acknowledgement comes back later than the last interval's lowest round trip plus twice its
## variance; on a steady path that variance is a few milliseconds, so a joiner's reliable burst
## acknowledged across one long frame takes the throttle to 0, and the client's commands and the
## server's snapshots stop arriving at 0% loss (dot-core's [code]DotTransportENet.
## packet_throttle_deceleration[/code], docs/transports.md). Loopback never shows it: there the
## round trip is under its own variance. Only mg-look-at-me, game-arena and game-g2gfast had a
## relay suite of their own, each inside its own project; this runs every game as players get
## it, a signed pack mounted into the shell, with the real dual-stack host and a real
## [DotClientLink] that picked ENet.
##
## [b]What it does.[/b] Boots the host on the game; puts the relay in front of its UDP port with a
## steady 60 ms each way; joins on ENet through it; holds the movement keys (W, then S, a second
## each) so the delivered client scene sends real commands. Two windows: 60 ms with no loss, with
## three 300 ms frames at its start (both ends stall, as a server loading a level does), then 60 ms
## at 5% loss. Each window checks: the share of the client's inputs the server's game link
## received, the share of the server's snapshots the client's game link received (at least 90% of
## what the relay let through), ENet's packet throttle at 32 at both ends for the whole window, and
## that the player moved on the server: the server link's input counter moved, and where dot-net's
## registry has an entity the client's peer owns, its path (teleports left out) was at least a
## metre, or 64 px in a 2D game. The throttle is also held to 32 from the connect through the join.
## dot-game-template's link keeps no counters, so there dot-net's own stand in (see [method
## _measure]); Delivery registers no entity per player, so there the counters are the whole probe.
##
## [code]--stock-throttle[/code] is the control: it puts ENet's throttle back as the engine ships
## it at both ends as each connects, and again whenever either end says otherwise (each end's own
## connect sends dot-core's setting to the far end, which can land later), and the throttle checks
## must fail. tools/enet_relay_all_games.sh requires that of every game.
##
## Prints one `RELAY {json}` line for the table. Exit 0 all held, 1 a check failed, 3 the game's
## pack is not published here (or the template or dot-ci is not beside this project).

const ServerWorld := preload("res://examples/server_world.gd")
const Installer := preload("res://tools/install_games.gd")
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

const CONTENT := "res://content"

## game id (sv_game) -> the packs it needs in dist/. dot-game-template is packaged by this run.
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

## Cvars set as the game is reached, before anybody joins, so the client's player can walk in the
## first seconds of a round. Prop Hunt holds a hunter still while the props hide.
const CVARS := {
	"prophunt": {"ph_hide_seconds": "3"},
}

## The template, published the way template_client publishes it (the site's half stood in for).
const TEMPLATE := "dot-game-template"
const TEMPLATE_ID := "someone/dot-game-template"
const TEMPLATE_VERSION := "0.0.1"

const PORT := 27310

## What [method _publish_template] returns when the template is here and did not publish.
const FAILED := "<failed>"

## Name, loss each way, delay each way (ms), seconds walked, long frames at its start.
const WINDOWS := [
	["60 ms, no loss, three 300 ms frames", 0.0, 60.0, 8.0, 3],
	["60 ms, 5% loss", 0.05, 60.0, 8.0, 0],
]
const HITCH_MS := 300

## Checks: boot 3, join 3, then each window's.
const WINDOW_CHECKS := 5
const SECTIONS := 2 + 2
const CHECKS := 3 + 3 + 2 * WINDOW_CHECKS

## How far the server's player must be carried in a window, where it can be seen: metres, or
## pixels in a 2D game (dot-game-template's player drifts about 2 px a second with no key held).
const MIN_MOVE := 1.0
const MIN_MOVE_2D := 64.0
## A step longer than this in one physics frame is a teleport, not a walk: metres, and pixels for
## a 2D game (whose distances are pixels throughout, MIN_MOVE included).
const TELEPORT := 3.0
const TELEPORT_2D := 100.0
## How far the server link's input counter must move in a window: an input a client tick.
const MIN_INPUTS := 30

var _game := "buses"
var _stock := false
var _verbose := false
var _root := "user://tmc_enet_relay"
var _host: Node = null
var _relay = null
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

## The lowest throttle seen at each end [client, server] since it was last reset.
var _low := [32, 32]
var _watching := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_verbose = "--verbose" in args
	_stock = "--stock-throttle" in args
	for i in range(args.size() - 1):
		if args[i] == "--game":
			_game = args[i + 1]
	DotLog.set_level(DotLog.Level.DEBUG if _verbose else DotLog.Level.ERROR)
	_root += "_" + _game.replace("-", "_")
	_result = {"game": _game, "stock": _stock}
	_run.call_deferred()


func _run() -> void:
	print("%s: a client on ENet through a lossy relay%s" % [_game, " (stock throttle: must fail)" if _stock else ""])
	DotPaths.remove_tree(_root)
	var content := CONTENT
	if _game == TEMPLATE:
		content = _publish_template()
		if content == "":
			_skip("no dot-game-template or dot-ci beside this project")
			return
		if content == FAILED:
			print("  FAIL  dot-game-template's HEAD did not package and publish")
			print("RELAY " + JSON.stringify(_result))
			DotPaths.remove_tree(_root)
			get_tree().quit(1)
			return
	else:
		if not PACKS.has(_game):
			push_error("unknown game %s" % _game)
			get_tree().quit(2)
			return
		for pack in PACKS[_game]:
			if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/" + pack)):
				_skip("dist/%s is not published here" % pack)
				return
		_write_config("")

	if await _boot(content) and await _join():
		for window in WINDOWS:
			await _window(window)

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
	print("RELAY " + JSON.stringify(_result))
	get_tree().quit(code)


func _skip(why: String) -> void:
	print("skipped: %s" % why)
	_result["skipped"] = why
	print("RELAY " + JSON.stringify(_result))
	DotPaths.remove_tree(_root)
	get_tree().quit(3)


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


## Fails [param n] checks that cannot run, so the total still adds up.
func _cannot(n: int, why: String) -> void:
	for i in range(n):
		_check(false, "(not reached)", why)


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _seconds(s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame


# --- Config and the template's pack -------------------------------------------

## The shared fixture files with this game in server.yml, the vote off, a port nothing else here
## uses, and the server awake (a hibernating server slows the clock a joiner builds its netcode
## on). [param trusted_key] adds a content.json that trusts that key (the template's run key).
func _write_config(trusted_key: String) -> void:
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
			# Warnings and worse, to the terminal only: one log per game is read by a person.
			text = "log_level: warn\nlog_file: false\n"
		DotPaths.write_text(cfg.path_join(name), text)
	if trusted_key != "":
		DotPaths.write_text(cfg.path_join("content.json"), JSON.stringify({
			"require_signed_manifests": true,
			"trusted_keys": {"default": trusted_key},
		}))


## The template's HEAD packaged by dot-ci's package.sh, signed under someone/dot-game-template with
## a key made for this run, into a content directory of this run's own. Returns that directory, ""
## when the template or dot-ci is not here, or [constant FAILED].
func _publish_template() -> String:
	var here := ProjectSettings.globalize_path("res://")
	var source := ""
	for dir in [OS.get_environment("TEMPLATE_SOURCE"), here.path_join("games/dot-game-template"),
			here.path_join("../dot-game-template").simplify_path()]:
		if dir != "" and FileAccess.file_exists(str(dir).path_join("game.yml")):
			source = dir
			break
	var package_sh := here.path_join("../dot-ci/scripts/package.sh").simplify_path()
	if source == "" or not FileAccess.file_exists(package_sh):
		return ""

	var godot := OS.get_executable_path()
	OS.set_environment("GODOT", godot)
	if not DirAccess.dir_exists_absolute(source.path_join(".godot/imported")):
		OS.execute(godot, ["--headless", "--path", source, "--import"])
	var out := ProjectSettings.globalize_path(_root.path_join("release"))
	var said: Array = []
	var status := OS.execute("bash", [package_sh, source, TEMPLATE_VERSION, "--out", out, "--name", TEMPLATE, "--pack"], said, true)
	var zip := out.path_join("%s-%s-pack.zip" % [TEMPLATE, TEMPLATE_VERSION])
	if status != 0 or not FileAccess.file_exists(zip):
		print("  package.sh: %s" % str(said).left(400))
		return FAILED
	var pack_dir := ProjectSettings.globalize_path(_root.path_join("unpacked"))
	DirAccess.make_dir_recursive_absolute(pack_dir)
	if OS.execute("unzip", ["-q", "-o", zip, "-d", pack_dir]) != 0:
		return FAILED

	var pair := DotCloudSignature.generate_keypair()
	if not pair.ok:
		return FAILED
	var descriptor := Installer.stamp_identity(
		FileAccess.get_file_as_string(pack_dir.path_join("game.yml")), TEMPLATE_ID, TEMPLATE_VERSION)
	if not descriptor.ok:
		return FAILED
	var fields: Dictionary = TmcYaml.parse(str(descriptor.value), "<stamped>").value
	var publisher := DotCloudPublisher.new()
	publisher.content_id = TEMPLATE_ID
	publisher.version = TEMPLATE_VERSION
	publisher.display_name = str(fields.get("name", ""))
	publisher.entry_scene = str(fields.get("client_scene", ""))
	publisher.signing_key_pem = str(pair.value["private"])
	publisher.signing_key_id = "default"
	var content := _root.path_join("content")
	var published := publisher.publish(pack_dir, ProjectSettings.globalize_path(
		content.path_join(TEMPLATE_ID).path_join(TEMPLATE_VERSION)))
	if not published.ok:
		print("  publish: %s" % str(published.error))
		return FAILED
	DotPaths.write_text(content.path_join(TEMPLATE).path_join("game.yml"), str(descriptor.value))
	_write_config(str(pair.value["public"]))
	return content


# --- Boot and join ------------------------------------------------------------

func _server() -> DotServer:
	return _host.server as DotServer


func _boot(content: String) -> bool:
	_section("a dual-stack host on the delivered game, and the relay in front of its UDP port")
	_host = (load("res://host/host.tscn") as PackedScene).instantiate()
	_host.auto_start = false
	ServerWorld.add(self, _host)
	var started: DotResult = await _host.start(_root.path_join("cfg"), content, _root.path_join("data"))
	if not _check(started.ok, "the host boots", "" if started.ok else str(started.error)):
		_cannot(2, "no host")
		_done()
		return false
	var reached := await _until(func() -> bool:
		var current := _server().games.current()
		return current != null and current.game_id == _game and _server().games.phase == DotGameManager.Phase.IDLE, 60.0)
	_check(reached, "and reaches the delivered game")
	var cvars: Dictionary = CVARS.get(_game, {})
	for cvar in cvars:
		var _set := _server().console.set_cvar(cvar, str(cvars[cvar]))

	_relay = Relay.new()
	_relay.seed = 20261012
	var w: Array = WINDOWS[0]
	_relay.up.configure(0.0, float(w[2]), 0.0)
	_relay.down.configure(0.0, float(w[2]), 0.0)
	var relayed: DotResult = _relay.start(0, "127.0.0.1", PORT)
	_check(relayed.ok, "the relay listens in front of UDP %d, %d ms each way" % [PORT, int(w[2])],
		"" if relayed.ok else str(relayed.error))
	_done()
	return reached and relayed.ok


func _join() -> bool:
	_section("a client joins on ENet through the relay")
	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Walker"
	_link.transport_preference = "udp"
	_link.udp_address = "127.0.0.1:%d" % _relay.port()
	_client_side.add_child(_link)
	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _gone[0] = reason)

	_low = [32, 32]
	_watching = true
	var t0 := Time.get_ticks_msec()
	# Not awaited: the control configures the client's peer the frame it exists, before the join.
	var _connecting: Variant = _link.call("connect_to_server", "127.0.0.1:%d" % PORT)
	var seated := await _until(func() -> bool:
		return _spawned[0] or _gone[0] != "" or _link.phase == DotClientLink.Phase.FAILED, 60.0)
	_check(seated and _spawned[0] and _link.transport_used == "enet", "it is seated, on ENet",
		"transport %s, %.1f s%s" % [_link.transport_used, (Time.get_ticks_msec() - t0) / 1000.0,
			"" if _gone[0] == "" else ", " + _gone[0]])
	if not _spawned[0]:
		_cannot(2, "not seated")
		_done()
		return false

	var found := await _until(func() -> bool: return _probe_ready(), 20.0)
	var how := _measure()
	_result["link"] = how.get("link", "-")
	_check(found, "the game's own link is found at both ends", str(how.get("link", "none")))
	# The join is the burst of reliable data (the game's state, every replicated cvar, a level):
	# held to 32 from the connect to here.
	await _seconds(2.0)
	_result["join_throttle"] = _low.duplicate()
	_result["deceleration"] = [_statistic(_client_side.multiplayer.multiplayer_peer, 1, &"PEER_PACKET_THROTTLE_DECELERATION"),
		_statistic(_server().multiplayer.multiplayer_peer, _client_side.multiplayer.get_unique_id(), &"PEER_PACKET_THROTTLE_DECELERATION")]
	_check(_low[0] == 32 and _low[1] == 32, "ENet's packet throttle stays at 32 at both ends through the join",
		"lowest client %d, server %d" % [_low[0], _low[1]])
	_done()
	return found


# --- The probe: links, the throttle, the player ---------------------------------

## The game's RPC link under [param parent]: the child keeping a link's counters, not retired.
static func _game_link(parent: Node, counter: String) -> Node:
	if parent == null or not is_instance_valid(parent):
		return null
	var found: Node = null
	for child in parent.get_children():
		if counter in child and not String(child.name).contains("_retired_"):
			found = child
	return found


## Every node under [param root] whose script is (or extends) the global class [param cls].
static func _find(root: Node, cls: String) -> Array[Node]:
	var out: Array[Node] = []
	if root == null:
		return out
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var s: Script = n.get_script()
		while s != null:
			if s.get_global_name() == cls:
				out.append(n)
				break
			s = s.get_base_script()
		for c in n.get_children():
			stack.append(c)
	return out


func _net(root: Node, server: bool) -> DotNetManager:
	for n in _find(root, "DotNetManager"):
		var m := n as DotNetManager
		if m.is_server == server and m.is_running():
			return m
	return null


func _probe_ready() -> bool:
	if _game_link(_server(), "inputs_received") != null and _game_link(_link, "snapshots_received") != null:
		return true
	# No counters (dot-game-template): dot-net's own, at both ends.
	return _net(_host, true) != null and _net(_client_side, false) != null \
		and _game_link(_server(), "inputs_received") == null


## The counters now: inputs sent and received, snapshots sent and received, and what measured them.
func _measure() -> Dictionary:
	var server_link := _game_link(_server(), "inputs_received")
	var client_link := _game_link(_link, "snapshots_received")
	if server_link != null and client_link != null:
		return {
			"link": String(server_link.name),
			"inputs_sent": int(client_link.get("inputs_sent")),
			"inputs_got": int(server_link.get("inputs_received")),
			"snaps_sent": int(server_link.get("snapshots_sent")),
			"snaps_got": int(client_link.get("snapshots_received")),
		}
	# dot-net's: the client's snapshots received against those it knows it lost, and the server's
	# input buffer for this peer, ticks it played with no command against ticks it played.
	var sn := _net(_host, true)
	var cn := _net(_client_side, false)
	if sn == null or cn == null:
		return {}
	var peer := _client_side.multiplayer.get_unique_id()
	var buffer: DotNetInput.Buffer = sn.input_buffer_for(peer) if sn.peers().has(peer) else null
	var consumed := buffer.last_consumed_tick() if buffer != null else 0
	var starved := buffer.starved_count if buffer != null else 0
	return {
		"link": "dot-net",
		"inputs_sent": consumed,
		"inputs_got": consumed - starved,
		"snaps_sent": cn.stats.snapshots_received + cn.stats.snapshots_lost,
		"snaps_got": cn.stats.snapshots_received,
	}


## A peer's ENet packet throttle out of 32, or -1 off ENet. [param mp] is the end's multiplayer
## peer, unwrapped through DotMeteredPeer ([code]inner[/code]) and DotDualPeer ([code]enet[/code]).
static func _throttle(mp: Object, peer_id: int) -> int:
	var packet_peer := _packet_peer(mp, peer_id)
	if packet_peer == null:
		return -1
	return int(packet_peer.call("get_statistic",
		ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_PACKET_THROTTLE")))


static func _statistic(mp: Object, peer_id: int, which: StringName) -> int:
	var packet_peer := _packet_peer(mp, peer_id)
	if packet_peer == null:
		return -1
	return int(packet_peer.call("get_statistic", ClassDB.class_get_integer_constant(&"ENetPacketPeer", which)))


static func _packet_peer(mp: Object, peer_id: int) -> Object:
	var at: Object = mp
	for i in range(4):
		if at == null:
			return null
		if at.is_class("ENetMultiplayerPeer"):
			return at.call("get_peer", peer_id)
		if "inner" in at:
			at = at.get("inner")
		elif "enet" in at:
			at = at.get("enet")
		else:
			return null
	return null


## Asked only once the peer is connected at that end: ENet's get_peer errors on an id it lacks.
func _client_throttle() -> int:
	if not _client_side.multiplayer.get_peers().has(1):
		return -1
	return _throttle(_client_side.multiplayer.multiplayer_peer, 1)


func _server_throttle() -> int:
	var id := _client_side.multiplayer.get_unique_id()
	if _host == null or _host.server == null or not _server().multiplayer.get_peers().has(id):
		return -1
	return _throttle(_server().multiplayer.multiplayer_peer, id)


func _physics_process(_delta: float) -> void:
	if not _watching or _client_side == null:
		return
	# The control: ENet's own throttle back at both ends, from the frame each end has the peer,
	# before the join's reliable traffic. Each end's own connect sets dot-core's and sends it to the
	# far end, which can land after this; so it is put back whenever either end says otherwise.
	if _stock:
		_stock_back(_client_side.multiplayer.multiplayer_peer, 1, _client_side.multiplayer.get_peers().has(1))
		if _host != null and _host.server != null:
			var id := _client_side.multiplayer.get_unique_id()
			_stock_back(_server().multiplayer.multiplayer_peer, id, _server().multiplayer.get_peers().has(id))
	var c := _client_throttle()
	var s := _server_throttle()
	if c >= 0:
		_low[0] = mini(_low[0], c)
	if s >= 0:
		_low[1] = mini(_low[1], s)


func _stock_back(mp: Object, peer_id: int, connected: bool) -> void:
	if not connected:
		return
	var packet_peer := _packet_peer(mp, peer_id)
	if packet_peer == null:
		return
	var said := int(packet_peer.call("get_statistic",
		ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_PACKET_THROTTLE_DECELERATION")))
	if said != DotTransportENet.ENET_DEFAULT_THROTTLE_DECELERATION:
		packet_peer.call("throttle_configure", DotTransportENet.ENET_DEFAULT_THROTTLE_INTERVAL_MS,
			DotTransportENet.ENET_DEFAULT_THROTTLE_ACCELERATION, DotTransportENet.ENET_DEFAULT_THROTTLE_DECELERATION)


## Where the server has the client's player: the first entity dot-net's registry says the client's
## peer owns that is a Node2D or a Node3D in the tree. Null where the game keeps none.
func _server_player() -> Node:
	var sn := _net(_host, true)
	if sn == null:
		return null
	for identity in sn.registry.owned_by(_client_side.multiplayer.get_unique_id()):
		var e: Node = identity.entity
		if e != null and is_instance_valid(e) and e.is_inside_tree() and (e is Node3D or e is Node2D):
			return e
	return null


static func _where(node: Node) -> Vector3:
	if node is Node3D:
		return (node as Node3D).global_position
	var p := (node as Node2D).global_position
	return Vector3(p.x, p.y, 0.0)


## Holds one movement key down (and the other up), the way a keyboard does: a physical key and
## its keycode, so a game reading actions and one reading keys both see it.
static func _hold(key: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = down
	Input.parse_input_event(event)


func _window(window: Array) -> void:
	var title := str(window[0])
	var loss := float(window[1])
	_section("walking, %s" % title)
	_relay.set_impairment(true, loss, float(window[2]), 0.0)
	_relay.set_impairment(false, loss, float(window[2]), 0.0)
	# A second with no key held first: how far the game moves the player on its own (a fall, a
	# conveyor, a push) is reported beside how far the keys carried it.
	var idle := await _path(1.0, -1)

	var before := _measure()
	_relay.reset_counts()
	_low = [32, 32]
	var walked := await _path(float(window[3]), int(window[4]))
	_hold(KEY_W, false)
	_hold(KEY_S, false)
	await _seconds(0.6)

	var after := _measure()
	var said: Dictionary = _relay.describe()
	var inputs_sent := int(after.get("inputs_sent", 0)) - int(before.get("inputs_sent", 0))
	var inputs_got := int(after.get("inputs_got", 0)) - int(before.get("inputs_got", 0))
	var snaps_sent := int(after.get("snaps_sent", 0)) - int(before.get("snaps_sent", 0))
	var snaps_got := int(after.get("snaps_got", 0)) - int(before.get("snaps_got", 0))
	var in_share := float(inputs_got) / float(maxi(inputs_sent, 1))
	var snap_share := float(snaps_got) / float(maxi(snaps_sent, 1))
	# What the relay lets through, less a margin for the packets in flight at either edge.
	var floor_share := (1.0 - loss) * 0.9
	var row := {
		"inputs": [inputs_got, inputs_sent], "snapshots": [snaps_got, snaps_sent],
		"throttle": _low.duplicate(), "moved": snappedf(walked[0], 0.01) if walked[1] > 0 else -1.0,
		"idle": snappedf(idle[0], 0.01) if idle[1] > 0 else -1.0, "bodies": walked[1],
		"loss": [said["up"]["measured_loss"], said["down"]["measured_loss"]],
	}
	_result["w%d" % (_entered - 2)] = row

	_check(inputs_sent > MIN_INPUTS and in_share >= floor_share, "the server's link received the client's inputs",
		"%d of %d, %.0f%%" % [inputs_got, inputs_sent, in_share * 100.0])
	_check(snaps_sent > 10 and snap_share >= floor_share, "the client's link received the server's snapshots",
		"%d of %d, %.0f%%" % [snaps_got, snaps_sent, snap_share * 100.0])
	_check(_low[0] == 32 and _low[1] == 32, "ENet's packet throttle stayed at 32 at both ends",
		"lowest client %d, server %d" % [_low[0], _low[1]])
	var unit := "px" if walked[2] else "m"
	_check(inputs_got > MIN_INPUTS and (walked[1] == 0 or walked[0] >= (MIN_MOVE_2D if walked[2] else MIN_MOVE)),
		"the held keys move the player on the server",
		("%d inputs; walked %.2f %s (%.2f in the idle second before)" % [inputs_got, walked[0], unit, idle[0]]) if walked[1] > 0
			else "%d inputs; no positioned entity the client's peer owns in dot-net's registry" % inputs_got)
	_check(_link.phase == DotClientLink.Phase.PLAYING and _gone[0] == "", "the client is still connected", _gone[0])
	_done()


## How far the server's player is carried over [param seconds]: the path, frame by frame, without
## any step longer than [constant TELEPORT] (a respawn or a round putting it somewhere is not a
## walk). [param hitches] >= 0 holds W and S a second each, with that many long frames at the
## start; -1 holds nothing. Returns [distance, bodies seen (0: no positioned entity), 2D].
func _path(seconds: float, hitches: int) -> Array:
	var t0 := Time.get_ticks_msec()
	var deadline := t0 + int(seconds * 1000.0)
	var player := _server_player()
	var last := _where(player) if player != null else Vector3.ZERO
	var bodies := 1 if player != null else 0
	var metres := 0.0
	var flat := player is Node2D
	var leg := 0
	while Time.get_ticks_msec() < deadline:
		if hitches >= 0:
			var key := KEY_W if leg % 2 == 0 else KEY_S
			_hold(KEY_S if key == KEY_W else KEY_W, false)
			_hold(key, true)
		var leg_end := mini(Time.get_ticks_msec() + 1000, deadline)
		while Time.get_ticks_msec() < leg_end:
			await get_tree().physics_frame
			if hitches > 0 and Time.get_ticks_msec() - t0 > 250 * (4 - hitches):
				# A long frame: one process, so both ends stall, as a server loading a level does.
				OS.delay_msec(HITCH_MS)
				hitches -= 1
			# Resolved every frame: a round may give the player a new body, and the old one can
			# stay in the tree (a corpse, a prop it left) without being moved again.
			var now := _server_player()
			if now != player:
				player = now
				bodies += 1 if player != null else 0
				if player != null:
					last = _where(player)
					flat = player is Node2D
				continue
			if player != null:
				var at := _where(player)
				var step := at.distance_to(last)
				if step < (TELEPORT_2D if player is Node2D else TELEPORT):
					metres += step
				last = at
		leg += 1
	_hold(KEY_W, false)
	_hold(KEY_S, false)
	return [metres, bodies, flat]


func _teardown() -> void:
	_watching = false
	_hold(KEY_W, false)
	_hold(KEY_S, false)
	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("test over")
	await _seconds(0.3)
	if _relay != null:
		_relay.stop()
	if _client_side != null and is_instance_valid(_client_side):
		remove_child(_client_side)
		_client_side.queue_free()
	await get_tree().process_frame
	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")
		ServerWorld.remove(_host)
		_host.queue_free()
		_host = null
	await get_tree().process_frame
