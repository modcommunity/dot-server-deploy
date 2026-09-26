extends Node

## A game published from its own repository installs on a server that has never seen it.
##
## The descriptor inside such a pack is written by the game's author, who cannot know the
## address the site gives it (`<their username>/<repo>`) or the version a re-sync claims
## (`1.2.0+r2`). `tools/install_games.gd` stamps both from what it just verified; this
## checks that stamp without a network, because a descriptor that disagrees with its pack
## mounts a path that does not exist and every script in the game is then "not found".
##
##     godot --headless --path . res://examples/install_descriptor.tscn

const Installer := preload("res://tools/install_games.gd")

## Every check below, counted. See docs/testing.md: a section that aborts part-way still
## counts as entered, so the total is the only thing that notices.
const CHECKS := 25

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: PackedStringArray = []


func _ready() -> void:
	_test_stamp()
	_test_refusal()
	_test_template()
	_test_repositories()

	print("")
	print("%d sections, %d completed" % [_entered, _completed])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	if _passed + _failed != CHECKS or _completed != _entered:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _test_stamp() -> void:
	_section("a pack's descriptor is told which pack it is")

	var authored := "\n".join([
		"# my game",
		"name: Crate Rush",
		"content_id: someone/crate-rush",
		"version: 0.0.0",
		"scene: scenes/server.tscn",
		"metadata:",
		"  version: keep-me",
	])

	var got := Installer.stamp_identity(authored, "gamemann/crate-rush", "1.2.0+r2")

	if not _check(got.ok, "the authored descriptor is stamped", str(got.error)):
		_done()
		return

	var tree := TmcYaml.parse(str(got.value), "<stamped>").value as Dictionary

	_check(str(tree.get("content_id")) == "gamemann/crate-rush",
		"content_id is the id that was installed, not the one the author guessed")
	_check(str(tree.get("version")) == "1.2.0+r2",
		"version is the version that was installed, re-sync suffix and all")
	_check(str(tree.get("kind")) == "pack",
		"kind is added when the author left it out")
	_check(str(TmcYaml.at(tree, "metadata.version", "")) == "keep-me",
		"an indented key of the same name is left alone")
	_check(str(got.value).contains("# my game"),
		"the author's comments survive, because an operator edits this file next")
	_done()


func _test_refusal() -> void:
	_section("a descriptor the reader cannot parse is refused, not written")

	var got := Installer.stamp_identity("name: [unterminated", "a/b", "1.0.0")

	_check(not got.ok, "a malformed descriptor is an error rather than a file on disk")
	_done()


func _test_template() -> void:
	_section("an empty descriptor still comes out whole")

	var got := Installer.stamp_identity("", "a/b", "2.0.0")

	if not _check(got.ok, "stamping nothing succeeds", str(got.error)):
		_done()
		return

	var tree := TmcYaml.parse(str(got.value), "<empty>").value as Dictionary

	_check(str(tree.get("content_id")) == "a/b", "content_id is written")
	_check(str(tree.get("version")) == "2.0.0", "version is written")
	_check(str(tree.get("kind")) == "pack", "kind is written")
	_done()


## A game repository's own descriptor, against the one this deployment carries.
##
## The same game is described twice: once in its repository (travels in the pack a site
## publishes) and once under content/ here (for `./server pack`). Two copies of one fact
## is the drift this family keeps finding, so every field that decides what RUNS must
## agree. The sibling checkout is read where bootstrap.sh puts it; a box without it
## skips, visibly, rather than failing on something it was never given.
const REPOSITORIES := {
	"game-arena": "arena",
	"game-simple-lobby": "lobby",
	"game-playground": "playground",
	"game-g2gfast": "g2gfast",
	"game-hungario": "hungry_classic",
	"mg-smash-copter": "smash",
	"mg-buses-from-hell": "buses",
}

const MUST_AGREE := ["name", "scene", "client_scene", "module"]


func _test_repositories() -> void:
	_section("each game repository's descriptor agrees with this deployment's")

	var root := ProjectSettings.globalize_path("res://").rstrip("/").get_base_dir()

	for repo in REPOSITORIES:
		var theirs_path := root.path_join(repo).path_join("game.yml")
		var ours_path := "res://content/%s/game.yml" % REPOSITORIES[repo]

		if not FileAccess.file_exists(theirs_path):
			_check(true, "%s: no sibling checkout, skipped" % repo)
			_check(true, "%s: (skipped)" % repo)
			continue

		var text := FileAccess.get_file_as_string(theirs_path)
		var stamped := Installer.stamp_identity(text, "someone/%s" % repo, "9.9.9")

		if not _check(stamped.ok, "%s: its game.yml parses and stamps" % repo, str(stamped.error)):
			_check(false, "%s: fields compared" % repo)
			continue

		var theirs := TmcYaml.parse(str(stamped.value), theirs_path).value as Dictionary
		var ours := TmcYaml.parse_file(ours_path).value as Dictionary
		var differ := PackedStringArray()

		for key in MUST_AGREE:
			if str(theirs.get(key, "")) != str(ours.get(key, "")):
				differ.append("%s: %s vs %s" % [key, theirs.get(key, ""), ours.get(key, "")])

		_check(differ.is_empty(),
			"%s: name, scene, client_scene and module match content/%s" % [repo, REPOSITORIES[repo]],
			"; ".join(differ))

	_done()


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
