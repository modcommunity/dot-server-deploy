class_name SelftestContentLists
extends RefCounted

## Content lists, the former game id and the deployed map clocks. Run by `selftest.gd`, which keeps the counters: every check goes through its `_check`.

const CFG := "res://examples/fixtures"

var t: Node


func _init(p_test: Node) -> void:
	t = p_test


func _section(title: String) -> void:
	t._section(title)


func _done() -> void:
	t._done()


func _check(condition: bool, what: String, detail: String = "") -> bool:
	return t._check(condition, what, detail)


func _put(path: String, text: String) -> void:
	t._put(path, text)


func _test_content_lists() -> void:
	_section("content lists: shipped default, operator replace or merge, bad entry, pin")
	var root := "user://selftest_content_lists"
	DotPaths.remove_tree(root)
	var shipped := TmcContentLists.load_list("addons", root)
	_check(shipped.ok and (shipped.value as Array).size() > 40, "the shipped addons list loads")
	_check(TmcContentLists.pin_for(shipped.value, "dot-core") != "", "and carries the pins of addons.lock")
	var games := TmcContentLists.load_list("games", root)
	_check(games.ok and (games.value as Array).size() > 10 and games.value[0]["content"] != "", "the shipped games list loads with its content directories")
	_put(root + "/content/addons.yml", "entries:\n  - dot-core@v9\n  - pack: gamemann/surf_mesa@1.2.0\n")
	var own := TmcContentLists.load_list("addons", root)
	_check(own.ok and (own.value as Array).size() == 2, "the operator's file replaces the default")
	_check(TmcContentLists.pin_for(own.value, "dot-core") == "v9" and TmcContentLists.pin_for(own.value, "gamemann/surf_mesa") == "1.2.0", "pins are respected, in both spellings")
	_check(own.value[1]["kind"] == "pack", "a pack id is told from a repository")
	_put(root + "/content/addons.yml", "merge: true\nremove: [dot-voice]\nentries:\n  - repo: dot-extra\n  - repo: dot-core\n    pin: v9\n")
	var merged := TmcContentLists.load_list("addons", root)
	var ids: Array = (merged.value as Array).map(func(e: Dictionary) -> String: return e["id"])
	_check(merged.ok and ids.has("dot-extra") and not ids.has("dot-voice") and ids.count("dot-core") == 1, "merge: true adds, removes, and replaces by id")
	_check(TmcContentLists.pin_for(merged.value, "dot-core") == "v9", "a merged entry's pin wins")
	_put(root + "/server/content/addons.yml", "entries:\n  - dot-only\n")
	var srv := TmcContentLists.load_list("addons", root)
	_check(srv.ok and (srv.value as Array).size() == 1, "the server tier overrides the operator's file")
	_put(root + "/server/content/addons.yml", "entries:\n  - repo: a\n    pack: b/c\n")
	var bad := TmcContentLists.load_list("addons", root)
	_check(not bad.ok and bad.error.code == DotError.CODE_INVALID and bad.error.message.contains("entry 1"), "a bad entry fails with CODE_INVALID naming it")
	_put(root + "/server/content/addons.yml", "entries:\n  - dot-x@bad pin!\n")
	_check(TmcContentLists.load_list("addons", root).error.code == DotError.CODE_INVALID, "a pin with odd characters is refused")
	_put(root + "/server/content/addons.yml", "entries: [\n")
	_check(not TmcContentLists.load_list("addons", root).ok, "a file that is not yml fails")
	_check(TmcContentLists.load_list("nope", root).error.code == DotError.CODE_INVALID, "an unknown list is refused")
	_put(root + "/server/content/addons.yml", "entries:\n  - repo: a\n    maps: [x]\n")
	_check(not TmcContentLists.load_list("addons", root).ok, "maps: in addons.yml is refused")
	DotPaths.remove_tree(root)
	_put(root + "/content/games.yml", "entries:\n  - repo: g1\n    content: one\n    maps: [b, a]\n    rotation: random\n  - repo: g2\n    content: two\n  - repo: g3\n")
	var gl := TmcContentLists.load_list("games", root)
	_check(gl.ok and gl.value[0]["maps"] == PackedStringArray(["b", "a"]) and gl.value[0]["rotation"] == "random", "games.yml entries carry maps: and rotation:")
	var order := TmcContentLists.game_order(gl.value, PackedStringArray(["g3", "zz", "two", "one"]))
	_check(order.ok and order.value == PackedStringArray(["one", "two", "g3", "zz"]), "game_order follows games.yml, then installed games it does not name sorted")
	_check(not TmcContentLists.game_order(gl.value, PackedStringArray(["one"]), PackedStringArray(["nope"])).ok, "game_order names an unknown game")
	var mr := TmcContentLists.map_rotation(gl.value, "one", PackedStringArray(["a", "b", "c"]))
	_check(mr.ok and mr.value["maps"] == PackedStringArray(["b", "a"]) and mr.value["rotation"] == "random", "map_rotation: maps: is the order")
	mr = TmcContentLists.map_rotation(gl.value, "two", PackedStringArray(["z", "y"]))
	_check(mr.ok and mr.value["maps"] == PackedStringArray(["y", "z"]) and mr.value["rotation"] == "sequential", "map_rotation: no maps: is installed sorted, sequential")
	var bm := TmcContentLists.map_rotation(gl.value, "one", PackedStringArray(["a"]))
	_check(not bm.ok and bm.error.message.contains("'b'"), "map_rotation names an uninstalled map")
	_check(not TmcContentLists.map_rotation(gl.value, "nope", PackedStringArray()).ok, "map_rotation refuses an unknown game")
	_put(root + "/content/games.yml", "entries:\n  - repo: g1\n    content: one\n    maps:\n      - a\n      - id: b\n        time_limit: 600\n  - repo: g2\n")
	var tl := TmcContentLists.load_list("games", root)
	var tr := TmcContentLists.map_rotation(tl.value, "one", PackedStringArray(["a", "b"])) if tl.ok else tl
	_check(tr.ok and tr.value["maps"] == PackedStringArray(["a", "b"]) and tr.value["time_limits"] == {"b": 600.0}, "a maps: item may carry its own time_limit")
	_check(TmcContentLists.map_rotation(tl.value, "g2", PackedStringArray(["x"])).value["time_limits"].is_empty(), "no time_limit means none set")
	_put(root + "/content/games.yml", "entries:\n  - repo: g1\n    maps:\n      - id: a\n        time_limit: -5\n")
	_check(not TmcContentLists.load_list("games", root).ok, "a non-positive time_limit is refused")
	_put(root + "/content/games.yml", "entries:\n  - repo: g1\n    rotation: fast\n")
	_check(not TmcContentLists.load_list("games", root).ok, "an unknown rotation mode is refused")
	var cyc := TmcGameRotation.from_order(PackedStringArray(["bee", "ay"]))
	_check(cyc.is_cycle() and cyc.rotation_names() == PackedStringArray(["main"]), "the zero-config game order is a cycle")
	DotPaths.remove_tree(root)
	_done()


## playground was renamed playlot. A deployment's server.yml, games list, cfg/game.yml section
## and vote_exclude written for the old id must still reach the game.
func _test_former_game_id() -> void:
	_section("a renamed game answers to its former id")

	# A live overrides.yml named a collection without /* and lost its start map to a 404.
	_check(TmcGameRef.qualify_map("gamemann/fc-dm-maps", "")["id"] == "gamemann/fc-dm-maps/*"
			and TmcGameRef.qualify_map("gamemann/arena-surf-dm-maps", "")["id"] == "gamemann/fc-surf-dm-maps/*",
		"a known collection named without /* is read as the whole collection, not a pack that 404s")
	_check(not bool(TmcGameRef.qualify_map("gamemann/fc-dm-maps@1.0.0", "")["ok"]),
		"a pin on a bare collection is refused like a pin on its wildcard")
	_check(TmcGameRef.qualify_map("gamemann/cp-orange-x3", "")["id"] == "gamemann/cp-orange-x3",
		"an ordinary owner/map is still one pack")

	var all := TmcContent.scan("res://content")

	if not _check(all.ok, "the shipped content scans", str(all.error)):
		_check(false, "(skipped)"); _check(false, "(skipped)"); _check(false, "(skipped)")
		_check(false, "(skipped)"); _check(false, "(skipped)"); _check(false, "(skipped)")
		_check(false, "(skipped)"); _check(false, "(skipped)")
		_check(false, "(skipped)"); _check(false, "(skipped)")
		_done()
		return

	var content := all.value as TmcContent
	var found := content.find("playground")
	_check(found != null and found.game_id == "playlot", "find(\"playground\") is playlot",
		found.game_id if found != null else "null")
	_check(content.find("playlot") == found, "and find(\"playlot\") is the same game")

	var narrowed := TmcContent.scan("res://content", PackedStringArray(["playground"]))
	var kept := narrowed.value as TmcContent if narrowed.ok else null
	_check(kept != null and kept.ids() == PackedStringArray(["playlot"]) and kept.missing.is_empty(),
		"a games list naming playground keeps playlot and reports nothing missing",
		str(kept.ids()) + " missing " + str(kept.missing) if kept != null else str(narrowed.error))

	var section := TmcGameConfig.section_in({"playground": {"marker": 1}}, found) if found != null else {}
	_check(section.get("marker", 0) == 1, "a cfg section keyed playground applies to playlot", str(section))
	_check(TmcGameConfig.section_in({"playground": {"marker": 1}, "playlot": {"marker": 2}}, found).get("marker", 0) == 2
		if found != null else false, "and a section under the new id wins over the old")
	_check(TmcVote._current_id(content.games, "playground") == "playlot",
		"vote_exclude: [playground] keeps playlot off the ballot")

	# arena was renamed fatalcontact the same way, and it is the default game besides.
	var dm := content.find("arena")
	_check(dm != null and dm.game_id == "fatalcontact" and content.default_game == "fatalcontact",
		"find(\"arena\") is fatalcontact, still the default game",
		(dm.game_id if dm != null else "null") + " default " + content.default_game)
	var dm_only := TmcContent.scan("res://content", PackedStringArray(["arena"]))
	var dm_kept := dm_only.value as TmcContent if dm_only.ok else null
	_check(dm_kept != null and dm_kept.ids() == PackedStringArray(["fatalcontact"]) and dm_kept.missing.is_empty(),
		"a games list naming arena keeps fatalcontact and reports nothing missing",
		str(dm_kept.ids()) + " missing " + str(dm_kept.missing) if dm_kept != null else str(dm_only.error))

	# g2gfast was renamed airdrift; its pack id stays tmc/g2gfast until a re-publish.
	var timer := content.find("g2gfast")
	_check(timer != null and timer.game_id == "airdrift", "find(\"g2gfast\") is airdrift",
		timer.game_id if timer != null else "null")
	var timer_only := TmcContent.scan("res://content", PackedStringArray(["g2gfast"]))
	var timer_kept := timer_only.value as TmcContent if timer_only.ok else null
	_check(timer_kept != null and timer_kept.ids() == PackedStringArray(["airdrift"]) and timer_kept.missing.is_empty(),
		"a games list naming g2gfast keeps airdrift and reports nothing missing",
		str(timer_kept.ids()) + " missing " + str(timer_kept.missing) if timer_kept != null else str(timer_only.error))

	_done()


## A deployed game whose map runs until it is voted out says so twice, and the two must agree:
## `<game>_map_seconds: "0"` stops the MAP session's timer, and the vote has a clock of its own.
func _test_deployed_map_clocks() -> void:
	var scanned := TmcContent.scan("res://content")

	if not _check(scanned.ok, "the shipped content scans", str(scanned.error)):
		return

	var content := scanned.value as TmcContent
	var untimed := PackedStringArray()
	var disagree := PackedStringArray()

	for descriptor in content.games:
		var stopped := false

		for name: Variant in descriptor.cvars:
			if str(name).ends_with("_map_seconds") and str(descriptor.cvars[name]).strip_edges() == "0":
				stopped = true

		if not stopped:
			continue

		untimed.append(descriptor.game_id)

		var overlay: Variant = descriptor.metadata.get("map_vote", {})
		var rules := DotVoteRules.new()
		var layered := rules.layer_over_defaults(
			"", overlay as Dictionary if overlay is Dictionary else {}
		)

		if (
			not layered.ok or not rules.validate().ok
			or rules.duration_sec > 0.0
			or rules.trigger != DotVoteRules.Trigger.RTV_ONLY
		):
			disagree.append("%s (trigger %s, duration %.0f)" % [
				descriptor.game_id, rules.enum_name("trigger"), rules.duration_sec
			])

	_check(
		untimed.has("playlot"),
		"the playlot ships with its map clock stopped (%s)" % ", ".join(untimed),
		"the check below is about nothing if no shipped game stops its map clock"
	)
	_check(
		disagree.is_empty(),
		"and every game that stops its map clock stops its vote's clock too: rtv_only, no duration",
		", ".join(disagree)
	)


## `end_vote`, `include_extend` and `extend_seconds` through `DOT_GAME_VOTE_*` and `--game-vote-*`,
## each in a child process, change what the server vote's ballot does. `_test_vote` checks one of
## the six as a parsed value; this asks the ballot.
