class_name TmcAddonAnnounce
extends RefCounted

## What this server tells joining clients about its addons: the lock's versions, the groups of the current game, and under `addons_announce: game` the next game's addons ahead of its content.
## One per host, which keeps the host's own state (server, config, content, the packs' needs) and is read through [member host].

const CHANNEL := "tmc.host"

## The host node (tmc_host.gd), read for `server`, `config`, `content`, `_module_name`, `_pack_requires` and `_mounted_versions`.
var host = null
## What [method advertise] announced before any game named its download groups, and the groups the current game's module names (`addon_groups()`).
var announced_set: Array = []
var told_groups := {}
## `addons_announce: game` only: the game a change is going to, between `game_changing` and its `game_loaded` or `game_load_failed`; its addons are announced beside the current game's.
var change_to: DotGameDescriptor = null
## `addons_announce: game` only: the addon set each peer was last told (at its challenge, or by [constant TmcAddonGroups.ANNOUNCE_KIND]), so a change tells only those who lack something.
var told := {}


func _init(p_host) -> void:
	host = p_host


## The addon refs this checkout installs. See setup.sh's "The addon lock".
const ADDONS_LOCK := "res://addons.lock"


## Tells every joining client which addon versions this server runs, so an addon release can skip the client build: an older shell fetches the newer addons as packs
## (`modcommunity/dot-<name>@<version>`, the alias of `gamespice-platform/<name>`; [method TmcAddonNamespaces.announced_pack_for] says why), lays them over its own and restarts into them (dot-cloud's `DotCloudAddonSet`).
## The lock, not a guess at the checkout: setup.sh puts every clone at the locked ref. `TMC_ADDONS_LOCK=off` advertises nothing, because then the lock is not true.
func advertise() -> void:
	if OS.get_environment("TMC_ADDONS_LOCK") == "off":
		DotLog.info(CHANNEL, "addons are not at the lock (TMC_ADDONS_LOCK=off); none advertised")
		return

	# [b]A box runs the dot-server its lock names, which may predate the field.[/b] Assigning
	# a property an older DotServer does not declare is a script error at boot, so the
	# question is asked of the object rather than assumed.
	if not ("addon_set" in host.server):
		DotLog.info(CHANNEL, "this dot-server cannot announce addons; clients keep their own", {
			"needs": "dot-server with DotServer.addon_set",
		})
		return

	var dirs := DirAccess.get_directories_at("res://addons")
	var announced := TmcAddonSet.addon_set_from(FileAccess.get_file_as_string(ADDONS_LOCK), dirs)
	# An operator's `overlays:` ride beside the lock's; one for a dir the lock names replaces it.
	var loaded := TmcAddonsConfig.load_from(host._config_dir, host._absolute(host._data_dir))

	if loaded.ok:
		announced = TmcAddonSet.merge_overlays(announced, (loaded.value as TmcAddonsConfig).overlay_set())
	else:
		DotLog.warn(CHANNEL, "addons.yml overlays not announced: %s" % loaded.error.message)

	# server.yml's `addons:` list: installed by setup.sh, announced here at the listed version (the lock's when it names none).
	var spaces := TmcAddonNamespaces.resolve((loaded.value as TmcAddonsConfig).namespaces if loaded.ok else PackedStringArray())
	var listed := TmcAddonSet.addons_from_list(host.config.addons_listed, spaces, FileAccess.get_file_as_string(ADDONS_LOCK), dirs)

	for problem in listed["errors"]:
		DotLog.error(CHANNEL, "server.yml addons: not announced: %s" % problem)
		push_error("TMC: server.yml addons: %s" % problem)

	announced = TmcAddonSet.merge_overlays(announced, listed["entries"])

	announced_set = announced
	_publish_addon_set()

	DotLog.info(CHANNEL, "the addon versions clients are told about", {
		"addons": announced.size(), "lock": ADDONS_LOCK, "announce": host.config.addons_announce,
	})


## Re-announces the addon set with the current game's download groups. After the module loads, because the module is what knows the game's weapons.
## A failed or absent module names none, so clients take every group, which is always safe.
func advertise_groups() -> void:
	if host.server == null or not ("addon_set" in host.server) or announced_set.is_empty():
		return

	var raw: Variant = null
	var module: Object = host.server.modules.get_module(host._module_name) if host._module_name != "" else null

	if module != null and module.has_method("addon_groups"):
		raw = module.call("addon_groups")

	var groups := TmcAddonSet.sanitize_groups(raw)

	if groups != told_groups:
		told_groups = groups
		DotLog.info(CHANNEL, "the download groups clients are told about", {
			"module": host._module_name, "groups": groups,
		})

	# Always, not only when the groups moved: under `addons_announce: game` the loaded game is what decides the set.
	_publish_addon_set()


## The entries clients are told about now. `all`: everything [method advertise] found. `game`: the framework's and what the current game needs,
## plus the game a change is going to; the whole set while either game's needs are unknown (no requires.json read yet, or a game with no pack).
func _announced_now() -> Array:
	if host.config == null or host.config.addons_announce != TmcConfig.ADDONS_ANNOUNCE_GAME:
		return announced_set

	var games: Array = [host.server.games.current() if host.server.games != null else null]

	if change_to != null:
		games.append(change_to)

	var needs: Array = []

	for descriptor: Variant in games:
		needs.append(_needs_of(descriptor))

	return TmcAddonSet.scoped(announced_set, TmcAddonSet.union_needs(needs))


## What a game's packs ask of the host's addons (`{dir: level}`, over its own pack and its dependencies), or null when not known: no game, a game with no
## delivered pack, or a pack whose requires.json has not been read. A dependency without one adds nothing; the game's own pack is the one that must be known.
func _needs_of(descriptor: DotGameDescriptor) -> Variant:
	if descriptor == null:
		return null

	# The game manager's descriptor is the loaded one, whose content id may be empty; the content list's names the pack and its dependencies,
	# as the host's `_publish_requires` reads them.
	var listed: DotGameDescriptor = host.content.find(descriptor.game_id) if host.content != null else null
	var source: DotGameDescriptor = listed if listed != null else descriptor
	var id := source.effective_content_id().get_slice("@", 0)
	var own: Variant = host._pack_requires.get(id)

	if not (own is Dictionary):
		# A game inside the build (no pack mounted for it) runs on the build's addons and needs no game addon.
		if not source.needs_delivered_content() and not host._mounted_versions.has(id):
			return {}

		return null

	var parts: Array = [own]

	for key in source.dependencies + source.server_dependencies:
		var needs: Variant = host._pack_requires.get(String(key).get_slice("@", 0))

		if needs is Dictionary:
			parts.append(needs)

	return TmcAddonSet.union_needs(parts)


## Sets `server.addon_set` (what the next challenge carries) from [method _announced_now]; true when it changed.
func _publish_addon_set() -> bool:
	if host.server == null or not ("addon_set" in host.server) or announced_set.is_empty():
		return false

	var wanted := TmcAddonSet.with_groups(_announced_now(), told_groups)

	if wanted == (host.server.get("addon_set") as Array):
		return false

	host.server.set("addon_set", wanted)

	if host.config.addons_announce == TmcConfig.ADDONS_ANNOUNCE_GAME:
		DotLog.info(CHANNEL, "the addons clients are told about (addons_announce: game)", {
			"addons": wanted.size(), "of": announced_set.size(),
			"game": host.server.games.current_content_id() if host.server.games != null else "",
			"next": change_to.content_id if change_to != null else "",
		})

	return true


## `addons_announce: game`: follows game changes so a client is told about the next game's addons before its content arrives. Nothing is wired under `all`.
func wire() -> void:
	if host.config.addons_announce != TmcConfig.ADDONS_ANNOUNCE_GAME or not ("addon_set" in host.server):
		return

	# Send-only here; the shell registers the handler. A shell that does not know it is not sent it (DotEnvelope).
	host.server.envelope.register(TmcAddonGroups.ANNOUNCE_KIND)
	host.server.game_changing.connect(_on_game_changing)
	host.server.games.game_load_failed.connect(_on_game_load_failed)
	host.server.client_state_changed.connect(func(session: DotClientSession) -> void:
		# The first state a session reports follows its challenge, which carried the set as it is now.
		if session != null and not told.has(session.peer_id):
			told[session.peer_id] = (host.server.get("addon_set") as Array).duplicate(true)
	)
	host.server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
		if session != null:
			told.erase(session.peer_id)
	)


func _on_game_changing(_from_key: String, _to_key: String) -> void:
	change_to = host.server.games.pending()
	announce_change()


func _on_game_load_failed(_content_key: String, _error: DotError) -> void:
	change_to = null
	_publish_addon_set()


## Announces the current and next games' addons, and tells every client in the game that lacks some of them ([constant TmcAddonGroups.ANNOUNCE_KIND]), before the change sends its content: the shell fetches them, mounts them in place where it can (restarts where it cannot) and rejoins into the new game. Run at `game_changing` and again as each pack of the change mounts here, because the next game's requires.json is only read when its pack is. A client too old for the kind that lacks an addon is kicked, loudly, rather than left to fail loading a game whose scripts it cannot compile; its rejoin gets the new set in the challenge.
func announce_change() -> void:
	if change_to == null:
		return

	# Not known until its pack mounts here: announcing the whole set meanwhile would send every client every addon. Its content_ready runs this again;
	# a pack that mounted with no requires.json stays unknown, and then the whole set is the safe answer.
	if _needs_of(change_to) == null and not host._mounted_versions.has(change_to.effective_content_id().get_slice("@", 0)):
		return

	if not _publish_addon_set():
		return

	var wanted: Array = host.server.get("addon_set")

	for session in host.server.sessions():
		if session == null or not session.is_active():
			continue

		var missing := TmcAddonSet.added(told.get(session.peer_id, []), wanted)

		if missing.is_empty():
			continue

		var dirs := PackedStringArray()

		for entry: Dictionary in missing:
			dirs.append(str(entry.get("dir", "")))

		if host.server.send_kind(session.peer_id, TmcAddonGroups.ANNOUNCE_KIND, {"addons": wanted, "game": change_to.content_key()}):
			told[session.peer_id] = wanted.duplicate(true)
			DotLog.info(CHANNEL, "told a client the next game's addons", {"user": session.label(), "addons": dirs})
			continue

		DotLog.warn(CHANNEL, "a client too old to be told the next game's addons is sent to rejoin", {
			"user": session.label(), "addons": dirs,
		})
		host.server.kick(session, "The next game needs addons this client has not got. Rejoin to download them.")
