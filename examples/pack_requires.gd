extends Node

## A pack this box publishes for itself carries requires.json, derived as dot-ci derives it.
##
## `./server pack <id> --source <repo>` (and setup.sh, which runs the same `tools/pack.gd`)
## published every game with no requires.json, while the release path (dot-ci's
## `package.sh --pack`) always wrote one. A box that self-published, and every client that
## fetched from it, therefore had nothing to refuse with: a game built against newer addons
## mounted and failed to compile instead of saying "needs dot-x API level N". This publishes
## a first-party game the way `./server pack` does, into a scratch directory, and reads the
## pack back.
##
##     godot --headless --path . res://examples/pack_requires.tscn
##
## Needs mg-look-at-me (the smallest first-party game) and game-arena (the one with a
## requires.floor.json) in games/ or beside this project, imported, with their addons
## linked. Armed by making `Pack.publisher_for` add nothing (the pack then fails to publish,
## "published without its requires.json"), and by passing it "" (the pack then publishes
## without one and the second check below fails).

const Pack := preload("res://tools/pack.gd")

const CHECKS := 13
const GAME := "lookatme"
const GAME_REPO := "mg-look-at-me"
const FLOORED_REPO := "game-arena"
const SCRATCH := "user://pack_requires"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: PackedStringArray = []


func _ready() -> void:
	DotPaths.remove_tree(SCRATCH)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))

	_test_published()
	_test_floors()
	_test_not_a_project()

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


## games/<repo>, then beside this project.
func _source(repo: String) -> String:
	var here := ProjectSettings.globalize_path("res://")
	for dir in [here.path_join("games").path_join(repo), here.path_join("..").path_join(repo).simplify_path()]:
		if FileAccess.file_exists(str(dir).path_join("project.godot")):
			return str(dir)
	return ""


func _test_published() -> void:
	_section("./server pack --source: a first-party game's pack carries requires.json")

	# No fallback to hide behind: the publisher is a plain DotCloudPublisher carrying the file.
	var chosen := Pack.publisher_for("/derived/requires.json")
	_check(
		chosen.get_script() == DotCloudPublisher
		and chosen.extra_files.get(DotAddonApi.REQUIREMENTS_FILE, "") == "/derived/requires.json",
		"requires.json goes through dot-cloud's public extra_files, not the private override"
	)

	var source := _source(GAME_REPO)
	if not _check(source != "", "%s is here to publish" % GAME_REPO):
		_done()
		return

	var scratch := ProjectSettings.globalize_path(SCRATCH)
	var pair := DotCloudSignature.generate_keypair()
	var key := scratch.path_join("content.key")
	var f := FileAccess.open(key, FileAccess.WRITE)
	f.store_string(str(pair.value["private"]) if pair.ok else "")
	f.close()

	var had_requires := FileAccess.file_exists(source.path_join(DotAddonApi.REQUIREMENTS_FILE))

	# The command ./server pack runs, in its own process as it is run.
	var said := []
	var code := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tools/pack.gd", "--",
		"--content", ProjectSettings.globalize_path("res://content"),
		"--out", scratch.path_join("dist"), "--key", key, "--id", GAME, "--source", source,
	], said, true)
	if not _check(code == 0, "tools/pack.gd publishes %s from %s" % [GAME, GAME_REPO], "\n".join(PackedStringArray(said)).right(800)):
		_done()
		return

	var manifest := _read_manifest(scratch.path_join("dist/tmc").path_join(GAME).path_join("manifest.json"))
	var entry: Dictionary = {}
	for file: Variant in (manifest.get("files", []) as Array):
		if file is Dictionary and str((file as Dictionary).get("path")) == DotAddonApi.REQUIREMENTS_FILE:
			entry = file
	if not _check(not entry.is_empty(), "the signed manifest lists requires.json at the pack's root"):
		_done()
		return

	var sha := str(entry.get("sha256", ""))
	var bytes := FileAccess.get_file_as_bytes(scratch.path_join("dist/tmc").path_join(GAME).path_join("objects").path_join(sha.substr(0, 2)).path_join(sha))
	var parsed := DotAddonApi.parse(bytes.get_string_from_utf8())
	var shipped: Dictionary = parsed.value if parsed.ok else {}
	_check(parsed.ok and shipped.has("dot_core") and shipped.has("dot_server"),
		"its object is a requires.json naming the addons the game compiles against (%d)" % shipped.size(), str(parsed.error) if not parsed.ok else "")

	# The same file dot-ci's package.sh --pack would have written: dot_requires.gd, in the source.
	var direct := Pack.derive_requires(source, SCRATCH.path_join("direct.json"))
	var expected: Dictionary = {}
	if direct.ok and str(direct.value) != "":
		expected = DotAddonApi.parse(FileAccess.get_file_as_string(str(direct.value))).value
	_check(not expected.is_empty() and DotValue.same(expected, shipped),
		"and it is what dot_requires.gd derives in the source project", "%s vs %s" % [expected, shipped])

	var refused := DotAddonApi.new().check({"dot_core": int(shipped.get("dot_core", 0)) + 1})
	_check(not refused.ok and str(refused.error.message).contains("level"),
		"a host whose dot-core is one level short of it is refused in a sentence", str(refused.error.message) if not refused.ok else "accepted")

	_check(FileAccess.file_exists(source.path_join(DotAddonApi.REQUIREMENTS_FILE)) == had_requires,
		"nothing was written into the game's checkout")
	_done()


func _test_floors() -> void:
	_section("a game's requires.floor.json is applied, as package.sh applies it")

	var source := _source(FLOORED_REPO)
	var floor_path := source.path_join(DotAddonApi.FLOOR_FILE)
	if not _check(source != "" and FileAccess.file_exists(floor_path), "%s is here, with a %s" % [FLOORED_REPO, DotAddonApi.FLOOR_FILE]):
		_done()
		return

	var floors: Dictionary = DotAddonApi.parse(FileAccess.get_file_as_string(floor_path), DotAddonApi.FLOOR_FILE).value
	var derived := Pack.derive_requires(source, SCRATCH.path_join("floored.json"))
	var got: Dictionary = {}
	if derived.ok and str(derived.value) != "":
		got = DotAddonApi.parse(FileAccess.get_file_as_string(str(derived.value))).value
	_check(not got.is_empty(), "requires.json is derived for it", str(derived.error) if not derived.ok else "")

	var wrong := PackedStringArray()
	for addon: String in floors:
		if int(got.get(addon, -1)) != int(floors[addon]):
			wrong.append("%s %s, floor %d" % [addon, got.get(addon, "absent"), int(floors[addon])])
	_check(not floors.is_empty() and wrong.is_empty(),
		"every floored addon asks for its floor, not the level it was built against (%d floored)" % floors.size(), ", ".join(wrong))
	_done()


func _test_not_a_project() -> void:
	_section("content that is not a Godot project gets no requires.json")

	var res := Pack.derive_requires("res://content/avatars", SCRATCH.path_join("avatars.json"))
	_check(res.ok and str(res.value) == "", "content/avatars publishes as it did", str(res.error) if not res.ok else str(res.value))
	_check(not FileAccess.file_exists(SCRATCH.path_join("avatars.json")), "and nothing was derived for it")
	_done()


## The payload of a signed manifest, as a Dictionary ({} when unreadable).
func _read_manifest(path: String) -> Dictionary:
	var outer: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not outer is Dictionary:
		return {}
	var payload := str((outer as Dictionary).get("payload", ""))
	# base64url without padding (dot-cloud's envelope), not Marshalls' base64: decoded as base64 it
	# parsed only when the manifest's length was a multiple of three, which lookatme's stopped being.
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
