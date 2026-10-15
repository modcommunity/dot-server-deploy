extends Node

## Two REAL clients over a REAL socket in a DELIVERED game: does one hear the other?
##
## [codeblock]
## godot --headless --path . res://examples/voice_two_clients.tscn -- --game deathrun
## tools/voice_all_games.sh          # every game, and the table
## [/codeblock]
##
## [b]Why here.[/b] Every game's own suite proves its half on a loopback; only the shell boots
## the game as players get it, a signed pack mounted into a build that does not contain it,
## with each client's dot-voice manager built by the delivered client scene. This finds each
## client's `DotVoiceManager` and the server's `DotVoiceRouter` by walking the trees (nothing
## here can name a game's types), feeds client A a tone through a buffer source (a headless
## run has no microphone; dot-voice's own device probe covers that layer), and asserts:
##
## - with `sv_voice_mode 1` (everybody), A's frames reach B through the server, stamped with
##   A's peer id, and decode to the tone rather than silence;
## - `sv_voice_enable 0` reaches B's manager through the replicated cvar, and nothing more
##   arrives while it is off (armed by the frames before it); 1 brings speech back;
## - with the game's own channel (`sv_voice_mode 0`) it reports whether B heard A, which is
##   the game's rule (team, proximity) and not a failure.
##
## Prints one `VOICE {json}` line at the end for tools/voice_all_games.sh. Exit 0 all held,
## 1 a check failed, 3 the game's pack is not published here.

const ServerWorld := preload("res://examples/server_world.gd")
const CONTENT := "res://content"

## game id (sv_game) -> the packs it needs in dist/.
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

const PORT := 27290

var _game := "buses"
var _data := "user://tmc_voice_two_clients"
var _config := "user://tmc_voice_two_clients_cfg"
var _host: Node = null
var _sides: Array[Node] = []
var _links: Array[DotClientLink] = []
var _passed := 0
var _failed := 0
var _result := {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else DotLog.Level.ERROR)
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--game":
			_game = args[i + 1]
	_data += "_" + _game
	_config += "_" + _game
	_result = {"game": _game}
	_run.call_deferred()


func _check(ok: bool, what: String) -> bool:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	return ok


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _wait(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame


func _run() -> void:
	print("voice between two clients in a delivered %s" % _game)
	for pack in PACKS.get(_game, []):
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/" + pack)):
			print("skipped: dist/%s is not published here" % pack)
			_result["skipped"] = "dist/%s missing" % pack
			print("VOICE " + JSON.stringify(_result))
			get_tree().quit(3)
			return

	_write_config()
	DotPaths.remove_tree(_data)
	var ok := await _boot() and await _connect_both()
	if ok:
		await _probe()
	await _teardown()
	DotPaths.remove_tree(_data)
	DotPaths.remove_tree(_config)
	_result["passed"] = _passed
	_result["failed"] = _failed
	print("%d passed, %d failed" % [_passed, _failed])
	print("VOICE " + JSON.stringify(_result))
	get_tree().quit(1 if _failed > 0 else 0)


## A fixture of this suite's own, so one scene serves every game: the shared fixture files
## with this game in server.yml, the vote off, and a port nothing else here uses.
func _write_config() -> void:
	DotPaths.remove_tree(_config)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_config))
	for name in DirAccess.get_files_at("res://examples/fixtures"):
		if name.ends_with(".yml"):
			var text := FileAccess.get_file_as_string("res://examples/fixtures/" + name)
			if name == "server.yml":
				var lines := PackedStringArray()
				for line in text.split("\n"):
					if line.begins_with("sv_game:") or line.begins_with("sv_map:") or line.begins_with("sv_tickrate:"):
						continue
					lines.append(line)
				lines.append("sv_game: \"%s\"" % _game)
				lines.append("sv_stdin_console: false")
				# Awake: server and clients share one process here, and a hibernating server slows the
				# physics clock the first client then builds its netcode on.
				lines.append("sv_hibernate_when_empty: false")
				text = "\n".join(lines)
			elif name == "net.yml":
				text = "net_bind_ip: \"127.0.0.1\"\nnet_port: %d\n" % PORT
			elif name == "vote.yml":
				text = "enabled: false\n"
			var f := FileAccess.open(_config + "/" + name, FileAccess.WRITE)
			f.store_string(text)
			f.close()


func _server() -> DotServer:
	return _host.server as DotServer


func _boot() -> bool:
	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.auto_start = false
	ServerWorld.add(self, _host)
	var started: DotResult = await _host.start(_config, CONTENT, _data)
	if not _check(started.ok, "the host boots (%s)" % (str(started.error) if not started.ok else "ok")):
		return false
	var reached := await _until(func() -> bool:
		var current := _server().games.current()
		return current != null and current.game_id == _game and _server().games.phase == DotGameManager.Phase.IDLE, 60.0)
	return _check(reached, "and reaches the delivered game")


## The house's own key for a player is the account in two games (look-at-me, delivery), and both
## clients in this process are one guest (one device id per install), so Bea's join took Ada's
## player and kicked her ("You joined from another tab or window"): both games failed here with
## a voice manager freed under the check. Keyed by session, as two people on two machines are
## (burst_probe and lookatme_client do the same).
func _key_by_session() -> void:
	for name in _server().modules.loaded_names():
		var module: DotModule = _server().modules.get_module(name)
		var bridge: Variant = module.get("bridge") if module != null else null
		if bridge is Object and "key_fn" in (bridge as Object):
			(bridge as Object).set("key_fn", Callable())


func _connect_both() -> bool:
	_key_by_session()
	for i in range(2):
		var side := Node.new()
		side.name = "ClientSide%d" % i
		add_child(side)
		get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
		var link := DotClientLink.new()
		link.name = "Server"
		link.player_name = ["Ada", "Bea"][i]
		side.add_child(link)
		_sides.append(side)
		_links.append(link)
		var spawned := [false]
		link.spawned.connect(func() -> void: spawned[0] = true)
		var connecting: DotResult = await link.connect_to_server("127.0.0.1:%d" % PORT)
		if not connecting.ok or not await _until(func() -> bool: return spawned[0], 60.0):
			return _check(false, "client %d finishes signon" % i)
	return _check(true, "two clients finish signon over a real socket")


static func _find(root: Node, cls: String) -> Array[Node]:
	var out: Array[Node] = []
	if root == null:
		return out
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_script() != null and (n.get_script() as Script).get_global_name() == cls:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _probe() -> void:
	var routers := _find(_host, "DotVoiceRouter")
	# A client builds its voice with its scene, which may finish a few frames after signon.
	var _built := await _until(func() -> bool:
		return _find(_sides[0], "DotVoiceManager").size() > 0 and _find(_sides[1], "DotVoiceManager").size() > 0, 15.0)
	var a_mgrs := _find(_sides[0], "DotVoiceManager")
	var b_mgrs := _find(_sides[1], "DotVoiceManager")
	if a_mgrs.is_empty() or b_mgrs.is_empty():
		for m in _find(get_tree().root, "DotVoiceManager"):
			print("  note  a voice manager at %s" % m.get_path())
		for side in _sides:
			var root := side.get_node_or_null(^"Server/GameRoot")
			print("  note  %s GameRoot: %s" % [side.name, str(root.get_children().map(func(n: Node) -> String: return n.name)) if root != null else "none"])
	_result["router"] = routers.size()
	_result["client_voice"] = [a_mgrs.size(), b_mgrs.size()]
	if not _check(routers.size() == 1, "the server runs one voice router (%d)" % routers.size()):
		return
	if not _check(a_mgrs.size() == 1 and b_mgrs.size() == 1, "each delivered client builds one voice manager (%d, %d)" % [a_mgrs.size(), b_mgrs.size()]):
		return
	var router: DotVoiceRouter = routers[0]
	var a: DotVoiceManager = a_mgrs[0]
	var b: DotVoiceManager = b_mgrs[0]
	var a_peer := _links[0].multiplayer.get_unique_id()

	_check(not a.is_capturing() and not b.is_capturing(), "no microphone is open before anybody presses the talk key")

	var heard := DotVoiceSinkBuffer.new()
	heard.sample_rate = b.config.sample_rate
	b.sink_factory = func(_speaker: int) -> DotVoiceSink: return heard
	var mic := DotVoiceSourceBuffer.new()
	mic.sample_rate = a.config.sample_rate
	mic.loop = true
	mic.write(DotVoiceSourceBuffer.tone(440.0, 0.2, mic.sample_rate, 0.4))
	a.source = mic

	# Everybody, so the transport is what is measured.
	var _m := _server().console.set_cvar("sv_voice_mode", "1")
	var replicated := await _until(func() -> bool: return _links[1].replicated_cvar("sv_voice_enable", "") == "1", 10.0)
	_check(replicated, "sv_voice_enable is replicated to the client (%s)" % _links[1].replicated_cvar("sv_voice_enable", "<none>"))

	var pressed := a.update_talk(true)
	_check(pressed.ok and a.is_capturing(), "the first press opens A's capture")
	var arrived := await _until(func() -> bool: return b.frames_received > 20, 10.0)
	_result["heard_all"] = b.frames_received
	_check(arrived, "B receives A's speech through the server (%d frames, %d relayed)" % [b.frames_received, router.relayed_packets])
	# Arrival is not playback: the jitter buffer pops on a real-time accumulator, so a burst of
	# frames after a slow frame can push frames_received past 20 before the sink has been
	# written once (seen ~1 run in 4, 'silence (0.000 rms)'). Wait for the sink itself.
	_result["written_at_arrival"] = heard.frames_written
	var played := await _until(func() -> bool: return heard.frames_written > 10, 10.0)
	_check(played, "B's sink is written from the jitter buffer (%d frames written, %d at arrival)" % [heard.frames_written, _result["written_at_arrival"]])
	_check(b.active_speakers().has(a_peer) or heard.frames_written > 0, "as A's peer id (%d)" % a_peer)
	_check(heard.rms() > 0.1, "and it plays the tone, not silence (%.3f rms)" % heard.rms())
	_result["rms"] = snappedf(heard.rms(), 0.001)

	# Off: the client learns it, and nothing more arrives.
	var _off := _server().console.set_cvar("sv_voice_enable", "0")
	var learned := await _until(func() -> bool: return not b.server_enabled and not a.server_enabled, 10.0)
	_check(learned, "sv_voice_enable 0 reaches both clients' managers")
	await _wait(0.4)
	var at_off := b.frames_received
	var _again := a.update_talk(true)
	await _wait(1.0)
	_result["leaked_off"] = b.frames_received - at_off
	_check(b.frames_received - at_off <= 1 and not a.is_capturing(), "and nothing is sent or relayed while it is off (%d)" % (b.frames_received - at_off))

	var _on := _server().console.set_cvar("sv_voice_enable", "1")
	var back := await _until(func() -> bool: return b.server_enabled and a.server_enabled, 10.0)
	var _t := a.update_talk(false)
	var _p := a.update_talk(true)
	var at_on := b.frames_received
	var resumed := await _until(func() -> bool: return b.frames_received - at_on > 10, 10.0)
	_check(back and resumed, "1 turns it back on and speech arrives again (%d)" % (b.frames_received - at_on))

	# The game's own channel: reported, not asserted.
	var _g := _server().console.set_cvar("sv_voice_mode", "0")
	await _wait(0.3)
	var at_game := b.frames_received
	await _wait(1.0)
	_result["game_channel"] = router.default_channel
	_result["heard_game_channel"] = b.frames_received - at_game
	print("  note  with the game's own channel (%d) B received %d frames in 1 s" % [router.default_channel, b.frames_received - at_game])
	var _r := a.update_talk(false)


func _teardown() -> void:
	for link in _links:
		if is_instance_valid(link):
			link.disconnect_from_server("test over")
	await get_tree().process_frame
	for side in _sides:
		if is_instance_valid(side):
			remove_child(side)
			side.queue_free()
	_sides.clear()
	_links.clear()
	await get_tree().process_frame
	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")
		ServerWorld.remove(_host)
		_host.queue_free()
		_host = null
	await get_tree().process_frame
