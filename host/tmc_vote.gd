class_name TmcVote
extends Node

## Voting for the next game, on this server.

const CHANNEL := "tmc.vote"

## What every console command of the server-level vote is called, unless games.yml's `commands:`
## block (`prefix`, `names`) says otherwise. See the class documentation: a game's own vote gets the
## bare names.
const COMMAND_PREFIX := "game_"

## The two roles whose default name would be a lie on a vote about games. `nextmap` is not a map
## here, and `votefor` next to `game_` reads as a verb phrase nobody types twice. Everything else
## keeps dot-vote's own name behind the prefix.
const COMMAND_NAMES := {"nextmap": "next", "vote": "vote"}

## The HUD line this vote owns on every client. See the class notes.
const NOTICE_TOPIC := &"game_vote"

## The drawn ballot's topic. Not [constant NOTICE_TOPIC]: a client clearing the line must
## not take the menu with it, and a game's map ballot uses a topic of its own beside it.
const BALLOT_TOPIC := &"game_ballot"

## The heading over the drawn ballot.
const BALLOT_TITLE := "Vote for the next game"

## Fewest games on offer for a game vote to exist. See the class notes.
const MIN_GAMES := 2

var director: DotVoteDirector = null
var source: DotVoteGameSource = null
var commands: DotVoteCommands = null
var feed: DotVoteBallotFeed = null

## Which games play (cfg/games.yml), or null: every installed game. See [TmcGameRotation].
var rotation: TmcGameRotation = null

## vote.yml's `end_vote`, before a cycle rotation turned it off.
var _end_vote_base := true

## vote.yml's cooldown, before any rotation's. A rotation with none of its own falls back to this,
## not to the previous rotation's value.
var _cooldown_base := 0

var server: DotServer = null

## How often the tree is searched for the loaded game's own vote directors. A game builds its
## director when its module loads, which [method _on_game_loaded] catches; this catches one
## built later (a round's, a map's).
const RESCAN_SEC := 1.0

## The chained [member DotVoteDirector.busy_fn] set on a game's director, kept on it as meta.
const CHAINED_META := &"tmc_game_vote_chained"

## `sv_game_rotation [name]` and `games_rotations`: which games play, switched live.
func _install_rotation_commands(p_server: DotServer) -> void:
	p_server.console.command("games_rotations", func(ctx: DotCmdContext) -> void:
		ctx.reply_lines(rotation.describe_lines()),
		"List the game rotations in games.yml", "").with_chat()
	p_server.console.command("sv_game_rotation", func(ctx: DotCmdContext) -> void:
		if ctx.args.is_empty():
			ctx.reply("Game rotation %s (of: %s)." % [rotation.active_name(), ", ".join(rotation.rotation_names())])
			return
		var switched := rotation.switch(ctx.args[0])
		if not switched.ok:
			ctx.reply_error(switched)
			return
		apply_rotation()
		ctx.reply("Now playing game rotation %s." % ctx.args[0]),
		"Show or switch the active game rotation", DotAdminFlags.CHANGEMAP)


## Re-applies the rotation after a live switch: the ballot's exclusions and order, the
## cooldown, and whether a game's end asks or moves on (a cycle moves on).
func apply_rotation() -> void:
	if rotation == null or director == null:
		return
	director.rules.end_vote = false if rotation.is_cycle() else _end_vote_base
	director.rules.cooldown = rotation.cooldown(_cooldown_base)
	_refresh_offer()


## The loaded game's own vote directors: its map, mode or layout vote. See [method game_directors].
var _game_directors: Array[DotVoteDirector] = []
var _rescan_in := 0.0

## The operator's `vote_exclude`, kept apart from what [method _refresh_offer] adds per game.
var _operator_excluded: Array[StringName] = []

## The game director whose round ends this vote hears, or null.
var _rounds_from: DotVoteDirector = null

## The running game's match, found beside [member _rounds_from]. See [method round_in_progress].
var _match_ref: WeakRef = null

## Whether clients have been told a line is up, so it is taken down exactly once.
var _notice_live := false

## What the line says, without its number: kept so a player who joins mid-countdown is
## shown the same sentence everybody else is looking at.
var _notice_text := ""


## Builds the whole thing and attaches it to [param p_server].
static func install(
	host: Node,
	p_server: DotServer,
	rules: DotVoteRules,
	excluded: PackedStringArray,
	p_rotation: TmcGameRotation = null
) -> TmcVote:
	if rules == null or not rules.enabled:
		DotLog.info(CHANNEL, "voting for the next game is turned off", {})
		return null

	if p_server == null or p_server.games == null:
		return null

	var valid := rules.validate()

	if not valid.ok:
		# Loud and not fatal. A server that refused to boot because its vote rules
		# disagree with each other would be a server an operator cannot get back, and
		# the rest of it works perfectly without a vote.
		DotLog.error(CHANNEL, "the vote configuration is not usable; voting is off", {
			"why": valid.error.message, "detail": valid.error.detail,
		})
		return null

	var source := DotVoteGameSource.of(p_server.games)

	for id in excluded:
		source.excluded.append(StringName(_current_id(p_server.games.games, str(id))))

	# The rotation's exclusions count towards "is there anything to vote about": a rotation
	# that leaves one game is a server with one game on offer.
	var operator_excluded: Array[StringName] = source.excluded.duplicate()
	var base_end_vote := rules.end_vote
	var base_cooldown := rules.cooldown
	var plan := {"excluded": [] as Array[StringName], "order": [] as Array[StringName], "fell_back": false}
	if p_rotation != null:
		plan = p_rotation.resolve(p_server.games.games)
		for id: StringName in plan["excluded"]:
			if not source.excluded.has(id):
				source.excluded.append(id)
		if p_rotation.is_cycle():
			rules.end_vote = false
		rules.cooldown = p_rotation.cooldown(rules.cooldown)

	var offered := votable_count(source, p_server.games)

	if offered < MIN_GAMES:
		DotLog.info(CHANNEL, "one game on offer; there is no game vote, and its own map vote decides", {
			"games": offered, "excluded": excluded.size(),
		})
		return null

	var votes := TmcVote.new()
	votes.name = "Votes"
	votes.server = p_server
	votes.source = source

	votes.director = DotVoteDirector.new()
	votes.director.name = "Director"
	votes.director.rules = rules
	votes.director.source = votes.source
	# The host's own game_loaded is what says a change landed — for a vote AND for an
	# operator typing `changelevel`, which must reset the clock and everybody's
	# rock-the-vote just the same. See DotVoteDirector.begin_on_apply.
	votes.director.begin_on_apply = false
	# `dot_vote_director` belongs to whatever the loaded game registers, not to this.
	votes.director.register_service = false

	votes._operator_excluded = operator_excluded
	votes.rotation = p_rotation
	votes._end_vote_base = base_end_vote
	votes._cooldown_base = base_cooldown
	votes._refresh_offer()
	votes._wire()

	host.add_child(votes)
	votes.add_child(votes.director)

	votes.commands = DotVoteCommands.new()
	votes.commands.director = votes.director
	votes.commands.prefix = COMMAND_PREFIX
	votes.commands.names = COMMAND_NAMES.duplicate()
	# games.yml's `commands:` block, laid over the defaults above by bind(): the operator's
	# names win, aliases register beside them, and a name another command has is skipped
	# with a WARN rather than taken.
	if p_rotation != null:
		votes.commands.spec_fn = p_rotation.commands
	if p_server.config != null and not p_server.config.chat_command_prefixes.is_empty():
		votes.commands.chat_prefix = p_server.config.chat_command_prefixes[0]
	# The server's vote is over GAMES, and the map menu (M) is the game's own director's: a
	# second `mapmenu` here would offer the game list as maps. By name, because a dot-vote
	# older than API 5 has no such property.
	if "with_map_menu" in votes.commands:
		votes.commands.set(&"with_map_menu", false)

	var bound := votes.commands.bind(p_server.console)

	# Not fatal, and not silent either. A vote nobody can type at still runs on its
	# time limit, which is most of the feature; an operator who cannot see why
	# `!game_rtv` does nothing has no way to find out otherwise.
	if not bound.ok:
		DotLog.error(CHANNEL, "the vote commands did not register", {
			"why": bound.error.message,
		})

	votes.feed = DotVoteBallotFeed.of(votes.director, votes._send_ballot)
	votes.feed.title = BALLOT_TITLE
	votes.feed.command = votes.commands.command_name("vote")
	votes.feed.people_fn = votes._person

	if p_rotation != null and p_rotation.has_rotations():
		votes._install_rotation_commands(p_server)

	p_server.games.game_loaded.connect(votes._on_game_loaded)
	p_server.client_disconnected.connect(votes._on_client_left)
	p_server.client_spawned.connect(votes._on_client_spawned)

	# The game that is already running when this is installed. Without it the director
	# is on no game at all: its clock never starts, nothing is on cooldown, and the
	# game everybody is playing is on its own first ballot.
	var current := p_server.games.current()

	if current != null:
		votes.director.begin(StringName(current.game_id))

	DotLog.info(CHANNEL, "voting for the next game is on", {
		"games": votes.source.choices().size(),
		"excluded": excluded.size(),
		"limit": votes.director.clock.formatted_remaining(),
	})

	return votes


## Distinct GAMES a ballot could offer: enabled, not excluded, and counted by content id.
static func votable_count(p_source: DotVoteGameSource, manager: DotGameManager) -> int:
	var keys := {}
	var names := {}
	var count := 0

	for choice in p_source.choices():
		if not choice.enabled:
			continue

		var descriptor := manager.find_game(String(choice.id)) if manager != null else null
		var key := String(choice.id)

		if descriptor != null and descriptor.content_id != "":
			key = descriptor.content_id

		var shown := choice.name_or_id().strip_edges().to_lower()

		if not keys.has(key) and not names.has(shown):
			count += 1

		keys[key] = true
		names[shown] = true

	return count


func _wire() -> void:
	director.player_count_fn = func() -> int:
		return server.player_count()

	# Only the people who are actually in the game. A player still joining is not a
	# vote that has been offered and would make the quorum unreachable by arithmetic.
	director.voters_fn = func() -> Array:
		var out := []

		for session in server.sessions():
			if session.is_playing():
				out.append(_voter_id(session))

		return out

	# The map flag, which is what the vote's admin commands are gated on too.
	director.is_admin_fn = func(voter: StringName) -> bool:
		var session := _session_for(voter)
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)

	# A votekick on screen, or the loaded game's own ballot: a ballot opened on top of either would be
	# two menus fighting for the same number keys. The due vote waits, through dot-vote's own retry.
	director.busy_fn = func() -> bool:
		return (server.votes != null and server.votes.is_active()) or game_ballot_up()

	# `round_based` says the game HAS rounds; this says one is being played. Without it a
	# game in warmup or waiting for players held a `finish_round` change for the whole
	# `finish_round_max_sec` (for ever at 0) for a round that had not started.
	director.round_in_progress_fn = round_in_progress

	director.is_spectator_fn = func(voter: StringName) -> bool:
		var session := _session_for(voter)
		# Not "is a spectator" — "is not playing". A voter this server has never heard
		# of is the console, and the console is not a spectator either; the guard that
		# matters is the one on a connected client that has not entered the game.
		return session != null and not session.is_playing()

	director.announce_fn = func(line: String) -> void:
		if server.chat != null:
			server.chat.broadcast_system(line)

	director.countdown_tick.connect(_on_countdown_tick)
	director.vote_opened.connect(_on_vote_opened)
	director.cue.connect(_on_cue)



## One second of the countdown to a ballot. The number is the notice's own countdown, so a
## client counts smoothly between these rather than jumping once a second.
func _on_countdown_tick(seconds_left: int, runoff: bool) -> void:
	_show_line(
		"A runoff for the next game starts in" if runoff
		else "A vote for the next game starts in",
		float(seconds_left)
	)


## The ballot is open: the line becomes how to vote, and the ballot's own time.
func _on_vote_opened(options: Array, seconds: float) -> void:
	_show_line(
		"Vote for the next game: %s 1-%d" % [
			commands.typed("vote") if commands != null else "!" + COMMAND_PREFIX + COMMAND_NAMES["vote"],
			options.size(),
		],
		seconds
	)


## A sound, and nothing on the line. The director names an id out of `vote.yml`'s `cue_*`
## and never an empty one; the shell plays it if its catalogue has it.
func _on_cue(id: StringName) -> void:
	server.broadcast_notice(DotNotice.make(id))


func _show_line(text: String, seconds: float) -> void:
	_notice_text = text
	_notice_live = true
	server.broadcast_notice(DotNotice.make(&"", text, seconds, NOTICE_TOPIC))


## The drawn ballot, to every playing session, each told which voter is theirs so their own
## choice is marked. Per session rather than one broadcast for exactly that field.
func _send_ballot(state: Dictionary) -> void:
	for session in server.playing_sessions():
		_send_ballot_to(session, state)


func _send_ballot_to(session: DotClientSession, state: Dictionary) -> void:
	var data := state.duplicate()
	data["you"] = String(_voter_id(session))
	# The line this ballot stands for: the overlay does not draw it while the ballot is open,
	# because the ballot says the same thing. A shell older than that ignores the field.
	data["line"] = String(NOTICE_TOPIC)
	server.send_notice(session, DotNotice.make(
		&"", "", float(state.get("seconds", -1.0)), BALLOT_TOPIC, data
	))


## Who a voter is, for the avatars on the drawn ballot.
func _person(voter: StringName) -> Dictionary:
	var session := _session_for(voter)

	if session == null:
		return {}

	var avatar := ""

	if session.identity != null:
		var url: Variant = session.identity.get("avatar_url")
		if url is String:
			avatar = url

	return {"name": session.display_name, "avatar": avatar}


## Somebody finished joining while the line is up. The server sends notices to playing
## sessions only, so without this a player who arrives mid-ballot sees nothing for its
## whole thirty seconds.
func _on_client_spawned(session: DotClientSession) -> void:
	var ballot := feed.snapshot() if feed != null else {}

	if not ballot.is_empty():
		_send_ballot_to(session, ballot)

	if not _notice_live:
		return

	var seconds := (
		director.countdown_remaining() if director.is_counting_down()
		else director.vote_seconds_remaining()
	)

	server.send_notice(
		session, DotNotice.make(&"", _notice_text, ceilf(seconds), NOTICE_TOPIC)
	)


## Takes the line down once nothing it could be saying is true any more — a ballot that
## closed, a countdown an admin cancelled, a vote a game change swept away.
func _sync_notice() -> void:
	if not _notice_live:
		return

	if director.is_counting_down() or director.is_voting():
		return

	_notice_live = false
	_notice_text = ""
	server.broadcast_notice(DotNotice.clear(NOTICE_TOPIC))


## The id a session votes under. `u<userid>` matches [DotVoteCommands]'s default, which is what
## actually reads it — two spellings of one key is the shape of the bug where a module looks a
## session up by `peer_id` and gets null every time, silently.
func _voter_id(session: DotClientSession) -> StringName:
	return StringName("u%d" % session.userid)


func _session_for(voter: StringName) -> DotClientSession:
	var text := String(voter)

	if not text.begins_with("u"):
		return null

	var userid := text.substr(1)

	if not userid.is_valid_int():
		return null

	for session in server.sessions():
		if session.userid == userid.to_int():
			return session

	return null


func _physics_process(delta: float) -> void:
	_rescan_in -= delta

	if _rescan_in <= 0.0:
		_rescan()

	if director != null:
		_advance_director(delta)
		_sync_notice()

		if feed != null:
			feed.poll()


## Set by a suite that has no server to ask; the answer to [method change_under_way] when valid.
var change_under_way_fn: Callable = Callable()


## Whether a game change is being made right now: the manager is fetching, syncing or swapping,
## or the director has handed one to it and is waiting for the answer.
func change_under_way() -> bool:
	if change_under_way_fn.is_valid():
		return bool(change_under_way_fn.call())

	if director != null and director.state == DotVoteDirector.State.APPLYING:
		return true

	return server != null and server.games != null \
		and server.games.phase != DotGameManager.Phase.IDLE


## Ticks the director, except while a change it (or anybody) started is landing. [b]The clock stands
## still for that long.[/b] A change takes seconds (the server fetches, every client downloads, the
## swap happens) and during it the player count falls to 0 as clients drop out to follow.
func _advance_director(delta: float) -> void:
	if change_under_way():
		return

	director.advance(delta)


func _on_game_loaded(_content_key: String) -> void:
	var current := server.games.current()

	if current == null:
		return

	_rescan()
	_refresh_offer()
	director.begin(StringName(current.game_id))

	DotLog.info(CHANNEL, "the vote clock restarted for the new game", {
		"game": current.game_id, "limit": director.clock.formatted_remaining(),
	})



## One choice per GAME on the ballot, and none of the running game's other modes. [b]A game with
## several modes is several game ids over one content id[/b] (hungario: six), and
## [DotVoteGameSource] lists every id.
func _refresh_offer() -> void:
	var excluded: Array[StringName] = _operator_excluded.duplicate()
	if rotation != null:
		var plan := rotation.resolve(server.games.games)
		for id: StringName in plan["excluded"]:
			if not excluded.has(id):
				excluded.append(id)
		source.order = plan["order"]
	var current := server.games.current() if server != null and server.games != null else null
	var running := current.content_id if current != null else ""
	var seen := {}

	for descriptor: DotGameDescriptor in server.games.games:
		var id := StringName(descriptor.game_id)
		var key := descriptor.content_id

		if key == "" or excluded.has(id):
			continue

		if current != null and key == running and descriptor.game_id != current.game_id:
			excluded.append(id)
		elif key != running and seen.has(key):
			excluded.append(id)

		seen[key] = true

	source.excluded = excluded


## The loaded game's own vote directors (its map, mode or layout vote), found in the tree.
func game_directors() -> Array[DotVoteDirector]:
	var live: Array[DotVoteDirector] = []

	for d in _game_directors:
		if is_instance_valid(d) and d.is_inside_tree():
			live.append(d)

	_game_directors = live
	return live


## Whether the loaded game's own ballot is on screen, or counting down to it.
func game_ballot_up() -> bool:
	for d in game_directors():
		if d.is_voting() or d.is_counting_down():
			return true

	return false


## Whether this vote's ballot is on screen, or counting down to it.
func is_on_screen() -> bool:
	return director != null and (director.is_voting() or director.is_counting_down())


## Finds the game's directors, makes each wait for this vote, and hears its rounds.
func _rescan() -> void:
	_rescan_in = RESCAN_SEC

	if not is_inside_tree() or director == null:
		return

	var found: Array[DotVoteDirector] = []

	for node in get_tree().root.find_children("*", "DotVoteDirector", true, false):
		var d := node as DotVoteDirector

		if d == null or d == director or d.get_parent() is TmcVote:
			continue

		found.append(d)

		# Compared with the chain itself, not a flag: a game that assigns busy_fn again after
		# this ran (a director rebuilt on a map change) is chained again rather than missed.
		var chained: Variant = d.get_meta(CHAINED_META) if d.has_meta(CHAINED_META) else null

		if not (chained is Callable and d.busy_fn == chained):
			var theirs := d.busy_fn
			var mine: WeakRef = weakref(self)
			var chain := func() -> bool:
				if theirs.is_valid() and bool(theirs.call()):
					return true
				var votes: TmcVote = mine.get_ref()
				return votes != null and votes.is_on_screen()
			d.busy_fn = chain
			d.set_meta(CHAINED_META, chain)

	_game_directors = found

	var rounds: DotVoteDirector = null

	for d in found:
		if d.round_based:
			rounds = d
			break

	if rounds != _rounds_from:
		if _rounds_from != null and is_instance_valid(_rounds_from) \
				and _rounds_from.clock.round_ended.is_connected(_on_game_round_ended):
			_rounds_from.clock.round_ended.disconnect(_on_game_round_ended)

		_rounds_from = rounds
		_match_ref = null

		if rounds != null:
			rounds.clock.round_ended.connect(_on_game_round_ended)

	director.round_based = rounds != null


func _on_game_round_ended(_played: int, _limit: int) -> void:
	var _over := director.note_round_end()


## Whether the loaded game is playing a round right now: its dot-match match is LIVE. Asked by the
## director under [code]time_up: finish_round[/code] once the clock has run out.
func round_in_progress() -> bool:
	var found := _rounds_match()
	return found == null or found.state == DotMatch.State.LIVE


func _rounds_match() -> DotMatch:
	if _match_ref != null:
		var cached := _match_ref.get_ref() as DotMatch
		if cached != null and is_instance_valid(cached) and cached.is_inside_tree():
			return cached
		_match_ref = null

	# A game change frees the old game's director before the next periodic scan finds the
	# new one, and a freed director has no match beside it: scan now rather than answer for
	# a game that is gone.
	if _rounds_from != null and not is_instance_valid(_rounds_from):
		_rescan()

	if _rounds_from == null or not is_instance_valid(_rounds_from):
		return null

	var node: Node = _rounds_from

	while node != null:
		var matches := node.find_children("*", "DotMatch", true, false)

		if not matches.is_empty():
			var found := matches[0] as DotMatch
			_match_ref = weakref(found)
			return found

		if node == server or node == get_tree().root:
			break

		node = node.get_parent()

	return null


## Forgets a player who left. Their rock-the-vote goes and their nominations stay — dot-vote's
## asymmetry, and the reason for it is that a rock-the-vote is a fraction of the people who are
## here.
func _on_client_left(session: DotClientSession, _reason: String) -> void:
	director.forget_voter(_voter_id(session))


func describe_lines() -> PackedStringArray:
	if director == null:
		return PackedStringArray(["voting is off"])

	var out := director.describe_lines()
	out.append("hud line   %s" % (('"%s"' % _notice_text) if _notice_live else "none"))
	out.append("game's own votes %d%s" % [
		game_directors().size(), ", its ballot is up" if game_ballot_up() else "",
	])
	if director.round_based:
		var found := _rounds_match()
		out.append("its round  %s" % (
			"no match to ask (counted as live)" if found == null
			else DotMatch.State.keys()[found.state].to_lower()
		))
	return out


## One phrase for the boot banner: how this server counts.
func rules_summary() -> String:
	var rules := director.rules

	return "%s, ties by %s" % [
		rules.enum_name("method").replace("_", " "),
		rules.enum_name("tie_break").replace("_", " "),
	]


## The id a game goes by now, for an id an operator wrote: a `vote_exclude: [playground]` written
## before the rename has to keep the renamed game off the ballot. Unknown ids come back as given.
static func _current_id(games: Array, id: String) -> String:
	for descriptor: DotGameDescriptor in games:
		if descriptor != null and descriptor.game_id == id:
			return id

	for descriptor: DotGameDescriptor in games:
		if descriptor != null and TmcContent.answers_to_former(descriptor, id):
			return descriptor.game_id

	return id
