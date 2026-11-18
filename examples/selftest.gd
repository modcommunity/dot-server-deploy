extends Node

## Everything this repository adds, checked without starting a server. Exits non-zero on any
## failure. The YAML reader, the config translation, the permission translation and the content
## index.

const CFG := "res://examples/fixtures"

## A loaded game with rounds and no match the game vote can find. See the section that uses it.
const RoundsWithoutMatch := preload("res://examples/fixtures/rounds_without_match.gd")

const Host := preload("res://host/tmc_host.gd")

const CHECKS := 639

## Where the replay section writes. Emptied at the start of every run, so a clip left by the
## last one cannot satisfy a check about this one (docs/testing.md, "a suite that writes to
## user://").
const REPLAY_DIR := "user://tmc_selftest_replay"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy")

	SelftestYaml.new(self)._test_yaml_scalars()
	SelftestYaml.new(self)._test_yaml_structure()
	SelftestYaml.new(self)._test_yaml_refusals()
	_test_config()
	_test_aliases()
	_test_admins()
	_test_layered_cfg()
	SelftestContentLists.new(self)._test_content_lists()
	_test_content()
	SelftestContentLists.new(self)._test_former_game_id()
	_test_owner_maps()
	await _test_map_collections()
	_test_game_refs()
	_test_vote()
	SelftestVoteBallot.new(self)._test_vote_layers_reach_a_ballot()
	_test_vote_rounds_without_a_match()
	SelftestVoteBallot.new(self)._test_vote_limit_waits_for_a_change()
	_test_game_rotation()
	_test_vote_notices()
	_test_auth()
	_test_logging()
	SelftestServerFeatures.new(self)._test_security()
	SelftestServerFeatures.new(self)._test_party()
	SelftestServerFeatures.new(self)._test_bot_record()
	await _test_replay()
	await _test_friends()
	_test_game_cfg_dirs()
	SelftestServerFeatures.new(self)._test_radio()
	SelftestAddonAnnounce.new(self)._test_addon_announce()
	SelftestServerFeatures.new(self)._test_startup_checks()
	SelftestServerFeatures.new(self)._test_cache_limit()

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

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
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


func _parse(text: String) -> Dictionary:
	var result := TmcYaml.parse(text, "<test>")
	return result.value as Dictionary if result.ok else {}


func _alias_cfg(label: String, server_yml: String, alias_yml: String) -> String:
	var dir := ProjectSettings.globalize_path("user://alias_test_%s" % label)
	DirAccess.make_dir_recursive_absolute(dir + "/server")
	var f := FileAccess.open(dir + "/server/server.yml", FileAccess.WRITE)
	f.store_string(server_yml)
	f.close()
	var path := dir + "/server/alias.yml"
	if alias_yml != "":
		var g := FileAccess.open(path, FileAccess.WRITE)
		g.store_string(alias_yml)
		g.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return dir


func _test_aliases() -> void:
	_section("aliases: game, sv_game, sv_games, alias.yml")

	var c1 := TmcConfig.load_dir(_alias_cfg("new", "game: \"smash\"\nsv_name: \"a\"\n", ""))
	_check(c1.ok and (c1.value as TmcConfig).initial_game == "smash", "`game:` names the boot game")

	var c2 := TmcConfig.load_dir(_alias_cfg("old", "sv_game: \"deathrun\"\nsv_games: [smash, deathrun]\n", ""))
	var cfg2: TmcConfig = c2.value if c2.ok else null
	_check(cfg2 != null and cfg2.initial_game == "deathrun", "`sv_game:` is a built-in alias of `game` with no alias.yml")
	_check(cfg2 != null and cfg2.games_allow.size() == 2, "`sv_games:` is a built-in alias of `games` (%s)" % str(cfg2.games_allow if cfg2 else []))
	_check(cfg2 != null and not cfg2.console_lines.has("sv_game deathrun"), "and is not queued as a console line")

	var c3 := TmcConfig.load_dir(_alias_cfg("both", "sv_game: \"deathrun\"\ngame: \"smash\"\n", ""))
	_check(c3.ok and (c3.value as TmcConfig).initial_game == "smash", "`game:` wins over `sv_game:` whatever the order")
	var c3b := TmcConfig.load_dir(_alias_cfg("both2", "game: \"smash\"\nsv_game: \"deathrun\"\n", ""))
	_check(c3b.ok and (c3b.value as TmcConfig).initial_game == "smash", "and in the other order")

	var c4 := TmcConfig.load_dir(_alias_cfg("user", "mygame: \"smash\"\nmymap: \"m1\"\n", "# mine\nmygame: game   # one word\n\"mymap\": map\nrestart: changelevel smash\n"))
	var cfg4: TmcConfig = c4.value if c4.ok else null
	_check(cfg4 != null and cfg4.initial_game == "smash" and cfg4.initial_map == "m1", "alias.yml aliases work as config keys, quoting and comments included (%s)" % str(c4.error if not c4.ok else ""))
	_check(cfg4 != null and cfg4.aliases.has("restart"), "an alias with arguments is kept for the console")

	# Zee's MiniGames: the owner's own server.yml, verbatim (examples/fixtures/zee_minigames).
	var zee := TmcConfig.load_dir("res://examples/fixtures/zee_minigames/cfg")
	var zc: TmcConfig = zee.value if zee.ok else null
	_check(zc != null, "the MiniGames server.yml loads (%s)" % str(zee.error if not zee.ok else ""))
	_check(zc != null and zc.server.hostname == "Zee's MiniGames #1 | Party/Random Games!", "`hostname:` is the server name, quotes, apostrophe and # included")
	_check(zc != null and zc.server.max_players == 40, "`sv_maxplayers: 40`")
	_check(zc != null and zc.initial_game == "mg-smash-copter", "`game:` is the bare id")
	_check(zc != null and zc.games_allow.size() == 7 and "gamemann/mg-smash-copter" in zc.games_allow,
		"`games:` keeps seven of eight entries: mg-deathrun twice is one game (%s)" % str(zc.games_allow if zc else []))
	_check(zc != null and zc.unknown.is_empty() and zc.console_lines.is_empty(), "and nothing in it is an unknown key or a console line")
	var zo := TmcConfig.load_dir(_alias_cfg("zee_full", "game: gamemann/mg-smash-copter\nhostname: x\ngames: [gamemann/mg-smash-copter]\n", ""))
	_check(zo.ok and (zo.value as TmcConfig).initial_game == "gamemann/mg-smash-copter", "`game:` also takes owner/repo")
	var zh := TmcConfig.load_dir(_alias_cfg("zee_both", "sv_name: \"a\"\nhostname: \"b\"\n", ""))
	_check(zh.ok and (zh.value as TmcConfig).server.hostname == "a", "`sv_name:` wins over its alias `hostname:`")
	var zn := TmcConfig.load_dir(_alias_cfg("zee_hostname", "hostname: \"Zee Server\"\n", ""))
	_check(zn.ok and (zn.value as TmcConfig).server.hostname == "Zee Server", "`hostname:` alone sets the server name")
	var hc := DotConsole.new()
	add_child(hc)
	hc.register_cvar(DotConVar.new("hostname", "x", "name", 0))
	hc.register_cvar(DotConVar.new("sv_gravity", "800", "g", 0))
	var rep := TmcAliases.check({
		"hostname": {"target": "sv_name", "source": "t:1", "layer": "addon"},
	}, hc)
	_check(rep["failures"] == 0 and (rep["unknown"] as PackedStringArray).is_empty(), "alias `hostname` -> `sv_name` is not a shadow of the cvar `hostname`")
	var rep2 := TmcAliases.check({
		"sv_gravity": {"target": "sv_name", "source": "t:2", "layer": "server"},
	}, hc)
	_check(rep2["failures"] == 1, "an alias that hides a DIFFERENT cvar is still a shadow failure")
	hc.queue_free()

	var bad := {
		"line": ["not a mapping line", "name: target"],
		"twice": ["a: game\na: games", "defined twice"],
		"self": ["foo: foo", "points at itself"],
		"chain": ["foo: game\nbar: foo", "alias `foo`"],
		"shadow": ["game: games", "shadow"],
		"name": ["bad name: game", "not a usable alias name"],
		"empty": ["foo:", "no target"],
	}
	for label in bad:
		var r := TmcConfig.load_dir(_alias_cfg("bad_" + label, "sv_name: \"a\"\n", bad[label][0]))
		_check(not r.ok and str(r.error).contains(bad[label][1]) and str(r.error).contains("alias.yml:"),
			"alias.yml '%s' fails loudly naming file and line (%s)" % [label, str(r.error).replace("\n", " | ")])
	_alias_layers()
	_done()


## Alias layers: addon defaults, the game and the server, later wins; and no cap on the count.
func _alias_layers() -> void:
	# Layers: addon defaults (host/aliases.yml), then game, then server; later wins; each can add, remove or remap.
	var cfg_l := TmcConfig.new()
	cfg_l._load_default_aliases()
	_check(cfg_l.aliases.get("sv_game", {}).get("layer", "") == "addon" and cfg_l.aliases["sv_game"]["target"] == "game",
		"layer 1 ships sv_game -> game (%s)" % str(cfg_l.aliases.get("sv_game")))
	_check(cfg_l.aliases.has("sv_games"), "layer 1 ships sv_games -> games")
	cfg_l.merge_alias_layer("game", "content/g/aliases.yml", "gm: game\nsv_game: map\nremove: [sv_games]\n")
	_check(cfg_l.aliases.has("gm") and cfg_l.aliases["gm"]["layer"] == "game", "the game layer ADDS an alias")
	_check(cfg_l.aliases["sv_game"]["target"] == "map" and cfg_l.aliases["sv_game"]["layer"] == "game", "the game layer REMAPS an addon alias")
	_check(not cfg_l.aliases.has("sv_games"), "the game layer REMOVES an addon alias")
	cfg_l.merge_alias_layer("server", "cfg/server/alias.yml", "sv_game: game\nremove: gm\nsv_games: games\n")
	_check(cfg_l.aliases["sv_game"]["target"] == "game" and cfg_l.aliases["sv_game"]["layer"] == "server", "the server layer overrides the game layer's remap")
	_check(not cfg_l.aliases.has("gm"), "the server layer REMOVES a game-layer alias")
	_check(cfg_l.aliases.has("sv_games") and cfg_l.aliases["sv_games"]["layer"] == "server", "and re-adds one the game layer removed")
	var own_n := 0
	for l in cfg_l.alias_lines():
		if "[server:" in l:
			own_n += 1
	_check(own_n == 2 and cfg_l.alias_lines().size() == 15, "alias_lines lists the effective table (%s)" % str(cfg_l.alias_lines()))

	var rem := TmcConfig.load_dir(_alias_cfg("remove", "sv_game: \"deathrun\"\n", "remove: [sv_game]\n"))
	_check(rem.ok and (rem.value as TmcConfig).initial_game == "" and (rem.value as TmcConfig).console_lines.has("sv_game deathrun"),
		"remove: [sv_game] in alias.yml turns the old spelling back into an ordinary (unknown) setting")
	var remap := TmcConfig.load_dir(_alias_cfg("remap", "sv_game: \"m1\"\n", "sv_game: map\n"))
	_check(remap.ok and (remap.value as TmcConfig).initial_map == "m1" and (remap.value as TmcConfig).initial_game == "", "alias.yml REMAPS sv_game to map")

	# No cap: a few hundred entries load.
	var many := ""
	for i in 500:
		many += "alias_%d: game\n" % i
	var big := TmcConfig.load_dir(_alias_cfg("many", "sv_name: \"a\"\n", many))
	_check(big.ok and (big.value as TmcConfig).aliases.size() >= 500, "no cap on the number of aliases")


func _test_config() -> void:
	_section("the configuration")

	var loaded := TmcConfig.load_dir(CFG)

	if not _check(loaded.ok, "the fixture config loads", str(loaded.error)):
		_done()
		return

	var config := loaded.value as TmcConfig

	# The operator's own names, on dot-server's own settings. Two vocabularies is a cost
	# and it is paid deliberately; what must not happen is a key that quietly reaches
	# neither.
	_check(config.server.hostname == "Fixture Server", "sv_name reaches hostname")
	_check(config.server.port == 27099, "net_port reaches the port (%d)" % config.server.port)
	_check(
		config.server.bind_address == "127.0.0.1",
		"net_bind_ip reaches the bind address"
	)
	_check(config.server.max_players == 12, "sv_maxplayers reaches max_players")

	# log.yml. Every one of these has to reach a property rather than fall through to
	# the console as an unknown cvar: the console does not have them, and it runs after
	# the boot they are most often being raised to diagnose.
	_check(config.server.log_level == "debug", "log_level reaches the level")
	_check(
		config.server.log_channel_levels.size() == 2
		and config.server.log_channel_levels[0] == "cloud=trace",
		"log_channels reaches the per-channel list"
	)
	_check(
		config.server.log_mirror_min_level == "error",
		"log_mirror_level reaches the engine-mirror threshold"
	)
	_check(config.server.log_directory == "user://fixture-logs", "log_dir reaches the directory")
	_check(config.server.log_basename == "fixture", "log_name reaches the basename")
	_check(config.server.log_max_files == 3, "log_keep reaches the retention count")
	_check(config.server.log_json, "log_json reaches the format")
	_check(
		config.server.stdin_console_pipes,
		"sv_stdin_console_pipes reaches dot-server's pipe switch",
		"a supervisor feeding commands down a pipe had no way to turn it on"
	)
	# Not `unknown.any(...)`: `unknown` is a PackedStringArray, which is its own Variant
	# type and has none of Array's higher-order methods. It is a parse error, and a parse
	# error in a suite scene makes the process HANG rather than fail.
	var log_unknown := 0
	for entry in config.unknown:
		if String(entry).contains("log_"):
			log_unknown += 1
	_check(log_unknown == 0, "and not one of them was reported unknown")
	_check(config.server.tickrate == 30, "sv_tickrate reaches the tickrate")
	_check(
		config.net.per_client_budget == 1000000,
		"net_max_bps reaches the netcode's per-client budget (%d)"
			% config.net.per_client_budget
	)
	var ceiling := config.net_ceiling()
	_check(
		ceiling.get("per_client_budget", -1) == 1000000
			and ceiling.get("per_client_packet_rate", -1) == 0
			and ceiling.get("snapshot_rate", -1) == 0
			and ceiling.get("mtu", -1) == 1100,
		"net_ceiling carries what cfg wrote, 0 meaning no limit (%s)" % str(ceiling)
	)
	_check(not ceiling.has("max_entities_per_snapshot"), "and not what it left to the default")
	_check(
		is_equal_approx(float(ceiling.get("interest_radius", -1)), 150.0)
			and int(ceiling.get("far_every", -1)) == 4
			and is_equal_approx(float(ceiling.get("far_distance", -1)), 60.0),
		"net_interest_radius, net_far_every and net_far_distance reach the ceiling (%s)" % str(ceiling)
	)
	_check(bool(ceiling.get("stagger_snapshots", false)), "net_stagger_snapshots reaches the ceiling (%s)" % str(ceiling))
	var near := config.nearest_names("net_intrest_radius")
	_check(near.has("net_interest_radius"), "an unknown setting is offered its nearest known name (%s)" % str(near))
	_check(config.nearest_names("zzzz_nothing").is_empty(), "and nothing when nothing is near")
	_check(config.public_address == "203.0.113.7", "net_public_ip is kept for the join line")
	_check(config.initial_game == "buses", "`game:` names the boot game")
	# [b]Its own key, and not a console line.[/b] `sv_map` has no cvar and no command behind it at this
	# level — the `map` command belongs to whichever game is loaded, and at read time that is none of
	# them.
	_check(config.initial_map == "fixture_map", "sv_map names the boot map (%s)"
		% config.initial_map)
	_check(
		not config.console_lines.has("sv_map fixture_map"),
		"and is not queued for a console that has no `map` to give it to"
	)
	# Same shape as `sv_map`: the host registers `sv_web_loader` after the boot that runs
	# the console lines, so a key passed through would be reported unknown and dropped.
	_check(config.web_loader == "fixture-loader", "sv_web_loader names the loader version (%s)"
		% config.web_loader)
	_check(
		not config.console_lines.has("sv_web_loader fixture-loader"),
		"and is not queued for a console that does not have the cvar yet"
	)
	_check(config.web_build == "20260101-0000", "sv_web_build is the operator's pin (%s)"
		% config.web_build)
	_check(
		not config.console_lines.has("sv_web_build 20260101-0000"),
		"and is not queued for a console that does not have the cvar yet"
	)
	_check(TmcConfig.new().web_build == "", "no pin by default: the site chooses the shell")
	_check(
		Array(config.server.tags) == ["fixture", "test"],
		"sv_tags becomes a list (%s)" % [config.server.tags]
	)

	# A name nothing recognises is handed to the console rather than refused here: modules
	# register cvars this layer cannot know about at read time, so a name-based guess would
	# refuse every setting a game contributed.
	_check(
		config.console_lines.has("bfh_round_seconds 120"),
		"an unrecognised setting is queued for the console (%s)" % [config.console_lines]
	)

	_check(config.groups.size() == 2, "groups.yml is read (%d)" % config.groups.size())
	_check(config.users.size() == 3, "and permissions.yml (%d)" % config.users.size())
	_check(
		String(TmcYaml.at(config.auth, "backend.type", "")) == "rest",
		"and auth.yml is kept whole for whoever reads it"
	)

	var missing := TmcConfig.load_dir("res://examples/fixtures/nothing-here")
	_check(
		missing.ok,
		"a directory with no files is not an error",
		"a first run has none of them"
	)
	_done()


## The sink layer, and the one list the shared settings come from.
func _test_logging() -> void:
	_section("the sink layer")

	var loaded := TmcConfig.load_dir(CFG)

	if not _check(loaded.ok, "the fixture config loads", str(loaded.error)):
		_done()
		return

	var config := loaded.value as TmcConfig

	# `on` is a BOOL in this YAML dialect, which is the whole reason the reader takes one.
	_check(config.log_router == "on", "log_router: on is read as a mode, not as a bool")
	_check(config.log.syslog_host == "10.0.0.9", "a router-only key reaches DotLogConfig")
	_check(config.log.syslog_port == 5140, "and a numeric one is coerced")
	_check(config.log.syslog_tcp, "and a boolean one")
	_check(config.log.memory_capacity == 64, "log_ring_size reaches the ring")
	_check(config.log.redact_ips, "log_redact_ips reaches the redactor")
	_check(config.log.dedupe_window_sec == 2.5, "log_dedupe_sec reaches the gate")

	var log_unknown := PackedStringArray()

	for entry in config.unknown:
		if String(entry).contains("log_"):
			log_unknown.append(String(entry))

	_check(
		log_unknown.is_empty(),
		"and not one log key fell through as unknown",
		" / ".join(Array(log_unknown))
	)

	var router := config.build_log_router()

	if not _check(router != null, "a router is built"):
		_done()
		return

	# [b]The shared settings are copied out of `server` rather than read twice.[/b] The file's
	# directory, name, rotation and JSON switch have to reach the router's file target from the SAME
	# keys that reach dot-core's sink.
	_check(
		config.log.file_directory == config.server.log_directory
			and config.log.file_basename == config.server.log_basename
			and config.log.file_json == config.server.log_json,
		"the file settings are the same ones dot-server's own sink reads"
	)
	_check(config.log.level == config.server.log_level, "and so is the level")
	_check(
		config.log.channel_levels.size() == config.server.log_channel_levels.size(),
		"and the per-channel list"
	)

	var names := PackedStringArray()

	for target: DotLogTarget in router.targets:
		names.append(target.target_name)

	_check(router.targets.size() == 3,
		"the ring, the file and syslog are all targets (%s)" % " ".join(Array(names)))
	_check(router.redactor != null, "the redactor is in front of all of them")
	_check(router.gate != null, "and so is the flood gate")

	router.free()

	# An empty service tag is worse than a missing one: it is a label with no value in
	# every dashboard, grouping every unconfigured server in the fleet together.
	_check(
		not config.log.context_tags().has("version"),
		"a tag nobody set is left out rather than sent empty"
	)

	# `off` is a supported deployment and not a degraded one: the server then makes its
	# own plain sink, exactly as it did before any of this existed.
	config.log_router = "off"
	_check(config.build_log_router() == null, "log_router: off builds nothing at all")

	_done()


func _test_replay() -> void:
	_section("the replay ring")

	var loaded := TmcConfig.load_dir(CFG)
	var config := loaded.value as TmcConfig

	_check(config.files_read.has("replay.yml"), "replay.yml is read")
	_check(config.replay_record and config.replay_keep_files == 3, "the deployment's switches reach the host")
	# By prefix, onto the addon's own config -- the table this file does not keep.
	_check(
		config.replay.ring_seconds == 30.0 and config.replay.ring_max_mib == 4
			and config.replay.keyframe_seconds == 5.0,
		"replay_ring_seconds, _ring_max_mib and _keyframe_seconds reach DotReplayConfig"
	)

	var replay_unknown := PackedStringArray()
	for entry in config.unknown:
		if String(entry).contains("replay"):
			replay_unknown.append(String(entry))
	_check(replay_unknown.is_empty(), "and not one of them fell through as unknown", " / ".join(Array(replay_unknown)))

	# The shipped defaults are the decision: on for every server, bounded, the ring only.
	var shipped := TmcConfig.new()
	_check(
		shipped.replay_enabled and not shipped.replay_record and shipped.replay_clip_on_punish
			and shipped.replay.ring_seconds > 0.0 and shipped.replay.ring_max_mib <= 32
			and shipped.replay.directory == "",
		"shipped: a bounded ring on every server, evidence on, no match files, under data/"
	)

	# A setting the addon refuses refuses the file, rather than a ring quietly not built.
	var bad := TmcConfig.new()
	bad.replay.apply_dictionary({"compression": "zip"}, "test")
	_check(
		not bad._apply_replay({}).ok,
		"a compression the addon does not have refuses replay.yml"
	)

	SelftestFiles.remove_tree(REPLAY_DIR)

	# A clock the suite moves. 30 ticks a second, the fixture's own sv_tickrate.
	var now: Array = [1000]
	var replay := TmcReplay.new()
	replay.now_ms_fn = func() -> int: return int(now[0])
	replay.game_fn = func() -> String: return "fixture_game"
	replay.roster_fn = func() -> Array: return [{"userid": 1, "name": "Ann"}]
	var built := replay.configure(config, REPLAY_DIR, 30)

	if not _check(built.ok, "a replay ring is built from the fixture", str(built.error)):
		replay.free()
		_done()
		return

	_check(
		replay.recorder.ring != null and replay.recorder.ring.max_bytes == 4 << 20
			and replay.recorder.ring.window_ticks == 30 * 30,
		"and bounded: the ring holds 30 s and at most 4 MiB"
	)
	_check(replay.directory == REPLAY_DIR.path_join("replays"), "an empty directory means <data>/replays (%s)" % replay.directory)

	var bus := DotEventBus.new()
	_check(replay.attach_bus(bus).ok, "the tap attaches to a dot-server event bus")
	_check(replay.begin().ok and replay.recorder.is_recording_to_file(), "recording, to the ring and to a match file")

	# Ninety seconds of a server: a chat line every second and one a filter blocked.
	for second in range(90):
		now[0] = 1000 + second * 1000
		replay._physics_process(0.0)
		bus.fire("player_chat", {"userid": 1, "text": "line %d" % second})
		if second == 88:
			bus.hook_pre("player_chat", func(e: DotEvent) -> void: e.cancel("filtered"))
			bus.fire("player_chat", {"userid": 1, "text": "a blocked line"})
			bus.unhook_all(self)

	var ring := replay.recorder.ring
	_check(
		ring.first_tick() > 0 and ring.last_tick() - ring.first_tick() <= (30 + 5 + 1) * 30,
		"the ring drops what fell out of its window (ticks %d-%d)" % [ring.first_tick(), ring.last_tick()]
	)

	var saved := replay.save_clip(0.0, "selftest")
	if not _check(saved.ok, "replay save writes a clip", str(saved.error)):
		replay.free()
		bus.free()
		_done()
		return

	var ev := saved.value as Dictionary
	var path := str(ev.get("replay", ""))
	_check(path.begins_with(replay.directory.path_join("clips")), "under clips/ (%s)" % path.get_file())

	var file := DotReplayFile.new()
	var opened := file.open(path)
	_check(opened.ok and file.complete and not file.truncated, "and dot-replay's own reader calls it complete", str(opened.error))
	_check(file.final_hash != "" and file.final_hash == str(ev.get("final_hash")), "whose final hash is the one the evidence names")
	_check(file.header != null and file.header.game == "fixture_game" and file.header.tick_rate == 30, "and whose header names the game and the clock")

	var all := file.read_all()
	var records: Array = all.value if all.ok else []
	var chats := 0
	var blocked := false
	var keyframe_first := false
	for i in range(records.size()):
		var r := records[i] as DotReplayRecord
		if i == 0:
			keyframe_first = r.is_keyframe()
		if r.channel == &"events":
			var v: Variant = r.value()
			if v is Dictionary and str((v as Dictionary).get("name")) == "player_chat":
				chats += 1
				if (v as Dictionary).get("cancelled", false):
					blocked = true
	_check(keyframe_first, "the clip begins with a roster keyframe")
	_check(chats >= 25 and chats <= 45, "and holds the last ~30 s of chat, not all 90 (%d lines)" % chats)
	_check(blocked, "including the line a filter blocked")

	# Evidence: one clip per incident, not one per punishment.
	var first := replay.evidence_clip("ban cheater")
	var second := replay.evidence_clip("kick cheater")
	# The PATH and the file count, not the hash: two clips of the same ring are the same
	# bytes and hash alike, so a hash comparison passes with the cooldown taken out.
	_check(
		first.ok and second.ok and str((first.value as Dictionary).get("replay")) == str((second.value as Dictionary).get("replay"))
			and SelftestFiles.count_replays(replay.directory.path_join("evidence")) == 1,
		"a ban and its own kick share one evidence clip, one file"
	)
	_check(str((first.value as Dictionary).get("replay", "")).contains("/evidence/"), "and it goes under evidence/, apart from manual clips")

	var ban := {"target": "backbone:9", "reason": "cheating"}
	replay._on_ban_added(ban)
	_check(
		ban.get("evidence") is Dictionary and str((ban["evidence"] as Dictionary).get("final_hash", "")) != "",
		"a dot-server ban record carries the clip's final hash"
	)

	var attached_before := int(replay.describe()["evidence_attached"])
	replay._on_audit({"action": "ban", "target": "x"})
	replay._on_audit({"action": "kick", "target": "Ann"})
	_check(
		int(replay.describe()["evidence_attached"]) == attached_before + 1,
		"an admin's kick is answered with an audit line; other audit actions are not"
	)

	# dot-moderation's path: through the registry service's own signal, and stored again.
	# Loaded by path, because this project does not link it for its own scripts.
	var mod_script: Variant = load("res://addons/dot_moderation/runtime/dot_moderation_manager.gd") \
		if ResourceLoader.exists("res://addons/dot_moderation/runtime/dot_moderation_manager.gd") else null
	var store_script: Variant = load("res://addons/dot_moderation/store/dot_punishment_store_file.gd") \
		if mod_script != null else null
	if mod_script == null or store_script == null:
		_check(true, "dot-moderation is not linked in this build; its evidence path is skipped")
		_check(true, "(skipped)")
	else:
		now[0] += 20000   # past the cooldown, so this is a new clip
		replay._physics_process(0.0)
		var manager: Object = (mod_script as GDScript).new()
		var store_path := REPLAY_DIR.path_join("moderation.json")
		manager.set("store", (store_script as GDScript).new(store_path))
		replay.watch_moderation(manager)
		var issued: DotResult = await manager.call("issue", 0, "uid:backbone:9", "aimbot", "console", 0)
		# The re-put is awaited inside the handler; one frame lets it land.
		await get_tree().process_frame
		var p: Object = issued.value if issued.ok else null
		var pev: Dictionary = p.get("evidence") if p != null else {}
		_check(str(pev.get("final_hash", "")) != "", "a dot-moderation ban carries the clip's final hash")
		var stored := FileAccess.get_file_as_string(store_path)
		_check(
			stored.contains(str(pev.get("final_hash", "-"))),
			"and the punishment store on disk has it, written again after the ban"
		)
		replay.watch_moderation(null)
		manager.free()

	# Bounded on disk: three files a directory, the oldest going first.
	for i in range(5):
		replay.save_clip(0.0, "burst %d" % i)
	_check(
		SelftestFiles.count_replays(replay.directory.path_join("clips")) <= 3,
		"clips/ keeps replay_keep_files and no more (%d)" % SelftestFiles.count_replays(replay.directory.path_join("clips"))
	)

	# A game change finishes the match file and starts the next.
	var match_path := replay.recorder.writer.path if replay.recorder.writer != null else ""
	replay._on_game_loaded("next")
	var finished := DotReplayFile.new()
	_check(
		match_path != "" and finished.open(match_path).ok and finished.complete,
		"a game change finishes the match file, complete"
	)

	replay.tap.detach()
	replay.recorder.stop()
	replay.free()
	bus.free()
	_done()


## `cfg/game/<game>/`: the current id, the migration from a retired one, and a base file for every game.
func _test_game_cfg_dirs() -> void:
	_section("cfg/game/<game>/ is the game's current id; every game gets a base config")
	var root := ProjectSettings.globalize_path("user://selftest_game_cfg")
	DotPaths.remove_tree(root)

	# Every game the build carries.
	var scanned := TmcContent.scan("res://content")
	var content: TmcContent = scanned.value if scanned.ok else null

	if not _check(content != null and not content.games.is_empty(), "the content index reads"):
		_done()
		return

	var names := {}

	for descriptor in content.games:
		names[TmcGameConfig.cfg_id(descriptor)] = descriptor.game_id

	_check(names.has("game-fatal-contact") and not names.has("game-arena") and not names.has("fatalcontact"),
		"Fatal Contact's config directory is game-fatal-contact", str(names.keys()))
	_check(names.size() == content.games.size(), "no two games share a config directory", "%d dirs for %d games" % [names.size(), content.games.size()])

	var written := TmcGameCfgDirs.write_base_configs(root, content)
	var missing := PackedStringArray()

	for descriptor in content.games:
		var name := TmcGameConfig.cfg_id(descriptor)
		var path := "%s/game/%s/server.yml" % [root, name]

		if not FileAccess.file_exists(path):
			missing.append(name)
		elif FileAccess.file_exists(path):
			var parsed := TmcYaml.parse_file(path)

			if not parsed.ok:
				missing.append(name + " (unreadable)")

	_check(missing.is_empty(), "every game (%d) gets a readable base cfg/game/<id>/server.yml on a cfg/ with none" % content.games.size(), str(missing))
	_check(written.size() == content.games.size(), "first boot writes one for each (%d)" % written.size(), str(written.size()))

	var text := FileAccess.get_file_as_string("%s/game/game-fatal-contact/server.yml" % root)
	_check(text.contains("# cvars:") and text.contains("fc_scorelimit") and not text.contains("\n  fc_"),
		"a base config lists the game's cvars, all commented out")
	var live := PackedStringArray()

	for line in text.split("\n"):
		if line.strip_edges() != "" and not line.begins_with("#"):
			live.append(line)

	_check(live.is_empty(), "and holds no live setting that could pin a default", str(live))

	# Never overwritten.
	var marker := FileAccess.open("%s/game/game-fatal-contact/server.yml" % root, FileAccess.WRITE)
	marker.store_string("max_players: 7\n")
	marker.close()
	_check(TmcGameCfgDirs.write_base_configs(root, content).is_empty()
		and FileAccess.get_file_as_string("%s/game/game-fatal-contact/server.yml" % root) == "max_players: 7\n",
		"a second run writes nothing and keeps an owner's file")
	_retired_cfg_dirs(content, root)
	_done()


## A retired directory moves whole and is still the game's settings; the shell migration names the same ones.
func _retired_cfg_dirs(content: TmcContent, root: String) -> void:
	# A retired directory moves, whole, and is still the game's settings.
	var old := ProjectSettings.globalize_path("user://selftest_game_cfg_old")
	DotPaths.remove_tree(old)
	DirAccess.make_dir_recursive_absolute(old + "/game/game-arena")
	DirAccess.make_dir_recursive_absolute(old + "/server/game/game-final-contact/sub")
	DirAccess.make_dir_recursive_absolute(old + "/game/game-fatal-contact")
	_put(old + "/game/game-arena/server.yml", "max_players: 9\n")
	_put(old + "/game/game-arena/extra.yml", "kept: 1\n")
	_put(old + "/game/game-fatal-contact/server.yml", "max_players: 5\n")
	_put(old + "/server/game/game-final-contact/server.yml", "max_players: 11\n")
	_put(old + "/server/game/game-final-contact/sub/a.yml", "a: 1\n")
	var lines := TmcGameCfgDirs.migrate_retired_dirs(old)
	_check(lines.size() == 2, "one line per migrated directory", str(lines))
	_check(not DirAccess.dir_exists_absolute(old + "/game/game-arena")
		and FileAccess.get_file_as_string(old + "/game/game-fatal-contact/extra.yml") == "kept: 1\n",
		"a file the current directory lacks is moved into it")
	_check(FileAccess.get_file_as_string(old + "/game/game-fatal-contact/server.yml") == "max_players: 5\n"
		and FileAccess.get_file_as_string(old + "/game/game-fatal-contact/server.yml.from-game-arena") == "max_players: 9\n",
		"a differing file is kept beside it, not lost and not replacing it")
	_check(FileAccess.get_file_as_string(old + "/server/game/game-fatal-contact/server.yml") == "max_players: 11\n"
		and FileAccess.file_exists(old + "/server/game/game-fatal-contact/sub/a.yml"),
		"an operator directory with no successor is renamed whole, subdirectories too")
	_check(TmcGameCfgDirs.migrate_retired_dirs(old).is_empty(), "a second run has nothing to do")

	# Until migrated, the old name still reaches the game.
	var cvars := TmcGameConfig.new()
	var fc := content.find("fatalcontact")
	var legacy := {"game-arena": {"marker": 1}}
	_check(fc != null and TmcGameConfig.section_in(legacy, fc).get("marker", 0) == 1,
		"a section still under game-arena applies to Fatal Contact until it is migrated")
	_check(cvars != null and fc != null and TmcGameConfig.section_in({"game-fatal-contact": {"marker": 2}, "game-arena": {"marker": 1}}, fc).get("marker", 0) == 2,
		"and the section under the current name wins")

	# The shell migration in tools/cfg_sync.sh names the same directories.
	var sync := FileAccess.get_file_as_string("res://tools/cfg_sync.sh")
	var drift := PackedStringArray()

	for retired: String in TmcGameCfgDirs.RETIRED_DIRS:
		if not sync.contains("%s:%s" % [retired, TmcGameCfgDirs.RETIRED_DIRS[retired]]):
			drift.append(retired)

	_check(drift.is_empty(), "tools/cfg_sync.sh renames every retired directory the host does", str(drift))
	DotPaths.remove_tree(root)
	DotPaths.remove_tree(old)


func _test_friends() -> void:
	_section("the friends client")

	# The site as it is today: every route a bare 404.
	var calls: Array = []
	var gone := DotFriendsBackendApp.new()
	# Answered a frame later, like a network, so the presence post and both polls are all
	# in flight when the first 404 lands -- which is what "once" has to survive.
	gone.request_fn = func(method: String, path: String, _body: Dictionary) -> DotResult:
		calls.append("%s %s" % [method, path])
		await get_tree().process_frame
		return DotResult.failure(DotError.from_http(404, ""))
	var offs: Array = []
	var f404 := TmcFriends.build(gone)
	f404.switched_off.connect(func(why: String) -> void: offs.append(why))
	f404.client.set_process(false)
	add_child(f404)
	f404.client.advance(1.0)
	for i in range(3):
		await get_tree().process_frame
	_check(f404.off and f404.client.backend == null, "a 404 from the site turns friends off")
	_check(
		offs.size() == 1 and calls.size() >= 2,
		"once, with %d requests in flight (%d)" % [calls.size(), offs.size()]
	)
	var before := calls.size()
	f404.client.advance(120.0)
	await get_tree().process_frame
	_check(calls.size() == before, "and nothing is asked again (%d then %d)" % [before, calls.size()])
	_check(f404.describe_lines()[0].begins_with("friends: off"), "describe says so")
	f404.queue_free()

	# A 404 the site EXPLAINED is a refusal, not missing routes.
	var keyed := DotFriendsBackendApp.new()
	keyed.request_fn = func(_m: String, _p: String, _b: Dictionary) -> DotResult:
		return DotResult.failure(DotError.from_http(404, '{"ok":false,"code":"friends.request.deny.notFound","message":"Member not found."}'))
	var fkeyed := TmcFriends.build(keyed)
	fkeyed.client.set_process(false)
	add_child(fkeyed)
	fkeyed.client.advance(1.0)
	for i in range(3):
		await get_tree().process_frame
	_check(not fkeyed.off, "a keyed 404 does not switch friends off")
	fkeyed.queue_free()

	# Two friends on the site's own rules, in process.
	var hub := DotFriendsLocalHub.new()
	# Members first: the hub, like the site, refuses a request to nobody it knows.
	var alice_backend := hub.as_user("alice", "Alice")
	var bob_backend := hub.as_user("bob", "Bob")
	hub.send_request("alice", "bob")
	hub.send_request("bob", "alice")   # asking somebody who asked you accepts them
	var cfg := DotFriendsConfig.new()
	cfg.presence_debounce_sec = 0.1
	var alice := TmcFriends.build(alice_backend, cfg)
	alice.client.set_process(false)
	add_child(alice)

	alice.on_playing("203.0.113.7:27015", "12", "Fatal Contact", "Fixture Server")
	alice.client.advance(0.5)
	await get_tree().process_frame
	var seen := hub.presence_seen_by("bob", "alice")
	_check(seen.status == DotPresence.Status.IN_GAME and seen.server_id == 12, "presence reflects a connect: in game, on server 12")
	_check(seen.joinable and seen.detail == "Playing Fatal Contact on Fixture Server", "joinable, with where (%s)" % seen.detail)

	alice.on_disconnected()
	alice.client.advance(0.5)
	await get_tree().process_frame
	seen = hub.presence_seen_by("bob", "alice")
	_check(
		seen.status == DotPresence.Status.ONLINE and seen.server_id == 0 and not seen.joinable,
		"and a disconnect: back on the menu, not followable"
	)

	# Following: the party when there is one, a server only where this shell has been.
	alice.on_playing("203.0.113.7:27015", "12", "Fatal Contact", "Fixture Server")
	alice.client.advance(0.5)
	await get_tree().process_frame
	var dialled: Array = []
	var bob := TmcFriends.build(bob_backend, cfg)
	bob.client.set_process(false)
	bob.connect_address_fn = func(address: String) -> void: dialled.append(address)
	add_child(bob)
	await bob.client.refresh()
	var refused: DotResult = await bob.join("alice")
	_check(
		not refused.ok and refused.error.detail == "friends.join.deny.unsupported",
		"a server this shell has never been on is refused honestly, with the site's key"
	)
	bob.on_playing("203.0.113.7:27015", "12", "Fatal Contact", "Fixture Server")
	var followed: DotResult = await bob.join("alice")
	_check(followed.ok and dialled == ["203.0.113.7:27015"], "one it has is dialled at the address it knows (%s)" % [dialled])

	var gone_now: DotResult = await alice.go_offline()
	seen = hub.presence_seen_by("bob", "alice")
	_check(gone_now.ok and not seen.is_online(), "go_offline() on quit: offline to friends at once")

	alice.queue_free()
	bob.queue_free()
	_done()


func _test_layered_cfg() -> void:
	_section("party, groups and security through the addons' layered loaders")
	var root := "user://selftest_layered_cfg"
	DotPaths.remove_tree(root)
	DotCfgLegacy.reset()
	_put(root + "/party.yml", "party_enabled: false\nparty_seat_hold_sec: 30\nparty_reserve_empty_only: true\n")
	_put(root + "/security.yml", "sec_enabled: true\nsec_caps_ratio: 0.5\nac_max_speed: 33.0\nsec_nonsense: 1\n")
	_put(root + "/groups.yml", "groups:\n  a:\n    permissions: [x]\n")
	var loaded := TmcConfig.load_dir(root)
	_check(loaded.ok, "the flat files still load (shim)")
	var flat: TmcConfig = loaded.value
	_check(not flat.party_enabled and is_equal_approx(flat.party.seat_hold_sec, 30.0) and flat.party_policy.empty_only, "party.yml: the deployment's switch, the addon's key and the policy")
	_check(flat.security.enabled and is_equal_approx(flat.security.caps_ratio, 0.5) and is_equal_approx(flat.anticheat.max_horizontal_speed, 33.0), "security.yml reaches both configs")
	_check("\n".join(flat.console_lines).contains("sec_nonsense"), "a sec_ key the addons do not know falls through as before")
	_check(flat.groups.has("a"), "groups.yml through DotAdminCfg")
	_put(root + "/addons/dot_party/party.yml", "party_seat_hold_sec: 40\n")
	_put(root + "/server/addons/dot_party/party.yml", "party_seat_hold_sec: 50\n")
	loaded = TmcConfig.load_dir(root)
	_check(loaded.ok and is_equal_approx((loaded.value as TmcConfig).party.seat_hold_sec, 50.0), "the operator's cfg/server/addons tier wins over addons and the flat file")
	_put(root + "/server/addons/dot_server/groups.yml", "groups:\n  b:\n    permissions: [y]\n")
	var g: TmcConfig = TmcConfig.load_dir(root).value
	_check(g.groups.has("b") and not g.groups.has("a"), "a new-layout groups.yml wins whole over the flat file")
	_put(root + "/rcon.yml", "rcon_password: \"flat-password\"\nrcon_port: 7001\n")
	var rc: TmcConfig = TmcConfig.load_dir(root).value
	_check(rc.server.rcon_password == "flat-password" and rc.server.rcon_port == 7001, "a flat rcon.yml is still read")
	_put(root + "/addons/dot_console/rcon.yml", "rcon_password: \"addon-password\"\n")
	rc = TmcConfig.load_dir(root).value
	_check(rc.server.rcon_password == "addon-password", "the addon folder's rcon.yml wins over the flat one")
	_put(root + "/server/addons/dot_console/rcon.yml", "rcon_password: \"operator-password\"\nrcon_allowed: [\"10.0.0.1\"]\n")
	rc = TmcConfig.load_dir(root).value
	_check(rc.server.rcon_password == "operator-password", "the operator tier is the strongest rcon.yml")
	_check(rc.server.rcon_allowed_addresses == PackedStringArray(["10.0.0.1"]), "and its other keys layer over the addon's")
	_put(root + "/server/addons/dot_console/rcon.yml", "rcon_password: \"\"\n")
	rc = TmcConfig.load_dir(root).value
	_check(rc.server.rcon_password == "", "an empty operator password switches RCON off, whatever the weaker tiers hold")
	_put(root + "/addons/dot_vote/vote.yml", "vote_exclude: [maze]\n")
	var vc: TmcConfig = TmcConfig.load_dir(root).value
	_check(vc.vote_exclude.has("maze"), "vote.yml is read from addons/dot_vote/")
	_put(root + "/addons/dot_core/loading.yml", "loading_title: Hello\n")
	_put(root + "/server/addons/dot_core/loading.yml", "loading_title: Operator\n")
	var ld := TmcConfig.merged_file("dot-core", "loading.yml", root)
	_check(ld.ok and String((ld.value as Dictionary).get("loading_title", "")) == "Operator", "loading.yml layers, the operator tier last")
	DotCfgLegacy.reset()
	_put(root + "/addons.yml", "defaults:\n  add: [dev/extra@1.2.0]\n")
	var old_packs := TmcAddonsConfig.load_from(root, root + "/data")
	_check(old_packs.ok and (old_packs.value as TmcAddonsConfig).defaults_add == PackedStringArray(["dev/extra@1.2.0"]),
		"an old cfg/addons.yml is still read for packs", str(old_packs.error))
	_check(DotCfgLegacy.warned_count() == 1, "and warns once")
	_put(root + "/content/addons.yml", "defaults:\n  add: [dev/new@2.0.0]\nentries: [dot-core]\n")
	var new_packs := TmcAddonsConfig.load_from(root, root + "/data")
	_check(new_packs.ok and (new_packs.value as TmcAddonsConfig).defaults_add == PackedStringArray(["dev/new@2.0.0"]),
		"cfg/content/addons.yml wins whole when both exist, and shares its file with the download list", str(new_packs.error))
	_put(root + "/games.yml", "rotation: old\n")
	var legacy_rot := DotCfgLegacy.find(root + "/" + TmcGameRotation.LEGACY_FILE, root + "/" + TmcGameRotation.FILE)
	_check(legacy_rot == root + "/games.yml", "cfg/games.yml is found through the shim")
	_put(root + "/content/games.yml", "rotation: main\ngames: [a/b]\n")
	_check(DotCfgLegacy.find(root + "/games.yml", root + "/" + TmcGameRotation.FILE) == root + "/content/games.yml",
		"cfg/content/games.yml wins when both exist")
	var rot := TmcGameRotation.load_file(root + "/content/games.yml")
	_check(rot.ok and (rot.value as TmcGameRotation).has_rotations(), "and reads as a rotation")
	# The same file as a download list: rotation keys alone are not a list, entries are.
	var shipped := TmcContentLists.load_list("games", root, "res://content-lists")
	_check(shipped.ok and (shipped.value as Array).size() > 1, "a rotation-only content/games.yml leaves the shipped download list alone")
	_put(root + "/content/games.yml", "rotation: main\nentries: [only-this]\n")
	var listed := TmcContentLists.load_list("games", root, "res://content-lists")
	_check(listed.ok and (listed.value as Array).size() == 1 and listed.value[0]["id"] == "only-this",
		"a content/games.yml with entries replaces it, beside the rotation keys")
	var rot2 := TmcGameRotation.load_file(root + "/content/games.yml")
	_check(rot2.ok and (rot2.value as TmcGameRotation).spec.get("rotations", {}).size() >= 0, "and still reads as a rotation")

	# server.yml: cfg/server/server.yml, the flat file through the shim, new wins whole, extras applied.
	DotCfgLegacy.reset()
	_put(root + "/server.yml", "sv_name: Flat\nsv_maxplayers: 5\n")
	var flat_srv: TmcConfig = TmcConfig.load_dir(root).value
	_check(flat_srv.server.hostname == "Flat" and flat_srv.server.max_players == 5, "the flat cfg/server.yml is still read")
	_check(DotCfgLegacy.warned_count() >= 1, "and warns")
	_put(root + "/server/server.yml", "sv_name: Operator\n")
	var nested: TmcConfig = TmcConfig.load_dir(root).value
	_check(nested.server.hostname == "Operator" and nested.server.max_players != 5, "cfg/server/server.yml wins whole over the flat file")
	_put(root + "/server/more.yml", "sv_maxplayers: 7\n")
	var extra: TmcConfig = TmcConfig.load_dir(root).value
	_check(extra.server.max_players == 7 and extra.server.hostname == "Operator", "another cfg/server/*.yml adds keys")

	# overrides: cfg/server/content/overrides.yml, the flat content.yml through the shim, new wins whole.
	DotCfgLegacy.reset()
	_put(root + "/content.yml", "games:\n  game-x:\n    max_players: 3\n")
	var old_ov := TmcGameConfig.load_from(root, root + "/data")
	_check(old_ov.ok and (old_ov.value as TmcGameConfig).games.get("game-x", {}).get("max_players") == 3, "cfg/content.yml is still read through the shim")
	_put(root + "/server/content/overrides.yml", "games:\n  game-x:\n    max_players: 4\n")
	var new_ov := TmcGameConfig.load_from(root, root + "/data")
	_check(new_ov.ok and (new_ov.value as TmcGameConfig).games.get("game-x", {}).get("max_players") == 4, "cfg/server/content/overrides.yml wins whole")
	_put(root + "/game/game-x/server.yml", "sv_maxplayers: 6\ncvars:\n  a: \"1\"\n")
	_put(root + "/server/game/game-x/server.yml", "sv_maxplayers: 9\n")
	var tiers := TmcGameConfig.load_from(root, root + "/data")
	var gx: Dictionary = (tiers.value as TmcGameConfig).games.get("game-x", {}) if tiers.ok else {}
	_check(gx.get("max_players") == 9 and gx.get("cvars", {}).get("a") == "1",
		"cfg/server/game/<g>/server.yml layers over the shipped cfg/game/<g>/server.yml", str(gx) + (tiers.error.message if not tiers.ok else ""))

	DotPaths.remove_tree(root)
	DotAddonConfig.config_root = ""
	_done()


func _put(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _test_admins() -> void:
	_section("groups and permissions")

	var loaded := TmcConfig.load_dir(CFG)
	var config := loaded.value as TmcConfig
	var built := TmcAdmins.from(config.groups, config.users)

	if not _check(built.ok, "the permission source builds", str(built.error)):
		_done()
		return

	var admins := built.value as TmcAdmins

	_check(admins.user_count() == 3, "with every user")

	# A uid key, which contains a colon. Read naively it would be the key `backbone` with
	# a value, and every command relayed from the website would grant nothing to anybody.
	var by_uid := admins.lookup(_identity("backbone:cmrhhfvmr00000jrpmj4o0ss4"))
	_check(by_uid.ok, "a uid key survives the colon in it")
	_check(
		by_uid.ok and PackedStringArray(by_uid.value["flags"]).has("kick"),
		"with the group it names, rather than a truncated key that matches nothing"
	)
	_check(
		Array(admins.group_names()) == ["admin", "owner"],
		"and both groups (%s)" % [admins.group_names()]
	)

	var owner := admins.lookup(_identity("boss"))
	_check(owner.ok, "an owner is found")
	_check(
		owner.ok and PackedStringArray(owner.value["flags"]).has(DotAdminFlags.ROOT),
		"and is_root becomes the root flag",
		"expanding it into a list here would stop covering a flag added later"
	)
	_check(owner.ok and int(owner.value["immunity"]) == 100, "with its immunity")

	var admin := admins.lookup(_identity("helper"))
	_check(admin.ok, "a group member is found")
	_check(
		admin.ok and PackedStringArray(admin.value["flags"]).has("kick"),
		"and holds the group's flags"
	)
	_check(
		admin.ok and PackedStringArray(admin.value["flags"]).has("spawn_npc"),
		"plus their own extra one",
		"sources merge rather than first-match-wins, and so does a user's own list"
	)
	_check(
		admin.ok and int(admin.value["immunity"]) == 42,
		"and an explicit immunity beats the group's (%d)"
			% (int(admin.value["immunity"]) if admin.ok else -1)
	)

	# Case-insensitive, because an operator typing a name into a config file and a player
	# typing one into a client will not agree about capitalisation.
	_check(admins.lookup(_identity("BOSS")).ok, "a name matches whatever its case")
	_check(not admins.lookup(_identity("nobody")).ok, "and a stranger is not listed")
	_check(not admins.lookup(null).ok, "nor is a null identity, which is not a crash")

	# A permission name that is not a flag is REPORTED, never refused. Refusing would be worse: a game
	# defines its own flags -- the fixture's `spawn_npc` is one -- and this file cannot know them.
	_check(
		Array(admins.unknown_flags).has("spawn_npc"),
		"a name that is not a flag is reported (%s)" % [admins.unknown_flags]
	)
	_check(
		not Array(admins.unknown_flags).has("kick"),
		"and a real one is not, which is the half that makes the warning worth reading"
	)

	var typo := TmcAdmins.from(
		{"staff": {"permissions": ["kick", "change", "announce"]}},
		{"one": "staff", "two": "staff"}
	)
	_check(typo.ok, "a group with a misspelled permission still builds")
	var typo_source := typo.value as TmcAdmins
	_check(
		Array(typo_source.unknown_flags).has("change")
			and Array(typo_source.unknown_flags).has("announce"),
		"both misspellings are named (%s)" % [typo_source.unknown_flags]
	)
	# Deduplicated: one misspelling in a group is repeated by every user in it, and a
	# warning naming `change` three times is one nobody reads to the end of.
	_check(
		typo_source.unknown_flags.size() == 2,
		"once each, however many people are in the group (%d)"
			% typo_source.unknown_flags.size()
	)
	_check(
		Array(typo_source.lookup(_identity("one")).value["flags"]).has("kick"),
		"and the flags that ARE real still work, so a typo costs one permission and not all of them"
	)
	_done()


## Something with the shape dot-server hands a source: `uid`, `username`, `display_name`.
func _identity(name: String) -> Object:
	var identity := DotGuestIdentity.new()
	identity.uid = "guest:%s" % name
	identity.username = name
	identity.display_name = name
	return identity


## `TMC_GAMES` entries: the release-tag spelling, and two owners with one name.
func _test_game_refs() -> void:
	_section("games list entries")
	_game_ref_entries()
	var installer := preload("res://tools/install_games.gd")
	var base := {"kind": "pack", "scene": "scenes/server.tscn", "content_id": "gamemann/demo", "version": "1.0.0"}
	_game_ref_dependencies(installer, base)
	await _game_ref_pointers(installer)
	_game_ref_moved_pointers(installer)
	_game_ref_maps(installer, base)
	_done()


## Games list entries: spellings, retired ids and same-named games of two owners.
func _game_ref_entries() -> void:

	_check(TmcGameRef.parse("gamemann/mg-buses@v0.1.2")["version"] == "0.1.2",
		"@v0.1.2 asks for the pack version 0.1.2, not a v0.1.2/ directory")
	_check(TmcGameRef.parse("gamemann/mg-buses@0.1.2")["version"] == "0.1.2",
		"@0.1.2 is unchanged")
	_check(TmcGameRef.parse("gamemann/mg-buses@latest")["version"] == "",
		"@latest is the newest version")

	# Retired ids: a panel still configured with the old name installs and offers the current one.
	var retired := TmcGameRef.parse("gamemann/game-final-contact@1.0.0")
	_check(retired["id"] == "gamemann/game-fatal-contact" and retired["dir"] == "gamemann/game-fatal-contact",
		"game-final-contact is installed as game-fatal-contact")
	_check(retired["version"] == "" and retired["retired"] == "gamemann/game-final-contact",
		"a pin on a retired id is dropped (the old id published no versions) and the old id is kept to log")
	_check(TmcGameRef.parse("gamemann/game-fatal-contact")["retired"] == "",
		"a current id is not marked retired")
	_check(TmcGameRef.dirs_in("gamemann/game-arena, gamemann/game-airdrift@1.2.0, game-arena")
			== PackedStringArray(["gamemann/game-fatal-contact", "gamemann/game-airdrift", "game-arena"]),
		"the host's filter aliases the same ids the installer does; a bare local name is left alone")
	_check(TmcGameRef.qualify_map("gamemann/arena-dm-maps/*", "")["collection"] == "gamemann/fc-dm-maps",
		"a retired collection wildcard reads the current collection")
	_check(TmcGameRef.parse("alice/demo@vnext")["version"] == "vnext",
		"a v that is not followed by a digit is part of the version")
	_check(TmcGameRef.parse("asher/game-testing@v1.0.0")["dir"] == "asher/game-testing",
		"a published game's id is owner/name, with no version")
	_check(TmcGameRef.dirs_in("asher/game-testing@v1.0.0, bob/game-testing, arena")
			== PackedStringArray(["asher/game-testing", "bob/game-testing", "arena"]),
		"a fork and its original are two games in one list")

	# Two owners' same-named games, installed side by side, both scan.
	var root := "user://selftest_forks"
	DotPaths.remove_tree(root)
	var fork_yml := "kind: pack\nscene: scenes/server.tscn\ncontent_id: %s\nversion: 1.0.0\n"
	DotPaths.write_text(root + "/asher/game-testing/game.yml", fork_yml % "asher/game-testing")
	DotPaths.write_text(root + "/bob/game-testing/game.yml", fork_yml % "bob/game-testing")
	DotPaths.write_text(root + "/gamemann/game-airdrift/game.yml", fork_yml % "gamemann/game-airdrift")
	DotPaths.write_text(root + "/arena/game.yml", "kind: pack\nscene: s.tscn\ncontent_id: arena\n")
	DirAccess.make_dir_recursive_absolute(root + "/emptyowner")
	var forks := TmcContent.scan(root)
	var index: TmcContent = forks.value if forks.ok else null
	_check(index != null and index.ids() == PackedStringArray(
			["arena", "asher/game-testing", "bob/game-testing", "gamemann/game-airdrift"]),
		"content/<owner>/<name>/ scans as owner/name beside a built-in's content/<name>/",
		str(index.ids()) if index != null else str(forks))
	_check(index != null and index.find("game-testing") == null
			and index.find("bob/game-testing") != null,
		"a name two owners share needs the owner; the full id always works")
	_check(index != null and index.find("game-airdrift") != null
			and index.find("game-airdrift").game_id == "gamemann/game-airdrift",
		"a name only one owner has still works on its own (TMC_GAME=game-airdrift)")
	DotPaths.remove_tree(root)


## Dependencies pinned by the installer and read into the descriptor.
func _game_ref_dependencies(installer: Variant, base: Dictionary) -> void:
	var yml := "name: X\ndependencies:\n  - gamemann/surf_mesa@latest\n# kept\nscene: s.tscn\n"
	var stamped: DotResult = installer.stamp_dependencies(yml, PackedStringArray(["gamemann/surf_mesa@1.2.0"]))
	_check(stamped.ok and str(stamped.value).contains("  - gamemann/surf_mesa@1.2.0\n# kept\nscene: s.tscn"),
		"the installer pins a dependency in place and keeps what follows it", str(stamped))
	var added: DotResult = installer.stamp_dependencies("name: X\n", PackedStringArray(["a/b@1.0.0"]))
	_check(added.ok and str(added.value).ends_with("dependencies:\n  - a/b@1.0.0"),
		"and adds the list to a descriptor that had none", str(added))

	# A version kept because the newest needs newer addons must be one that mounts. Prop Hunt 0.1.15
	# was signed before the site stamped runs_code: provides without it, 54 .gd files.
	var stale := DotCloudManifest.new()
	stale.provides = {"schema": 1, "kinds": ["game"]}
	var gd := DotCloudFile.new()
	gd.path = "scripts/ph_world.gd"
	stale.files.append(gd)
	var declared := DotCloudManifest.new()
	declared.provides = {"schema": 1, "kinds": ["game"], "runs_code": true}
	declared.files.append(gd)
	var data_only := DotCloudManifest.new()
	data_only.provides = {"schema": 1, "kinds": ["game"]}
	var tex := DotCloudFile.new()
	tex.path = "textures/a.png"
	data_only.files.append(tex)
	var legacy := DotCloudManifest.new()
	legacy.files.append(gd)
	_check(str(installer.refused_at_mount(stale)).contains("runs_code")
			and str(installer.refused_at_mount(stale)).contains("scripts/ph_world.gd")
			and installer.refused_at_mount(declared) == "" and installer.refused_at_mount(data_only) == ""
			and installer.refused_at_mount(legacy) == "",
		"a kept pack that ships code without declaring runs_code is named unusable; declared, data-only and pre-provides packs are not",
		str(installer.refused_at_mount(stale)))

	var pinned := base.duplicate()
	pinned["dependencies"] = ["gamemann/surf_mesa@1.2.0", "modcommunity/dot-ui@v0.1.2"]
	var built: DotResult = TmcContent.new()._build("demo", pinned)
	_check(built.ok and PackedStringArray((built.value as DotGameDescriptor).dependencies)
			== PackedStringArray(["gamemann/surf_mesa@1.2.0", "modcommunity/dot-ui@0.1.2"]),
		"a pinned dependency reaches the descriptor, @v spelling and all",
		str(built.value.dependencies) if built.ok else str(built))
	var loose := base.duplicate()
	loose["dependencies"] = ["gamemann/surf_mesa@latest"]
	_check(not TmcContent.new()._build("demo", loose).ok,
		"an unresolved @latest is refused, not resolved per join")
	var bare := base.duplicate()
	bare["dependencies"] = ["surf_mesa"]
	_check(not TmcContent.new()._build("demo", bare).ok,
		"a dependency with no owner is refused")


## The latest.json pointer, through the pack API and the CDN, and after a restart.
func _game_ref_pointers(installer: Variant) -> void:
	# Pack API first, latest.json after: a fake transport that records what was asked.
	var asked := []
	var api_up := {"v": "2.0.0"}
	var transport := func(url: String) -> DotResult:
		asked.append(url)
		if url.contains("/api/packs/latest"):
			if api_up["v"] == "":
				return DotResult.fail(DotError.CODE_IO, "HTTP 404")
			return DotResult.success({"version": api_up["v"]})
		if url.ends_with("/a/b/latest.json"):
			return DotResult.success({"version": "1.0.0"})
		return DotResult.fail(DotError.CODE_IO, "<Error><Code>AccessDenied</Code></Error>")
	var cdn := PackedStringArray(["https://cdn.example/content"])
	var viaapi: DotResult = await installer.pointer_from("a/b", "https://site.example/", cdn, 0, transport)
	_check(viaapi.ok and viaapi.value["version"] == "2.0.0" and asked.size() == 1
			and str(asked[0]) == "https://site.example/api/packs/latest?id=a%2Fb",
		"the pack API answers first and latest.json is not asked", str(asked))
	api_up["v"] = ""
	asked.clear()
	var viacdn: DotResult = await installer.pointer_from("a/b", "https://site.example", cdn, 0, transport)
	_check(viacdn.ok and viacdn.value["version"] == "1.0.0" and asked.size() == 2,
		"a 404 from the pack API falls back to latest.json", str(asked))
	asked.clear()
	var site_dir := "user://site_from_config"
	DirAccess.make_dir_recursive_absolute(site_dir)
	_check(installer.site_from_config(site_dir) == "", "no auth.yml names no site")
	var af := FileAccess.open(site_dir + "/auth.yml", FileAccess.WRITE)
	af.store_string("strategy: ticket\nbackbone_url: \"https://site.example\"\n")
	af.close()
	_check(installer.site_from_config(site_dir) == "https://site.example", "auth.yml backbone_url is the install site", installer.site_from_config(site_dir))
	DirAccess.remove_absolute(site_dir + "/auth.yml")
	var nosite: DotResult = await installer.pointer_from("a/b", "", cdn, 0, transport)
	_check(nosite.ok and asked.size() == 1 and str(asked[0]).ends_with("/a/b/latest.json"),
		"with no site set only latest.json is asked", str(asked))
	var both_down: DotResult = await installer.pointer_from("a/x", "https://site.example", cdn, 0, transport)
	_check(not both_down.ok and both_down.error.detail.contains("misspelled"),
		"both sources failing keeps the misspelled-id hint", str(both_down.error))

	# The restart half of dot-cloud auto-update: after the exit-75 restart install-games asks again
	# and must see the version published meanwhile, including through a moved_to pointer.
	var pub := {"v": "1.0.0", "moved": ""}
	var live := func(url: String) -> DotResult:
		if url.ends_with("/a/old/latest.json") and pub["moved"] != "":
			return DotResult.success({"moved_to": pub["moved"]})
		if url.ends_with("/a/b/latest.json") or url.ends_with("/a/new/latest.json"):
			return DotResult.success({"version": pub["v"]})
		return DotResult.fail(DotError.CODE_IO, "HTTP 404")
	var before: DotResult = await installer.pointer_from("a/b", "", cdn, 0, live)
	pub["v"] = "2.0.0"
	var after: DotResult = await installer.pointer_from("a/b", "", cdn, 0, live)
	_check(before.ok and after.ok and before.value["version"] == "1.0.0" and after.value["version"] == "2.0.0",
		"a restart after a newer pack was published resolves the new version", str(after))
	pub["moved"] = "a/new"
	var moved_after: DotResult = await installer.pointer_from("a/old", "", cdn, 0, live)
	_check(moved_after.ok and moved_after.value["moved_to"] == "a/new" and moved_after.value["version"] == "",
		"a moved_to in latest.json is handed back through the same resolver the client shell uses", str(moved_after))

	_check(installer.pointer_hint("a/b", "<Error><Code>AccessDenied</Code></Error>").contains("misspelled")
			and installer.pointer_hint("a/b", "HTTP 404").contains("not published")
			and installer.pointer_hint("a/b", "connection refused") == "",
		"a forbidden or missing latest.json says the id may be misspelled; an outage does not")


## A renamed repository: exactly one moved_to hop is followed.
func _game_ref_moved_pointers(installer: Variant) -> void:
	# A renamed repository's old latest.json carries moved_to; exactly one hop is followed.
	var plain: DotResult = installer.follow_pointer("a/old", {"version": "1.0.0"}, 0)
	_check(plain.ok and plain.value["version"] == "1.0.0" and plain.value["moved_to"] == "",
		"a latest.json with no moved_to resolves to its own version", str(plain))
	var moved: DotResult = installer.follow_pointer("a/old", {"version": "1.0.0", "moved_to": "a/new"}, 0)
	_check(moved.ok and moved.value["moved_to"] == "a/new" and moved.value["version"] == "",
		"a moved_to is handed back for the caller to follow, not the stale version", str(moved))
	var landed: DotResult = installer.follow_pointer("a/new", {"version": "2.0.0"}, 1)
	_check(landed.ok and landed.value["version"] == "2.0.0",
		"the new id's latest.json after one hop resolves normally", str(landed))
	var chained: DotResult = installer.follow_pointer("a/new", {"version": "2.0.0", "moved_to": "a/newer"}, 1)
	_check(not chained.ok and chained.error.code == DotError.CODE_STATE,
		"a second hop is refused with an error", str(chained))
	var looped: DotResult = installer.follow_pointer("a/old", {"moved_to": "a/old"}, 0)
	_check(not looped.ok and looped.error.code == DotError.CODE_STATE,
		"a moved_to naming the id itself is refused as a loop", str(looped))
	var bad_target: DotResult = installer.follow_pointer("a/old", {"moved_to": "nonsense"}, 0)
	_check(not bad_target.ok, "a moved_to that is not <owner>/<name> is refused", str(bad_target))


## Server-only packs and delivered maps: the same pinning, their own fields.
func _game_ref_maps(installer: Variant, base: Dictionary) -> void:
	# The server-only packs and the delivered maps: the same pinning, their own fields.
	var maps_yml := "name: X\nmaps:\n  - gamemann/surf_mesa\n  - gamemann/bhop_aztec@latest\nscene: s.tscn\n"
	var maps_stamped: DotResult = installer.stamp_dependencies(maps_yml,
		PackedStringArray(["gamemann/surf_mesa@0.0.0-aa", "gamemann/bhop_aztec@0.0.0-bb"]), "maps")
	_check(maps_stamped.ok and str(maps_stamped.value).contains(
			"maps:\n  - gamemann/surf_mesa@0.0.0-aa\n  - gamemann/bhop_aztec@0.0.0-bb\nscene: s.tscn"),
		"the installer pins a maps: list in place", str(maps_stamped))
	var untouched: DotResult = installer.stamp_dependencies("name: X\n", PackedStringArray(), "maps")
	_check(untouched.ok and str(untouched.value) == "name: X\n",
		"and leaves a descriptor that names no maps alone", str(untouched))
	var full := base.duplicate()
	full["server_dependencies"] = ["gamemann/bots@1.0.0"]
	full["maps"] = ["gamemann/surf_mesa@0.0.0-aa", "gamemann/bhop_aztec@0.0.0-bb"]
	var full_built: DotResult = TmcContent.new()._build("demo", full)
	_check(full_built.ok
			and Array((full_built.value as DotGameDescriptor).server_dependencies) == ["gamemann/bots@1.0.0"]
			and Array((full_built.value as DotGameDescriptor).maps) == ["gamemann/surf_mesa@0.0.0-aa", "gamemann/bhop_aztec@0.0.0-bb"]
			and (full_built.value as DotGameDescriptor).dependencies.is_empty(),
		"server_dependencies and maps reach their own descriptor fields",
		str(full_built.value.describe()) if full_built.ok else str(full_built))
	var loose_map := base.duplicate()
	loose_map["maps"] = ["gamemann/surf_mesa"]
	_check(not TmcContent.new()._build("demo", loose_map).ok,
		"an unpinned map is refused, like an unpinned dependency")


func _game_config(text: String) -> TmcGameConfig:
	var config := TmcGameConfig.new()
	var read := config.read(_parse(text))
	return config if read.ok else null


func _owner_game(id: String, maps: PackedStringArray) -> DotGameDescriptor:
	var game := DotGameDescriptor.new()
	game.game_id = id
	game.content_id = id
	game.maps = maps
	game.max_players = 16
	game.cvars = {"g_speed": "1", "g_keep": "x"}
	game.metadata = {
		"kind": "pack", "module": "res://m.gd", "directory": "content/x",
		"map_vote": {"duration_sec": 600, "trigger": "rtv_only"},
	}
	return game


func _test_owner_maps() -> void:
	_section("a server's settings per game (cfg/content.yml)")

	var owner_deps := PackedStringArray(["me/a@1", "me/b@1", "me/c@1"])

	var layered := _game_config("""games:
  game-x:
    name: "Renamed"
    max_players: 24
    cvars:
      g_speed: "2"
    metadata:
      map_vote:
        duration_sec: 1800
    maps:
      add:
        - me/d
        - me/b@9
      remove:
        - me/c
defaults:
  cvars:
    g_speed: "9"
    g_all: "1"
""")
	_check(layered != null, "defaults and a game section with every key read")
	layered.resolved = {"me/d": "4"}
	var game := _owner_game("owner/game-x", owner_deps)
	var content := TmcContent.new()
	content.games.append(game)
	content.games.append(_owner_game("owner/other", PackedStringArray(["me/z@1"])))
	_check(layered.apply_all(content) == 2, "defaults reach every game")
	_check(
		game.maps == PackedStringArray(["me/a@1", "me/b@9", "me/d@4"]),
		"the game's maps, one removed, one re-pinned by the owner, one added at its resolved version",
		str(game.maps)
	)
	_check(game.display_name == "Renamed" and game.max_players == 24, "name and max_players override")
	_check(game.cvars == {"g_speed": "2", "g_keep": "x", "g_all": "1"},
		"cvars merge: the game's section beats defaults beats the game's own", str(game.cvars))
	_check(game.metadata["map_vote"] == {"duration_sec": 1800, "trigger": "rtv_only"},
		"metadata merges key by key, keeping what the owner did not mention", str(game.metadata["map_vote"]))
	var other: DotGameDescriptor = content.games[1]
	_check(other.maps == PackedStringArray(["me/z@1"]) and other.cvars["g_speed"] == "9"
		and other.max_players == 16, "another game gets the defaults and nothing else")

	var bare := _game_config("games:\n  owner/game-x:\n    maps:\n      - me/e\n      - me/f@2\n")
	var game2 := _owner_game("owner/game-x", owner_deps)
	bare.apply(game2)
	_check(
		game2.maps == PackedStringArray(["me/a@1", "me/b@1", "me/c@1", "me/f@2"]),
		"a bare map list adds; an unpinned map with no resolved version is left out",
		str(game2.maps)
	)
	_check(bare.warnings.size() == 1 and bare.warnings[0].contains("me/e"),
		"and the server says which, and why", str(bare.warnings))

	var replaced := _game_config("games:\n  game-x:\n    maps:\n      game_maps: false\n      add:\n        - me/q@3\n")
	var game3 := _owner_game("owner/game-x", owner_deps)
	replaced.apply(game3)
	_check(game3.maps == PackedStringArray(["me/q@3"]), "game_maps: false replaces the game's list", str(game3.maps))

	var host := _game_config("games:\n  game-x:\n    metadata:\n      module: res://evil.gd\n")
	var game4 := _owner_game("owner/game-x", owner_deps)
	host.apply(game4)
	_check(game4.metadata["module"] == "res://m.gd" and host.warnings.size() == 1,
		"the host's own metadata keys are not overridden, and that is reported")

	var delivered := _game_config("games:\n  game-x:\n    maps:\n      - me/docs@5\n")
	var client_game := _owner_game("owner/game-x", owner_deps)
	client_game.metadata["maps_delivery"] = "client"
	client_game.dependencies = PackedStringArray(["me/a@1"])
	delivered.apply(client_game)
	var server_game := _owner_game("owner/game-x", owner_deps)
	server_game.metadata["maps_delivery"] = "server"
	delivered.apply(server_game)
	var lazy_game := _owner_game("owner/game-x", owner_deps)
	delivered.apply(lazy_game)
	_check(client_game.dependencies == PackedStringArray(["me/a@1", "me/b@1", "me/c@1", "me/docs@5"])
		and client_game.server_dependencies.is_empty()
		and server_game.server_dependencies == PackedStringArray(["me/a@1", "me/b@1", "me/c@1", "me/docs@5"])
		and server_game.dependencies.is_empty()
		and lazy_game.dependencies.is_empty() and lazy_game.server_dependencies.is_empty(),
		"maps_delivery: client fetches maps before load for everybody, server for the server, lazy on a change",
		"%s / %s" % [client_game.dependencies, server_game.server_dependencies])

	var stray := _game_config("games:\n  nothing-here:\n    max_players: 2\n")
	stray.apply_all(content)
	_check(stray.warnings.size() == 1, "a game the server does not have is reported")

	_check(_game_config("games:\n  game-x:\n    scene: res://other.tscn\n") == null,
		"what makes the game the game (scene) is refused")
	_check(_game_config("games:\n  game-x:\n    max_player: 3\n") == null, "a misspelt key is refused")
	_check(_game_config("games:\n  game-x:\n    maps:\n      - a/b/c\n") == null,
		"a three-segment map id stays refused")
	_check(_game_config("games:\n  game-x:\n    maps:\n      - surf_mesa\n") != null,
		"a bare map name is read")
	_check(_game_config("games:\n  game-x:\n    map_owner: a/b\n") == null,
		"a map_owner that is not one name is refused")

	var by_key := _game_config("""games:
  game-x:
    map_owner: keyowner
    maps:
      add:
        - surf_mesa
        - bhop_pit@2
      remove:
        - me/c
""")
	by_key.resolved = {"keyowner/surf_mesa": "7"}
	var key_game := _owner_game("owner/game-x", owner_deps)
	var key_content := TmcContent.new()
	key_content.games.append(key_game)
	by_key.apply_all(key_content)
	_check(key_game.maps == PackedStringArray(["me/a@1", "me/b@1", "keyowner/surf_mesa@7", "keyowner/bhop_pit@2"]),
		"a bare add takes the section's map_owner (resolved version or its own pin)", str(key_game.maps))
	_check(by_key.errors.is_empty(), "and nothing is reported", str(by_key.errors))
	_check(by_key.all_map_entries(key_content).has("keyowner/surf_mesa")
		and by_key.all_map_entries(key_content).has("keyowner/bhop_pit@2"),
		"the installer's entry list is qualified by the same rule (what it pins is what the host looks up)",
		str(by_key.all_map_entries(key_content)))

	var rank := _game_config("games:\n  game-x:\n    maps:\n      - m1\n      - m2\n      - m3\n")
	var ranked := _owner_game("own/game-x", PackedStringArray())
	ranked.cvars["sv_map_content_owner"] = "fromcvar"
	var rank_content := TmcContent.new()
	rank_content.games.append(ranked)
	_check(rank.map_owner_for(ranked) == "fromcvar", "no map_owner: the game's sv_map_content_owner cvar wins over its content id")
	ranked.cvars.erase("sv_map_content_owner")
	_check(rank.map_owner_for(ranked) == "own", "no cvar: the owner half of the game's content id")
	var with_default := _game_config("defaults:\n  map_owner: dflt\ngames:\n  game-x:\n    maps:\n      - m1\n")
	_check(with_default.map_owner_for(ranked) == "dflt", "defaults: map_owner beats the cvar and the content id")
	var with_own := _game_config("defaults:\n  map_owner: dflt\ngames:\n  game-x:\n    map_owner: mine\n")
	_check(with_own.map_owner_for(ranked) == "mine", "the game's map_owner beats defaults:")
	ranked.content_id = ""
	_check(rank.map_owner_for(ranked) == "", "nothing resolves: no owner")

	var sug_game := _owner_game("own/game-x", PackedStringArray(["me/a@1"]))
	sug_game.metadata["suggested"] = ["dm=zz/dm-one", "surf=zz/surf-one"]
	var sug_content := TmcContent.new()
	sug_content.games.append(sug_game)
	var sug_on := _game_config("games:\n  game-x:\n    maps:\n      - m1\n")
	sug_on.resolved = {"zz/dm-one": "3", "zz/surf-one": "4"}
	_check(sug_on.all_map_entries(sug_content).has("zz/dm-one") and sug_on.all_map_entries(sug_content).has("zz/surf-one"),
		"the installer pins a game's suggested map packs by default", str(sug_on.all_map_entries(sug_content)))
	sug_on.apply(sug_game)
	_check(sug_game.maps.has("zz/dm-one@3") and sug_game.maps.has("zz/surf-one@4") and sug_game.maps.has("me/a@1"),
		"and the host puts them in the map list beside the game's own", str(sug_game.maps))
	var sug_off := _game_config("games:\n  game-x:\n    suggested_maps: false\n")
	sug_off.resolved = sug_on.resolved
	_check(not sug_off.all_map_entries(sug_content).has("zz/dm-one"), "suggested_maps: false leaves them out of the installer's list")
	var sug_off_game := _owner_game("own/game-x", PackedStringArray(["me/a@1"]))
	sug_off_game.metadata["suggested"] = ["dm=zz/dm-one", "surf=zz/surf-one"]
	sug_off.apply(sug_off_game)
	_check(sug_off_game.maps == PackedStringArray(["me/a@1"]), "and out of the host's map list", str(sug_off_game.maps))
	var sug_groups := _game_config("games:\n  game-x:\n    suggested_maps: surf\n")
	_check(sug_groups.suggested_entries(sug_game) == PackedStringArray(["zz/surf-one"]),
		"suggested_maps: surf keeps that group only", str(sug_groups.suggested_entries(sug_game)))
	_check(_game_config("games:\n  game-x:\n    suggested_maps: \"a b\"\n") == null, "a bad suggested_maps is refused")
	var sug_cvar := _game_config("games:\n  game-x:\n    cvars:\n      sv_suggested_maps: none\n")
	_check(sug_cvar.suggested_entries(sug_game).is_empty(),
		"the sv_suggested_maps cvar is read from the section's cvars")
	rank.apply_all(rank_content)
	_check(rank.errors.size() == 3 and rank.errors[0].contains("m1") and rank.errors[0].contains("game-x"),
		"and each bare entry is refused with the game and the entry named", str(rank.errors))

	var removal := _game_config("games:\n  game-x:\n    map_owner: me\n    maps:\n      remove:\n        - a\n        - me/b\n")
	var removed := _owner_game("owner/game-x", owner_deps)
	removal.apply(removed)
	_check(removed.maps == PackedStringArray(["me/c@1"]),
		"remove: matches the bare and the qualified spelling of the same map", str(removed.maps))

	var none := TmcGameConfig.load_from("res://examples/fixtures/nothing", "res://examples/fixtures/nothing")
	var game5 := _owner_game("owner/game-x", owner_deps)
	if _check(none.ok, "no cfg/content.yml is no overrides, not an error"):
		# The invariant, not the outcome. With `defaults` left as `{}` the script error is
		# inside _apply_section, which is all it aborts: apply() carries on and returns an
		# honest false, so a check on the result passes over the bug (it did, armed).
		var empty: Dictionary = (none.value as TmcGameConfig).defaults
		_check(empty.has("cvars") and empty.has("metadata") and empty.has("maps"),
			"and its defaults are an empty section, not {}", str(empty))

	var template := TmcGameConfig.load_from("res://cfg.example", "res://examples/fixtures/nothing")
	_check(template.ok, "the template reads", str(template.error) if not template.ok else "")
	if template.ok:
		var parsed: TmcGameConfig = template.value
		var g2g_adds: PackedStringArray = (parsed.games.get("game-airdrift", {}) as Dictionary).get("maps", {}).get("add", PackedStringArray())
		var every := parsed.all_map_entries()
		_check(g2g_adds.size() == 26 and g2g_adds.has("gamemann/surf_mesa")
			and every.has("gamemann/mg-wipeout-maps") and every.has("gamemann/playlot-maps"),
			"the template offers Airdrift's 26 courses (%d) and every other game's maps pack" % g2g_adds.size())

	var moved_dir := "res://examples/fixtures/cfg_move"
	var moved := TmcConfig.load_dir(moved_dir)
	if _check(moved.ok, "a cfg/ with net_* in server.yml and no net.yml loads", str(moved.error) if not moved.ok else ""):
		_check((moved.value as TmcConfig).server.port == 27055 and (moved.value as TmcConfig).server.bind_address == "127.0.0.1",
			"net_port and net_bind_ip in server.yml reach the boot config")
	var per_game := TmcGameConfig.load_from(moved_dir, "res://examples/fixtures/nothing")
	if _check(per_game.ok, "cfg/game/<game>/server.yml reads", str(per_game.error) if not per_game.ok else ""):
		var section: Dictionary = (per_game.value as TmcGameConfig).games.get("game-x", {})
		_check(section.get("max_players") == 8, "sv_maxplayers in a game's file overrides content.yml's max_players", str(section))
		_check(section.get("cvars", {}).get("a") == "2" and section.get("cvars", {}).get("keep") == "yes"
			and section.get("cvars", {}).get("b") == "3", "cvars merge key by key, the game's file winning", str(section.get("cvars")))
		_check(section.get("maps", {}).get("add") == PackedStringArray(["me/new_map"]) and section.get("map_owner") == "me",
			"maps replace whole, as the other keys do", str(section.get("maps")))

	_done()


func _test_map_collections() -> void:
	_section("owner/collection/* in maps")

	var whole := TmcGameRef.qualify_map("gamemann/airdrift-maps/*", "")
	_check(bool(whole["ok"]) and bool(whole["wildcard"]) and whole["collection"] == "gamemann/airdrift-maps",
		"a whole collection parses (and needs no map_owner)", str(whole))
	for bad in ["gamemann/airdrift-maps/bhop_*", "gamemann/*/*", "*", "airdrift-maps/*", "gamemann/airdrift-maps/*/x",
			"*/airdrift-maps/*", "gamemann//*", "gamemann/airdrift-maps/a"]:
		_check(not bool(TmcGameRef.qualify_map(bad, "me")["ok"]), "'%s' is refused" % bad)
	var pinned := TmcGameRef.qualify_map("gamemann/airdrift-maps/*@1.4.0", "")
	_check(not bool(pinned["ok"]) and str(pinned["why"]).contains("@version"),
		"a pin on a wildcard is refused with a clear reason", str(pinned))
	_check(_game_config("games:\n  game-x:\n    maps:\n      - gamemann/airdrift-maps/*@1.4.0\n") == null,
		"and the file that holds one does not load")
	_check(_game_config("games:\n  game-x:\n    maps:\n      add:\n        - gamemann/airdrift-maps/*\n      remove:\n        - gamemann/airdrift-maps/*\n") != null,
		"a wildcard is read in add and in remove")
	_check(_game_config("games:\n  game-x:\n    maps:\n      - gamemann/airdrift-maps/bhop_*\n") == null,
		"a partial glob is refused when the file is read")

	var doc := {"format": 1, "id": "o/c", "version": "1.0.0", "packs": ["o/m1", "o/m2", "o/m1"]}
	var parsed := TmcGameConfig.parse_collection("o/c", doc)
	_check(parsed.ok and parsed.value == PackedStringArray(["o/m1", "o/m2"]),
		"collection.json lists its packs (duplicates dropped)", str(parsed))
	var future := TmcGameConfig.parse_collection("o/c", {"format": 2, "packs": []})
	_check(not future.ok and str(future.error).contains("o/c") and str(future.error).contains("format"),
		"a newer format is an error naming the collection", str(future))
	_check(not TmcGameConfig.parse_collection("o/c", {"packs": []}).ok, "no format is refused")
	_check(not TmcGameConfig.parse_collection("o/c", {"format": 1, "id": "o/other", "packs": []}).ok,
		"a document for another collection is refused")
	_check(not TmcGameConfig.parse_collection("o/c", {"format": 1, "packs": ["o/m@1"]}).ok
		and not TmcGameConfig.parse_collection("o/c", {"format": 1, "packs": ["bare"]}).ok
		and not TmcGameConfig.parse_collection("o/c", "nope").ok,
		"a pack that is not owner/map, and a body that is not an object, are refused")

	var merged := _game_config("""games:
  game-x:
    maps:
      add:
        - o/c/*
        - o/m2@9.9.9
      remove:
        - o/m3
""")
	merged.collections = {"o/c": ["o/m1", "o/m2", "o/m3"]}
	merged.resolved = {"o/m1": "1.0.0", "o/m2": "2.0.0", "o/m3": "3.0.0"}
	var wild_game := _owner_game("owner/game-x", PackedStringArray(["me/a@1"]))
	merged.apply_all(_content_of(wild_game))
	_check(wild_game.maps == PackedStringArray(["me/a@1", "o/m1@1.0.0", "o/m2@9.9.9"]),
		"a wildcard adds every member; an explicit pin beside it wins; remove subtracts one",
		str(wild_game.maps))

	var wipe := _game_config("games:\n  game-x:\n    maps:\n      add:\n        - o/c/*\n      remove:\n        - o/c/*\n        - me/a\n")
	wipe.collections = {"o/c": ["o/m1"]}
	wipe.resolved = {"o/m1": "1.0.0"}
	var wiped := _owner_game("owner/game-x", PackedStringArray(["me/a@1", "me/b@1"]))
	wipe.apply_all(_content_of(wiped))
	_check(wiped.maps == PackedStringArray(["me/b@1"]),
		"a wildcard in remove takes the collection out (and wins over a wildcard add of it)", str(wiped.maps))

	var layered := _game_config("""defaults:
  maps:
    add:
      - o/c/*
games:
  game-x:
    maps:
      remove:
        - o/m1
""")
	layered.collections = {"o/c": ["o/m1", "o/m2"]}
	layered.resolved = {"o/m1": "1.0.0", "o/m2": "2.0.0"}
	var layered_game := _owner_game("owner/game-x", PackedStringArray())
	layered.apply_all(_content_of(layered_game))
	_check(layered_game.maps == PackedStringArray(["o/m2@2.0.0"]),
		"a game's remove takes one map out of a default wildcard", str(layered_game.maps))

	var unknown := _game_config("games:\n  game-x:\n    maps:\n      - o/c/*\n")
	var unknown_game := _owner_game("owner/game-x", PackedStringArray())
	unknown.apply_all(_content_of(unknown_game))
	_check(unknown_game.maps.is_empty() and unknown.warnings.size() == 1 and unknown.errors.is_empty(),
		"a collection never expanded offers nothing and warns once (not an error)", str(unknown.warnings))
	_check(merged.all_map_entries(_content_of(wild_game)).has("o/c/*"),
		"the installer sees the wildcard entry to expand", str(merged.all_map_entries(_content_of(wild_game))))

	var origin := {"o/c": {"format": 1, "id": "o/c", "version": "1.0.0", "packs": ["o/m1", "o/m2"]},
		"o/new": {"format": 2, "packs": []}}
	var origin_state := {"up": true}
	var fetch := func(id: String) -> DotResult:
		if not origin_state["up"] or not origin.has(id):
			return DotResult.fail(DotError.CODE_IO, "origin down: " + id)
		return TmcGameConfig.parse_collection(id, origin[id])
	var installer := preload("res://tools/install_games.gd")
	var first: Dictionary = await installer.resolve_collections(PackedStringArray(["o/c"]), fetch, {})
	_check(first["collections"] == {"o/c": ["o/m1", "o/m2"]} and (first["failed"] as PackedStringArray).is_empty(),
		"a start expands the collection from the origin", str(first))
	origin_state["up"] = false
	var outage: Dictionary = await installer.resolve_collections(PackedStringArray(["o/c"]), fetch, first["collections"])
	_check(outage["collections"] == first["collections"] and (outage["failed"] as PackedStringArray).size() == 1,
		"an outage keeps the last good expansion and says so", str(outage))
	var cold: Dictionary = await installer.resolve_collections(PackedStringArray(["o/c"]), fetch, {})
	_check((cold["collections"] as Dictionary).is_empty() and (cold["failed"] as PackedStringArray).size() == 1,
		"an outage with nothing cached leaves the collection out and says so", str(cold))
	origin_state["up"] = true
	var refused: Dictionary = await installer.resolve_collections(PackedStringArray(["o/new"]), fetch, {"o/new": ["o/old"]})
	_check(refused["collections"] == {"o/new": ["o/old"]} and str((refused["failed"] as PackedStringArray)[0]).contains("o/new"),
		"a newer format is reported by collection and keeps the cache", str(refused))

	# The cache round trip the host reads at boot.
	var dir := "user://selftest_collections"
	DirAccess.make_dir_recursive_absolute(dir)
	var cache := FileAccess.open(dir + "/" + TmcGameConfig.RESOLVED_FILE, FileAccess.WRITE)
	cache.store_string(JSON.stringify({"maps": {"o/m1": "1.0.0"}, "collections": first["collections"], "checked": {"o/m1": 1000.0}}))
	cache.close()
	var reloaded := TmcGameConfig.load_from("res://examples/fixtures/nothing", dir)
	_check(reloaded.ok and (reloaded.value as TmcGameConfig).collections == first["collections"]
			and (reloaded.value as TmcGameConfig).resolved == {"o/m1": "1.0.0"},
		"the host reads the expansion back from data/content-maps.json, check times and all")
	# A start within the TTL reuses the last answer instead of one latest.json per map.
	var times: Dictionary = installer._checked_times(dir + "/" + TmcGameConfig.RESOLVED_FILE)
	_check(installer.is_fresh(times.get("o/m1"), 1100, 900) and not installer.is_fresh(times.get("o/m1"), 2000, 900)
			and not installer.is_fresh(times.get("o/m1"), 1100, 0) and not installer.is_fresh(null, 1100, 900)
			and not installer.is_fresh(5000, 1100, 900),
		"a map checked under the TTL ago is reused; older, TTL 0, never checked or a future time is asked again", str(times))
	DirAccess.remove_absolute(dir + "/" + TmcGameConfig.RESOLVED_FILE)
	DirAccess.remove_absolute(dir)

	_done()


func _content_of(game: DotGameDescriptor) -> TmcContent:
	var content := TmcContent.new()
	content.games.append(game)
	return content


func _test_content() -> void:
	_section("the content index")

	var scanned := TmcContent.scan("res://examples/fixtures/content")

	if not _check(scanned.ok, "the fixture content scans", str(scanned.error)):
		_done()
		return

	var content := scanned.value as TmcContent

	_check(content.games.size() == 2, "two games (%d)" % content.games.size())
	_check(content.default_game == "second", "the one marked default is the default")
	_check(
		content.skipped.size() == 1,
		"a directory with no game.yml is skipped and reported (%s)" % [content.skipped]
	)

	var builtin := content.find("first")
	_check(builtin != null, "a builtin game is indexed")
	_check(
		builtin != null and builtin.manifest_url == "",
		"with no manifest, which is what makes it builtin"
	)
	_check(
		builtin != null and builtin.client_scene == "",
		"and no client scene",
		"DotClientLink refuses every absolute res:// path outside dot-cloud's mount, so "
		+ "naming one has the client refuse it and be timed out in LOADING"
	)
	_check(
		builtin != null and builtin.display_name == "The First",
		"and the name from its game.yml"
	)
	_check(
		builtin != null and String(builtin.metadata.get("module", "")) != "",
		"and the module it names"
	)

	# The operator's `metadata:` block. dot-vote's game source reads `metadata.vote` and a
	# game's own map vote reads `metadata.map_vote`, and both were dropped here: every
	# per-game vote setting anybody wrote in a game.yml was ignored, in silence.
	var vote_meta: Variant = builtin.metadata.get("vote", {}) if builtin != null else {}
	_check(
		vote_meta is Dictionary and int((vote_meta as Dictionary).get("time_limit_sec", 0)) == 60,
		"a game's `metadata: vote:` reaches its descriptor (%s)" % str(vote_meta),
		"it is what DotVoteGameSource reads a game's own time limit from"
	)
	_check(
		builtin != null and builtin.metadata.get("map_vote", {}) is Dictionary
			and not (builtin.metadata.get("map_vote", {}) as Dictionary).is_empty(),
		"and so does `metadata: map_vote:`, which the game's own map vote layers"
	)
	_check(
		builtin != null and String(builtin.metadata.get("module", "")) != "res://nowhere.gd",
		"and a `module` inside it does not override the game's real one",
		"a second, undocumented way to say `module:` is a game that loads the wrong script"
	)

	# The refusal the trap above deserves. A builtin game that named a client scene would
	# produce a connection that appears to work and silently does not.
	var bad := TmcContent.scan("res://examples/fixtures/bad-content")
	_check(
		not bad.ok and str(bad.error).contains("client_scene"),
		"a builtin game that names a client_scene is refused (%s)" % str(bad.error)
	)

	var absent := TmcContent.scan("res://examples/fixtures/nothing-here")
	_check(
		not absent.ok,
		"and a missing content directory is an error, not an empty list",
		"a server with no content is legitimate; a missing directory is a typo"
	)

	SelftestContentLists.new(self)._test_deployed_map_clocks()
	_done()


func _test_vote() -> void:
	_section("voting for the next game")

	# The environment layers over vote.yml under the SERVER vote's own prefix, and
	# dot-vote's plain one is left to the map vote inside a game. Set before the load and
	# cleared straight after, so nothing else in this suite sees either.
	OS.set_environment("DOT_GAME_VOTE_EXTEND_SECONDS", "1234")
	OS.set_environment("DOT_VOTE_MAX_EXTENDS", "9")
	var loaded := TmcConfig.load_dir(CFG)
	OS.unset_environment("DOT_GAME_VOTE_EXTEND_SECONDS")
	OS.unset_environment("DOT_VOTE_MAX_EXTENDS")

	if not _check(loaded.ok, "the fixture config loads", str(loaded.error)):
		_done()
		return

	var config := loaded.value as TmcConfig

	_check(config.vote.enabled, "vote.yml turns voting on")

	# The Gamespice spelling: GS_GAME_VOTE_* wins over the old DOT_ one, and GS_VOTE_* is still the map vote's.
	OS.set_environment("DOT_GAME_VOTE_EXTEND_SECONDS", "1234")
	OS.set_environment("GS_GAME_VOTE_EXTEND_SECONDS", "777")
	OS.set_environment("GS_VOTE_MAX_EXTENDS", "9")
	var gs_loaded := TmcConfig.load_dir(CFG)
	OS.unset_environment("DOT_GAME_VOTE_EXTEND_SECONDS")
	OS.unset_environment("GS_GAME_VOTE_EXTEND_SECONDS")
	OS.unset_environment("GS_VOTE_MAX_EXTENDS")
	var gs_config := gs_loaded.value as TmcConfig if gs_loaded.ok else null
	_check(gs_config != null and is_equal_approx(gs_config.vote.extend_seconds, 777.0), "GS_GAME_VOTE_* wins over the old DOT_GAME_VOTE_*")
	_check(gs_config != null and gs_config.vote.max_extends != 9, "and GS_VOTE_* does not reach the server vote either")
	_check(
		is_equal_approx(config.vote.extend_seconds, 1234.0),
		"DOT_GAME_VOTE_* overrides vote.yml (%.0f)" % config.vote.extend_seconds,
		"these layers were claimed in a comment and never applied"
	)
	_check(
		config.vote.max_extends != 9,
		"and DOT_VOTE_* does not reach it (%d)" % config.vote.max_extends,
		"that prefix is the map vote inside a game, in the same process: one flag "
		+ "changing two votes is a flag nobody can use"
	)
	_check(
		Array(config.vote_exclude) == ["playground"],
		"and names the games that are never on a ballot (%s)" % [config.vote_exclude],
		"which is TMC's question rather than dot-vote's"
	)

	# Every enum written by NAME. A config file full of enum indices is one nobody can
	# read or diff, and renumbering an enum would silently change how a server counts.
	_check(
		config.vote.method == DotVoteRules.Method.INSTANT_RUNOFF,
		"`method: instant_runoff` reaches the counting method"
	)
	_check(
		config.vote.tie_break == DotVoteRules.TieBreak.LEAST_RECENTLY_PLAYED,
		"in any case and with dashes (`LEAST-RECENTLY-PLAYED`)"
	)
	_check(
		config.vote.fill == DotVoteRules.Fill.WEIGHTED
			and config.vote.apply == DotVoteRules.Apply.IMMEDIATE
			and config.vote.trigger == DotVoteRules.Trigger.RTV_ONLY,
		"and so do fill, apply and trigger"
	)

	_check(
		is_equal_approx(config.vote.duration_sec, 900.0)
			and is_equal_approx(config.vote.rtv_fraction, 0.75),
		"numbers are coerced through the property's own type"
	)
	_check(
		config.vote.max_options == 4 and config.vote.nomination_slots == 2,
		"and so are integers"
	)

	var marks := config.vote.warn_marks()
	_check(
		marks.size() == 2 and is_equal_approx(marks[0], 120.0),
		"the warning marks parse out of a quoted list (%s)" % [marks]
	)

	_check(
		config.vote.validate().ok,
		"the fixture's rules validate",
		str(config.vote.validate().error)
	)

	# Reported in the same boot report as a typo in server.yml, and never fatal.
	var reported := false

	for entry in config.unknown:
		if entry.contains("vote_nonsense"):
			reported = true

	_check(
		reported,
		"an unknown key in vote.yml is reported rather than silently ignored (%s)"
			% [config.unknown],
		"a key ignored AND not reported is the worst of both: the operator believes "
		+ "it took effect"
	)

	_done()


## `time_up: finish_round` in a game whose match the game vote cannot find: the change waits for the
## round end the game's own director forwards, and goes on it.
func _test_vote_rounds_without_a_match() -> void:
	_section("finish_round in a game whose match the game vote cannot find")

	var rules := DotVoteRules.new()
	rules.enabled = true
	rules.duration_sec = 10.0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	rules.finish_round_max_sec = 0.0

	var votes := TmcVote.new()
	votes.name = "RoundsVotes"
	votes.director = DotVoteDirector.new()
	votes.director.name = "Director"
	votes.director.rules = rules
	# A list rather than the server's games: there is no server, and the ballot is not under test.
	votes.director.source = DotVoteListSource.of_ids(["standin", "next"])
	votes.director.register_service = false
	votes.director.begin_on_apply = false
	# Advisory, so `change_due` is the change and nothing tries to load a game.
	votes.director.auto_apply = false
	votes._wire()
	# Chat is the server's, and there is none: what the vote says is kept here instead.
	var said := PackedStringArray()
	votes.director.announce_fn = func(line: String) -> void: said.append(line)
	# Advanced by hand below: there is no server here for its HUD poll to tell.
	votes.set_physics_process(false)
	add_child(votes)
	votes.add_child(votes.director)

	var game: Node = RoundsWithoutMatch.new()
	add_child(game)

	var due: Array[StringName] = []
	votes.director.change_due.connect(
		func(id: StringName, _choice: DotVoteChoice) -> void: due.append(id)
	)

	votes.director.begin(&"standin")
	votes._rescan()

	_check(
		votes.director.round_based,
		"the game vote hears rounds from the game's own round-based director"
	)
	_check(
		votes._rounds_match() == null and votes.round_in_progress(),
		"and with no match beside it, a round counts as live",
		"the stand-in must leave round_in_progress with nothing to ask, or the forwarding is not what is tested"
	)

	var next := votes.director.set_next(&"next")
	_check(next.ok, "the next game is decided before the clock runs out", str(next.error))

	# Twice the limit, in frames: the clock runs out at ten seconds mid-round.
	for i in 120:
		votes.director.advance(1.0 / 6.0)

	_check(
		votes.director.clock.is_expired() and due.is_empty()
			and votes.director.is_finishing_round(),
		"the clock ran out mid-round and the change waits for the round (%s)" % [due],
		"finish_round changed the game at the expiry"
	)

	game.end_round()

	for i in 3:
		votes.director.advance(1.0 / 60.0)

	_check(
		due == [&"next"],
		"the round's end, forwarded from the game's director, lets the change go (%s)" % [due],
		"TmcVote._rescan forwards the game director's clock.round_ended to note_round_end; "
		+ "without it a game whose match cannot be found never changes under finish_round"
	)

	votes.free()
	game.free()
	_done()


## Forced rather than waited for: the change is declared under way by hand, nobody is on the server,
## and the clock is run well past its limit. Without TmcVote's hold the director draws a game at
## random and announces a second change.
func _rotation_votes(tree: Dictionary, excluded: Array = [], running: String = "") -> TmcVote:
	var manager := DotGameManager.new()
	for id in ["fc", "surf", "bhop", "maze", "deathrun"]:
		var d := DotGameDescriptor.new()
		d.game_id = id
		d.content_id = "tmc/" + id
		d.display_name = id
		manager.games.append(d)
	var server := DotServer.new()
	server.games = manager
	var rules := DotVoteRules.new()
	rules.enabled = true
	rules.duration_sec = 10.0
	rules.empty_choice = DotVoteRules.EmptyChoice.RANDOM
	var rotation := TmcGameRotation.from_tree(tree)
	var votes := TmcVote.new()
	votes.name = "RotVotes"
	votes.server = server
	votes.source = DotVoteGameSource.of(manager)
	for id in excluded:
		votes.source.excluded.append(StringName(id))
	votes._operator_excluded = votes.source.excluded.duplicate()
	votes.rotation = rotation
	votes._end_vote_base = rules.end_vote
	votes._refresh_offer()
	votes.director = DotVoteDirector.new()
	votes.director.name = "Director"
	votes.director.rules = rules
	votes.director.source = votes.source
	votes.director.register_service = false
	votes.director.begin_on_apply = false
	votes.director.auto_apply = false
	votes.director.player_count_fn = func() -> int: return 0
	votes.director.busy_fn = func() -> bool: return false
	votes.set_physics_process(false)
	add_child(votes)
	votes.add_child(votes.director)
	votes.director.begin(StringName(running if running != "" else "fc"))
	return votes


func _ids(choices: Array) -> Array:
	var out := []
	for c in choices:
		out.append(String(c.id))
	return out


func _test_game_rotation() -> void:
	_section("games.yml decides which games are voted on and played")

	var tree := {"rotation": "small", "rotations": {
		"small": {"mode": "random", "games": ["fc", "surf", "bhop"]},
		"loop": {"mode": "cycle", "cooldown": 7, "games": ["bhop", "fc", "surf"]},
	}}
	var votes := _rotation_votes(tree)
	var director := votes.director

	# The ballot and the offer: maze and deathrun are installed, and on no ballot.
	var offered := _ids(votes.source.choices())
	_check(not offered.has("maze") and not offered.has("deathrun") and offered.has("surf"),
		"the ballot's pool is the rotation's games (%s)" % [offered])

	var options := _ids(director.build_options(0))
	_check(not options.has("maze") and not options.has("deathrun") and not options.is_empty(),
		"a ballot built now carries only listed games (%s)" % [options])

	# Nominations.
	_check(not director.nominate(&"p1", &"maze").ok, "!game_nominate refuses an installed game that is not listed")
	_check(director.nominate(&"p1", &"surf").ok, "and takes a listed one")
	_check(not director.nominatable_ids().has(&"deathrun"), "the nomination list leaves unlisted games out")

	# Next game: !game_next (set_next) and the rotation fallback used by rtv and the time limit.
	_check(not director.set_next(&"maze").ok, "game_next refuses an unlisted game")
	var seen := {}
	for i in 30:
		seen[String(director.next_in_rotation())] = true
		director.history.note_played(StringName("bhop"))
	_check(not seen.has("maze") and not seen.has("deathrun"),
		"rtv and the end-of-game draw never land on an unlisted game (%s)" % [seen.keys()])
	votes.free()

	# Written order under a cycle, and the vote ends the game by the order alone.
	var cyc := TmcGameRotation.from_tree(tree)
	_check(cyc.switch("loop").ok and cyc.is_cycle(), "sv_game_rotation can switch to the cycle")
	votes = _rotation_votes(tree)
	votes.rotation.switch("loop")
	votes.apply_rotation()
	_check(votes.director.rules.end_vote == false, "a cycle turns the end-of-game ballot off")
	_check(_ids(votes.source.choices()).slice(0, 3) == ["bhop", "fc", "surf"],
		"and the offer is in the written order (%s)" % [_ids(votes.source.choices())])
	votes.rotation.switch("small")
	votes.apply_rotation()
	_check(votes.director.rules.end_vote == votes._end_vote_base, "leaving the cycle restores the ballot")
	votes.rotation.switch("loop")
	votes.apply_rotation()
	_check(votes.director.rules.cooldown == 7, "a rotation's own cooldown applies")
	votes.rotation.switch("small")
	votes.apply_rotation()
	_check(votes.director.rules.cooldown == votes._cooldown_base and votes._cooldown_base != 7,
		"and a rotation with none falls back to vote.yml's, not the previous rotation's")
	votes.free()

	# vote_exclude still works with a rotation: both sets are off the ballot.
	votes = _rotation_votes(tree, ["surf"])
	var both := _ids(votes.source.choices())
	_check(not both.has("surf") and not both.has("maze") and both.has("fc"),
		"vote_exclude and the rotation both apply (%s)" % [both])
	votes.free()

	# No file: content order, every game.
	votes = _rotation_votes({})
	_check(_ids(votes.source.choices()).size() == 5, "with no games.yml every installed game is offered")
	votes.free()

	# A rotation matching nothing plays everything, and an unknown entry is only a WARN.
	votes = _rotation_votes({"games": ["nothing_like_it", "fc", "surf"]})
	var some := _ids(votes.source.choices())
	_check(some.has("fc") and some.has("surf") and not some.has("bhop"),
		"an entry matching no game is skipped and the rest still play (%s)" % [some])
	votes.free()
	votes = _rotation_votes({"games": ["nothing_like_it"]})
	_check(_ids(votes.source.choices()).size() == 5, "a rotation with no match plays every game")
	votes.free()

	# games.yml's `commands:` block: the constants are only the defaults.
	var named := TmcGameRotation.from_tree({"commands": {
		"prefix": "g_", "names": {"rtv": ["rockthevote", "rock"], "vote": "pick", "timeleft": "BAD NAME"},
	}})
	_check(named.warnings.size() == 1, "a name that cannot be typed is dropped with one warning (%s)" % [named.warnings])
	var console := DotConsole.new()
	add_child(console)
	console.command("g_rock", func(_c: DotCmdContext) -> void: pass, "someone else's", "")
	votes = _rotation_votes(tree)
	var cmds := DotVoteCommands.new()
	cmds.director = votes.director
	cmds.prefix = TmcVote.COMMAND_PREFIX
	cmds.names = TmcVote.COMMAND_NAMES.duplicate()
	cmds.spec_fn = named.commands
	cmds.chat_prefix = "/"
	cmds.with_map_menu = false
	cmds.bind(console)
	_check(console.find_command("g_rockthevote") != null and console.find_command("g_pick") != null
			and console.find_command("g_vote") == null and console.find_command("game_rtv") == null,
		"games.yml renames the game vote's prefix and commands")
	_check(cmds.skipped.has("g_rock") and cmds.registered.has("g_rockthevote"),
		"an alias that another command holds is skipped, the name beside it registers (%s)" % [cmds.skipped])
	_check(cmds.typed("vote") == "/g_pick" and cmds.command_name("nextmap") == "g_next",
		"the hint reads the renamed command behind the first chat prefix, and untouched roles keep the defaults (%s)" % cmds.typed("vote"))
	var plain := DotVoteCommands.new()
	plain.prefix = TmcVote.COMMAND_PREFIX
	plain.names = TmcVote.COMMAND_NAMES.duplicate()
	plain.spec_fn = TmcGameRotation.from_tree({}).commands
	_check(plain.command_name("rtv") == "game_rtv" and plain.command_name("vote") == "game_vote",
		"with no commands block the old names stand")
	console.free()
	votes.free()

	# Patterns, the same matcher as maps.yml.
	votes = _rotation_votes({"games": ["tmc/f*", "deathrun"]})
	var globbed := _ids(votes.source.choices())
	_check(globbed.has("fc") and globbed.has("deathrun") and globbed.size() == 2,
		"globs and bare names pick games (%s)" % [globbed])
	votes.free()

	_done()


func _test_vote_notices() -> void:
	_section("the game vote on the shell's HUD")

	var parsed := TmcYaml.parse_file("res://cfg.example/server/addon/dot_vote/vote.yml")

	if not _check(parsed.ok, "the shipped vote.yml template parses", str(parsed.error)):
		_done()
		return

	var tree: Dictionary = parsed.value
	var catalogue := TmcNoticeOverlay.sound_catalogue()
	var named := PackedStringArray()
	var missing := PackedStringArray()

	for key in ["cue_vote_start", "cue_vote_end", "cue_warning", "cue_runoff_warning", "cue_countdown"]:
		var id := str(tree.get(key, ""))
		if id == "":
			continue
		# The countdown cue may carry the second in it; every second it could name must
		# then be in the catalogue, which for a %d id is a question about the template.
		var ids := PackedStringArray()
		if id.contains("%d"):
			for at in str(tree.get("cue_countdown_at", "")).split(",", false):
				ids.append(id % int(at))
		else:
			ids.append(id)
		for one in ids:
			named.append(one)
			if not catalogue.has(StringName(one)):
				missing.append(one)

	_check(
		named.size() >= 4,
		"the template names the vote's cues (%s)" % ", ".join(named),
		"cue_* shipped empty or commented out: the shell has sounds and is never asked"
	)
	_check(
		missing.is_empty(),
		"and every one is in the shell's catalogue",
		"the shell has no def for %s, so those are silent for every player" % ", ".join(missing)
	)

	# No file ships for any of them, so each must have a synthesised stand-in or it is
	# silent on a real sound card too -- the same failure one layer down.
	var unvoiced := PackedStringArray()
	var recipes := TmcNoticeOverlay.sound_recipes()
	for id in catalogue.ids():
		if not recipes.has(id):
			unvoiced.append(String(id))
	_check(
		unvoiced.is_empty(),
		"every cue the shell can play has a stand-in sound (%d)" % recipes.size(),
		"no stand-in for %s" % ", ".join(unvoiced)
	)
	_check(catalogue.validate().ok, "and the catalogue validates", str(catalogue.validate().error))

	# A countdown needs a warning to count. At 0 the ballot opens at once and the HUD shows
	# the ballot's time only, which is legitimate -- but it is not what this template means.
	_check(
		float(tree.get("vote_warning_sec", 0)) > 0.0,
		"the template counts down to a ballot (%ss)" % str(tree.get("vote_warning_sec", 0))
	)

	# The overlay itself, with no server. The socket half is `shell_notice`.
	var overlay := TmcNoticeOverlay.new()
	add_child(overlay)

	var sink := overlay.audio.sink as DotAudioSinkNull
	_check(sink != null, "headless, the overlay's sounds go to the null sink")

	overlay.show_notice(DotNotice.make(&"", "A vote starts in", 10.0, &"game_vote"))
	_check(
		overlay.line_text(&"game_vote").begins_with("A vote starts in"),
		"a notice with a topic puts up a line (%s)" % overlay.line_text(&"game_vote")
	)
	overlay.show_notice(DotNotice.make(&"", "A vote starts in", 9.0, &"game_vote"))
	_check(
		overlay.describe()["lines"].size() == 1 and overlay.line_text(&"game_vote").ends_with("9s"),
		"and the next one for that topic replaces it rather than stacking (%s)"
			% overlay.line_text(&"game_vote")
	)
	overlay.show_notice(DotNotice.make(TmcNoticeOverlay.CUE_VOTE_COUNT))
	_check(
		overlay.describe()["lines"].size() == 1,
		"a bare cue draws nothing"
	)
	_check(
		sink != null and sink.count_of(TmcNoticeOverlay.CUE_VOTE_COUNT) == 1,
		"and is played through the catalogue"
	)
	overlay.show_notice(DotNotice.make(&"tmc_no_such_cue"))
	_check(
		sink != null and sink.count_of(&"tmc_no_such_cue") == 0,
		"an id the shell does not have is silence, not an error"
	)
	# The ballot names the line it stands for, and the line is not drawn while it is open:
	# the two said the same thing, and the line sat on every game's top-centre HUD.
	overlay.show_notice(DotNotice.make(&"", "", 20.0, &"game_ballot", {
		"open": true, "title": "Vote for the next game", "command": "game_vote", "seconds": 20.0,
		"options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}], "line": "game_vote",
	}))
	_check(
		overlay.has_line(&"game_vote") and not overlay.is_line_shown(&"game_vote"),
		"an open ballot hides the line it names, and the line is still there"
	)
	overlay.show_notice(DotNotice.make(&"", "Restarting soon", 30.0, &"restart"))
	_check(overlay.is_line_shown(&"restart"), "and only that line: another one is drawn")
	overlay.show_notice(DotNotice.make(&"", "", -1.0, &"game_ballot", {"open": false, "winner": "A"}))
	_check(overlay.is_line_shown(&"game_vote"), "and once the ballot closes the line is back")
	var result_up := overlay.ballot(&"game_ballot").visible
	overlay.show_notice(DotNotice.make(&"", "", 20.0, &"map_ballot", {
		"open": true, "title": "Vote for the next map", "command": "votefor", "seconds": 20.0,
		"options": [{"id": "x", "label": "X"}, {"id": "y", "label": "Y"}],
	}))
	_check(
		result_up and not overlay.ballot(&"game_ballot").visible and overlay.ballot(&"map_ballot").visible,
		"a closed ballot's result comes down when another ballot opens",
		"'Don't change won' stayed above a game's own ballot, and the two covered its HUD"
	)
	_check(
		overlay.ballot(&"map_ballot").ui_theme.background.a == 1.0,
		"and a ballot's background is opaque, so a game's HUD does not read through it"
	)
	overlay.show_notice(DotNotice.make(&"", "", -1.0, &"map_ballot", {"open": false}))
	# A headless viewport is 64 x 64, so the width is checked as the function it is.
	_check(
		TmcNoticeOverlay.column_width(1280.0) == 360.0 and TmcNoticeOverlay.column_width(854.0) < 300.0
			and TmcNoticeOverlay.column_width(400.0) == 240.0,
		"the column is a third of the frame, 240..360 px (%d at 854)" % int(TmcNoticeOverlay.column_width(854.0))
	)
	overlay.show_notice(DotNotice.clear(&"restart"))
	overlay.show_notice(DotNotice.clear(&"game_vote"))
	_check(not overlay.has_line(&"game_vote"), "and a clear takes the line down")
	_check(
		TmcNoticeOverlay.format_seconds(75.2) == "1:16"
			and TmcNoticeOverlay.format_seconds(9.1) == "10s",
		"a countdown reads as seconds under a minute and m:ss above, rounded up"
	)

	remove_child(overlay)
	overlay.free()

	_done()


func _test_auth() -> void:
	_section("authentication")

	# [b]The case that shipped: a file nothing read.[/b] `TmcConfig.auth` was parsed and handed to a
	# TmcAuth that did not exist, so a server advertised `auth=none`, everybody arrived as a guest, and
	# `permissions.yml` did nothing.
	var off := TmcAuth.build({}, "cfg")
	_check(off.ok and off.value != null, "no auth.yml at all is TMC's sign-in (ticket, guests allowed), not a guest server")

	var disabled := TmcAuth.build({"enabled": false, "strategy": "ticket"}, "cfg")
	_check(
		disabled.ok and disabled.value == null,
		"and so is one that says enabled: false"
	)

	# Turning it on has to be a decision somebody made. A deployment that upgrades into
	# authentication is a deployment whose admins silently changed.
	var legacy := TmcAuth.build({"backend": {"type": "rest"}}, "cfg")
	_check(
		legacy.ok and legacy.value == null,
		"the old example's shape stays off rather than half-configuring anything"
	)

	var unknown := TmcAuth.build({"enabled": true, "strategy": "magic"}, "cfg")
	_check(not unknown.ok, "an unknown strategy is refused")
	_check(
		unknown.error != null and str(unknown.error.detail).contains("ticket"),
		"and the refusal lists the ones that exist",
		str(unknown.error)
	)

	# TICKET with no server_id adopts it from the site. dot-auth refuses every signed-in
	# join until then: a ticket verified with no audience is valid on every server.
	var work := "user://tmc_auth_test"
	DotPaths.remove_tree(work)
	DotPaths.ensure_dir(work)

	var pub := work.path_join("issuer.pub.pem")
	DotPaths.write_text(pub, "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----\n")

	var no_id := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "issuer_public_key_file": "issuer.pub.pem",
	}, work, work)
	var no_id_server: DotAuthServer = no_id.value if no_id.ok else null
	_check(
		no_id_server != null and no_id_server.config.adopt_ticket_trust
			and no_id_server.config.ticket_public_key.contains("PUBLIC KEY")
			and no_id_server.config.ticket_trust_cache == work.path_join("ticket_trust.json"),
		"a ticket server with no server_id learns it from the site, keeping its key file",
		str(no_id.error)
	)
	_check(no_id_server != null and not no_id_server.ticket_trust_ready(),
		"and verifies nothing until it has")
	if no_id_server != null:
		no_id_server.free()

	var shipped := TmcYaml.parse_file("res://cfg.example/addon/dot_auth/auth.yml")
	var shipped_built := TmcAuth.build(shipped.value if shipped.ok else {}, work)
	var shipped_cfg: DotAuthConfig = (shipped_built.value as DotAuthServer).config \
		if shipped_built.ok and shipped_built.value != null else null
	_check(
		shipped_cfg != null and shipped_cfg.strategy == DotAuthConfig.Strategy.TICKET
			and shipped_cfg.adopt_ticket_trust and shipped_cfg.ticket_public_key == ""
			and shipped_cfg.backbone_url.begins_with("https://"),
		"the shipped auth.yml is ticket mode with nothing to fill in",
		str(shipped_built.error)
	)
	_check(shipped_cfg != null and not shipped_cfg.require_ticket_binding,
		"and accepts unbound tickets until the operator says otherwise")
	if shipped_built.ok and shipped_built.value != null:
		(shipped_built.value as Node).free()
	var strict := TmcAuth.build({"enabled": true, "strategy": "ticket", "require_ticket_binding": true}, work)
	_check(strict.ok and strict.value != null
			and (strict.value as DotAuthServer).config.require_ticket_binding,
		"require_ticket_binding reaches the auth server", str(strict.error))
	if strict.ok and strict.value != null:
		(strict.value as Node).free()

	# [b]A private key here would verify AND mint.[/b] Every operator holding one could
	# forge any player's identity, which is the one thing the whole ticket design exists
	# to prevent -- so it is refused by name rather than quietly working.
	var priv := work.path_join("issuer.key.pem")
	DotPaths.write_text(priv, "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n")

	var wrong_half := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.key.pem",
	}, work)
	_check(not wrong_half.ok, "and a PRIVATE key is refused, because it would also mint")

	var missing := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "nope.pem",
	}, work)
	_check(
		missing.ok and (missing.value as DotAuthServer).config.adopt_ticket_trust
			and (missing.value as DotAuthServer).config.server_id == "eu-1",
		"a key file that is not there falls back to the site's keys, keeping the pinned id",
		str(missing.error)
	)
	if missing.ok:
		(missing.value as Node).free()

	var good := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem", "allow_guests": true,
	}, work)
	_check(good.ok, "a complete ticket configuration builds", str(good.error))

	var node: Node = good.value
	_check(node != null, "and produces an auth server for dot-server to find")

	if node != null:
		var cfg: DotAuthConfig = node.get("config")
		_check(
			cfg.strategy == DotAuthConfig.Strategy.TICKET and cfg.server_id == "eu-1"
				and cfg.allow_guests,
			"carrying the strategy, the audience and the guest policy from the YAML"
		)
		# `DotAuthServer` layers a JSON file over the config it was handed, and its
		# default points into `user://` -- a file no operator of this tool writes,
		# silently outranking the YAML that is the documented surface.
		_check(
			str(node.get("config_file")) == "",
			"and no user:// config file that would outrank the YAML"
		)
		node.free()

	# [b]Introspection here is scoped or refused.[/b] The site's avatar and profile routes resolve only
	# the key it mints for this server's credential; a join let in through `/me` would be keyed by the
	# account id instead.
	var scoped := TmcAuth.build({
		"enabled": true, "strategy": "introspect", "first_party": true,
		"backbone_url": "https://site.example", "allow_guests": true,
		# The template names one whatever the strategy; introspection must not need it.
		"issuer_public_key_file": "not-here.pem",
	}, work)
	var scoped_node: DotAuthServer = scoped.value if scoped.ok else null
	_check(
		scoped_node != null and scoped_node.scoped_only,
		"introspection refuses joins until it can ask the site as this server",
		str(scoped.error)
	)
	if scoped_node != null:
		scoped_node.free()

	var legacy_introspect := TmcAuth.build({
		"enabled": true, "strategy": "introspect", "introspect_scoped": false, "first_party": true,
		"backbone_url": "https://site.example",
	}, work)
	_check(
		legacy_introspect.ok and not (legacy_introspect.value as DotAuthServer).scoped_only,
		"and introspect_scoped: false is the old first-party behaviour, by name"
	)
	if legacy_introspect.ok:
		(legacy_introspect.value as Node).free()

	# The flat legacy file every server got: introspect, no server_id, no first_party.
	# Read as ticket, with one WARN naming the file, instead of guests only.
	DotPaths.write_text(work.path_join("auth.yml"), "enabled: true\nstrategy: introspect\n")
	var migrated := TmcAuth.build({
		"enabled": true, "strategy": "introspect", "server_id": "",
		"backbone_url": "https://site.example", "allow_guests": true,
	}, work)
	var migrated_cfg: DotAuthConfig = (migrated.value as DotAuthServer).config if migrated.ok else null
	_check(
		migrated_cfg != null and migrated_cfg.strategy == DotAuthConfig.Strategy.TICKET
			and migrated_cfg.adopt_ticket_trust,
		"a legacy introspect auth.yml with no server_id runs in ticket mode",
		str(migrated.error)
	)
	_check(
		TmcAuth.auth_files(work) == PackedStringArray([work.path_join("auth.yml")]),
		"and the warning names the file to fix"
	)
	if migrated.ok:
		(migrated.value as Node).free()

	# [b]The roster report[/b]: the URL from the YAML, the key from a file beside it, and a
	# key written inline refused by name, because a secret in the YAML is a secret in every
	# paste of the configuration.
	DotPaths.write_text(work.path_join("report.key"), "s3cret-report-key\n")
	var reporting := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem",
		"session_report_url": "https://issuer.example", "session_report_key_file": "report.key",
		"session_report_interval_sec": 30,
	}, work)
	var reporting_cfg: DotAuthConfig = (reporting.value as Node).get("config") if reporting.ok else null
	_check(
		reporting_cfg != null and reporting_cfg.session_report_url == "https://issuer.example"
			and reporting_cfg.session_report_key == "s3cret-report-key"
			and is_equal_approx(reporting_cfg.session_report_interval_sec, 30.0),
		"session reporting is configured from auth.yml, the key read from its file",
		str(reporting.error)
	)
	if reporting.ok:
		(reporting.value as Node).free()
	var inline_key := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem",
		"session_report_url": "https://issuer.example", "session_report_key": "pasted",
	}, work)
	_check(not inline_key.ok, "a report key written into the YAML is refused")
	var no_key := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem", "session_report_url": "https://issuer.example",
	}, work)
	_check(not no_key.ok, "a report URL with no key is refused (anyone could report anyone)")
	var lost_key := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "server_id": "eu-1",
		"issuer_public_key_file": "issuer.pub.pem",
		"session_report_url": "https://issuer.example", "session_report_key_file": "gone.key",
	}, work)
	_check(not lost_key.ok, "and a key file that is not there names the path")

	DotPaths.remove_tree(work)
	_done()

