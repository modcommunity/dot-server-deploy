class_name SelftestAddonAnnounce
extends RefCounted

## The addon set a server announces: lock and overlay translation, namespaces, scoped announce and download groups. Run by `selftest.gd`, which keeps the counters: every check goes through its `_check`.

var t: Node


func _init(p_test: Node) -> void:
	t = p_test


func _section(title: String) -> void:
	t._section(title)


func _done() -> void:
	t._done()


func _check(condition: bool, what: String, detail: String = "") -> bool:
	return t._check(condition, what, detail)


func _test_addon_announce() -> void:
	_section("the addon set a server announces")
	var lock := "arena-weapons\tv1.4.10\ndot-core\tv0.1.30\n"
	var out := TmcAddonSet.addon_set_from(lock, PackedStringArray(["arena_weapons", "dot_core"]))
	_check(out.size() == 2 and out[0]["id"] == "gamemann/fc-weapons" and out[0]["repo"] == "fc-weapons" and out[0]["version"] == "1.4.10", "a game addon's pack is announced under its author and published name, at the lock's version")
	var renamed := TmcAddonSet.addon_set_from("fc-weapons\tv1.4.11\n", PackedStringArray(["arena_weapons"]))
	_check(renamed.size() == 1 and renamed[0]["id"] == "gamemann/fc-weapons" and renamed[0]["version"] == "1.4.11", "a lock under the renamed repository's name announces the same pack")
	_check(TmcAddonNamespaces.lock_repo("arena_weapons") == "fc-weapons" and TmcAddonNamespaces.lock_repo("fc_weapons") == "fc-weapons", "fc_weapons and its legacy arena_weapons are both locked as fc-weapons")
	_check(TmcAddonNamespaces.dir_for("fc-weapons") == "fc_weapons" and TmcAddonNamespaces.dir_for("arena-weapons") == "fc_weapons", "fc-weapons, by either repository name, installs to fc_weapons")
	_check(TmcAddonNamespaces.dir_for("fc-weapons", "1.4.51") == "arena_weapons" and TmcAddonNamespaces.dir_for("arena-weapons", "v1.4.10") == "arena_weapons", "a version up to the last legacy tag (1.4.51) holds the legacy arena_weapons")
	_check(TmcAddonNamespaces.dir_for("fc-weapons", "1.4.52") == "fc_weapons" and TmcAddonNamespaces.dir_for("fc-weapons", "1.5.0") == "fc_weapons", "a newer version holds fc_weapons")
	_check(TmcAddonNamespaces._warned.has("arena_weapons@fc-weapons@1.4.51") and not TmcAddonNamespaces._warned.has("fc_weapons@fc-weapons@1.5.0"), "the legacy dir is warned about, naming the ref; the current one is not")
	var current := TmcAddonSet.addon_set_from("fc-weapons\tv1.5.0\n", PackedStringArray(["fc_weapons"]))
	_check(current.size() == 1 and current[0]["dir"] == "fc_weapons" and current[0]["id"] == "gamemann/fc-weapons" and current[0]["version"] == "1.5.0", "an installed fc_weapons is announced as fc-weapons")
	var stale := TmcAddonSet.addon_set_from("fc-weapons\tv1.4.52\nzee-dot-weapons\tv0.1.66\n", PackedStringArray(["arena_weapons", "fc_weapons", "zee_weapons"]))
	_check(stale.size() == 2 and stale[0]["dir"] == "fc_weapons" and stale[1]["dir"] == "zee_weapons", "a leftover legacy arena_weapons the locked fc-weapons (1.4.52+) no longer holds is not announced", str(stale))
	var stale_only := TmcAddonSet.addon_set_from("fc-weapons\tv1.4.54\n", PackedStringArray(["arena_weapons"]))
	_check(stale_only.is_empty(), "a stale legacy dir alone announces nothing, so no client builds an overlay from a pack that lacks it", str(stale_only))
	_check(TmcAddonNamespaces._warned.has("arena_weapons@fc-weapons@1.4.11"), "an installed legacy arena_weapons is announced with a warning naming the locked ref")
	_check(out[1]["id"] == "modcommunity/dot-core" and out[1]["repo"] == "dot-core" and out[1]["version"] == "0.1.30", "a dot-* addon is announced under its old id, which every shell takes, at the lock's version")
	var core := TmcAddonNamespaces.pack_for("dot_core")
	_check(core["id"] == "gamespice-platform/core" and core["repo"] == "core" and core["old_id"] == "modcommunity/dot-core", "a dot-* addon's pack is gamespice-platform/<name>, with the modcommunity alias as its old id")
	_check(TmcAddonNamespaces.dir_for_id("gamespice-platform/core") == "dot_core" and TmcAddonNamespaces.dir_for_id("modcommunity/dot-core") == "dot_core" and TmcAddonNamespaces.dir_for_id("gamemann/fc-weapons") == "fc_weapons" and TmcAddonNamespaces.dir_for_id("gamemann/fc-weapons", "1.4.40") == "arena_weapons", "both of an addon's ids find its dir, a renamed one's by version")
	_check(TmcAddonNamespaces.covers(TmcAddonNamespaces.DEFAULTS, "gamespice-platform/core") and TmcAddonNamespaces.covers(TmcAddonNamespaces.DEFAULTS, "modcommunity/dot-core"), "the shell takes the organisation's packs under the new and the old id")
	_check(TmcAddonSet.addon_set_from(lock, PackedStringArray(["natural_disasters"])).is_empty(), "an addon the lock does not name is not announced")

	var cfg := TmcAddonsConfig.new()
	var bad := cfg.read({"overlays": ["alice/dot-x@1.0.0"]})
	_check(not bad.ok, "an overlay whose owner is not under namespaces: is refused")
	cfg = TmcAddonsConfig.new()
	_check(cfg.read({"namespaces": ["alice/"], "overlays": ["alice/dot-x@v1.0.0"]}).ok, "a trusted owner's overlay is read")
	var mixed := TmcAddonSet.merge_overlays(out, cfg.overlay_set())
	_check(mixed.size() == 3 and mixed[2]["dir"] == "dot_x" and mixed[2]["id"] == "alice/dot-x" and mixed[2]["version"] == "1.0.0", "the overlay is announced beside the lock's set")
	cfg = TmcAddonsConfig.new()
	_check(cfg.read({"overlays": ["gamemann/zee-dot-weapons@0.1.63", "gamemann/fc-weapons@1.4.40"]}).ok, "a default owner's game-addon overlay is read")
	var games := cfg.overlay_set()
	_check(games[0]["dir"] == "zee_weapons" and games[1]["dir"] == "arena_weapons" and games[1]["repo"] == "fc-weapons", "a game-addon overlay names the dir its pack carries, not its repository's (fc-weapons 1.4.40: the legacy one)")
	cfg = TmcAddonsConfig.new()
	_check(cfg.read({"overlays": ["gamemann/fc-weapons@1.5.0"]}).ok and cfg.overlay_set()[0]["dir"] == "fc_weapons", "an fc-weapons overlay past the rename names fc_weapons")
	var swapped := TmcAddonSet.merge_overlays(out, games)
	_check(swapped.size() == 3 and swapped[1]["dir"] == "zee_weapons" and swapped[2]["version"] == "1.4.40", "a game-addon overlay replaces the lock's entry for its dir")
	_check(not TmcAddonsConfig.new().read({"namespaces": ["*"]}).ok and not TmcAddonsConfig.new().read({"namespaces": ["alice"]}).ok, "a wildcard or a bare name is not a namespace")

	for name in ["dot_trail", "dot_radio"]:
		var author := TmcAddonNamespaces.pack_for(name)
		_check(author["id"] == "gamemann/" + name.replace("_", "-") and author["repo"] == name.replace("_", "-") and author["old_id"] == "", "%s is announced under its author, gamemann/, with no alias" % name)
		_check(TmcAddonNamespaces.covers(TmcAddonNamespaces.DEFAULTS, str(author["id"])) and TmcAddonNamespaces.dir_for_id(str(author["id"])) == name, "the shell takes %s's pack, and its id finds the dir" % name)
	var spaces0 := TmcAddonNamespaces.DEFAULTS
	var ref := TmcAddonsConfig.addon_ref("gamemann/dot-trail@v0.1.5", spaces0)
	_check(ref.ok and ref.value["dir"] == "dot_trail" and ref.value["id"] == "gamemann/dot-trail" and ref.value["version"] == "0.1.5", "addons: gamemann/dot-trail@version resolves to the dir, id and version")
	_check(TmcAddonsConfig.addon_ref("gamemann/dot-radio", spaces0, {"dot-radio": "v0.1.4"}).value["version"] == "0.1.4", "an addons: entry without a version takes the lock's")
	_check(not TmcAddonsConfig.addon_ref("gamemann/dot-radio", spaces0).ok, "an addons: entry with no version anywhere is refused")
	_check(not TmcAddonsConfig.addon_ref("mallory/dot-radio@1.0.0", spaces0).ok, "an addons: entry from an untrusted owner is refused")
	_check(TmcAddonsConfig.addon_ref("gamemann/fc-weapons", spaces0, {"fc-weapons": "v1.4.51"}).value["dir"] == "arena_weapons" and TmcAddonsConfig.addon_ref("gamemann/fc-weapons@1.5.0", spaces0).value["dir"] == "fc_weapons", "an addons: fc-weapons entry takes the dir its version holds (legacy arena_weapons up to 1.4.51)")
	var listed := TmcAddonSet.addons_from_list(PackedStringArray(["gamemann/dot-trail@0.1.5", "gamemann/dot-radio@0.1.4", "mallory/x@1.0.0", "gamemann/dot-radio"]), spaces0, "", PackedStringArray(["dot_trail"]))
	_check(listed["entries"].size() == 1 and listed["errors"].size() == 3, "addons_from_list announces the installed trusted ones and reports each of the rest")
	var hc := TmcConfig.new()
	_check(hc != null and TmcConfig.HOST_KEYS.has("addons"), "addons is a server.yml host key")

	var spaces := TmcAddonNamespaces.resolve(PackedStringArray(["alice/", "bad entry", "modcommunity/"]))
	_check(spaces.size() == TmcAddonNamespaces.DEFAULTS.size() + 1 and TmcAddonNamespaces.covers(spaces, "alice/dot-x") and not TmcAddonNamespaces.covers(spaces, "alicia/dot-x"), "operator namespaces extend the defaults; owner prefix needs the slash")
	_check(TmcAddonNamespaces.parse_lines("# c\nalice/ # me\n\n") == PackedStringArray(["alice/"]), "the namespaces file is one entry per line with comments")
	_check(TmcAddonNamespaces.covers(TmcAddonNamespaces.DEFAULTS, "gamemann/arena-weapons") and not TmcAddonNamespaces.covers(TmcAddonNamespaces.DEFAULTS, "gamemann/arena-weapons-evil"), "the defaults keep their exact-id entries exact")
	for dir: String in ["fc_weapons", "zee_weapons", "zed_weapons", "natural_disasters"]:
		var id := str(TmcAddonNamespaces.pack_for(dir)["id"])
		_check(str(TmcAddonNamespaces.pack_for(dir)["repo"]) == id.get_file(), "%s's pack repo is its id's name, as the addon set requires" % dir)
		_check(TmcAddonNamespaces.dir_for(id.get_file()) == dir and TmcAddonNamespaces.dir_for(TmcAddonNamespaces.lock_repo(dir)) == dir, "%s round-trips through its pack and lock names" % dir)
		_check(TmcAddonNamespaces.covers(TmcAddonNamespaces.DEFAULTS, id), "the shell takes %s's overlay (%s), since it does not carry it" % [dir, id])

	var pins: Variant = JSON.parse_string(TmcAddonSet.pack_pins_json(out, {"modcommunity/dot-core": "9.9.9", "ow/map_a": "1.0.0"}))
	_check(pins is Dictionary and pins.get("ow/map_a") == "1.0.0" and pins.get("modcommunity/dot-core") == "9.9.9", "sv_pack_pins lists mounted packs, and what is mounted wins over the lock")
	_check(pins is Dictionary and pins.get("gamespice-platform/core") == "0.1.30" and not pins.has("gamespice-platform/fc-weapons"), "sv_pack_pins also pins a dot-* addon's version under its new id")
	_check(TmcAddonSet.pack_pins_json([], {}) == "", "nothing pinned reports nothing")
	_addon_download_groups(out)
	_addon_announce_scope(out)
	_done()


## `addons_announce: game`: the framework's addons plus what the game's requires.json names; unknown needs announce everything.
func _addon_announce_scope(out: Array) -> void:
	var only := TmcAddonSet.scoped(out, {"arena_weapons": 1})
	_check(only.size() == 2 and only[0]["dir"] == "arena_weapons" and only[1]["dir"] == "dot_core", "a game that needs fc-weapons is announced it and the framework")
	var bare := TmcAddonSet.scoped(out, {})
	_check(bare.size() == 1 and bare[0]["dir"] == "dot_core", "a game that needs no game addon is announced the framework only")
	_check(TmcAddonSet.scoped(out, null).size() == out.size(), "a game whose needs are not known is announced everything, the old behaviour")
	only[0]["version"] = "x"
	_check(out[0]["version"] == "1.4.10", "the scoped set is a copy")
	_check(TmcAddonSet.union_needs([{"a": 1}, {"a": 2, "b": 1}]) == {"a": 2, "b": 1}, "the needs of the current and the next game are unioned at the higher level")
	_check(TmcAddonSet.union_needs([{"a": 1}, null]) == null, "one game with unknown needs makes the union unknown")
	var told := [{"dir": "dot_core", "version": "0.1.30"}]
	var next := [{"dir": "dot_core", "version": "0.1.30"}, {"dir": "zed_weapons", "version": "0.2.0"}]
	var fresh := TmcAddonSet.added(told, next)
	_check(fresh.size() == 1 and fresh[0]["dir"] == "zed_weapons", "a client is sent only what it was not told")
	_check(TmcAddonSet.added(next, told).is_empty() and TmcAddonSet.added(told, [{"dir": "dot_core", "version": "0.1.31"}]).size() == 1, "a narrower set adds nothing; a new version of a told addon does")
	_check(TmcConfig.check_addons_announce("all").ok and TmcConfig.check_addons_announce("game").ok, "addons_announce takes all and game")
	_check(not TmcConfig.check_addons_announce("gam").ok and not TmcConfig.check_addons_announce("").ok, "any other addons_announce refuses boot")
	_check(TmcConfig.HOST_KEYS.has("addons_announce") and TmcConfig.new().addons_announce == TmcConfig.ADDONS_ANNOUNCE_ALL, "addons_announce is a server.yml host key, all by default")
	_check(TmcAddonGroups.ANNOUNCE_KIND == &"tmc.addons", "the mid-session announce has its envelope kind")


## Download groups: the game names them per dir, the shell unions what it is about to build.
func _addon_download_groups(out: Array) -> void:
	# Download groups: the game names them per dir, the shell unions what it is about to build.
	var named := TmcAddonSet.with_groups(out, TmcAddonSet.sanitize_groups({"arena_weapons": PackedStringArray(["weapon-b", "weapon-a"]), "dot_nowhere": ["x"], "dot_core": [3]}))
	_check(named[0]["groups"] == ["weapon-b", "weapon-a"] and not named[1].has("groups") and not out[0].has("groups"), "the game's groups ride its dir's entry only, on a copy; a malformed list is dropped")
	var server := [
		{"dir": "arena_weapons", "groups": ["weapon-rifle", "weapon-awp"]}, {"dir": "dot_ui"}, {"dir": "zee_weapons", "groups": ["weapon-awp", "weapon-x"]},
	]
	_check(TmcAddonGroups.needed_groups(server, {"arena_weapons": {}, "dot_ui": {}}) == PackedStringArray(["weapon-awp", "weapon-rifle"]), "an entry without groups adds none to the union")
	_check(TmcAddonGroups.needed_groups(server, {"dot_ui": {}}) == PackedStringArray(["*"]), "nothing named is everything")
	_check(TmcAddonGroups.needed_groups([{"dir": "a", "groups": ["*"]}, {"dir": "b", "groups": ["g"]}], {"a": {}, "b": {}}) == PackedStringArray(["*"]) and TmcAddonGroups.needed_groups([{"dir": "a", "groups": "g"}], {"a": {}}) == PackedStringArray(["*"]), "a wildcard or a malformed field is everything")
	_check(TmcAddonGroups.wanted_groups(server, {"arena_weapons": {}, "zee_weapons": {}}, {"groups": ["weapon-knife"]}) == PackedStringArray(["weapon-awp", "weapon-knife", "weapon-rifle", "weapon-x"]), "never narrower than the running overlay")
	_check(TmcAddonGroups.wanted_groups(server, {"arena_weapons": {}}, {"addons": {}}) == PackedStringArray(["*"]), "a plan from before groups took everything, and keeps it")
	_check(TmcAddonGroups.covers(PackedStringArray(["a", "b"]), PackedStringArray(["b"])) and not TmcAddonGroups.covers(PackedStringArray(["a"]), PackedStringArray(["a", "b"])) and not TmcAddonGroups.covers(PackedStringArray(["a"]), PackedStringArray(["*"])) and TmcAddonGroups.covers(PackedStringArray(["*"]), PackedStringArray(["z"])), "an overlay covers a server only with every group it needs")
