extends Node
# [b]Not preloaded, and there is nothing left to preload.[/b] Every game here is
# DELIVERED now: its files exist at `res://dot_cloud/<id>/<version>/…`, a path no constant
# in this file can name, because the version belongs to the game and this file belongs to
# the host. A `preload("res://game/hungry_module.gd")` used to work because the game was
# copied into this project; there is no `game/` any more.
#
# What is left is what the host and the game actually agree on: the REGISTRY NAME each
# world publishes itself under, and the module name. Those are the contract -- a host
# finds a game's world by asking DotRegistry for a name, exactly as a module finds it --
# so a literal here is not a shortcut past a type, it IS the interface. If a game renames
# one, the check below reports "a hungry world is registered: false", which is the right
# failure and names the right thing.
const HUNGRY_WORLD := &"hungry_world"
const ROOM_WORLD := &"room_world"

## Changing the game under a running server, which is what a multi-game server is for.
##
## [codeblock]
## godot --headless --path . res://examples/multigame.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## It drives the **real** [TmcHost] — the same boot `./server` runs, with `auto_start` off
## and directories of its own — rather than a second one written to look like it. Every
## bug in that file has been an ordering bug, and a copy would have its own ordering.
##
## What it proves, in the order an operator meets it:
##
## - three games are registered from `content/`, so `changelevel` can reach any of them
## - switching from the lobby to hungry unloads one module and loads another
## - switching between hungry's two modes keeps the same module and rebinds it, because
##   reloading would drop every connected player
## - switching back brings the lobby's module back
## - and the client is told which game it is now, which is the only thing that tells a
##   multi-game client which of its built-in scenes to show

const CONFIG := "res://examples/fixtures/multigame"
const CONTENT := "res://content"
const DATA := "user://tmc_multigame"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: changing games")

	DotPaths.remove_tree(DATA)

	if await _boot():
		await _test_registered()
		await _test_switch_to_hungry()
		await _test_switch_between_modes()
		await _test_switch_back()
		await _test_unknown_game()
		await _test_finds_a_map_session()
		await _test_vote_changes_the_game()

	_teardown()
	DotPaths.remove_tree(DATA)

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


func _server() -> DotServer:
	return _host.server as DotServer


## Runs the console the way an admin does, and reports what it said.
##
## Through [method DotConsole.execute] rather than by calling `change_game` directly: the
## console is what an operator and RCON both reach, and a check that bypassed it would not
## notice a command that had stopped being registered.
func _console(line: String) -> DotResult:
	return _server().console.execute(line)


## Waits for a game change to finish. Returns whether it did.
##
## A deadline rather than a fixed number of frames. A change frees a scene, instantiates
## another, loads a module and puts every client back through LOADING, and how long that
## takes depends on what else the machine is doing.
func _until(condition: Callable, seconds: float = 10.0) -> bool:
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


# --- Boot ------------------------------------------------------------------

func _boot() -> bool:
	print("")
	print("booting")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	# Off before it enters the tree: on, it reads this process's command line and calls
	# get_tree().quit() when it is done, which would end the suite mid-check.
	_host.auto_start = false
	add_child(_host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not _check(started.ok, "the host boots on a fixture config", str(started.error)):
		return false

	_check(
		_server() != null and _server().state == DotServer.State.RUNNING,
		"and the server is running"
	)
	return true


func _teardown() -> void:
	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")

		remove_child(_host)
		# Freed rather than queued: a queue_free on the last line before quit() is a free
		# that never happens, and every node under it is reported as leaked at exit.
		_host.free()


# --- Sections --------------------------------------------------------------

func _test_finds_a_map_session() -> void:
	_section("`+map` finds the thing it has to talk to")

	# [b]The whole of `sv_map` rests on one duck-typed lookup, and a duck-typed lookup
	# that stops matching returns null rather than failing.[/b] `_find_map_session`
	# walks the loaded game looking for something that answers `change_to` and
	# `change_to_map`; the day a game builds its session under a different node, or
	# dot-map renames a method, the only symptom is a `+map` that goes back to being
	# silently ignored — which is the exact bug this setting exists to fix.
	#
	# So both directions are checked: that the predicate still matches a real
	# [DotMapSession], and that it does not match something else in a real game's tree.
	#
	# Through `call` because `tmc_host.gd` declares no `class_name` — it is a host
	# script the scene owns, not a type anything is meant to reference by name.
	var probe := Node.new()
	probe.name = "MapProbe"
	var session := DotMapSession.new()
	session.name = "Session"
	probe.add_child(session)
	add_child(probe)

	_check(
		_host.call("_find_map_session", probe) == session,
		"a real DotMapSession still answers the duck-typed predicate",
		"if this fails, dot-map renamed a method and `--map` now does nothing at all"
	)

	remove_child(probe)
	probe.free()

	# The server is on the lobby here, which genuinely has no maps. A false positive is
	# worse than no match: it would send `change_to` to whatever answered.
	_check(
		_at_game("lobby"),
		"the server is on the lobby for the negative case (%s)"
			% _server().games.current_content_id()
	)
	_check(
		_host.call("_find_map_session", _server().games) == null,
		"and nothing in a game with no maps is mistaken for a map session"
	)

	_done()


func _test_registered() -> void:
	_section("what the server can run")

	var ids := Array(_host.content.ids())

	for wanted in ["lobby", "hungry_classic", "hungry_frenzy"]:
		_check(ids.has(wanted), "%s is registered" % wanted)
		_check(
			_server().games.find_game(wanted) != null,
			"and dot-server knows it, so changelevel can reach it"
		)

	_check(
		_at_game("lobby"),
		"the server booted into the lobby, which is what content/lobby/game.yml claims"
	)
	_check(
		_server().modules.has_module("room"),
		"with the lobby's module loaded"
	)
	_check(
		not _server().modules.has_module("hungry"),
		"and nobody else's"
	)

	# `avatars` sits under content/ because HungryContentSource reads
	# res://content/avatars/, and it must not be mistaken for a game an admin can switch to.
	_check(
		not ids.has("avatars"),
		"and the avatar parts are not offered as a game"
	)

	# [b]The half a `kind: pack` game needs and that nothing here used to build.[/b]
	# `DotGameManager` fetches and mounts a delivered game's content on the SERVER before
	# it asks any client to — the scene it loads is a path inside the mount — so a tool
	# that documents pack games and creates no cloud client can serve none of them. Every
	# game in `content/` is builtin, which is precisely why nothing noticed.
	#
	# Asserted on the registry name rather than on the node, because the registry entry is
	# the whole of what dot-server, dot-map and dot-user-avatar look for, and a client that
	# exists without registering is a bug this family has already shipped once.
	_check(
		DotRegistry.get_service(&"dot_cloud_client") != null,
		"a content client is registered, so a pack game could be fetched",
		"without it dot-server refuses every game with a manifest_url"
	)
	_done()


func _test_switch_to_hungry() -> void:
	_section("lobby -> hungry")

	# [b]With somebody in the room.[/b] Switching an EMPTY server exercises the module
	# swap and nothing else — no entity is despawned, no peer is removed from the
	# netcode, and the world that is about to be freed is holding nothing. A real
	# `changelevel` happens under players, and that is a different code path: it took a
	# browser sitting in the lobby to reach it, and it segfaulted the server.
	var lobby: DotModule = _server().modules.get_module("room")

	# [b]Somebody came and went before the one who is still here.[/b] That is what a real
	# server looks like by the time anybody types `changelevel`, and it is the difference
	# between the two runs that found the crash: switching with one client attached is
	# fine, and switching after another has been through leaves state behind for the
	# change to walk over.
	lobby.bridge.add_occupant(2, 4242, "Left already")
	lobby.bridge.remove_peer(2)

	var seated: DotResult = lobby.bridge.add_occupant(3, 4243, "Occupant")
	_check(seated.ok, "somebody is in the lobby first", str(seated.error))
	_check(
		lobby.world.occupant_count() == 1,
		"and the one who left is gone (%d in the room)" % lobby.world.occupant_count()
	)

	var result := _console("changelevel hungry_classic")
	_check(result.ok, "an admin can change the game from the console", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("hungry_classic"))

	if not _check(arrived, "and the server ends up on it"):
		_done()
		return

	_check(
		_server().modules.has_module("hungry"),
		"hungry's module is loaded",
		"dot-server changes the scene and tells the modules already loaded; it does not "
		+ "load one, so without the host doing it the new game has no netcode at all"
	)
	_check(
		not _server().modules.has_module("room"),
		"and the lobby's is gone",
		"two modules each holding a DotNetManager would both tick the same world"
	)

	var world := DotRegistry.get_node_service(HUNGRY_WORLD)
	_check(world != null, "a hungry world is registered")
	_check(
		DotRegistry.get_node_service(ROOM_WORLD) == null,
		"and the room's world is not"
	)

	var module: DotModule = _server().modules.get_module("hungry")
	_check(
		module != null and module.world == world,
		"the module is bound to the world the scene created"
	)
	_check(
		module != null and module.net != null and module.net.is_running(),
		"and its netcode is running"
	)

	# What a joining client is told, which for a delivered game is the whole of what it
	# needs: a game id it can show a name for, and a scene path RELATIVE to the mount.
	var info := _server().games.load_info()
	_check(
		String(info.get("game_id", "")) == "hungry_classic",
		"and what a joining client is told names the game (%s)" % info.get("game_id", "")
	)
	_check(
		String(info.get("scene", "")) == "game/client/hungry_client.tscn",
		"and names its client scene RELATIVELY (%s)" % info.get("scene", ""),
		"DotClientLink refuses every absolute res:// path outside dot-cloud's mount, so "
		+ "a relative one is the only spelling a client will resolve"
	)
	_done()


func _test_switch_between_modes() -> void:
	_section("hungry classic -> frenzy")

	var before := _server().modules.get_module("hungry")
	var world_before := DotRegistry.get_node_service(HUNGRY_WORLD)

	var result := _console("changelevel hungry_frenzy")
	_check(result.ok, "the second mode can be reached", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("hungry_frenzy"))

	if not _check(arrived, "and the server ends up on it"):
		_done()
		return

	var after := _server().modules.get_module("hungry")

	# [b]The reason the host compares module PATHS and not game ids.[/b] Two game ids, one
	# module: reloading it between them would rebuild the DotNetManager, which resets the
	# message ids, the peer records and the clock — a disconnect for everybody, and exactly
	# what changing the game is supposed to avoid.
	_check(
		after == before,
		"the module instance survives, because both modes share it",
		"reloading it would rebuild the DotNetManager and disconnect everybody"
	)

	var world_after := DotRegistry.get_node_service(HUNGRY_WORLD)
	_check(world_after != world_before, "the world is a new one")
	_check(
		after != null and after.world == world_after,
		"and the module rebound onto it"
	)
	_check(
		after != null and after.net != null
			and after.net.is_running(),
		"with the same netcode still running"
	)
	_done()


func _test_switch_back() -> void:
	_section("hungry -> lobby")

	var result := _console("changelevel lobby")
	_check(result.ok, "the lobby can be returned to", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("lobby"))

	if not _check(arrived, "and the server ends up on it"):
		_done()
		return

	_check(_server().modules.has_module("room"), "the lobby's module is back")
	_check(not _server().modules.has_module("hungry"), "and hungry's is gone")
	_check(
		DotRegistry.get_node_service(ROOM_WORLD) != null,
		"a room world is registered again"
	)
	_check(
		DotRegistry.get_node_service(HUNGRY_WORLD) == null,
		"and hungry's world is not",
		"a world left registered would be found by the next module to look for one"
	)
	_done()


func _test_unknown_game() -> void:
	_section("a game that is not there")

	# [b]Asserted on the outcome, not on what the console returned.[/b]
	# `changelevel`'s handler is a coroutine — it `await`s `change_game` — so
	# [method DotConsole.execute] reports that the command was *dispatched*, not what it
	# decided. A check written against the return value passes whatever happens, which is
	# worse than no check: it would go green on a server that had just wiped its own game.
	_console("changelevel no_such_game")

	# Long enough for a real change to have got somewhere, so "nothing happened" means it.
	await _until(func() -> bool: return false, 1.0)

	_check(
		_at_game("lobby"),
		"changing to a game the server does not have leaves it where it was",
		"a failed change restores the previous game; a server on no game at all is worse "
		+ "than one on the old one"
	)
	_check(_server().modules.has_module("room"), "with its module untouched")
	_check(
		not _server().modules.has_module("hungry"),
		"and nothing else loaded"
	)
	_done()


# --- Voting ----------------------------------------------------------------

## The players choosing the next game, on a real server, end to end.
##
## [b]This is the join dot-vote was built for, and it is a join nothing else runs.[/b]
## Every check dot-vote has of its own drives its director against fixtures or against a
## game manager built for the test; this one goes through the whole of the real thing —
## `cfg` read into `DotVoteRules`, a `TmcVote` attached to the running server, a ballot
## filled from `content/`, and a `change_game` that unloads one module and loads another
## while the vote system watches the host's own `game_loaded` to know it happened.
##
## The family's own lesson says this is where the bugs are, and it found one: the
## director called `begin()` on a successful apply AND the host called it again from
## `game_loaded`, which is two entries in the play history for one play and a cooldown
## quietly half as long as it says it is.
func _test_vote_changes_the_game() -> void:
	_section("the players vote for the next game")

	var votes: TmcVote = _host.votes

	if not _check(votes != null, "the host installed a vote system", "vote.yml is off"):
		_done()
		return

	var director := votes.director
	var here := _at_game("lobby")

	_check(here, "the server is back on the lobby after the switches above")

	_check(
		director.current_id() == &"lobby",
		"and the vote system knows it (%s)" % director.current_id(),
		"a director on no game has no clock, nothing on cooldown, and offers the "
		+ "game everybody is playing on its own first ballot"
	)

	var offered := PackedStringArray()

	for choice in director.build_options(1):
		offered.append(String(choice.id))

	_check(
		not Array(offered).has("lobby"),
		"the lobby is not on the ballot (%s)" % [offered],
		"it is this server's home screen; 'vote to go back to the menu' is not "
		+ "something anybody votes for"
	)
	_check(
		Array(offered).has("hungry_classic") or Array(offered).has("hungry_frenzy"),
		"and the games are (%s)" % [offered]
	)

	# The whole player-facing sequence, in the order a player meets it.
	var nominated := director.nominate(&"u1", &"hungry_frenzy")
	_check(nominated.ok, "a player nominates a game", str(nominated.error))

	# Nobody is connected, so rocking the vote cannot pass and must say so. A fraction
	# of nobody is not a mandate, and the refusal is the correct behaviour rather than a
	# limitation of this suite.
	var rocked := director.rock_the_vote(&"u1")
	_check(
		not rocked.ok,
		"rocking the vote is refused with nobody here (%s)"
			% (rocked.error.message if rocked.error != null else "")
	)

	# Opened through the real console command, which is how an operator does it — and
	# which fails if dot-vote's commands stopped being registered on this server.
	#
	# [b]Spelled out of TmcVote.COMMAND_PREFIX rather than typed.[/b] The prefix is
	# what keeps this vote from taking four command names a loaded game's own map vote
	# already answers to, and a test that hardcoded `revote` would still pass on the
	# day somebody dropped the prefix and reintroduced that collision.
	var revote := "%srevote" % TmcVote.COMMAND_PREFIX

	# [b]What the shells are told, heard at the server.[/b] Nobody is connected, so every
	# notice reaches nobody -- and `notice_sent` fires anyway, which is what lets a suite
	# with no client assert what a client would have been sent. The half with a client is
	# `shell_notice`.
	var notices: Array[DotNotice] = []
	var on_notice := func(n: DotNotice, _count: int) -> void: notices.append(n)
	_server().notice_sent.connect(on_notice)

	var opened := await _console(revote)
	_check(opened.ok, "an operator opens the ballot with `%s`" % revote, str(opened.error))
	_check(
		_server().console.find_command("revote") == null,
		"and the bare `revote` is left alone for a game's own vote to claim"
	)
	_check(
		director.is_voting(),
		"which opens a ballot rather than changing the game blind"
	)
	_check(
		director.ballot.option_ids().has(&"hungry_frenzy"),
		"with the nomination on it"
	)

	var line := _notice_for(notices, TmcVote.NOTICE_TOPIC)
	_check(
		line != null and line.has_countdown()
			and line.text.contains("!%s%s" % [TmcVote.COMMAND_PREFIX, TmcVote.COMMAND_NAMES["vote"]]),
		"the ballot goes on every HUD, with its time and the command that votes (%s)"
			% (str(line.describe()) if line != null else "nothing"),
		"the vote reached players as chat only before dot-server had a notice"
	)
	_check(
		_notice_with_cue(notices, &"tmc_vote_start"),
		"and its opening cue goes with it (%d notices)" % notices.size(),
		"vote.yml's cue_vote_start is read, emitted and relayed, or none of it"
	)

	# Counted BEFORE, because the sections above already switched through this game and
	# each of those was a real play. The number that matters is the delta.
	var played_before := director.history.times_played(&"hungry_frenzy")

	director.cast_one(&"u1", &"hungry_frenzy")

	var result := director.close_vote()
	_check(
		result.winner_id == &"hungry_frenzy",
		"the vote elects it (%s)" % result.summary
	)

	_check(
		_notice_with_cue(notices, &"tmc_vote_end"),
		"with its closing cue"
	)

	# Taken down by TmcVote's poll, which runs on the next physics tick. Polled, because
	# the director emits nothing when an admin calls a countdown off, and a line left up
	# would count to zero on every screen for a ballot that never opens.
	notices.clear()
	var took_down := func() -> bool:
		for n in notices:
			if n.is_clear() and n.topic == TmcVote.NOTICE_TOPIC:
				return true
		return false
	var cleared := await _until(took_down, 5.0)
	_check(cleared, "and the closed ballot comes off every HUD")
	_server().notice_sent.disconnect(on_notice)

	var switched := await _until(func() -> bool: return _at_game("hungry_frenzy"), 20.0)

	_check(
		switched,
		"and the SERVER actually changes to it",
		"a ballot that elects a winner and cannot make the server play it is this "
		+ "family's own 'the two ends never met'"
	)
	_check(
		_server().modules.has_module("hungry"),
		"with the winning game's module loaded, which is what makes it playable"
	)

	# The host's game_loaded is what tells the director a change landed, and it fires
	# for an operator typing `changelevel` too.
	_check(
		director.current_id() == &"hungry_frenzy",
		"the vote system followed the change (%s)" % director.current_id()
	)
	_check(
		director.history.times_played(&"hungry_frenzy") == played_before + 1,
		"and counted it as played exactly ONCE (%d, was %d)" % [
			director.history.times_played(&"hungry_frenzy"), played_before
		],
		"the director applying the change and the host announcing it are two "
		+ "notifications of one play, and counting both halves every cooldown — "
		+ "which is why DotVoteDirector.begin_on_apply exists and is off here"
	)
	_check(
		director.clock.rtv_votes() == 0,
		"with everybody's rock-the-vote cleared for the new game"
	)

	# And the same clock reset for a change the vote had nothing to do with.
	await _console("changelevel lobby")
	var manual := await _until(func() -> bool: return _at_game("lobby"), 20.0)

	_check(manual, "an operator changes the game by hand")
	_check(
		director.current_id() == &"lobby",
		"and the vote clock follows that too (%s)" % director.current_id(),
		"otherwise a manual changelevel leaves the previous game's timer running "
		+ "and the new game ends early"
	)

	_done()


## The last notice sent for [param topic], or null.
func _notice_for(notices: Array[DotNotice], topic: StringName) -> DotNotice:
	for i in range(notices.size() - 1, -1, -1):
		if notices[i].topic == topic:
			return notices[i]
	return null


func _notice_with_cue(notices: Array[DotNotice], cue: StringName) -> bool:
	for n in notices:
		if n.cue == cue:
			return true
	return false
