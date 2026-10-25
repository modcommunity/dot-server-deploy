class_name TmcRadio
extends Node

## dot-radio on the server, when the addon is linked and `radio.yml` turns it on. Never fatal.
##
## The addon's classes are reached through the global class list, not by name: this project
## must parse in a build that does not carry dot-radio, and listing it in addons.yml is
## the only thing an operator does to get it.

const CHANNEL := "tmc.radio"
const SERVICE := &"dot_radio"
## The notice topic that tells a shell where the station is. See `client/tmc_radio_link.gd`.
const TOPIC := "tmc.radio"
const CLASSES := ["DotRadioLibrary", "DotRadioStation", "DotRadioApi", "DotRadioHttp"]

var http: RefCounted = null
var api: RefCounted = null
var public_url := ""

var _server: DotServer = null


## The script for a global `class_name`, or null when this build does not carry it.
static func script_named(class_name_: String) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_:
			return load(str(entry.get("path", ""))) as Script
	return null


static func available() -> bool:
	for c in CLASSES:
		if script_named(c) == null:
			return false
	return true


static func install(host: Node, p_server: DotServer, config: TmcConfig, data_dir: String) -> TmcRadio:
	if not config.radio_enabled:
		return null
	if not available():
		DotLog.warn(CHANNEL, "radio_enabled is on but dot-radio is not in this build; add `- repo: dot-radio` to cfg/content/addons.yml and run setup", {})
		return null
	var node := TmcRadio.new()
	node.name = "Radio"
	node._server = p_server
	var started := node.start(config.radio, data_dir)
	if not started.ok:
		DotLog.error(CHANNEL, "the radio did not start", {"why": str(started.error)})
		node.free()
		return null
	host.add_child(node)
	if p_server != null:
		p_server.client_spawned.connect(node._on_client_spawned)
	DotRegistry.register(SERVICE, node.api)
	DotLog.info(CHANNEL, "the radio is on", node.describe())
	return node


## Builds the station from the `radio_*` keys and starts the HTTP side.
func start(cfg: Dictionary, data_dir: String) -> DotResult:
	var library: RefCounted = script_named("DotRadioLibrary").new()
	var dir := str(cfg.get("radio_dir", ""))
	library.root = dir if not dir.is_empty() else data_dir.path_join("radio")
	DirAccess.make_dir_recursive_absolute(library.root)
	var station: RefCounted = script_named("DotRadioStation").new(library)
	api = script_named("DotRadioApi").new(library, station)
	http = script_named("DotRadioHttp").new(api)
	public_url = str(cfg.get("radio_public_url", ""))
	var block := {
		"enabled": true,
		"port": int(cfg.get("radio_port", 8791)),
		"bind": str(cfg.get("radio_bind", "127.0.0.1")),
		"token_file": str(cfg.get("radio_token_file", "")),
		"base": str(cfg.get("radio_base", "")),
		"autostart": bool(cfg.get("radio_autostart", true)),
		"upload_timeout_sec": float(cfg.get("radio_upload_timeout_sec", 120.0)),
		"library_dir": library.root,
	}
	if cfg.has("radio_max_track_mb"):
		block["max_track_mb"] = float(cfg["radio_max_track_mb"])
	return http.start_from_config(block)


func _process(_delta: float) -> void:
	if http != null:
		http.poll()


func _exit_tree() -> void:
	if http != null:
		http.stop()


## Tells the new player's shell where the station is, once, when they spawn.
func _on_client_spawned(session: DotClientSession) -> void:
	if public_url.is_empty() or _server == null:
		return
	_server.send_notice(session, DotNotice.make(&"", "", -1.0, TOPIC, {"url": public_url}))


func describe() -> Dictionary:
	return http.describe() if http != null else {}
