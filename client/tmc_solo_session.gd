class_name TmcSoloSession
extends Node

## The solo game the shell is running, as a game and its menu find it.
##
## Registered in [DotRegistry] under [constant TmcSolo.MAPS_SERVICE] while a solo game is on
## screen, and NOT under the client link's name: every game decides it is offline by finding
## no link there, so a stand-in under that name would make a solo game wait for a server.
##
## Two things live here.
##
## [b]The map packs the shell mounted for this game[/b] ([member map_roots]): a game's
## offline catalogue reads them the way its server module reads the packs its server names
## (dot-game's `DotGameContent.map_dirs`), duck-typed, because nothing in a pack may name a
## shell class.
##
## [b]The way back to the shell's menu.[/b] dot-menu's stock Leave disconnects whatever
## [member DotMenu.leave_link] is, when it reports itself connected, and hides itself in a
## browser offline (a tab cannot be closed by its page, and a quit there is a frozen canvas).
## The shell points every menu in a solo game at this node, so Leave reads "Back to menu"
## and takes the player there instead of doing nothing.

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

## Whether the game's manifest has `provides.accepts`. A game without it takes no
## subscriptions, the sync is not run for it, and its page says so.
var takes_subscriptions: bool = false

## The Workshop's summary for this start (`{}` when it did not run), for the Subscriptions
## page: what mounted, what was skipped and why, whether the player was a guest.
var workshop_summary: Dictionary = {}

## What leaving does. Set by the shell.
var leave_fn: Callable = Callable()


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


func describe() -> Dictionary:
	return {
		"content_id": content_id,
		"version": version,
		"display_name": display_name,
		"mount_root": mount_root,
		"map_keys": Array(map_keys),
		"takes_subscriptions": takes_subscriptions,
		"subscribed": (workshop_summary.get("mounted", []) as Array).size(),
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("solo %s@%s (%s)" % [content_id, version, display_name])
	for key in map_keys:
		lines.append("  maps %s" % key)
	return lines
