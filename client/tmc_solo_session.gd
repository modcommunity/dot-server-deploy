class_name TmcSoloSession
extends Node

## The solo game the shell is running, as a game and its menu find it.

## `<owner>/<repo>` and the version that was mounted.
var content_id: String = ""
var version: String = ""

## The game's display name, from its `game.yml`.
var display_name: String = ""

## Where the game's pack is mounted: `res://dot_cloud/<id>/<version>`.
var mount_root: String = ""

## Each mounted map pack's root, `res://dot_cloud/<id>/<version>`, in `client/solo.json`'s
## order, and the `<id>@<version>` keys they were mounted from.
var map_roots: PackedStringArray = PackedStringArray()
var map_keys: PackedStringArray = PackedStringArray()

## The map the player asked to start on (`?map=`, `--solo-map`), &"" for the game's own first map.
## Only a request: the game checks it is a map it has or can fetch.
var start_map: StringName = &""

## Whether the game's manifest has `provides.accepts`. A game without it takes no
## subscriptions, the sync is not run for it, and its page says so.
var takes_subscriptions: bool = false

## The Workshop's summary for this start (`{}` when it did not run), for the Subscriptions
## page: what mounted, what was skipped and why, whether the player was a guest.
var workshop_summary: Dictionary = {}

## What leaving does. Set by the shell.
var leave_fn: Callable = Callable()

## The `<id>@<version>` keys of the packs the game named beside its own (`dependencies` and
## `server_dependencies`), as they were resolved and mounted.
var pack_keys: PackedStringArray = PackedStringArray()

## Where the packs were downloaded, and the `--content-url` this shell was given (or ""): what a
## second process needs to mount the same packs without fetching them again.
var cache_dir: String = ""
var content_url: String = ""


## dot-menu's Leave calls this on its [member DotMenu.leave_link].
func disconnect_from_server(_reason: String = "") -> void:
	leave()


## Always true while the session exists, so dot-menu shows Leave and routes it here.
func is_connected_to_server() -> bool:
	return true


func leave() -> void:
	if leave_fn.is_valid():
		leave_fn.call_deferred()


## `<root>/<subdir>` for every mounted map pack that has that directory: the same answer
## `DotGameContent.map_dirs` gives a server module for the packs its server names.
func map_dirs(subdir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for root in map_roots:
		var dir := root.path_join(subdir) if subdir != "" else root
		if DirAccess.dir_exists_absolute(dir):
			out.append(dir)
	return out


## The user args (after `--`) that start this shell again as the game's own server process:
## the same game, version and packs, from the same cache, with no menu (see
## [method TmcSolo.is_sim_child]). A game that hosts its solo session in a second process
## appends these to its own; one that does not never calls this. Subscribed Workshop packs
## are not passed.
func sim_child_args() -> PackedStringArray:
	var out := PackedStringArray([TmcSolo.CHILD_FLAG, "1", "--solo", content_id, "--solo-version", version])
	if not pack_keys.is_empty():
		out.append_array([TmcSolo.PACKS_FLAG, ",".join(pack_keys)])
	if not map_keys.is_empty():
		out.append_array([TmcSolo.MAPS_FLAG, ",".join(map_keys)])
	if cache_dir != "":
		out.append_array(["--cloud-cache-dir", cache_dir])
	if content_url != "":
		out.append_array(["--content-url", content_url])
	return out


func describe() -> Dictionary:
	return {
		"content_id": content_id,
		"version": version,
		"display_name": display_name,
		"mount_root": mount_root,
		"start_map": String(start_map),
		"map_keys": Array(map_keys),
		"takes_subscriptions": takes_subscriptions,
		"subscribed": (workshop_summary.get("mounted", []) as Array).size(),
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("solo %s@%s (%s)" % [content_id, version, display_name])
	if start_map != &"":
		lines.append("  start map %s" % start_map)
	for key in map_keys:
		lines.append("  maps %s" % key)
	return lines
