class_name TmcAddonGroups
extends RefCounted

## Which download groups (dot-cloud's `groups.json`, API 22) the shell asks [DotCloudAddonSet] for when it builds an overlay for a server.
##
## The server names, per addon entry, the groups its game needs (`groups` on an `addon_set` entry, from the game module's `addon_groups()`).
## dot-cloud takes one list for every pack of an overlay, so this is the union of what the wanted entries name.
## An entry without the field adds nothing: it is a pack the game does not narrow, and a pack without `groups.json` has only ungrouped files,
## which every selection takes. If no wanted entry names any, or one names `*` or something malformed, it is everything (`*`), the old behaviour.
## A game that narrows one grouped pack therefore has to name every grouped pack its server runs (today only arena-weapons has groups).
##
## Never narrower than the overlay already running: a player who goes from a server with every weapon to one with a few keeps them all,
## and does not restart again on the way back.

const ALL := "*"


## The groups to build [param wanted] (`plan_for`'s dir -> entry) with, from the [param server]'s `addon_set` and the running [param plan]'s groups.
## [param plan] is the plan whose overlay is mounted, or an empty Dictionary when none is.
static func wanted_groups(server: Array, wanted: Dictionary, plan: Dictionary) -> PackedStringArray:
	var needed := needed_groups(server, wanted)

	if plan.is_empty():
		return needed

	return union(needed, plan_groups(plan))


## What [param server] names for the dirs in [param wanted], unioned; `*` when that cannot be narrowed.
static func needed_groups(server: Array, wanted: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var named := false

	for raw: Variant in server:
		if not (raw is Dictionary):
			continue

		var entry := raw as Dictionary

		if not wanted.has(str(entry.get("dir", ""))) or not entry.has("groups"):
			continue

		var value: Variant = entry["groups"]

		if not (value is Array or value is PackedStringArray):
			return PackedStringArray([ALL])

		named = true

		for group: Variant in value:
			var name := str(group) if (group is String or group is StringName) else ""

			if name == "" or name == ALL:
				return PackedStringArray([ALL])

			if not out.has(name):
				out.append(name)

	if not named:
		return PackedStringArray([ALL])

	out.sort()
	return out


## The groups [param plan]'s overlay was built with. A plan from before groups (dot-cloud 0.1.45 and older) took everything.
static func plan_groups(plan: Dictionary) -> PackedStringArray:
	var value: Variant = plan.get("groups", null)

	if not (value is Array or value is PackedStringArray):
		return PackedStringArray([ALL])

	var out := PackedStringArray()

	for group: Variant in value:
		out.append(str(group))

	return out if not out.is_empty() else PackedStringArray([ALL])


## Every group in [param a] or [param b]; `*` if either is.
static func union(a: PackedStringArray, b: PackedStringArray) -> PackedStringArray:
	if a.has(ALL) or b.has(ALL):
		return PackedStringArray([ALL])

	var out := a.duplicate()

	for group in b:
		if not out.has(group):
			out.append(group)

	out.sort()
	return out


## Whether an overlay built with [param have] holds every group in [param needed].
static func covers(have: PackedStringArray, needed: PackedStringArray) -> bool:
	if have.has(ALL):
		return true

	if needed.has(ALL):
		return false

	for group in needed:
		if not have.has(group):
			return false

	return true
