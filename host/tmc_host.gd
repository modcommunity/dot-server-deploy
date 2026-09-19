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

## The query responder. Answers A2S and DQP; see dot-server-query.
var query_host: DotQueryHost = null

## The sink layer, when `log_router` is not `off`. See [method _build_logging].
var log_router: DotLogRouter = null

## The guard. Built for every server, and it ships in dry run.
var guard: DotSecurityManager = null

## The detectors, reporting into the same guard.
var anticheat: DotAntiCheat = null

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

	var scanned := TmcContent.scan(_content_dir, config.games_allow)

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
		if not _selftest_operator_surface():
			server.shutdown("selftest failed")
			get_tree().quit(EXIT_CONFIG)
			return

		server.shutdown("selftest complete")
		print("")
		print("selftest ok")
		get_tree().quit(EXIT_OK)


## The operator's console, asserted on a REAL server rather than on a fixture.
##
## [b]Both of these were installed addons that reached no console at all.[/b] dot-log's
## command object could only be plugged into a client console until dot-server grew
## `DotConsole.add_source`, and the guard was in the dependency list and instantiated
## nowhere — so a server admin had neither `log tail` nor `sec_status`, and nothing
## anywhere could report their absence because an absent command is an absent command.
##
## Checked here and not in `examples/selftest.tscn` because a fixture has no console: what
## is being asserted is that these names are on the console of a server that actually
## booted, which is the only place the mistake could have happened.
func _selftest_operator_surface() -> bool:
	var expected := PackedStringArray(["status", "sec_status", "sec_why"])

	if log_router != null:
		expected.append("log")

	var missing := PackedStringArray()

	for name in expected:
		if server.console.find_command(name) == null:
			missing.append(name)

	if not missing.is_empty():
		printerr(
			"selftest FAILED: the console is missing %s"
			% " ".join(Array(missing))
		)
		return false

	if log_router != null and not log_router.is_started():
		printerr("selftest FAILED: the log router was built and never started")
		return false

	return true


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

	var scanned := TmcContent.scan(_content_dir, config.games_allow)

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

	# [b]The set this server offers, as one comma-separated argument.[/b] It is one
	# argument rather than a repeated flag because the thing on the other end of it is a
	# panel text box and a unit file's `Environment=`, neither of which can repeat a flag
	# -- TMC_GAMES reaches here through `server` exactly as TMC_GAME reaches the line
	# above it.
	#
	# REPLACES the YAML rather than adding to it, like every other override here: a list
	# that could only grow is a list an operator cannot use to narrow a box that already
	# has a `games:` key, which is the case it exists for.
	var offered := _value(args, "--games", "")

	if offered != "":
		# [b]Through TmcGameRef, because the same string also names things to FETCH.[/b]
		# `TMC_GAMES` may say `gamemann/game-g2gfast01@1.2.0`, which installs into
		# `content/game-g2gfast01/` -- so a filter that compared the raw entry against a
		# directory name would find nothing, report the game as missing, and offer none
		# of it on a server that had just downloaded it.
		config.games_allow = TmcGameRef.dirs_in(offered)

	# [b]Where content comes from, as an argument, for the same reason the list of games
	# is one.[/b] A panel operator has a text box and no shell; `cfg/server.yml` is
	# written by setup.sh and is not theirs to edit. It replaces the file's list rather
	# than adding to it: a deployment pointing at its own mirror must be able to say "not
	# the public origin", which an additive flag cannot express.
	#
	# The clients are told the same thing in the same breath. `content_urls` in the YAML
	# does this a few lines into TmcConfig for the reason written there -- two settings
	# for one fact is this tree's most repeated bug -- and an override that changed only
	# the server's half would send every client to the origin this box was just told not
	# to use.
	var urls := _value(args, "--content-url", "")

	if urls != "":
		var origins := PackedStringArray()

		for entry in urls.split(",", false):
			var url := entry.strip_edges()

			if url != "" and not url in origins:
				origins.append(url)

		config.content_urls = origins

		if "content_base_urls" in config.server:
			config.server.content_base_urls = origins

	# [b]Two spellings, and the second one is the reason this exists.[/b] `--map` is
	# the flag `server` and TMC_MAP hand down, matching `--game` beside it; `+map` is
	# what the fingers of anybody who has run a dedicated server type, and what
	# dot-server's own command-line documentation has used as its example all along.
	#
	# `+map` reaches here rather than the console on purpose. DotConsole runs the
	# `+command` half after the listener opens — which is still BEFORE this host has
	# loaded a game, so the `map` command the statement is looking for belongs to a
	# module that does not exist yet. It was parsed, dispatched, found nothing, and
	# returned a DotResult nobody read: the server booted on the game's default map
	# and said nothing about the argument it had just thrown away.
	#
	# `--map` wins a disagreement because it is the explicit one, and because it is
	# the one a unit file sets through TMC_MAP where a typo is expensive to find.
	var map_id := _value(args, "--map", _value(args, "+map", ""))

	if map_id != "":
		config.initial_map = map_id

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

	# [b]Before the server exists, because the first line this boot emits is the
	# interesting one.[/b] The router registers itself as a DotLog sink when it enters the
	# tree, so anything built after it is covered and anything built before it is not --
	# and what a server admin most wants out of a log is the reason the boot went wrong.
	_build_logging()

	server = DotServer.new()
	server.name = "Server"
	server.config = config.server
	server.config_file = ""
	server.auto_boot = false

	if log_router != null:
		# dot-server duck-types this: a `DotLogSink` for a rotating file or a dot-log
		# router for the whole sink layer, recognised by what it can do rather than by
		# what it is called. Pointed at the router, it does not make a second file writer.
		server.log_sink_ref = DotNodeRef.of_path(NodePath("../DotLogRouter"))
	# Both config slots are named absolutely, so dot-server's search path cannot reach the
	# `server.cfg` and `autoexec.cfg` its own addon ships. Those are correct defaults for a
	# deployment configured with `.cfg` files and wrong for one that has chosen YAML: they
	# would run after the operator's settings and silently override them. `cfg/autoexec.cfg`
	# is still honoured, and still runs after the listener opens, because that is where
	# something dot-server has and this format does not belongs.
	config.server.autoexec_config = "%s/autoexec.cfg" % _config_dir
	add_child(server)

	# Queries are their own addon now, and a server only answers them if a host is
	# plugged in. `a2s_enabled: true` ships in cfg/server.yml and TMC's own scanner
	# speaks A2S, so a deployment without this is one that quietly drops off every
	# listing it is on.
	query_host = DotQueryHost.new()
	query_host.name = "QueryHost"
	query_host.app_url = config.app_url
	query_host.server_ref = DotNodeRef.of_path(NodePath("../Server"))
	add_child(query_host)

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

	# [b]Before boot() for a second reason: the challenge.[/b] `DotServer` answers a
	# connecting client with the strategy it wants, and it works that out by asking the
	# registry for `dot_auth_server` -- so an auth server registered after the listener
	# opens is one that every client already in flight was told did not exist.
	if not _build_auth():
		return false

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

	# After boot, because both of these want a console to register on and the guard wants
	# a running server to attach to. Neither is fatal: a server with no guard is a server,
	# and one whose log command failed to register still logs.
	_register_log_commands()
	_build_security()

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

	# Before the vote, because the vote's clock and its play history are about to be
	# told what is running and this is what is running.
	await _apply_initial_map()

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
## Builds the auth server `cfg/auth.yml` asks for. False means the file is wrong.
##
## A configuration error is fatal rather than a warning, and that is the whole point of
## it: every other outcome here leaves the server running with everybody as a guest, which
## is exactly what a misconfigured `auth.yml` looks like from the outside. An operator who
## has written one wants to be told it is broken, not to discover months later that their
## admins were never admins.
## Builds the sink layer, when the configuration asks for one.
##
## [b]dot-log was in this project's dependency list and instantiated nowhere.[/b] `cfg/log.yml`
## has documented a level, per-channel levels, a mirror threshold and five file settings
## since it was written, and every one of them reached dot-core's own `DotLogSink` -- which
## writes a file and nothing else. Syslog, a hosted collector, a SQL table, redaction,
## flood gating and the in-memory ring behind `log tail` were all installed, all
## configured-for, and all unreachable.
##
## Not fatal, ever. A collector that cannot be reached is a reason to look at the
## configuration, not a reason for a server full of people to stop.
func _build_logging() -> void:
	log_router = config.build_log_router()

	if log_router == null:
		return

	log_router.name = "DotLogRouter"
	# The router is what applies the levels from here on. `DotServer._apply_log_levels`
	# does it again during boot with the same values out of the same config, which is
	# idempotent and stays because a server with `log_router: off` still needs it.
	add_child(log_router)

	DotLog.debug(CHANNEL, "the sink layer is up", log_router.describe())


## Puts `log` on the console.
##
## [b]dot-log ships a console object and, until dot-server grew `add_source`, it could only
## be plugged into a CLIENT console.[/b] The one kind of process with a log worth tailing is
## the one kind that could not reach it. `DotConsole.add_source` wraps each name a
## duck-typed source claims in a real `DotConCommand`, so `log` gets the permission check,
## the RCON gate and the audit line like everything else.
##
## GENERIC, not root: reading back what the server has been saying is what being staff is
## for, and `log test` is the only thing here that writes anything at all.
func _register_log_commands() -> void:
	if server == null or server.console == null:
		return

	var source := DotLogCommands.new(log_router)
	var registered := server.console.add_source(source, DotAdminFlags.GENERIC)

	DotLog.result(CHANNEL, "the log console commands", registered, DotLog.Level.WARN)


## Builds the guard, its watchers and the detectors.
##
## [b]This addon was in the dependency list and instantiated nowhere either.[/b] It ships in
## dry run -- every rule evaluates, every trip is logged and ledgered marked WOULD, and
## nobody is punished -- which is what makes building it for every server the right default
## rather than an imposition: an operator reads `sec_status` for a week and then decides.
##
## [b]Nothing here is fatal.[/b] A server with no guard is a server that runs; one that
## refused to boot because a rules file was unreadable costs the players what they came
## for over a permissions mistake.
func _build_security() -> void:
	if server == null:
		return

	if not config.security.enabled:
		DotLog.info(CHANNEL, "the security guard is off in cfg/security.yml")
		return

	guard = DotSecurityManager.new()
	guard.name = "Security"
	guard.config = config.security
	# The YAML is the layer. A second file under `user://cfg/` would be a second place a
	# setting can come from with no order written down between them, which is exactly what
	# `DotConfig`'s layering exists to avoid.
	guard.config_file = ""
	# [b]`".."`, not `"../Server"`.[/b] The guard is a CHILD of the server, so `..` already
	# IS the server; `../Server` asks the server for a child of its own called Server,
	# finds nothing, and the guard reports "A security manager needs a server" and then
	# watches nothing at all for the life of the process. The two watchers below are the
	# other shape and correctly say `../Security`, because they are siblings of the guard.
	guard.server_ref = DotNodeRef.of_path(NodePath(".."))
	server.add_child(guard)

	# One node rather than five. Every source it watches is optional and every one it
	# cannot find simply does nothing, so a deployment without dot-chat loses the router
	# half and keeps dot-server's own chat path.
	var watch := DotSecurityWatch.new()
	watch.name = "SecurityWatch"
	watch.guard_ref = DotNodeRef.of_path(NodePath("../Security"))
	server.add_child(watch)

	if config.anticheat.enabled:
		anticheat = DotAntiCheat.new()
		anticheat.name = "AntiCheat"
		anticheat.config = config.anticheat
		anticheat.config_file = ""
		anticheat.guard_ref = DotNodeRef.of_path(NodePath("../Security"))
		server.add_child(anticheat)

	# The console commands are NOT registered here: `DotSecurityManager.attach()` does it
	# itself, and a second `DotSecurityCommands.register` produces thirteen "command
	# registered twice" warnings and two for the cvars -- every one of which is the console
	# correctly keeping the first registration and telling somebody about the second.

	DotLog.info(
		CHANNEL,
		"the security guard is watching",
		{
			"dry_run": guard.is_dry_run(),
			"anticheat": anticheat != null,
		}
	)


func _build_auth() -> bool:
	var built := TmcAuth.build(config.auth, _config_dir)

	if not built.ok:
		_die(EXIT_CONFIG, str(built.error))
		return false

	var node: Node = built.value

	if node != null:
		server.add_child(node)

	return true


func _build_cloud() -> void:
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = "%s/content_cache" % _data_dir
	# [b]Falls back to the tracked defaults when the deployment has no answer of its
	# own.[/b] `cfg/content.json` is GENERATED from `client/content.json` by setup.sh, so
	# it exists on a real install and on nothing else -- and with every game delivered, a
	# config directory without it is a server that can mount no game at all. It failed
	# with "require_signed_manifests is on but no trusted_keys are configured", which is
	# true, unhelpful, and names a file the operator never wrote.
	#
	# `client/content.json` is the shipped default and is in this repository on purpose:
	# it holds the PUBLIC half of the signing key, which is not a secret and is the same
	# for every deployment that trusts our packs. A deployment that trusts a different
	# publisher writes `cfg/content.json` and this never looks.
	cloud.config_file = "%s/content.json" % _config_dir

	if not FileAccess.file_exists(cloud.config_file):
		cloud.config_file = "res://client/content.json"
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

	# [b]And the manifests `install-games` kept, which is what makes a restart survive an
	# origin outage.[/b] dot-cloud resolves a manifest before it looks at what the store
	# already holds, and a manifest is fetched over the network every time -- so a server
	# with every byte of a pack on its disk still refused to boot while the content origin
	# was down. Measured: exit 7, `Could not download the content manifest`, on a box
	# holding all 212 files of the game it was being asked to start.
	#
	# Searched, not trusted: a manifest found here goes through the same signature check
	# as one off the wire, because it is the same code path -- these directories are
	# tried before the URLs and are otherwise nothing special.
	var manifests := "%s/manifests" % _data_dir

	if DirAccess.dir_exists_absolute(manifests):
		searched.append(manifests)

	cloud.local_search_dirs = searched

	# [b]Where to fetch content this box does not have.[/b] Without this the client
	# could only ever find a pack already on disk -- the comment above says "the content
	# directory is searched before the network", and there was no network half at all.
	#
	# What that cost: `maps/imported/` is gitignored in game-g2gfast, so a server stood
	# up by cloning the repositories has the game and none of its 66 MB of maps. It boots,
	# loads g2gfast, and dies on its own default map with "No such map in the catalogue"
	# -- while all eight of those maps sit published and reachable on the content origin,
	# which is exactly what dot-cloud is for. The browser client had the base URL and the
	# server did not, so a player could download a map the server could not.
	#
	# A list, and searched in order, because a LAN deployment mirrors the packs somewhere
	# of its own and should not reach the internet to find them.
	cloud.http_base_urls = config.content_urls

	if config.content_urls.is_empty():
		DotLog.info(CHANNEL, "no content urls; this server can only use content it already has", {
			"searched": searched,
			"hint": "set content_urls in cfg/server.yml to fetch maps and packs",
		})

	# [b]The published layout is `{id}/{version}/`, and that is dot-cloud's own default.[/b]
	# This used to override it to a flat `{id}/manifest.json`, which was right when the
	# only origin was this project's own `dist/` and every pack had one version in it.
	# The site publishes `content/<owner>/<name>/<version>/manifest.json` -- a member may
	# have four versions of one game up at once -- so the versioned shape is the primary
	# one now.
	#
	# The flat form stays as a FALLBACK because an origin holds both: eight imported map
	# packs were published under it and are still the maps a game asks for by name.
	# Re-publishing everything in existence is not a precondition for this server starting.
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])

	# [b]Say what a download is doing, on the console an operator is watching.[/b] A
	# server fetching a 15 MB map printed one line when it started and nothing again
	# until it finished or failed -- which on a slow link is indistinguishable from a
	# hang, and the operator's only recourse is to kill a transfer that was working.
	#
	# Throttled to a line a second rather than forwarded raw: `progress_changed` fires
	# per chunk, and a server log is read afterwards as often as it is watched live. A
	# spinner is for a loading screen; this is for a file somebody greps.
	cloud.progress_changed.connect(_on_content_progress)
	cloud.content_ready.connect(_on_content_ready)

	server.add_child(cloud)


## Last time a content-progress line was printed, in milliseconds.
var _progress_said_ms: int = 0

## How often progress is printed while content downloads.
const PROGRESS_EVERY_MS := 1000


func _on_content_progress(progress: Dictionary) -> void:
	var now := Time.get_ticks_msec()

	# The last line always lands, whatever the throttle says: "94%" as the final word
	# on a finished download reads as a download that stopped.
	var fraction := float(progress.get("fraction", 0.0))
	var finishing := fraction >= 1.0

	if not finishing and now - _progress_said_ms < PROGRESS_EVERY_MS:
		return

	_progress_said_ms = now

	DotLog.info(CHANNEL, "downloading content", {
		"percent": "%d%%" % int(round(fraction * 100.0)),
		"files": "%d/%d" % [
			int(progress.get("done_files", 0)), int(progress.get("total_files", 0))
		],
		"bytes": "%s / %s" % [
			DotPaths.format_bytes(int(progress.get("done_bytes", 0))),
			DotPaths.format_bytes(int(progress.get("total_bytes", 0))),
		],
	})


func _on_content_ready(manifest: DotCloudManifest, mount_prefix: String) -> void:
	if manifest == null:
		return

	DotLog.info(CHANNEL, "content ready", {
		"content": manifest.key(),
		"at": mount_prefix,
	})


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

	# Awaited, because a game module's `_module_load` is a coroutine: it builds an
	# identity layer that reaches a content host and a profile store. Un-awaited, this
	# returned at the first suspension and the check below read `.ok` off null -- so a
	# server whose backbone was slow failed to load its game and said "Trying to call an
	# async function without 'await'".
	var loaded: DotResult = await server.modules.load_module(wanted)

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


## Puts the boot on `sv_map` / `--map` / `+map`, once the game that owns it is up.
##
## [b]After the game rather than instead of it, and that is not free.[/b] A game's map
## session is built by the game's own scene and reads the game's own config, so the
## first map is chosen and loaded before anything in this host can say otherwise. The
## honest consequence is that a server given `+map` loads two maps at boot and the
## game's own default is briefly the current one. The alternative — reaching into a
## scene that has not been instantiated yet to change a value it is about to read — is
## the kind of thing that works until a game builds its session somewhere else.
##
## Nothing here is fatal. A game with no maps, and a map that is not in the catalogue,
## are both an operator's typo on a server that is otherwise up and full of people.
func _apply_initial_map() -> void:
	if config.initial_map == "":
		return

	var session := _find_map_session(server.games)

	if session == null:
		DotLog.warn(CHANNEL, "a map was asked for and this game has no maps", {
			"map": config.initial_map,
			"game": server.games.current_content_id(),
			"why": "not every game has a catalogue; a lobby and a built arena do not",
		})
		return

	# [b]Fetch it before asking for it.[/b] `change_to` refuses an id the catalogue does
	# not hold, and a catalogue only holds what is on disk -- so a delivered map is
	# refused here rather than downloaded, and the refusal reads as an operator's typo.
	# `G2GGame.change_map` has had this fetch since it was written, with a comment
	# saying why it must come first; this path does not go through it, so it needed its
	# own. A game that fetches its own content sees a mount that is already there and
	# does nothing twice.
	await _ensure_map_content(StringName(config.initial_map), server.games)

	var changed: Variant = await session.call("change_to", StringName(config.initial_map))

	if changed is DotResult and not (changed as DotResult).ok:
		DotLog.error(CHANNEL, "could not start on the map that was asked for", {
			"map": config.initial_map,
			"why": (changed as DotResult).error.message,
		})
		return

	DotLog.info(CHANNEL, "starting on the map that was asked for", {
		"map": config.initial_map,
	})


## Download the content a map lives in, if this deployment can and does not have it.
##
## [b]The map id IS the content id.[/b] That is the convention the publisher already
## follows -- `dist/surf_mesa/` holds a manifest naming `surf_mesa` -- and inventing a
## second registry to say so would be a third place to keep in step.
##
## Every outcome here is non-fatal. No cloud client, no content urls, a pack that is
## already mounted, a map that ships in the build: all of them mean "carry on", and the
## refusal that follows from `change_to` is the better message anyway because it names
## the map.
func _ensure_map_content(id: StringName, root: Node = null) -> void:
	if id == &"":
		return

	# [b]Through the game's own fetch when it has one, because mounting is only half.[/b]
	# A delivered map has to be ADDED to the catalogue as well: a catalogue holds what was
	# on disk when the game booted, and a pack mounted a moment ago is not in it. This
	# host did the mount and not the registration, so every delivered map named by `+map`
	# was downloaded, verified, mounted -- and then refused by `change_to` with "No such
	# map in the catalogue", after which the server booted on the game's own default.
	# It read as an operator's typo about a map that was sitting in the cache.
	#
	# It looked like it worked because g2gfast's own `initial_map` default IS `surf_mesa`,
	# so the map the operator asked for was already the one the game was loading; asking
	# for any other map is what showed it.
	#
	# Duck-typed on the method rather than the type, for the reason `_find_map_session`
	# gives: this host names no game's class. A game that fetches and registers its own
	# map content answers `ensure_map_content`; one that does not falls through to the
	# mount below, which is still right for a game whose catalogue is already complete.
	var fetcher := _find_map_fetcher(root)

	if fetcher != null:
		var registered: Variant = await fetcher.call("ensure_map_content", id)

		if registered is DotResult and not (registered as DotResult).ok:
			# Info for the same reason the cloud path below is: `change_to` is about to
			# refuse the id with a message that names the map, and that is the better
			# line to read.
			DotLog.info(CHANNEL, "the game could not fetch this map; using what is here", {
				"map": String(id),
				"why": (registered as DotResult).error.message,
			})

		return

	var cloud := DotRegistry.get_service(&"dot_cloud_client")

	if cloud == null or not cloud.has_method("ensure"):
		return

	var got: Variant = await cloud.call("ensure", id)

	if got is DotResult and not (got as DotResult).ok:
		# Info, not a warning: a map that ships in the build is not in dot-cloud and
		# never will be, so this is the ordinary answer for most servers.
		DotLog.info(CHANNEL, "no delivered content for this map; using what is here", {
			"map": String(id),
			"why": (got as DotResult).error.message,
		})


## The running game, if it fetches and registers its own map content.
##
## Duck-typed and walked the same way as [method _find_map_session], and for the same
## reason: the game is a scene this host loaded from a pack, not a type it may name.
## `ensure_map_content` is the half `change_to` cannot do for itself -- see
## [method _ensure_map_content].
static func _find_map_fetcher(root: Node) -> Object:
	if root == null:
		return null

	for child in root.get_children():
		if child.has_method("ensure_map_content"):
			return child

		var found := _find_map_fetcher(child)

		if found != null:
			return found

	return null


## The loaded game's map session, or null.
##
## [b]Duck-typed, like everything else that crosses into a game.[/b] `has_method` and
## `call` rather than `is DotMapSession`: this host has no business requiring that a
## game use dot-map, and a game with a session of its own that answers `change_to` is
## as much of a map session as this needs. It is the same contract dot-vote's map
## source has always used for the same reason.
static func _find_map_session(root: Node) -> Object:
	if root == null:
		return null

	for child in root.get_children():
		if child.has_method("change_to") and child.has_method("change_to_map"):
			return child

		var found := _find_map_session(child)

		if found != null:
			return found

	return null


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
		else "%s, %s per game, !%srtv at %d%%" % [
			votes.rules_summary(),
			votes.director.clock.formatted_remaining(),
			TmcVote.COMMAND_PREFIX,
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
