extends Node

## The game vote on a REAL shell's HUD, over a REAL socket.
##
## [codeblock]
## godot --headless --path . res://examples/shell_notice.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]Why a suite of its own.[/b] Three halves meet here and each has its own tests: dot-vote
## counts the countdown, dot-server carries a [DotNotice] across a socket (its
## `signon_revision` suite), and `selftest` checks the overlay draws and plays what it is
## handed. None of them can see whether the countdown a director emits becomes a line on
## the screen of a client the SERVER admitted — the host's wiring, the shell's wiring and
## the RPC routing between them, which is the family's "two ends that never met" in its
## plainest form. `multigame` hears the server's side with no client; `reconnect` has a
## client and no vote.
##
## Headless, so the overlay's sounds go to dot-audio's null sink, which records what it
## would have played. That is what "the cue was played" means here, and it is the real
## catalogue, cooldowns and concurrency caps in front of it — see dot-audio's CLAUDE.md.

const CONFIG := "res://examples/fixtures/shell_notice"
const CONTENT := "res://content"
const DATA := "user://tmc_shell_notice"
const SHELL := "res://client/shell.tscn"

## How many checks a clean run makes. See docs/testing.md: a section that aborts after it
## announced itself satisfies the section counter, and only a total can see it.
const CHECKS := 24

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _shell: Node = null
var _port := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: the game vote on the shell's HUD")

	DotPaths.remove_tree(DATA)

	if await _boot():
		if await _test_connect():
			await _test_the_countdown()
			await _test_the_ballot()
			await _test_a_cancelled_countdown()
			await _test_a_line_runs_out()
			await _test_leaving_takes_it_down()

	await _teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"and made every check it has (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a check that never ran is not a check that passed"
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


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _server() -> DotServer:
	if _host == null or not is_instance_valid(_host):
		return null
	return _host.server as DotServer


func _director() -> DotVoteDirector:
	var votes: TmcVote = _host.votes if _host != null else null
	return votes.director if votes != null else null


func _overlay() -> TmcNoticeOverlay:
	return _shell.notices as TmcNoticeOverlay


func _line() -> String:
	return _overlay().line_text(TmcVote.NOTICE_TOPIC)


func _played(id: StringName) -> int:
	var sink := _overlay().audio.sink as DotAudioSinkNull
	return sink.count_of(id) if sink != null else -1


# --- Boot ------------------------------------------------------------------

func _boot() -> bool:
	_section("booting")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.name = "Host"
	_host.auto_start = false
	add_child(_host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not _check(started.ok, "the host boots", str(started.error)):
		_done()
		return false

	_port = int(_host.config.server.port)

	_check(_director() != null, "with the game vote installed", "vote.yml is off")

	_shell = (load(SHELL) as PackedScene).instantiate()
	_shell.name = "Shell"
	add_child(_shell)

	# The shell scopes its own MultiplayerAPI and signs in before it dials anything.
	await get_tree().process_frame
	await get_tree().process_frame

	# Content from this project's own `dist/`, for the reason `reconnect` gives: the export's
	# content.json names the page's origin, which a headless run cannot reach.
	_shell._ensure_cloud()
	_shell._cloud.http_base_urls = PackedStringArray([
		ProjectSettings.globalize_path("res://dist")
	])

	_check(
		_overlay() != null and _overlay().audio != null,
		"and the shell has its overlay, with its own sounds"
	)

	# [b]Every sound ends the moment it starts.[/b] The null sink finishes nothing on its
	# own, so each cue def's one-at-a-time cap would refuse the second "tick" of a
	# countdown here -- a refusal a real 35 ms click never meets -- and four voices would
	# be full after four cues. `finish` is the null sink's documented way to end one.
	var sink := _overlay().audio.sink as DotAudioSinkNull
	if sink != null:
		_overlay().audio.played.connect(
			func(_id: StringName, handle: int, _why: StringName) -> void:
				if handle > 0:
					sink.finish(handle)
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


# --- Sections --------------------------------------------------------------

func _test_connect() -> bool:
	_section("a player joins")

	_shell._connect_to("127.0.0.1:%d" % _port)

	# The server's SPAWNED, not the client's PLAYING: notices go to playing sessions, and
	# the server moves a session there a poll after the client announces it loaded.
	var admitted := await _until(func() -> bool:
		return _server() != null and _server().playing_sessions().size() == 1
	)

	_check(admitted, "the server admits them and signon finishes")
	_check(not _overlay().has_line(TmcVote.NOTICE_TOPIC), "with nothing on the HUD yet")
	_done()
	return admitted


func _test_the_countdown() -> void:
	_section("the countdown to a ballot is on their screen")

	var started := _director().start_vote()

	if not _check(started.ok, "a vote is started", str(started.error)):
		_done()
		return

	var shown := await _until(func() -> bool: return _line() != "", 5.0)

	_check(
		shown and _line().begins_with("A vote for the next game starts in"),
		"the line arrives over the socket (%s)" % _line(),
		"the director counted, the server has no client, or the shell never connected "
		+ "notice_received"
	)

	var left := _overlay().seconds_left(TmcVote.NOTICE_TOPIC)
	_check(left > 0.0 and left <= 3.0, "counting down from the fixture's 3s (%.2f)" % left)

	# The warning cue goes out as the countdown starts, and the count cue on each of
	# `cue_countdown_at`'s seconds.
	var heard := await _until(
		func() -> bool: return _played(&"tmc_vote_warning") >= 1 and _played(&"tmc_vote_count") >= 2,
		5.0
	)
	_check(
		heard,
		"and its cues are played through the shell's catalogue (warning %d, count %d)"
			% [_played(&"tmc_vote_warning"), _played(&"tmc_vote_count")],
		"a cue out of vote.yml that is emitted and relayed and not in the catalogue is silent"
	)

	# Replaced, not stacked: every second is a notice on the same topic.
	_check(
		(_overlay().describe()["lines"] as Dictionary).size() == 1,
		"as one line that changes, not one per second"
	)
	_done()


func _test_the_ballot() -> void:
	_section("the ballot replaces it")

	var opened := await _until(func() -> bool: return _director().is_voting(), 6.0)

	if not _check(opened, "the countdown ends in a ballot"):
		_done()
		return

	var told := await _until(func() -> bool: return _line().contains("!game_vote"), 5.0)
	_check(told, "and the line says how to vote (%s)" % _line())
	_check(
		await _until(func() -> bool: return _played(&"tmc_vote_start") >= 1, 5.0),
		"with the ballot's opening cue"
	)

	# Nobody votes, so nothing changes -- and the line has to come off anyway, which is
	# the poll in TmcVote rather than any signal.
	_director().close_vote()

	# [b]One second, against a ballot line with thirty on it.[/b] The overlay takes a line
	# down by itself once its countdown runs out, so a window longer than what is left would
	# pass with TmcVote's clear removed -- and did, the first time this was armed.
	_check(
		await _until(func() -> bool: return not _overlay().has_line(TmcVote.NOTICE_TOPIC), 1.0),
		"a closed ballot comes off the HUD",
		"left up, it counts to zero on every screen and then sits there"
	)
	_check(
		await _until(func() -> bool: return _played(&"tmc_vote_end") >= 1, 5.0),
		"with its closing cue"
	)
	_done()


## [b]The case the poll exists for.[/b] [method DotVoteDirector.cancel_countdown] emits
## nothing, so a HUD driven only by the director's signals keeps counting to a ballot that
## is never going to open.
func _test_a_cancelled_countdown() -> void:
	_section("a countdown an admin calls off comes down")

	var started := _director().start_vote()

	if not _check(started.ok, "another vote is started", str(started.error)):
		_done()
		return

	_check(
		await _until(func() -> bool: return _line() != "", 5.0),
		"its countdown is on the HUD"
	)

	_director().cancel_countdown()

	# One second against three, for the reason the ballot's check gives.
	_check(
		await _until(func() -> bool: return not _overlay().has_line(TmcVote.NOTICE_TOPIC), 1.0),
		"and is taken down when it is called off (%s)" % _line()
	)
	_done()


## The overlay's own clock: a line whose countdown the server stops caring about is not
## left at 0s for ever.
func _test_a_line_runs_out() -> void:
	_section("a countdown nobody clears runs out on its own")

	_server().broadcast_notice(DotNotice.make(&"", "Restarting in", 0.2, &"restart"))

	_check(
		await _until(func() -> bool: return _overlay().has_line(&"restart"), 5.0),
		"an operator's line arrives (%s)" % _overlay().line_text(&"restart")
	)
	_check(
		await _until(func() -> bool: return not _overlay().has_line(&"restart"), 5.0),
		"and goes once its countdown has run out"
	)
	_done()


func _test_leaving_takes_it_down() -> void:
	_section("leaving the server takes everything down")

	_server().broadcast_notice(DotNotice.make(&"", "Stays until cleared", -1.0, &"sticky"))

	if not _check(
		await _until(func() -> bool: return _overlay().has_line(&"sticky"), 5.0),
		"a line is up"
	):
		_done()
		return

	_server().kick(_server().playing_sessions()[0], "test over")

	_check(
		await _until(func() -> bool: return not _overlay().has_line(&"sticky"), 5.0),
		"and a player who is kicked is not left looking at it",
		"a line from a server this player has left is a promise nobody is keeping"
	)
	_done()
