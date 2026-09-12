extends Node

## Boots a [DotServer] from `cfg/` and `content/`, and prints an address a friend can
## paste.
##
## This is what `./server` runs. Everything an operator configures reaches the server
## through here, and nothing here decides anything a config file could have said.
##
## [codeblock]
## godot --headless --path . res://host/host.tscn -- --config cfg --content content
## [/codeblock]
##
## [b]The boot order is dot-server's and it is load-bearing.[/b]
##
## [codeblock]
## cfg/*.yml read                    <- refuses a malformed file, naming the line
##   -> DotServerConfig built
##   -> command line overrides it    <- one run, without editing a file
##   -> server.boot()
##        console created, cvars registered
##        cfg's console lines run    <- FLAG_STARTUP_ONLY still settable
##        LISTENER OPENS             <- and locks
##   -> content scanned, games registered
##   -> the default game loads
##   -> its module loads
## [/codeblock]
##
## The console lines run inside `boot()` because that is the only window in which
## `sv_tickrate` and the port can still be set. Games are registered afterwards because
## [method DotGameManager.change_game] can only change to a game it already knows about.

const CHANNEL := "tmc.host"

## Exit codes, so a supervisor can tell a misconfiguration from a crash.
##
## The same set `dotserve` uses and the same reason: a server that cannot find its config
## will not find it on the ninetieth attempt either, and retrying turns one clear error
## into a journal full of them.
const EXIT_OK := 0
const EXIT_USAGE := 2
const EXIT_CONFIG := 5
const EXIT_PORT := 6
const EXIT_CONTENT := 7

var config: TmcConfig = null
var content: TmcContent = null
var admins: TmcAdmins = null
var server: DotServer = null

## Voting for the next game, or null when `vote.yml` turns it off.
var votes: TmcVote = null

## Reports this server's own state to its site listing. Never null; it reports nothing
## when there is no token, which is every LAN deployment and every test.
var listing: TmcReport = null

var _config_dir := "cfg"
var _content_dir := "content"

## Where everything the server *writes* goes: admins, bans, the audit log, the generated
## config, and any state a game keeps.
##
## [b]One directory, separate from the two it reads.[/b] A container mounts `cfg/` and
## `content/` read-only and `data/` read-write; a systemd unit points `ReadWritePaths` at
## exactly this and nothing else. Mixing written state into the config directory is what
## makes both of those impossible to express.
var _data_dir := "data"

var _selftest := false

## The module currently loaded on behalf of the running game, and where it came from.
##
## The path is what is compared, not the id: two game ids can share one module — hungry's
## classic and frenzy do — and reloading it between them would disconnect everybody.
var _module_name := ""
var _module_path := ""

## Whether the last game change failed to bring its module up.
##
## Fatal at boot and merely loud afterwards: at boot there is nobody to disappoint and a
## server running a game with no netcode is worse than one that refused to start, but once
## players are on it, refusing to continue drops them because one game is broken.
var _module_failed := false


func _ready() -> void:
	# [b]The RPC routing, and it is not optional.[/b] Godot addresses an RPC by the
	# receiver's node path *relative to its MultiplayerAPI root*, which by default is
	# `/root`. So a [DotServer] at `/root/Host/Server` sends calls addressed to
	# "Host/Server", and the client shell — whose [DotClientLink] is at `/root/Shell/Server`
	# — answers every one of them with `Node not found: "Host/Server"`. The handshake
	# included, whose only symptom is a timeout.
	#
	# Scoping an API to this subtree makes the path relative to *this node*, so both ends
	# send and expect "Server" and neither has to know what the other's scene is called.
	# dot-platform's sandbox proved the mechanism; this is the deployment that needs it.
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), get_path()
	)

	if auto_start:
		_run.call_deferred()


## Whether entering the tree reads the command line and starts a server.
##
## On, because that is what `./server` runs. Off is for anything that wants the same boot
## with directories of its own and no `quit()` at the end — `examples/multigame.tscn` does,
## and the point of the switch is that it drives the *real* boot rather than a second one
## written to look like it.
@export var auto_start: bool = true


func _run() -> void:
	var args := OS.get_cmdline_user_args()

	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in args else DotLog.Level.INFO
	)

	_config_dir = _value(args, "--config", "cfg")
	_content_dir = _value(args, "--content", "content")
	_data_dir = _value(args, "--data", "data")
	_selftest = "--selftest" in args

	var made := DirAccess.make_dir_recursive_absolute(_absolute(_data_dir))

	if made != OK and made != ERR_ALREADY_EXISTS:
		_die(EXIT_CONFIG, "Could not create the data directory %s." % _data_dir)
		return

	var loaded := TmcConfig.load_dir(_config_dir)

	if not loaded.ok:
		_die(EXIT_CONFIG, str(loaded.error))
		return

	config = loaded.value as TmcConfig
	_apply_overrides(args)

	if _selftest:
		# [b]A boot test must not need the live port.[/b] `./server check` is what CI runs
		# and what an operator runs to find out why a server will not start — and both of
		# those happen on a box where one is very often already serving. Binding the
		# configured port would then fail with "already in use", which is true and is not
		# the question being asked.
		#
		# Port 0 lets the OS pick a free one. RCON goes off with it because
		# `DotServerConfig.validate` refuses an ephemeral game port alongside an RCON
		# password with no explicit port — there is no fixed number to derive one from —
		# and a check does not administer anything.
		config.server.port = 0
		config.server.rcon_password = ""

	if "--print-config" in args:
		for line in config.describe_lines():
			print(line)

		get_tree().quit(EXIT_OK)
		return

	var scanned := TmcContent.scan(_content_dir)

	if not scanned.ok:
		_die(EXIT_CONTENT, str(scanned.error))
		return

	content = scanned.value as TmcContent

	if "--list-games" in args:
		for line in content.describe_lines():
			print(line)

		get_tree().quit(EXIT_OK)
		return

	var built := await _boot()

	if not built:
		return

	_announce()


	if _selftest:
		# Booted, listened, loaded a game and loaded a module — which is everything
		# `./server --check` claims. Shutting down here rather than serving is what makes
		# that claim checkable in CI without a client.
		server.shutdown("selftest complete")
		print("")
		print("selftest ok")
		get_tree().quit(EXIT_OK)


## Reads the configuration and brings a server up, without touching the command line.
##
## What `_run` does between parsing argv and printing the address, and the only path either
## of them takes. A test that reimplemented the boot would be testing its own copy of it,
## and the first thing to drift would be the ordering — which is where every bug in this
## file has been.
func start(
	config_dir: String,
	content_dir: String,
	data_dir: String
) -> DotResult:
	_config_dir = config_dir
	_content_dir = content_dir
	_data_dir = data_dir

	DirAccess.make_dir_recursive_absolute(_absolute(data_dir))

	var loaded := TmcConfig.load_dir(_config_dir)

	if not loaded.ok:
		return loaded

	config = loaded.value as TmcConfig

	var scanned := TmcContent.scan(_content_dir)

	if not scanned.ok:
		return scanned

	content = scanned.value as TmcContent

	var built: bool = await _boot()

	if not built:
		return DotResult.fail(DotError.CODE_STATE, "The server did not come up.")

	return DotResult.success(self)


static func _absolute(path: String) -> String:
	if path.contains("://") or path.begins_with("/"):
		return path

	return ProjectSettings.globalize_path("res://").path_join(path)


## `--sv-*` style overrides, for one run without editing a file.
##
## Deliberately narrow: a port, a bind address, a name, a game. Everything else belongs in
## `cfg/`, because a flag is invisible to whoever reads the config file next — and secrets
## are refused outright, for [method DotConfig.sensitive_keys]'s reason: argv is readable
## by every other process on the machine and ends up in pasted bug reports.
func _apply_overrides(args: PackedStringArray) -> void:
	var port := _value(args, "--port", "")

	if port != "":
		config.server.port = port.to_int()

	var bind := _value(args, "--bind", "")

	if bind != "":
		config.server.bind_address = bind

	var hostname := _value(args, "--name", "")

	if hostname != "":
		config.server.hostname = hostname

	var players := _value(args, "--max-players", "")

	if players != "":
		config.server.max_players = players.to_int()

	var game := _value(args, "--game", "")

	if game != "":
		config.initial_game = game

	for flag in ["--rcon-password", "--password"]:
		if flag in args:
			DotLog.warn(CHANNEL, "a secret on the command line is refused", {
				"flag": flag,
				"why": "argv is readable by other processes; put it in cfg/server.yml",
			})


func _boot() -> bool:
	# Everything the server writes goes under one directory. Set before `boot()` because
	# dot-server reads them during it: the admin file is loaded, a template is written if
	# there is none, and the audit log is opened.
	config.server.admins_path = "%s/admins.json" % _data_dir
	config.server.bans_path = "%s/bans.json" % _data_dir
	config.server.audit_log_path = "%s/audit.jsonl" % _data_dir

	server = DotServer.new()
	server.name = "Server"
	server.config = config.server
	server.config_file = ""
	server.auto_boot = false
	# Both config slots are named absolutely, so dot-server's search path cannot reach the
	# `server.cfg` and `autoexec.cfg` its own addon ships. Those are correct defaults for a
	# deployment configured with `.cfg` files and wrong for one that has chosen YAML: they
	# would run after the operator's settings and silently override them. `cfg/autoexec.cfg`
	# is still honoured, and still runs after the listener opens, because that is where
	# something dot-server has and this format does not belongs.
	config.server.autoexec_config = "%s/autoexec.cfg" % _config_dir
	add_child(server)

	# The YAML's console lines are compiled to a `.cfg` and handed to dot-server's own
	# startup-config path, which runs after the console exists and before the listener
	# opens — the only window in which a FLAG_STARTUP_ONLY cvar is still settable.
	var generated := "%s/from_yaml.cfg" % _data_dir
	var written := config.write_cfg(generated)

	if not written.ok:
		_die(EXIT_CONFIG, str(written.error))
		return false

	config.server.startup_config = generated

	# [b]A `kind: pack` game needs a cloud client on the SERVER, not only on the
	# clients.[/b] `DotGameManager` fetches and mounts the new game's content itself
	# before it asks anybody else to — it has to, because the scene it loads is a path
	# inside the mount. Nothing here created one, so every pack game this tool
	# documents would have been refused with "delivered content and dot-cloud is not
	# installed". Before that refusal existed it was worse: the server told every
	# client to download, waited for them, and then failed to find its own scene.
	#
	# Added before boot() so the registration is in place before the game manager runs
	# its initial change.
	_build_cloud()

	var booted: DotResult = await server.boot()

	if not booted.ok:
		# "Already in use" is the common one and it is a *port* failure, not a
		# configuration one — a supervisor that treated it as a misconfiguration would
		# stop retrying, and the usual cause is the previous instance not having exited
		# yet, which retrying fixes.
		var why := str(booted.error).to_lower()
		var code := (
			EXIT_PORT
			if why.contains("bind") or why.contains("already in use")
				or why.contains("listening")
			else EXIT_CONFIG
		)
		_die(code, str(booted.error))
		return false

	var source := TmcAdmins.from(config.groups, config.users)

	if not source.ok:
		_die(EXIT_CONFIG, str(source.error))
		return false

	admins = source.value as TmcAdmins
	config.note_console_result(server.console)
	var added := server.admins.add_source(admins)

	if not added.ok:
		_die(EXIT_CONFIG, str(added.error))
		return false

	for descriptor in content.games:
		server.games.add_game(descriptor)

	var wanted := config.initial_game if config.initial_game != "" else content.default_game

	if wanted == "":
		# Legitimate, and said out loud. dot-server supports a server with no game and a
		# player who connects to one sees nothing, which is indistinguishable from a
		# broken server unless somebody says so.
		DotLog.warn(CHANNEL, "no game to load; the server will run empty", {
			"content": _content_dir,
		})
		return true

	if content.find(wanted) == null:
		_die(
			EXIT_CONTENT,
			"No game called '%s' in %s (have: %s)"
				% [wanted, _content_dir, ", ".join(content.ids())]
		)
		return false

	# Connected before the first change, so the boot load and every later `changelevel` take
	# exactly the same path. A separate "load the module for the game we booted into" step
	# is a second path that only the first game ever takes — and the family's own rule is
	# that a path only one shape reaches is a path nothing has run.
	server.games.game_loaded.connect(_on_game_loaded)

	var loaded: DotResult = await server.games.change_game(wanted, "boot")

	if not loaded.ok:
		_die(EXIT_CONTENT, str(loaded.error))
		return false

	if _module_failed:
		_die(EXIT_CONTENT, "The game loaded but its module did not. See the log above.")
		return false

	# After the first game is loaded, because the director has to be told what is
	# running — a vote system that starts on no game at all has no clock, nothing on
	# cooldown, and offers the game everybody is playing on its own first ballot.
	votes = TmcVote.install(self, server, config.vote, config.vote_exclude)

	# Last, and after the first game is loaded, because the first report goes out
	# immediately and a server reporting "no game" before it has one is a listing that
	# blinks on every restart.
	listing = TmcReport.install(
		self, server, content, "%s/listing.json" % _data_dir
	)

	return true


## Keeps the right module loaded as the game changes.
##
## [b]This is what makes a multi-game server a multi-game server.[/b] A game's server-side
## behaviour is a [DotModule], and dot-server does not load one: it changes the scene and
## tells whatever modules are already loaded. So without this, `changelevel` swaps the world
## and leaves the previous game's module driving it — or, from a lobby, leaves no module at
## all, which is a game whose netcode never ticks and whose players never join. Nothing
## errors either way.
##
## Three cases, and the middle one is the reason this compares paths rather than ids:
##
## - **A different module.** Unload the old one, load the new one. Unloading first, because
##   two modules holding a [DotNetManager] each would both tick the same world.
## - **The same module, a different game.** Hungry's classic and frenzy are two game ids
##   and one module, and it rebinds itself through [method DotModule._module_game_changed].
##   Reloading it would drop every connected player for no reason — which is exactly what
##   changing the game is supposed to avoid.
## - **No module.** A game that is only a scene is legitimate.
## Creates the content client a delivered game is fetched through.
##
## Config comes from a file rather than from YAML because the one setting that matters —
## `trusted_keys` — is refused from the environment and the command line on purpose:
## anything that can set a variable in this process would otherwise become a content
## publisher. `DotCloudConfig.sensitive_keys` is where that is decided.
func _build_cloud() -> void:
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = "%s/content_cache" % _data_dir
	cloud.config_file = "%s/content.json" % _config_dir
	# The content directory is searched before the network, so a pack sitting beside the
	# game that names it needs no web server at all — which is what a LAN deployment and
	# every test of this are.
	# `dist/` too, when there is one: it is where `./server pack` writes, so a server
	# that published a map is a server that has it, and asking the network for something
	# it produced itself would be absurd. Absent on a deployment that only consumes.
	var searched := PackedStringArray([content.root])
	var published := ProjectSettings.globalize_path("res://dist")

	if DirAccess.dir_exists_absolute(published):
		searched.append(published)

	cloud.local_search_dirs = searched
	# Same reasoning as `client/shell.gd`: the published layout carries no version
	# segment, and the default template asks for one.
	cloud.manifest_url_template = "{base}/{id}/manifest.json"
	server.add_child(cloud)


func _on_game_loaded(_content_key: String) -> void:
	if server == null or server.games == null:
		return

	var current := server.games.current()
	var wanted := ""

	if current != null:
		var descriptor := content.find(current.game_id)

		if descriptor != null:
			wanted = String(descriptor.metadata.get("module", ""))

	if wanted == _module_path:
		return

	if _module_name != "":
		var unloaded := server.modules.unload_module(_module_name)

		if not unloaded.ok:
			DotLog.warn(CHANNEL, "could not unload the previous game's module", {
				"module": _module_name, "error": str(unloaded.error),
			})

		_module_name = ""
		_module_path = ""

	if wanted == "":
		return

	var loaded := server.modules.load_module(wanted)

	if not loaded.ok:
		# Loud, and not fatal. The server is already running and players may already be on
		# it; refusing to continue would drop them because one game is broken, and the
		# operator can change back.
		DotLog.error(CHANNEL, "the game's module would not load", {
			"module": wanted, "error": str(loaded.error),
		})
		_module_failed = true
		return

	_module_failed = false
	_module_path = wanted
	_module_name = String((loaded.value as DotModule)._module_name())

	DotLog.info(CHANNEL, "module loaded for the current game", {
		"module": _module_name,
		"game": current.game_id if current != null else "",
	})

	# [b]The game's own cvars, now that the module owning them exists.[/b]
	# `DotGameManager` applies a descriptor's `cvars:` while the scene is up and the
	# module is not — it has to, because dot-server does not load a module for a game;
	# it changes the scene and tells whatever modules are already loaded, and tying one
	# module to one game is THIS host's policy. So a game.yml naming `sv_airaccelerate`,
	# which belongs to g2gfast's module and not to dot-server, was refused as unknown on
	# the first pass and had to be applied again here.
	#
	# Only when the module actually changed: the branch above returns early when it did
	# not, and in that case the first pass already found every cvar registered.
	server.games.reapply_descriptor_cvars()


## The lines an operator reads to find out whether it worked.
##
## [b]Every address, including a LAN one.[/b] "It says it started and my friend cannot
## connect" is almost always a bind address or a firewall, and the first thing that helps
## is knowing which address the server is actually on. dot-serve's README names this as one
## of the two things easy to leave out and painful to add later.
func _announce() -> void:
	var port := config.server.port
	var scheme := "ws"

	print("")
	print("  %s" % config.server.hostname)
	print("")

	for address in _addresses():
		print("  %s://%s:%d" % [scheme, address, port])

	if config.public_address != "":
		print("  %s://%s:%d   (public)" % [scheme, config.public_address, port])

	print("")
	print("  games   : %s" % ", ".join(content.ids()))
	print("  voting  : %s" % (
		"off" if votes == null
		else "%s, %s per game, !rtv at %d%%" % [
			votes.rules_summary(),
			votes.director.clock.formatted_remaining(),
			int(config.vote.rtv_fraction * 100.0),
		]
	))
	print("  rcon    : %s" % (
		"port %d" % config.server.effective_rcon_port()
		if config.server.rcon_password != "" else "off"
	))

	for line in config.unknown:
		print("  WARNING : unrecognised setting %s" % line)

	print("")


## Every address a client could reach this server on.
##
## The loopback is listed last: it is the one that always works and the one that never
## helps somebody else connect.
func _addresses() -> PackedStringArray:
	var out := PackedStringArray()

	if config.server.bind_address not in ["*", "0.0.0.0", ""]:
		out.append(config.server.bind_address)
		return out

	for address in IP.get_local_addresses():
		if address.contains(":"):
			continue  # IPv6; not what a friend pastes

		if address.begins_with("127."):
			continue

		out.append(address)

	out.append("127.0.0.1")
	return out


func _die(code: int, why: String) -> void:
	printerr("")
	printerr("  %s" % why)
	printerr("")
	get_tree().quit(code)


static func _value(args: PackedStringArray, flag: String, fallback: String) -> String:
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else fallback
