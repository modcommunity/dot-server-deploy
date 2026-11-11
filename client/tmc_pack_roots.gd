class_name TmcPackRoots
extends RefCounted

## Tells an addon that a mounted pack carries files its build left out.
##
## The web shell may leave an addon's heavy assets out of its own pck and fetch them as a pack on join. Each addon that supports this keeps a list of fallback roots (folders laid out like its own assets); this
## adds a mounted pack's folder to that list when the pack is ready and takes it off when the pack is released.
## An addon that is not in the build, or is older than the call, is skipped: the pack still mounts and nothing here fails.

## One row per addon: its script, the static calls, and the folder inside a mounted pack.
const TARGETS: Array[Dictionary] = [
	{
		"script": "res://addons/arena_weapons/art/aw_model_cache.gd",
		"add": "add_fallback_root",
		"remove": "remove_fallback_root",
		"subdir": "addons/arena_weapons/assets",
	},
]

## The rows in use; a suite swaps in a stand-in addon.
var targets: Array[Dictionary] = TARGETS.duplicate()

## Content key to the roots it listed, as `[script path, root]` pairs.
var _listed: Dictionary = {}


## Follows [param cloud]'s mounts. Safe to call once per client.
func attach(cloud: Object) -> void:
	cloud.connect("content_ready", _on_ready)
	cloud.connect("content_released", _on_released)


func _on_ready(manifest: Object, mount_prefix: String) -> void:
	var key := DotCloudClient.content_key_for(StringName(str(manifest.get("content_id"))), str(manifest.get("version")))
	list_mount(key, mount_prefix)


## Lists every target's folder found under [param mount_prefix]. Returns how many were listed.
func list_mount(key: String, mount_prefix: String) -> int:
	var rows: Array = []
	for target in targets:
		var root := mount_prefix.path_join(str(target["subdir"]))
		if not DirAccess.dir_exists_absolute(root):
			continue
		if _call_target(target, "add", root):
			rows.append([str(target["script"]), root])
	if not rows.is_empty():
		_listed[key] = rows
	return rows.size()


func _on_released(key: String) -> void:
	unlist_mount(key)


## Takes back what [method list_mount] listed for [param key].
func unlist_mount(key: String) -> void:
	for row: Array in _listed.get(key, []):
		for target in targets:
			if str(target["script"]) == row[0]:
				_call_target(target, "remove", str(row[1]))
	_listed.erase(key)


func _call_target(target: Dictionary, which: String, root: String) -> bool:
	var path := str(target["script"])
	if not ResourceLoader.exists(path):
		return false
	var script := load(path) as Script
	var method := str(target[which])
	if script == null or not _has_static(script, method):
		return false
	script.call(method, root)
	return true


static func _has_static(script: Script, method: String) -> bool:
	for m: Dictionary in script.get_script_method_list():
		if m["name"] == method:
			return true
	return false
