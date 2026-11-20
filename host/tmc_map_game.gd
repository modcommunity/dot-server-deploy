class_name TmcMapGame
extends RefCounted

## Finds the parts of the loaded game that handle maps. Duck-typed, like everything that crosses into a game: `has_method` and `call` rather than `is DotMapSession`,
## because this host has no business requiring GameSpice Map (GameSpice Vote's map source uses the same contract). The game is a scene loaded from a pack, not a type this host may name.


## The loaded game's map session, or null: the node under [param root] that answers `change_to` and `change_to_map`.
static func session_in(root: Variant) -> Object:
	return first_answering(root, ["change_to", "change_to_map"])


## The node under [param root] that answers `start_on_map(id) -> DotResult`: a game whose map change is its own rather than a DotMapSession's.
static func starter_in(root: Variant) -> Object:
	return first_answering(root, ["start_on_map"])


## The running game, if it fetches and registers its own map content. `ensure_map_content` is the half `change_to` cannot do for itself, see `TmcHost._ensure_map_content`.
static func fetcher_in(root: Variant) -> Object:
	return first_answering(root, ["ensure_map_content"])


## The roots a server keeps map directors under: its games, then its modules.
static func roots_of(server: Object) -> Array:
	var roots: Array = []

	if server != null and server.get("games") != null:
		roots.append(server.games)

	if server != null and server.get("modules") != null:
		roots.append(server.modules)

	return roots


## The first node below [param root] (or, given an Array, below each in turn), depth first, that has every method in [param methods]; null when none does.
static func first_answering(root: Variant, methods: Array) -> Object:
	if root == null:
		return null

	# A list of roots is searched in order: the games first, then the modules, because a game whose map director is held by a module (Fatal Contact's) is not under the games node.
	if root is Array:
		for each: Variant in root:
			var in_each := first_answering(each, methods)

			if in_each != null:
				return in_each

		return null

	for child in root.get_children():
		var answers := true

		for method: String in methods:
			answers = answers and child.has_method(method)

		if answers:
			return child

		var found := first_answering(child, methods)

		if found != null:
			return found

	return null
