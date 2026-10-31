extends Node

## Boots a [DotServer] from `cfg/` and `content/` and prints an address a friend can paste; this is what `./server` runs, and it decides nothing a config file could have said.
## The boot order is dot-server's and load-bearing: console lines run inside `boot()` (the only window where `sv_tickrate` and the port can still be set), then the listener opens and locks,
## then games register, because [method DotGameManager.change_game] needs a known game, then the default game and its module load.

const CHANNEL := "tmc.host"

## Exit codes, so a supervisor can tell a misconfiguration from a crash (the set `dotserve` uses): a server that cannot find its config
## will not find it on the ninetieth attempt either, and retrying turns one clear error into a journal full of them.
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

## dot-radio, when the addon is linked and `radio.yml` turns it on; null otherwise. See [TmcRadio].
var radio: TmcRadio = null
## dot-trail, likewise from `trail.yml`. See [TmcTrail].
var trail: TmcTrail = null

var _config_dir := "cfg"
var _content_dir := "content"

## Where everything the server *writes* goes: admins, bans, the audit log, the generated config, and any state a game keeps.
## Separate from the two it reads: a container mounts `cfg/` and `content/` read-only and `data/` read-write, and a systemd unit points `ReadWritePaths` at exactly this.
var _data_dir := "data"

var _selftest := false

## Whether this boot asks the site for a credential when it has none ([TmcEnroll]).
## Off unless the command line booted it: a suite embeds this host through [method start] with a token-less `data/`, and sixteen suites asking the real site
## who they are would be sixteen requests from CI to production per run. A real server is always `_run`, which turns it on (except `--selftest`).
var enroll_with_site := false

## Every script error the engine logs during a selftest; null on a normal run. See
## [TmcScriptWatch] for why the check cannot trust its own exit path without it.
var _script_watch: TmcScriptWatch = null

## The module currently loaded on behalf of the running game, and where it came from.
## The path is compared, not the id: two game ids can share one module (hungry's classic and frenzy), and reloading it between them would disconnect everybody.
var _module_name := ""
var _module_path := ""

## Whether the last game change failed to bring its module up.
## Fatal at boot and merely loud afterwards: a server running a game with no netcode is worse than one that refused to start, but refusing once players are on it drops them.
var _module_failed := false


func _ready() -> void:
	# The RPC routing is not optional: Godot addresses an RPC by the receiver's node path *relative to its MultiplayerAPI root* (`/root` by default),
	# so a [DotServer] at `/root/Host/Server` would send calls to "Host/Server" that the client shell's `/root/Shell/Server` answers with `Node not found`, handshake included.
	# Scoping an API to this subtree makes both ends send and expect "Server".
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), get_path()
	)

	if auto_start:
		_run.call_deferred()


## Whether entering the tree reads the command line and starts a server.
## On for `./server`; off is for anything that wants the same boot with directories of its own and no `quit()` (`examples/multigame.tscn`), so it drives the *real* boot rather than a copy.
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
		# A boot test must not need the live port: `./server check` runs on boxes where one is often already serving, and "already in use" is true but not the question asked.
		# Port 0 lets the OS pick; RCON goes off with it because `DotServerConfig.validate` refuses an ephemeral game port alongside an RCON password with no explicit port.
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

	var extras := _apply_addons_config()

	if not extras.ok:
		_die(EXIT_CONFIG, str(extras.error))
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
## A script that fails to parse is logged and handed back uninstantiable, and every later step can still succeed, so "selftest ok" printed over a module that never compiled; the engine's log is the only record, so it is read.
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
## These addons were installed and reached no console at all (dot-log's commands could not plug into a server console, the guard was instantiated nowhere), and an absent command reports nothing.
## Checked here and not in `examples/selftest.tscn` because a fixture has no console.
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

	# Registered ALWAYS, empty unless the operator pinned a shell, so rcon can set it and the query reports it (a cvar without NOTIFY is not in the rules).
	var pinned := server.console.find_cvar("sv_web_build")

	if pinned == null or not pinned.has_flag(DotConVar.FLAG_NOTIFY) \
			or pinned.get_string() != _release_label(config.web_build):
		printerr("selftest FAILED: sv_web_build is not a NOTIFY cvar reporting the configured pin (%s)" % config.web_build)
		return false

	print("sv_web_build: %s" % (pinned.get_string() if pinned.get_string() != "" else "(latest shell)"))

	var requires := server.console.find_cvar("sv_web_requires")

	if requires == null or not requires.has_flag(DotConVar.FLAG_NOTIFY):
		printerr("selftest FAILED: sv_web_requires is not a NOTIFY cvar the query reports")
		return false

	# The addon versions a joining client is told about. Empty on a box with a lock means every player keeps the addons their shell was exported with, however old.
	# Through `get`, not the property: a box's dot-server may predate it, and a typed access would stop this whole script compiling there.
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

	# Asked, not only looked up: a command that is registered and answers nothing is the same absent command one layer down.
	# An Array rather than a PackedStringArray: a lambda captures by value, and only a container's contents survive the copy (docs/gdscript-hazards.md).
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
## The only path `_run` and tests take: a test that reimplemented the boot would test its own copy, and the ordering is what drifts.
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

	var extras := _apply_addons_config()

	if not extras.ok:
		return extras

	var built: bool = await _boot()

	if not built:
		return DotResult.fail(DotError.CODE_STATE, "The server did not come up.")

	return DotResult.success(self)


static func _absolute(path: String) -> String:
	if path.contains("://") or path.begins_with("/"):
		return path

	return ProjectSettings.globalize_path("res://").path_join(path)


## `--sv-*` style overrides, for one run without editing a file.
## Deliberately narrow (a port, a bind address, a name, a game): a flag is invisible to whoever reads the config file next, and secrets are refused for [method DotConfig.sensitive_keys]'s reason (argv is readable by every process).
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

	# The other three ports, and the interface the query listener binds. All four are derived WRONG on a panel: RCON defaults to game port plus one and both query ports to the game port,
	# but Pterodactyl hands out whatever allocations were free on that node, and a taken `port + 1` fails as "address in use" on a port nobody configured.
	# Not secrets, so argv is fine, unlike `--rcon-password`.
	var rcon_port := _value(args, "--rcon-port", "")

	if rcon_port != "":
		config.server.rcon_port = rcon_port.to_int()

	# A2S first, because `query_port` DERIVES FROM IT (`effective_query_port()` falls back to `effective_a2s_port()`): setting only `--a2s-port` moves both onto one socket,
	# which the two protocols tell apart by their first four bytes. Setting `--query-port` as well splits them.
	var a2s_port := _value(args, "--a2s-port", "")

	if a2s_port != "":
		config.server.a2s_port = a2s_port.to_int()

	var query_port := _value(args, "--query-port", "")

	if query_port != "":
		config.server.query_port = query_port.to_int()

	# The one setting a reverse-proxied server cannot do without: nginx cannot forward UDP, so with `--bind` on loopback the query listener binds where no tracker can reach it
	# and looks like a server that is down. `*` puts the query port, and only it, on every interface; RCON deliberately does not follow.
	var query_bind := _value(args, "--query-bind", "")

	if query_bind != "":
		config.server.query_bind_address = query_bind

	var game := _value(args, "--game", "")

	if game != "":
		config.initial_game = game

	# The set this server offers, as one comma-separated argument: the other end is a panel text box or a unit file's `Environment=`, neither of which can repeat a flag.
	# REPLACES the YAML rather than adding to it, so an operator can narrow a box that already has a `games:` key.
	var offered := _value(args, "--games", "")

	if offered != "":
		# Through TmcGameRef, because the same string also names things to FETCH: `TMC_GAMES` may say `gamemann/game-g2gfast01@1.2.0`,
		# which installs into `content/game-g2gfast01/`, so comparing the raw entry against a directory name would offer none of a game just downloaded.
		config.games_allow = TmcGameRef.dirs_in(offered)

	# Where content comes from, as an argument, for the same reason the list of games is one (a panel operator has no shell; `cfg/server.yml` is setup.sh's).
	# It replaces the file's list so a deployment can say "not the public origin". Clients are told the same thing as the server (`content_urls` in TmcConfig):
	# two settings for one fact is this tree's most repeated bug.
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

	# Two spellings: `--map` is what `server` and TMC_MAP hand down, `+map` is what anybody who has run a dedicated server types.
	# `+map` reaches here rather than the console because DotConsole runs `+command` after the listener opens but BEFORE a game is loaded, so the `map` command did not exist yet and the argument was silently dropped.
	# `--map` wins a disagreement, being the explicit one and the one a unit file sets.
	var map_id := _value(args, "--map", _value(args, "+map", ""))

	if map_id != "":
		config.initial_map = map_id

	# Same two spellings as `--map`, for the same reason: `+sv_web_loader` would otherwise go
	# to the console, which runs it before this host has registered the cvar.
	var web_loader := _value(args, "--web-loader", _value(args, "+sv_web_loader", ""))

	if web_loader != "":
		config.web_loader = web_loader

	var web_build := _value(args, "--web-build", _value(args, "+sv_web_build", ""))

	if web_build != "":
		config.web_build = web_build

	for flag in ["--rcon-password", "--password"]:
		if flag in args:
			DotLog.warn(CHANNEL, "a secret on the command line is refused", {
				"flag": flag,
				"why": "argv is readable by other processes; put it in cfg/server.yml",
			})


## The owner's per-game settings from `cfg/server/content/overrides.yml` (cvars, metadata, player counts, maps), laid over each `game.yml` before any descriptor is read.
## Here rather than in TmcContent.scan because the scan knows a content directory and nothing about cfg/ or data/; see TmcGameConfig.
func _apply_game_config() -> DotResult:
	var loaded := TmcGameConfig.load_from(_config_dir, _absolute(_data_dir))

	if not loaded.ok:
		return loaded

	var overrides := loaded.value as TmcGameConfig
	overrides.apply_all(content)

	for line in overrides.warnings:
		DotLog.warn(CHANNEL, line)

	if not overrides.errors.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"cfg/%s: %s" % [TmcGameConfig.FILE, "; ".join(overrides.errors)],
			"a bare map name needs map_owner:, sv_map_content_owner or an owner/map spelling"
		)

	return DotResult.success(overrides)


## The server owner's extra packs (`cfg/addons.yml`), appended to each game's dependencies
## AFTER the game's own settings are applied, so a `remove:` there cannot be undone here. A
## malformed file is a configuration error (exit 5), not a content one: the content is fine.
func _apply_addons_config() -> DotResult:
	var loaded := TmcAddonsConfig.load_from(_config_dir, _absolute(_data_dir))

	if not loaded.ok:
		return loaded

	var extras := loaded.value as TmcAddonsConfig
	extras.apply_all(content)

	for line in extras.warnings:
		DotLog.warn(CHANNEL, line)

	return DotResult.success(extras)


func _boot() -> bool:
	# Everything the server writes goes under one directory. Set before `boot()` because
	# dot-server reads them during it: the admin file is loaded, a template is written if
	# there is none, and the audit log is opened.
	config.server.admins_path = "%s/admins.json" % _data_dir
	config.server.bans_path = "%s/bans.json" % _data_dir
	config.server.audit_log_path = "%s/audit.jsonl" % _data_dir

	# Before the server exists, because the first line this boot emits is the interesting one: the router registers itself as a DotLog sink on entering the tree,
	# so what is built before it is not covered, and a log is most wanted for why the boot went wrong.
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
	# Both config slots are named absolutely, so dot-server's search path cannot reach the `server.cfg` and `autoexec.cfg` its own addon ships,
	# which would run after the operator's YAML and silently override it. `cfg/autoexec.cfg` is still honoured, and runs after the listener opens.
	config.server.autoexec_config = "%s/autoexec.cfg" % _config_dir
	# The operator's net_max_* as ceilings on whatever game loads: dot-game's
	# DotGameModule reads this meta before its netcode starts. The name is spelled out
	# (it is DotGameNetcode.CEILING_META) so the host does not need dot-game linked to boot.
	server.set_meta(&"dot_net_ceiling", config.net_ceiling())
	add_child(server)

	# Queries are their own addon now and only answer if a host is plugged in; `a2s_enabled: true` ships in cfg/server.yml,
	# so a deployment without this quietly drops off every listing.
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

	# A `kind: pack` game needs a cloud client on the SERVER too: `DotGameManager` fetches and mounts the new game's content itself before asking anybody else,
	# because the scene it loads is a path inside the mount. Added before boot() so the registration is in place before the game manager runs its initial change.
	_build_cloud()

	# Before boot() too: the list rides the signon challenge, and the first client can
	# arrive the moment the listener opens.
	_advertise_addons()

	# Before boot() for a second reason, the challenge: `DotServer` answers a connecting client with the strategy it wants by asking the registry for `dot_auth_server`,
	# so one registered after the listener opens was reported to every client in flight as absent.
	if not _build_auth():
		return false

	var booted: DotResult = await server.boot()

	if not booted.ok:
		# "Already in use" is the common one and a *port* failure, not a configuration one: treating it as a misconfiguration would stop retrying,
		# and the usual cause is the previous instance not having exited yet.
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

	# Connected before the first change, so the boot load and every later `changelevel` take exactly the same path:
	# a separate "load the module for the game we booted into" step is a path only the first game ever takes.
	server.games.game_loaded.connect(_on_game_loaded)

	# Before the first game, because the game's identity layer needs the credential: `DotPlatformIdentity` finds `dot_backbone_client` while the module loads
	# and reads avatars through it; built after, every booted game kept avatars in a local file the site never sees. Reports are on the client's timer, so nothing is reported early.
	# The credential is asked for first when there is none: an unenrolled box proves it is the server at its listed address and is issued one (see [TmcEnroll]); awaited, bounded.
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

	# After the first game is loaded, because the director has to be told what is running: a vote that starts on no game has no clock and offers the game everybody is playing on its first ballot.
	# games.yml: no file is every game; an unreadable one is an ERROR and plays every game too, because a vote that cannot start is worse.
	var rotation_read := TmcGameRotation.load_file(DotCfgLegacy.find(
		"%s/%s" % [_config_dir, TmcGameRotation.LEGACY_FILE], "%s/%s" % [_config_dir, TmcGameRotation.FILE]))
	if not rotation_read.ok:
		DotLog.error(CHANNEL, "cfg/content/games.yml could not be read; every installed game plays", {
			"why": str(rotation_read.error),
		})
	var games_rotation: TmcGameRotation = rotation_read.value if rotation_read.ok else null
	if games_rotation != null and not games_rotation.has_rotations():
		games_rotation = _order_from_content_list(server) if _has_content_games_list() else games_rotation
	votes = TmcVote.install(self, server, config.vote, config.vote_exclude, games_rotation)

	# After the listing, because that is where the backbone client is: a second client for the same token would be two rate limiters for one budget.
	# With no token there is no client and bookings still come from the console. After the first game too: the booking chains onto `dot_ban_source`, which the game's module registers dot-moderation on, and would be displaced.
	parties = TmcParty.install(
		self, server, config,
		listing.backbone if listing != null else null,
		_data_dir
	)

	# After the first game, so the first header names a game and the first keyframe has a roster to hold; before any player can be kicked.
	# It watches the registry for each game's dot-moderation itself, so it need not precede the module that registers one.
	replay = TmcReplay.install(self, server, config, _data_dir)

	# The recorder's settings for whichever game declares a schema; it builds the recorder.
	if config.bot_record.path == "":
		config.bot_record.path = _absolute(_data_dir).path_join("bot/demos")
	DotRegistry.register(&"bot_record_config", config.bot_record)

	radio = TmcRadio.install(self, server, config, _absolute(_data_dir))
	trail = TmcTrail.install(self, server, config, _absolute(_data_dir))

	# After the first game, so the menu's first look at the console sees the game's own
	# commands -- though it looks again on every page, which is what keeps it right across
	# a changelevel. `warn` is registered here only if nothing before it took the name.
	var map_session := func() -> Object:
		return _find_map_session(server.games)

	admin_menu = TmcAdminMenu.install(self, server, config.admin_menu, map_session)

	# After the first game too: it watches that game's map session for per-map screens.
	var reread := func() -> DotResult:
		return TmcConfig.merged_file("dot-core", "loading.yml", _config_dir)

	loading = TmcLoading.install(self, server, config.loading, reread, map_session)

	return true


## Builds the sink layer, when the configuration asks for one. Not fatal, ever: a collector that cannot be reached is a reason to look at the configuration,
## not for a server full of people to stop. (Syslog, collector, SQL, redaction, flood gating and the ring behind `log tail` were configured-for and unreachable before this.)
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
## The same client, so the same token and rate limiter: the site resolves the scope from the credential, and another token would mint keys in another scope.
func _hand_backbone_to_auth() -> void:
	if auth == null or auth.config == null:
		return
	var adopting := auth.config.adopt_ticket_trust
	if auth.config.strategy != DotAuthConfig.Strategy.INTROSPECT and not adopting:
		return

	var client: DotBackboneClient = listing.backbone if listing != null else null

	if client == null:
		if adopting and auth.config.server_id == "":
			DotLog.warn(CHANNEL, "this server does not know its site id yet; signed-in players wait", {
				"fix": "enroll (data/listing.json), or set server_id in auth.yml",
			})
		elif auth.scoped_only:
			DotLog.warn(CHANNEL, "introspection has no integration credential; signed-in players will be refused", {
				"fix": "put an integration token with the USER_LOOKUP scope in data/listing.json",
			})
		return

	auth.backbone = client
	if not adopting:
		DotLog.info(CHANNEL, "sign-ins are verified by the site, as this server")


## The site issued a credential after the boot stopped waiting for it. The listing and the sign-in check take it now, so the next member joins as themselves;
## the party tracker and a game's avatar reads pick it up at the next restart and game change, and rebuilding those under live players is not worth a credential that arrives seconds late once in a server's life.
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


## Tells every joining client which addon versions this server runs, so an addon release can skip the client build: an older shell fetches the newer addons as packs
## (`modcommunity/<repo>@<version>`), lays them over its own and restarts into them (dot-cloud's `DotCloudAddonSet`).
## The lock, not a guess at the checkout: setup.sh puts every clone at the locked ref. `TMC_ADDONS_LOCK=off` advertises nothing, because then the lock is not true.
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


## Addon repositories whose id on the site is a Workshop data pack (provides.json, weapons/), not the addon directory; a shell cannot overlay it as an addon.
const DATA_PACK_REPOS := ["arena-weapons"]


## One `{dir, repo, id, version}` per installed addon the lock names, bar those in [constant DATA_PACK_REPOS].
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

		if not versions.has(repo) or DATA_PACK_REPOS.has(repo):
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


## Reports `sv_web_build`: the shell build this server's players are pinned to. EMPTY by default, which means the site's newest compatible shell, with no restart needed to move.
## The pin is the operator's decision (`sv_web_build`, `--web-build`, TMC_WEB_BUILD), for a server deliberately held on an older shell the site still lists. `web/shell-build` is only this checkout's record of the shell it was exported with.
## Always registered so rcon can set it.
func _register_web_build() -> void:
	if server == null or server.console == null:
		return

	var wanted := _release_label(config.web_build)

	if wanted == "" and config.web_build.strip_edges() != "":
		DotLog.warn(CHANNEL, "sv_web_build is not a build id; players get the site's newest shell", {
			"value": config.web_build,
			"expected": "one path segment: letters, digits, dot, dash, underscore",
		})

	server.console.cvar(
		"sv_web_build", wanted,
		"Pins the web client shell build this server's players load. Empty is the site's newest compatible shell.",
		DotConVar.FLAG_NOTIFY
	)
	server.console.cvar(
		"sv_web_requires", "",
		"JSON of the addon API levels the loaded game's pack needs, so the site can pick a compatible shell. Set by the host.",
		DotConVar.FLAG_NOTIFY
	)

	if wanted != "":
		DotLog.info(CHANNEL, "this server pins a web shell build", {"build": wanted})


## Addon API levels each mounted pack asked for (`requires.json`), by content id.
var _pack_requires: Dictionary = {}


## Records what a mounted pack needs. Read here because the pack is mounted and nothing has to be fetched twice.
func _record_requires(manifest: DotCloudManifest, mount_prefix: String) -> void:
	var path := mount_prefix.trim_suffix("/") + "/" + DotAddonApi.REQUIREMENTS_FILE

	if not FileAccess.file_exists(path):
		return

	var parsed := DotAddonApi.parse(FileAccess.get_file_as_string(path))

	if parsed.ok:
		_pack_requires[manifest.content_id] = parsed.value


## Publishes the loaded game's needs as `sv_web_requires`: the highest level of each addon over the game's pack and its dependencies.
## Empty when the pack carries no requires.json, which the site reads as "no constraint".
func _publish_requires() -> void:
	var cvar := server.console.find_cvar("sv_web_requires") if server != null and server.console != null else null
	var current := server.games.current() if server != null and server.games != null else null

	if cvar == null or current == null:
		return

	var descriptor := content.find(current.game_id)
	var ids := PackedStringArray()

	if descriptor != null:
		ids.append(descriptor.content_id)
		ids.append_array(descriptor.dependencies)
		ids.append_array(descriptor.server_dependencies)

	var merged: Dictionary = {}

	for key in ids:
		var needs: Variant = _pack_requires.get(String(key).get_slice("@", 0))

		if needs is Dictionary:
			for addon in needs:
				merged[addon] = maxi(int(merged.get(addon, 0)), int(needs[addon]))

	cvar.set_value("" if merged.is_empty() else JSON.stringify(merged))


## One path segment, as the site checks it (website-city `IsReleaseId`): it becomes part of
## a URL the site hands a browser, so anything else is ignored there anyway.
const _WEB_LOADER_PATTERN := "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"


## The configured loader version if it is one the site could honour, else "".
func _web_loader_value() -> String:
	return _release_label(config.web_loader)


## A loader version or build id if it is one path segment the site could honour, else "".
func _release_label(raw: String) -> String:
	var wanted := raw.strip_edges()

	if wanted == "":
		return ""

	var re := RegEx.create_from_string(_WEB_LOADER_PATTERN)

	if re.search(wanted) == null or wanted.contains(".."):
		return ""

	return wanted


## Reports `sv_web_loader`: the version of the site's web game loader this server's browser players should get.
## The loader is the site's and moves on its schedule; a disabled or unknown version is ignored there, so this can never turn a launch into an error, only fail to hold a server back.
## From the operator's configuration (`sv_web_loader`, `--web-loader`, TMC_WEB_LOADER), like `sv_web_build`, because holding a server on an older loader is a decision. Always registered, empty by default, so rcon can set it.
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


## Puts `log` on the console. dot-log's console object could only plug into a CLIENT console until dot-server grew `add_source`, so the one process with a log worth tailing could not reach it;
## `DotConsole.add_source` wraps each name in a real `DotConCommand`, so `log` gets the permission check, RCON gate and audit line.
## GENERIC, not root: reading back what the server has said is what being staff is for, and `log test` is the only thing here that writes.
func _register_log_commands() -> void:
	if server == null or server.console == null:
		return

	var source := DotLogCommands.new(log_router)
	var registered := server.console.add_source(source, DotAdminFlags.GENERIC)

	DotLog.result(CHANNEL, "the log console commands", registered, DotLog.Level.WARN)


## Builds the guard, its watchers and the detectors. It ships in dry run (every rule evaluates and is ledgered marked WOULD, nobody is punished),
## which is why building it for every server is the right default: an operator reads `sec_status` for a week and then decides.
## Nothing here is fatal: refusing to boot over an unreadable rules file costs players what they came for over a permissions mistake.
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
	# `".."`, not `"../Server"`: the guard is a CHILD of the server, so `..` already IS the server, and `../Server` finds nothing and
	# watches nothing for the life of the process. The two watchers below are siblings of the guard and correctly say `../Security`.
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

	# The console commands are NOT registered here: `DotSecurityManager.attach()` does it itself, and a second `DotSecurityCommands.register`
	# produces "command registered twice" warnings (the console correctly keeping the first).

	DotLog.info(
		CHANNEL,
		"the security guard is watching",
		{
			"dry_run": guard.is_dry_run(),
			"anticheat": anticheat != null,
		}
	)


## Builds the auth server `cfg/auth.yml` asks for. False means the file is wrong.
## A configuration error is fatal: every other outcome leaves the server running with everybody a guest, which is what a broken `auth.yml` looks like from outside.
func _build_auth() -> bool:
	var built := TmcAuth.build(config.auth, _config_dir, _absolute(_data_dir))

	if not built.ok:
		_die(EXIT_CONFIG, str(built.error))
		return false

	var node: Node = built.value

	if node != null:
		server.add_child(node)
		auth = node as DotAuthServer

	return true


## Creates the content client a delivered game is fetched through. Config comes from a file, not YAML: `trusted_keys` is refused from the environment and
## command line on purpose (`DotCloudConfig.sensitive_keys`), or anything able to set a variable here would become a content publisher.
func _build_cloud() -> void:
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	# Who a pack's requires.json refusal names: "This game needs dot-net API level 3 or
	# newer; this SERVER has level 2" -- the operator's to fix, not the player's.
	cloud.host_role = "server"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = "%s/content_cache" % _data_dir
	# A pack's client-only files (a game's baked light, dot-cloud API 8) are never fetched
	# here: this process never draws. Said outright rather than left to `auto`, which reads
	# the same on a headless box and would read wrong on a server started with a window.
	cloud.config.side = "server"
	# Falls back to the tracked defaults when the deployment has no answer of its own: `data/content.json` is GENERATED from `client/content.json` by setup.sh (plus this box's signing key),
	# so it exists only on a real install, and without it no delivered game can mount ("no trusted_keys are configured", naming a file the operator never wrote).
	# It lives in `data/`, not `cfg/`, being machine-written. `client/content.json` holds the PUBLIC half of the signing key, not a secret; a deployment trusting another publisher writes `data/content.json` and this never looks.
	cloud.config_file = "%s/content.json" % _data_dir

	if not FileAccess.file_exists(cloud.config_file):
		cloud.config_file = "res://client/content.json"
	# The content directory is searched before the network, so a pack beside the game that names it needs no web server (a LAN deployment, every test).
	# `dist/` too, when there is one: it is where `./server pack` writes, so a server that published a map has it. Absent on a deployment that only consumes.
	var searched := PackedStringArray([content.root])
	var published := ProjectSettings.globalize_path("res://dist")

	if DirAccess.dir_exists_absolute(published):
		searched.append(published)

	# And `dist/maps/`, where owned map packs land (`<owner>/<map>`): a map is asked for as `gamemann/surf_mesa`, so with `dist/` alone this looked for
	# `dist/gamemann/surf_mesa` and never found the maps in `dist/maps/gamemann/`, while the export check counted them as published.
	var published_maps := published.path_join("maps")

	if DirAccess.dir_exists_absolute(published_maps):
		searched.append(published_maps)

	# And the manifests `install-games` kept, which makes a restart survive an origin outage: a manifest is fetched over the network every time, so a server with every byte of a pack on disk
	# still refused to boot while the origin was down. Searched, not trusted: a manifest found here goes through the same signature check as one off the wire.
	var manifests := "%s/manifests" % _data_dir

	if DirAccess.dir_exists_absolute(manifests):
		searched.append(manifests)

	cloud.local_search_dirs = searched

	# Where to fetch content this box does not have. Without it the client could only find a pack already on disk: a server stood up by cloning the repositories has the game and none of
	# its gitignored maps, and dies on its own default map while they sit published on the origin. A list, searched in order, because a LAN deployment mirrors the packs somewhere of its own.
	cloud.http_base_urls = config.content_urls

	if config.content_urls.is_empty():
		DotLog.info(CHANNEL, "no content urls; this server can only use content it already has", {
			"searched": searched,
			"hint": "set content_urls in cfg/server.yml to fetch maps and packs",
		})

	# The published layout is `{id}/{version}/`, dot-cloud's own default: the site publishes `content/<owner>/<name>/<version>/manifest.json` (a member may have four versions of one game up at once).
	# The flat form stays as a FALLBACK because an origin holds both: imported map packs were published under it, and re-publishing everything is not a precondition for starting.
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])

	# Say what a download is doing, on the console an operator is watching: one line at the start and nothing until the end is indistinguishable from a hang on a slow link.
	# Throttled to a line a second rather than forwarded raw (`progress_changed` fires per chunk): this is for a file somebody greps, not a spinner.
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

	_record_requires(manifest, mount_prefix)

	DotLog.info(CHANNEL, "content ready", {
		"content": manifest.key(),
		"at": mount_prefix,
	})


func _on_game_loaded(_content_key: String) -> void:
	if server == null or server.games == null:
		return

	await _load_game_module()
	_attach_addon_entries()
	_publish_requires()


## Starts the extra packs that run on the server, as children of the DotServer node: the game's own root is private to DotGameManager,
## which frees whatever sits under the server node when the game changes, so they go with the game. After the module, because an entry may look for the game's services.
func _attach_addon_entries() -> void:
	var current := server.games.current()

	if current == null:
		return

	var descriptor := content.find(current.game_id)
	var cloud := DotRegistry.get_service(&"dot_cloud_client")

	if descriptor == null or cloud == null:
		return

	var keys := PackedStringArray(descriptor.dependencies)
	keys.append_array(descriptor.server_dependencies)
	TmcAddonEntry.attach(server, cloud, keys, "server")


## Keeps the right module loaded as the game changes: dot-server does not load modules, so without this `changelevel` leaves the previous game's module driving the new world, or none at all.
## Paths are compared, not ids: a different module is unloaded first (two [DotNetManager]s would tick one world), the same module under another game id rebinds itself
## through [method DotModule._module_game_changed] (reloading would drop every player), and no module is legitimate.
func _load_game_module() -> void:
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

	# Awaited, because a game module's `_module_load` is a coroutine (an identity layer reaching a content host and a profile store);
	# un-awaited, this returned at the first suspension and the check below read `.ok` off null.
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

	# The game's own cvars, now that the module owning them exists: `DotGameManager` applies a descriptor's `cvars:` while the scene is up and the module is not
	# (tying one module to one game is THIS host's policy), so a game.yml naming a module cvar was refused as unknown on the first pass.
	# Only when the module actually changed: otherwise the first pass already found every cvar registered.
	server.games.reapply_descriptor_cvars()


## Puts the boot on `sv_map` / `--map` / `+map`, once the game that owns it is up. After the game rather than instead of it: the game's map session reads its own config,
## so its first map is loaded before this host can say otherwise and a `+map` server loads two maps at boot; reaching into a scene not yet instantiated is the kind of thing that works until a game builds its session elsewhere.
## Nothing here is fatal: a game with no maps, or a map not in the catalogue, is an operator's typo on a server full of people.
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

	# Fetch it before asking for it: `change_to` refuses an id the catalogue does not hold, and a catalogue only holds what is on disk,
	# so a delivered map was refused here rather than downloaded and read as an operator's typo. A game that fetches its own content sees a mount already there and does nothing twice.
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


## Download the content a map lives in, if this deployment can and does not have it. The map id IS the content id (the publisher's convention; a second registry would be a third place to keep in step).
## Every outcome is non-fatal: the refusal that follows from `change_to` is the better message anyway because it names the map.
func _ensure_map_content(id: StringName, root: Node = null) -> void:
	if id == &"":
		return

	# Through the game's own fetch when it has one, because mounting is only half: a delivered map has to be ADDED to the catalogue too, and a pack mounted a moment ago is not in it,
	# so a `+map` map was downloaded, verified, mounted and then refused with "No such map in the catalogue" (hidden whenever the asked map was already the game's default).
	# Duck-typed on the method, as `_find_map_session` explains: a game that answers `ensure_map_content` registers its own; otherwise the mount below is right for a complete catalogue.
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


## The running game, if it fetches and registers its own map content. Duck-typed and walked like [method _find_map_session]: the game is a scene loaded from a pack, not a type this host may name.
## `ensure_map_content` is the half `change_to` cannot do for itself, see [method _ensure_map_content].
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


## The loaded game's map session, or null. Duck-typed, like everything that crosses into a game: `has_method` and `call` rather than `is DotMapSession`,
## because this host has no business requiring dot-map (dot-vote's map source uses the same contract).
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


## The lines an operator reads to find out whether it worked. Every address, including a LAN one: "it started and my friend cannot connect" is almost always a bind address or a firewall,
## and the first help is knowing which address the server is on.
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
		else "%s, %s per game, %s at %d%%" % [
			votes.rules_summary(),
			votes.director.clock.formatted_remaining(),
			votes.commands.typed("rtv"),
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


## Every address a client could reach this server on. The loopback is listed last: it always works and never helps somebody else connect.
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


## True when the operator wrote cfg/content/games.yml; the shipped list alone never changes how games rotate.
func _has_content_games_list() -> bool:
	return FileAccess.file_exists("%s/content/games.yml" % _config_dir) or FileAccess.file_exists("%s/server/content/games.yml" % _config_dir)


## Zero-config game order: the operator's games.yml order over the installed games, when there are several.
## Null (keep what is there) for one game or an unreadable list; an unknown game in it is an ERROR and every game plays.
func _order_from_content_list(p_server: DotServer) -> TmcGameRotation:
	var listed := TmcContentLists.load_list("games", _config_dir)
	if not listed.ok:
		DotLog.error(CHANNEL, "cfg/content/games.yml could not be read; every installed game plays", {"why": str(listed.error)})
		return null
	var installed := PackedStringArray()
	for d: DotGameDescriptor in p_server.games.games:
		var key := TmcGameRotation.key_of(d)
		var short := key.get_slice("/", key.get_slice_count("/") - 1)
		if not installed.has(short):
			installed.append(short)
	if installed.size() < 2:
		return null
	var order := TmcContentLists.game_order(listed.value, installed)
	if not order.ok:
		DotLog.error(CHANNEL, "games.yml game order not applied; every installed game plays", {"why": str(order.error)})
		return null
	return TmcGameRotation.from_order(order.value)
