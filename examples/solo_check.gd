extends Node

## Solo play's pieces that can be checked without a network: what a page may ask for, the
## shell's `game.yml` reader against the host's, the shell's map list against the stock
## server one, and the session a game reads its map packs from.
##
##     godot --headless --path . res://examples/solo_check.tscn
##
## The boot itself (fetch, verify, mount, start offline) is proven against real packs by
## running the shell: `godot --headless --path . res://client/boot.tscn -- --solo
## gamemann/game-arena --content-url <origin>/content` (docs/web-client.md#solo-play).
##
## Armed by: making `follow_pointer` ignore `moved_to` (the hop checks fail); letting `valid_id` accept an upper-case or three-segment id (the refusals
## fail); dropping the `_strip_comment` call in `parse_descriptor` (every game.yml with a
## trailing comment on a read field disagrees with TmcYaml); and deleting a game from
## `client/solo.json` (the drift check names it).

const CHECKS := 27

## Every game repository, beside this project or in games/: `games.list`'s first column.
const GAMES_LIST := "res://games.list"

## The stock per-game map packs a server ships with.
const STOCK_CONTENT := "res://cfg.example/content.yml"

## Games whose maps are NOT fetched by the shell before a solo game starts, and why. Each
## one is a map list the shell deliberately does not copy, so the drift check skips it.
const NOT_PREFETCHED := {
	# One pack per map, about 50 MB each: the game fetches the one it changes to itself
	# (`g2g: fetching a map this build does not have`), as a server does.
	"game-g2gfast": "one large pack per map, fetched by the game when it changes to it",
}

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: PackedStringArray = []


func _ready() -> void:
	_test_ids()
	_test_descriptor_reader()
	_test_map_list()
	await _test_session()

	print("")
	print("%d sections, %d completed" % [_entered, _completed])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)

	if _passed + _failed != CHECKS or _completed != _entered:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _test_ids() -> void:
	_section("a page may name a pack and nothing else")

	_check(TmcSolo.valid_id("gamemann/game-arena"), "an owner/repo id is accepted")
	_check(TmcSolo.valid_id("modcommunity/zee_dot-weapons2"), "digits, '-' and '_' are accepted")
	_check(not TmcSolo.valid_id("Gamemann/game-arena"), "an upper-case id is refused (it would not mount)")
	_check(not TmcSolo.valid_id("gamemann/game-arena/0.1.0"), "three segments are refused")
	_check(not TmcSolo.valid_id("../x"), "a path is refused")
	_check(not TmcSolo.valid_id("gamemann"), "an id with no repo is refused")
	_check(TmcSolo.valid_version("") and TmcSolo.valid_version("0.1.12"), "an empty or dotted version is accepted")
	var hop: DotResult = TmcSolo.follow_pointer("a/old", {"version": "1.0.0", "moved_to": "a/new"}, 0)
	_check(hop.ok and hop.value["moved_to"] == "a/new" and hop.value["version"] == "",
		"a latest.json with moved_to hands back the new id, not the stale version")
	_check(not TmcSolo.follow_pointer("a/new", {"moved_to": "a/x"}, 1).ok
			and not TmcSolo.follow_pointer("a/old", {"moved_to": "a/old"}, 0).ok,
		"a second hop and a loop are refused")
	_check(not TmcSolo.valid_version("0.1/../..") and not TmcSolo.valid_version(".."), "a version that climbs is refused")

	var split := TmcSolo.split_key("gamemann/surf_mesa@1.2.2")
	_check(split["id"] == "gamemann/surf_mesa" and split["version"] == "1.2.2", "a key splits at its last '@'")

	_done()


func _test_descriptor_reader() -> void:
	_section("the shell's game.yml reader agrees with the host's on every game")

	var read := 0
	var disagreements := PackedStringArray()

	for repo in _games():
		var path := _source(repo).path_join("game.yml")
		if not FileAccess.file_exists(path):
			continue

		var text := FileAccess.get_file_as_string(path)
		var mine := TmcSolo.parse_descriptor(text)
		var host := TmcYaml.parse(text, path)

		if not host.ok:
			disagreements.append("%s: TmcYaml refused it: %s" % [repo, str(host.error)])
			continue

		read += 1
		var theirs: Dictionary = host.value

		for key in ["name", "content_id", "version", "client_scene"]:
			if str(mine[key]) != str(theirs.get(key, "")):
				disagreements.append("%s %s: shell '%s', host '%s'" % [repo, key, mine[key], theirs.get(key, "")])

		for key in ["dependencies", "server_dependencies"]:
			var want := PackedStringArray()
			for v: Variant in (theirs.get(key, []) if theirs.get(key) is Array else []):
				want.append(str(v))
			if mine[key] != want:
				disagreements.append("%s %s: shell %s, host %s" % [repo, key, mine[key], want])

	_check(read >= 13, "every game's game.yml is here to read", "read %d" % read)
	_check(disagreements.is_empty(), "the two readers agree on every field solo uses", "\n".join(disagreements))

	var inline := TmcSolo.parse_descriptor(
		"name: \"A # not a comment\"  # a comment\nclient_scene: game/x.tscn\n"
		+ "dependencies: [a/b@1.0, 'c/d@2']\nserver_dependencies:\n  - e/f@3  # why\ncvars:\n  x: \"1\"\n"
	)
	_check(inline["name"] == "A # not a comment", "a '#' inside quotes is kept and a trailing comment dropped")
	_check(inline["dependencies"] == PackedStringArray(["a/b@1.0", "c/d@2"]), "an inline list is read")
	_check(inline["server_dependencies"] == PackedStringArray(["e/f@3"]), "a block list is read, its comment dropped")
	_check(inline["client_scene"] == "game/x.tscn", "a nested block after the lists is skipped")

	_done()


func _test_map_list() -> void:
	_section("client/solo.json carries every stock map list from cfg.example/content.yml")

	var stock := TmcYaml.parse_file(STOCK_CONTENT)
	if not _check(stock.ok, "cfg.example/content.yml parses", str(stock.error) if not stock.ok else ""):
		_done()
		return

	var games: Variant = (stock.value as Dictionary).get("games", {})
	var drift := PackedStringArray()
	var compared := 0

	for repo: Variant in (games as Dictionary if games is Dictionary else {}):
		if NOT_PREFETCHED.has(str(repo)):
			continue
		var entry: Variant = (games as Dictionary)[repo]
		var maps: Variant = (entry as Dictionary).get("maps", {}) if entry is Dictionary else {}
		var add: Variant = (maps as Dictionary).get("add", []) if maps is Dictionary else []
		var want := PackedStringArray()
		for v: Variant in (add if add is Array else []):
			want.append(str(v))
		if want.is_empty():
			continue
		compared += 1
		var have := TmcSolo.map_packs("gamemann/%s" % repo)
		if have != want:
			drift.append("%s: solo.json %s, cfg.example %s" % [repo, have, want])

	_check(compared >= 4, "the stock list names map packs to compare", "compared %d" % compared)
	_check(drift.is_empty(), "solo.json and cfg.example/content.yml agree", "\n".join(drift))

	# And nothing in solo.json names a game this project does not publish.
	var known := _games()
	var strays := PackedStringArray()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TmcSolo.SOLO_CONFIG))
	for id: Variant in ((parsed as Dictionary).get("maps", {}) as Dictionary):
		if not known.has(str(id).get_slice("/", 1)):
			strays.append(str(id))
	_check(strays.is_empty(), "every game solo.json names is in games.list", ", ".join(strays))

	_done()


func _test_session() -> void:
	_section("the session hands a game its map packs and the menu a way back")

	var root := "user://solo_check"
	DotPaths.remove_tree(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("a/maps"))
	DirAccess.make_dir_recursive_absolute(root.path_join("b/courses"))

	var session := TmcSoloSession.new()
	session.map_roots = PackedStringArray([root.path_join("a"), root.path_join("b")])
	var left := [0]
	session.leave_fn = func() -> void: left[0] += 1
	add_child(session)
	DotRegistry.register(TmcSolo.MAPS_SERVICE, session)

	# The way a delivered game asks: by name, duck-typed.
	var host: Object = DotRegistry.get_service(&"dot_solo")
	_check(host == session, "the session is published under dot_solo, the name every game looks up")
	_check(host.call(&"map_dirs", "maps") == PackedStringArray([root.path_join("a/maps")]), "map_dirs names the packs that have the directory")
	_check(host.call(&"map_dirs", "routes") == PackedStringArray(), "and none when no pack has it")
	_check(DotRegistry.get_service(&"dot_client_link") == null, "no client link is published, so the game plays offline")

	_check(session.is_connected_to_server(), "dot-menu sees a link to leave")
	session.disconnect_from_server("Left")
	await get_tree().process_frame
	_check(left[0] == 1, "Leave reaches the shell's leave_fn")

	DotRegistry.unregister_instance(TmcSolo.MAPS_SERVICE, session)
	session.queue_free()
	DotPaths.remove_tree(root)
	_done()


# --- Helpers -----------------------------------------------------------------

func _games() -> PackedStringArray:
	var out := PackedStringArray()
	for line in FileAccess.get_file_as_string(GAMES_LIST).split("\n"):
		var row := line.strip_edges()
		if row == "" or row.begins_with("#"):
			continue
		var repo := row.split(" ", false)[0]
		if _source(repo) != "" and FileAccess.file_exists(_source(repo).path_join("game.yml")):
			out.append(repo)
	return out


## games/<repo>, then beside this project.
func _source(repo: String) -> String:
	var here := ProjectSettings.globalize_path("res://")
	for dir in [here.path_join("games").path_join(repo), here.path_join("..").path_join(repo).simplify_path()]:
		if FileAccess.file_exists(str(dir).path_join("project.godot")):
			return str(dir)
	return ""


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("== %s" % title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [what, ("\n        " + detail.replace("\n", "\n        ")) if detail != "" else ""])
		_failures.append(what)
	return ok
