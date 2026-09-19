class_name TmcConfig
extends RefCounted

## The `cfg/` directory, read into everything a server needs.
##
## Five YAML files, four destinations, and one rule that decides which:
##
## [b]Where a key names something dot-server's console already knows, it is applied as a
## console command.[/b] The console is the parser, the validator, the range clamp, the
## permission check and the audit trail; a second one here would drift from it and the
## drift would be silent. That is dot-serve's rule — "dot-server's console is the parser" —
## and it is why `sv_maxplayers: 64` becomes the line `sv_maxplayers 64` rather than an
## assignment.
##
## [b]Where a key names something the console cannot reach, it is applied to the boot
## config.[/b] The listening port and the bind address are fixed before the console exists;
## `DotConVar.FLAG_STARTUP_ONLY` is what dot-server uses to say so, and there is no cvar at
## all for a port.
##
## Everything else — groups, per-user permissions, the auth backend, per-content settings —
## has no console surface and is handed to whatever owns it.
##
## [b]An unknown key is reported, never fatal.[/b] Refusing to boot a server because its
## config mentions a setting from a newer version is worse than ignoring it — which is
## `DotConfig`'s own rule, for the same reason, and this follows it.

const CHANNEL := "tmc.config"

## The files read, in the order they are applied.
##
## `net.yml` after `server.yml` so a network setting wins over a general one that happens
## to name the same thing — which is the order an operator would expect from the filenames.
const FILES := [
	"server.yml", "net.yml", "log.yml", "rcon.yml", "auth.yml", "groups.yml",
	"permissions.yml", "vote.yml", "security.yml",
]

## Operator-facing name -> boot config property.
##
## [b]These are the ones the console cannot reach.[/b] Two vocabularies is a cost and it is
## paid deliberately: an operator writes `net_port`, dot-server calls it `port`, and the
## alternatives are renaming a published cvar or asking an operator to know which layer
## they are configuring.
const BOOT_KEYS := {
	"net_port": "port",
	"net_bind_ip": "bind_address",
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
	# dot-server documents this as the one stdin decision that is a real decision rather
	# than an environment -- and it was unreachable, because YAML is the only surface this
	# deployment has and the key was not on it. A server whose stdin carries something
	# other than commands needs it, and so does anything running two servers in one
	# process: [DotStdinConsole] is a thread blocked in a read the engine cannot cancel,
	# so the second one keeps the process alive after everything else has stopped.
	"sv_stdin_console": "stdin_console_enabled",
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
}

## Operator-facing name -> [code]DotLogConfig[/code] property.
##
## [b]Only what dot-log adds.[/b] The level, the channels, the mirror threshold and every
## file setting are in [constant BOOT_KEYS] already, because a server with no dot-log still
## has all of them through dot-core's own sink — so they are read once, into
## [member server], and copied across in [method build_log_router]. Two lists for one fact
## is this tree's most repeated bug and the file settings are exactly the fact it would be.
## [code]log_router[/code] is NOT here: it decides whether the router is built at all
## rather than setting a property on it, and is handled by name in [method _apply_settings].
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

## Operator-facing name -> [code]DotSecurityConfig[/code] property.
const SECURITY_KEYS := {
	"sec_enabled": "enabled",
	"sec_dryrun": "dry_run",
	"sec_rules_file": "rules_file",
	"sec_notify_subject": "notify_subject",
	"sec_notify_admins": "notify_admins",
	"sec_notify_flag": "notify_flag",
	"sec_announce_removals": "announce_removals",
	"sec_caps_min_length": "caps_min_length",
	"sec_caps_ratio": "caps_ratio",
	"sec_duplicate_memory_sec": "duplicate_memory_sec",
	"sec_duplicate_depth": "duplicate_depth",
	"sec_link_allow": "link_allow",
	"sec_churn_window_sec": "churn_window_sec",
	"sec_ledger_size": "ledger_size",
}

## Operator-facing name -> [code]DotAntiCheatConfig[/code] property.
##
## Separate from [constant SECURITY_KEYS] because the anti-cheat has its **own** dry run,
## and that separation is the addon's own decision rather than this file's: an operator
## commonly trusts the chat rules long before a movement threshold they have not measured
## on their own maps.
const ANTICHEAT_KEYS := {
	"ac_enabled": "enabled",
	"ac_dryrun": "dry_run",
	"ac_watch_movement": "watch_movement",
	"ac_max_speed": "max_horizontal_speed",
	"ac_max_vertical_speed": "max_vertical_speed",
	"ac_max_tick_distance": "max_tick_distance",
	"ac_max_airborne_sec": "max_airborne_sec",
	"ac_watch_timing": "watch_timing",
	"ac_max_time_ratio": "max_time_ratio",
	"ac_watch_fire_rate": "watch_fire_rate",
	"ac_fire_interval_tolerance": "fire_interval_tolerance",
}

## Keys that exist and are handled somewhere other than a config object.
##
## Listed so they are not reported as unknown. A key that is silently ignored *and* not
## reported is the worst of both: the operator believes it took effect.
##
## `net_public_ip` is here rather than in [constant BOOT_KEYS] because dot-server has no
## such setting and should not: what a server binds to and what a player types are
## different questions, and only the second one is behind NAT. It is what the join address
## is printed from.
const HANDLED_ELSEWHERE := ["sv_content_dir"]

## The boot configuration, after every file has been applied.
var server: DotServerConfig = DotServerConfig.new()

## The netcode configuration a game module reads.
var net: DotNetConfig = DotNetConfig.new()

## What dot-log adds on top of the file every server already writes.
##
## Only the router-only half is read into it; see [constant LOG_KEYS]. The rest is copied
## out of [member server] by [method build_log_router], so there is one list.
var log: DotLogConfig = DotLogConfig.new()

## Whether the sink layer is built at all: [code]"auto"[/code], [code]"on"[/code] or
## [code]"off"[/code].
##
## [b]`auto` is on, and that is not the same as the setting being pointless.[/b] The router
## is a strict superset of the file every server already writes -- same directory, same
## name, same rotation, same JSON switch -- so turning it on costs a deployment nothing and
## buys it `log tail`, `log grep` and `log test` on the console, plus somewhere for syslog
## and a collector to be configured later. `off` is for a box that wants the plain sink and
## nothing else, which is a legitimate and much smaller thing to have running.
var log_router: String = "auto"

## The guard, after every file has been applied. See [constant SECURITY_KEYS].
var security: DotSecurityConfig = DotSecurityConfig.new()

## The detectors. Separate dry run, deliberately. See [constant ANTICHEAT_KEYS].
var anticheat: DotAntiCheatConfig = DotAntiCheatConfig.new()

## Console commands to run once the console exists, in file order.
var console_lines: PackedStringArray = PackedStringArray()

## `groups.yml`, as parsed. Group name -> {is_root, permissions, immunity}.
var groups: Dictionary = {}

## `permissions.yml`, as parsed. User -> {group, permissions, immunity}.
var users: Dictionary = {}

## `auth.yml`, as parsed. Handed to [TmcAuth], which is the only thing that reads it.
var auth: Dictionary = {}

## `vote.yml`, as a real [DotVoteRules].
##
## Applied through [method DotConfig.apply_dictionary] rather than key by key, because
## that is what reads an enum written by name and coerces every YAML scalar through the
## property's own type — the same path `DOT_VOTE_*` and `--vote-*` take. A second
## translation table here would be a second place for `method: instant_runoff` to mean
## something different.
var vote: DotVoteRules = DotVoteRules.new()

## Game ids `vote.yml` says are never on a ballot.
##
## Not a [DotVoteRules] setting: which of the things in `content/` count as games a
## player would choose is a question about this deployment, and dot-vote should not have
## an opinion about a lobby.
var vote_exclude: PackedStringArray = PackedStringArray()

## The game to load at boot, or "" for whatever the content directory says is first.
var initial_game: String = ""

## The map to start that game on, or "" for the game's own default.
##
## `sv_map` in the YAML, `--map` on the command line, and `+map` after a `--` for the
## muscle memory of every other dedicated server. [b]It is a request, not a
## guarantee.[/b] A game decides whether it has maps at all — a lobby and an arena of
## built geometry do not — and the id has to be in that game's catalogue. Both are
## reported and neither is fatal: a server that refused to boot because one argument
## named a map that is not there is a server an operator cannot get back.
##
## Deliberately NOT a per-game setting. `--g2g-initial-map` already exists and always
## has; what did not exist was a way to say it without knowing which game's config
## prefix to spell, which is the whole difficulty on a box that runs seven of them.
var initial_map: String = ""

## The only games this server offers, or empty for everything in the content directory.
##
## `games` in the YAML, `--games a,b,c` on the command line, `TMC_GAMES` in a container.
##
## [b]A filter, not an installer.[/b] `tools/install_games.gd` is what puts a game's
## descriptor on the disk; this decides which of the ones that ARE on the disk a player
## may reach — the `games` listing, `changelevel`, the vote menu and the boot game all
## read the scanned set, and the scan is where the list has to be applied for all four to
## agree. Filtering at any one of them leaves the other three offering a game this server
## was told not to run.
##
## [b]Empty means everything, and that is not the same as "none".[/b] A server with no
## list is the ordinary hand-run one and must not lose its content the day this key is
## added; a deployment that genuinely wants one game names one game. An id here that is
## not on the disk is reported at boot and is not fatal, because the usual cause is a
## pack that has not finished downloading yet and a server that refuses to boot over it
## is a server an operator cannot get back.
var games_allow: PackedStringArray = PackedStringArray()

## Where this server fetches content it does not have, in order.
##
## `content_urls` in the YAML. Empty means the network half is off and only packs
## already on disk -- under `content/` or `dist/` -- can be used.
##
## [b]This is how a cloned server gets its maps.[/b] `maps/imported/` is gitignored in
## the games that have one, so a deployment stood up by cloning the repositories has the
## game and none of its maps; they live on the content origin instead, which is what
## dot-cloud is for. Without this the server could only ever use what was already beside
## it, while the browser client -- which has always had a base URL -- could download the
## very map the server was refusing to load.
var content_urls: PackedStringArray = PackedStringArray()

## The app's URL segment on the website, reported in a query as the game's name.
##
## `sv_query_app` in the YAML. Empty falls back to the running game's id, which is
## already slug-shaped and is the right answer on a box running one game.
##
## [b]Display only.[/b] A server can claim any app it likes; nothing that has to be
## certain which app a server belongs to — a launch resolving a build, a play grant
## — reads this. Those ask the backbone, which knows.
var app_url: String = ""

## The address a player types, when it is not the one the server binds to.
##
## Behind NAT the two differ and only the operator knows the difference. Printed in the
## join line and reported in the server listing; nothing binds to it.
var public_address: String = ""

## Keys that were seen and did not correspond to anything.
##
## Collected rather than reported one at a time, so a file with three typos produces three
## warnings at boot rather than one abort.
var unknown: PackedStringArray = PackedStringArray()

## Files that were present and files that were not.
var files_read: PackedStringArray = PackedStringArray()
var files_missing: PackedStringArray = PackedStringArray()


## Reads a whole `cfg/` directory.
##
## A missing file is not an error: a deployment that does not use RCON has no reason to
## carry an `auth.yml`, and a first run has none of them. A file that is *present and
## malformed* is an error, and it names the line.
static func load_dir(directory: String) -> DotResult:
	var config := TmcConfig.new()
	var base := directory.rstrip("/")

	for name in FILES:
		var path := "%s/%s" % [base, name]

		if not FileAccess.file_exists(path):
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
		var applied := config._apply(name, tree as Dictionary)

		if not applied.ok:
			return applied

	var valid := config.server.validate()

	if not valid.ok:
		return valid.wrap("The configuration in %s is not usable" % base)

	return DotResult.success(config)


func _apply(file: String, tree: Dictionary) -> DotResult:
	match file:
		"groups.yml":
			groups = TmcYaml.at(tree, "groups", {}) as Dictionary
			return DotResult.success(null)
		"permissions.yml":
			users = TmcYaml.at(tree, "users", {}) as Dictionary
			return DotResult.success(null)
		"auth.yml":
			auth = tree
			return DotResult.success(null)
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

	# Reported here rather than left in the resource, so a typo in vote.yml appears in
	# the same boot report as a typo in server.yml. An unknown key is never fatal —
	# DotConfig's rule, and refusing to boot over a setting from a newer version is
	# worse than ignoring it.
	for i in range(before, vote.unknown_keys.size()):
		unknown.append("vote.yml: %s" % vote.unknown_keys[i])

	return DotResult.success(null)


## `server.yml` and `net.yml`: flat keys, three possible destinations.
func _apply_settings(file: String, tree: Dictionary) -> DotResult:
	for key in tree.keys():
		var name := String(key)
		var value: Variant = tree[key]

		if value is Dictionary or value is Array and name not in [
			"sv_tags", "rcon_allowed"
		]:
			# A nested block in a flat file. Reported rather than flattened: a reader that
			# invented a dotted name for it would invent a different one from the writer.
			if value is Dictionary:
				unknown.append("%s: %s (nested blocks are not settings)" % [file, name])
				continue

		if name == "sv_game":
			initial_game = String(value)
			continue

		if name == "sv_map":
			# Not passed through as a console line for the same reason `sv_query_app`
			# is not: there is no `map` cvar or command at this level to receive it.
			# The one that exists belongs to whichever game is loaded, which at the
			# time the startup config runs is none of them.
			initial_map = String(value)
			continue

		if name == "games":
			# A list, or one string, exactly as `content_urls` below takes either --
			# `games: arena` is what an operator with one game writes and there is no
			# reason to make them write a list of one.
			#
			# Not passed through as a console line: dot-server has no cvar for the set of
			# games a host offers, because the set is this host's idea rather than the
			# server's. `sv_game` picks one OF these and is a cvar, which is why the two
			# spellings are deliberately not alike.
			if value is Array:
				for entry in (value as Array):
					var one_game := String(entry).strip_edges()
					if one_game != "":
						games_allow.append(one_game)
			else:
				var only_game := String(value).strip_edges()
				if only_game != "":
					games_allow.append(only_game)

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

			# [b]The same list to the clients, from the same line of YAML.[/b] The
			# server downloads its maps from these and the client has to download the
			# same maps from somewhere; left to itself the only address a shipped build
			# can guess is the origin its page came from, which is right for a
			# self-hosted deployment and wrong for every CDN. Two settings for one fact
			# is this tree's most repeated bug, so there is one setting.
			#
			# [b]Assigned only if this dot-server has the property, and the check is
			# not paranoia.[/b] Every addon here is a separately cloned repository, so
			# an operator who pulls this one and not that one is the ordinary case --
			# and a plain assignment to a property a resource does not have is a FATAL
			# script error naming a type rather than a version:
			#
			#   Invalid assignment of property or key 'content_base_urls' with value
			#   of type 'PackedStringArray' on a base object of type
			#   'Resource (DotServerConfig)'
			#
			# which aborts `_apply_settings` mid-way, returns null into a caller that
			# reads `.ok` off it, and buries the cause under two more errors about Nil.
			# A server that booted yesterday then does not boot today and says nothing
			# an operator can act on.
			#
			# This file's rule for the opposite skew -- a key from a NEWER config file
			# than the code -- is fifty lines up: never fatal, report it and carry on.
			# Same rule, other direction.
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
			# Not passed through as a console line: the cvar of that name is
			# registered by the query host, which opens AFTER the startup config
			# runs, so a `sv_query_app` line in the generated .cfg would name a
			# cvar that does not exist yet and be reported as unknown.
			app_url = String(value)
			continue

		if name == "net_public_ip":
			public_address = String(value)
			continue

		if name == "sv_tags":
			server.tags = _string_list(value)
			continue

		if name == "log_router":
			# [b]A bool is accepted because `on` and `off` ARE bools in this dialect.[/b]
			# `TmcYaml` reads `on`, `yes` and `true` as true and `off`, `no` and `false`
			# as false -- which is the same rule that famously turns the country code `NO`
			# into a boolean, and is right here because that is what an operator writing
			# `log_router: on` means. Reading only the three words would report the most
			# natural spelling of the setting as an unknown key and quietly leave the
			# default in force.
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

		if SECURITY_KEYS.has(name):
			var applied_sec := _set_on(security, String(SECURITY_KEYS[name]), value)

			if not applied_sec.ok:
				return applied_sec.wrap("%s: %s" % [file, name])

			continue

		if ANTICHEAT_KEYS.has(name):
			var applied_ac := _set_on(anticheat, String(ANTICHEAT_KEYS[name]), value)

			if not applied_ac.ok:
				return applied_ac.wrap("%s: %s" % [file, name])

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

			continue

		if name in HANDLED_ELSEWHERE:
			continue

		# Anything left that *looks* like a cvar is handed to the console, unresolved.
		# dot-server registers cvars a module owns, which this layer cannot know about at
		# read time — `room_...`, `hungry_bots` — so a name-based guess here would refuse
		# every setting a game contributed. The console answers "unknown command" for a
		# real typo, which is the same report by a better-informed party.
		console_lines.append(_console_line(name, value))

	return DotResult.success(null)


## The sink layer this configuration describes, or null when it is switched off.
##
## [b]The shared settings are copied out of [member server] rather than read twice.[/b] The
## level, the channels, the mirror threshold and every file setting exist on
## [DotServerConfig] because a deployment with no dot-log still has all of them through
## dot-core's own sink -- so `log.yml` names each of them once, they land there, and this
## carries them across. A second set of keys for the same six facts is the shape this
## project has already been bitten by twice.
##
## Returns null for [code]log_router: off[/code], and the server then makes its own
## [code]DotLogSink[/code] exactly as it did before this existed.
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


## Assigns onto a [DotConfig], coercing through its own rules.
##
## Through [method DotConfig.apply_dictionary] rather than [method Object.set], so a value
## of the wrong type is coerced and reported the way every other layer of configuration in
## this family coerces and reports it — and so `max-players`, `maxPlayers` and
## `max_players` all reach the same property.
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


## Writes the console lines to a `.cfg` for dot-server to execute at boot.
##
## [b]Through dot-server's own startup-config path rather than through a hook of our
## own.[/b] `DotServer.boot()` runs `config.startup_config` after the console exists and
## *before* the listener opens, which is the only window in which a `FLAG_STARTUP_ONLY`
## cvar — `sv_tickrate`, and everything else fixed at boot — is still settable. There is no
## signal in that window and there should not be one: reaching in would be a second
## ordering to keep in step with dot-server's, and dot-serve's rule already says the
## console is the parser.
##
## The file is **generated and overwritten every boot**, which is the opposite of
## dot-serve's rule about never touching `server.cfg` and is right for the opposite reason:
## this file is derived, and the authored one is the YAML. It is written rather than kept
## in memory so an operator can read exactly what their configuration became — which is the
## question they actually have when a setting appears not to work.
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


## Reports what dot-server made of the generated config.
##
## Called after boot. A line the console refused is a warning rather than a refusal to
## start, for [member unknown]'s reason — but it is a warning that names the line, because
## the alternative is a setting that silently did nothing.
func note_console_result(console: DotConsole) -> void:
	for line in console_lines:
		var name := line.split(" ")[0]

		if console.find_cvar(name) == null and console.find_command(name) == null:
			DotLog.warn(CHANNEL, "a setting names nothing this server has", {"setting": name})
			unknown.append("cfg: %s" % name)


## Turns a scalar or a sequence into a list of strings.
##
## A single value is a list of one. `sv_tags: pvp` and `sv_tags: [pvp, modded]` are both
## things an operator writes and neither is a mistake.
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
	# [b]`sv_game` was settable, worked, and was invisible from here.[/b] The parser has
	# always mapped it onto `initial_game`, the shipped `server.yml` never mentioned it,
	# and this report -- the one command whose entire job is "show me what my
	# configuration became" -- did not print it. So the only way to find out which game a
	# box would boot was to boot it and read the log. Empty is not "nothing": it means the
	# content directory's own default wins, which is a different statement and is worth
	# saying out loud rather than leaving as a blank.
	out.append("game     : %s" % (
		initial_game if initial_game != "" else "(content default)"))
	# Here for the same reason `game` is, and it was about to repeat the same mistake:
	# a setting worth having is worth being able to read back without booting.
	out.append("map      : %s" % (
		initial_map if initial_map != "" else "(the game's default)"))
	# Same argument a third time. A server offering three of the ten games on its disk
	# is a deliberate choice somewhere, and "somewhere" is this line -- without it the
	# only way to tell a filtered server from an empty content directory is to boot one
	# and count what came back.
	out.append("games    : %s" % (
		", ".join(games_allow) if not games_allow.is_empty() else "(everything in content/)"))
	out.append("content  : %s" % (
		", ".join(content_urls) if not content_urls.is_empty() else "(local only)"))
	out.append("rcon     : %s" % ("on, port %d" % server.effective_rcon_port() if server.rcon_password != "" else "off"))
	out.append("groups   : %d" % groups.size())
	out.append("admins   : %d" % users.size())
	out.append("cvars    : %d queued" % console_lines.size())

	for line in unknown:
		out.append("UNKNOWN  : %s" % line)

	return out
