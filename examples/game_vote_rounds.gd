extends Node
# [b]Nothing preloaded out of a game, because no game is in this build.[/b] Both games are
# delivered packs; each one's match is reached through the module's `game` and its
# `match_node`, a dot-match DotMatch, which this build does carry.

## The game vote's `time_up: finish_round`, through REAL round ends in two delivered games.
##
## [codeblock]
## godot --headless --path . res://examples/game_vote_rounds.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs `dist/tmc/smash`, `dist/tmc/prophunt` and
## `dist/tmc/prophunt_maps` (`./server pack <id> --source games/<repo>`); says "skipped"
## without them.
##
## [b]Why this exists.[/b] `game_vote_all` asserts that the game vote knows whether each game
## reports rounds, and `multigame` that the rule reads right, but neither ever lets the game
## vote's clock run out while a round is being played: a delivered game's rounds are minutes
## long. Before TmcVote forwarded a game's `round_ended`, `finish_round` changed the game at
## the expiry, mid-round, in every game, and every suite passed. Here each game's round is
## shortened through its own cvars (`fixtures/game_vote_rounds/content.yml`, the way an owner
## sets them), a real shell votes the other game in, and the suite watches every physics frame
## from the expiry: the server stays on the game until its match ends the round, and changes
## after that.
##
## [b]Two round shapes.[/b] Smash Copter is a survival phase, a short warning and then a
## showdown, ending when one side is left or the showdown runs out; Prop Hunt is a hiding
## phase, then a hunt that ends when the props are found or its own clock runs out. Smash
## votes Prop Hunt in, and Prop Hunt votes Smash back, so both are switched into and out of
## under `finish_round`.

const CONFIG := "res://examples/fixtures/game_vote_rounds"
const CONTENT := "res://content"
const DATA := "user://tmc_game_vote_rounds"
const SHELL := "res://client/shell.tscn"

const ORDER := ["smash", "prophunt"]

## The packs both games need, prophunt's maps among them.
const NEEDS := ["tmc/smash", "tmc/prophunt", "tmc/prophunt_maps"]

## Checks per game section, whichever branch it takes.
const PER_GAME := 9

## Every check this suite runs: booting (3), each game, the way back (2), the two totals.
const CHECKS := 3 + PER_GAME * 2 + 2 + 2

## dot-match's `State.LIVE`: the round is being played.
const LIVE := DotMatch.State.LIVE

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _shell: Node = null

## Ticks (msec) of every `round_ended` the running game's match emitted, this game only.
var _round_ends: Array[int] = []

## The match being listened to.
var _match: DotMatch = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: the game vote's finish_round through real round ends")

	for id: String in NEEDS:
		if not FileAccess.file_exists("res://dist/%s/manifest.json" % id):
			print("skipped: dist/%s is not published here" % id)
			print("  ./server pack smash --source games/mg-smash-copter")
			print("  ./server pack prophunt_maps --source games/mg-prop-hunt-maps")
			print("  ./server pack prophunt --source games/mg-prop-hunt")
			get_tree().quit(0)
			return

	DotPaths.remove_tree(DATA)

	if await _boot():
		for i in ORDER.size():
			await _test_game(ORDER[i], ORDER[(i + 1) % ORDER.size()])

		await _test_back_at_the_start()

	await _teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered]
	)
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


# --- The harness ------------------------------------------------------------

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


func _skip(count: int, why: String) -> void:
	for i in count:
		_check(false, "skipped: %s" % why)


func _server() -> DotServer:
	if _host == null or not is_instance_valid(_host):
		return null
	return _host.server as DotServer


func _votes() -> TmcVote:
	return _host.votes as TmcVote if _host != null else null


func _director() -> DotVoteDirector:
	var votes := _votes()
	return votes.director if votes != null else null


func _link() -> DotClientLink:
	return _shell.link as DotClientLink if _shell != null else null


func _overlay() -> TmcNoticeOverlay:
	return _shell.notices as TmcNoticeOverlay


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _at_game(game_id: String) -> bool:
	var current := _server().games.current()
	return current != null and current.game_id == game_id \
		and _server().games.phase == DotGameManager.Phase.IDLE


## The server has started leaving [param game_id]: another game current, or a change under way.
func _leaving(game_id: String) -> bool:
	var current := _server().games.current()
	return current == null or current.game_id != game_id \
		or _server().games.phase != DotGameManager.Phase.IDLE


func _client_in(game_id: String) -> bool:
	var link := _link()
	return (
		link != null and link.server_game_id == game_id
		and link.phase == DotClientLink.Phase.PLAYING
		and link._scene_instance != null and is_instance_valid(link._scene_instance)
		and _server().playing_sessions().size() == 1
	)


## The running game's match: the first loaded module whose `game` has a `match_node`.
func _find_match() -> DotMatch:
	for name in _server().modules.loaded_names():
		var module := _server().modules.get_module(name)
		var world: Variant = module.get("game") if module != null else null
		var node: Variant = (world as Object).get("match_node") if world is Object else null

		if node is DotMatch:
			return node as DotMatch

	return null


## The running game's own account of itself, for a failure's detail.
func _world_says() -> String:
	for name in _server().modules.loaded_names():
		var module := _server().modules.get_module(name)
		var world: Variant = module.get("game") if module != null else null

		if world is Object and (world as Object).has_method("describe") and (world as Object).get("match_node") != null:
			return str((world as Object).call("describe"))

	return "{}"


func _match_state() -> String:
	if _match == null or not is_instance_valid(_match):
		return "no match"
	return DotMatch.State.keys()[_match.state]


func _panel_index(id: StringName) -> int:
	var panel := _overlay().ballot(TmcVote.BALLOT_TOPIC)

	if panel == null or not panel.is_open():
		return -1

	for i in panel.option_count():
		if StringName(str(panel._options[i]["id"])) == id:
			return i

	return -1


func _on_round_ended(_number: int, _winner: int, _outcome: int) -> void:
	_round_ends.append(Time.get_ticks_msec())


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	_section("booting")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.name = "Host"
	_host.auto_start = false
	add_child(_host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not _check(started.ok, "the host boots", str(started.error)):
		_skip(2, "the host did not boot")
		_done()
		return false

	_check(
		_director() != null and _director().rules.time_up == DotVoteRules.TimeUp.FINISH_ROUND
			and _director().rules.apply == DotVoteRules.Apply.END_OF_TIME,
		"with the game vote on finish_round, applied at the end of time",
		"time_up %d, apply %d" % [_director().rules.time_up, _director().rules.apply] if _director() != null else "no game vote"
	)

	_shell = (load(SHELL) as PackedScene).instantiate()
	_shell.name = "Shell"
	add_child(_shell)

	await get_tree().process_frame
	await get_tree().process_frame

	# Content from this project's own `dist/`, as `game_vote_all` does.
	_shell._ensure_cloud()
	_shell._cloud.http_base_urls = PackedStringArray([
		ProjectSettings.globalize_path("res://dist")
	])

	var sink := _overlay().audio.sink as DotAudioSinkNull
	if sink != null:
		_overlay().audio.played.connect(
			func(_id: StringName, handle: int, _why: StringName) -> void:
				if handle > 0:
					sink.finish(handle)
		)

	_shell._connect_to("127.0.0.1:%d" % int(_host.config.server.port))

	var first: String = ORDER[0]
	_check(
		await _until(func() -> bool: return _at_game(first) and _client_in(first), 60.0),
		"a real shell joins %s" % first
	)
	_done()
	return true


func _teardown() -> void:
	if _shell != null and is_instance_valid(_shell):
		if _shell.link != null and is_instance_valid(_shell.link):
			_shell.link.disconnect_from_server()

		remove_child(_shell)
		_shell.queue_free()
		_shell = null
		await get_tree().process_frame

	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")

		remove_child(_host)
		_host.free()
		_host = null

		await get_tree().physics_frame
		await get_tree().physics_frame


# --- One game ---------------------------------------------------------------

func _test_game(game_id: String, next: String) -> void:
	_section("%s: the time limit runs out mid-round, and %s waits for the round" % [game_id, next])

	var here := await _until(func() -> bool: return _at_game(game_id) and _client_in(game_id), 60.0)
	if not _check(here, "the server runs %s with the client in it" % game_id):
		_skip(PER_GAME - 1, "%s never ran" % game_id)
		_done()
		return

	# The game's own match, heard directly: the suite's evidence of a round end, beside (not
	# through) the forwarding under test.
	_match = _find_match()
	_round_ends.clear()
	if _match != null:
		_match.round_ended.connect(_on_round_ended)
	_check(_match != null, "its match is found (%s)" % _match_state())

	# Let TmcVote's tree scan find the game's own vote and hear its rounds.
	await _until(func() -> bool: return _director().round_based, 3.0)
	_check(_director().round_based, "the game vote hears %s's rounds" % game_id,
		"round_based is off: finish_round has no round to wait for")

	# The time-limit ballot; the player puts the next game on it and clicks it.
	_link().send_chat("/%snominate %s" % [TmcVote.COMMAND_PREFIX, next])
	var drawn := await _until(
		func() -> bool: return _panel_index(StringName(next)) >= 0,
		_director().clock.remaining + 15.0
	)
	if drawn:
		_overlay().ballot(TmcVote.BALLOT_TOPIC).choose(_panel_index(StringName(next)))
	var decided := await _until(
		func() -> bool: return _director().pending_id() == StringName(next), 20.0
	)
	_check(
		drawn and decided and _at_game(game_id),
		"the time-limit ballot elects %s, and it waits for the clock" % next,
		"drawn %s, pending '%s', %s" % [drawn, _director().pending_id(), _director().describe_lines()[0]]
	)

	# The clock runs out. A round ended between the ballot and now does not count: the round
	# the change waits for is the one in progress at the expiry.
	var expired := await _until(func() -> bool: return _director().clock.is_expired(), 60.0)
	var expired_at := Time.get_ticks_msec()
	var state_at_expiry := _match_state()
	var ends_before := _round_ends.size()
	_check(
		expired and _match != null and is_instance_valid(_match) and _match.state == LIVE,
		"the game vote's clock runs out while a %s round is being played" % game_id,
		"expired %s, match %s, %s" % [expired, state_at_expiry, _world_says()]
	)
	_check(
		_director().is_finishing_round(),
		"and the game vote says it is playing the round out",
		_director().describe_lines()[0]
	)

	# Every frame from the expiry: still on this game until the match ends the round.
	var changed := await _until(func() -> bool: return _leaving(game_id), 120.0)
	var changed_at := Time.get_ticks_msec()
	var round_end_at := _round_ends[ends_before] if _round_ends.size() > ends_before else -1
	_check(
		changed and round_end_at >= 0 and changed_at >= round_end_at,
		"%s stays on until its round ends (held %.1f s past the time limit)" % [
			game_id, (changed_at - expired_at) / 1000.0
		],
		"changed %s; round end %s ms after expiry; change %d ms after expiry" % [
			changed, str(round_end_at - expired_at) if round_end_at >= 0 else "never",
			changed_at - expired_at,
		]
	)
	_check(
		changed and round_end_at >= 0 and changed_at - round_end_at < 3000,
		"and changes as that round ends, not later",
		"%d ms after the round end" % (changed_at - round_end_at if round_end_at >= 0 else -1)
	)

	if _match != null and is_instance_valid(_match) and _match.round_ended.is_connected(_on_round_ended):
		_match.round_ended.disconnect(_on_round_ended)
	_match = null

	var arrived := await _until(func() -> bool: return _at_game(next) and _client_in(next), 60.0)
	_check(arrived, "the server plays %s and the client follows" % next)
	_done()


func _test_back_at_the_start() -> void:
	var first: String = ORDER[0]
	_section("back to %s" % first)

	_check(_at_game(first) and _client_in(first), "the server is running %s again, the client in it" % first)
	_check(
		_server().state == DotServer.State.RUNNING and _server().sessions().size() == 1,
		"after %d changes under finish_round the server is still serving its one player" % ORDER.size()
	)
	_done()
