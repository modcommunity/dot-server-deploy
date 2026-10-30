class_name TmcTrailLink
extends Node

## The shell's half of dot-trail: fetches the server's trail pack before the join, carries wear requests on the link's envelope, draws ribbons on figures and adds a Trails page to the game's menu.
## Every dot-trail and dot-game class is reached by name, so a shell built without dot-trail parses and simply has no trails.

const CHANNEL := "tmc.trail"
const CLASSES := ["DotTrailRegistry", "DotTrailClient", "DotTrailEnvelope", "DotTrailMenu", "DotTrailBackendHttp", "DotTrailBackendStub"]
const GAME_CLIENT := &"dot_game_client"
const STUB_SAVE := "user://trail_store.json"

## func() -> String: the site's base url, "" offline.
var site_fn: Callable = Callable()
## func() -> String: the signed-in player's site token.
var token_fn: Callable = Callable()
## func() -> Object: the shell's DotCloudClient, made on demand.
var cloud_fn: Callable = Callable()

var registry: RefCounted = null
var client: RefCounted = null
var backend: RefCounted = null
var _menu: Object = null
var _screen: WeakRef = null
var _figure_fn: Callable = Callable()
var _tick := 0.0


## The script for a global `class_name`, or null; TmcRadio is host-only and absent from the web export.
static func _script_named(class_name_: String) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_:
			return load(str(entry.get("path", ""))) as Script
	return null


static func available() -> bool:
	for c in CLASSES:
		if _script_named(c) == null:
			return false
	return true


func _ready() -> void:
	if not available():
		set_process(false)
		return
	registry = _script_named("DotTrailRegistry").new()
	client = _script_named("DotTrailClient").new()
	client.registry = registry
	var avatars := _script_named("DotGameClientAvatars")
	if avatars != null and _has_static(avatars, &"figure_of"):
		_figure_fn = Callable(avatars, &"figure_of")
	client.node_for = func(actor: int) -> Node: return _figure_fn.call(actor) if _figure_fn.is_valid() else null
	client.changed.connect(func(_actor: int, _id: String) -> void:
		var screen: Object = _screen.get_ref() if _screen != null else null
		if screen != null:
			screen.server_changed())


## Adds the pack fetch to [param prejoin]'s extra steps; a failed fetch is a warning, never a failed join.
func before_join(prejoin: Object) -> void:
	if client == null or not (&"extra_steps" in prejoin):
		return
	var steps: Array = prejoin.get(&"extra_steps")
	steps.append(func(rules: Dictionary) -> DotResult:
		var cloud: Object = cloud_fn.call() if cloud_fn.is_valid() else null
		if cloud == null:
			return DotResult.success(0)
		return await client.fetch_pack(cloud, rules))


## Routes the trail kind through [param link]; call before the link is added (its credentials advertise the kind).
func attach(link: Object) -> void:
	if client != null:
		DotLog.result(CHANNEL, "trail envelope", _script_named("DotTrailEnvelope").attach(link, client))


## Back to no wearers and no page when the game is left.
func reset() -> void:
	if client != null:
		client.worn.clear()
	_menu = null


func _process(delta: float) -> void:
	_tick += delta
	if _tick < 0.5:
		return
	_tick = 0.0
	if client.worn.size() > 0:
		client.apply_missing()
	var game: Object = DotRegistry.get_service(GAME_CLIENT)
	var menu: Object = game.get(&"menu") if game != null and is_instance_valid(game) else null
	if menu != null and menu != _menu and is_instance_valid(menu):
		_menu = menu
		_script_named("DotTrailMenu").add_to(menu, _setup)


func _setup(screen: Object) -> void:
	screen.bind(registry, _backend())
	screen.request_fn = func(id: String) -> DotResult: return client.request(id)
	screen.worn_fn = func() -> String: return str(client.worn.get(multiplayer.get_unique_id(), "")) if multiplayer.has_multiplayer_peer() else ""
	_screen = weakref(screen)
	screen.refresh()


## The site's store when the shell knows the site, else a local stub so the page still works offline.
func _backend() -> RefCounted:
	if backend != null:
		return backend
	var site := str(site_fn.call()) if site_fn.is_valid() else ""
	if not site.is_empty():
		backend = _script_named("DotTrailBackendHttp").call(&"make", self, site, token_fn)
	else:
		backend = _script_named("DotTrailBackendStub").call(&"from_registry", registry, 1000, get_tree())
		backend.save_path = STUB_SAVE
		backend.load_state()
	DotLog.debug(CHANNEL, "trail store", {"site": site, "stub": site.is_empty()})
	return backend


static func _has_static(script: Script, method: StringName) -> bool:
	for m in script.get_script_method_list():
		if StringName(m.get("name", "")) == method:
			return true
	return false
