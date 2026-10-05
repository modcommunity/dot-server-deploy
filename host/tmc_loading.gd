class_name TmcLoading
extends Node

## What a player sees and hears while this server changes game or map under them:
## a background picture, music, tips — `cfg/loading.yml`, sent to the shell, drawn by
## [code]TmcLoadingScreen[/code].
##
## [b]Only for a change, not for the first connect.[/b] Before a player has joined, the
## page that launched them is what they are looking at, and this server has not been
## asked anything yet. Once they are in, every `changelevel` and every map that has to be
## downloaded is a stretch of nothing on screen, and that stretch is the server owner's to
## fill.
##
## [b]Sent as data, fetched by the client.[/b] The server sends URLs, never bytes: a
## picture and a song are what a CDN is for, a [DotNotice] holds eight kilobytes, and a
## server that streamed media to every player at the moment it is also sending them a
## game would be competing with itself for the one link that matters. So the document
## goes out once, on spawn, and the shell fetches what it names in the background WHILE
## THE PLAYER IS PLAYING — the change is the worst moment to start downloading a song.
##
## Three layers, each field falling through on its own: the map's entry, then the game's,
## then the default. A map with a screenshot and no music plays the game's music over its
## screenshot. Map entries are not in the document — a records server has two hundred
## maps, and the notice would be dropped whole — but sent as a hint when that map is about
## to load, from the loaded game's map session (`fetching` and `changing`, duck-typed:
## a game with no map session simply has no per-map screens).
##
## [b]A URL is only ever http(s).[/b] A server naming `res://` or `user://` would be a
## server reading files out of the player's own build or profile; the shell refuses those
## too, because the shell is where it matters, and they are refused here so an owner finds
## out at boot rather than from a player.

const CHANNEL := "tmc.loading"

## The notice topic. The shell keeps the last document it was sent under it.
const TOPIC := &"loading_screen"

## What the document is, so a shell can refuse one shaped by a future it does not know.
const VERSION := 1

## Most images, songs and tips an entry keeps.
const MAX_IMAGES := 8
const MAX_MUSIC := 4
const MAX_TIPS := 12

## Longest URL, tip and title.
const MAX_URL := 512
const MAX_TIP := 160
const MAX_TITLE := 64

## Under [constant DotNotice.MAX_DATA_BYTES]: a document past it would be dropped whole.
const MAX_DOC_BYTES := 6500

var enabled := true

## The default entry. See [method entry_from].
var default_entry: Dictionary = {}

## game id -> entry.
var games: Dictionary = {}

## map id -> entry.
var maps: Dictionary = {}

## Seconds the shell waits before showing a screen for a map download, so a download
## that is over in a blink does not flash one.
var show_delay_sec := 0.25

var problems := PackedStringArray()

var server: DotServer = null

## `func(data: Dictionary) -> int`: to everybody playing. Seam for a suite.
var broadcast_fn: Callable = Callable()

## `func(session: DotClientSession, data: Dictionary) -> bool`. Seam for a suite.
var send_fn: Callable = Callable()

## Where `loading_reload` reads the file again from. Set by [method install].
var reload_fn: Callable = Callable()

## `func() -> Object`: the loaded game's map session, or null. The host's own finder,
## handed in rather than repeated -- see `TmcHost._find_map_session`.
var map_session_fn: Callable = Callable()

var _map_session: Object = null


static func install(
	host: Node, p_server: DotServer, tree: Dictionary,
	p_reload_fn: Callable = Callable(), p_map_session_fn: Callable = Callable()
) -> TmcLoading:
	var node := TmcLoading.new()
	node.name = "Loading"
	node.configure(tree)

	for problem in node.problems:
		DotLog.warn(CHANNEL, "loading.yml: %s" % problem, {})

	if p_server == null:
		return null

	node.server = p_server
	node.reload_fn = p_reload_fn
	node.map_session_fn = p_map_session_fn
	node.broadcast_fn = func(data: Dictionary) -> int:
		return p_server.broadcast_notice(DotNotice.make(&"", "", -1.0, TOPIC, data))
	node.send_fn = func(session: DotClientSession, data: Dictionary) -> bool:
		return p_server.send_notice(session, DotNotice.make(&"", "", -1.0, TOPIC, data))

	host.add_child(node)

	p_server.client_spawned.connect(node._on_client_spawned)
	p_server.game_changing.connect(node._on_game_changing)
	if p_server.games != null:
		p_server.games.game_loaded.connect(node._on_game_loaded)
		p_server.games.game_load_failed.connect(node._on_game_load_failed)
	node._watch_maps()
	node._register_commands()

	DotLog.info(CHANNEL, "loading screens", node.describe())
	return node


# --- Configuration ---------------------------------------------------------------

## Reads `loading.yml`'s tree. Returns self.
func configure(tree: Dictionary) -> TmcLoading:
	problems.clear()
	enabled = true
	games = {}
	maps = {}

	var top := {}
	for key in tree.keys():
		var name := String(key)
		match name:
			"loading_enabled":
				enabled = TmcAdminMenu._truthy(tree[key])
			"loading_show_delay_sec":
				show_delay_sec = clampf(float(tree[key]), 0.0, 5.0)
			"loading_games", "loading_maps":
				var by_id: Variant = tree[key]
				if not (by_id is Dictionary):
					problems.append("%s must be a mapping of id to a screen" % name)
					continue
				var into := games if name == "loading_games" else maps
				for id in (by_id as Dictionary).keys():
					var raw: Variant = by_id[id]
					if not (raw is Dictionary):
						problems.append("%s.%s must be a mapping" % [name, String(id)])
						continue
					var e := entry_from(raw, "%s.%s" % [name, String(id)], "")
					if not e.is_empty():
						into[String(id)] = e
			_:
				if name.begins_with("loading_"):
					top[name.trim_prefix("loading_")] = tree[key]
				else:
					problems.append("unknown key '%s'" % name)

	default_entry = entry_from(top, "loading.yml", "loading_")

	if not games.is_empty() and not document().has("games"):
		problems.append("the default and loading_games come to more than %d bytes; each game's screen is sent when it loads instead of ahead of time" % MAX_DOC_BYTES)
	if JSON.stringify(document()).length() > MAX_DOC_BYTES:
		problems.append("the default screen alone is more than %d bytes and will not reach anybody; fewer tips?" % MAX_DOC_BYTES)

	return self


## One screen from YAML: `image`/`images`, `music`, `music_volume`, `tips`, `title`,
## `done_sound`. Unknown keys are problems. [param prefix] is how they were spelled.
func entry_from(raw: Dictionary, where: String, prefix: String) -> Dictionary:
	var out := {}
	var images := _urls(_list(raw.get("images", raw.get("image", []))), "%s: image" % where)
	if images.size() > MAX_IMAGES:
		problems.append("%s: only the first %d images are used" % [where, MAX_IMAGES])
		images = images.slice(0, MAX_IMAGES)
	if not images.is_empty():
		out["images"] = Array(images)

	var music := _urls(_list(raw.get("music", [])), "%s: music" % where)
	if not music.is_empty():
		out["music"] = Array(music.slice(0, MAX_MUSIC))

	if raw.has("music_volume"):
		out["volume"] = clampf(float(raw["music_volume"]), 0.0, 1.0)

	var done := _urls(_list(raw.get("done_sound", [])), "%s: done_sound" % where)
	if not done.is_empty():
		out["done"] = done[0]

	var tips := PackedStringArray()
	for tip in _list(raw.get("tips", [])):
		var clean := DotChatManager.sanitise(tip, MAX_TIP)
		if clean != "":
			tips.append(clean)
	if not tips.is_empty():
		out["tips"] = Array(tips.slice(0, MAX_TIPS))

	if raw.has("title"):
		var t := DotChatManager.sanitise(str(raw["title"]), MAX_TITLE)
		if t != "":
			out["title"] = t

	for key in raw.keys():
		if not String(key) in ["image", "images", "music", "music_volume", "done_sound", "tips", "title", "enabled", "show_delay_sec"]:
			problems.append("%s: unknown key '%s%s'" % [where, prefix, String(key)])

	return out


static func _list(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for v in value:
			if str(v).strip_edges() != "":
				out.append(str(v).strip_edges())
	elif value != null and str(value).strip_edges() != "":
		out.append(str(value).strip_edges())
	return out


func _urls(values: PackedStringArray, where: String) -> PackedStringArray:
	var out := PackedStringArray()
	for url in values:
		if is_safe_url(url):
			out.append(url)
		else:
			problems.append("%s '%s' is not an http(s) URL, and a player's shell will not fetch it" % [where, url.substr(0, 80)])
	return out


## The rule the shell applies too: an absolute http(s) URL, bounded, one token.
static func is_safe_url(url: String) -> bool:
	if url.length() > MAX_URL or url.contains(" ") or url.contains("\n") or url.contains("\"") or url.contains("\\"):
		return false
	var lower := url.to_lower()
	if not (lower.begins_with("https://") or lower.begins_with("http://")):
		return false
	var host := url.substr(url.find("//") + 2)
	return host != "" and not host.begins_with("/")


## The document every playing client is sent on spawn.
func document() -> Dictionary:
	var doc := {"v": VERSION, "default": default_entry, "delay": show_delay_sec}
	var with_games := doc.duplicate()
	with_games["games"] = games
	# The games' entries ride along when they fit, so their media can be fetched ahead of
	# time; when they do not, each goes out as a hint when its game is about to load.
	if JSON.stringify(with_games).length() <= MAX_DOC_BYTES:
		return with_games
	return doc


func is_empty() -> bool:
	return default_entry.is_empty() and games.is_empty() and maps.is_empty()


# --- What happens ----------------------------------------------------------------

func _on_client_spawned(session: DotClientSession) -> void:
	if not enabled or is_empty() or not send_fn.is_valid():
		return
	send_fn.call(session, document())


## A game is about to change: say which, and that a screen should go up now. The server
## is about to make every client download it while the OLD game is still on screen, and
## without this the screen would wait for the download to start rather than the change.
func _on_game_changing(_from_key: String, _to_key: String) -> void:
	if not enabled or is_empty():
		return
	var game_id := ""
	if server != null and server.games != null and server.games.pending() != null:
		game_id = server.games.pending().game_id
	_broadcast({"next": {"game": game_id, "entry": games.get(game_id, {})}, "show": true})


func _on_game_load_failed(_content_key: String, _error: DotError) -> void:
	if enabled and not is_empty():
		_broadcast({"cancel": true})


func _on_game_loaded(_content_key: String) -> void:
	# The new game's map session, if it has one, is in the tree now.
	_watch_maps.call_deferred()


## The map session's two moments a map is on its way. Not a show: a map that is already on
## a client's disk loads in a frame, and the shell decides from its own download whether
## there is anything to cover.
func _hint_map(map: Object) -> void:
	if not enabled or map == null:
		return
	var id := String(map.get("id"))
	if not maps.has(id):
		return
	_broadcast({"next": {"map": id, "entry": maps[id]}})


func _watch_maps() -> void:
	if not map_session_fn.is_valid():
		return
	var session: Object = map_session_fn.call()
	if session == _map_session:
		return
	_map_session = session
	if session == null:
		return
	# Bound to the session, so they go when it does: a game change frees it.
	if session.has_signal("fetching"):
		session.connect("fetching", func(map: Object) -> void: _hint_map(map))
	if session.has_signal("changing"):
		session.connect("changing", func(_from: Object, to: Object) -> void: _hint_map(to))


func _broadcast(data: Dictionary) -> void:
	if broadcast_fn.is_valid():
		broadcast_fn.call(data)


# --- Console ---------------------------------------------------------------------

func _register_commands() -> void:
	if server == null or server.console == null:
		return
	server.console.command("loading_screen", func(ctx: DotCmdContext) -> void:
		ctx.reply_lines(describe_lines()),
		"What the loading screen shows, per game and per map.",
		DotAdminFlags.GENERIC
	).with_chat()
	server.console.command("loading_screen_reload", func(ctx: DotCmdContext) -> void:
		if not reload_fn.is_valid():
			ctx.reply("This server cannot re-read its loading screen.")
			return
		var tree: Variant = reload_fn.call()
		if tree is DotResult:
			if not (tree as DotResult).ok:
				ctx.reply_error(tree)
				return
			tree = (tree as DotResult).value
		configure(tree if tree is Dictionary else {})
		for problem in problems:
			ctx.reply("problem: %s" % problem)
		if enabled and not is_empty():
			_broadcast(document())
		ctx.reply("Loading screen re-read and sent to everybody playing."),
		"Re-read cfg/loading.yml and send it to everybody playing.",
		DotAdminFlags.CONFIG
	)


func describe() -> Dictionary:
	return {
		"enabled": enabled,
		"default": not default_entry.is_empty(),
		"games": games.size(),
		"maps": maps.size(),
		"problems": problems.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("enabled  : %s" % ("yes" if enabled else "no"))
	out.append("default  : %s" % _summary(default_entry))
	for id in games.keys():
		out.append("game %-12s: %s" % [id, _summary(games[id])])
	for id in maps.keys():
		out.append("map  %-12s: %s" % [id, _summary(maps[id])])
	for problem in problems:
		out.append("problem  : %s" % problem)
	return out


static func _summary(entry: Dictionary) -> String:
	if entry.is_empty():
		return "(nothing)"
	return "%d image(s), %d song(s), %d tip(s)%s" % [
		(entry.get("images", []) as Array).size(),
		(entry.get("music", []) as Array).size(),
		(entry.get("tips", []) as Array).size(),
		", \"%s\"" % entry["title"] if entry.has("title") else "",
	]
