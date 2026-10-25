extends Node

## A server owner's extra pack (`cfg/content/addons.yml`) is mounted as a dependency of the game and
## its entry scene is started.
##
## Publishes four fixture packs with the real `tools/pack.gd` (one starting on the server, one
## on the client, one with no entry, one whose entry scene is not in the pack), mounts them
## through a real [DotCloudClient] against a signed scratch origin, lets [TmcAddonsConfig]
## append them to a game's dependencies, and has [TmcAddonEntry] start them. The entry scene
## carries no script (a delivered scene cannot name its own files by res:// path), only a
## group, so "instantiated" is read off the tree and off the scene's path under the mount.
##
##     godot --headless --path . res://examples/addon_entry.tscn
##
## Armed by making `TmcAddonEntry.attach` ignore `side` (the server run then also starts the
## client pack and the counts fail), and by making `TmcAddonsConfig.apply` append nothing.

const CHECKS := 23
const FIXTURE := "res://examples/fixtures/addon_pack"
const SCRATCH := "user://addon_entry"
const PACKS := ["extra", "clientside", "plain", "broken"]

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: PackedStringArray = []


func _ready() -> void:
	DotPaths.remove_tree(SCRATCH)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))

	var pair := DotCloudSignature.generate_keypair()

	if _publish(pair):
		await _mount_and_attach(pair)

	DotPaths.remove_tree(SCRATCH)

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


func _publish(pair: DotResult) -> bool:
	_section("tools/pack.gd publishes a pack whose manifest carries its entry")

	var scratch := ProjectSettings.globalize_path(SCRATCH)
	var key := scratch.path_join("content.key")
	var f := FileAccess.open(key, FileAccess.WRITE)
	f.store_string(str(pair.value["private"]) if pair.ok else "")
	f.close()

	for id in PACKS:
		var said := []
		var code := OS.execute(OS.get_executable_path(), [
			"--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://tools/pack.gd", "--",
			"--content", ProjectSettings.globalize_path(FIXTURE).path_join("content"),
			"--out", scratch.path_join("dist"), "--key", key, "--id", id,
			"--source", ProjectSettings.globalize_path(FIXTURE).path_join("source"),
		], said, true)

		if not _check(code == 0, "pack.gd publishes %s" % id, "\n".join(PackedStringArray(said)).right(600)):
			_done()
			return false

	var manifest := _read_manifest(_manifest_path("dev/extra", "1.2.0"))
	var meta: Dictionary = manifest.get("metadata", {})
	_check(str(meta.get("entry", "")) == "entry.tscn" and str(meta.get("side", "")) == "server",
		"the signed manifest carries entry and side", str(meta))
	_check(not _read_manifest(_manifest_path("dev/plain", "2.0.0")).has("metadata"),
		"a pack with no addon key carries no metadata")
	_check(str(manifest.get("entry_scene", "")) == "",
		"and the manifest's own entry scene stays free for a game's scene")

	# A bad side is refused when the pack is built, not discovered by a player.
	var bad := scratch.path_join("badcontent/bad")
	DirAccess.make_dir_recursive_absolute(bad)
	var w := FileAccess.open(bad.path_join("pack.json"), FileAccess.WRITE)
	w.store_string('{"id": "dev/bad", "version": "1.0.0", "addon": {"entry": "entry.tscn", "side": "moon"}}')
	w.close()
	var refused := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tools/pack.gd", "--",
		"--content", scratch.path_join("badcontent"), "--out", scratch.path_join("baddist"),
		"--key", key, "--id", "bad", "--source", ProjectSettings.globalize_path(FIXTURE).path_join("source"),
	], [], true)
	_check(refused != 0, "a side other than server, client or both is refused when publishing")
	_done()
	return true


func _mount_and_attach(pair: DotResult) -> void:
	_section("the owner's file adds the packs, and each side starts its own")

	var scratch := ProjectSettings.globalize_path(SCRATCH)
	var cfg := scratch.path_join("cfg")
	var data := scratch.path_join("data")
	DirAccess.make_dir_recursive_absolute(cfg.path_join("content"))
	DirAccess.make_dir_recursive_absolute(data)
	_write(cfg.path_join("content.json"), JSON.stringify({
		"require_signed_manifests": true, "trusted_keys": {"default": str(pair.value["public"])},
	}))
	# `plain` is left unpinned in the file: the installer's cache answers for it.
	_write(cfg.path_join("content/addons.yml"),
		"defaults:\n  add: [dev/extra@1.2.0, dev/plain]\ngames:\n  game:\n    add: [dev/clientside@0.3.0, dev/broken@1.0.0]\n")
	_write(data.path_join(TmcAddonsConfig.RESOLVED_FILE), JSON.stringify({"packs": {"dev/plain": "2.0.0"}}))

	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.host_role = "server"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = scratch.path_join("cache")
	cloud.config_file = cfg.path_join("content.json")
	cloud.local_search_dirs = PackedStringArray([scratch.path_join("dist")])
	# The shapes TmcHost, install-games and the shell all set: pack.gd writes the flat one,
	# and without it every versioned ask misses the scratch dist/.
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])
	add_child(cloud)

	var loaded := TmcAddonsConfig.load_from(cfg, data)
	_check(loaded.ok, "cfg/content/addons.yml and the installer's pins load", str(loaded.error) if not loaded.ok else "")

	if not loaded.ok:
		_done()
		return

	var addons := loaded.value as TmcAddonsConfig
	var descriptor := DotGameDescriptor.new()
	descriptor.game_id = "dev/game"
	descriptor.dependencies = PackedStringArray(["dev/maps@1.0.0"])
	var content := TmcContent.new()
	content.games = [descriptor]
	_check(addons.apply_all(content) == 1, "applying it changes the one game")
	_check(descriptor.dependencies == PackedStringArray([
		"dev/maps@1.0.0", "dev/extra@1.2.0", "dev/plain@2.0.0", "dev/clientside@0.3.0", "dev/broken@1.0.0",
	]), "the packs follow the game's own dependency, defaults first, the unpinned one pinned from the cache",
		str(descriptor.dependencies))

	# What the server's game change does: every dependency is mounted first.
	for key in descriptor.dependencies.slice(1):
		var ref := TmcGameRef.parse(key)
		var got: DotResult = await cloud.ensure(StringName(str(ref["id"])), str(ref["version"]))
		_check(got.ok, "%s mounts" % key, str(got.error) if not got.ok else "")

	var server_side := Node.new()
	add_child(server_side)
	var started := TmcAddonEntry.attach(server_side, cloud, descriptor.dependencies, "server")
	_check(started == 1, "the server starts exactly the pack that runs there (the broken one is logged, not fatal)", str(started))
	_check(server_side.get_child_count() == 1 and server_side.get_child(0).is_in_group("addon_probe"),
		"and its entry scene is in the tree")
	var live: Node = server_side.get_child(0) if server_side.get_child_count() > 0 else null
	_check(live != null and live.scene_file_path == "res://dot_cloud/dev/extra/1.2.0/entry.tscn",
		"loaded through the pack's mount prefix", live.scene_file_path if live != null else "none")
	_check(live != null and live.name == &"Addon_dev_extra", "named for the pack", str(live.name) if live != null else "none")

	var client_side := Node.new()
	add_child(client_side)
	_check(TmcAddonEntry.attach(client_side, cloud, descriptor.dependencies, "client") == 1
		and client_side.get_child(0).name == &"Addon_dev_clientside",
		"the client starts the other one, and not the server's")

	_check(TmcAddonEntry.attach(Node.new(), cloud, PackedStringArray(["dev/plain@2.0.0"]), "server") == 0,
		"a pack with no entry is only mounted")
	_check(TmcAddonEntry.attach(Node.new(), cloud, PackedStringArray(["dev/never@9.9.9"]), "server") == 0,
		"a key nothing mounted is skipped")

	# remove: drops a default for one game.
	_write(cfg.path_join("content/addons.yml"),
		"defaults:\n  add: [dev/extra@1.2.0]\ngames:\n  game:\n    remove: [dev/extra]\n")
	var again := TmcAddonsConfig.load_from(cfg, data)
	var other := DotGameDescriptor.new()
	other.game_id = "dev/other"
	_check(again.ok and (again.value as TmcAddonsConfig).entries_for(descriptor).is_empty()
		and (again.value as TmcAddonsConfig).entries_for(other) == PackedStringArray(["dev/extra@1.2.0"]),
		"remove: drops a default for that game only")
	_done()


func _manifest_path(id: String, version: String) -> String:
	var base := ProjectSettings.globalize_path(SCRATCH).path_join("dist")
	for p in [base.path_join(id).path_join(version).path_join("manifest.json"), base.path_join(id).path_join("manifest.json")]:
		if FileAccess.file_exists(p):
			return p
	return base.path_join(id).path_join("manifest.json")


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read_manifest(path: String) -> Dictionary:
	var outer: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not outer is Dictionary:
		return {}
	var payload := str((outer as Dictionary).get("payload", ""))
	var inner: Variant = JSON.parse_string(DotHash.base64url_decode(payload).get_string_from_utf8()) if payload != "" else outer
	return inner if inner is Dictionary else {}


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition
