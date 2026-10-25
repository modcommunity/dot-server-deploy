class_name TmcGameRotation
extends RefCounted

## Which GAMES this server plays: `cfg/content/games.yml`.
##
## The same format as `cfg/maps.yml` (named rotations, `random` or `cycle`, a cooldown, a plain
## list as shorthand for `main`, wildcards), and the same code: parsing, layering and the
## matcher are dot-core's [DotRotationSpec], not a second copy. The only difference is what a
## candidate is: an installed game, named by its content id (`owner/name`, matched as
## content.yml matches games) or by its game id when it has none.
##
## A game outside the active rotation stays installed and an admin can still change to it
## (`changelevel`); it is left out of the game ballot, `!game_nominate`, the next game a
## `!game_rtv` or the end of a game picks, and the content/-order fallback. `vote_exclude:` in
## vote.yml is applied as well, on top.
##
## [codeblock]
## rotation: main              # sv_game_rotation <name> switches live
## mode: random                # random (cooldown) | cycle (written order, wraps)
## cooldown: 2
## games: [gamemann/*]         # a plain list is the main rotation
## rotations:
##   party: {mode: cycle, games: [mg-wipeout, mg-deathrun]}
## [/codeblock]

const CHANNEL := "tmc.games_rotation"
## Beside the download list of the same name: this reads `games:`, `rotations:` and the rest, that reads `entries:`.
const FILE := "content/games.yml"
## Before the cfg/ move; read through DotCfgLegacy until its cutoff.
const LEGACY_FILE := "games.yml"

var spec: Dictionary = {}
var requested: String = ""
var warnings: PackedStringArray = PackedStringArray()
var source_path: String = ""
var _warned: Dictionary = {}


## A missing file is not an error: no file means every game plays. An unreadable one is.
static func load_file(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.success(from_tree({}))
	var parsed := DotYaml.parse_file(path)
	if not parsed.ok:
		return parsed.wrap("reading %s" % path)
	var rotation := from_tree(parsed.value as Dictionary)
	rotation.source_path = path
	return DotResult.success(rotation)


## No games.yml rotation, but the operator's cfg/content/games.yml gives an order: those games, in that order,
## as the `main` cycle. See [method TmcContentLists.game_order].
static func from_order(order: PackedStringArray) -> TmcGameRotation:
	return from_tree({"rotation": "main", "mode": "cycle", "games": Array(order)})


static func from_tree(tree: Dictionary) -> TmcGameRotation:
	var rotation := TmcGameRotation.new()
	rotation.spec = DotRotationSpec.normalize(tree, "games", rotation.warnings, FILE)
	for w in rotation.warnings:
		DotLog.warn(CHANNEL, w)
	return rotation


## The merged `commands:` block (`prefix`, `names`): what the vote commands are called. See
## [DotRotationSpec]; the commands classes take it through their `spec_fn`.
func commands() -> Dictionary:
	return spec.get("commands", {"names": {}})


func has_rotations() -> bool:
	return not (spec.get("rotations", {}) as Dictionary).is_empty()


func rotation_names() -> PackedStringArray:
	var out := PackedStringArray()
	for n: Variant in (spec.get("rotations", {}) as Dictionary):
		out.append(str(n))
	return out


func active_name() -> String:
	return DotRotationSpec.active_name(spec, requested)


func switch(name: String) -> DotResult:
	if not (spec.get("rotations", {}) as Dictionary).has(name):
		return DotResult.fail(DotError.CODE_INVALID, "No game rotation called '%s'." % name,
			"rotations: %s" % ", ".join(rotation_names()))
	requested = name
	return DotResult.success(name)


func is_cycle() -> bool:
	return has_rotations() and DotRotationSpec.mode_of(spec, active_name()) == "cycle"


func cooldown(fallback: int) -> int:
	return DotRotationSpec.cooldown_of(spec, active_name(), fallback) if has_rotations() else fallback


## The content key a descriptor is matched by: its content id, else its game id.
static func key_of(descriptor: DotGameDescriptor) -> String:
	return descriptor.content_id if descriptor.content_id != "" else descriptor.game_id


## The content keys the active rotation plays, in written order. Empty when there is no file,
## nothing matched or the rotation is unknown: the caller then plays every installed game.
func plays(games: Array) -> PackedStringArray:
	var use := active_name()
	var rots: Dictionary = spec.get("rotations", {})
	if use == "" or not rots.has(use):
		return PackedStringArray()
	var candidates: Array = []
	var seen := {}
	for d: DotGameDescriptor in games:
		var key := key_of(d)
		if seen.has(key):
			continue
		seen[key] = true
		candidates.append({"id": key.get_slice("/", key.get_slice_count("/") - 1), "ref": key if key.contains("/") else ""})
	var unmatched := PackedStringArray()
	var names := DotRotationSpec.expand((rots[use] as Dictionary)["entries"], candidates, {}, unmatched)
	for entry in unmatched:
		var k := "%s|%s" % [use, entry]
		if not _warned.has(k):
			_warned[k] = true
			DotLog.warn(CHANNEL, "a game rotation entry matches no installed game", {"rotation": use, "entry": entry})
	var found: Array[String] = []
	for d: DotGameDescriptor in games:
		var key := key_of(d)
		if names.has(key.get_slice("/", key.get_slice_count("/") - 1)) and not found.has(key):
			found.append(key)
	# Written order, not install order: the names come back in the file's order.
	found.sort_custom(func(a: String, b: String) -> bool:
		return names.find(a.get_slice("/", a.get_slice_count("/") - 1)) < names.find(b.get_slice("/", b.get_slice_count("/") - 1)))
	return PackedStringArray(found)


## The game ids to keep off the ballot because the active rotation does not play them, and
## (out) the game ids of the rotation in its written order, one per content key's descriptors.
## An empty result for the rotation falls back to every game, with one WARN.
func resolve(games: Array) -> Dictionary:
	var keys := plays(games)
	var excluded: Array[StringName] = []
	var order: Array[StringName] = []
	if has_rotations() and keys.is_empty():
		var k := "empty|%s" % active_name()
		if not _warned.has(k):
			_warned[k] = true
			DotLog.warn(CHANNEL, "the game rotation is empty; every installed game plays", {"rotation": active_name()})
		return {"excluded": excluded, "order": order, "fell_back": true}
	if not has_rotations():
		return {"excluded": excluded, "order": order, "fell_back": false}
	for key in keys:
		for d: DotGameDescriptor in games:
			if key_of(d) == key:
				order.append(StringName(d.game_id))
	for d: DotGameDescriptor in games:
		if not keys.has(key_of(d)):
			excluded.append(StringName(d.game_id))
	return {"excluded": excluded, "order": order, "fell_back": false}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	for n in rotation_names():
		var entries: PackedStringArray = (spec["rotations"] as Dictionary)[n]["entries"]
		lines.append("%s %s (%s, cooldown %d): %s" % ["*" if n == active_name() else " ", n,
			DotRotationSpec.mode_of(spec, n), DotRotationSpec.cooldown_of(spec, n, 0), ", ".join(entries)])
	return lines
