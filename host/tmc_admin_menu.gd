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

## Bytes a page's notice data may encode to before rows are cut, measured the way
## [DotNotice] measures it — [method @GlobalScope.var_to_bytes] of the whole `data` — and a
## margin under its [constant DotNotice.MAX_DATA_BYTES], past which it drops the tree WHOLE:
## a menu that silently never opens.
##
## [b]Bytes, not characters, and the review that found it measured both.[/b] The first
## version cut at 6000 characters of JSON: sixty players with ASCII names came to 7.6 KB
## encoded, Cyrillic names to 10.7 KB and CJK to 13.9 KB, all past the notice limit while
## under the character cut. Players choose their own names.
const MAX_PAGE_BYTES := 7900

## Step kinds this file fills itself. Any other kind is the name of a list.
##
## `player` is somebody the admin outranks; `anyone` is any player at all, for a step that
## names a place rather than a victim (`goto`, `send`'s destination), which is
## dot-moderation's own rule for those; `item` is what the loaded game's `give` can hand out.
const BUILTIN_KINDS := ["player", "anyone", "game", "map", "item", "text"]

## `DotPunishment.Kind.WARN`, as a number: this host has dot-moderation in its build, but
## the manager is found in the registry and spoken to by duck type, for the reason
## [TmcReplay] gives.
const PUNISHMENT_WARN := 4
const MODERATION_SERVICE := &"dot_moderation"

## The lists a step may name. A layer's `lists:` merges over these by key.
##
## A list either has `options:` (chosen by position, so the server's own text reaches the
## command) or a `source:`, the name of a list a game registered in code with
## [method add_list] — chosen by value, because what a game offers can change between two
## key presses, and the value is checked against what it offers NOW.
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
	"toggle": {
		"title": "On or off",
		"options": [{"label": "On", "value": "on"}, {"label": "Off", "value": "off"}],
	},
	"damage": {
		"title": "How hard",
		"options": [
			{"label": "Just a shove", "value": "0"},
			{"label": "5 damage", "value": "5"},
			{"label": "10 damage", "value": "10"},
			{"label": "25 damage", "value": "25"},
			{"label": "50 damage", "value": "50"},
		],
	},
	"burn": {
		"title": "For how long",
		"format": "seconds",
		"options": ["5", "10", "30"],
	},
	"blind": {
		"title": "For how long",
		"options": [
			{"label": "10 seconds", "value": "10"},
			{"label": "30 seconds", "value": "30"},
			{"label": "Until lifted", "value": "on"},
			{"label": "Lift it", "value": "off"},
		],
	},
	"health": {
		"title": "Health",
		"options": ["1", "25", "100", "200", "500"],
	},
	"speed": {
		"title": "Speed",
		"options": [
			{"label": "Half speed", "value": "0.5"},
			{"label": "Normal", "value": "1"},
			{"label": "One and a half", "value": "1.5"},
			{"label": "Double", "value": "2"},
			{"label": "Triple", "value": "3"},
		],
	},
	"gravity": {
		"title": "Gravity",
		"options": [
			{"label": "Moon (a quarter)", "value": "0.25"},
			{"label": "Half", "value": "0.5"},
			{"label": "Normal", "value": "1"},
			{"label": "Heavy (double)", "value": "2"},
		],
	},
}

## Every item a server gets without writing one. An item whose command this server does
## not have is simply not drawn — see the class notes — and one with an `ability` is drawn
## only when the loaded game says it can do that (see [method supports]). So the fun ones
## below appear in the 3D games, which implement them, and not in a 2D game, which has no
## body to slap.
const DEFAULT_ITEMS := {
	"kick": {"label": "Kick", "command": "kick {player} {reason}", "steps": ["player", "reason"]},
	"ban": {"label": "Ban", "command": "ban {player} {duration} {reason}", "steps": ["player", "duration", "reason"], "confirm": true},
	"warn": {"label": "Warn", "command": "warn {player} {reason}", "steps": ["player", "reason"]},
	"mute": {"label": "Mute (voice and chat)", "command": "mute {player} {duration} {reason}", "steps": ["player", "duration", "reason"]},
	"gag": {"label": "Gag (chat only)", "command": "gag {player} {duration} {reason}", "steps": ["player", "duration", "reason"]},
	"unmute": {"label": "Unmute", "command": "unmute {player}", "steps": ["player"]},
	"info": {"label": "Player info", "info": true, "steps": ["player"], "self": true, "flag": "kick"},

	"slay": {"label": "Slay", "command": "slay {player}", "steps": ["player"], "ability": "slay", "groups": true},
	"slap": {"label": "Slap", "command": "slap {player} {damage}", "steps": ["player", "damage"], "ability": "slap", "groups": true},
	"burn": {"label": "Set on fire", "command": "burn {player} {burn}", "steps": ["player", "burn"], "ability": "burn", "groups": true},
	"freeze": {"label": "Freeze", "command": "freeze {player} {seconds}", "steps": ["player", "seconds"], "ability": "freeze", "groups": true},
	"unfreeze": {"label": "Unfreeze", "command": "unfreeze {player}", "steps": ["player"], "ability": "freeze", "groups": true},
	"blind": {"label": "Blind", "command": "blind {player} {blind}", "steps": ["player", "blind"], "ability": "blind", "groups": true},
	"beacon": {"label": "Beacon", "command": "beacon {player} {toggle}", "steps": ["player", "toggle"], "ability": "beacon", "groups": true},
	"rename": {"label": "Rename", "command": "rename {player} {text}", "steps": ["player", "text"], "ability": "rename"},
	"respawn": {"label": "Respawn", "command": "respawn {player}", "steps": ["player"], "ability": "respawn", "self": true, "groups": true},

	"noclip": {"label": "Noclip", "command": "noclip {player} {toggle}", "steps": ["player", "toggle"], "ability": "noclip", "self": true},
	"god": {"label": "God mode", "command": "god {player} {toggle}", "steps": ["player", "toggle"], "ability": "god", "self": true},
	"buddha": {"label": "Buddha (hurt, never die)", "command": "buddha {player} {toggle}", "steps": ["player", "toggle"], "ability": "buddha", "self": true},
	"hp": {"label": "Set health", "command": "hp {player} {health}", "steps": ["player", "health"], "ability": "health", "self": true, "groups": true},
	"speed": {"label": "Speed", "command": "speed {player} {speed}", "steps": ["player", "speed"], "ability": "speed", "self": true, "groups": true},
	"gravity": {"label": "Gravity", "command": "gravity {player} {gravity}", "steps": ["player", "gravity"], "ability": "gravity", "self": true, "groups": true},
	"give": {"label": "Give", "command": "give {player} {item}", "steps": ["player", "item"], "ability": "give", "self": true},
	"strip": {"label": "Take their weapons", "command": "strip {player}", "steps": ["player"], "ability": "strip", "groups": true},

	"bring": {"label": "Bring to me", "command": "bring {player}", "steps": ["player"], "ability": "teleport", "groups": true},
	"goto": {"label": "Go to", "command": "goto {player}", "steps": ["player:anyone"], "ability": "teleport"},
	"send": {"label": "Send to somebody", "command": "send {player} {to}", "steps": ["player", "to:anyone"], "ability": "teleport"},
	"return": {"label": "Send back", "command": "return {player}", "steps": ["player"], "ability": "teleport", "self": true},

	"changelevel": {"label": "Change game", "command": "changelevel {game}", "steps": ["game"], "confirm": true},
	"map": {"label": "Change map", "command": "map {map}", "steps": ["map"], "confirm": true},
	"say": {"label": "Announce", "command": "say {text}", "steps": ["text"]},
}

## The layout a server gets without writing one. Ordered: the menu draws them as written.
const DEFAULT_CATEGORIES := {
	"players": {
		"title": "Player commands",
		"items": ["info", "kick", "ban", "warn", "mute", "gag", "unmute"],
	},
	"fun": {
		"title": "Fun commands",
		"items": ["slay", "slap", "burn", "freeze", "unfreeze", "blind", "beacon", "rename", "respawn"],
	},
	"powers": {
		"title": "Powers",
		"items": ["noclip", "god", "buddha", "hp", "speed", "gravity", "give", "strip"],
	},
	"teleport": {
		"title": "Teleport",
		"items": ["bring", "goto", "send", "return"],
	},
	"server": {
		"title": "Server commands",
		"items": ["changelevel", "map", "say"],
	},
}

## Where a game's own items go when it names no category: one per game, after the built-in
## ones, titled with the game's name.
const GAME_CATEGORY := "game"

## The registry name a game finds the menu under. Duck-typed on purpose: a game is a
## delivered pack and may not name this host's classes, and a game on a server that is not
## this one finds nothing and carries on. See [method set_layer] and [method add_list].
const SERVICE := &"admin_menu"

## The group targets a player step with `groups: true` offers, as dot-moderation's live
## tool commands spell them. Their own immunity rule skips anybody the admin cannot outrank.
const GROUPS := [["@all", "Everyone"], ["@others", "Everyone else"]]

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

## Whether a game's own items (its `game.yml` and what it registers in code) are on the
## menu. The owner's file wins either way; this is the switch for "none of them".
var game_items := true

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

## The owner's `admin_menu.yml`, kept so a game's layer can be merged UNDER it on every
## change. See [method _rebuild].
var _owner_tree: Dictionary = {}

## key -> {"tree": Dictionary, "owner": Object or null, "lists": {name: Callable}}, in the
## order they were set. "game" is the loaded game's `game.yml`; anything else is code.
var _layers: Dictionary = {}

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
	DotRegistry.register(SERVICE, menu)

	# The game's own `metadata: admin_menu:`, swapped on every change. Read now too, for
	# the game the server booted into, which loaded before this existed.
	if p_server.games != null:
		p_server.games.game_loaded.connect(func(_key: String) -> void: menu.adopt_game(p_server.games.current()))
		menu.adopt_game(p_server.games.current())

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
	DotRegistry.unregister_instance(SERVICE, self)
	if server != null and is_instance_valid(server):
		server.envelope.unregister(KIND)
	if console == null:
		return
	for name in _registered:
		console.unregister_command(name)
	_registered.clear()


# --- Configuration ---------------------------------------------------------------

## Reads `admin_menu.yml`'s tree over the defaults and any game layers. Returns self.
##
## [b]Four layers, the owner's last.[/b] The built-in defaults; the loaded game's
## `metadata: admin_menu:` from its `game.yml`; anything a game registered in code
## ([method set_layer]); and the owner's file. Each merges over the one before:
##
## - [b]items and lists merge by key[/b], so `items: {kick: {label: Boot}}` renames kick and
##   keeps its command, and `items: {slap: {enabled: false}}` takes a game's or the
##   built-in slap off;
## - [b]an item may name its own `category:`[/b], which is created if it does not exist;
## - [b]a game's `categories:` merge[/b]: their items are appended to a category of the
##   same id, or a new one is added after the built-in ones;
## - [b]the owner's `categories:` replace the built-in layout[/b], because that is the owner
##   saying what is on the menu — and a game's items still follow it unless
##   `admin_menu_game_items: false`, because a game that ships a "Restart the round" should
##   not lose it on every server whose owner reordered the moderation commands.
##
## An item somebody added and placed nowhere goes under the game's category (a game's) or
## "Other" (the owner's) rather than being defined and unreachable.
func configure(tree: Dictionary) -> TmcAdminMenu:
	_owner_tree = tree
	_rebuild()
	return self


func _read_settings(tree: Dictionary) -> void:
	# From the defaults every time: a setting taken out of the file goes back to its default
	# rather than keeping whatever the last read left behind.
	enabled = true
	commands = PackedStringArray(DEFAULT_COMMANDS)
	title = "Admin menu"
	open_flag = ""
	warn_flag = "kick"
	warn_announce = false
	address_flag = "kick"
	after_run = "close"
	game_items = true

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
			"admin_menu_game_items":
				game_items = _truthy(value)
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


## Everything, from the four layers. Called on every change to any of them.
func _rebuild() -> void:
	problems.clear()
	_prune()
	_read_settings(_owner_tree)

	var trees: Array = []
	if game_items:
		for key in _layers.keys():
			trees.append([String(key), _layers[key]["tree"]])
	trees.append(["admin_menu.yml", _owner_tree])

	# Lists first: an item's steps are checked against them.
	var raw_lists: Dictionary = {}
	for id in DEFAULT_LISTS.keys():
		raw_lists[id] = (DEFAULT_LISTS[id] as Dictionary).duplicate(true)
	for pair in trees:
		var given: Variant = (pair[1] as Dictionary).get("lists", {})
		if given is Dictionary:
			for key in (given as Dictionary).keys():
				var id := _id(String(key))
				if id == "" or not (given[key] is Dictionary):
					problems.append("%s: lists.%s must be a mapping" % [pair[0], String(key)])
					continue
				var merged: Dictionary = raw_lists.get(id, {})
				merged.merge(given[key], true)
				raw_lists[id] = merged
		elif given != null and str(given) != "":
			problems.append("%s: lists must be a mapping" % pair[0])
	lists = {}
	for id in raw_lists.keys():
		lists[id] = _normalise_list(id, raw_lists[id])

	# Items, remembering who added each one, for where an unplaced one goes.
	var raw_items: Dictionary = {}
	var added_by: Dictionary = {}
	for id in DEFAULT_ITEMS.keys():
		raw_items[id] = (DEFAULT_ITEMS[id] as Dictionary).duplicate(true)
	for pair in trees:
		var given: Variant = (pair[1] as Dictionary).get("items", {})
		if given is Dictionary:
			for key in (given as Dictionary).keys():
				var id := _id(String(key))
				if id == "" or not (given[key] is Dictionary):
					problems.append("%s: items.%s must be a mapping" % [pair[0], String(key)])
					continue
				if not raw_items.has(id):
					added_by[id] = pair[0]
					raw_items[id] = {}
				(raw_items[id] as Dictionary).merge(given[key], true)
		elif given != null and str(given) != "":
			problems.append("%s: items must be a mapping" % pair[0])

	items = {}
	for id in raw_items.keys():
		var item := _normalise_item(id, raw_items[id])
		if bool(item["enabled"]):
			items[id] = item

	# The layout: the owner's, or the built-in one; then each game's merged in.
	categories = {}
	var owner_layout: Variant = _owner_tree.get("categories", null)
	if owner_layout is Dictionary and not (owner_layout as Dictionary).is_empty():
		_merge_categories(owner_layout, "admin_menu.yml", raw_items, true)
	else:
		if owner_layout != null and not (owner_layout is Dictionary) and str(owner_layout) != "":
			problems.append("admin_menu.yml: categories must be a mapping")
		_merge_categories(DEFAULT_CATEGORIES, "built-in", raw_items, true)
	if game_items:
		for key in _layers.keys():
			var layout: Variant = (_layers[key]["tree"] as Dictionary).get("categories", {})
			if layout is Dictionary:
				_merge_categories(layout, String(key), raw_items, false)

	# An item's own `category:` wins over where a layout put it; then the unplaced ones.
	for id in items.keys():
		var wanted := _id(str(raw_items[id].get("category", "")))
		if wanted != "":
			_place(id, wanted, wanted.capitalize())
	for id in added_by.keys():
		if items.has(id) and not _placed(id):
			if added_by[id] == "admin_menu.yml":
				_place(id, OTHER_CATEGORY, "Other")
			else:
				_place(id, GAME_CATEGORY, str(_layers.get(added_by[id], {}).get("title", "This game")))


func _merge_categories(layout: Dictionary, where: String, raw_items: Dictionary, replace: bool) -> void:
	for key in layout.keys():
		var id := _id(String(key))
		var raw: Variant = layout[key]
		if id == "" or not (raw is Dictionary):
			problems.append("%s: categories.%s must be a mapping" % [where, String(key)])
			continue
		var existing: Dictionary = categories.get(id, {})
		var members: PackedStringArray = existing.get("items", PackedStringArray()) if not replace else PackedStringArray()
		var listed: Variant = (raw as Dictionary).get("items", [])
		for one in (listed if listed is Array else []):
			var item_id := _id(str(one))
			if items.has(item_id):
				if not members.has(item_id):
					members.append(item_id)
			elif not raw_items.has(item_id):
				problems.append("%s: categories.%s names '%s', which is not an item" % [where, id, str(one)])
		categories[id] = {
			"title": _label(str((raw as Dictionary).get("title", existing.get("title", id.capitalize())))),
			"flag": str((raw as Dictionary).get("flag", existing.get("flag", ""))).strip_edges(),
			"items": members,
		}


## Puts [param id] in [param category] (and nowhere else), making the category if needed.
func _place(id: String, category: String, p_title: String) -> void:
	for key in categories.keys():
		var members: PackedStringArray = categories[key]["items"]
		if members.has(id):
			members.remove_at(members.find(id))
			categories[key]["items"] = members
	var cat: Dictionary = categories.get(category, {"title": _label(p_title), "flag": "", "items": PackedStringArray()})
	# Taken out, appended and put back: a PackedStringArray is a value, and appending to
	# the one a cast hands back appends to a copy nobody keeps.
	var members: PackedStringArray = cat["items"]
	members.append(id)
	cat["items"] = members
	categories[category] = cat


func _placed(id: String) -> bool:
	for key in categories.keys():
		if (categories[key]["items"] as PackedStringArray).has(id):
			return true
	return false


# --- What a game adds ------------------------------------------------------------

## Adds or replaces a layer of items, lists and categories, in the same shape as
## `admin_menu.yml`. For a game, from its module:
##
## [codeblock]
## var menu := DotRegistry.get_service(&"admin_menu")
## if menu != null and menu.has_method("set_layer"):
##     menu.set_layer("arena", {
##         "title": "Arena",
##         "items": {"restart": {"label": "Restart the match", "command": "arena_restart"}},
##     }, self)
## [/codeblock]
##
## With an [param owner], the layer goes when the owner leaves the tree or is freed — a
## module unloaded by a game change takes its items with it and nothing has to remember to
## call [method clear_layer]. `title` names the category its unplaced items go under.
## The owner's own `admin_menu.yml` still wins over anything here.
func set_layer(key: String, tree: Dictionary, owner: Object = null) -> void:
	var layer: Dictionary = _layers.get(key, {"lists": {}})
	layer["tree"] = tree.duplicate(true)
	# Lists registered in code survive the tree being replaced.
	var declared: Dictionary = (layer["tree"] as Dictionary).get("lists", {})
	for name in (layer["lists"] as Dictionary).keys():
		if not declared.has(name):
			declared[name] = {"title": String(name).capitalize(), "source": name}
	if not declared.is_empty():
		layer["tree"]["lists"] = declared
	layer["title"] = _label(str(tree.get("title", key.capitalize())))
	layer["owner"] = weakref(owner) if owner != null else null
	_layers[key] = layer
	if owner is Node and not (owner as Node).tree_exiting.is_connected(clear_layer.bind(key)):
		(owner as Node).tree_exiting.connect(clear_layer.bind(key), CONNECT_ONE_SHOT)
	_rebuild()


## Takes a layer off, and every list it registered.
func clear_layer(key: String) -> void:
	if _layers.erase(key):
		_rebuild()


## A list whose options a game computes when the page is drawn: what `give` can hand out,
## the rounds a mode has, the teams there are. [param fn] returns an Array of
## `[value, label]` pairs or of plain strings. A step names it by giving its list a
## `source: <name>`, or by naming [param name] directly as the step's kind.
##
## Values are single words (no space, quote or semicolon), because the chosen value travels
## back in the path; anything else is dropped from the list.
func add_list(key: String, name: String, fn: Callable, list_title: String = "", owner: Object = null) -> void:
	if not _layers.has(key):
		set_layer(key, {}, owner)
	var id := _id(name)
	(_layers[key]["lists"] as Dictionary)[id] = fn
	var tree: Dictionary = _layers[key]["tree"]
	var given: Dictionary = tree.get("lists", {})
	if not given.has(id):
		given[id] = {"title": list_title if list_title != "" else id.capitalize(), "source": id}
		tree["lists"] = given
	_rebuild()


## The loaded game's `metadata: admin_menu:`, or nothing. Called on every game change.
func adopt_game(descriptor: Object) -> void:
	var tree: Variant = null
	var game_title := "This game"
	if descriptor != null:
		var meta: Variant = descriptor.get("metadata")
		if meta is Dictionary:
			tree = (meta as Dictionary).get("admin_menu", null)
		if descriptor.has_method("display_name_or_id"):
			game_title = str(descriptor.call("display_name_or_id"))
	if tree is Dictionary and not (tree as Dictionary).is_empty():
		var layer := (tree as Dictionary).duplicate(true)
		if not layer.has("title"):
			layer["title"] = game_title
		set_layer("game", layer)
	elif _layers.has("game"):
		clear_layer("game")


## Layers whose owner has gone.
func _prune() -> void:
	for key in _layers.keys():
		var held: Variant = _layers[key].get("owner")
		if held is WeakRef and (held as WeakRef).get_ref() == null:
			_layers.erase(key)


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

	var source := _id(str(raw.get("source", "")))
	if options.is_empty() and source == "" and not _truthy(raw.get("custom", false)):
		problems.append("lists.%s offers nothing to choose" % id)

	return {
		"title": _label(str(raw.get("title", id.capitalize()))),
		"custom": _truthy(raw.get("custom", false)),
		"format": format,
		"options": options,
		"source": source,
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
		"groups": _truthy(raw.get("groups", false)),
		"ability": _id(str(raw.get("ability", ""))),
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


## Whether [param id] is on a category [param ctx] can see.
func on_menu(ctx: DotCmdContext, id: String) -> bool:
	for cat in categories.keys():
		var flag := String(categories[cat]["flag"])
		if (categories[cat]["items"] as PackedStringArray).has(id) and (flag == "" or ctx.has_permission(flag)):
			return true
	return false


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

	if not supports(item):
		return false

	return ctx.has_permission(cmd.permission)


## Whether the loaded game can do what [param item]'s `ability` names.
##
## [b]The command existing is not enough for these, and that is dot-moderation's own
## design.[/b] Its live-tool commands are registered whether or not a game supports them,
## so `!slap` in a 2D game answers with the game's reason rather than "unknown command" —
## right for somebody typing, wrong for a menu, where a Slap row that can only fail is a
## row that should not be there. So an item with an ability asks the command's own handler
## object for its `tools` and asks those `supports(ability)`; `teleport` asks whether the
## game gave them a way to move a player. Duck-typed throughout: an item whose command is
## somebody else's, with no `tools` to ask, is shown, and the command answers for itself.
func supports(item: Dictionary) -> bool:
	var ability := String(item.get("ability", ""))
	if ability == "":
		return true
	var tools := _tools_of(command_of(item))
	if tools == null:
		return true
	if ability == "teleport":
		var mover: Variant = tools.get("teleport_fn")
		return mover is Callable and (mover as Callable).is_valid()
	if tools.has_method("supports"):
		return bool(tools.call("supports", StringName(ability)))
	return true


## dot-moderation's `DotModTools` behind a command, or null: the handler's object's `tools`.
static func _tools_of(cmd: DotConCommand) -> Object:
	if cmd == null or not cmd.handler.is_valid():
		return null
	var holder := cmd.handler.get_object()
	if holder == null:
		return null
	var tools: Variant = holder.get("tools")
	return tools as Object if tools is Object else null


## What the loaded game's `give` can hand out, as `[value, label]`: its command's own
## `items_fn`, which every game that has `give` already fills for the command's completion.
func _give_items() -> Array:
	var cmd := console.find_command("give") if console != null else null
	if cmd == null or not cmd.handler.is_valid() or cmd.handler.get_object() == null:
		return []
	var fn: Variant = cmd.handler.get_object().get("items_fn")
	if not (fn is Callable) or not (fn as Callable).is_valid():
		return []
	return _pairs(func() -> Array:
		var out := []
		for id in (fn as Callable).call():
			out.append([str(id), str(id).replace("_", " ").capitalize()])
		return out)


## A list's options as `{label, value}` rows: its own, or what its `source` returns now.
func _options_of(list: Dictionary) -> Array:
	var source := String(list.get("source", ""))
	if source == "":
		return list["options"]
	var fn := Callable()
	for key in _layers.keys():
		var held: Dictionary = _layers[key].get("lists", {})
		if held.has(source):
			fn = held[source]
	var out := []
	for pair in _pairs(fn):
		out.append({"label": _label(str(pair[1])), "value": str(pair[0])})
	return out


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

	var item_id := _id(head.substr(2))
	var item: Dictionary = items.get(item_id, {})

	# On the menu for THIS admin, not only usable: a path can name an item the owner left
	# out of every category, or put under a category whose flag this admin lacks, and the
	# drawing check is not the one that counts. For a command item the console's own flag
	# would still refuse; for an info item this is the only gate.
	if not on_menu(ctx, item_id) or not may_use(ctx, item):
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
		"player", "anyone":
			var anyone := kind == "anyone"
			heading = "Choose a player"
			# Groups first, for the first step of an item that takes them: the command's own
			# immunity rule skips whoever the admin cannot outrank, and says how many.
			if index == 0 and bool(item["groups"]):
				for group in GROUPS:
					rows.append({"label": group[1], "go": "%s %s" % [prefix, group[0]]})
			var people := _sessions()
			people.sort_custom(func(a: DotClientSession, b: DotClientSession) -> bool:
				return a.display_name.naturalnocasecmp_to(b.display_name) < 0)
			var someone := false
			for session in people:
				var me := session == ctx.session
				if me and not bool(item["self"]):
					continue
				if not me and not anyone and not ctx.outranks(session.immunity):
					continue
				someone = true
				rows.append({
					"label": _label("%s (#%d)%s" % [session.display_name, session.userid, " — you" if me else ""]),
					"go": "%s #%d" % [prefix, session.userid],
				})
			if not someone:
				rows.append({"label": "Nobody here you may act on."})
		"item":
			heading = "Choose what to give"
			for pair in _give_items():
				rows.append({"label": _label(str(pair[1])), "go": "%s =%s" % [prefix, pair[0]]})
			if rows.is_empty():
				rows.append({"label": "This game has nothing to give."})
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
			var dynamic := String(list["source"]) != ""
			for option in _options_of(list):
				n += 1
				# A computed list travels by value; see DEFAULT_LISTS.
				rows.append({"label": String(option["label"]),
					"go": "%s =%s" % [prefix, option["value"]] if dynamic else "%s %d" % [prefix, n]})
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
			if bool(item["info"]) or (item["steps"] as Array).is_empty() or not (item["steps"][0]["kind"] in ["player", "anyone"]):
				continue
			if session == ctx.session and not bool(item["self"]):
				continue
			if session != ctx.session and item["steps"][0]["kind"] == "player" and not ctx.outranks(session.immunity):
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
		"player", "anyone":
			for group in GROUPS:
				if token == group[0]:
					var first: Dictionary = (item["steps"] as Array)[0]
					if not bool(item["groups"]) or first != step:
						return DotResult.fail(DotError.CODE_INVALID, "Not for everybody at once.")
					return DotResult.success([group[0], String(group[1]).to_lower()])
			var session := _session_for(token)
			if session == null:
				return DotResult.fail(DotError.CODE_INVALID, "%s is not here any more." % token)
			var me := session == ctx.session
			if me and not bool(item["self"]):
				return DotResult.fail(DotError.CODE_INVALID, "Not on yourself.")
			if not me and kind == "player" and not ctx.outranks(session.immunity):
				return DotResult.fail(DotError.CODE_FORBIDDEN,
					"%s has equal or higher immunity than you." % session.display_name)
			return DotResult.success(["#%d" % session.userid, session.display_name])
		"item":
			for pair in _give_items():
				if "=%s" % pair[0] == token:
					return DotResult.success([str(pair[0]), str(pair[1])])
			return DotResult.fail(DotError.CODE_INVALID, "This game cannot give that.")
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

	var options: Array = _options_of(list)
	if String(list["source"]) != "":
		for option in options:
			if "=%s" % option["value"] == token:
				return DotResult.success([String(option["value"]), String(option["label"])])
		return DotResult.fail(DotError.CODE_INVALID, "That choice is not on the list any more.")
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
	# The "…and N more" row is counted in, so adding it cannot push the page back over.
	var cut := 0
	while encoded_size(page) > MAX_PAGE_BYTES and (page["rows"] as Array).size() > 1:
		if cut > 0:
			(page["rows"] as Array).pop_back()
		(page["rows"] as Array).pop_back()
		cut += 1
		(page["rows"] as Array).append({"label": "…and %d more" % cut})

	return page


## What [param page] costs inside a notice, as [DotNotice] counts it.
static func encoded_size(page: Dictionary) -> int:
	return var_to_bytes({"menu": page}).size()


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
