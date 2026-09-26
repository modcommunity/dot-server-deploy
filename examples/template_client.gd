extends Node
# [b]Nothing preloaded out of the game, because no game is in this build.[/b] The template is
# a delivered pack: its files are at `res://dot_cloud/someone/dot-game-template/0.0.1/…`, and
# everything about it is reached through the host's module table and `get()`, the way a host
# is supposed to reach a game it cannot name.

const Installer := preload("res://tools/install_games.gd")

## A game made from dot-game-template, delivered the way a third-party developer's is.
##
## [codeblock]
## godot --headless --path . res://examples/template_client.tscn
## [/codeblock]
##
## Exits non-zero on any failure, and exits 0 with a line saying so when the template or dot-ci
## is not beside this project (a release tarball, a container), because there is then nothing
## to deliver.
##
## [b]The whole path a developer's game takes, with the site stood in for.[/b] The template's
## committed tree is packaged by dot-ci's `package.sh --pack` -- the exact step its release
## workflow runs -- and the `-pack.zip` that produces is published the way website-city
## publishes a release file ending in `-pack.zip`: unpacked, every res:// reference into the pack
## rewritten onto the mount, signed, under `<site username>/<repo>` (here
## `someone/dot-game-template`). The descriptor is the one inside the pack, stamped by
## `install_games.gd`'s own `stamp_identity`. Then a real host boots it, a real client joins
## over a real socket, and plays: it steers at a coin and the score comes back.
##
## [b]Why this and not smash_client.[/b] That one publishes with this project's own
## `./server pack`, from a checkout. The template is the thing strangers copy, and what they ship
## is a CI artifact the site signs -- so this checks that artifact, and a template that works
## only in its own project is caught here instead of in somebody else's first release.
##
## The template's own suites run inside its project, where its files are at res:// and nothing
## is mounted; this is the half they cannot reach. It packages git HEAD, so commit first.

const CONFIG_FIXTURE := "res://examples/fixtures/template"
const ROOT := "user://tmc_template_client"

const GAME := "dot-game-template"
const CONTENT_ID := "someone/dot-game-template"
const VERSION := "0.0.1"
const MODULE := "tpl"

const CHECKS := 21

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _client_side: Node = null
var _link: DotClientLink = null
var _spawned := [false]
var _refused := [""]


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: a game made from dot-game-template, delivered and joined")

	var source := _template_source()
	var package_sh := ProjectSettings.globalize_path("res://").path_join("../dot-ci/scripts/package.sh").simplify_path()

	if source == "" or not FileAccess.file_exists(package_sh):
		print("  --    skipped: no dot-game-template or dot-ci beside this project; nothing to deliver")
		get_tree().quit(0)
		return

	DotPaths.remove_tree(ROOT)

	var pack_dir := _package(source, package_sh)

	if pack_dir != "" and _publish(pack_dir) and await _boot():
		if await _test_connect():
			_test_the_pack_mounted()
			await _test_playing()
			_test_still_serving()

	await _teardown()
	DotPaths.remove_tree(ROOT)

	print("")
	_check(_completed == _entered, "every section ran to its last line (%d of %d)" % [_completed, _entered])
	_check(
		_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a section that aborted part-way stops adding checks, and only a total can show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 else 0)


## The template's checkout: TEMPLATE_SOURCE, then games/, then beside this project.
func _template_source() -> String:
	var candidates := PackedStringArray([OS.get_environment("TEMPLATE_SOURCE")])
	var here := ProjectSettings.globalize_path("res://")
	candidates.append(here.path_join("games/dot-game-template"))
	candidates.append(here.path_join("../dot-game-template").simplify_path())

	for dir in candidates:
		if dir != "" and FileAccess.file_exists(dir.path_join("game.yml")):
			return dir
	return ""


# --- The release, and the site ----------------------------------------------

## What the template's release workflow does: import, then `package.sh --pack`.
func _package(source: String, package_sh: String) -> String:
	_section("the template is packaged as its release packages it")

	var godot := OS.get_executable_path()
	OS.set_environment("GODOT", godot)

	# package.sh refuses an unimported checkout, because a pack is never re-imported.
	if not DirAccess.dir_exists_absolute(source.path_join(".godot/imported")):
		OS.execute(godot, ["--headless", "--path", source, "--import"])

	var out := ProjectSettings.globalize_path(ROOT.path_join("release"))
	var said: Array = []
	# `--name`, as the release workflow passes it: the checkout's directory is not always the
	# repository's name, and the artifact is named for the second.
	var status := OS.execute("bash", [package_sh, source, VERSION, "--out", out, "--name", GAME, "--pack"], said, true)
	var zip := out.path_join("dot-game-template-%s-pack.zip" % VERSION)

	if not _check(status == 0 and FileAccess.file_exists(zip), "package.sh --pack makes the pack zip", str(said)):
		_done()
		return ""

	var pack_dir := ProjectSettings.globalize_path(ROOT.path_join("unpacked"))
	DirAccess.make_dir_recursive_absolute(pack_dir)
	var unpacked := OS.execute("unzip", ["-q", "-o", zip, "-d", pack_dir])

	_check(unpacked == 0 and FileAccess.file_exists(pack_dir.path_join("game.yml")),
		"it carries the game's own game.yml")
	_check(FileAccess.file_exists(pack_dir.path_join("requires.json")),
		"and a requires.json naming the addon API it was built against")
	_done()
	return pack_dir if unpacked == 0 else ""


## What the site does with a `-pack.zip`: sign it under `<username>/<repo>` and serve it.
## Here the origin is the content directory, which the host searches before any network, and
## the signing key is made for this run and trusted by this run's config alone.
func _publish(pack_dir: String) -> bool:
	_section("published the way the site publishes a release")

	var pair := DotCloudSignature.generate_keypair()
	if not _check(pair.ok, "a signing key for this run", str(pair.error)):
		_done()
		return false

	var descriptor := Installer.stamp_identity(
		FileAccess.get_file_as_string(pack_dir.path_join("game.yml")), CONTENT_ID, VERSION
	)
	var fields: Dictionary = TmcYaml.parse(str(descriptor.value), "<stamped>").value if descriptor.ok else {}
	var client_scene := str(fields.get("client_scene", ""))

	var publisher := DotCloudPublisher.new()
	publisher.content_id = CONTENT_ID
	publisher.version = VERSION
	publisher.display_name = str(fields.get("name", ""))
	publisher.entry_scene = client_scene
	publisher.signing_key_pem = str(pair.value["private"])
	publisher.signing_key_id = "default"
	var content := ROOT.path_join("content")
	var published := publisher.publish(pack_dir, ProjectSettings.globalize_path(
		content.path_join(CONTENT_ID).path_join(VERSION)))
	_check(published.ok, "the pack is signed as %s@%s" % [CONTENT_ID, VERSION], str(published.error))

	# The installer's half: the descriptor out of the pack, stamped with the id and version it
	# was published under, at content/<repo>/game.yml.
	DotPaths.write_text(content.path_join(GAME).path_join("game.yml"), str(descriptor.value))
	_check(descriptor.ok and str(fields.get("content_id")) == CONTENT_ID
		and str(fields.get("version")) == VERSION and client_scene != "" and not client_scene.contains("://"),
		"its descriptor is stamped with that id and version, and names a relative client scene")

	# This run's config: the fixture, plus a content.json that trusts this run's key and no other.
	var cfg := ROOT.path_join("cfg")
	for name in DirAccess.get_files_at(CONFIG_FIXTURE):
		DotPaths.write_text(cfg.path_join(name), FileAccess.get_file_as_string(CONFIG_FIXTURE.path_join(name)))
	DotPaths.write_text(cfg.path_join("content.json"), JSON.stringify({
		"require_signed_manifests": true,
		"trusted_keys": {"default": str(pair.value["public"])},
	}))
	_done()
	return published.ok and descriptor.ok


# --- Boot, and a client -------------------------------------------------------

func _boot() -> bool:
	_section("a host boots the delivered game")

	_host = (load("res://host/host.tscn") as PackedScene).instantiate()
	_host.auto_start = false
	add_child(_host)

	var started: DotResult = await _host.start(ROOT.path_join("cfg"), ROOT.path_join("content"), ROOT.path_join("data"))
	if not _check(started.ok, "the host boots", str(started.error)):
		_done()
		return false

	var reached := await _until(func() -> bool:
		var current := _server().games.current()
		return current != null and current.game_id == GAME \
			and _server().games.phase == DotGameManager.Phase.IDLE, 45.0)
	_check(reached, "and reaches the game out of the pack")

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())
	_done()
	return reached


func _test_connect() -> bool:
	_section("a client joins and the game's own client scene loads")

	# "Server", the same as DotServer's node. The name is the routing.
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Newcomer"
	_client_side.add_child(_link)
	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _refused[0] = reason)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % _host.config.server.port)
	var admitted := connecting.ok and await _until(func() -> bool: return _spawned[0] or _refused[0] != "", 45.0)

	if not _check(admitted and _refused[0] == "", "it signs on", "refused: %s" % _refused[0]):
		_done()
		return false

	var scene := _client_scene()
	var path := String((scene.get_script() as Resource).resource_path) if scene != null else ""
	_check(path.begins_with("res://dot_cloud/%s/%s/" % [CONTENT_ID, VERSION]),
		"the client scene the server named is the mounted copy", path)

	var told := await _until(func() -> bool: return scene != null and int(scene.get("local_id")) != 0, 20.0)
	_check(told, "and the server told it which player it is")
	_done()
	return told


func _test_the_pack_mounted() -> void:
	_section("the server runs the game out of the pack")

	var module: DotModule = _server().modules.get_module(MODULE)
	if not _check(module != null, "the game's module loaded"):
		_done()
		return

	var path := String((module.get_script() as Resource).resource_path)
	_check(path.begins_with("res://dot_cloud/%s/%s/" % [CONTENT_ID, VERSION]),
		"from the mount, not from any build", path)
	_check(module.get("net") != null and (module.get("net") as DotNetManager).is_running(),
		"with its netcode running")

	var said := _world_says()
	_check(int(said.get("coins", 0)) > 0 and int(said.get("players", 0)) == 1,
		"and a world with coins and the one player in it (%s)" % [said])
	_done()


## Played, not inspected: the client scene is steered at the nearest coin it can see, through
## the same hook a keyboard feeds, until the server scores one and the client shows it.
func _test_playing() -> void:
	_section("a coin is collected and the score comes back")

	var scene := _client_scene()
	var game: Object = scene.get("game")
	var me := func() -> Object: return (game.get("players") as Dictionary).get(int(scene.get("local_id")))

	scene.set("steer", func() -> Vector2:
		var at: Vector2 = me.call().get("position")
		var best: Vector2 = game.get("coins")[0]
		for spot: Vector2 in game.get("coins"):
			if spot.distance_to(at) < best.distance_to(at):
				best = spot
		return (best - at).normalized()
	)

	var scored := await _until(func() -> bool: return int(_world_says().get("collected", 0)) > 0, 30.0)
	_check(scored, "the server scores it")
	_check(await _until(func() -> bool: return int(me.call().get("score")) > 0, 10.0),
		"and the client's copy of the player shows the score")
	scene.set("steer", Callable())
	_done()


func _test_still_serving() -> void:
	_section("still serving")
	_check(_server().console.execute("tpl_status").ok, "the delivered game's own console command answers")
	_check(_refused[0] == "" and _link.is_playing(), "and the client is still connected")
	_done()


# --- Helpers -------------------------------------------------------------------

func _server() -> DotServer:
	return _host.server as DotServer


## The client scene the link loaded, found by walking: this build cannot name its type.
func _client_scene() -> Node:
	var root := _link.get_node_or_null(^"GameRoot") if _link != null else null
	return root.get_child(0) if root != null and root.get_child_count() > 0 else null


func _world_says() -> Dictionary:
	var module: DotModule = _server().modules.get_module(MODULE)
	var world: Variant = module.get("game") if module != null else null
	return (world as Object).call("describe") if world != null else {}


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


## The client first, a frame, then the host: the client holds the delivered scene, and freeing
## the host first leaves it alive with nothing referencing it. See smash_client.
func _teardown() -> void:
	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("test over")
	await get_tree().process_frame
	if _client_side != null:
		remove_child(_client_side)
		_client_side.queue_free()
	await get_tree().process_frame
	if _host != null:
		if _host.server != null:
			_host.server.shutdown("test over")
		remove_child(_host)
		_host.queue_free()
	await get_tree().process_frame


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
