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
## Armed by: making `TmcSiteDefault.resolve` ignore the environment or argv (the "wins" checks fail); making `follow_pointer` ignore `moved_to` (the hop checks fail); letting `valid_id` accept an upper-case or three-segment id (the refusals
## fail); dropping the `_strip_comment` call in `parse_descriptor` (every game.yml with a
## trailing comment on a read field disagrees with TmcYaml); and deleting a game from
## `client/solo.json` (the drift check names it).

const CHECKS := 47

## Every game repository, beside this project or in games/: the repositories of cfg/content/games.yml (shipped content-lists/games.yml).

## The stock per-game map packs a server ships with.
const STOCK_CONTENT := "res://cfg.example/server/content/overrides.yml"

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
	_test_site_default()
	_test_first_party()
	await _test_session()
	_test_skip_maps()

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


func _test_site_default() -> void:
	_section("a hand-started shell lists the site from client/auth.json")

	var auth := '{"backbone_url": "https://site.example/"}'
	var none := PackedStringArray()
	_check(TmcSiteDefault.resolve(auth, "", none, "") == "https://site.example", "the shipped site is the default, trailing slash trimmed")
	_check(TmcSiteDefault.resolve(auth, "https://env.example", none, "") == "", "an environment variable wins")
	_check(TmcSiteDefault.resolve(auth, "", PackedStringArray(["--browser-backbone-url=https://a.example"]), "") == "", "argv with = wins")
	_check(TmcSiteDefault.resolve(auth, "", PackedStringArray(["--browser-backbone-url", "https://a.example"]), "") == "", "argv with a separate value wins")
	_check(TmcSiteDefault.resolve(auth, "", none, "https://q.example") == "", "?backbone= wins on the web")
	_check(TmcSiteDefault.resolve("", "", none, "") == "" and TmcSiteDefault.resolve("{}", "", none, "") == "", "a missing or unreadable file names no site")
	_check(TmcSiteDefault.resolve('{"backbone_url": "javascript:x"}', "", none, "") == "", "a non-http value is refused")
	_check(TmcSiteDefault.resolve(FileAccess.get_file_as_string("res://client/auth.json"), "", none, "").begins_with("http"), "the shipped client/auth.json yields a site")

	_done()


func _test_first_party() -> void:
	_section("client/auth.json names the servers the shell signs in to, and only those")

	var out := []
	var tool := ProjectSettings.globalize_path("res://tools/shell-auth-json.sh")
	var code := OS.execute("bash", [tool, "https://site.example", "server:3550523, app:113"], out, true)
	var path := "user://solo_check_auth.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(str(out[0]) if not out.is_empty() else "")
	file.close()

	var client := DotAuthClient.new()
	client.config = DotAuthConfig.new()
	var applied := client.config.apply_json_file(path)
	_check(code == 0 and applied.ok, "tools/shell-auth-json.sh writes a file DotAuthConfig reads")
	_check(client.is_first_party("server:3550523") and client.is_first_party("app:113"), "a listed server or app is first-party")
	_check(not client.is_first_party("server:3550524") and not client.is_first_party(""), "an unlisted or unannounced server is not")
	_check(OS.execute("bash", [tool, "https://site.example", "server:x"], [], true) != 0, "an entry that is not server:<id> or app:<id> fails the write")

	var shipped := DotAuthClient.new()
	shipped.config = DotAuthConfig.new()
	shipped.config.apply_json_file("res://client/auth.json")
	_check(not shipped.is_first_party("server:999999999"), "the shipped file does not trust an arbitrary server")

	var site := TmcSiteDefault.first_party_from({"audiences": ["server:7", "app:3", "global", "server:0", 5]})
	_check(site.ok and site.value == PackedStringArray(["server:7", "app:3"]), "the site's play/first-party answer keeps only server and app audiences")
	_check(not TmcSiteDefault.first_party_from({}).ok and not TmcSiteDefault.first_party_from(null).ok \
		and not TmcSiteDefault.first_party_from({"audiences": "server:7"}).ok, "a malformed answer fails, so the shell keeps the shipped list")
	_check(TmcSiteDefault.first_party_from({"audiences": []}).ok, "an empty answer is an answer: the site trusts no server")

	client.free()
	shipped.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
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
	_section("client/solo.json carries every stock map list from cfg.example/server/content/overrides.yml")

	var stock := TmcYaml.parse_file(STOCK_CONTENT)
	if not _check(stock.ok, "cfg.example/server/content/overrides.yml parses", str(stock.error) if not stock.ok else ""):
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
	_check(drift.is_empty(), "solo.json and cfg.example/server/content/overrides.yml agree", "\n".join(drift))

	# And nothing in solo.json names a game this project does not publish.
	var known := _games()
	var strays := PackedStringArray()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TmcSolo.SOLO_CONFIG))
	for id: Variant in ((parsed as Dictionary).get("maps", {}) as Dictionary):
		if not known.has(str(id).get_slice("/", 1)):
			strays.append(str(id))
	_check(strays.is_empty(), "every game solo.json names is in games.yml", ", ".join(strays))

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


func _test_skip_maps() -> void:
	_section("the player's choice to skip a game's maps pack is kept, and defaults to fetching")

	var id := "gamemann/solo-check-probe"
	var before := FileAccess.get_file_as_bytes(TmcSolo.PREFS) if FileAccess.file_exists(TmcSolo.PREFS) else PackedByteArray()
	TmcSolo.set_skip_maps(id, false)
	_check(not TmcSolo.skip_maps(id), "with no choice made the maps pack is fetched")
	TmcSolo.set_skip_maps(id, true)
	_check(TmcSolo.skip_maps(id), "a skip is kept")
	_check(not TmcSolo.skip_maps("gamemann/other"), "and is per game")
	TmcSolo.set_skip_maps(id, false)
	_check(not TmcSolo.skip_maps(id), "turning it back on returns to the default")

	if before.is_empty():
		DirAccess.remove_absolute(TmcSolo.PREFS)
	_done()


# --- Helpers -----------------------------------------------------------------

func _games() -> PackedStringArray:
	var out := PackedStringArray()
	var listed := TmcContentLists.load_list("games", "res://cfg")
	if not listed.ok:
		return out
	for e: Dictionary in listed.value:
		var repo := String(e["id"])
		if e["kind"] == "repo" and _source(repo) != "" and FileAccess.file_exists(_source(repo).path_join("game.yml")):
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
