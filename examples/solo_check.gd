extends Node

## Solo play's pieces that can be checked without a network: what a page may ask for, the shell's
## `game.yml` reader against the host's, the shell's map list against the stock server one, and the
## session a game reads its map packs from. godot --headless --path .

const CHECKS := 84

## Every game repository, beside this project or in games/: the repositories of cfg/content/games.yml (shipped content-lists/games.yml).

## The stock per-game map packs a server ships with.
const STOCK_CONTENT := "res://cfg.example/server/content/overrides.yml"

## Games whose maps are NOT fetched by the shell before a solo game starts, and why. Each
## one is a map list the shell deliberately does not copy, so the drift check skips it.
## Repos whose pack id was renamed while the directory kept its name (see setup.sh repo_url):
## solo.json is keyed by the pack id, overrides.yml by the game.
const RENAMED_PACK := {"mg-deathrun": "game-deathrun", "mg-prop-hunt": "game-prop-hunt", "game-playground": "game-playlot"}

const NOT_PREFETCHED := {
	# One pack per map, about 50 MB each: the game fetches the one it changes to itself
	# (`g2g: fetching a map this build does not have`), as a server does.
	"game-g2gfast": "one large pack per map, fetched by the game when it changes to it",
	"game-arena": "39 combat surf packs, lazy delivery like game-g2gfast: fetched when the game changes to a map",
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
	_test_sim_child_args()
	_test_requires_reader()
	_test_overlay_blocked()

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
	var both := TmcSolo.tried_summary(PackedStringArray(["https://cdn.example/content/a/b/latest.json: 404", "/content/a/b/latest.json: bad URL"]))
	_check(both.contains("cdn.example") and both.contains("/content/a/b"), "a failed pointer names every address it tried, not only the last")
	_check(TmcSolo.tried_summary(PackedStringArray()) == "no content address is configured", "no addresses says so")
	_check(not TmcSolo.valid_version("0.1/../..") and not TmcSolo.valid_version(".."), "a version that climbs is refused")

	var split := TmcSolo.split_key("gamemann/surf_mesa@1.2.2")
	_check(split["id"] == "gamemann/surf_mesa" and split["version"] == "1.2.2", "a key splits at its last '@'")

	_check(TmcSolo.valid_map("ph_apartment") and TmcSolo.valid_map("bhop_g2g_intro"), "a map id (?map=) is a slug")
	_check(not TmcSolo.valid_map("../x") and not TmcSolo.valid_map("a/b") and not TmcSolo.valid_map("Ph_x") and not TmcSolo.valid_map(""),
		"a path, an owner/repo, upper case or nothing is not a map id")
	_check(TmcSolo.per_map_key("gamemann/mg-prop-hunt-maps@1.0.3", "ph_apartment") == "gamemann/ph_apartment",
		"a start map's own pack is <bulk owner>/<map>, newest version")
	_check(TmcSolo.per_map_key("gamemann/x-maps", "") == "" and TmcSolo.per_map_key("gamemann/x-maps", "a/b") == "",
		"no start map or a bad one gives no per-map pack")
	_check(TmcSolo.map_groups(false, "wo_sweet_course") == PackedStringArray(["*"]) and TmcSolo.map_groups(false, "") == PackedStringArray(["*"]),
		"a native solo launch takes every group of a map pack")
	_check(TmcSolo.map_groups(true, "wo_sweet_course") == PackedStringArray(["wo_sweet_course"]),
		"a web solo launch takes the start map's group of a map pack")
	_check(TmcSolo.map_groups(true, "").is_empty() and TmcSolo.map_groups(true, "../x").is_empty(),
		"a web solo launch with no start map (or a bad one) takes only the ungrouped files")

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
		+ "dependencies: [a/b@1.0, 'c/d@2']\nserver_dependencies:\n  - e/f@3  # why\nsuggested:\n  - dm=a/b\ncvars:\n  x: \"1\"\n"
	)
	_check(inline["name"] == "A # not a comment", "a '#' inside quotes is kept and a trailing comment dropped")
	_check(inline["dependencies"] == PackedStringArray(["a/b@1.0", "c/d@2"]), "an inline list is read")
	_check(inline["server_dependencies"] == PackedStringArray(["e/f@3"]), "a block list is read, its comment dropped")
	_check(inline["suggested"] == PackedStringArray(["dm=a/b"]), "a suggested list is read")
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
		var have := TmcSolo.map_packs("gamemann/%s" % RENAMED_PACK.get(str(repo), str(repo)))
		if have != want:
			drift.append("%s: solo.json %s, cfg.example %s" % [repo, have, want])

	_check(compared >= 4, "the stock list names map packs to compare", "compared %d" % compared)
	_check(drift.is_empty(), "solo.json and cfg.example/server/content/overrides.yml agree", "\n".join(drift))

	# And nothing in solo.json names a game this project does not publish.
	var known := _games(false)
	var strays := PackedStringArray()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TmcSolo.SOLO_CONFIG))
	for id: Variant in ((parsed as Dictionary).get("maps", {}) as Dictionary):
		var name := str(id).get_slice("/", 1)
		var listed_name := false
		for k in known:
			listed_name = listed_name or _names(k).has(name)
		if not listed_name and not RENAMED_PACK.values().has(name):
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
	session.start_map = &"ph_apartment"
	_check(&"start_map" in host and host.get(&"start_map") == &"ph_apartment", "a game reads the start map duck-typed as start_map")

	_check(session.is_connected_to_server(), "dot-menu sees a link to leave")
	session.disconnect_from_server("Left")
	await get_tree().process_frame
	_check(left[0] == 1, "Leave reaches the shell's leave_fn")

	DotRegistry.unregister_instance(TmcSolo.MAPS_SERVICE, session)
	session.queue_free()
	DotPaths.remove_tree(root)
	_done()


func _test_sim_child_args() -> void:
	_section("a solo game's server process is told the packs the shell mounted")

	var session := TmcSoloSession.new()
	session.content_id = "gamemann/game-arena"
	session.version = "0.1.40"
	session.pack_keys = PackedStringArray(["gamemann/dot-weapons@1.2", "gamemann/dot-bots@3"])
	session.map_keys = PackedStringArray(["gamemann/fc-dm-maps@2.0"])
	session.cache_dir = "/tmp/solo cache"
	var args := session.sim_child_args()
	_check(TmcSolo.is_sim_child_for(args) and not TmcSolo.is_sim_child_for(PackedStringArray(["--solo", "a/b"])),
		"the args make a server process, and --solo alone does not", " ".join(args))
	var asked_id := args[args.find("--solo") + 1]
	var asked_version := args[args.find("--solo-version") + 1]
	_check(asked_id == session.content_id and asked_version == session.version, "the game and its version are passed")
	_check(TmcSolo.child_keys_in(args, TmcSolo.PACKS_FLAG) == session.pack_keys
		and TmcSolo.child_keys_in(args, TmcSolo.MAPS_FLAG) == session.map_keys,
		"the dependency and map pack keys come back as they went in", " ".join(args))
	_check(args[args.find("--cloud-cache-dir") + 1] == session.cache_dir and not args.has("--content-url"),
		"the cache folder is passed as one arg, and an unset content address is left out")
	session.pack_keys = PackedStringArray()
	session.map_keys = PackedStringArray()
	var bare := session.sim_child_args()
	_check(not bare.has(TmcSolo.PACKS_FLAG) and not bare.has(TmcSolo.MAPS_FLAG)
		and TmcSolo.child_keys_in(bare, TmcSolo.PACKS_FLAG).is_empty() and not bare.has("--solo-map"),
		"no packs, no pack flags, no start map")
	session.start_map = &"dm_box"
	var mapped := session.sim_child_args()
	_check(mapped.has("--solo-map") and mapped[mapped.find("--solo-map") + 1] == "dm_box",
		"the start map the player asked for goes to the server process", " ".join(mapped))
	session.workshop_summary = {"mounted": [{"content_id": "gamemann/some-mod"}]}
	_check(session.sim_child_args().is_empty(), "a start that mounted Workshop packs gets no server process (the child would lack them)")
	session.workshop_summary = {"mounted": []}
	_check(not session.sim_child_args().is_empty(), "a Workshop sync that mounted none leaves the server process on")
	session.free()
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



## The games list's game repos; [param checked_out] keeps only those with a source here,
## since a runner (a GPU box mirror) may lack one that the list still publishes.
func _games(checked_out := true) -> PackedStringArray:
	var out := PackedStringArray()
	var listed := TmcContentLists.load_list("games", "res://cfg")
	if not listed.ok:
		return out
	for e: Dictionary in listed.value:
		var repo := String(e["id"])
		if e["kind"] != "repo":
			continue
		if not checked_out or (_source(repo) != "" and FileAccess.file_exists(_source(repo).path_join("game.yml"))):
			out.append(repo)
	return out


## games/<repo>, then beside this project; under any name dot-bootstrap's projects.tsv gives the repo.
func _source(repo: String) -> String:
	var here := ProjectSettings.globalize_path("res://")
	for name in _names(repo):
		var dirs := [here.path_join("games").path_join(name), here.path_join("..").path_join(name).simplify_path()]
		var base := _checkout_parent()
		if base != "":
			dirs.append(base.path_join(name))
		for dir in dirs:
			if FileAccess.file_exists(str(dir).path_join("project.godot")):
				return str(dir)
	return ""


## Where the sibling repos live when this is a git worktree outside that folder (~/wt/...): the
## .git file of a worktree names the main checkout's .git/worktrees/<n>, whose parent holds the siblings.
func _checkout_parent() -> String:
	var gitfile := ProjectSettings.globalize_path("res://").path_join(".git")
	if not FileAccess.file_exists(gitfile):
		return ""
	var line := FileAccess.get_file_as_string(gitfile).strip_edges()
	var cut := line.find("/.git/worktrees/")
	if not line.begins_with("gitdir:") or cut < 0:
		return ""
	return line.substr(7, cut - 7).strip_edges().get_base_dir()


## [param repo] and every other name projects.tsv gives it (column 1 is current, column 3 the old names).
func _names(repo: String) -> PackedStringArray:
	var out := PackedStringArray([repo])
	var tsv := ProjectSettings.globalize_path("res://").path_join("../dot-bootstrap/projects.tsv").simplify_path()
	# A worktree under ~/wt has no sibling dot-bootstrap; tools/check.sh exports where it is.
	var boot := OS.get_environment("DOT_BOOTSTRAP")
	if not FileAccess.file_exists(tsv) and boot != "":
		tsv = boot.path_join("projects.tsv")
	if not FileAccess.file_exists(tsv) and _checkout_parent() != "":
		tsv = _checkout_parent().path_join("dot-bootstrap/projects.tsv")
	if not FileAccess.file_exists(tsv):
		return out
	for line in FileAccess.get_file_as_string(tsv).split("\n"):
		if line.begins_with("#") or line.strip_edges() == "":
			continue
		var cols := line.split("\t")
		var row := PackedStringArray([cols[0]])
		if cols.size() > 2:
			row.append_array(cols[2].strip_edges().split(","))
		if row.has(repo):
			for n in row:
				if not out.has(n):
					out.append(n)
	return out


## A solo game's addons are read from both requires files before its pack is fetched: a hard
## requirement only in requires.json (Prop Hunt's zee_weapons) refuses the pack while missing.
func _test_requires_reader() -> void:
	_section("the addons a solo game's requires files name")
	var shell := load("res://client/shell.gd") as GDScript
	_check(shell.SOLO_REQUIRE_FILES.has("requires.json") and shell.SOLO_REQUIRE_FILES.has("requires.floor.json"),
		"both requires.json and requires.floor.json are read")
	var got: Dictionary = shell.solo_addons_in('{"addons": {"zee_weapons": 6, "dot_ui": 13}}')
	_check(got.get("zee_weapons") == 6 and got.get("dot_ui") == 13, "a requires file's addons and levels are read", str(got))
	_check((shell.solo_addons_in("not json") as Dictionary).is_empty()
			and (shell.solo_addons_in('{"addons": []}') as Dictionary).is_empty(),
		"a file that is not a requires map names nothing")
	_check(not (shell.solo_addons_in('{"addons": {"../x": 1, "a/b": 1, "ok": 1}}') as Dictionary).has("../x")
			and not (shell.solo_addons_in('{"addons": {"a/b": 1}}') as Dictionary).has("a/b"),
		"a name that is a path is dropped")
	_done()


## `sessionStorage` for [method _test_overlay_blocked]: getItem, setItem and removeItem.
class FakeStorage:
	extends RefCounted
	var items := {}

	func getItem(key: String) -> Variant:
		return items.get(key)

	func setItem(key: String, value: String) -> void:
		items[key] = value

	func removeItem(key: String) -> void:
		items.erase(key)


## A solo game whose addons did not start must not be started without them (PLAYLOT's black screen of 2026-11-13: two restarts
## that worked used up the tab's count, and the third visit played on without zee_weapons). It is blocked behind Retry, and the
## count and the failed mark belong to one shell build.
func _test_overlay_blocked() -> void:
	_section("a solo game whose addons did not start is blocked behind Retry, per shell build")

	var plan_before := FileAccess.get_file_as_string(DotCloudAddonSet.PLAN)
	var shell: Node = (load("res://client/shell.gd") as GDScript).new()
	var storage := FakeStorage.new()
	shell.set("attempt_storage", storage)
	shell.set("shell_build", "20261113-0522")

	var wanted := {"zee_weapons": {"version": "0.1.62"}, "arena_weapons": {"version": "1.4.46"}}
	var target := "solo:gamemann/game-playlot"
	var attempt: String = shell.call("_attempt_key", target, wanted)
	_check(attempt == "solo:gamemann/game-playlot|arena_weapons@1.4.46,zee_weapons@0.1.62", "the attempt key names the game and its addon set", attempt)

	DotCloudAddonSet.forget()
	_check(not shell.call("_overlay_blocked", attempt, wanted), "a fresh tab builds the overlay")
	shell.call("_note_update_attempt", attempt)
	_check(not shell.call("_overlay_blocked", attempt, wanted), "one restart leaves another")
	shell.call("_note_update_attempt", attempt)
	_check(shell.call("_overlay_blocked", attempt, wanted), "after two restarts the game is blocked, not started without its addons")

	shell.set("_solo_retry", attempt)
	shell.call("_forget_solo_retry")
	_check(not shell.call("_overlay_blocked", attempt, wanted) and str(shell.get("_solo_retry")) == "", "Retry clears the count and builds the overlay again")

	shell.call("_note_update_attempt", attempt)
	shell.call("_note_update_attempt", attempt)
	shell.set("shell_build", "20261114-0900")
	_check(int(shell.call("_update_attempts", attempt)) == 0, "a new shell build starts the count again")

	storage.items[shell.get("UPDATE_ATTEMPTS_KEY")] = JSON.stringify({attempt: 2})
	_check(int(shell.call("_update_attempts", attempt)) == 0, "the flat count an older shell kept is not read as this build's")

	shell.call("_note_update_attempt", attempt)
	shell.call("_note_update_attempt", "solo:gamemann/other|x@1")
	shell.call("_clear_update_attempts", target)
	_check(int(shell.call("_update_attempts", attempt)) == 0 and int(shell.call("_update_attempts", "solo:gamemann/other|x@1")) == 1,
		"once a game's addons are running its counts go, and only its own")

	# A failed mark: the overlay's plan written for this build's addons.lock, then marked failed at boot.
	DotCloudAddonSet.write_plan({"state": DotCloudAddonSet.STATE_FAILED, "build": DotCloudAddonSet.build_fingerprint(), "addons": wanted})
	_check(DotCloudAddonSet.failed_before(wanted), "the seeded plan is a failed mark for this set")
	_check(not shell.call("_overlay_blocked", attempt, wanted), "a failed mark no shell build stamped gets one more try")
	shell.call("_stamp_plan")
	_check(str(DotCloudAddonSet.read_plan().get("shell", "")) == "20261114-0900" and DotCloudAddonSet.failed_before(wanted),
		"the plan is stamped with the shell build that built it, the rest kept")
	_check(shell.call("_overlay_blocked", attempt, wanted), "a failed mark from this shell build blocks")
	shell.set("shell_build", "20261115-0100")
	_check(not shell.call("_overlay_blocked", attempt, wanted), "a failed mark from another shell build does not")
	shell.set("shell_build", "20261114-0900")
	shell.set("_solo_retry", attempt)
	shell.call("_forget_solo_retry")
	_check(DotCloudAddonSet.read_plan().is_empty() and not shell.call("_overlay_blocked", attempt, wanted), "Retry forgets the failed mark")

	shell.free()
	if plan_before != "":
		DotPaths.write_text(DotCloudAddonSet.PLAN, plan_before)
	else:
		DotCloudAddonSet.forget()
	_done()


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
