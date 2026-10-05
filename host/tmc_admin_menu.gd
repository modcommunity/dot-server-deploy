class_name TmcAdminMenu
extends Node

## `/admin`: a menu of everything this admin may do here, picked with a number key or a
## click, and built from `cfg/admin_menu.yml`.
##
## [codeblock]
## /admin
##   1. Player commands      -> 1. Kick  2. Ban  3. Warn  ...
##   2. Server commands         -> 1. Bob (#12)  2. Alice (#14)  ...
##                                -> 1. Spamming  2. Abusive language  ...  8. Custom…
##                                   -> runs `kick #12 "Spamming"` as the admin
## [/codeblock]
##
## [b]The menu is a way of TYPING a command, and nothing else.[/b] Every leaf ends as one
## console line, run through [method DotConsole.execute] with the admin's own chat context
## — so the permission check, the immunity check, the chat gate, the audit line and the
## reply are the console's, exactly as if the admin had typed `/kick #12 Spamming`. A menu
## that performed its own kicks would be a second implementation of every moderation
## command, drifting from the first the day either changed; and a menu that only checked
## permissions when DRAWING would be a menu a modified client could walk past. Here the
## drawing check is a courtesy and the console's is the one that counts.
##
## [b]So "everything is listed if they have the permission" is computed, not configured.[/b]
## An item is shown when the command its line begins with exists in the console right now,
## may be run from chat, and the admin holds that command's flag (and the item's own
## `flag`, when the file sets one, as a further restriction — never a grant). That is why
## the default menu names `slay` and `map` on every server: a game that registers them
## shows them, one that does not hides them, and the first `changelevel` to a game without
## live tools takes them off the menu with nothing here having to know.
##
## [b]Server-driven, one page at a time.[/b] The client is sent a page — a title and rows
## — as a [DotNotice] under [constant TOPIC], and each choice comes back as an envelope kind
## of its own, [constant KIND], carrying the path. A page is
## built when it is asked for, so a player list is the players who are here NOW and not
## the ones who were when the menu opened; and nothing about which commands exist, who
## outranks whom or what a reason list says ever has to reach a client that is not
## about to draw it. Pages ride the notice and choices ride a KIND rather than an RPC of
## their own, because every new RPC is a signon revision every shipped client has to be
## rebuilt for, and a kind is not: a peer that does not know it is simply not sent it.
##
## [b]Not chat, and that was found by running it.[/b] The choices first went back as
## `/admin_menu <path>` chat lines, which is how a ballot votes — and a ballot is one line.
## A menu walk is six (open, category, item, player, reason, confirm) inside a few
## seconds, and dot-server's chat limiter allows a burst of five and then one every three
## seconds, so the sixth was dropped and the admin told they were "sending messages too
## quickly" by a menu. The kind has a limiter of its own sized for pressing keys
## ([constant NAV_PER_SEC]). The chat command is still registered: it is the fallback for a
## shell talking to a server that does not advertise the kind, and it is typable.
##
## [b]A path, not a session.[/b] `i:ban #12 3 2` is "ban, player #12, the third duration,
## the second reason" — `y:ban #12 3 2` is the same, confirmed — and the server keeps no per-admin menu state: each path is
## re-validated from scratch, so a player who left between two key presses is a reply
## ("#12 is not here any more") and a fresh list rather than a ban on whoever is #12 next.
## List choices travel as indices into the SERVER's list, never as the text, so the only
## free text a client can put in a command line is a custom entry — and that is stripped
## of quotes, semicolons and control characters before it is quoted into one argument.
## A semicolon would otherwise be a second statement with the admin's permissions.

const CHANNEL := "tmc.admin_menu"

## The notice topic every page is sent under, and that a close takes down.
const TOPIC := &"admin_menu"

## The command a client's menu sends a choice back as. Hidden from `help`: nobody types it.
const NAV_COMMAND := "admin_menu"

## The envelope kind a client's menu sends a choice on: `{"path": "i:kick #2"}`.
const KIND := &"tmc.admin_menu"

## Choices per second one admin may send, and the burst. A person pressing keys, not a
## script: past this a choice is dropped, and the menu simply does not move.
const NAV_PER_SEC := 4.0
const NAV_BURST := 16.0

## Longest path accepted off the wire. The longest real one is an item, three values and a
## custom text of [constant MAX_TEXT].
const MAX_PATH := 320

## What an admin types to open it, unless `admin_menu_commands` says otherwise.
const DEFAULT_COMMANDS := ["admin"]

## Rows on one page at most. The client pages them seven at a time; this bounds the notice.
const MAX_ROWS := 60

## Longest label drawn.
const MAX_LABEL := 64

## Longest custom text an admin may type into a command.
const MAX_TEXT := 120

## Bytes of JSON a page may encode to before rows are cut. Under [constant DotNotice.MAX_DATA_BYTES],
## which drops a tree that is too big WHOLE — a menu that silently never opens.
const MAX_PAGE_BYTES := 6000

## Step kinds this file fills itself. Any other kind is the name of a list.
const BUILTIN_KINDS := ["player", "game", "map", "text"]

## `DotPunishment.Kind.WARN`, as a number: this host has dot-moderation in its build, but
## the manager is found in the registry and spoken to by duck type, for the reason
## [TmcReplay] gives.
const PUNISHMENT_WARN := 4
const MODERATION_SERVICE := &"dot_moderation"

## The lists a step may name. `admin_menu.yml`'s `lists:` merges over these by key.
const DEFAULT_LISTS := {
	"reason": {
		"title": "Reason",
		"custom": true,
		"options": [
			"Spamming",
			"Abusive language",
			"Cheating",
			"Griefing",
			"Ignoring an admin",
			"Inappropriate name",
		],
	},
	"duration": {
		"title": "For how long",
		"format": "duration",
		"options": ["5m", "30m", "1h", "1d", "7d", "30d", "0"],
	},
	"seconds": {
		"title": "For how long",
		"format": "seconds",
		"options": ["10", "30", "60", "300"],
	},
}

## Every item a server gets without writing one. An item whose command this server does
## not have is simply not drawn — see the class notes.
const DEFAULT_ITEMS := {
	"kick": {"label": "Kick", "command": "kick {player} {reason}", "steps": ["player", "reason"]},
	"ban": {"label": "Ban", "command": "ban {player} {duration} {reason}", "steps": ["player", "duration", "reason"], "confirm": true},
	"warn": {"label": "Warn", "command": "warn {player} {reason}", "steps": ["player", "reason"]},
	"mute": {"label": "Mute (voice and chat)", "command": "mute {player} {duration} {reason}", "steps": ["player", "duration", "reason"]},
	"gag": {"label": "Gag (chat only)", "command": "gag {player} {duration} {reason}", "steps": ["player", "duration", "reason"]},
	"unmute": {"label": "Unmute", "command": "unmute {player}", "steps": ["player"]},
	"info": {"label": "Player info", "info": true, "steps": ["player"], "self": true, "flag": "kick"},
	"slay": {"label": "Slay", "command": "slay {player}", "steps": ["player"]},
	"slap": {"label": "Slap", "command": "slap {player}", "steps": ["player"]},
	"freeze": {"label": "Freeze", "command": "freeze {player} {seconds}", "steps": ["player", "seconds"]},
	"unfreeze": {"label": "Unfreeze", "command": "unfreeze {player}", "steps": ["player"]},
	"respawn": {"label": "Respawn", "command": "respawn {player}", "steps": ["player"]},
	"bring": {"label": "Bring to me", "command": "bring {player}", "steps": ["player"]},
	"goto": {"label": "Go to", "command": "goto {player}", "steps": ["player"]},
	"changelevel": {"label": "Change game", "command": "changelevel {game}", "steps": ["game"], "confirm": true},
	"map": {"label": "Change map", "command": "map {map}", "steps": ["map"], "confirm": true},
	"say": {"label": "Announce", "command": "say {text}", "steps": ["text"]},
}

## The layout a server gets without writing one. Ordered: the menu draws them as written.
const DEFAULT_CATEGORIES := {
	"players": {
		"title": "Player commands",
		"items": ["info", "kick", "ban", "warn", "mute", "gag", "unmute", "slay", "slap", "freeze", "unfreeze", "respawn", "bring", "goto"],
	},
	"server": {
		"title": "Server commands",
		"items": ["changelevel", "map", "say"],
	},
}

## Where an item the file adds but places in no category is put, rather than nowhere.
const OTHER_CATEGORY := "other"

# --- Settings, from `admin_menu.yml` ---------------------------------------------

var enabled := true

## What an admin types to open it.
var commands := PackedStringArray(DEFAULT_COMMANDS)

## The heading on the first page.
var title := "Admin menu"

## A flag needed to open the menu at all. Empty: anybody with one usable item.
var open_flag := ""

## The flag the `warn` command this file registers needs. A server with its own `warn`
## keeps it; this only fills the gap.
var warn_flag := "kick"

## Whether a warning is announced to everybody, or only told to the player warned.
var warn_announce := false

## Who sees a player's address on the info page. `whois` shows it to `kick`, so the same.
var address_flag := "kick"

## What the menu does after a command runs: `close`, `back` (the item's first page, a
## fresh player list) or `root`.
var after_run := "close"

## id -> normalised item. See [method _normalise_item].
var items: Dictionary = {}

## id -> {title, custom, format, options: [{label, value}]}.
var lists: Dictionary = {}

## id -> {title, flag, items: PackedStringArray}, in draw order.
var categories: Dictionary = {}

## What was wrong with the file. Reported at install; never fatal.
var problems := PackedStringArray()

# --- Seams -----------------------------------------------------------------------

var server: DotServer = null
var console: DotConsole = null

## `func() -> Array[DotClientSession]`: who may appear on a player list.
var sessions_fn: Callable = Callable()

## `func(session: DotClientSession, page: Dictionary) -> bool`. An empty page closes it.
var send_fn: Callable = Callable()

## `func() -> Array` of `[id, label]`: the games a `game` step offers.
var games_fn: Callable = Callable()

## `func() -> Array` of `[id, label]`: the maps a `map` step offers.
var maps_fn: Callable = Callable()

## `func() -> Object`: dot-moderation's manager, or null.
var moderation_fn: Callable = Callable()

## The commands this registered, so they go when it does.
var _registered := PackedStringArray()

var _limiter := DotRateLimiter.new(NAV_PER_SEC, NAV_BURST)


## Builds the menu from `admin_menu.yml`'s tree and registers its commands. Null when the
## file turns it off.
static func install(
	host: Node, p_server: DotServer, tree: Dictionary, map_session_fn: Callable = Callable()
) -> TmcAdminMenu:
	var menu := TmcAdminMenu.new()
	menu.name = "AdminMenu"
	menu.configure(tree)

	if not menu.enabled:
		DotLog.info(CHANNEL, "the admin menu is turned off", {})
		return null

	if p_server == null or p_server.console == null:
		return null

	menu.server = p_server
	menu.console = p_server.console
	menu.sessions_fn = p_server.playing_sessions
	menu.send_fn = func(session: DotClientSession, page: Dictionary) -> bool:
		if page.is_empty():
			return p_server.send_notice(session, DotNotice.clear(TOPIC))
		return p_server.send_notice(session, DotNotice.make(&"", "", -1.0, TOPIC, {"menu": page}))
	menu.games_fn = func() -> Array:
		var out := []
		if p_server.games == null:
			return out
		# Not the one running: changing to it is refused, and a row that can only fail is
		# a row that should not be there.
		var running := p_server.games.current()
		for id in p_server.games.game_ids():
			if running != null and running.game_id == id:
				continue
			var d := p_server.games.find_game(id)
			out.append([id, d.display_name_or_id() if d != null else id])
		return out
	menu.maps_fn = func() -> Array:
		return TmcAdminMenu.maps_of(map_session_fn.call() if map_session_fn.is_valid() else null)
	menu.moderation_fn = func() -> Object:
		return DotRegistry.get_service(MODERATION_SERVICE)

	host.add_child(menu)
	menu.register_commands()
	p_server.envelope.register(KIND, menu._on_kind)

	for problem in menu.problems:
		DotLog.warn(CHANNEL, "admin_menu.yml: %s" % problem, {})

	DotLog.info(CHANNEL, "admin menu ready", {
		"open_with": ", ".join(menu.commands),
		"items": menu.items.size(),
		"categories": menu.categories.size(),
	})

	return menu


## The maps a duck-typed map session's catalogue holds, as `[id, label]`.
static func maps_of(session: Object) -> Array:
	var out := []
	if session == null:
		return out
	var catalogue: Variant = session.get("catalogue")
	if catalogue == null or not (catalogue as Object).has_method("available"):
		return out
	var current: Variant = session.get("current")
	var running := String(current.get("id")) if current != null else ""
	for map in (catalogue as Object).call("available"):
		var id := String(map.get("id"))
		if id == running:
			continue
		var label := str(map.get("display_name"))
		out.append([id, label if label != "" else id])
	return out


func _exit_tree() -> void:
	if server != null and is_instance_valid(server):
		server.envelope.unregister(KIND)
	if console == null:
		return
	for name in _registered:
		console.unregister_command(name)
	_registered.clear()


# --- Configuration ---------------------------------------------------------------

## Reads `admin_menu.yml`'s tree over the defaults. Returns self.
##
## [b]Items and lists merge by key; categories replace.[/b] `items: {kick: {label: Boot}}`
## renames kick and keeps the rest of it, because an owner changing one word should not
## have to restate a command line. A `categories:` block is the owner saying what is on
## the menu, so it replaces the layout whole — an item they left out is out — and the one
## exception is an item they ADDED and placed nowhere, which goes under "Other" rather than
## being defined and unreachable.
func configure(tree: Dictionary) -> TmcAdminMenu:
	problems.clear()

	for key in tree.keys():
		var name := String(key)
		var value: Variant = tree[key]

		match name:
			"admin_menu_enabled":
				enabled = _truthy(value)
			"admin_menu_commands":
				commands = PackedStringArray()
				for one in (value if value is Array else [value]):
					var c := _id(str(one))
					if c != "":
						commands.append(c)
				if commands.is_empty():
					problems.append("admin_menu_commands names no command; using /admin")
					commands = PackedStringArray(DEFAULT_COMMANDS)
			"admin_menu_title":
				title = _label(str(value))
			"admin_menu_flag":
				open_flag = str(value).strip_edges()
			"admin_menu_warn_flag":
				warn_flag = str(value).strip_edges()
			"admin_menu_warn_announce":
				warn_announce = _truthy(value)
			"admin_menu_address_flag":
				address_flag = str(value).strip_edges()
			"admin_menu_after_run":
				var mode := str(value).strip_edges().to_lower()
				if mode in ["close", "back", "root"]:
					after_run = mode
				else:
					problems.append("admin_menu_after_run must be close, back or root, not '%s'" % mode)
			"items", "lists", "categories":
				pass
			_:
				problems.append("unknown key '%s'" % name)

	# Lists first: an item's steps are checked against them.
	lists = {}
	for id in DEFAULT_LISTS.keys():
		lists[id] = _normalise_list(id, DEFAULT_LISTS[id])

	var file_lists: Variant = tree.get("lists", {})
	if file_lists is Dictionary:
		for key in (file_lists as Dictionary).keys():
			var id := _id(String(key))
			var raw: Variant = file_lists[key]
			if id == "" or not (raw is Dictionary):
				problems.append("lists.%s must be a mapping" % String(key))
				continue
			var merged: Dictionary = (DEFAULT_LISTS.get(id, {}) as Dictionary).duplicate(true)
			merged.merge(raw, true)
			lists[id] = _normalise_list(id, merged)
	elif file_lists != null and str(file_lists) != "":
		problems.append("lists must be a mapping")

	var raw_items: Dictionary = {}
	for id in DEFAULT_ITEMS.keys():
		raw_items[id] = (DEFAULT_ITEMS[id] as Dictionary).duplicate(true)

	var added := PackedStringArray()
	var file_items: Variant = tree.get("items", {})
	if file_items is Dictionary:
		for key in (file_items as Dictionary).keys():
			var id := _id(String(key))
			var raw: Variant = file_items[key]
			if id == "" or not (raw is Dictionary):
				problems.append("items.%s must be a mapping" % String(key))
				continue
			if not raw_items.has(id):
				added.append(id)
				raw_items[id] = {}
			(raw_items[id] as Dictionary).merge(raw, true)
	elif file_items != null and str(file_items) != "":
		problems.append("items must be a mapping")

	items = {}
	for id in raw_items.keys():
		var item := _normalise_item(id, raw_items[id])
		if bool(item["enabled"]):
			items[id] = item

	categories = {}
	var file_categories: Variant = tree.get("categories", null)
	var layout: Dictionary = DEFAULT_CATEGORIES
	if file_categories is Dictionary and not (file_categories as Dictionary).is_empty():
		layout = file_categories
	elif file_categories != null and not (file_categories is Dictionary) and str(file_categories) != "":
		problems.append("categories must be a mapping")

	var placed := {}
	for key in layout.keys():
		var id := _id(String(key))
		var raw: Variant = layout[key]
		if id == "" or not (raw is Dictionary):
			problems.append("categories.%s must be a mapping" % String(key))
			continue
		var members := PackedStringArray()
		var listed: Variant = (raw as Dictionary).get("items", [])
		for one in (listed if listed is Array else []):
			var item_id := _id(str(one))
			if items.has(item_id):
				members.append(item_id)
				placed[item_id] = true
			elif not raw_items.has(item_id):
				problems.append("categories.%s names '%s', which is not an item" % [id, str(one)])
		categories[id] = {
			"title": _label(str((raw as Dictionary).get("title", id.capitalize()))),
			"flag": str((raw as Dictionary).get("flag", "")).strip_edges(),
			"items": members,
		}

	var orphans := PackedStringArray()
	for id in added:
		if items.has(id) and not placed.has(id):
			orphans.append(id)
	if not orphans.is_empty():
		var other: Dictionary = categories.get(OTHER_CATEGORY, {"title": "Other", "flag": "", "items": PackedStringArray()})
		# Taken out, appended and put back: a PackedStringArray is a value, and appending to
		# the one a cast hands back appends to a copy nobody keeps.
		var members: PackedStringArray = other["items"]
		members.append_array(orphans)
		other["items"] = members
		categories[OTHER_CATEGORY] = other

	return self


func _normalise_list(id: String, raw: Dictionary) -> Dictionary:
	var format := str(raw.get("format", "")).strip_edges().to_lower()
	var options: Array = []
	var given: Variant = raw.get("options", [])

	for one in (given if given is Array else []):
		var label := ""
		var value := ""
		if one is Dictionary:
			value = _value(str((one as Dictionary).get("value", "")))
			label = _label(str((one as Dictionary).get("label", "")))
		else:
			value = _value(str(one))
		if value == "":
			problems.append("lists.%s has an empty option" % id)
			continue
		if label == "":
			label = _option_label(format, value)
		options.append({"label": label, "value": value})

	if options.is_empty() and not _truthy(raw.get("custom", false)):
		problems.append("lists.%s offers nothing to choose" % id)

	return {
		"title": _label(str(raw.get("title", id.capitalize()))),
		"custom": _truthy(raw.get("custom", false)),
		"format": format,
		"options": options,
	}


## A step's option as a person reads it: `1d` is "1 day", `0` is "Permanent".
static func _option_label(format: String, value: String) -> String:
	match format:
		"duration":
			var seconds := DotBanManager.parse_duration(value)
			if seconds == 0:
				return "Permanent"
			if seconds > 0:
				return human_duration(seconds)
		"seconds":
			if value.is_valid_int() and value.to_int() > 0:
				return human_duration(value.to_int())
	return value


## `90` is "1 minute 30 seconds", `86400` is "1 day". Words rather than dot-server's
## compact `1d`, because a menu row is read by somebody deciding, not typed.
static func human_duration(seconds: int) -> String:
	var parts := PackedStringArray()
	for unit in [[604800, "week"], [86400, "day"], [3600, "hour"], [60, "minute"], [1, "second"]]:
		var n := seconds / int(unit[0])
		if n > 0:
			parts.append("%d %s%s" % [n, unit[1], "" if n == 1 else "s"])
			seconds -= n * int(unit[0])
		if parts.size() == 2:
			break
	return " ".join(parts) if not parts.is_empty() else "0 seconds"


func _normalise_item(id: String, raw: Dictionary) -> Dictionary:
	var item := {
		"id": id,
		"label": _label(str(raw.get("label", id.capitalize()))),
		"command": str(raw.get("command", "")).strip_edges(),
		"flag": str(raw.get("flag", "")).strip_edges(),
		"info": _truthy(raw.get("info", false)),
		"confirm": _truthy(raw.get("confirm", false)),
		"self": _truthy(raw.get("self", false)),
		"enabled": _truthy(raw.get("enabled", true)),
		"steps": [],
	}

	var steps: Variant = raw.get("steps", [])
	for one in (steps if steps is Array else [steps]):
		var text := str(one).strip_edges()
		var name := text
		var kind := text
		if text.contains(":"):
			name = _id(text.get_slice(":", 0))
			kind = _id(text.get_slice(":", 1))
		else:
			name = _id(text)
			kind = name
		if name == "" or not (kind in BUILTIN_KINDS or lists.has(kind)):
			problems.append("items.%s: '%s' is not a step (player, game, map, text, or a list)" % [id, text])
			item["enabled"] = false
			continue
		(item["steps"] as Array).append({"name": name, "kind": kind})

	# Typed text is the last value on a path and takes every word after it, so a step that
	# can be typed into anywhere but last would swallow the steps behind it.
	var all_steps: Array = item["steps"]
	for i in range(all_steps.size() - 1):
		if all_steps[i]["kind"] == "text":
			problems.append("items.%s: a text step has to be the last one" % id)
			item["enabled"] = false

	if not bool(item["info"]):
		var command := String(item["command"])
		if command == "":
			problems.append("items.%s has no command" % id)
			item["enabled"] = false
		else:
			for step in item["steps"]:
				if not command.contains("{%s}" % step["name"]):
					problems.append("items.%s asks for '%s' and its command never uses {%s}" % [id, step["name"], step["name"]])
	elif (item["steps"] as Array).is_empty() or item["steps"][0]["kind"] != "player":
		problems.append("items.%s is an info item, which needs a player step first" % id)
		item["enabled"] = false

	return item


# --- Commands --------------------------------------------------------------------

func register_commands() -> void:
	for name in commands:
		var cmd := console.command(name, _cmd_open, "Open the admin menu", "").with_chat()
		_claim(cmd, name)

	var nav := console.command(
		NAV_COMMAND, _cmd_nav, "A choice in the admin menu. Sent by the menu, not typed.", ""
	).with_chat().as_hidden()
	_claim(nav, NAV_COMMAND)

	# `warn` is in the default menu and nothing in the family registered one: dot-moderation
	# has had a WARN record since it was written and no command that issues it. A server
	# whose game brings its own keeps that one.
	if console.find_command("warn") == null:
		var warn := console.command(
			"warn", _cmd_warn, "Warn a player: told to them, and kept on their record.", warn_flag
		).with_usage("<player> <reason>").with_args(2).with_chat()
		_claim(warn, "warn")


func _claim(cmd: DotConCommand, name: String) -> void:
	# `register_command` keeps the first registration of a name and hands it back, so a
	# collision is not an error -- it is somebody else's command, and ours is not there.
	if cmd != null and cmd.handler.get_object() == self:
		_registered.append(name)
	else:
		problems.append("a command called '%s' already exists; the menu did not take it" % name)


func _cmd_open(ctx: DotCmdContext) -> void:
	if ctx.session == null:
		ctx.reply("The admin menu is drawn on a player's screen. From here, type the commands themselves.")
		return

	if not may_open(ctx):
		ctx.reply("There is nothing on the admin menu you may use here.")
		return

	_send(ctx, root_page(ctx))


func _cmd_nav(ctx: DotCmdContext) -> void:
	if ctx.session == null:
		return

	if not may_open(ctx):
		ctx.reply("There is nothing on the admin menu you may use here.")
		_send(ctx, {})
		return

	handle(ctx, ctx.args)


## A choice off the wire. See [constant KIND].
##
## [b]Answered as CHAT.[/b] It is the player's in-game input channel, the same one the
## typed `/admin_menu` arrives on, so a command that refuses chat is refused here too and
## the menu does not become a way round a game's own rule. Replies go to the admin as chat
## lines, which is where a typed command's replies go.
func _on_kind(peer_id: int, payload: Dictionary) -> void:
	if server == null:
		return
	var session := server.session_of(peer_id)
	if session == null or not session.is_playing():
		return
	if not _limiter.allow(session.userid):
		DotLog.debug(CHANNEL, "menu choices too fast; dropped", {"user": session.label()})
		return
	session.touch()
	var path := DotEnvelope.text(payload, "path").substr(0, MAX_PATH)
	var ctx := session.make_context(NAV_COMMAND, DotConsole.tokenize(path), DotCmdContext.Source.CHAT,
		func(line: String) -> void:
			if server.chat != null:
				server.chat.send_system_to(session, line))
	_cmd_nav(ctx)


## The `warn` this file fills in. See [method register_commands].
func _cmd_warn(ctx: DotCmdContext) -> void:
	var resolved := _resolve_target(ctx, ctx.arg(0))
	if not resolved.ok:
		ctx.reply_error(resolved)
		return

	var session: DotClientSession = resolved.value
	var reason := _text(ctx.rest(1))
	if reason == "":
		reason = "Warned by an admin"

	# Told to them twice: on the HUD, which they cannot miss, and in chat, which they can
	# scroll back to. Never naming the admin, dot-moderation's rule for every player message.
	var line := "Warning from an admin: %s" % reason
	if server != null:
		server.send_notice(session, DotNotice.make(&"", line, -1.0, &"admin_warning"))
		if server.chat != null:
			server.chat.send_system_to(session, line)

	var on_record := -1
	var moderation: Object = moderation_fn.call() if moderation_fn.is_valid() else null
	if moderation != null and moderation.has_method("issue") and moderation.has_method("subject_for_peer"):
		var subject := str(moderation.call("subject_for_peer", session.peer_id))
		var issued: Variant = await moderation.call(
			"issue", PUNISHMENT_WARN, subject, reason, ctx.caller_label(), 0, ctx.immunity
		)
		if issued is DotResult and not (issued as DotResult).ok:
			ctx.reply("Told them, but it was not recorded: %s" % (issued as DotResult).error.message)
		elif moderation.has_method("history_for"):
			on_record = 0
			for p in moderation.call("history_for", subject):
				if int(p.get("kind")) == PUNISHMENT_WARN:
					on_record += 1

	if server != null and server.audit != null:
		server.audit.record("warn", ctx.caller_label(), session.display_name, {"reason": reason})

	ctx.reply("Warned %s: %s%s" % [
		session.display_name, reason,
		"" if on_record < 0 else " (%d on record)" % on_record,
	])

	if warn_announce and server != null and server.chat != null:
		server.chat.announce_action("%s was warned: %s" % [session.display_name, reason])


# --- Visibility ------------------------------------------------------------------

## Whether [param ctx] may open the menu at all: the open flag, and one usable item.
func may_open(ctx: DotCmdContext) -> bool:
	if open_flag != "" and not ctx.has_permission(open_flag):
		return false
	for id in categories.keys():
		if not visible_items(ctx, id).is_empty():
			return true
	return false


## The ids of [param category]'s items [param ctx] may use, in order.
func visible_items(ctx: DotCmdContext, category: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cat: Dictionary = categories.get(category, {})
	if cat.is_empty():
		return out
	if String(cat["flag"]) != "" and not ctx.has_permission(String(cat["flag"])):
		return out
	for id in cat["items"]:
		if may_use(ctx, items.get(id, {})):
			out.append(id)
	return out


## Whether [param ctx] may use [param item]. See the class notes: computed from the console.
func may_use(ctx: DotCmdContext, item: Dictionary) -> bool:
	if item.is_empty() or not bool(item.get("enabled", false)):
		return false

	if String(item["flag"]) != "" and not ctx.has_permission(String(item["flag"])):
		return false

	for step in item["steps"]:
		if step["kind"] == "game" and _games().is_empty():
			return false
		if step["kind"] == "map" and _maps().is_empty():
			return false

	if bool(item["info"]):
		return true

	var cmd := command_of(item)
	if cmd == null:
		return false

	if ctx.source == DotCmdContext.Source.CHAT and not cmd.allows_chat(console.chat_commands_are_open()):
		return false

	return ctx.has_permission(cmd.permission)


## The console command [param item]'s line runs, or null when this server has none.
func command_of(item: Dictionary) -> DotConCommand:
	if console == null:
		return null
	var words := DotConsole.tokenize(String(item.get("command", "")))
	if words.is_empty():
		return null
	return console.find_command(words[0].to_lower())


# --- Pages -----------------------------------------------------------------------

## The first page: the categories this admin can use anything in. One is opened directly.
func root_page(ctx: DotCmdContext) -> Dictionary:
	var rows: Array = []
	var only := ""
	for id in categories.keys():
		if visible_items(ctx, id).is_empty():
			continue
		rows.append({"label": String(categories[id]["title"]), "go": "c:%s" % id})
		only = id

	if rows.size() == 1:
		return category_page(ctx, only)

	# A path of its own, so Back from a category comes here rather than closing.
	return _page(title, "", "root", rows)


func category_page(ctx: DotCmdContext, id: String) -> Dictionary:
	var rows: Array = []
	for item_id in visible_items(ctx, id):
		rows.append({"label": String(items[item_id]["label"]), "go": "i:%s" % item_id})

	if rows.is_empty():
		rows.append({"label": "Nothing here you may use."})

	return _page(String(categories.get(id, {}).get("title", title)), "", "c:%s" % id, rows)


## Answers one choice. [param tokens] is the path the client sent.
func handle(ctx: DotCmdContext, tokens: PackedStringArray) -> void:
	if tokens.is_empty():
		_send(ctx, root_page(ctx))
		return

	var head := tokens[0]

	if head.begins_with("c:"):
		var cat := _id(head.substr(2))
		if not categories.has(cat) or visible_items(ctx, cat).is_empty():
			_send(ctx, root_page(ctx))
			return
		_send(ctx, category_page(ctx, cat))
		return

	# `y:` is `i:` confirmed. In the head rather than after the values, because a custom
	# entry is the last value and swallows everything after it.
	if not (head.begins_with("i:") or head.begins_with("y:")):
		_send(ctx, root_page(ctx))
		return

	var item: Dictionary = items.get(_id(head.substr(2)), {})

	if not may_use(ctx, item):
		ctx.reply("That is not on your menu any more.")
		_send(ctx, root_page(ctx))
		return

	_advance(ctx, item, _fold_text(tokens.slice(1)), head.begins_with("y:"))


## Fills [param item]'s steps from [param values], then asks for the next one, shows the
## info page, asks for confirmation, or runs it.
func _advance(ctx: DotCmdContext, item: Dictionary, values: PackedStringArray, confirmed: bool = false) -> void:
	var steps: Array = item["steps"]
	var filled := {}
	var said := PackedStringArray()
	var path := PackedStringArray(["i:%s" % item["id"]])

	for i in steps.size():
		if i >= values.size():
			_send(ctx, step_page(ctx, item, i, path, said))
			return

		var got := _resolve(ctx, item, steps[i], values[i])
		if not got.ok:
			ctx.reply(got.error.message)
			_send(ctx, step_page(ctx, item, i, path, said))
			return

		filled[steps[i]["name"]] = got.value[0]
		said.append(got.value[1])
		path.append(values[i] if not values[i].begins_with("t:") else "t:%s" % got.value[1])

	if bool(item["info"]):
		_send(ctx, info_page(ctx, _session_for(values[0]), " ".join(path)))
		return

	var line := fill(String(item["command"]), filled)

	if bool(item["confirm"]) and not confirmed:
		var yes := path.duplicate()
		yes[0] = "y:%s" % item["id"]
		_send(ctx, _page(String(item["label"]), " · ".join(said), " ".join(path), [
			{"label": _label(line)},
			{"label": "Yes, do it", "go": " ".join(yes)},
			{"label": "No", "back": true},
		]))
		return

	DotLog.info(CHANNEL, "admin menu", {"by": ctx.caller_label(), "line": line})

	# The admin's own context, so this is exactly a typed command -- see the class notes.
	var result: Variant = console.execute(line, ctx)
	if result is DotResult and not (result as DotResult).ok:
		DotLog.debug(CHANNEL, "the menu's command was refused", {"line": line, "why": str((result as DotResult).error)})

	match after_run:
		"back":
			_send(ctx, step_page(ctx, item, 0, PackedStringArray(["i:%s" % item["id"]]), PackedStringArray()))
		"root":
			_send(ctx, root_page(ctx))
		_:
			_send(ctx, {})


## The page that asks for step [param index] of [param item].
func step_page(
	ctx: DotCmdContext, item: Dictionary, index: int,
	path: PackedStringArray, said: PackedStringArray
) -> Dictionary:
	var step: Dictionary = item["steps"][index]
	var prefix := " ".join(path.slice(0, index + 1))
	var kind := String(step["kind"])
	var rows: Array = []
	var heading := ""
	var input_now := false

	match kind:
		"player":
			heading = "Choose a player"
			var people := _sessions()
			people.sort_custom(func(a: DotClientSession, b: DotClientSession) -> bool:
				return a.display_name.naturalnocasecmp_to(b.display_name) < 0)
			for session in people:
				var me := session == ctx.session
				if me and not bool(item["self"]):
					continue
				if not me and not ctx.outranks(session.immunity):
					continue
				rows.append({
					"label": _label("%s (#%d)%s" % [session.display_name, session.userid, " — you" if me else ""]),
					"go": "%s #%d" % [prefix, session.userid],
				})
			if rows.is_empty():
				rows.append({"label": "Nobody here you may act on."})
		"game":
			heading = "Choose a game"
			for pair in _games():
				rows.append({"label": _label(str(pair[1])), "go": "%s %s" % [prefix, pair[0]]})
		"map":
			heading = "Choose a map"
			for pair in _maps():
				rows.append({"label": _label(str(pair[1])), "go": "%s %s" % [prefix, pair[0]]})
		"text":
			heading = "Type it"
			input_now = true
			rows.append({"label": "Type…", "input": prefix, "prompt": String(item["label"])})
		_:
			var list: Dictionary = lists[kind]
			heading = String(list["title"])
			var n := 0
			for option in list["options"]:
				n += 1
				rows.append({"label": String(option["label"]), "go": "%s %d" % [prefix, n]})
			if bool(list["custom"]) and index == (item["steps"] as Array).size() - 1:
				rows.append({"label": "Custom…", "input": prefix, "prompt": heading})

	var subtitle := " · ".join(said)
	subtitle = heading if subtitle == "" else "%s — %s" % [subtitle, heading]
	var page := _page(String(item["label"]), subtitle, prefix, rows)
	if input_now:
		page["input_now"] = true
	return page


## Everything an admin asks about a player, and what they may do to them from here.
func info_page(ctx: DotCmdContext, session: DotClientSession, path: String = "") -> Dictionary:
	if session == null:
		return _page("Player info", "", "", [{"label": "They are not here any more."}])

	var rows: Array = []
	var line := func(text: String) -> void:
		rows.append({"label": _label(text)})

	line.call("User id: #%d" % session.userid)
	line.call("Account: %s" % (session.uid() if session.uid() != "" else "guest"))
	if session.username() != "":
		line.call("Username: %s" % session.username())
	if address_flag == "" or ctx.has_permission(address_flag):
		line.call("Address: %s" % session.address)
	var seconds := session.connected_seconds()
	line.call("Connected %d:%02d · ping %s" % [
		seconds / 60, seconds % 60, ("%d ms" % session.ping_ms) if session.ping_ms >= 0 else "?"
	])
	if session.platform != "":
		line.call("Playing on %s" % session.platform)
	if session.is_admin():
		line.call("Staff, immunity %d" % session.immunity)
	if session.muted or session.gagged:
		line.call("Silenced: %s" % ("voice and chat" if session.muted else "chat"))

	var moderation: Object = moderation_fn.call() if moderation_fn.is_valid() else null
	if moderation != null and moderation.has_method("history_for") and moderation.has_method("subject_for_peer"):
		var history: Array = moderation.call("history_for", str(moderation.call("subject_for_peer", session.peer_id)))
		var active := 0
		var kinds := {}
		for p in history:
			if p.has_method("is_active") and bool(p.call("is_active")):
				active += 1
			var kind: String = ["ban", "kick", "voice mute", "gag", "warning"][clampi(int(p.get("kind")), 0, 4)]
			kinds[kind] = int(kinds.get(kind, 0)) + 1
		if history.is_empty():
			line.call("Nothing on record")
		else:
			var parts := PackedStringArray()
			for k in kinds.keys():
				parts.append("%d %s%s" % [kinds[k], k, "" if kinds[k] == 1 else "s"])
			line.call("On record: %s; %d in force" % [", ".join(parts), active])

	# Every other player item, already pointed at this player: the shortest way from
	# "who is this" to doing something about it.
	var actions: Array = []
	for cat in categories.keys():
		for id in visible_items(ctx, cat):
			var item: Dictionary = items[id]
			if bool(item["info"]) or (item["steps"] as Array).is_empty() or item["steps"][0]["kind"] != "player":
				continue
			if session == ctx.session and not bool(item["self"]):
				continue
			if session != ctx.session and not ctx.outranks(session.immunity):
				continue
			var go := "i:%s #%d" % [id, session.userid]
			if actions.any(func(r: Dictionary) -> bool: return r["go"] == go):
				continue
			actions.append({"label": String(item["label"]), "go": go})

	if not actions.is_empty():
		rows.append({"label": "— Actions —"})
		rows.append_array(actions)

	return _page(_label(session.display_name), "Player info", path, rows)


# --- Values ----------------------------------------------------------------------

## A step's value, checked against what this server has now. `[substituted, label]`.
func _resolve(ctx: DotCmdContext, item: Dictionary, step: Dictionary, token: String) -> DotResult:
	var kind := String(step["kind"])

	match kind:
		"player":
			var session := _session_for(token)
			if session == null:
				return DotResult.fail(DotError.CODE_INVALID, "%s is not here any more." % token)
			var me := session == ctx.session
			if me and not bool(item["self"]):
				return DotResult.fail(DotError.CODE_INVALID, "Not on yourself.")
			if not me and not ctx.outranks(session.immunity):
				return DotResult.fail(DotError.CODE_FORBIDDEN,
					"%s has equal or higher immunity than you." % session.display_name)
			return DotResult.success(["#%d" % session.userid, session.display_name])
		"game":
			for pair in _games():
				if str(pair[0]) == token:
					return DotResult.success([token, str(pair[1])])
			return DotResult.fail(DotError.CODE_INVALID, "No game called '%s' here." % token)
		"map":
			for pair in _maps():
				if str(pair[0]) == token:
					return DotResult.success([token, str(pair[1])])
			return DotResult.fail(DotError.CODE_INVALID, "No map called '%s' here." % token)
		"text":
			var text := _text(token.trim_prefix("t:")) if token.begins_with("t:") else ""
			if text == "":
				return DotResult.fail(DotError.CODE_INVALID, "Nothing was typed.")
			return DotResult.success([text, text])

	var list: Dictionary = lists[kind]

	if token.begins_with("t:"):
		var custom := _text(token.trim_prefix("t:"))
		var last: Dictionary = (item["steps"] as Array).back()
		if not bool(list["custom"]) or custom == "" or last != step:
			return DotResult.fail(DotError.CODE_INVALID, "Choose one from the list.")
		return DotResult.success([custom, custom])

	var options: Array = list["options"]
	if not token.is_valid_int() or token.to_int() < 1 or token.to_int() > options.size():
		return DotResult.fail(DotError.CODE_INVALID, "That choice is not on the list any more.")

	var option: Dictionary = options[token.to_int() - 1]
	return DotResult.success([String(option["value"]), String(option["label"])])


## [param template] with each `{name}` replaced by its value as ONE console argument.
##
## Quoted when it has a space, and never containing a quote or a semicolon: every value
## is either the server's own (a userid, a list entry) or went through [method _text].
static func fill(template: String, values: Dictionary) -> String:
	var out := template
	for name in values.keys():
		var value := _value(str(values[name]))
		if value.contains(" ") or value == "":
			value = "\"%s\"" % value
		out = out.replace("{%s}" % name, value)
	return out


## Joins a custom entry back together: the client sends `t:` and the words, which the
## console's tokenizer has split. Only ever the last value.
static func _fold_text(values: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for i in values.size():
		if values[i].begins_with("t:"):
			out.append(" ".join(values.slice(i)))
			return out
		out.append(values[i])
	return out


func _session_for(token: String) -> DotClientSession:
	if not token.begins_with("#") or not token.substr(1).is_valid_int():
		return null
	var userid := token.substr(1).to_int()
	for session in _sessions():
		if session.userid == userid:
			return session
	return null


## `warn`'s target. Through the server when there is one, which is what every other
## moderation command uses; by userid or exact name otherwise, which is a suite.
func _resolve_target(ctx: DotCmdContext, text: String) -> DotResult:
	if server != null:
		return server.resolve_target(ctx, text)
	var found := _session_for(text if text.begins_with("#") else "#%s" % text)
	if found == null:
		for session in _sessions():
			if session.display_name.to_lower() == text.to_lower():
				found = session
	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No player matching '%s'." % text)
	if not ctx.outranks(found.immunity):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "%s has equal or higher immunity than you." % found.display_name)
	return DotResult.success(found)


func _sessions() -> Array[DotClientSession]:
	var out: Array[DotClientSession] = []
	if sessions_fn.is_valid():
		for s in sessions_fn.call():
			if s is DotClientSession:
				out.append(s)
	return out


func _games() -> Array:
	return _pairs(games_fn)


func _maps() -> Array:
	return _pairs(maps_fn)


## `[id, label]` pairs whose id is one console token, so a path can carry it.
static func _pairs(fn: Callable) -> Array:
	var out := []
	if not fn.is_valid():
		return out
	for pair in fn.call():
		var id := str(pair[0])
		if id == "" or id.contains(" ") or id.contains("\"") or id.contains(";"):
			continue
		out.append([id, str(pair[1]) if (pair as Array).size() > 1 else id])
	return out


# --- Sending ---------------------------------------------------------------------

func _page(p_title: String, subtitle: String, path: String, rows: Array) -> Dictionary:
	var page := {"title": _label(p_title), "subtitle": _label(subtitle), "path": path, "rows": rows}

	if rows.size() > MAX_ROWS:
		page["rows"] = rows.slice(0, MAX_ROWS)
		(page["rows"] as Array).append({"label": "…and %d more" % (rows.size() - MAX_ROWS)})

	# Cut until it fits rather than have DotNotice drop the whole tree. See MAX_PAGE_BYTES.
	var cut := 0
	while JSON.stringify(page).length() > MAX_PAGE_BYTES and (page["rows"] as Array).size() > 1:
		(page["rows"] as Array).pop_back()
		cut += 1
	if cut > 0:
		(page["rows"] as Array).append({"label": "…and %d more" % cut})

	return page


func _send(ctx: DotCmdContext, page: Dictionary) -> void:
	if ctx.session == null or not send_fn.is_valid():
		return
	send_fn.call(ctx.session, page)


# --- Cleaning --------------------------------------------------------------------

## A label as drawn: one line, bounded.
static func _label(text: String) -> String:
	return DotChatManager.sanitise(text, MAX_LABEL)


## Text an admin typed, made safe to be one console argument: no quotes, no semicolons,
## nothing a tokenizer or a statement splitter reads as structure.
static func _text(text: String) -> String:
	return _value(DotChatManager.sanitise(text, MAX_TEXT))


static func _value(text: String) -> String:
	return text.replace("\"", "'").replace(";", ",").replace("\n", " ").replace("\r", " ").strip_edges()


static func _id(text: String) -> String:
	var out := ""
	for ch in text.strip_edges().to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
	return out


static func _truthy(value: Variant) -> bool:
	if value is bool:
		return value
	return str(value).strip_edges().to_lower() in ["true", "yes", "on", "1"]


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("open with : /%s" % ", /".join(commands))
	out.append("after run : %s" % after_run)
	for id in categories.keys():
		out.append("%-10s: %s" % [id, ", ".join(categories[id]["items"])])
	for problem in problems:
		out.append("problem   : %s" % problem)
	return out
