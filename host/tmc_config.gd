class_name TmcConfig
extends RefCounted

## The `cfg/` directory, read into everything a server needs. Where a key names something the console knows it becomes a console command (the console is the parser, validator,
## clamp, permission check and audit trail; `sv_maxplayers: 64` is the line `sv_maxplayers 64`); what the console cannot reach (the port, the bind address) goes to the boot config;
## the rest is handed to its owner. An unknown key is reported, never fatal, as `DotConfig` does: refusing to boot over a newer version's setting is worse than ignoring it.

const CHANNEL := "tmc.config"

## The files read, in the order they are applied: `net.yml` after `server.yml`, so a network setting wins over a general one naming the same thing.
const FILES := [
	"server.yml", "net.yml", "log.yml", "rcon.yml", "auth.yml", "groups.yml",
	"permissions.yml", "vote.yml", "security.yml", "party.yml", "matchmaking.yml",
	"replay.yml", "admin_menu.yml", "loading.yml", "radio.yml", "trail.yml", "bot_record.yml",
]

## The operator's base directory under `cfg/`: `server.yml` and any other flat server file. Never touched by an update.
const SERVER_DIR := "server"
## Files in it that another loader reads.
const SERVER_DIR_OWNED := ["content.yml"]

## Operator-facing name -> boot config property, for what the console cannot reach. Two vocabularies are paid for deliberately:
## an operator writes `net_port`, dot-server calls it `port`, and the alternative is renaming a published cvar.
const BOOT_KEYS := {
	"net_port": "port",
	"net_bind_ip": "bind_address",
	# dual (WebSocket for browsers + ENet over UDP for native clients, one match),
	# websocket, or enet. See DotServerConfig.transport_mode.
	"net_transport": "transport_mode",
	# ENet's UDP port; 0 is the game port's number, shared with A2S/DQP through a demux.
	"net_enet_port": "enet_port",
	# Empty follows query_bind_ip: behind nginx the UDP side must face the world itself.
	"net_enet_bind_ip": "enet_bind_address",
	"net_enet_share_udp": "enet_share_udp_port",
	"sv_name": "hostname",
	"sv_id": "server_id",
	"sv_maxplayers": "max_players",
	"sv_reserved_slots": "reserved_slots",
	"sv_tickrate": "tickrate",
	"sv_password": "password",
	"rcon_password": "rcon_password",
	"rcon_port": "rcon_port",
	"rcon_allowed": "rcon_allowed_addresses",
	"rcon_websocket": "rcon_websocket",
	"query_enabled": "query_enabled",
	"query_websocket": "query_websocket",
	"query_port": "query_port",
	# The one setting a reverse-proxied server cannot do without: nginx forwards the
	# game's WebSocket and cannot forward UDP, so a query listener sharing
	# `net_bind_ip` binds loopback and no tracker on earth can reach it.
	"query_bind_ip": "query_bind_address",
	"a2s_enabled": "a2s_enabled",
	"a2s_port": "a2s_port",
	"content_manifest_url": "content_manifest_url",
	# dot-server documents this as the one stdin decision that is a real decision, and it was unreachable because YAML is this deployment's only surface.
	# A server whose stdin carries something other than commands needs it, and so does anything running two servers in one process:
	# [DotStdinConsole] is a thread blocked in a read the engine cannot cancel, so the second keeps the process alive.
	"sv_stdin_console": "stdin_console_enabled",
	# And whether a PIPE counts (dot-server 5f46687): off by default, because a reader blocked on a pipe whose writer never closes keeps the process from exiting.
	# TMC's panel talks RCON and neither the Docker image nor the systemd unit gives the server a stdin, so the default stands.
	"sv_stdin_console_pipes": "stdin_console_pipes",
	# log.yml. The level is the one an operator changes most often and the one they most
	# often cannot find: it is not a cvar, because it has to apply before the console
	# exists in order to cover the boot it is being raised to diagnose.
	"log_level": "log_level",
	"log_channels": "log_channel_levels",
	"log_mirror_level": "log_mirror_min_level",
	"log_file": "log_file_enabled",
	"log_dir": "log_directory",
	"log_name": "log_basename",
	"log_json": "log_json",
	"log_max_bytes": "log_max_file_bytes",
	"log_keep": "log_max_files",
}

## Operator-facing name -> netcode config property.
const NET_KEYS := {
	"net_max_bps": "per_client_budget",
	"net_max_pps": "per_client_packet_rate",
	"net_max_update_rate": "snapshot_rate",
	"net_mtu": "mtu",
	"net_interp_buffer": "interpolation_buffer",
	"net_max_entities": "max_entities_per_snapshot",
	# Relevance: who is sent what. The radius is a ceiling on the game's, the far pair replaces it.
	"net_interest_radius": "interest_radius",
	"net_far_every": "far_every",
	"net_far_distance": "far_distance",
	# Replaces the game's value (off unless written): peers spread over the ticks between snapshots.
	"net_stagger_snapshots": "stagger_snapshots",
}

## Operator-facing name -> [code]DotLogConfig[/code] property, only what dot-log adds: the level, channels, mirror threshold and file settings are in [constant BOOT_KEYS]
## already (a server without dot-log has them through dot-core's sink) and are copied across in [method build_log_router]; two lists for one fact is this tree's most repeated bug.
## [code]log_router[/code] is NOT here: it decides whether the router is built, and is handled by name in [method _apply_settings].
const LOG_KEYS := {
	"log_ring": "memory_enabled",
	"log_ring_size": "memory_capacity",
	"log_service": "service",
	"log_env": "env",
	"log_instance": "instance",
	"log_version": "version",
	"log_syslog": "syslog_enabled",
	"log_syslog_host": "syslog_host",
	"log_syslog_port": "syslog_port",
	"log_syslog_tcp": "syslog_tcp",
	"log_syslog_app": "syslog_app",
	"log_syslog_level": "syslog_level",
	"log_remote": "remote_enabled",
	"log_remote_format": "remote_format",
	"log_remote_url": "remote_url",
	"log_remote_token": "remote_token",
	"log_remote_level": "remote_level",
	"log_remote_batch": "remote_batch",
	"log_remote_tags": "remote_tags",
	"log_sentry_dsn": "sentry_dsn",
	"log_redact": "redact_enabled",
	"log_redact_ips": "redact_ips",
	"log_redact_emails": "redact_emails",
	"log_redact_keys": "redact_drop_keys",
	"log_dedupe_sec": "dedupe_window_sec",
	"log_rate_per_channel": "per_channel_rate",
}

## The files each addon reads itself, through its own layered loader (`cfg/addons/<addon>/`, the
## game's, the operator's `cfg/server/addons/<addon>/`, then the flat file here until 2026-12-31).
## Each addon owns its key table, so this file keeps no second copy that goes stale.
const LAYERED := {
	"security.yml": "dot-server-security",
	"party.yml": "dot-party",
	"replay.yml": "dot-replay",
	"bot_record.yml": "dot-bot-record",
	"matchmaking.yml": "dot-matchmaking",
	"groups.yml": "dot-server",
	"permissions.yml": "dot-server",
	"admin_menu.yml": "dot-menu",
	"log.yml": "dot-log",
	"rcon.yml": "dot-console",
	"auth.yml": "dot-auth",
	"vote.yml": "dot-vote",
	"loading.yml": "dot-core",
	"radio.yml": "dot-radio",
	"trail.yml": "dot-trail",
}

## Key prefix in `server.yml` -> the addon folder that owns it now (`cfg/addons/<addon>/`). Still
## applied from `server.yml` until DotCfgLegacy's cutoff, with one WARN naming the keys.
## `rcon_password` stays where it is: a secret may live in `server.yml` or the addon's folder.
const LEGACY_KEYS := {
	"log_": "dot_log",
	"rcon_": "dot_console",
}

## Keys that exist and are handled somewhere other than a config object, listed so they are not reported as unknown (a key silently ignored and not reported looks like it took effect).
## `net_public_ip` is here, not in [constant BOOT_KEYS], because dot-server should have no such setting: what a server binds to and what a player types differ, and only the second is behind NAT.
const HANDLED_ELSEWHERE := ["sv_content_dir"]

## The boot configuration, after every file has been applied.
var server: DotServerConfig = DotServerConfig.new()


func _init() -> void:
	# TMC's scanner speaks A2S, so a server with no cfg file naming it must still answer.
	server.a2s_enabled = true

## The operator's net settings as written in cfg (a [DotNetConfig] with its defaults
## for the rest). Nothing reads this directly: a game builds its own [DotNetConfig], so
## these numbers only matter through [method net_ceiling].
var net: DotNetConfig = DotNetConfig.new()

## The [DotNetConfig] properties the operator actually wrote, so [method net_ceiling]
## does not pass off a DotNetConfig default as an operator limit.
var _net_written: PackedStringArray = []

## What dot-log adds on top of the file every server already writes. Only the router-only half is read into it, see [constant LOG_KEYS];
## the rest is copied out of [member server] by [method build_log_router], so there is one list.
var log: DotLogConfig = DotLogConfig.new()

## Whether the sink layer is built at all: [code]"auto"[/code], [code]"on"[/code] or [code]"off"[/code].
## `auto` is on: the router is a strict superset of the file every server writes, so it costs nothing and buys `log tail`, `log grep` and `log test`. `off` is for a box that wants the plain sink.
var log_router: String = "auto"

## The guard, after every file has been applied. Its keys are [constant DotSecurityConfig.CFG_KEYS].
var security: DotSecurityConfig = DotSecurityConfig.new()

## The detectors. Separate dry run, deliberately. Its keys are [constant DotAntiCheatConfig.CFG_KEYS].
var anticheat: DotAntiCheatConfig = DotAntiCheatConfig.new()

## `party.yml`: the timings both party nodes read. Every [DotPartyConfig] property,
## written with a `party_` prefix — `party_seat_hold_sec: 120`. See [method _apply_party].
var party: DotPartyConfig = DotPartyConfig.new()

## `party.yml`: this server's terms for a party booking it, written `party_reserve_*`. Ships with [member DotPartyReservePolicy.enabled] off, as the site does,
## so an owner opts in; a booking made at the console with `party_reserve` is the owner's own act and is not held to it.
var party_policy: DotPartyReservePolicy = DotPartyReservePolicy.new()

## Whether this server takes part in parties at all. On: a server with no backbone still
## gets console bookings and party chat, and one with no booking admits everybody.
var party_enabled: bool = true

## Whether each game's chat router gets a grouped `party` channel. See [TmcParty].
var party_chat: bool = true

## This server's id on the backbone, for bookings a local hub would make. 0 is none.
var party_server_id: int = 0

## `matchmaking.yml`: the queue's own settings, written `mm_*` over [DotMatchmakingConfig].
var matchmaking: DotMatchmakingConfig = DotMatchmakingConfig.new()

## Off unless `matchmaking.yml` says so. A matchmaker with no playlists queues nobody,
## and a server that silently ran one would be a server answering `mm_queue` for a queue
## that can never fill.
var mm_enabled: bool = false

## The region every ticket from this server is filed under. The matchmaker places a match
## on a server in the ticket's region, so it has to be the same word `mm_servers` uses.
var mm_region: String = "local"

## `mm_playlists:`, one mapping per queue, each built into a [DotMmPlaylist].
var mm_playlists: Array[DotMmPlaylist] = []

## `mm_servers:`, id -> {address, region, playlists}. Empty means a ready match carries no
## allocation and the players are told who they are playing with and nothing about where.
var mm_servers: Dictionary = {}

## `replay.yml`: every [DotReplayConfig] property written with a `replay_` prefix (`replay_ring_seconds: 120`). See [method _apply_replay] and [TmcReplay].
## `directory` starts empty, and empty means `<data>/replays`: the addon's `user://replays` is outside `data/`, the one directory a container mounts writable, so a clip written there is evidence nobody can find.
var replay: DotReplayConfig = _replay_defaults()

## `bot_record.yml`: the demonstration recorder's settings, every [DotBotDemoConfig] property
## written `bot_record_<name>` (`record` is `bot_record`). Empty `path` means `<data>/bot/demos`.
## Handed to the game through [DotRegistry] as `bot_record_config`; see [TmcHost].
var bot_record: DotBotDemoConfig = DotBotDemoConfig.new()

## Whether the replay ring is built at all. On: see [TmcReplay] for what it costs.
var replay_enabled: bool = true

## Whether every match is also written to a file under `replays/matches/`. Off: the ring is
## the evidence a moderator needs, and a demo of every match is disk nobody asked for.
var replay_record: bool = false

## A kick or a ban issued on this server saves a clip and files its final hash with the
## punishment. See [method TmcReplay.evidence_clip].
var replay_clip_on_punish: bool = true

## How much of the ring an evidence clip keeps, in seconds. 0 is everything it holds.
var replay_clip_seconds: float = 0.0

## Punishments this close together share one clip. A ban is followed by its own kick, and
## a guard that removes ten bots in a second is one incident, not ten files.
var replay_evidence_cooldown_sec: float = 10.0

## Each of `matches/`, `clips/` and `evidence/` keeps at most this many files ...
var replay_keep_files: int = 50

## ... and at most this many MiB. The oldest go first.
var replay_keep_mib: int = 512

## Console commands to run once the console exists, in file order.
var console_lines: PackedStringArray = PackedStringArray()

## `groups.yml`, as parsed. Group name -> {is_root, permissions, immunity}.
var groups: Dictionary = {}

## `permissions.yml`, as parsed. User -> {group, permissions, immunity}.
var users: Dictionary = {}

## `auth.yml`, as parsed. Handed to [TmcAuth], which is the only thing that reads it.
var auth: Dictionary = {}

## `vote.yml`, as a real [DotVoteRules]. Applied through [method DotConfig.apply_dictionary] rather than key by key, because that reads an enum by name and coerces every scalar through the property's type,
## the same path `DOT_GAME_VOTE_*` takes (see [method _layer_vote_overrides]); a second table would be a second place for `method: instant_runoff` to mean something else.
var vote: DotVoteRules = DotVoteRules.new()

## `admin_menu.yml`, as parsed. Handed to [TmcAdminMenu], which is the only thing that
## reads it and reports its own problems — the menu's vocabulary is its own, not the
## console's.
var admin_menu: Dictionary = {}

## `loading.yml`, as parsed. Handed to [TmcLoading], for the same reason.
var loading: Dictionary = {}

## `radio.yml` (dot-radio, optional): the `radio_*` keys, validated by [method _apply_radio]. Off by default; handed to [TmcRadio].
var radio: Dictionary = {}
var radio_enabled: bool = false
## `trail.yml` (dot-trail, optional): the `trail_*` keys, read by [method TmcTrail.apply_config].
var trail: Dictionary = {}

## Game ids `vote.yml` says are never on a ballot. Not a [DotVoteRules] setting: which things in `content/` count as games a player would choose is this deployment's question, and dot-vote should not have an opinion.
var vote_exclude: PackedStringArray = PackedStringArray()

## The game to load at boot, or "" for whatever the content directory says is first.
var initial_game: String = ""

## The site's web loader version this server's browser players should get, or "" for the site's default. Reported as the NOTIFY cvar `sv_web_loader` (see `TmcHost._register_web_loader`).
## A host field and not a console line, as `sv_game` is: the cvar is registered after dot-server boots, and the YAML's console lines run during that boot, so it would be dropped as unknown.
## Unlike `sv_web_build` (a fact about the checkout) it is the operator's, for a server deliberately behind the site's default.
var web_loader: String = ""

## The map to start that game on, or "" for the game's own default: `sv_map` in the YAML, `--map`, and `+map` after a `--`. A request, not a guarantee: the game decides whether it has maps
## and the id must be in its catalogue; both are reported and neither is fatal, since a server that refuses to boot over a map name cannot be got back.
## Deliberately NOT per-game: `--g2g-initial-map` exists, but saying it needs the game's config prefix, which is the difficulty on a box that runs seven.
var initial_map: String = ""

## The only games this server offers, or empty for everything in the content directory: `games` in the YAML, `--games a,b,c`, `TMC_GAMES` in a container.
## A filter, not an installer (`tools/install_games.gd` puts descriptors on disk): the `games` listing, `changelevel`, the vote menu and the boot game all read the scanned set,
## so the scan is where it must apply or the other three offer a game this server was told not to run. Empty means everything, not none; an id not on disk is reported, not fatal (the pack may still be downloading).
var games_allow: PackedStringArray = PackedStringArray()

## Where this server fetches content it does not have, in order: `content_urls` in the YAML. Empty means only packs already on disk (`content/`, `dist/`) can be used.
## This is how a cloned server gets its maps: `maps/imported/` is gitignored, so a clone has the game and none of its maps, which live on the content origin; the browser client always had a base URL, the server did not.
var content_urls: PackedStringArray = PackedStringArray()

## The app's URL segment on the website, reported in a query as the game's name: `sv_query_app` in the YAML, empty falling back to the running game's id.
## Display only: a server can claim any app, so nothing that must be certain (a launch resolving a build, a play grant) reads this; those ask the backbone.
var app_url: String = ""

## The address a player types, when it is not the one the server binds to (behind NAT only the operator knows). Printed in the join line and reported in the listing; nothing binds to it.
var public_address: String = ""

## Keys that were seen and did not correspond to anything, collected so a file with three typos produces three warnings at boot rather than one abort.
var unknown: PackedStringArray = PackedStringArray()

## Files that were present and files that were not.
var files_read: PackedStringArray = PackedStringArray()
var files_missing: PackedStringArray = PackedStringArray()


## Reads a whole `cfg/` directory. A missing file is not an error (no RCON means no reason to carry an `auth.yml`); a file that is *present and malformed* is, and names the line.
static func load_dir(directory: String) -> DotResult:
	var config := TmcConfig.new()
	var base := directory.rstrip("/")
	DotAddonConfig.config_root = base

	for name in FILES:
		if LAYERED.has(name):
			var layered := config._load_layered(name, base)
			if not layered.ok:
				return layered
			continue

		var path := config._flat_path(name, base)

		if path == "":
			config.files_missing.append(name)
			continue

		var parsed := TmcYaml.parse_file(path)

		if not parsed.ok:
			return parsed.wrap("Could not read %s" % path)

		var tree: Variant = parsed.value

		if not (tree is Dictionary):
			return DotResult.fail(
				DotError.CODE_PARSE, "%s must contain a mapping." % path
			)

		config.files_read.append(name)
		if name == "net.yml":
			config._warn_legacy_file(path, "cfg/server/server.yml (the same net_* keys)")
		if name == "server.yml":
			config._warn_legacy_keys(path, tree as Dictionary)
		var applied := config._apply(name, tree as Dictionary)

		if not applied.ok:
			return applied

	var extra := config._load_server_extras(base)
	if not extra.ok:
		return extra

	config._layer_vote_overrides()
	config._layer_party_overrides()
	config._layer_replay_overrides()
	config._layer_bot_record_overrides()

	var valid := config.server.validate()

	if not valid.ok:
		return valid.wrap("The configuration in %s is not usable" % base)

	return DotResult.success(config)


## `server.yml` lives in `cfg/server/` now; the flat `cfg/server.yml` is read until DotCfgLegacy's cutoff, and the new one wins whole.
func _flat_path(name: String, base: String) -> String:
	if name == "server.yml":
		return DotCfgLegacy.find("%s/%s" % [base, name], "%s/%s/%s" % [base, SERVER_DIR, name])
	var path := "%s/%s" % [base, name]
	return path if FileAccess.file_exists(path) else ""


## Every other `cfg/server/*.yml` the loaders below do not own: more flat server keys, applied after `net.yml` in name order.
func _load_server_extras(base: String) -> DotResult:
	var dir := DirAccess.open("%s/%s" % [base, SERVER_DIR])
	if dir == null:
		return DotResult.success(null)
	var names := Array(dir.get_files())
	names.sort()
	for file: String in names:
		if not file.ends_with(".yml") or file in FILES or file in SERVER_DIR_OWNED:
			continue
		var path := "%s/%s/%s" % [base, SERVER_DIR, file]
		var parsed := TmcYaml.parse_file(path)
		if not parsed.ok:
			return parsed.wrap("Could not read %s" % path)
		if parsed.value == null:
			continue
		if not (parsed.value is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "%s must contain a mapping." % path)
		files_read.append("%s/%s" % [SERVER_DIR, file])
		var applied := _apply("server.yml", parsed.value as Dictionary)
		if not applied.ok:
			return applied
	return DotResult.success(null)


## One WARN per file that moved but is merged, not replaced, so DotCfgLegacy.find (which picks one) does not fit.
func _warn_legacy_file(path: String, new_home: String) -> void:
	if DotCfgLegacy._warned.has(path):
		return
	DotCfgLegacy._warned[path] = true
	DotLog.warn("cfg", "legacy config file %s: still read after server.yml; move its keys to %s before %s" % [
		path, new_home, DotCfgLegacy.REMOVE_AFTER], {"old": path, "remove_after": DotCfgLegacy.REMOVE_AFTER})


## One WARN naming the subsystem keys of `server.yml` that have an addon folder ([constant LEGACY_KEYS]).
func _warn_legacy_keys(path: String, tree: Dictionary) -> void:
	var moved := PackedStringArray()
	for key in tree.keys():
		var name := String(key)
		if name == "rcon_password":
			continue
		for prefix: String in LEGACY_KEYS:
			if name.begins_with(prefix):
				moved.append("%s -> cfg/addons/%s/" % [name, LEGACY_KEYS[prefix]])
	if moved.is_empty() or DotCfgLegacy._warned.has(path + "#keys"):
		return
	DotCfgLegacy._warned[path + "#keys"] = true
	DotLog.warn("cfg", "%s: subsystem keys still read here until %s: %s" % [
		path, DotCfgLegacy.REMOVE_AFTER, ", ".join(moved)], {"path": path})


## The environment and the command line over `vote.yml`, under DOT_GAME_VOTE_* and --game-vote-*, not dot-vote's own prefixes:
## a game loaded from `content/` runs its own MAP vote in this process under `DOT_VOTE_*`, and one prefix for both would make a flag change two votes. The server-level vote's commands are `game_*` for the same reason.
func _layer_vote_overrides() -> void:
	var before := vote.unknown_keys.size()

	vote.apply_env("DOT_GAME_VOTE_")
	vote.apply_cli("--game-vote-")

	for i in range(before, vote.unknown_keys.size()):
		unknown.append("--game-vote-: %s" % vote.unknown_keys[i])


## The environment and the command line over `party.yml` and `matchmaking.yml`, under the addons' own prefixes (`DOT_PARTY_*` / `--party-*`, `DOT_MM_*` / `--mm-*`):
## unlike the vote there is one of each in the process, so no second one for a prefix to collide with.
func _layer_party_overrides() -> void:
	for target in [party, matchmaking]:
		var cfg := target as DotConfig
		var before := cfg.unknown_keys.size()
		cfg.apply_env()
		cfg.apply_cli()
		for i in range(before, cfg.unknown_keys.size()):
			unknown.append("%s: %s" % [cfg.cli_prefix(), cfg.unknown_keys[i]])


## The environment and the command line over `replay.yml`: dot-replay's own `DOT_REPLAY_*` and `--replay-*`, as with the party (one recorder per process);
## `--replay-ring-seconds 300` for one tournament is the case the prefix exists for. A layered value the addon refuses is caught when [TmcReplay] validates again: the ring is not built, said at ERROR.
func _layer_replay_overrides() -> void:
	var before := replay.unknown_keys.size()
	replay.apply_env()
	replay.apply_cli()
	for i in range(before, replay.unknown_keys.size()):
		unknown.append("%s: %s" % [replay.cli_prefix(), replay.unknown_keys[i]])


## The environment and the command line over `bot_record.yml`; the token stays file-only.
func _layer_bot_record_overrides() -> void:
	var before := bot_record.unknown_keys.size()
	bot_record.apply_env()
	bot_record.apply_cli()
	for i in range(before, bot_record.unknown_keys.size()):
		unknown.append("%s: %s" % [bot_record.cli_prefix(), bot_record.unknown_keys[i]])


static func _replay_defaults() -> DotReplayConfig:
	var cfg := DotReplayConfig.new()
	cfg.directory = ""
	# Half the addon's 512. A match file is the event stream and a roster, kilobytes a
	# minute; a file that reaches this is a loop somewhere, and 512 MiB of it on a small
	# VPS disk is the incident rather than the record of one.
	cfg.max_file_mib = 256
	return cfg


## The operator's net settings as limits on a game's own: [DotNetConfig] property -> number, only for what cfg wrote. Handed to the game module, which applies it ([code]DotGameNetcode.cap[/code]) before its netcode starts,
## because every game builds its own [DotNetConfig]. Ceilings, not overrides: 0 is "no limit", the game's lower value wins; [code]net_interp_buffer[/code] is a smoothing choice the module overrides.
func net_ceiling() -> Dictionary:
	var out := {}

	for key in _net_written:
		out[key] = net.get(key)

	return out


## One file in [constant LAYERED], read through its addon's loaders over every tier.
func _load_layered(name: String, base: String) -> DotResult:
	var addon: String = LAYERED[name]
	var found := true
	match name:
		"groups.yml":
			var g := DotAdminCfg.load_groups(base)
			if not g.ok:
				return g
			groups = g.value as Dictionary
			found = not groups.is_empty()
		"permissions.yml":
			var u := DotAdminCfg.load_users(base)
			if not u.ok:
				return u
			users = u.value as Dictionary
			found = not users.is_empty()
		"admin_menu.yml":
			var m := DotMenuCfg.load_admin_menu(base)
			if not m.ok:
				return m
			admin_menu = m.value as Dictionary
			found = not admin_menu.is_empty()
		_:
			var merged := _merged_tree(addon, name, base)
			if not merged.ok:
				return merged
			found = merged.value["found"] as bool
			if found:
				var typed := _apply_typed(name, base)
				if not typed.ok:
					return typed
				var applied := _apply(name, merged.value["tree"] as Dictionary)
				if not applied.ok:
					return applied
	if found:
		files_read.append(name)
	else:
		files_missing.append(name)
	return DotResult.success(null)


## Value: every tier of [param file] merged into one tree ({} when no tier has it).
static func merged_file(addon: String, file: String, base: String) -> DotResult:
	var config := TmcConfig.new()
	var merged := config._merged_tree(addon, file, base)
	return DotResult.success(merged.value["tree"]) if merged.ok else merged


## Value: {tree, found}, every tier of [param file] merged, for the keys that are this deployment's.
func _merged_tree(addon: String, file: String, base: String) -> DotResult:
	var tree := {}
	var res := DotAddonConfig.apply_file(
		addon, file, base,
		func(values: Dictionary, path: String) -> PackedStringArray:
			DotAddonConfig.merge(tree, values)
			return PackedStringArray([path])
	)
	if not res.ok:
		return res
	return DotResult.success({"tree": tree, "found": not (res.value as PackedStringArray).is_empty()})


## The addon's own typed properties, from its own loader.
func _apply_typed(name: String, base: String) -> DotResult:
	match name:
		"security.yml":
			var sec := security.apply_cfg_file(name, base)
			if not sec.ok:
				return sec
			return anticheat.apply_cfg_file(name, base)
		"party.yml":
			return _note_unknown(party, name, party.apply_cfg_file(name, base))
		"replay.yml":
			return _note_unknown(replay, name, replay.apply_cfg_file(name, base))
		"matchmaking.yml":
			return _note_unknown(matchmaking, name, matchmaking.apply_cfg_file(name, base))
	return DotResult.success(null)


func _note_unknown(cfg: DotConfig, file: String, res: DotResult) -> DotResult:
	for k in cfg.unknown_keys:
		unknown.append("%s: %s" % [file, k])
	cfg.unknown_keys = PackedStringArray()
	return res


func _apply(file: String, tree: Dictionary) -> DotResult:
	match file:
		"replay.yml":
			return _apply_replay(tree)
		"party.yml":
			return _apply_party(tree)
		"matchmaking.yml":
			return _apply_matchmaking(tree)
		"bot_record.yml":
			return _apply_bot_record(tree)
		"auth.yml":
			auth = tree
			return DotResult.success(null)
		"loading.yml":
			loading = tree
			return DotResult.success(null)
		"radio.yml":
			return _apply_radio(tree)
		"trail.yml":
			return TmcTrail.apply_config(self, tree)
		"vote.yml":
			return _apply_vote(tree)
		_:
			return _apply_settings(file, tree)


## `vote.yml`: straight onto a [DotVoteRules], minus this deployment's own keys.
func _apply_vote(tree: Dictionary) -> DotResult:
	var settings := tree.duplicate()

	if settings.has("vote_exclude"):
		vote_exclude = _string_list(settings["vote_exclude"])
		settings.erase("vote_exclude")

	var before := vote.unknown_keys.size()
	vote.apply_dictionary(settings, "vote.yml")

	# Reported here rather than left in the resource, so a typo in vote.yml appears in the same boot report as one in server.yml; an unknown key is never fatal (DotConfig's rule).
	for i in range(before, vote.unknown_keys.size()):
		unknown.append("vote.yml: %s" % vote.unknown_keys[i])

	return DotResult.success(null)


## `party.yml`: three switches of this deployment's, then two objects by prefix rather than by table (`party_seat_hold_sec` is `seat_hold_sec` on [DotPartyConfig]),
## because a table would be a second copy of each addon's property list, which goes stale when the addon gains a setting. An unknown one is still reported, by the object that did not have it.
func _apply_party(tree: Dictionary) -> DotResult:
	for key in tree.keys():
		var name := String(key)
		var value: Variant = tree[key]

		match name:
			"party_enabled":
				party_enabled = _truthy(value)
				continue
			"party_chat":
				party_chat = _truthy(value)
				continue
			"party_server_id":
				party_server_id = int(value)
				continue

		if name.begins_with("party_reserve_"):
			var applied_policy := _set_on_resource(
				party_policy, name.trim_prefix("party_reserve_"), value
			)
			if not applied_policy.ok:
				unknown.append("party.yml: %s (%s)" % [name, applied_policy.error.message])
			continue

		if name.begins_with("party_") and party.config_keys().has(name.trim_prefix("party_")):
			continue  # Applied by the addon's own loader.

		unknown.append("party.yml: %s" % name)

	var valid := party.validate()

	if not valid.ok:
		# The one party setting worth refusing a boot over: a heartbeat past the
		# backbone's staleness limit drops every member from their own party, which is
		# the feature failing while looking configured.
		return valid.wrap("party.yml")

	return DotResult.success(null)


## Every key `radio.yml` accepts, with its type; anything else is reported as unknown.
const RADIO_KEYS := {
	"radio_enabled": TYPE_BOOL, "radio_port": TYPE_INT, "radio_bind": TYPE_STRING,
	"radio_dir": TYPE_STRING, "radio_token_file": TYPE_STRING, "radio_max_track_mb": TYPE_FLOAT,
	"radio_base": TYPE_STRING, "radio_upload_timeout_sec": TYPE_FLOAT, "radio_autostart": TYPE_BOOL,
	"radio_public_url": TYPE_STRING,
}


## `radio.yml`: kept as a tree for [TmcRadio]; the addon may be absent, so nothing here names its classes.
func _apply_radio(tree: Dictionary) -> DotResult:
	radio = {}
	for key in tree.keys():
		var name := String(key)
		if not RADIO_KEYS.has(name):
			unknown.append("radio.yml: %s" % name)
			continue
		radio[name] = tree[key]
	radio_enabled = _truthy(radio.get("radio_enabled", false))
	return DotResult.success(null)


## `replay.yml`: six switches of this deployment's, then every [DotReplayConfig] property by its `replay_` name, by prefix as [method _apply_party] explains.
## A setting the addon refuses refuses the boot: otherwise a recorder is quietly not built, and a moderator finds out typing `replay save` during an incident.
func _apply_replay(tree: Dictionary) -> DotResult:
	for key in tree.keys():
		var name := String(key)
		var value: Variant = tree[key]

		match name:
			"replay_enabled":
				replay_enabled = _truthy(value)
				continue
			"replay_record":
				replay_record = _truthy(value)
				continue
			"replay_clip_on_punish":
				replay_clip_on_punish = _truthy(value)
				continue
			"replay_clip_seconds":
				replay_clip_seconds = maxf(float(value), 0.0)
				continue
			"replay_evidence_cooldown_sec":
				replay_evidence_cooldown_sec = maxf(float(value), 0.0)
				continue
			"replay_keep_files":
				# At least one: a cap of zero would delete the clip it was asked to keep.
				replay_keep_files = maxi(int(value), 1)
				continue
			"replay_keep_mib":
				replay_keep_mib = maxi(int(value), 1)
				continue

		if name.begins_with("replay_") and replay.config_keys().has(name.trim_prefix("replay_")):
			continue  # Applied by the addon's own loader.

		unknown.append("replay.yml: %s" % name)

	var valid := replay.validate()

	if not valid.ok:
		return valid.wrap("replay.yml")

	return DotResult.success(null)


## `bot_record.yml`: `bot_record` and `bot_record_<property>`, onto [member bot_record]. A value the
## addon refuses refuses the boot, like `replay.yml`.
func _apply_bot_record(tree: Dictionary) -> DotResult:
	var own := {}
	var keys := bot_record.config_keys()
	for raw in tree:
		var name := String(raw)
		var prop := "record" if name == "bot_record" else name.trim_prefix("bot_record_")
		if (name == "bot_record" or name.begins_with("bot_record_")) and keys.has(prop):
			own[prop] = tree[raw]
		else:
			unknown.append("bot_record.yml: %s" % name)
	bot_record.apply_dictionary(own, "bot_record.yml")
	for k in bot_record.unknown_keys:
		unknown.append("bot_record.yml: %s" % k)
	bot_record.unknown_keys = PackedStringArray()
	var valid := bot_record.validate()
	if not valid.ok:
		return valid.wrap("bot_record.yml")
	return DotResult.success(null)


## `matchmaking.yml`: `mm_enabled`, `mm_region`, `mm_playlists`, `mm_servers`, and every
## [DotMatchmakingConfig] property by its `mm_` name.
func _apply_matchmaking(tree: Dictionary) -> DotResult:
	for key in tree.keys():
		var name := String(key)
		var value: Variant = tree[key]

		match name:
			"mm_enabled":
				mm_enabled = _truthy(value)
				continue
			"mm_region":
				mm_region = String(value).strip_edges()
				continue
			"mm_servers":
				if value is Dictionary:
					mm_servers = (value as Dictionary).duplicate(true)
				elif value != null and str(value) != "":
					unknown.append("matchmaking.yml: mm_servers must be a mapping of id to {address, region}")
				continue
			"mm_playlists":
				var built := _playlists_from(value)
				if not built.ok:
					return built.wrap("matchmaking.yml")
				continue

		if name.begins_with("mm_") and matchmaking.config_keys().has(name.trim_prefix("mm_")):
			continue  # Applied by the addon's own loader.

		unknown.append("matchmaking.yml: %s" % name)

	return DotResult.success(null)


## `mm_playlists:` as a mapping of id to settings. The id is the key, so two playlists
## cannot share one -- which [method DotMatchmaker.add_playlist] would refuse anyway, but
## later and with less to say about where.
func _playlists_from(value: Variant) -> DotResult:
	if value == null or (value is String and String(value) == ""):
		return DotResult.success(null)

	if not (value is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "mm_playlists must be a mapping of id to settings")

	for id in (value as Dictionary).keys():
		var settings: Variant = (value as Dictionary)[id]
		var pl := DotMmPlaylist.new()
		pl.id = StringName(String(id))
		pl.display_name = String(id)

		if settings is Dictionary:
			for k in (settings as Dictionary).keys():
				var applied := _set_on_resource(pl, String(k), (settings as Dictionary)[k])
				if not applied.ok:
					unknown.append("matchmaking.yml: mm_playlists.%s.%s" % [id, k])

		var valid := pl.validate()

		if not valid.ok:
			return valid.wrap("playlist %s" % id)

		mm_playlists.append(pl)

	return DotResult.success(null)


## Sets one property on a plain [Resource], coerced through the property's own type. [DotConfig] has this built in and these two (the reservation policy, a playlist) are not DotConfigs;
## a plain `set()` would store a YAML string into an int and fail far away.
static func _set_on_resource(target: Object, property: String, value: Variant) -> DotResult:
	for prop in target.get_property_list():
		if String(prop["name"]) != property:
			continue
		if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			break

		var want := int(prop["type"])
		var coerced: Variant = value

		match want:
			TYPE_BOOL:
				coerced = _truthy(value)
			TYPE_INT:
				# An enum is an int, and an operator writes its NAME. Matched against the
				# hint string the same way DotConfig reads one.
				if int(prop["hint"]) == PROPERTY_HINT_ENUM and value is String \
						and not String(value).is_valid_int():
					var names := String(prop["hint_string"]).to_lower().split(",")
					var wanted := String(value).strip_edges().to_lower().replace(" ", "_")
					var index := -1
					for i in names.size():
						var label := names[i].get_slice(":", 0).strip_edges().replace(" ", "_")
						if label == wanted:
							# `NAME:value` when the enum says so, the position when not.
							index = names[i].get_slice(":", 1).to_int() if names[i].contains(":") else i
					if index < 0:
						return DotResult.fail(
							DotError.CODE_INVALID,
							"'%s' is not one of %s" % [value, prop["hint_string"]]
						)
					coerced = index
				else:
					coerced = int(value)
			TYPE_FLOAT:
				coerced = float(value)
			TYPE_STRING:
				coerced = str(value)
			TYPE_STRING_NAME:
				coerced = StringName(str(value))
			TYPE_ARRAY:
				var list: Array = value if value is Array else ([] if str(value) == "" else [value])
				var current: Variant = target.get(property)
				if current is Array and (current as Array).is_typed() \
						and (current as Array).get_typed_builtin() == TYPE_INT:
					var ints: Array[int] = []
					for entry in list:
						ints.append(int(entry))
					coerced = ints
				else:
					coerced = list

		target.set(property, coerced)
		return DotResult.success(coerced)

	return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a setting of %s" % [property, target.get_class()])


static func _truthy(value: Variant) -> bool:
	if value is bool:
		return value
	if value is int or value is float:
		return value != 0
	return str(value).strip_edges().to_lower() in ["1", "true", "yes", "on"]


## `server.yml` and `net.yml`: flat keys, three possible destinations.
func _apply_settings(file: String, tree: Dictionary) -> DotResult:
	for key in tree.keys():
		var name := String(key)
		var value: Variant = tree[key]

		if value is Dictionary or value is Array and name not in [
			"sv_tags", "rcon_allowed", "chat_command_prefixes"
		]:
			# A nested block in a flat file. Reported rather than flattened: a reader that
			# invented a dotted name for it would invent a different one from the writer.
			if value is Dictionary:
				unknown.append("%s: %s (nested blocks are not settings)" % [file, name])
				continue

		if name == "sv_game":
			initial_game = String(value)
			continue

		if name == "sv_web_loader":
			web_loader = str(value).strip_edges()
			continue

		if name == "sv_map":
			# Not passed through as a console line, like `sv_query_app`: there is no `map` cvar at this level; the one that exists belongs to whichever game is loaded, which is none when the startup config runs.
			initial_map = String(value)
			continue

		if name == "games":
			# A list, or one string, as `content_urls` below takes either (`games: arena` is what an operator with one game writes).
			# Not a console line: dot-server has no cvar for the set of games a host offers; `sv_game` picks one OF these, so the two spellings are deliberately unalike.
			# Each entry through TmcGameRef, as the command-line override is, so `gamemann/game-g2gfast01@1.2.0` in a file means the same directory as in a panel field.
			if value is Array:
				for entry in (value as Array):
					for dir_name in TmcGameRef.dirs_in(String(entry)):
						if not dir_name in games_allow:
							games_allow.append(dir_name)
			else:
				for dir_name in TmcGameRef.dirs_in(String(value)):
					if not dir_name in games_allow:
						games_allow.append(dir_name)

			continue

		if name == "content_urls":
			# A list, or one string for the common case of a single origin. Not passed
			# through as a console line: this is dot-cloud's, and dot-server's console
			# has no cvar for it.
			if value is Array:
				for entry in (value as Array):
					var url := String(entry).strip_edges()
					if url != "":
						content_urls.append(url)
			else:
				var one := String(value).strip_edges()
				if one != "":
					content_urls.append(one)

			# The same list to the clients, from the same line of YAML: the server downloads maps from these and the client must download them from somewhere, and a shipped build can only guess its page's origin, wrong for every CDN.
			# Assigned only if this dot-server has the property: addons are separately cloned, so pulling one and not another is ordinary, and assigning a missing property is a FATAL script error
			# that aborts `_apply_settings` mid-way and returns null into a caller that reads `.ok` off it. (A key from a NEWER file than the code is the opposite skew: never fatal.)
			if "content_base_urls" in server:
				server.content_base_urls = content_urls
			else:
				unknown.append(
					"%s: content_urls was read, but this dot-server has no " % file
					+ "content_base_urls to put it in -- clients will not be told "
					+ "where the content is. Update the dot-server addon."
				)
			continue

		if name == "sv_query_app":
			# Not a console line: the cvar of that name is registered by the query host, which opens AFTER the startup config runs, so a generated `sv_query_app` line would be reported unknown.
			app_url = String(value)
			continue

		if name == "net_public_ip":
			public_address = String(value)
			continue

		if name == "sv_tags":
			server.tags = _string_list(value)
			continue

		if name == "chat_command_prefixes":
			# The characters a chat line starts with to run a command. The FIRST is the one
			# help text and the game vote's ballot line tell players to type.
			var prefixes := _string_list(value)
			if prefixes.is_empty():
				unknown.append("%s: chat_command_prefixes needs at least one prefix" % file)
			else:
				server.chat_command_prefixes = prefixes
			continue

		if name == "log_router":
			# A bool is accepted because `on` and `off` ARE bools in this dialect (`TmcYaml` reads `on`/`yes`/`true` as true), and `log_router: on` is the natural spelling;
			# reading only the three words would report it as an unknown key and leave the default in force.
			var mode := ""

			if value is bool:
				mode = "on" if bool(value) else "off"
			else:
				mode = String(value).strip_edges().to_lower()

			if mode not in ["auto", "on", "off"]:
				unknown.append(
					"%s: log_router must be auto, on or off (got '%s')" % [file, mode]
				)
			else:
				log_router = mode

			continue

		if LOG_KEYS.has(name):
			var applied_log := _set_on(log, String(LOG_KEYS[name]), value)

			if not applied_log.ok:
				return applied_log.wrap("%s: %s" % [file, name])

			continue

		if DotSecurityConfig.CFG_KEYS.has(name) or DotAntiCheatConfig.CFG_KEYS.has(name):
			# security.yml went through the addons' loaders already; the keys are theirs alone.
			if file != "security.yml":
				unknown.append("%s: %s (belongs in security.yml)" % [file, name])
			continue

		if BOOT_KEYS.has(name):
			var applied := _set_on(server, String(BOOT_KEYS[name]), value)

			if not applied.ok:
				return applied.wrap("%s: %s" % [file, name])

			continue

		if NET_KEYS.has(name):
			var applied_net := _set_on(net, String(NET_KEYS[name]), value)

			if not applied_net.ok:
				return applied_net.wrap("%s: %s" % [file, name])

			if not _net_written.has(String(NET_KEYS[name])):
				_net_written.append(String(NET_KEYS[name]))

			continue

		if name in HANDLED_ELSEWHERE:
			continue

		# Anything left that *looks* like a cvar is handed to the console unresolved: a module's cvars (`room_...`, `hungry_bots`) are not known at read time,
		# so a name-based guess here would refuse every setting a game contributed; the console answers "unknown command" for a real typo.
		console_lines.append(_console_line(name, value))

	return DotResult.success(null)


## The sink layer this configuration describes, or null when it is switched off (the server then makes its own [code]DotLogSink[/code]).
## The shared settings are copied out of [member server] rather than read twice: a deployment with no dot-log has them through dot-core's sink, so `log.yml` names each once; a second set of keys is a shape this project was bitten by twice.
func build_log_router() -> DotLogRouter:
	if log_router == "off":
		return null

	log.level = server.log_level
	log.channel_levels = server.log_channel_levels
	log.mirror_min_level = server.log_mirror_min_level

	log.file_enabled = server.log_file_enabled
	log.file_directory = server.log_directory
	log.file_basename = server.log_basename
	log.file_json = server.log_json
	log.file_max_bytes = server.log_max_file_bytes
	log.file_max_files = server.log_max_files
	# The file keeps whatever DotLog itself let through, which is what the plain sink does.
	# A second threshold in front of the file is a way to have a log file quieter than the
	# level an operator set, which is never what they meant.
	log.file_level = server.log_level

	# The tags a collector groups by. `host` is left to the router's own default; the
	# others are this deployment's identity and an empty one is worse than a missing one,
	# so `context_tags()` drops whatever is still blank.
	if log.service == "":
		log.service = server.hostname

	if log.instance == "":
		log.instance = "%s:%d" % [server.bind_address, server.port]

	var invalid := log.validate()

	if not invalid.ok:
		# Reported and skipped rather than fatal, which is this file's rule for every
		# other unusable setting: a server that will not boot because a syslog port was
		# mistyped is a worse outcome than one that boots without syslog and says so.
		unknown.append("log.yml: %s" % invalid.error.message)
		return null

	return log.build_router()


## Assigns onto a [DotConfig], coercing through its own rules: through [method DotConfig.apply_dictionary] rather than [method Object.set], so a wrong-typed value is coerced and reported
## as every other layer does, and `max-players`, `maxPlayers` and `max_players` reach the same property.
func _set_on(target: DotConfig, property: String, value: Variant) -> DotResult:
	var before := target.unknown_keys.size()
	var applied := target.apply_dictionary({property: value}, "cfg")

	if applied.is_empty() and target.unknown_keys.size() > before:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' is not a setting of %s." % [property, target.get_class()]
		)

	return DotResult.success(applied)


## One console line, quoted so a value with spaces survives.
static func _console_line(name: String, value: Variant) -> String:
	if value is bool:
		return "%s %d" % [name, 1 if value else 0]

	if value is Array:
		return "%s \"%s\"" % [name, ",".join((value as Array).map(func(v: Variant) -> String:
			return str(v)))]

	var text := str(value)

	if text.contains(" ") or text == "":
		return "%s \"%s\"" % [name, text.replace("\"", "'")]

	return "%s %s" % [name, text]


## Writes the console lines to a `.cfg` for dot-server to execute at boot, through its own startup-config path: `DotServer.boot()` runs it after the console exists and *before* the listener opens,
## the only window where a `FLAG_STARTUP_ONLY` cvar (`sv_tickrate`) is still settable, and a hook of our own would be a second ordering to keep in step.
## Generated and overwritten every boot (it is derived; the YAML is the authored file) and written rather than kept in memory so an operator can read what their configuration became.
func write_cfg(path: String) -> DotResult:
	var text := PackedStringArray([
		"// GENERATED from cfg/*.yml on every boot. Do not edit: your changes will be",
		"// overwritten. Edit the YAML instead.",
		"//",
		"// It is written out rather than executed from memory so that this file answers",
		"// \"what did my configuration actually become\" without a debugger.",
		"",
	])

	text.append_array(console_lines)
	text.append("")

	var written := DotPaths.write_text(path, "\n".join(text))

	if not written.ok:
		return written.wrap("Could not write the generated config")

	return DotResult.success(path)


## Reports what dot-server made of the generated config, after boot. A line the console refused is a warning, for [member unknown]'s reason, but one that names the line.
func note_console_result(console: DotConsole) -> void:
	for line in console_lines:
		var name := line.split(" ")[0]

		if console.find_cvar(name) == null and console.find_command(name) == null:
			var near := nearest_names(name, console)
			DotLog.warn(CHANNEL, "a setting names nothing this server has", {"setting": name, "did_you_mean": near})
			unknown.append("cfg: %s%s" % [name, " (did you mean %s?)" % ", ".join(near) if not near.is_empty() else ""])


## The settings this server does have that [param name] most resembles, best first (at most 3). Godot's bigram [method String.similarity] rather than a prefix test:
## a typo like `net_intrest_radius` shares no useful prefix with the key it meant.
func nearest_names(name: String, console: DotConsole = null) -> PackedStringArray:
	var pool := PackedStringArray()
	for keys: Dictionary in [BOOT_KEYS, NET_KEYS, LOG_KEYS]:
		pool.append_array(PackedStringArray(keys.keys()))
	if console != null:
		pool.append_array(console.cvar_names())
	var scored: Array = []
	for candidate in pool:
		var score := name.to_lower().similarity(String(candidate).to_lower())
		if score >= 0.6 and candidate != name:
			scored.append([score, String(candidate)])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var out := PackedStringArray()
	for entry in scored:
		if not out.has(entry[1]):
			out.append(entry[1])
		if out.size() >= 3:
			break
	return out


## Turns a scalar or a sequence into a list of strings: a single value is a list of one (`sv_tags: pvp` and `sv_tags: [pvp, modded]` are both legitimate).
static func _string_list(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()

	if value is Array:
		for entry in (value as Array):
			out.append(str(entry))
	elif str(value) != "":
		out.append(str(value))

	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("read     : %s" % ", ".join(files_read))
	out.append("missing  : %s" % (", ".join(files_missing) if not files_missing.is_empty() else "-"))
	out.append("hostname : %s" % server.hostname)
	out.append("listen   : %s:%d" % [server.bind_address, server.port])
	out.append("players  : %d" % server.max_players)
	# `sv_game` was settable and worked but invisible here: the one report whose job is "show me what my configuration became" did not print it.
	# Empty is not "nothing": it means the content directory's own default wins, which is worth saying out loud.
	out.append("game     : %s" % (
		initial_game if initial_game != "" else "(content default)"))
	# Here for the same reason `game` is, and it was about to repeat the same mistake:
	# a setting worth having is worth being able to read back without booting.
	out.append("map      : %s" % (
		initial_map if initial_map != "" else "(the game's default)"))
	out.append("loader   : %s" % (
		web_loader if web_loader != "" else "(the site's default)"))
	# Same argument a third time: a server offering three of the ten games on its disk is a deliberate choice, and without this line a filtered server looks like an empty content directory.
	out.append("games    : %s" % (
		", ".join(games_allow) if not games_allow.is_empty() else "(everything in content/)"))
	out.append("content  : %s" % (
		", ".join(content_urls) if not content_urls.is_empty() else "(local only)"))
	out.append("rcon     : %s" % ("on, port %d" % server.effective_rcon_port() if server.rcon_password != "" else "off"))
	out.append("groups   : %d" % groups.size())
	out.append("admins   : %d" % users.size())
	out.append("party    : %s" % (
		"off" if not party_enabled else "on, chat %s, bookings %s" % [
			"on" if party_chat else "off",
			"offered" if party_policy.enabled else "console only",
		]))
	out.append("matchmk  : %s" % (
		"off" if not mm_enabled else "on, %d playlist(s), region %s, %d server(s)" % [
			mm_playlists.size(), mm_region, mm_servers.size()
		]))
	out.append("radio    : %s" % (
		"off" if not radio_enabled else "on, port %d, %s" % [
			int(radio.get("radio_port", 8791)), str(radio.get("radio_bind", "127.0.0.1"))]))
	out.append("replay   : %s" % (
		"off" if not replay_enabled else "ring %ss (%d MiB max)%s, clips %s, keep %d files / %d MiB each" % [
			replay.ring_seconds, replay.ring_max_mib,
			", every match to a file" if replay_record else "",
			"on punishment" if replay_clip_on_punish else "on request only",
			replay_keep_files, replay_keep_mib,
		]))
	out.append("bot rec  : %s" % (
		"off" if not bot_record.record else "on, store %s, rate %s Hz" % [bot_record.store, bot_record.rate]))
	out.append("cvars    : %d queued" % console_lines.size())

	for line in unknown:
		out.append("UNKNOWN  : %s" % line)

	return out
