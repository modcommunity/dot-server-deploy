extends Node

## Everything this repository adds, checked without starting a server.
##
## [codeblock]
## godot --headless --path . res://examples/selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## The YAML reader, the config translation, the permission translation and the content
## index. `./server check` is the other half — it boots a real server, loads the lobby and
## shuts down — and between them they cover everything before a client connects.

const CFG := "res://examples/fixtures"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy")

	_test_yaml_scalars()
	_test_yaml_structure()
	_test_yaml_refusals()
	_test_config()
	_test_admins()
	_test_content()
	_test_vote()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


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


func _parse(text: String) -> Dictionary:
	var result := TmcYaml.parse(text, "<test>")
	return result.value as Dictionary if result.ok else {}


# --- Sections --------------------------------------------------------------

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


## What it refuses, and that it says which line.
##
## Every one of these is either a mistake or a feature this format does not have, and both
## are better as an error at boot than as a value nobody intended.
func _test_yaml_refusals() -> void:
	_section("YAML refusals")

	for entry in [
		["tabs", "a:\n\tb: 1", "tab"],
		["a duplicate key", "a: 1\na: 2", "duplicate"],
		["an anchor", "a: &anchor 1", "anchor"],
		["an alias", "a: *anchor", "anchor"],
		["a tag", "a: !!str 1", "anchor"],
		["a block scalar", "a: |", "anchor"],
		["an inline mapping", "a: {b: 1}", "inline mapping"],
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

	var located := TmcYaml.parse("a: 1\nb: 2\n\tc: 3", "cfg/server.yml")
	_check(
		not located.ok and str(located.error).contains("cfg/server.yml:3"),
		"and the refusal names the file and the line (%s)" % str(located.error)
	)
	_done()


func _test_config() -> void:
	_section("the configuration")

	var loaded := TmcConfig.load_dir(CFG)

	if not _check(loaded.ok, "the fixture config loads", str(loaded.error)):
		_done()
		return

	var config := loaded.value as TmcConfig

	# The operator's own names, on dot-server's own settings. Two vocabularies is a cost
	# and it is paid deliberately; what must not happen is a key that quietly reaches
	# neither.
	_check(config.server.hostname == "Fixture Server", "sv_name reaches hostname")
	_check(config.server.port == 27099, "net_port reaches the port (%d)" % config.server.port)
	_check(
		config.server.bind_address == "127.0.0.1",
		"net_bind_ip reaches the bind address"
	)
	_check(config.server.max_players == 12, "sv_maxplayers reaches max_players")
	_check(config.server.tickrate == 30, "sv_tickrate reaches the tickrate")
	_check(
		config.net.per_client_budget == 500000,
		"net_max_bps reaches the netcode's per-client budget (%d)"
			% config.net.per_client_budget
	)
	_check(config.public_address == "203.0.113.7", "net_public_ip is kept for the join line")
	_check(config.initial_game == "lobby", "sv_game names the boot game")
	_check(
		Array(config.server.tags) == ["fixture", "test"],
		"sv_tags becomes a list (%s)" % [config.server.tags]
	)

	# A name nothing recognises is handed to the console rather than refused here: modules
	# register cvars this layer cannot know about at read time, so a name-based guess would
	# refuse every setting a game contributed.
	_check(
		config.console_lines.has("room_pellets 400"),
		"an unrecognised setting is queued for the console (%s)" % [config.console_lines]
	)

	_check(config.groups.size() == 2, "groups.yml is read (%d)" % config.groups.size())
	_check(config.users.size() == 2, "and permissions.yml (%d)" % config.users.size())
	_check(
		String(TmcYaml.at(config.auth, "backend.type", "")) == "rest",
		"and auth.yml is kept whole for whoever reads it"
	)

	var missing := TmcConfig.load_dir("res://examples/fixtures/nothing-here")
	_check(
		missing.ok,
		"a directory with no files is not an error",
		"a first run has none of them"
	)
	_done()


func _test_admins() -> void:
	_section("groups and permissions")

	var loaded := TmcConfig.load_dir(CFG)
	var config := loaded.value as TmcConfig
	var built := TmcAdmins.from(config.groups, config.users)

	if not _check(built.ok, "the permission source builds", str(built.error)):
		_done()
		return

	var admins := built.value as TmcAdmins

	_check(admins.user_count() == 2, "with both users")
	_check(
		Array(admins.group_names()) == ["admin", "owner"],
		"and both groups (%s)" % [admins.group_names()]
	)

	var owner := admins.lookup(_identity("boss"))
	_check(owner.ok, "an owner is found")
	_check(
		owner.ok and PackedStringArray(owner.value["flags"]).has(DotAdminFlags.ROOT),
		"and is_root becomes the root flag",
		"expanding it into a list here would stop covering a flag added later"
	)
	_check(owner.ok and int(owner.value["immunity"]) == 100, "with its immunity")

	var admin := admins.lookup(_identity("helper"))
	_check(admin.ok, "a group member is found")
	_check(
		admin.ok and PackedStringArray(admin.value["flags"]).has("kick"),
		"and holds the group's flags"
	)
	_check(
		admin.ok and PackedStringArray(admin.value["flags"]).has("slay"),
		"plus their own extra one",
		"sources merge rather than first-match-wins, and so does a user's own list"
	)
	_check(
		admin.ok and int(admin.value["immunity"]) == 42,
		"and an explicit immunity beats the group's (%d)"
			% (int(admin.value["immunity"]) if admin.ok else -1)
	)

	# Case-insensitive, because an operator typing a name into a config file and a player
	# typing one into a client will not agree about capitalisation.
	_check(admins.lookup(_identity("BOSS")).ok, "a name matches whatever its case")
	_check(not admins.lookup(_identity("nobody")).ok, "and a stranger is not listed")
	_check(not admins.lookup(null).ok, "nor is a null identity, which is not a crash")
	_done()


## Something with the shape dot-server hands a source: `uid`, `username`, `display_name`.
func _identity(name: String) -> Object:
	var identity := DotGuestIdentity.new()
	identity.uid = "guest:%s" % name
	identity.username = name
	identity.display_name = name
	return identity


func _test_content() -> void:
	_section("the content index")

	var scanned := TmcContent.scan("res://examples/fixtures/content")

	if not _check(scanned.ok, "the fixture content scans", str(scanned.error)):
		_done()
		return

	var content := scanned.value as TmcContent

	_check(content.games.size() == 2, "two games (%d)" % content.games.size())
	_check(content.default_game == "second", "the one marked default is the default")
	_check(
		content.skipped.size() == 1,
		"a directory with no game.yml is skipped and reported (%s)" % [content.skipped]
	)

	var builtin := content.find("first")
	_check(builtin != null, "a builtin game is indexed")
	_check(
		builtin != null and builtin.manifest_url == "",
		"with no manifest, which is what makes it builtin"
	)
	_check(
		builtin != null and builtin.client_scene == "",
		"and no client scene",
		"DotClientLink refuses every absolute res:// path outside dot-cloud's mount, so "
		+ "naming one has the client refuse it and be timed out in LOADING"
	)
	_check(
		builtin != null and builtin.display_name == "The First",
		"and the name from its game.yml"
	)
	_check(
		builtin != null and String(builtin.metadata.get("module", "")) != "",
		"and the module it names"
	)

	# The refusal the trap above deserves. A builtin game that named a client scene would
	# produce a connection that appears to work and silently does not.
	var bad := TmcContent.scan("res://examples/fixtures/bad-content")
	_check(
		not bad.ok and str(bad.error).contains("client_scene"),
		"a builtin game that names a client_scene is refused (%s)" % str(bad.error)
	)

	var absent := TmcContent.scan("res://examples/fixtures/nothing-here")
	_check(
		not absent.ok,
		"and a missing content directory is an error, not an empty list",
		"a server with no content is legitimate; a missing directory is a typo"
	)
	_done()


func _test_vote() -> void:
	_section("voting for the next game")

	var loaded := TmcConfig.load_dir(CFG)

	if not _check(loaded.ok, "the fixture config loads", str(loaded.error)):
		_done()
		return

	var config := loaded.value as TmcConfig

	_check(config.vote.enabled, "vote.yml turns voting on")
	_check(
		Array(config.vote_exclude) == ["lobby", "playground"],
		"and names the games that are never on a ballot (%s)" % [config.vote_exclude],
		"which is TMC's question rather than dot-vote's: a lobby is not a game"
	)

	# Every enum written by NAME. A config file full of enum indices is one nobody can
	# read or diff, and renumbering an enum would silently change how a server counts.
	_check(
		config.vote.method == DotVoteRules.Method.INSTANT_RUNOFF,
		"`method: instant_runoff` reaches the counting method"
	)
	_check(
		config.vote.tie_break == DotVoteRules.TieBreak.LEAST_RECENTLY_PLAYED,
		"in any case and with dashes (`LEAST-RECENTLY-PLAYED`)"
	)
	_check(
		config.vote.fill == DotVoteRules.Fill.WEIGHTED
			and config.vote.apply == DotVoteRules.Apply.IMMEDIATE
			and config.vote.trigger == DotVoteRules.Trigger.RTV_ONLY,
		"and so do fill, apply and trigger"
	)

	_check(
		is_equal_approx(config.vote.duration_sec, 900.0)
			and is_equal_approx(config.vote.rtv_fraction, 0.75),
		"numbers are coerced through the property's own type"
	)
	_check(
		config.vote.max_options == 4 and config.vote.nomination_slots == 2,
		"and so are integers"
	)

	var marks := config.vote.warn_marks()
	_check(
		marks.size() == 2 and is_equal_approx(marks[0], 120.0),
		"the warning marks parse out of a quoted list (%s)" % [marks]
	)

	_check(
		config.vote.validate().ok,
		"the fixture's rules validate",
		str(config.vote.validate().error)
	)

	# Reported in the same boot report as a typo in server.yml, and never fatal.
	var reported := false

	for entry in config.unknown:
		if entry.contains("vote_nonsense"):
			reported = true

	_check(
		reported,
		"an unknown key in vote.yml is reported rather than silently ignored (%s)"
			% [config.unknown],
		"a key ignored AND not reported is the worst of both: the operator believes "
		+ "it took effect"
	)

	_done()
