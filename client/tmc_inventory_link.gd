class_name TmcInventoryLink
extends Node

## Web transport for dot-cloud's inventory bridge: page `message` events in, `postMessage` replies out, only to allowlisted origins.
## Off-web or without dot-cloud's bridge class this does nothing. Schema: docs/web-inventory-bridge.md.

const CHANNEL := "tmc.inventory"
const BRIDGE_CLASS := "DotCloudInventoryBridge"
const CALLBACK := "tmc_inventory_message"

## func() -> Object: the shell's DotCloudClient, made on demand.
var cloud_fn: Callable = Callable()
## func() -> void: queue the shell's clear-on-restart.
var clear_fn: Callable = Callable()
## Origins that may ask; empty keeps the bridge off.
var origins: PackedStringArray = PackedStringArray()

var bridge: RefCounted = null
var _listening := false


static func _script_named(class_name_: String) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_:
			return load(str(entry.get("path", ""))) as Script
	return null


## Starts listening; false when off-web, no origin is configured or the bridge class is absent.
func start() -> bool:
	if _listening or origins.is_empty() or not DotPlatform.is_web():
		return false
	if _script_named(BRIDGE_CLASS) == null:
		return false
	var win: Variant = DotWeb.get_global("window")
	if win == null:
		return false
	var cb: Variant = DotWeb.create_callback(CALLBACK, _on_event)
	if cb == null:
		return false
	win.addEventListener("message", cb)
	_listening = true
	DotLog.info(CHANNEL, "inventory bridge listening", {"origins": origins.size()})
	return true


func _ensure_bridge() -> RefCounted:
	if bridge != null:
		return bridge
	var cloud: Object = cloud_fn.call() if cloud_fn.is_valid() else null
	if cloud == null or cloud.get("store") == null:
		return null
	bridge = _script_named(BRIDGE_CLASS).new(cloud.store, origins)
	bridge.clear_all_fn = func() -> DotResult:
		if clear_fn.is_valid():
			clear_fn.call()
		return DotResult.success(true)
	return bridge


## Origin first, and nothing else read from an unlisted sender.
func _on_event(args: Array) -> void:
	if args.is_empty():
		return
	var event: Variant = args[0]
	var origin := str(event.origin)
	if not origins.has(origin):
		return
	var json: Variant = DotWeb.get_global("JSON")
	var raw: Variant = event.data
	var text: String = raw if raw is String else str(json.stringify(raw))
	var message: Variant = JSON.parse_string(text)
	if not (message is Dictionary) or not _script_named(BRIDGE_CLASS).is_request(message):
		return
	var b := _ensure_bridge()
	if b == null:
		return
	_answer(b, message, origin, event.source)


func _answer(b: RefCounted, message: Dictionary, origin: String, source: Variant = null) -> void:
	var reply: Dictionary = await b.handle(message, origin)
	if reply.is_empty():
		return
	var target: Variant = source if source != null else DotWeb.get_global("parent")
	if target != null:
		target.postMessage(JSON.stringify(reply), origin)
