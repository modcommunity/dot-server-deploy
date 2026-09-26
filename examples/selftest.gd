extends Node

## Everything this repository adds, checked without starting a server.
##
## [codeblock]
## godot --headless --path . res://examples/selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## The YAML reader, the config translation, the permission translation and the content
## index. `./server check` is the other half — it boots a real server, loads the lobby and
## shuts down — and between them they cover everything before a client connects.

const CFG := "res://examples/fixtures"

const CHECKS := 226

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

	_test_yaml_scalars()
	_test_yaml_structure()
	_test_yaml_refusals()
	_test_config()
	_test_admins()
	_test_content()
	_test_vote()
	_test_vote_layers_reach_a_ballot()
	_test_vote_notices()
	_test_auth()
	_test_logging()
	_test_security()
	_test_party()
	await _test_replay()
	await _test_friends()

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


# --- Sections --------------------------------------------------------------

func _test_yaml_scalars() -> void:
	_section("YAML scalars")

	var tree := _parse("""
# a comment
name: "TMC Test Server"
bare: a bare string
players: 64
ratio: 0.75
on_flag: true
off_flag: no
empty:
url: http://localhost:8000
hashed: "Bob's #1 server"   # a trailing comment
""")

	_check(String(tree.get("name", "")) == "TMC Test Server", "a quoted string")
	_check(String(tree.get("bare", "")) == "a bare string", "a bare string with spaces")
	_check(tree.get("players") is int and int(tree["players"]) == 64, "an integer stays one")
	_check(tree.get("ratio") is float, "and a float stays a float")
	_check(tree.get("on_flag") == true, "true is a bool")
	_check(tree.get("off_flag") == false, "and so is 'no'")
	_check(String(tree.get("empty", "x")) == "", "a key with nothing after it is empty")

	# The rule that makes a URL parse: a colon separates a key only when a space or the
	# end of the line follows it. Without it `http://localhost:8000` is a key called
	# `url: http` with an unparseable value.
	_check(
		String(tree.get("url", "")) == "http://localhost:8000",
		"a URL keeps its colons (%s)" % tree.get("url", "")
	)

	# A `#` inside quotes is data. Without this, a server named "Bob's #1" is named
	# "Bob's — which is a name nobody typed and no error anywhere.
	_check(
		String(tree.get("hashed", "")) == "Bob's #1 server",
		"a # inside quotes is not a comment (%s)" % tree.get("hashed", "")
	)
	_done()


func _test_yaml_structure() -> void:
	_section("YAML structure")

	var tree := _parse("""
backend:
  type: rest
  verify:
    type: jwt
    key: secret
tags:
  - pvp
  - modded
flow: [kick, ban, mute]
groups:
  admin:
    permissions:
      - kick
      - ban
  moderator:
    permissions: [kick]
""")

	_check(
		String(TmcYaml.at(tree, "backend.type", "")) == "rest",
		"a nested map, by dotted path"
	)
	_check(
		String(TmcYaml.at(tree, "backend.verify.type", "")) == "jwt",
		"nested twice"
	)
	_check(
		TmcYaml.at(tree, "backend.missing.deep", "fallback") == "fallback",
		"and a missing path is the fallback, not a crash"
	)

	var tags: Variant = tree.get("tags")
	_check(tags is Array and (tags as Array).size() == 2, "a block sequence")
	_check(tags is Array and String((tags as Array)[0]) == "pvp", "with its values")

	var flow: Variant = tree.get("flow")
	_check(flow is Array and (flow as Array).size() == 3, "a flow sequence on one line")

	var permissions: Variant = TmcYaml.at(tree, "groups.admin.permissions")
	_check(
		permissions is Array and (permissions as Array).size() == 2,
		"a sequence two levels down"
	)
	_check(
		(TmcYaml.at(tree, "groups.moderator.permissions") as Array).size() == 1,
		"and a flow sequence beside a block one"
	)
	_done()


## What it refuses, and that it says which line.
##
## Every one of these is either a mistake or a feature this format does not have, and both
## are better as an error at boot than as a value nobody intended.
func _test_yaml_refusals() -> void:
	_section("YAML refusals")

	for entry in [
		["tabs", "a:\n\tb: 1", "tab"],
		["a duplicate key", "a: 1\na: 2", "duplicate"],
		["an anchor", "a: &anchor 1", "anchor"],
		["an alias", "a: *anchor", "anchor"],
		["a tag", "a: !!str 1", "anchor"],
		["a block scalar", "a: |", "anchor"],
		["an inline mapping", "a: {b: 1}", "inline mapping"],
		["a document marker", "---\na: 1", "document marker"],
		["an unclosed flow sequence", "a: [1, 2", "same line"],
		["a key with no colon", "just a line", "expected 'key: value'"],
	]:
		var result := TmcYaml.parse(String(entry[1]), "<test>")
		var message := str(result.error) if not result.ok else ""

		_check(
			not result.ok and message.contains(String(entry[2])),
			"%s is refused" % entry[0],
			"got: %s" % (message if message != "" else "accepted")
		)

	var located := TmcYaml.parse("a: 1\nb: 2\n\tc: 3", "cfg/server.yml")
	_check(
		not located.ok and str(located.error).contains("cfg/server.yml:3"),
		"and the refusal names the file and the line (%s)" % str(located.error)
	)
	_done()


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
		config.net.per_client_budget == 500000,
		"net_max_bps reaches the netcode's per-client budget (%d)"
			% config.net.per_client_budget
	)
	_check(config.public_address == "203.0.113.7", "net_public_ip is kept for the join line")
	_check(config.initial_game == "lobby", "sv_game names the boot game")
	# [b]Its own key, and not a console line.[/b] `sv_map` has no cvar and no command
	# behind it at this level — the `map` command belongs to whichever game is loaded,
	# and at read time that is none of them. So the check that matters is the negative
	# one below it: a key this parser did not claim would end up queued for a console
	# that will never have a `map`, which is exactly how it behaved before it was a
	# setting at all.
	_check(config.initial_map == "fixture_map", "sv_map names the boot map (%s)"
		% config.initial_map)
	_check(
		not config.console_lines.has("sv_map fixture_map"),
		"and is not queued for a console that has no `map` to give it to"
	)
	_check(
		Array(config.server.tags) == ["fixture", "test"],
		"sv_tags becomes a list (%s)" % [config.server.tags]
	)

	# A name nothing recognises is handed to the console rather than refused here: modules
	# register cvars this layer cannot know about at read time, so a name-based guess would
	# refuse every setting a game contributed.
	_check(
		config.console_lines.has("room_pellets 400"),
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
##
## [b]dot-log was in the dependency list and instantiated nowhere.[/b] `cfg/log.yml` has
## documented a level, per-channel levels, a mirror threshold and five file settings since
## it was written, and every one reached dot-core's plain rotating sink -- syslog, a hosted
## collector, a SQL table, redaction, flood gating and the ring behind `log tail` were
## installed, configured-for and unreachable.
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

	# [b]The shared settings are copied out of `server` rather than read twice.[/b] The
	# file's directory, name, rotation and JSON switch have to reach the router's file
	# target from the SAME keys that reach dot-core's sink, or a deployment that turns the
	# router on silently starts writing somewhere else.
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


## The guard, which was also in the dependency list and instantiated nowhere.
func _test_party() -> void:
	_section("parties and matchmaking")

	var loaded := TmcConfig.load_dir(CFG)
	var config := loaded.value as TmcConfig

	_check(config.files_read.has("party.yml"), "party.yml is read")
	_check(config.files_read.has("matchmaking.yml"), "and matchmaking.yml")
	_check(config.party_enabled and config.party_chat, "the two switches reach the host")
	_check(config.party_server_id == 42, "party_server_id reaches the booking keeper")
	# By prefix, onto the addon's own config: the table this file does not keep.
	_check(config.party.seat_hold_sec == 120.0, "party_seat_hold_sec reaches DotPartyConfig")
	_check(config.party.state_report_sec == 20.0, "and the roster report interval")
	_check(config.party_policy.enabled, "party_reserve_enabled reaches the owner's terms")
	# Written by NAME, as an operator writes it, and read as the enum.
	_check(
		config.party_policy.lobbies == DotPartyReservePolicy.Lobbies.PUBLIC_AND_PRIVATE,
		"a booking shape written by name is read as the enum (%d)" % config.party_policy.lobbies
	)
	_check(not config.party_policy.empty_only, "a bool reaches the terms")
	_check(
		config.party_policy.days.size() == 2 and config.party_policy.days[0] == 5
			and config.party_policy.days[1] == 6,
		"a list of days stays a typed list (%s)" % [config.party_policy.days]
	)
	# 22:00 to 02:00: the wrapped window the site's own rules have. 2026-09-26 is a
	# Saturday, and this is 23:00 UTC on it.
	_check(
		config.party_policy.window_open(1790463600),
		"a window crossing midnight is open late on a booking day"
	)

	_check(config.mm_enabled, "mm_enabled reaches the host")
	_check(config.mm_region == "eu", "and the region tickets are filed under")
	_check(is_equal_approx(config.matchmaking.tau, 0.6), "mm_tau reaches DotMatchmakingConfig")
	_check(config.mm_playlists.size() == 2, "two playlists, one per key (%d)" % config.mm_playlists.size())

	var duel: DotMmPlaylist = config.mm_playlists[0] if config.mm_playlists.size() > 0 else null
	_check(
		duel != null and duel.id == &"duel" and duel.team_size == 1 and duel.accept_timeout_sec == 15.0,
		"a playlist's settings reach it by their own names"
	)
	_check(config.mm_servers.has("eu1"), "mm_servers is kept for the allocator")

	var party_unknown := PackedStringArray()

	for entry in config.unknown:
		var text := String(entry)
		if text.contains("party") or text.contains("mm_") or text.contains("matchmaking"):
			party_unknown.append(text)

	_check(
		party_unknown.is_empty(),
		"and not one of them fell through as unknown",
		" / ".join(Array(party_unknown))
	)

	# The shipped defaults, restated because they are the decision: a booking is the
	# owner's opt-in, and a queue nobody configured is not running.
	var shipped := TmcConfig.new()
	_check(
		shipped.party_enabled and not shipped.party_policy.enabled and not shipped.mm_enabled,
		"shipped: parties on, bookings by parties off, matchmaking off"
	)

	_done()


## Where the replay section writes. Emptied at the start of every run, so a clip left by the
## last one cannot satisfy a check about this one (docs/testing.md, "a suite that writes to
## user://").
const REPLAY_DIR := "user://tmc_selftest_replay"


static func _rm_tree(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		_rm_tree(dir.path_join(sub))
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


static func _count_replays(dir: String) -> int:
	var da := DirAccess.open(dir)
	var n := 0
	if da != null:
		for f in da.get_files():
			if f.ends_with(".dreplay"):
				n += 1
	return n


## dot-replay was linked here and built nowhere. What this asserts: the ring is built by
## default and bounded, `replay save` writes a file dot-replay's own reader calls complete,
## and a ban or a kick carries the hash of a clip that is really on disk.
##
## Driven with no server: [TmcReplay] keeps everything a server is needed for in
## `install()`, and `./server check` asserts that half on a server that booted.
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
	_check(
		not bad._apply_replay({"replay_compression": "zip"}).ok,
		"a compression the addon does not have refuses replay.yml"
	)

	_rm_tree(REPLAY_DIR)

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
			and _count_replays(replay.directory.path_join("evidence")) == 1,
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
		_count_replays(replay.directory.path_join("clips")) <= 3,
		"clips/ keeps replay_keep_files and no more (%d)" % _count_replays(replay.directory.path_join("clips"))
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


## dot-friends was linked here and built nowhere. What this asserts: a site with no friends
## routes turns the client off, once, and a presence says where the player is as the
## connection comes and goes -- read back from the site's rules, not from what was posted.
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

	alice.on_playing("203.0.113.7:27015", "12", "Arena", "Fixture Server")
	alice.client.advance(0.5)
	await get_tree().process_frame
	var seen := hub.presence_seen_by("bob", "alice")
	_check(seen.status == DotPresence.Status.IN_GAME and seen.server_id == 12, "presence reflects a connect: in game, on server 12")
	_check(seen.joinable and seen.detail == "Playing Arena on Fixture Server", "joinable, with where (%s)" % seen.detail)

	alice.on_disconnected()
	alice.client.advance(0.5)
	await get_tree().process_frame
	seen = hub.presence_seen_by("bob", "alice")
	_check(
		seen.status == DotPresence.Status.ONLINE and seen.server_id == 0 and not seen.joinable,
		"and a disconnect: back on the menu, not followable"
	)

	# Following: the party when there is one, a server only where this shell has been.
	alice.on_playing("203.0.113.7:27015", "12", "Arena", "Fixture Server")
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
	bob.on_playing("203.0.113.7:27015", "12", "Arena", "Fixture Server")
	var followed: DotResult = await bob.join("alice")
	_check(followed.ok and dialled == ["203.0.113.7:27015"], "one it has is dialled at the address it knows (%s)" % [dialled])

	var gone_now: DotResult = await alice.go_offline()
	seen = hub.presence_seen_by("bob", "alice")
	_check(gone_now.ok and not seen.is_online(), "go_offline() on quit: offline to friends at once")

	alice.queue_free()
	bob.queue_free()
	_done()


func _test_security() -> void:
	_section("the guard")

	var loaded := TmcConfig.load_dir(CFG)
	var config := loaded.value as TmcConfig

	_check(config.security.enabled, "sec_enabled reaches the guard")
	# [b]The two dry runs are separate on purpose and the fixture sets them apart.[/b] An
	# operator commonly trusts the chat rules long before a movement threshold they have
	# not measured on their own maps, and a single switch for both would make that
	# unsayable — so the fixture says it, and this check would fail if they were merged.
	_check(config.security.dry_run, "sec_dryrun reaches the guard's own dry run")
	_check(not config.anticheat.dry_run, "and the detectors keep a separate one")
	_check(config.security.caps_ratio == 0.8, "a float reaches the chat detection")
	_check(config.security.duplicate_depth == 7, "an int reaches it too")
	_check(config.security.ledger_size == 128, "sec_ledger_size reaches the ledger")
	_check(
		Array(config.security.link_allow) == ["example.test"],
		"and a list stays a list (%s)" % [config.security.link_allow]
	)
	_check(config.anticheat.max_horizontal_speed == 420.0, "ac_max_speed reaches the detector")
	_check(config.anticheat.max_time_ratio == 1.02, "and the timing tolerance")

	var sec_unknown := PackedStringArray()

	for entry in config.unknown:
		var text := String(entry)
		if text.contains("sec_") or text.contains("ac_"):
			sec_unknown.append(text)

	_check(
		sec_unknown.is_empty(),
		"and not one of them fell through as unknown",
		" / ".join(Array(sec_unknown))
	)

	# The shipped default, restated here because it is the decision rather than the value:
	# an addon that starts punishing an existing community the moment it is installed is
	# one that gets turned off after the first false positive.
	_check(DotSecurityConfig.new().dry_run, "a guard nobody configured is in dry run")

	_done()


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

	# A permission name that is not a flag is REPORTED, never refused.
	#
	# Refusing would be worse: a game defines its own flags -- the fixture's `spawn_npc` is
	# one -- and this file cannot know them. (It was `slay`, until dot-server made `slay` a
	# standard flag for dot-moderation's live tools and this check started failing on a
	# name that had become real.) But silence was worse than either. `cfg/groups.yml`
	# shipped `warn`, `announce` and `change`, none of which is a flag, so the group called
	# `admin` granted kick, ban and mute and could not change the map, use admin chat, or
	# be recognised as staff. Every one of those reads as a correctly configured group that
	# mysteriously does not work.
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

	_test_deployed_map_clocks()
	_done()


## A deployed game whose map runs until it is voted out says so twice, and the two must
## agree: `<game>_map_seconds: "0"` stops the MAP session's timer, and the vote has a
## clock of its own. The playground shipped with the first and not the second, and was put
## to a ballot at twenty-eight minutes under people mid-build.
##
## Read off the real `content/`, not a fixture, because the contradiction is in a file an
## operator ships — and layered exactly as the game layers it, `metadata: map_vote:` over
## dot-vote's defaults, so what is asserted is what a running server would do.
func _test_deployed_map_clocks() -> void:
	var scanned := TmcContent.scan("res://content")

	if not _check(scanned.ok, "the shipped content scans", str(scanned.error)):
		return

	var content := scanned.value as TmcContent
	var untimed := PackedStringArray()
	var disagree := PackedStringArray()

	for descriptor in content.games:
		var stopped := false

		for name: Variant in descriptor.cvars:
			if str(name).ends_with("_map_seconds") and str(descriptor.cvars[name]).strip_edges() == "0":
				stopped = true

		if not stopped:
			continue

		untimed.append(descriptor.game_id)

		var overlay: Variant = descriptor.metadata.get("map_vote", {})
		var rules := DotVoteRules.new()
		var layered := rules.layer_over_defaults(
			"", overlay as Dictionary if overlay is Dictionary else {}
		)

		if (
			not layered.ok or not rules.validate().ok
			or rules.duration_sec > 0.0
			or rules.trigger != DotVoteRules.Trigger.RTV_ONLY
		):
			disagree.append("%s (trigger %s, duration %.0f)" % [
				descriptor.game_id, rules.enum_name("trigger"), rules.duration_sec
			])

	_check(
		untimed.has("playground"),
		"the playground ships with its map clock stopped (%s)" % ", ".join(untimed),
		"the check below is about nothing if no shipped game stops its map clock"
	)
	_check(
		disagree.is_empty(),
		"and every game that stops its map clock stops its vote's clock too: rtv_only, no duration",
		", ".join(disagree)
	)


## `end_vote`, `include_extend` and `extend_seconds` through `DOT_GAME_VOTE_*` and
## `--game-vote-*`, each in a child process, change what the server vote's ballot does.
##
## `_test_vote` checks one of the six as a parsed value; this asks the ballot. `vote.yml`'s
## own layer is `multigame`'s, on the real running server. `[mce-1]`.
func _test_vote_layers_reach_a_ballot() -> void:
	_section("the server vote's own layers reach a running ballot")

	var project := ProjectSettings.globalize_path("res://")

	var probe := func(extra: PackedStringArray, env: Dictionary) -> Dictionary:
		for key: String in env:
			OS.set_environment(key, env[key])
		var args := PackedStringArray([
			"--headless", "--path", project, "--script", "res://examples/vote_layer_probe.gd", "--",
		])
		args.append_array(extra)
		var out := []
		var _code := OS.execute(OS.get_executable_path(), args, out, true)
		for key: String in env:
			OS.unset_environment(key)
		var found := {}
		for line: String in "\n".join(PackedStringArray(out)).split("\n"):
			var trimmed := line.strip_edges()
			if trimmed.begins_with("{"):
				var parsed: Variant = JSON.parse_string(trimmed)
				if parsed is Dictionary:
					found = parsed
		return found

	var control: Dictionary = probe.call(PackedStringArray(), {})
	_check(
		control.get("opened") == true and control.get("extend_offered") == true
			and is_equal_approx(float(control.get("extended_by", -1.0)), 600.0),
		"with neither layer, the fixture's ballot opens, offers Extend, and adds 600 s",
		str(control)
	)

	var cases := [
		["end_vote", "false", "opened", false],
		["include_extend", "false", "extend_offered", false],
		["extend_seconds", "90", "extended_by", 90.0],
	]

	for case: Array in cases:
		var key: String = case[0]

		for layer in ["DOT_GAME_VOTE_*", "--game-vote-*"]:
			var extra := PackedStringArray()
			var env := {}

			if layer == "DOT_GAME_VOTE_*":
				env["DOT_GAME_VOTE_" + key.to_upper()] = case[1]
			else:
				extra.append("--game-vote-%s=%s" % [key, case[1]])

			var got: Dictionary = probe.call(extra, env)
			var seen: Variant = got.get(case[2])
			var want: Variant = case[3]
			var same: bool = is_equal_approx(float(seen), float(want)) \
				if want is float else seen == want
			_check(
				got.get("layered") == true and same,
				"%s from %s: the ballot's %s is %s" % [key, layer, case[2], str(want)],
				str(got)
			)

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
		Array(config.vote_exclude) == ["lobby", "playground"],
		"and names the games that are never on a ballot (%s)" % [config.vote_exclude],
		"which is TMC's question rather than dot-vote's: a lobby is not a game"
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


## The game vote's HUD: what the template asks the shell to play, and what the shell does
## with a notice.
##
## [b]Two copies of one list, checked against each other, because they cannot be one.[/b]
## The cue ids are named by the SERVER's configuration and played out of the CLIENT's
## catalogue, and the client is a different build — host/ is not in it. So the ids are
## written twice by necessity, and this is the check that the two agree: a template
## naming a cue the shell has no def for is a vote that is silent for every player, with
## nothing erroring anywhere, because dot-audio treats an unknown id as silence on purpose.
func _test_vote_notices() -> void:
	_section("the game vote on the shell's HUD")

	var parsed := TmcYaml.parse_file("res://cfg.example/vote.yml")

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

	# [b]The case that shipped: a file nothing read.[/b] `TmcConfig.auth` was parsed and
	# handed to a TmcAuth that did not exist, so a server advertised `auth=none`,
	# everybody arrived as a guest, and `permissions.yml` did nothing -- which is
	# indistinguishable from a deployment that chose not to authenticate.
	var off := TmcAuth.build({}, "cfg")
	_check(off.ok and off.value == null, "no auth.yml at all is a guest server, not an error")

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

	# TICKET without a server_id is the replay hole: a ticket that names no audience is
	# a ticket every server accepts. DotAuthConfig.validate refuses it and this is the
	# check that the refusal reaches an operator rather than being swallowed here.
	var work := "user://tmc_auth_test"
	DotPaths.remove_tree(work)
	DotPaths.ensure_dir(work)

	var pub := work.path_join("issuer.pub.pem")
	DotPaths.write_text(pub, "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----\n")

	var no_id := TmcAuth.build({
		"enabled": true, "strategy": "ticket", "issuer_public_key_file": "issuer.pub.pem",
	}, work)
	_check(not no_id.ok, "a ticket server with no server_id is refused")

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
	_check(not missing.ok, "a key file that is not there names the path it looked at")

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

	DotPaths.remove_tree(work)
	_done()
