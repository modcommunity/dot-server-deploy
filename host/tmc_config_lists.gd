class_name TmcConfigLists
extends RefCounted

## The list-shaped and mode keys of `server.yml`, applied onto a [TmcConfig]: `games`, `addons`, `content_urls` and `log_router`.


## `games`: the directories a host offers, deduplicated.
static func apply_games(cfg: TmcConfig, file: String, value: Variant) -> void:
	# A list, or one string, as `content_urls` below takes either (`games: fatalcontact` is what an operator with one game writes).
	# Not a console line: dot-server has no cvar for the set of games a host offers; `sv_game` picks one OF these, so the two spellings are deliberately unalike.
	# Each entry through TmcGameRef, as the command-line override is, so `gamemann/game-g2gfast01@1.2.0` in a file means the same directory as in a panel field.
	# A game listed twice is one game: kept once, and ONE warning naming every repeat, never an error (a panel's list is edited by hand and copied around).
	var repeats := PackedStringArray()
	var entries: Array = (value as Array) if value is Array else [value]
	for entry in entries:
		for dir_name in TmcGameRef.dirs_in(String(entry)):
			if dir_name in cfg.games_allow:
				if not dir_name in repeats:
					repeats.append(dir_name)
			else:
				cfg.games_allow.append(dir_name)

	if not repeats.is_empty():
		DotLog.warn(TmcConfig.CHANNEL, "%s: games lists %s more than once; keeping one of each" % [file, ", ".join(repeats)])


## `addons`: the addon entries the operator listed, each checked on read.
static func apply_addons(cfg: TmcConfig, file: String, value: Variant) -> void:
	# A list, or one string. Every entry is checked now, against the first-party owners; an owner the operator trusts through `namespaces:` in cfg/content/addons.yml is rechecked by the host, which reads that file.
	var raw_entries: Array = (value as Array) if value is Array else [value]

	for entry in raw_entries:
		var text := String(entry).strip_edges()

		if text == "":
			continue

		var known := TmcAddonsConfig.parse_entry(text)

		if not known.ok:
			cfg.unknown.append("%s: addons: %s" % [file, known.error.message])
		elif not cfg.addons_listed.has(str(known.value)):
			cfg.addons_listed.append(str(known.value))


## `content_urls`: where the server (and, through it, the clients) fetch content from.
static func apply_content_urls(cfg: TmcConfig, file: String, value: Variant) -> void:
	# A list, or one string for the common case of a single origin. Not passed
	# through as a console line: this is dot-cloud's, and dot-server's console
	# has no cvar for it.
	if value is Array:
		for entry in (value as Array):
			var url := String(entry).strip_edges()
			if url != "":
				cfg.content_urls.append(url)
	else:
		var one := String(value).strip_edges()
		if one != "":
			cfg.content_urls.append(one)

	# The same list to the clients, from the same line of YAML: the server downloads maps from these and the client must download them from somewhere, and a shipped build can only guess its page's origin, wrong for every CDN.
	# Assigned only if this dot-server has the property: addons are separately cloned, so pulling one and not another is ordinary, and assigning a missing property is a FATAL script error
	# that aborts `TmcConfig._apply_settings` mid-way and returns null into a caller that reads `.ok` off it. (A key from a NEWER file than the code is the opposite skew: never fatal.)
	if "content_base_urls" in cfg.server:
		cfg.server.content_base_urls = cfg.content_urls
	else:
		cfg.unknown.append(
			"%s: content_urls was read, but this dot-server has no " % file
			+ "content_base_urls to put it in -- clients will not be told "
			+ "where the content is. Update the dot-server addon."
		)


## `log_router`: auto, on or off.
static func apply_log_router(cfg: TmcConfig, file: String, value: Variant) -> void:
	# A bool is accepted because `on` and `off` ARE bools in this dialect (`TmcYaml` reads `on`/`yes`/`true` as true), and `log_router: on` is the natural spelling;
	# reading only the three words would report it as an unknown key and leave the default in force.
	var mode := ""

	if value is bool:
		mode = "on" if bool(value) else "off"
	else:
		mode = String(value).strip_edges().to_lower()

	if mode not in ["auto", "on", "off"]:
		cfg.unknown.append(
			"%s: log_router must be auto, on or off (got '%s')" % [file, mode]
		)
	else:
		cfg.log_router = mode
