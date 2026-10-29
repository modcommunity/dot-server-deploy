class_name TmcTrail
extends Node

## dot-trail on the server, when the addon is linked and `trail.yml` turns it on: who wears what, checked against the site's purchases, carried on a dot-server envelope kind so no game's netcode changes. Never fatal.
## The addon is reached through the global class list, as [TmcRadio] does, so this project parses without it.

const CHANNEL := "tmc.trail"
const SERVICE := &"dot_trail_relay"
const CLASSES := ["DotTrailRegistry", "DotTrailStore", "DotTrailEquip", "DotTrailRelay", "DotTrailEnvelope", "DotTrailConfig", "DotTrailClient", "DotTrailBackendHttp"]

## Every key `trail.yml` accepts, with its type; anything else is reported as unknown.
const KEYS := {
	"trail_enabled": TYPE_BOOL, "trail_pack": TYPE_STRING, "trail_store_dir": TYPE_STRING,
	"trail_site_url": TYPE_STRING, "trail_api_key_file": TYPE_STRING,
	"trail_entitlements_path": TYPE_STRING, "trail_equip_cooldown": TYPE_FLOAT,
}

var registry: RefCounted = null
var relay: RefCounted = null
var backend: RefCounted = null
## The pack advertised as `sv_trail_pack`, "" for none.
var pack := ""

var _server: DotServer = null
var _sessions: Dictionary = {}
## peer id -> {ids: PackedStringArray, at: msec}
var _owned: Dictionary = {}


static func script_named(class_name_: String) -> Script:
	return TmcRadio.script_named(class_name_)


static func available() -> bool:
	for c in CLASSES:
		if script_named(c) == null:
			return false
	return true


## `trail.yml` into [member TmcConfig.trail]; unknown keys are reported, not fatal.
static func apply_config(config: TmcConfig, tree: Dictionary) -> DotResult:
	config.trail = {}
	for key in tree.keys():
		var name := String(key)
		if not KEYS.has(name):
			config.unknown.append("trail.yml: %s" % name)
			continue
		config.trail[name] = tree[key]
	return DotResult.success(null)


static func install(host: Node, p_server: DotServer, config: TmcConfig, data_dir: String) -> TmcTrail:
	var cfg: Dictionary = config.trail
	if not TmcConfig._truthy(cfg.get("trail_enabled", false)):
		return null
	if not available():
		DotLog.warn(CHANNEL, "trail_enabled is on but dot-trail is not in this build; add `- repo: dot-trail` to cfg/content/addons.yml and run setup", {})
		return null
	var node := TmcTrail.new()
	node.name = "Trails"
	node._server = p_server
	var started := node.start(cfg, data_dir)
	if not started.ok:
		DotLog.error(CHANNEL, "trails did not start", {"why": str(started.error)})
		node.free()
		return null
	host.add_child(node)
	DotLog.info(CHANNEL, "trails are on", node.describe())
	return node


## Loads the trail set, builds the relay on the server's envelope, advertises the pack.
func start(cfg: Dictionary, data_dir: String) -> DotResult:
	registry = script_named("DotTrailRegistry").new()
	registry.config.equip_cooldown = float(cfg.get("trail_equip_cooldown", registry.config.equip_cooldown))
	var dir := str(cfg.get("trail_store_dir", ""))
	dir = dir if not dir.is_empty() else data_dir.path_join("trails")
	if DirAccess.dir_exists_absolute(dir):
		var loaded: DotResult = script_named("DotTrailStore").new(registry).load_dir(dir)
		if not loaded.ok:
			return loaded.wrap("loading trails from " + dir)
	_make_backend(cfg)
	var equip: RefCounted = script_named("DotTrailEquip").new(registry)
	relay = script_named("DotTrailRelay").create(equip, _groups, _entitlements)
	if _server == null:
		return DotResult.success(self)
	var served: DotResult = script_named("DotTrailEnvelope").serve(_server, relay, _refresh)
	if not served.ok:
		return served
	_server.client_spawned.connect(_on_spawned)
	_server.client_disconnected.connect(_on_left)
	DotRegistry.register(SERVICE, relay)
	pack = str(cfg.get("trail_pack", "")).strip_edges()
	return _advertise()


func _make_backend(cfg: Dictionary) -> void:
	var url := str(cfg.get("trail_site_url", "")).strip_edges()
	var key_file := str(cfg.get("trail_api_key_file", ""))
	if url.is_empty() or key_file.is_empty():
		return
	var key := FileAccess.get_file_as_string(key_file).strip_edges() if FileAccess.file_exists(key_file) else ""
	if key.is_empty():
		DotLog.warn(CHANNEL, "no trail API key; only free and group trails can be worn", {"file": key_file})
		return
	var http_script := script_named("DotTrailBackendHttp")
	backend = http_script.call(&"make", self, url)
	backend.api_key = key
	var path := str(cfg.get("trail_entitlements_path", ""))
	if not path.is_empty():
		backend.entitlements_path = path


func _advertise() -> DotResult:
	if pack.is_empty() or _server.console == null:
		return DotResult.success(self)
	var tc: Object = script_named("DotTrailConfig").new()
	tc.pack = pack
	var res: DotResult = script_named("DotTrailClient").advertise(_server.console, tc)
	return DotResult.success(self) if res.ok else res


func _on_spawned(session: DotClientSession) -> void:
	_sessions[session.peer_id] = session
	relay.add_peer(session.peer_id)


func _on_left(session: DotClientSession, _reason: String) -> void:
	_sessions.erase(session.peer_id)
	_owned.erase(session.peer_id)
	relay.remove_peer(session.peer_id)


func _groups(peer: int) -> PackedStringArray:
	var s: DotClientSession = _sessions.get(peer)
	return s.groups if s != null else PackedStringArray()


func _entitlements(peer: int) -> PackedStringArray:
	return (_owned.get(peer, {}) as Dictionary).get("ids", PackedStringArray())


## Before a refusal: asks the site what [param peer] owns, at most every 2 s, so a trail bought a moment ago can be worn.
func _refresh(peer: int, _id: String) -> void:
	var s: DotClientSession = _sessions.get(peer)
	if backend == null or s == null or s.userid <= 0:
		return
	var row: Dictionary = _owned.get(peer, {})
	if not row.is_empty() and Time.get_ticks_msec() - int(row["at"]) < 2000:
		return
	var res: DotResult = await backend.entitlements(str(s.userid))
	if res.ok:
		_owned[peer] = {"ids": res.value["ids"], "at": Time.get_ticks_msec()}
	else:
		DotLog.warn(CHANNEL, "entitlements unavailable", {"peer": peer, "why": str(res.error)})


func describe() -> Dictionary:
	return {"trails": registry.count() if registry != null else 0, "pack": pack, "store": backend != null, "players": _sessions.size()}
