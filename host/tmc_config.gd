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
	"server.yml", "net.yml", "rcon.yml", "auth.yml", "groups.yml", "permissions.yml",
	"vote.yml",
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
	"a2s_enabled": "a2s_enabled",
	"content_manifest_url": "content_manifest_url",
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

		if name == "net_public_ip":
			public_address = String(value)
			continue

		if name == "sv_tags":
			server.tags = _string_list(value)
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
	out.append("rcon     : %s" % ("on, port %d" % server.effective_rcon_port() if server.rcon_password != "" else "off"))
	out.append("groups   : %d" % groups.size())
	out.append("admins   : %d" % users.size())
	out.append("cvars    : %d queued" % console_lines.size())

	for line in unknown:
		out.append("UNKNOWN  : %s" % line)

	return out
