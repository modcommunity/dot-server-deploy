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

## `/admin`, or null when `admin_menu.yml` turns it off.
var admin_menu: TmcAdminMenu = null

## The loading screen players see on a game or map change, from `loading.yml`.
var loading: TmcLoading = null

## Reports this server's own state to its site listing. Never null; it reports nothing
## when there is no token, which is every LAN deployment and every test.
var listing: TmcReport = null

## The auth server cfg/auth.yml asked for, or null.
var auth: DotAuthServer = null

## Parties, the booking this server keeps, party chat and the optional queue. Built for
## every game, like the guard. See [TmcParty].
var parties: TmcParty = null

## The last minute of the server, for `replay save` and for the evidence a kick or a ban
## files. Built for every game, like the guard; null when `replay.yml` turns it off. See
## [TmcReplay].
var replay: TmcReplay = null

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

## Whether this boot asks the site for a credential when it has none ([TmcEnroll]).
##
## Off unless the command line booted it: a suite embeds this host through [method start]
## with a fixture `data/` that has no token, and sixteen suites each asking the real site
## who they are would be sixteen requests from CI to production per run. A real server is
## always `_run`, which turns it on (except for `--selftest`, which is a check, not a
## server anybody joins).
var enroll_with_site := false

## Every script error the engine logs during a selftest; null on a normal run. See
## [TmcScriptWatch] for why the check cannot trust its own exit path without it.
var _script_watch: TmcScriptWatch = null

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
	enroll_with_site = not _selftest

	if _selftest:
		# First, before anything that could load a script: a parse error logged before
		# the watch exists is a parse error the check never hears about.
		_script_watch = TmcScriptWatch.new()
		OS.add_logger(_script_watch)

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

	var overrides := _apply_game_config()

	if not overrides.ok:
		_die(EXIT_CONTENT, str(overrides.error))
		return

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

		# After the shutdown, because tearing a game down runs its scripts too.
		if not _selftest_scripts_loaded():
			get_tree().quit(EXIT_CONTENT)
			return

		print("")
		print("selftest ok")
		get_tree().quit(EXIT_OK)


## Whether every script this boot touched compiled and loaded.
##
## [b]`selftest ok` used to be printed over a module that never compiled.[/b] A script
## that fails to parse is logged and handed back uninstantiable, and every step after it
## can still succeed: the scene loads with the node's script missing, the host's module
## load throws inside a coroutine and returns nothing, and the boot carries on to the end.
## The only record is the engine's log, so that is what is read.
func _selftest_scripts_loaded() -> bool:
	if _script_watch == null or _script_watch.count() == 0:
		return true

	printerr("")
	printerr(
		"selftest FAILED: %d script error(s) while booting; the first:"
		% _script_watch.count()
	)

	for line in _script_watch.lines():
		printerr("  %s" % line)

	printerr("  A missing base class is usually an addon setup.sh did not link or vendor.")
	return false


func _exit_tree() -> void:
	if _script_watch != null:
		OS.remove_logger(_script_watch)
		_script_watch = null


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
	var expected := PackedStringArray(["status", "sec_status", "sec_why", "party_status", "mm_status"])

	if log_router != null:
		expected.append("log")

	if config.replay_enabled:
		expected.append("replay")

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

	# [b]The build the site frames for this server, as the query will report it.[/b] A
	# cvar without NOTIFY is not in the rules, and the site would then frame the shared
	# shell for a server running other addons — a game that will not load, and nothing on
	# this side that could see why.
	var named := FileAccess.get_file_as_string(WEB_BUILD_FILE).strip_edges() \
		if FileAccess.file_exists(WEB_BUILD_FILE) else ""

	if named != "":
		var reported := server.console.find_cvar("sv_web_build")

		if reported == null or reported.get_string() != named \
				or not reported.has_flag(DotConVar.FLAG_NOTIFY):
			printerr("selftest FAILED: sv_web_build does not report %s to the query" % named)
			return false

		print("sv_web_build: %s" % named)

	# [b]The addon versions a joining client is told about.[/b] Empty on a box with a lock
	# means every player keeps the addons their shell was exported with, however old -- the
	# thing this list exists to stop, and invisible from here unless asked.
	# Through `get`, not the property: a box's dot-server may predate it, and a typed access
	# would stop this whole script compiling there rather than skip one check.
	var announced: Variant = server.get("addon_set")

	if announced is Array and OS.get_environment("TMC_ADDONS_LOCK") != "off" \
			and FileAccess.file_exists(ADDONS_LOCK):
		if (announced as Array).is_empty():
			printerr("selftest FAILED: %s names addons and none are advertised to clients" % ADDONS_LOCK)
			return false

		for entry in announced:
			if str(entry.get("dir", "")) == "dot_server" and str(entry.get("id", "")) != "modcommunity/dot-server":
				printerr("selftest FAILED: dot_server is advertised as %s" % str(entry.get("id", "")))
				return false

		print("addons advertised: %d" % (announced as Array).size())

	# Registered ALWAYS, empty or not, so an operator can move a running server with rcon.
	# A cvar that only exists when the config named a version is one `sv_web_loader x`
	# answers "unknown command" to on every server that has not needed it yet.
	var loader := server.console.find_cvar("sv_web_loader")

	if loader == null or not loader.has_flag(DotConVar.FLAG_NOTIFY):
		printerr("selftest FAILED: sv_web_loader is not a NOTIFY cvar the query reports")
		return false

	if loader.get_string() != _web_loader_value():
		printerr("selftest FAILED: sv_web_loader reports %s, the configuration says %s" % [
			loader.get_string(), _web_loader_value(),
		])
		return false

	print("sv_web_loader: %s" % (loader.get_string() if loader.get_string() != "" else "(site default)"))

	# [b]Asked, not only looked up.[/b] A command that is registered and answers nothing
	# is the same absent command one layer down. `party_status` prints what was built,
	# and a booking with nobody behind it is the one thing it must always be able to say.
	# An Array rather than a PackedStringArray: a lambda captures by value, and only a
	# container's contents survive the copy (docs/gdscript-hazards.md).
	var answered: Array = []
	var asking := DotCmdContext.internal("party_status", PackedStringArray())
	asking.reply_sink = func(line: String) -> void: answered.append(line)

	var said := server.console.execute("party_status", asking)

	if not said.ok or answered.is_empty():
		printerr("selftest FAILED: party_status did not answer (%s)" % str(said.error))
		return false

	if config.party_enabled and (parties == null or parties.reservations == null):
		printerr("selftest FAILED: cfg/party.yml asked for parties and none were built")
		return false

	for line in answered:
		print("party_status: %s" % line)

	# [b]The ring, recording on the server that booted.[/b] dot-replay was the other addon
	# linked here and built nowhere; an absent `replay` command is caught above, and a ring
	# that was built and never started is the same failure one layer down.
	if config.replay_enabled and (replay == null or not replay.recorder.is_recording()):
		printerr("selftest FAILED: cfg/replay.yml asked for the replay ring and it is not recording")
		return false

	if replay != null:
		for line in replay.describe_lines():
			print("replay: %s" % line)

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

	var overrides := _apply_game_config()

	if not overrides.ok:
		return overrides

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

	# [b]The other three ports, and the interface the query listener binds.[/b]
	#
	# All four are derivable and all four are derived WRONG on a panel. RCON defaults to
	# the game port plus one, and both query ports default to the game port itself --
	# which is right on a box where you choose the numbers, and is not how Pterodactyl
	# works: it hands a server the allocations it was given, which are whatever was free
	# on that node. A server that assumes `port + 1` on a machine where `port + 1`
	# belongs to somebody else does not fail cleanly, it fails as "address in use" on a
	# port nobody configured.
	#
	# Not secrets, so argv is fine -- unlike `--rcon-password` below, which is refused.
	# A port number is visible in `ss -ltn` to anybody who can read argv anyway.
	var rcon_port := _value(args, "--rcon-port", "")

	if rcon_port != "":
		config.server.rcon_port = rcon_port.to_int()

	# A2S first, because `query_port` DERIVES FROM IT: dot-server's
	# `effective_query_port()` falls back to `effective_a2s_port()`, so setting only
	# `--a2s-port` moves both onto one socket -- which is the arrangement the two
	# protocols are designed for, told apart by their first four bytes. Setting
	# `--query-port` as well is how you split them.
	var a2s_port := _value(args, "--a2s-port", "")

	if a2s_port != "":
		config.server.a2s_port = a2s_port.to_int()

	var query_port := _value(args, "--query-port", "")

	if query_port != "":
		config.server.query_port = query_port.to_int()

	# [b]The one setting a reverse-proxied server cannot do without.[/b] nginx forwards
	# the game's WebSocket and CANNOT forward UDP, so with `--bind` on loopback the
	# query listener binds where no tracker on earth can reach it -- and a tracker
	# cannot tell that from a server that is down. `*` puts the query port, and only
	# the query port, on every interface. RCON deliberately does not follow it.
	var query_bind := _value(args, "--query-bind", "")

	if query_bind != "":
		config.server.query_bind_address = query_bind

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

	# Same two spellings as `--map`, for the same reason: `+sv_web_loader` would otherwise go
	# to the console, which runs it before this host has registered the cvar.
	var web_loader := _value(args, "--web-loader", _value(args, "+sv_web_loader", ""))

	if web_loader != "":
		config.web_loader = web_loader

	for flag in ["--rcon-password", "--password"]:
		if flag in args:
			DotLog.warn(CHANNEL, "a secret on the command line is refused", {
				"flag": flag,
				"why": "argv is readable by other processes; put it in cfg/server.yml",
			})


## The owner's per-game settings from `cfg/content.yml` -- cvars, metadata, player
## counts, maps -- laid over each game's own `game.yml` before anything reads a
## descriptor. Here rather than in TmcContent.scan because the scan knows a content
## directory and nothing about cfg/ or data/; see TmcGameConfig.
func _apply_game_config() -> DotResult:
	var loaded := TmcGameConfig.load_from(_config_dir, _absolute(_data_dir))

	if not loaded.ok:
		return loaded

	var overrides := loaded.value as TmcGameConfig
	overrides.apply_all(content)

	for line in overrides.warnings:
		DotLog.warn(CHANNEL, line)

	return DotResult.success(overrides)


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

	# Before boot() too: the list rides the signon challenge, and the first client can
	# arrive the moment the listener opens.
	_advertise_addons()

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
	_register_web_build()
	_register_web_loader()
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

	# [b]Before the first game, because the game's identity layer needs the credential.[/b]
	# `DotPlatformIdentity` finds the integration client as `dot_backbone_client` while
	# the game's module loads, and reads players' avatars from the site through it; built
	# after, every game this server booted into kept avatars in a local file the site
	# never sees. The auth server gets it here too, which closes the window in which a
	# signed-in join is refused. Nothing is reported early: reports are on the client's
	# timer, whose first tick is an interval away, by which time the game is loaded.
	# [b]And the credential is asked for first, when there is none.[/b] A box nobody put a
	# token on proves to the site that it is the server at its listed address and is
	# issued one (see [TmcEnroll]). Awaited, bounded, because everything below reads it.
	var listing_path := "%s/listing.json" % _data_dir
	var enroll: TmcEnroll = null

	if enroll_with_site:
		enroll = await TmcEnroll.at_boot(
			self, server, listing_path,
			auth.config.backbone_url if auth != null and auth.config != null else DotAuthConfig.new().backbone_url,
			config.public_address
		)

	if enroll != null and not enroll.done:
		enroll.enrolled.connect(_on_enrolled_late.bind(listing_path), CONNECT_ONE_SHOT)

	listing = TmcReport.install(self, server, content, listing_path)

	_hand_backbone_to_auth()

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

	# [b]After the listing, because the listing is where the backbone client is.[/b] A
	# party is reported over the same integration credential the listing uses, and a
	# second client for the same token would be two rate limiters for one budget. With no
	# token there is no client, parties are not reported, and bookings still come from the
	# console -- the same "never fatal" as the guard above.
	#
	# After the first game, too: the booking chains onto `dot_ban_source`, and the game's
	# module is what registers dot-moderation there. Built before it, the booking would be
	# displaced the moment the module loaded.
	parties = TmcParty.install(
		self, server, config,
		listing.backbone if listing != null else null,
		_data_dir
	)

	# After the first game, so the first header names a game and the first keyframe has a
	# roster to hold; before any player can be kicked, which is what it is for. It watches
	# the registry for each game's dot-moderation itself, so it does not have to be built
	# before the module that registers one.
	replay = TmcReplay.install(self, server, config, _data_dir)

	# After the first game, so the menu's first look at the console sees the game's own
	# commands -- though it looks again on every page, which is what keeps it right across
	# a changelevel. `warn` is registered here only if nothing before it took the name.
	var map_session := func() -> Object:
		return _find_map_session(server.games)

	admin_menu = TmcAdminMenu.install(self, server, config.admin_menu, map_session)

	# After the first game too: it watches that game's map session for per-map screens.
	var reread := func() -> DotResult:
		var path := "%s/loading.yml" % _config_dir
		if not FileAccess.file_exists(path):
			return DotResult.success({})
		return TmcYaml.parse_file(path)

	loading = TmcLoading.install(self, server, config.loading, reread, map_session)

	return true


## Keeps the right module loaded as the game changes.
##
## [b]This is what makes a multi-game server a multi-game server.[/b] A game's server-side
## behaviour is a [DotModule], and dot-server does not load one: it changes the scene and
## tells whatever modules are already loaded. So without this, `changelevel` swaps the world
## and leaves the previous game's module driving it — or, from a game with no module of its own, leaves no module at
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


## Gives scoped introspection the listing's integration client. See [TmcAuth].
##
## The same client and so the same token and rate limiter: the site resolves the scope
## from that credential, so a second client on another token would mint keys in another
## scope. Without one, an introspecting server can admit nobody signed in, and says so.
func _hand_backbone_to_auth() -> void:
	if auth == null or auth.config == null \
			or auth.config.strategy != DotAuthConfig.Strategy.INTROSPECT:
		return

	var client: DotBackboneClient = listing.backbone if listing != null else null

	if client == null:
		if auth.scoped_only:
			DotLog.warn(CHANNEL, "introspection has no integration credential; signed-in players will be refused", {
				"fix": "put an integration token with the USER_LOOKUP scope in data/listing.json",
			})
		return

	auth.backbone = client
	DotLog.info(CHANNEL, "sign-ins are verified by the site, as this server")


## The site issued a credential after the boot stopped waiting for it.
##
## The listing and the sign-in check take it now, which is what a player notices: the next
## member to join arrives as themselves. The party tracker and a game's avatar reads were
## handed the listing's client when they were built and pick it up at the next restart and
## the next game change respectively -- rebuilding those under live players is not worth
## a credential that arrives seconds late once in a server's life.
func _on_enrolled_late(_token: String, listing_path: String) -> void:
	if listing != null and listing.backbone != null:
		return

	if listing != null:
		listing.queue_free()

	listing = TmcReport.install(self, server, content, listing_path)
	_hand_backbone_to_auth()
	DotLog.info(CHANNEL, "the site's credential is in use; parties start with the next restart")


## The addon refs this checkout installs. See setup.sh's "The addon lock".
const ADDONS_LOCK := "res://addons.lock"


## Tells every joining client which addon versions this server runs.
##
## [b]This is what lets an addon release skip the client build.[/b] A client whose shell is
## older fetches the newer addons as packs (each tag is published as
## `modcommunity/<repo>@<version>`), lays them over its own and restarts into them -- see
## dot-cloud's `DotCloudAddonSet`. Without the list a client can only play on the addons it
## was exported with, and every addon fix waited for the next shell.
##
## [b]The lock, not a guess at the checkout.[/b] setup.sh puts every addon clone it owns
## at the locked ref, so the lock is what a box runs. `TMC_ADDONS_LOCK=off` -- addons at
## whatever their branch is -- advertises nothing, because then the lock is not true.
func _advertise_addons() -> void:
	if OS.get_environment("TMC_ADDONS_LOCK") == "off":
		DotLog.info(CHANNEL, "addons are not at the lock (TMC_ADDONS_LOCK=off); none advertised")
		return

	# [b]A box runs the dot-server its lock names, which may predate the field.[/b] Assigning
	# a property an older DotServer does not declare is a script error at boot, so the
	# question is asked of the object rather than assumed.
	if not ("addon_set" in server):
		DotLog.info(CHANNEL, "this dot-server cannot announce addons; clients keep their own", {
			"needs": "dot-server with DotServer.addon_set",
		})
		return

	var dirs := DirAccess.get_directories_at("res://addons")
	var announced := addon_set_from(FileAccess.get_file_as_string(ADDONS_LOCK), dirs)
	server.set("addon_set", announced)

	DotLog.info(CHANNEL, "the addon versions clients are told about", {
		"addons": announced.size(), "lock": ADDONS_LOCK,
	})


## One `{dir, repo, id, version}` per installed addon the lock names.
static func addon_set_from(lock_text: String, dirs: PackedStringArray) -> Array:
	var versions := {}

	for raw in lock_text.split("\n"):
		var line := raw.strip_edges()

		if line == "" or line.begins_with("#"):
			continue

		var parts := line.split("\t", false)

		if parts.size() >= 2:
			versions[parts[0].strip_edges()] = parts[1].strip_edges().trim_prefix("v")

	var out: Array = []

	for dir in dirs:
		if dir.begins_with("."):
			continue

		var repo := addon_repo(dir)

		if not versions.has(repo):
			continue

		out.append({
			"dir": dir,
			"repo": repo,
			"id": "%s/%s" % [content_owner(repo), repo],
			"version": versions[repo],
		})

	return out


## The repository an addon directory comes from. setup.sh's `addon_repo`, and the two
## must agree: one exception, and otherwise underscores become dashes.
static func addon_repo(dir: String) -> String:
	if dir == "zee_weapons":
		return "zee-dot-weapons"

	return dir.replace("_", "-")


## Whose namespace a repository's packs are published under. setup.sh's `repo_url`: the
## `dot-*` addons are the organisation's, everything else (the weapons pack) Christian's.
static func content_owner(repo: String) -> String:
	return "modcommunity" if repo.begins_with("dot-") else "gamemann"


## The tracked file naming the web client shell built from this checkout's addons.lock.
const WEB_BUILD_FILE := "res://web/shell-build"


## Reports `sv_web_build`: the client shell build this server's players need.
##
## [b]A server and the shell are built from one lock, and moved on different days.[/b] The
## site frames ONE shared shell by default, and a server is reinstalled onto new addons on
## its owner's schedule. A pack built against the new addons will not compile on the old
## shell, and the old pack will not run on a server whose addons have moved on, so a single
## shared shell broke one side or the other on every release. The site reads this from the
## query rules (NOTIFY is what puts a cvar there) and frames this build for a launch into
## this server; a server that reports nothing gets the shared one.
##
## [b]From a tracked file, not from the operator's config.[/b] The fact is "which shell was
## exported from the addons this server installed", which is a property of the checkout,
## and the release that bumps addons.lock is the one that publishes the shell and writes
## this file. An operator-set value would be a second copy of that fact that nothing keeps
## in step. Absent or empty registers nothing, which is the shared build.
func _register_web_build() -> void:
	if server == null or server.console == null:
		return

	var build := FileAccess.get_file_as_string(WEB_BUILD_FILE).strip_edges() \
		if FileAccess.file_exists(WEB_BUILD_FILE) else ""

	if build == "":
		DotLog.info(CHANNEL, "no web shell build is named; players get the shared one", {
			"file": WEB_BUILD_FILE,
		})
		return

	server.console.cvar(
		"sv_web_build", build,
		"The web client build this server's players load. Read from %s." % WEB_BUILD_FILE,
		DotConVar.FLAG_NOTIFY
	)
	DotLog.info(CHANNEL, "the web shell build this server needs", {"build": build})


## One path segment, as the site checks it (website-city `IsReleaseId`): it becomes part of
## a URL the site hands a browser, so anything else is ignored there anyway.
const _WEB_LOADER_PATTERN := "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"


## The configured loader version if it is one the site could honour, else "".
func _web_loader_value() -> String:
	var wanted := config.web_loader.strip_edges()

	if wanted == "":
		return ""

	var re := RegEx.create_from_string(_WEB_LOADER_PATTERN)

	if re.search(wanted) == null or wanted.contains(".."):
		return ""

	return wanted


## Reports `sv_web_loader`: the version of the site's web game loader this server's browser
## players should get.
##
## [b]The loader is the site's, not ours, and it moves on the site's schedule.[/b] The site
## keeps every loader version it has published and serves the newest active one by default;
## a server on addons older than that default names the version it still needs, and the site
## serves that one while it is not disabled. A disabled or unknown version is ignored there
## and the player gets the default — so this can never turn a launch into an error, only
## fail to hold a server back.
##
## [b]From the operator's configuration[/b] (`sv_web_loader` in cfg/server.yml,
## `--web-loader`, TMC_WEB_LOADER), unlike `sv_web_build` next door, because holding a server
## on an older loader is a decision rather than a property of the checkout. Always
## registered, empty by default, so rcon can set it on a running server; the site picks the
## change up at its next scan.
func _register_web_loader() -> void:
	if server == null or server.console == null:
		return

	var wanted := _web_loader_value()

	if wanted == "" and config.web_loader.strip_edges() != "":
		DotLog.warn(CHANNEL, "sv_web_loader is not a version label; players get the site's default", {
			"value": config.web_loader,
			"expected": "one path segment: letters, digits, dot, dash, underscore",
		})

	server.console.cvar(
		"sv_web_loader", wanted,
		"The site web game loader version this server's players get. Empty is the site's default.",
		DotConVar.FLAG_NOTIFY
	)

	if wanted != "":
		DotLog.info(CHANNEL, "this server asks the site for a web loader version", {"version": wanted})


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
		auth = node as DotAuthServer

	return true


func _build_cloud() -> void:
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	# Who a pack's requires.json refusal names: "This game needs dot-net API level 3 or
	# newer; this SERVER has level 2" -- the operator's to fix, not the player's.
	cloud.host_role = "server"
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
			"why": "not every game has a catalogue; a game of built geometry does not",
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
