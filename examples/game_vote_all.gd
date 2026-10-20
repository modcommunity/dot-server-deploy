extends Node
# [b]Nothing preloaded out of a game, because no game is in this build.[/b] Every game here is
# a delivered pack; its module and its own vote are reached through the host's module table
# and through TmcVote, which finds a loaded game's vote directors in the tree.

## The server's game vote, played through EVERY game in `content/`, with a real shell attached.
##
## [codeblock]
## godot --headless --path . res://examples/game_vote_all.tscn
## [/codeblock]
##
## Exits non-zero on any failure. Needs every game published in `dist/`
## (`./server pack <id> --source games/<repo>`); with no `dist/` at all it says "skipped".
##
## [b]Why one suite walks all of them.[/b] `multigame` votes one change between two games with
## nobody connected, and `shell_notice` draws the ballot over buses. Neither can say whether the
## vote works in arena, or in a minigame whose own layout ballot opens by itself twenty seconds
## into every round, or in a game with no rounds at all. A game reaches the game vote through
## three things that are each game's: what it registers in the tree, whether it has a vote of its
## own and when that one opens, and whether a real client can follow a change into it and out of
## it. So every game is the running game once, and for each:
##
## - [b]Rock the vote offers a ballot[/b], typed by the client through chat, and the ballot is
##   drawn on the shell's HUD. The client chooses "don't change" by clicking it.
## - [b]The game's own vote waits for it[/b]: a ballot the game asks for while the game ballot is
##   up is refused, and opens by itself once the game ballot closes.
## - [b]The time limit offers a ballot[/b], and waits while the game's own ballot is up. A game
##   without rounds reaches it the same way, because the game vote's clock is the game's time.
## - [b]Never two ballots at once[/b], watched every physics frame for the whole run.
## - [b]The winner is played[/b]: the client clicks the next game, the server unloads the old
##   module and loads the new one, and the client downloads, mounts and enters it.
##
## The last game votes the first one back, so every game is both switched into and out of.

const CONFIG := "res://examples/fixtures/game_vote_all"

## The server in a World3D of its own, away from the client in this process. See the helper.
const ServerWorld := preload("res://examples/server_world.gd")

## The engine's "RPC to a node this end does not have" errors, counted for the whole run.
const RpcPathWatch := preload("res://examples/rpc_path_watch.gd")
const CONTENT := "res://content"
const DATA := "user://tmc_game_vote_all"
const SHELL := "res://client/shell.tscn"

## Every game in the family, in the order they are played. hungario is one game over several ids
## (its modes); one of them stands for it, and its mode vote is its own vote.
const ORDER := [
	"arena", "playground", "g2gfast", "hungry_classic", "hideseek", "zombiezone", "smash",
	"buses", "wipeout", "deathrun", "delivery", "lookatme", "prophunt",
]

## Checks per game section, whichever branch it takes.
const PER_GAME := 17

## The games this run plays: [constant ORDER], or `-- --order=arena,smash,wipeout`. The first
## is always ORDER's first, because the fixture boots into it (`sv_game`); an order without it
## has it put in front.
var _order: Array = ORDER.duplicate()

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null
var _shell: Node = null

## Frames on which the game ballot and a game's own ballot were open together, per game.
var _overlaps := {}

## One row per game for the table at the end.
var _rows: Array[Dictionary] = []

## The modules the last game ran, by name, as the instances it ran.
var _previous_modules := {}


## `-- --shot=<dir>`: while the suite runs, save `<dir>/<game>_game.png` once the game ballot is
## drawn over each game, and `<dir>/<game>_own.png` once the game's own ballot is voting (waited
## for up to 10 s; a game with nothing of its own to vote on has no second frame). The run goes
## on and is checked as usual. Under xvfb-run without --headless (a null renderer saves an empty
## frame), and with `--order` to look at a few games:
##
##   xvfb-run -a godot --path . --resolution 1280x720 res://examples/game_vote_all.tscn -- --shot=/tmp/ballots --order=arena,smash,wipeout
##
## Until 2026-10-11 a shot rendered the first game only and quit from inside the first game's
## section, and the next section then ran against a torn-down host ("'games' on Nil").
var _shot_dir := ""

## Frames saved, for the summary.
var _shots := PackedStringArray()


## The delivered game's client node that owns a lot panel (`garage` and `_show_garage`), or null.
## Duck-typed, because nothing of a game is preloaded here.
func _find_lot_client() -> Node:
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.has_method("_show_garage") and "garage" in node:
			return node
		stack.append_array(node.get_children())
	return null


func _save_shot(shot_name: String) -> void:
	# The shell's loading cover first: the suite counts the client as playing at the link's
	# phase, which comes before the delivered game has mounted its content and built its world,
	# and the first game of a run (a cold shader and map cache) is the slow one. A frame taken
	# then is the cover, not the game.
	var loading = _shell.get("loading")
	if loading != null:
		await _until(func() -> bool: return not loading.is_showing(), 30.0)

	# A few frames, so the panel has laid itself out and the game behind it has drawn.
	for i in 30:
		await get_tree().process_frame

	var path := _shot_dir.path_join("%s.png" % shot_name)
	var image := get_viewport().get_texture().get_image()
	var saved := image.save_png(path)
	print("  shot  %s: %s (%dx%d)" % [path, error_string(saved), image.get_width(), image.get_height()])
	if saved == OK:
		_shots.append(path)


## Every check this suite runs: booting (4), each game, the way back to the first (3), the
## RPC watch and the two totals.
func _expected_checks() -> int:
	return 4 + PER_GAME * _order.size() + 3 + 3


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_dir = arg.trim_prefix("--shot=")
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_shot_dir))
		elif arg.begins_with("--order="):
			_order.clear()
			for id in arg.trim_prefix("--order=").split(",", false):
				if not ORDER.has(id.strip_edges()):
					push_error("game_vote_all: --order names %s, which is not in ORDER" % id)
					continue
				if not _order.has(id.strip_edges()):
					_order.append(id.strip_edges())
			_order.erase(ORDER[0])
			_order.push_front(ORDER[0])

	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args() else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: the game vote in every game")

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://dist/tmc")):
		print("skipped: nothing is published in dist/ here")
		get_tree().quit(0)
		return

	DotPaths.remove_tree(DATA)

	# For the whole run: a game change is where a game's RPC node used to be renamed.
	var rpc_watch := RpcPathWatch.new()
	OS.add_logger(rpc_watch)

	if await _boot():
		for i in _order.size():
			if _server() == null:
				break
			var here: String = _order[i]
			var next: String = _order[(i + 1) % _order.size()]
			await _test_game(here, next)

		await _test_back_at_the_start()

	await _teardown()
	DotPaths.remove_tree(DATA)
	OS.remove_logger(rpc_watch)

	_print_table()

	if not _shots.is_empty():
		print("")
		print("%d frames in %s" % [_shots.size(), _shot_dir])

	print("")
	# Godot drops an RPC whose node path the receiver lacks with three C++ errors and nothing
	# else; the old game's link, left under `Server` on both ends, renamed the same game's next
	# link to `@Node@<n>` and every request after a return to a game went nowhere.
	_check(
		rpc_watch.count() == 0,
		"no RPC was addressed to a node the other end does not have (%d)" % rpc_watch.count(),
		rpc_watch.summary()
	)
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered]
	)
	_check(
		_passed + _failed + 1 == _expected_checks(),
		"every check ran (%d of %d)" % [_passed + _failed + 1, _expected_checks()],
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


## Checks that a section skipped, counted as failures so the total still adds up and the
## reason is named.
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


## The client is in [param game_id]: told of it, its scene loaded, and the server's session
## playing again.
func _client_in(game_id: String) -> bool:
	var link := _link()
	return (
		link != null and link.server_game_id == game_id
		and link.phase == DotClientLink.Phase.PLAYING
		and link._scene_instance != null and is_instance_valid(link._scene_instance)
		and _server().playing_sessions().size() == 1
	)


func _on_screen(d: DotVoteDirector) -> bool:
	return d != null and is_instance_valid(d) and (d.is_voting() or d.is_counting_down())


## The game's own director that has something to vote between, or the first one, or null.
func _own() -> DotVoteDirector:
	var found: Array[DotVoteDirector] = _votes().game_directors()

	for d in found:
		if d.has_alternatives():
			return d

	return found[0] if not found.is_empty() else null


## The drawn game ballot's index of [param id], or -1.
func _panel_index(id: StringName) -> int:
	var panel := _overlay().ballot(TmcVote.BALLOT_TOPIC)

	if panel == null or not panel.is_open():
		return -1

	for i in panel.option_count():
		if StringName(str(panel._options[i]["id"])) == id:
			return i

	return -1


func _physics_process(_delta: float) -> void:
	var votes := _votes() if _host != null and is_instance_valid(_host) else null

	if votes == null or _server() == null:
		return

	if not votes.director.is_voting():
		return

	for d in votes.game_directors():
		if d.is_voting():
			var current := _server().games.current()
			var key := current.game_id if current != null else "?"
			_overlaps[key] = int(_overlaps.get(key, 0)) + 1


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	_section("booting")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.name = "Host"
	_host.auto_start = false
	ServerWorld.add(self, _host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not _check(started.ok, "the host boots", str(started.error)):
		_skip(3, "the host did not boot")
		_done()
		return false

	_check(_director() != null, "with the game vote installed", "vote.yml is off")

	var rot: Variant = _votes().rotation if _votes() != null else null
	_check(rot != null and rot.has_rotations() and rot.plays(_host.server.games.games).size() > 1,
		"and games.yml's rotation reaches it, naming the installed games",
		"fixture games.yml is missing or matched nothing")

	_shell = (load(SHELL) as PackedScene).instantiate()
	_shell.name = "Shell"
	add_child(_shell)

	await get_tree().process_frame
	await get_tree().process_frame

	# Content from this project's own `dist/`, as `shell_notice` does.
	_shell._ensure_cloud()
	# And `dist/maps`, where owned map packs are published (`gamemann/surf_mesa`): the host
	# searches it too. Without it g2gfast sat on "Joining..." for its whole section.
	_shell._cloud.http_base_urls = PackedStringArray([
		ProjectSettings.globalize_path("res://dist"),
		ProjectSettings.globalize_path("res://dist/maps"),
	])

	# Every sound ends the moment it starts; see `shell_notice`.
	var sink := _overlay().audio.sink as DotAudioSinkNull
	if sink != null:
		_overlay().audio.played.connect(
			func(_id: StringName, handle: int, _why: StringName) -> void:
				if handle > 0:
					sink.finish(handle)
		)

	_shell._connect_to("127.0.0.1:%d" % int(_host.config.server.port))

	var first: String = _order[0]
	_check(
		await _until(func() -> bool: return _at_game(first) and _client_in(first), 60.0),
		"a real shell joins %s" % first,
		"phase %s, game '%s'" % [
			_link().phase if _link() != null else -1,
			_link().server_game_id if _link() != null else "",
		]
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

		ServerWorld.remove(_host)
		_host.free()
		_host = null

		await get_tree().physics_frame
		await get_tree().physics_frame


# --- One game ---------------------------------------------------------------

func _test_game(game_id: String, next: String) -> void:
	_section("%s (then %s)" % [game_id, next])

	var row := {
		"game": game_id, "offered_rtv": false, "offered_time": false, "own": "none",
		"coexists": "n/a", "switched": false, "rounds": false,
	}
	_rows.append(row)

	var published := FileAccess.file_exists(
		"res://dist/%s/manifest.json" % _server().games.find_game(game_id).content_id
	) if _server().games.find_game(game_id) != null else false

	if not _check(published, "%s is in content/ and published in dist/" % game_id):
		_skip(PER_GAME - 1, "%s is not published" % game_id)
		_done()
		return

	# --- It is the running game, and the client is in it.
	var arrived := await _until(func() -> bool: return _at_game(game_id), 60.0)
	_check(arrived, "the server is running %s" % game_id)

	# The last game's modules are torn down: none of the instances it ran is still loaded. By
	# instance, because a module several games load (dot-platform's) has the same name in both.
	var loaded := _server().modules.loaded_names()
	var leftover := PackedStringArray()
	for name: String in _previous_modules:
		var was: Variant = _previous_modules[name]
		var now := _server().modules.get_module(name)
		# A freed object compares equal to null, so both must be alive to be the same one.
		if now != null and is_instance_valid(was) and now == was:
			leftover.append(name)
	_check(
		loaded.size() > 0 and leftover.is_empty(),
		"its modules are loaded (%s) and the last game's are gone" % [loaded],
		"still loaded from the last game: %s" % [leftover]
	)
	_previous_modules.clear()
	for name in loaded:
		_previous_modules[name] = _server().modules.get_module(name)

	var followed := await _until(func() -> bool: return _client_in(game_id), 60.0)
	row["switched"] = arrived and followed
	_check(
		followed,
		"the client followed: told, downloaded, mounted, playing",
		"phase %s, game '%s'" % [_link().phase, _link().server_game_id]
	)

	_check(
		_director().current_id() == StringName(game_id),
		"the game vote's clock is on %s (%s)" % [game_id, _director().current_id()]
	)

	# Let TmcVote's tree scan find the game's own vote, if it has one.
	await _until(func() -> bool: return false, 1.2)
	var own := _own()
	row["own"] = "none" if own == null else ("ballot" if own.has_alternatives() else "one choice")

	# Within a rescan: a game may decide it has rounds only once its first map is in (g2gfast
	# fetches its map after it is running), and TmcVote looks again every RESCAN_SEC.
	var rounds_now := func() -> bool:
		var any := false
		for d in _votes().game_directors():
			any = any or d.round_based
		return any
	await _until(func() -> bool: return _director().round_based == bool(rounds_now.call()), TmcVote.RESCAN_SEC + 1.0)
	var rounds: bool = rounds_now.call()
	row["rounds"] = rounds
	_check(
		_director().round_based == rounds,
		"the game vote knows whether %s reports rounds (%s)" % [game_id, rounds],
		"without it `time_up: finish_round` cannot tell a round in progress from no rounds"
	)

	# --- Rock the vote, typed by the player.
	_link().send_chat("/%srtv" % TmcVote.COMMAND_PREFIX)
	var rocked := await _until(func() -> bool: return _director().is_voting(), 10.0)
	row["offered_rtv"] = rocked
	_check(rocked, "!game_rtv offers a ballot of games", _director().describe_lines()[0])

	var drawn := await _until(func() -> bool: return _panel_index(DotVoteBallot.KEEP) >= 0, 5.0)
	_check(drawn, "drawn on the shell's HUD, with \"don't change\" on it")

	if _shot_dir != "":
		await _save_shot("%s_game" % game_id)
		# A game with a full-width panel of its own (delivery's lot) is looked at with it open:
		# the case a ballot column can hide most of.
		var lot := _find_lot_client()
		if lot != null:
			lot.call("_show_garage", true)
			await _save_shot("%s_lot" % game_id)
			lot.call("_show_garage", false)

	# The game asks for its own ballot while the game ballot is up.
	var refused := true
	if own != null and own.has_alternatives() and own.state == DotVoteDirector.State.RUNNING:
		var asked := own.start_vote(DotVoteClock.REASON_MANUAL)
		refused = not asked.ok and not _on_screen(own)
	_check(
		refused,
		"the game's own vote cannot open over it" if own != null else "(no vote of its own)",
		"two ballots on one screen, the number keys belonging to whichever opened last"
	)

	# The player clicks "don't change".
	var keep_at := _panel_index(DotVoteBallot.KEEP)
	if keep_at >= 0:
		_overlay().ballot(TmcVote.BALLOT_TOPIC).choose(keep_at)
	var kept := await _until(
		func() -> bool: return not _on_screen(_director()), 10.0
	)
	_check(
		kept and _at_game(game_id),
		"a click on \"don't change\" closes it and %s carries on" % game_id
	)

	# The player asks for the next game, so it is on the next ballot.
	var heard: Array[String] = []
	var hear := func(payload: Dictionary) -> void:
		if str(payload.get("kind", "")) == "system":
			heard.append(str(payload.get("text", "")))
	_link().chat_received.connect(hear)
	_link().send_chat("/%snominate %s" % [TmcVote.COMMAND_PREFIX, next])

	# The line everybody reads names the player. It named the voter id: "[Server] u1
	# nominated Arena." in every game, while the ballot beside it drew the name.
	var sessions := _server().sessions() if _server() != null else []
	var me: DotClientSession = sessions[0] if not sessions.is_empty() else null
	var nominated_line := func() -> String:
		for line in heard:
			if line.contains(" nominated "):
				return line
		return ""
	await _until(func() -> bool: return nominated_line.call() != "", 5.0)
	_link().chat_received.disconnect(hear)
	var said: String = nominated_line.call()
	_check(
		me != null and me.display_name != "" and said.begins_with("%s nominated " % me.display_name)
			and not said.begins_with("u%d " % me.userid),
		"the nomination line names the player (%s)" % said,
		"the director's line printed the voter id; DotVoteDirector.people_fn / the feed's"
	)

	# The game's own ballot follows the game ballot rather than being lost.
	var follows := true
	if own != null and own.has_alternatives():
		follows = await _until(func() -> bool: return _on_screen(own), 8.0)
	_check(
		follows,
		"the game's own ballot opens once the game ballot is down"
			if own != null and own.has_alternatives() else "(nothing of its own to follow)",
		"refused for the game ballot and dropped: that round's map ballot never came"
	)

	# The frame that showed the game ballot's result stacked over this one.
	if _shot_dir != "" and follows and own != null and own.has_alternatives():
		await _until(func() -> bool: return own.is_voting(), 10.0)
		await _save_shot("%s_own" % game_id)

	# --- The time limit falls due while the game's own ballot is up, and waits for it.
	var due_and_waiting := true
	if _on_screen(own):
		var due := await _until(
			func() -> bool: return _director().clock.is_vote_due() or _director().clock.is_expired(),
			_director().clock.remaining + 2.0
		)
		# A game may take its own ballot down by itself before then (wipeout starts the next
		# round and its director over); then there is nothing to wait for and the frame watch
		# below is what still holds.
		if _on_screen(own):
			due_and_waiting = due and not _on_screen(_director())
			row["coexists"] = "waits" if due_and_waiting else "BOTH"
		else:
			due_and_waiting = due
			row["coexists"] = "own closed first"

		if own.is_counting_down():
			own.cancel_countdown()
		await _until(func() -> bool: return own.is_voting(), 3.0)
		if own.is_voting():
			var _closed := own.close_vote()
	elif own != null:
		row["coexists"] = "n/a (one choice)"
	_check(
		due_and_waiting,
		"the time limit waits while the game's own ballot is up"
			if row["coexists"] != "n/a"
			else "(no ballot of its own up to wait for)"
	)

	var timed := await _until(
		func() -> bool: return _director().is_voting(),
		_director().clock.remaining + 10.0
	)
	row["offered_time"] = timed
	_check(timed, "the time limit offers a ballot of games", _director().describe_lines()[0])

	# One entry per game, and none of the running game's other modes (hungario's are its own
	# mode vote's to offer).
	var by_content := {}
	var doubled := PackedStringArray()
	var current_key := _server().games.find_game(game_id).content_id
	for id in _director().ballot.option_ids():
		var d := _server().games.find_game(String(id))
		if d == null:
			continue
		if d.content_id == current_key or by_content.has(d.content_id):
			doubled.append(String(id))
		by_content[d.content_id] = true
	_check(
		doubled.is_empty(),
		"one entry per game on it, none of them %s's own modes (%s)" % [game_id, _director().ballot.option_ids()],
		"doubled: %s" % [doubled]
	)

	_check(
		int(_overlaps.get(game_id, 0)) == 0,
		"never two ballots open at once (%d frames)" % int(_overlaps.get(game_id, 0))
	)

	# --- The player clicks the next game, and it is played.
	# The panel redraws from the ballot's notice; give it a moment to arrive.
	await _until(func() -> bool: return _panel_index(StringName(next)) >= 0, 5.0)
	var next_at := _panel_index(StringName(next))

	if next_at >= 0:
		_overlay().ballot(TmcVote.BALLOT_TOPIC).choose(next_at)

	var elected := await _until(func() -> bool: return _elected(next), 10.0)
	_check(
		next_at >= 0 and elected,
		"a click on %s elects it" % next,
		"on the ballot: %s" % [_director().ballot.option_ids()]
	)
	_done()


## The vote went to [param next]: decided, under way, or done.
##
## [b]The game manager's pending game counts[/b], and it is set before the server fetches the
## new game's content. Phase stays IDLE through that fetch, and mounting zombiezone's 1293
## files on this server took 9.3 s of the 10 the click is given: a client drawing a few
## more chat lines per frame (dot-game's box drawing the server's own lines, 2026-10-11)
## made it 9.9 and failed the check three runs in three with the vote long since won.
func _elected(next: String) -> bool:
	var pending := _server().games.pending()
	return (
		_at_game(next) or _director().pending_id() == StringName(next)
		or (pending != null and pending.game_id == next)
		or _server().games.phase != DotGameManager.Phase.IDLE
	)


func _test_back_at_the_start() -> void:
	var first: String = _order[0]
	_section("back to %s" % first)

	_check(await _until(func() -> bool: return _at_game(first), 60.0), "the server is running %s again" % first)
	_check(
		await _until(func() -> bool: return _client_in(first), 60.0),
		"and the client followed it back"
	)
	_check(
		_server().state == DotServer.State.RUNNING and _server().sessions().size() == 1,
		"after %d game changes the server is still serving its one player" % _order.size()
	)
	_done()


func _print_table() -> void:
	print("")
	print("%-15s %-6s %-6s %-12s %-18s %-8s %s" % [
		"game", "rtv", "time", "own vote", "with own ballot", "rounds", "switched in",
	])

	for row in _rows:
		print("%-15s %-6s %-6s %-12s %-18s %-8s %s" % [
			row["game"], row["offered_rtv"], row["offered_time"], row["own"],
			row["coexists"], row["rounds"], row["switched"],
		])
