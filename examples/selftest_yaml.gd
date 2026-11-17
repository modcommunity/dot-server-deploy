class_name SelftestYaml
extends RefCounted

## The YAML reader: scalars, structure and what it refuses. Run by `selftest.gd`, which keeps the counters: every check goes through its `_check`.

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


func _parse(text: String) -> Dictionary:
	return t._parse(text)


func _test_yaml_scalars() -> void:
	_section("YAML scalars")

	var tree := _parse("""
# a comment
name: "TMC Test Server"
bare: a bare string
players: 64
ratio: 0.75
on_flag: true
off_flag: no
empty:
url: http://localhost:8000
hashed: "Bob's #1 server"   # a trailing comment
""")

	_check(String(tree.get("name", "")) == "TMC Test Server", "a quoted string")
	_check(String(tree.get("bare", "")) == "a bare string", "a bare string with spaces")
	_check(tree.get("players") is int and int(tree["players"]) == 64, "an integer stays one")
	_check(tree.get("ratio") is float, "and a float stays a float")
	_check(tree.get("on_flag") == true, "true is a bool")
	_check(tree.get("off_flag") == false, "and so is 'no'")
	_check(String(tree.get("empty", "x")) == "", "a key with nothing after it is empty")

	# The rule that makes a URL parse: a colon separates a key only when a space or the
	# end of the line follows it. Without it `http://localhost:8000` is a key called
	# `url: http` with an unparseable value.
	_check(
		String(tree.get("url", "")) == "http://localhost:8000",
		"a URL keeps its colons (%s)" % tree.get("url", "")
	)

	# A `#` inside quotes is data. Without this, a server named "Bob's #1" is named
	# "Bob's — which is a name nobody typed and no error anywhere.
	_check(
		String(tree.get("hashed", "")) == "Bob's #1 server",
		"a # inside quotes is not a comment (%s)" % tree.get("hashed", "")
	)
	_done()


func _test_yaml_structure() -> void:
	_section("YAML structure")

	var tree := _parse("""
backend:
  type: rest
  verify:
    type: jwt
    key: secret
tags:
  - pvp
  - modded
flow: [kick, ban, mute]
groups:
  admin:
    permissions:
      - kick
      - ban
  moderator:
    permissions: [kick]
""")

	_check(
		String(TmcYaml.at(tree, "backend.type", "")) == "rest",
		"a nested map, by dotted path"
	)
	_check(
		String(TmcYaml.at(tree, "backend.verify.type", "")) == "jwt",
		"nested twice"
	)
	_check(
		TmcYaml.at(tree, "backend.missing.deep", "fallback") == "fallback",
		"and a missing path is the fallback, not a crash"
	)

	var tags: Variant = tree.get("tags")
	_check(tags is Array and (tags as Array).size() == 2, "a block sequence")
	_check(tags is Array and String((tags as Array)[0]) == "pvp", "with its values")

	var flow: Variant = tree.get("flow")
	_check(flow is Array and (flow as Array).size() == 3, "a flow sequence on one line")

	var permissions: Variant = TmcYaml.at(tree, "groups.admin.permissions")
	_check(
		permissions is Array and (permissions as Array).size() == 2,
		"a sequence two levels down"
	)
	_check(
		(TmcYaml.at(tree, "groups.moderator.permissions") as Array).size() == 1,
		"and a flow sequence beside a block one"
	)
	_done()


## What it refuses, and that it says which line. Every one of these is either a mistake or a feature
## this format does not have, and both are better as an error at boot than as a value nobody
## intended.


## What it refuses, and that it says which line. Every one of these is either a mistake or a feature
## this format does not have, and both are better as an error at boot than as a value nobody
## intended.
func _test_yaml_refusals() -> void:
	_section("YAML refusals")

	for entry in [
		["tabs", "a:\n\tb: 1", "tab"],
		["a duplicate key", "a: 1\na: 2", "duplicate"],
		["an anchor", "a: &anchor 1", "anchor"],
		["an alias", "a: *anchor", "anchor"],
		["a tag", "a: !!str 1", "anchor"],
		["a block scalar", "a: |", "anchor"],
		["an unclosed flow mapping", "a: {b: 1", "same line"],
		["a flow mapping entry with no colon", "a: {b}", "flow mapping"],
		["a duplicate key in a flow mapping", "a: {b: 1, b: 2}", "duplicate"],
		["a document marker", "---\na: 1", "document marker"],
		["an unclosed flow sequence", "a: [1, 2", "same line"],
		["a key with no colon", "just a line", "expected 'key: value'"],
	]:
		var result := TmcYaml.parse(String(entry[1]), "<test>")
		var message := str(result.error) if not result.ok else ""

		_check(
			not result.ok and message.contains(String(entry[2])),
			"%s is refused" % entry[0],
			"got: %s" % (message if message != "" else "accepted")
		)

	# dot-core v0.1.46 reads one-line flow mappings, so an inline mapping is a value, not a refusal.
	var flow := TmcYaml.parse("a: {map: x, mode: ctf}", "<test>")
	_check(
		flow.ok and TmcYaml.at(flow.value, "a.map") == "x" and TmcYaml.at(flow.value, "a.mode") == "ctf",
		"an inline mapping is read as a mapping",
		str(flow.error) if not flow.ok else ""
	)

	var located := TmcYaml.parse("a: 1\nb: 2\n\tc: 3", "cfg/server.yml")
	_check(
		not located.ok and str(located.error).contains("cfg/server.yml:3"),
		"and the refusal names the file and the line (%s)" % str(located.error)
	)
	_done()
