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

const CHECKS := 162

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
	_test_auth()
	_test_logging()
	_test_security()
	_test_party()

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
