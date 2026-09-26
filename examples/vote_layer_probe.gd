extends SceneTree

## Loads this deployment's [TmcConfig] the way a host does and runs one real [DotVoteDirector]
## on its server vote, then prints what the ballot did as one JSON line.
##
## [b]A child process[/b], for dot-vote's `examples/layer_probe.gd` reason: `DOT_GAME_VOTE_*`
## and `--game-vote-*` are read from the process's own environment and command line, and
## `selftest`'s "the server vote's own layers reach a running ballot" starts this once per
## layer. The rules are the fixture's `vote.yml` plus whatever the child was started with;
## everything the ballot needs to be driven by hand is set AFTER loading and is none of the
## three settings under test.
##
## [codeblock]
## godot --headless --path . --script res://examples/vote_layer_probe.gd -- [--game-vote-<key>=<value> ...]
## [/codeblock]

# No `CHANNEL`: a probe that prints one line for a suite to read.


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var loaded := TmcConfig.load_dir("res://examples/fixtures")
	if not loaded.ok:
		print(JSON.stringify({"layered": false, "why": str(loaded.error)}))
		quit(1)
		return

	var rules: DotVoteRules = (loaded.value as TmcConfig).vote

	rules.apply_delay_sec = 0.0
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 20.0
	rules.cooldown = 0
	rules.apply = DotVoteRules.Apply.IMMEDIATE

	var choices: Array[DotVoteChoice] = []
	for id in ["a", "b", "c"]:
		choices.append(DotVoteChoice.of(StringName(id), id.capitalize()))

	var source := DotVoteListSource.of(choices)
	var director := DotVoteDirector.new()
	director.rules = rules
	director.source = source
	director.register_service = false
	director.self_advance = false
	director.player_count_fn = func() -> int: return 4
	root.add_child(director)
	await process_frame

	director.begin(&"a")
	source.current = &"a"

	for _i in range(90):
		director.advance(1.0)

	var opened := director.is_voting()
	var offered := opened and director.ballot != null and director.ballot.has_extend()
	var extended_by := -1.0

	if offered:
		var before := director.clock.remaining
		for voter in [&"v1", &"v2", &"v3", &"v4"]:
			var _cast := director.cast_one(voter, DotVoteBallot.EXTEND)
		var _result := director.close_vote()
		extended_by = director.clock.remaining - before

	print(JSON.stringify({
		"layered": true,
		"end_vote": rules.end_vote,
		"include_extend": rules.include_extend,
		"extend_seconds": rules.extend_seconds,
		"opened": opened,
		"extend_offered": offered,
		"extended_by": snappedf(extended_by, 0.01),
	}))
	quit(0)
