class_name SelftestServerFeatures
extends RefCounted

## Party, bot recording, radio, security and the startup checks. Run by `selftest.gd`, which keeps the counters: every check goes through its `_check`.

const CFG := "res://examples/fixtures"
const Host := preload("res://host/tmc_host.gd")

var t: Node


func _init(p_test: Node) -> void:
	t = p_test


func _section(title: String) -> void:
	t._section(title)


func _done() -> void:
	t._done()


func _check(condition: bool, what: String, detail: String = "") -> bool:
	return t._check(condition, what, detail)


func _put(path: String, text: String) -> void:
	t._put(path, text)


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
	# 22:00 to 02:00: the wrapped window the site's own rules have.
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


## GameSpice Replay was linked here and built nowhere. What this asserts: the ring is built by default and
## bounded, `replay save` writes a file GameSpice Replay's own reader calls complete, and a ban or a kick
## carries the hash of a clip that is really on disk.
func _test_bot_record() -> void:
	_section("the bot demonstration recorder")
	var config := TmcConfig.load_dir(CFG).value as TmcConfig
	_check(config.files_read.has("bot_record.yml"), "bot_record.yml is read")
	_check(
		not config.bot_record.record and config.bot_record.rate == 8.0 and config.bot_record.cap == 50
			and config.bot_record.store == "memory" and config.bot_record.kinds == "ride",
		"bot_record, bot_record_rate, _cap, _store and _kinds reach DotBotDemoConfig"
	)
	var stray := PackedStringArray()
	for entry in config.unknown:
		if String(entry).contains("bot_record"):
			stray.append(String(entry))
	_check(stray.is_empty(), "and none fell through as unknown", " / ".join(Array(stray)))
	var shipped := TmcConfig.new()
	_check(shipped.bot_record.record and shipped.bot_record.validate().ok, "shipped: on, and valid")
	# The shipped template parses to the shipped defaults.
	var tpl := TmcYaml.parse_file("res://cfg.example/addon/dot_bot_record/bot_record.yml")
	_check(tpl.ok and (tpl.value as Dictionary).has("bot_record_token"), "the template documents every key")
	if tpl.ok:
		var probe := TmcConfig.new()
		var applied := probe._apply_bot_record(tpl.value as Dictionary)
		_check(applied.ok and probe.unknown.is_empty(), "and the template is accepted whole", str(probe.unknown))
		var missing := PackedStringArray()
		for k in probe.bot_record.config_keys():
			var key := "bot_record" if k == "record" else "bot_record_" + k
			if not (tpl.value as Dictionary).has(key):
				missing.append(key)
		_check(missing.is_empty(), "no DotBotDemoConfig property is missing from it", ", ".join(missing))
	_done()


func _test_radio() -> void:
	_section("dot-radio, optional")
	var root := "user://selftest_radio_cfg"
	DotPaths.remove_tree(root)
	DotCfgLegacy.reset()
	var template := TmcYaml.parse_file("res://cfg.example/addon/dot_radio/radio.yml")
	_check(template.ok and template.value is Dictionary, "the shipped radio.yml parses")
	var shipped: Dictionary = template.value if template.ok else {}
	var keys_known := true
	for k in shipped:
		keys_known = keys_known and TmcConfig.RADIO_KEYS.has(String(k))
	_check(keys_known and shipped.get("radio_enabled", true) == false, "every shipped key is known and the radio is off")
	_check(not TmcConfig.new().radio_enabled, "no radio.yml means no radio")
	_put(root + "/radio.yml", "radio_enabled: true\nradio_port: 9911\nradio_token_file: t.token\nradio_typo: 1\n")
	var cfg: TmcConfig = TmcConfig.load_dir(root).value
	_check(cfg.radio_enabled and int(cfg.radio.get("radio_port", 0)) == 9911, "radio.yml turns it on and carries its keys")
	_check("\n".join(cfg.unknown).contains("radio_typo"), "an unknown radio_ key is reported")
	var present := TmcRadio.available()
	var host := Node.new()
	var off := TmcRadio.install(host, null, TmcConfig.new(), root)
	_check(off == null and host.get_child_count() == 0, "disabled builds nothing")
	var absent: TmcRadio = null if present else TmcRadio.install(host, null, cfg, root)
	_check(present or (absent == null and host.get_child_count() == 0), "enabled without the addon is a warning, not a crash")
	var link := TmcRadioLink.new()
	_check(not link.adopt({}) and link.radio == null, "the shell ignores a notice with no url")
	_check(present or not link.adopt({"url": "http://x"}), "and without the addon in the shell build builds no client")
	var live := false
	if present:
		_put(root + "/t.token", "secret-token\n")
		cfg.radio["radio_token_file"] = ProjectSettings.globalize_path(root + "/t.token")
		cfg.radio["radio_port"] = 0
		cfg.radio["radio_dir"] = ProjectSettings.globalize_path(root + "/lib")
		var on := TmcRadio.install(host, null, cfg, ProjectSettings.globalize_path(root))
		live = on != null and DotRegistry.get_service(TmcRadio.SERVICE) != null and on.api.authenticate("secret-token").ok
		if on != null:
			on.free()
	_check(not present or live, "with the addon: the station starts, registers, and the token file is the admin token")
	host.free()
	link.free()
	_done()


func _test_security() -> void:
	_section("the guard")

	var loaded := TmcConfig.load_dir(CFG)
	var config := loaded.value as TmcConfig

	_check(config.security.enabled, "sec_enabled reaches the guard")
	# [b]The two dry runs are separate on purpose and the fixture sets them apart.[/b] An operator
	# commonly trusts the chat rules long before a movement threshold they have not measured on their
	# own maps, and a single switch for both would make that unsayable — so the fixture says.
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


## A game older than the list asks for, and a `map:` for a game without a DotMapSession: each ends in a logged ERROR, not a yellow warning nobody reads.
func _test_startup_checks() -> void:
	_section("startup: an old game and a map path of the game's own")

	var state_path := OS.get_user_data_dir().path_join("selftest-behind-state.json")
	var f := FileAccess.open(state_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"installed": {}, "behind": {"game-zombie-zone": {"wanted": "latest", "why": "needs dot_core 40"}}}))
	f.close()
	var entry := Host.behind_entry(state_path, "game-zombie-zone")
	_check(str(entry.get("wanted", "")) == "latest" and str(entry.get("why", "")) == "needs dot_core 40",
		"a game the installer kept older than asked is read back as behind (%s)" % entry)
	_check(Host.behind_entry(state_path, "buses").is_empty(), "and a game that is current is not")
	DirAccess.remove_absolute(state_path)

	var root := Node.new()
	var holder := Node.new()
	root.add_child(holder)
	var starter := _MapStarter.new()
	holder.add_child(starter)
	_check(TmcMapGame.starter_in(root) == starter, "a game that answers start_on_map is found for `map:` (Zombie Zone has no map session)")
	holder.remove_child(starter)
	starter.free()
	_check(TmcMapGame.starter_in(root) == null, "and a game with neither is not, so the host logs an ERROR instead")
	root.free()

	# A map director held by a module sits under the modules node, not the games node; the host searches both.
	var games_node := Node.new()
	var modules_node := Node.new()
	var module_holder := Node.new()
	modules_node.add_child(module_holder)
	var module_starter := _MapStarter.new()
	module_holder.add_child(module_starter)
	_check(TmcMapGame.starter_in([games_node, modules_node]) == module_starter, "a map director held by a module is found when the games and modules are searched together")
	_check(TmcMapGame.starter_in(games_node) == null, "and is not found under the games alone")
	games_node.free()
	modules_node.free()

	_done()


## What refuses boot: an old game, a map path that is not the game's, and a cache ceiling that is not a byte count.
func _test_boot_refusals() -> void:
	_test_startup_checks()
	_test_cache_limit()


## The content cache ceiling: unlimited by default on a server, a byte count or nothing, and the line that says what it is.
func _test_cache_limit() -> void:
	_section("the content cache ceiling (cache_bytes)")

	for pair in [["", 0], ["0", 0], [0, 0], ["1048576", 1048576], ["20G", 20 * 1073741824], ["512 MiB", 512 * 1048576], ["3kb", 3072], [8589934592, 8589934592]]:
		var got := TmcCloudLimit.parse(pair[0])
		_check(got.ok and int(got.value) == int(pair[1]), "cache_bytes '%s' is %d bytes (%s)" % [str(pair[0]), int(pair[1]), str(got.value)])

	for bad in ["-1", "lots", "1.5G", "20X", "G"]:
		var refused := TmcCloudLimit.parse(bad)
		_check(not refused.ok and str(refused.error).contains("cache_bytes") and str(refused.error).contains(TmcCloudLimit.WHERE), "cache_bytes '%s' refuses boot, naming where it is set" % bad)

	var cfg := TmcConfig.new()
	_check(TmcConfig.HOST_KEYS.has("cache_bytes"), "cache_bytes is a server.yml host key")
	_check(cfg.cache_bytes == "" and cfg.describe_lines().has("cache    : unlimited"), "a server with nothing written is unlimited, and ./server config says so")
	cfg._apply_settings("server.yml", {"cache_bytes": "20G"})
	_check(cfg.cache_bytes == "20G" and cfg.describe_lines().has("cache    : 20.0 GiB"), "cache_bytes: 20G reaches the config and the summary (%s)" % cfg.cache_bytes)
	# A loop, not `.any()`: `unknown` is a PackedStringArray, which has none of Array's higher-order methods.
	var reported := false
	for entry in cfg.unknown:
		reported = reported or String(entry).contains("cache_bytes")
	_check(not reported, "and is not reported unknown")
	_check(cfg.check_boot_values().ok, "a byte count and the default announce mode pass the boot check")
	cfg.cache_bytes = "lots"
	_check(not cfg.check_boot_values().ok and str(cfg.check_boot_values().error).contains("cache_bytes"), "a ceiling that is not a byte count fails it, by name")

	var cloud := DotCloudConfig.new()
	var dir := OS.get_user_data_dir().path_join("selftest-cache-limit")
	cloud.cache_dir = dir
	_check(cloud.cache_bytes > 0, "dot-cloud's own default is a ceiling (%d), which is why the server sets one" % cloud.cache_bytes)
	TmcCloudLimit.apply(cloud, 0, "selftest", dir.path_join("absent.json"))
	_check(cloud.cache_bytes == 0, "the server's cloud config is unlimited")
	_check(not ("limit_hint" in cloud) or str(cloud.get("limit_hint")) == TmcCloudLimit.WHERE, "and a dot-cloud that names a hint in its quota refusal names the server's key")
	var json := dir.path_join("content.json")
	var f := FileAccess.open(json, FileAccess.WRITE)
	f.store_string(JSON.stringify({"cache_bytes": 0, "trusted_keys": []}))
	f.close()
	_check(TmcCloudLimit._file_override(json).contains("cache_bytes=0"), "a cache_bytes in the cloud config file, which dot-cloud applies over this, is named")
	_check(TmcCloudLimit._file_override(dir.path_join("absent.json")) == "", "and a file without one is not")
	DirAccess.remove_absolute(json)
	DirAccess.remove_absolute(dir)

	_done()


class _MapStarter extends Node:
	func start_on_map(_id: StringName) -> DotResult:
		return DotResult.success(null)
