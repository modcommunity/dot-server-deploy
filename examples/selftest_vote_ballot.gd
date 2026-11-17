class_name SelftestVoteBallot
extends RefCounted

## What reaches the game vote ballot: the layers and the change limit. Run by `selftest.gd`, which keeps the counters: every check goes through its `_check`.

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


func add_child(node: Node) -> void:
	t.add_child(node)


## `end_vote`, `include_extend` and `extend_seconds` through `DOT_GAME_VOTE_*` and `--game-vote-*`,
## each in a child process, change what the server vote's ballot does. `_test_vote` checks one of
## the six as a parsed value; this asks the ballot.
func _test_vote_layers_reach_a_ballot() -> void:
	_section("the server vote's own layers reach a running ballot")

	var project := ProjectSettings.globalize_path("res://")

	var probe := func(extra: PackedStringArray, env: Dictionary) -> Dictionary:
		for key: String in env:
			OS.set_environment(key, env[key])
		var args := PackedStringArray([
			"--headless", "--path", project, "--script", "res://examples/vote_layer_probe.gd", "--",
		])
		args.append_array(extra)
		var out := []
		var _code := OS.execute(OS.get_executable_path(), args, out, true)
		for key: String in env:
			OS.unset_environment(key)
		var found := {}
		for line: String in "\n".join(PackedStringArray(out)).split("\n"):
			var trimmed := line.strip_edges()
			if trimmed.begins_with("{"):
				var parsed: Variant = JSON.parse_string(trimmed)
				if parsed is Dictionary:
					found = parsed
		return found

	var control: Dictionary = probe.call(PackedStringArray(), {})
	_check(
		control.get("opened") == true and control.get("extend_offered") == true
			and is_equal_approx(float(control.get("extended_by", -1.0)), 600.0),
		"with neither layer, the fixture's ballot opens, offers Extend, and adds 600 s",
		str(control)
	)

	var cases := [
		["end_vote", "false", "opened", false],
		["include_extend", "false", "extend_offered", false],
		["extend_seconds", "90", "extended_by", 90.0],
	]

	for case: Array in cases:
		var key: String = case[0]

		for layer in ["DOT_GAME_VOTE_*", "--game-vote-*"]:
			var extra := PackedStringArray()
			var env := {}

			if layer == "DOT_GAME_VOTE_*":
				env["DOT_GAME_VOTE_" + key.to_upper()] = case[1]
			else:
				extra.append("--game-vote-%s=%s" % [key, case[1]])

			var got: Dictionary = probe.call(extra, env)
			var seen: Variant = got.get(case[2])
			var want: Variant = case[3]
			var same: bool = is_equal_approx(float(seen), float(want)) \
				if want is float else seen == want
			_check(
				got.get("layered") == true and same,
				"%s from %s: the ballot's %s is %s" % [key, layer, case[2], str(want)],
				str(got)
			)

	_done()


func _test_vote_limit_waits_for_a_change() -> void:
	_section("the game vote's limit waits for a change under way")

	var rules := DotVoteRules.new()
	rules.enabled = true
	rules.duration_sec = 10.0
	rules.empty_choice = DotVoteRules.EmptyChoice.RANDOM

	var votes := TmcVote.new()
	votes.name = "LimitVotes"
	votes.director = DotVoteDirector.new()
	votes.director.name = "Director"
	votes.director.rules = rules
	votes.director.source = DotVoteListSource.of_ids(["standin", "next"])
	votes.director.register_service = false
	votes.director.begin_on_apply = false
	votes.director.auto_apply = false
	votes._wire()
	# After _wire, which points the count at the server there is not.
	votes.director.player_count_fn = func() -> int: return 0
	votes.director.busy_fn = func() -> bool: return false
	votes.set_physics_process(false)
	add_child(votes)
	votes.add_child(votes.director)

	var under_way := [true]
	votes.change_under_way_fn = func() -> bool: return under_way[0]

	var due: Array[StringName] = []
	votes.director.change_due.connect(
		func(id: StringName, _choice: DotVoteChoice) -> void: due.append(id)
	)

	votes.director.begin(&"standin")

	for i in 120:
		votes._advance_director(1.0 / 6.0)

	_check(
		due.is_empty() and not votes.director.clock.is_expired(),
		"twenty seconds of a ten second limit pass with a change under way and nothing is drawn (%s)" % [due],
		"the limit fired on an empty server mid-change and changed the game away from the one elected"
	)

	under_way[0] = false

	for i in 120:
		votes._advance_director(1.0 / 6.0)

	_check(
		due.size() == 1,
		"and once it has landed the limit is the limit again (%s)" % [due]
	)

	votes.free()
	_done()


## The game vote's HUD: what the template asks the shell to play, and what the shell does with a
## notice.
