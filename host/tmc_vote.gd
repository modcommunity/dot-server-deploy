class_name TmcVote
extends Node

## Voting for the next game, on this server.
##
## [b]This is the first place in the family anybody votes for a GAME.[/b] dot-map has
## voted for maps since it was written and two games use it; nothing has ever voted for
## what the server should be running, because until this project there was nowhere a
## server ran more than one. There are five games in `content/` and `changelevel`
## switches between them under live players — so the only thing missing was letting the
## players ask.
##
## [codeblock]
## !game_nominate g2gfast
## !game_rtv
## Vote: g2gfast, playground, hungry_frenzy (30s)
## !game_vote 1
## [/codeblock]
##
## [b]Every one of those is prefixed, and the prefix is the whole reason this works.[/b]
## A game loaded out of `content/` may run a vote of its own — g2gfast votes for the
## next MAP, which is what a records server has always done — and that game's module
## registers `rtv`, `nominate`, `timeleft` and `nextmap` before this file is ever
## installed. [DotConsole] keeps the first registration of a name and returns it, so an
## unprefixed game vote does not fail: it silently gets four dead commands and nine live
## ones, and a player types `!nominate arena`, is told there is no such map, then types
## `!nominations` and is shown an empty GAME ballot. Worse, those four names belong to
## the game's module, so the first `changelevel` away takes them out of the console for
## the rest of the process and nothing puts them back.
##
## So the server-level vote namespaces itself and the game keeps the names players'
## fingers already know. [code]!rtv[/code] is always about what the game in front of you
## is doing; [code]!game_rtv[/code] is always about which game is next.
##
## Everything about how that behaves is `cfg/vote.yml`, which is a [DotVoteRules] and
## therefore the same fifty-five settings dot-vote documents. This file is only the
## wiring: who counts as a player, who counts as an admin, where the announcements go,
## and which games are not on the ballot.
##
## [b]Heard in chat, and seen and heard on the shell's HUD.[/b]
## [method DotVoteDirector.announce_fn] is chat, as it always was. The countdown to a
## ballot, the ballot's own time and every [signal DotVoteDirector.cue] go out as
## [DotNotice]s — dot-server's one message to the client APPLICATION rather than to the
## game on screen — and the shell's [code]TmcNoticeOverlay[/code] draws the line and plays
## the cue out of its own catalogue. It was chat only until 2026-09-24, because the shell
## had no channel but chat and a loaded game's wire is the game's; the pair that closed it
## changed the signon revision, which is written up in dot-server's CLAUDE.md.
##
## [b]One HUD line, [constant NOTICE_TOPIC], and this file owns it.[/b] Each countdown
## second replaces it; the ballot replaces it with its own time; and it is taken down by
## [method _physics_process] the moment the director is neither counting down nor voting —
## polled rather than signalled, because [method DotVoteDirector.cancel_countdown] emits
## nothing, and a countdown an admin called off would otherwise run to zero on every
## screen for a ballot that never opens.
##
## [b]One game is nothing to vote about.[/b] A server whose content offers one game —
## after `vote_exclude`, and counting a game's several modes as one ([method votable_count])
## — installs no game vote at all: no `!game_*` commands, no clock, no
## ballot asking the players to choose between that game and extending it. The game's own
## MAP vote is then the only vote on the server, and it is unaffected either way: it runs
## inside the game, on its own rules, with or without this one beside it. Where there are
## two games or more, both run at once — the game vote on its clock and the map vote on its
## own — which is why every command here is prefixed and the two ballots carry different
## topics to the shell.
##
## [b]The ballot is drawn, not only typed.[/b] [DotVoteBallotFeed] sends the open ballot as
## a notice's [code]data[/code] under [constant BALLOT_TOPIC] whenever it changes, to each
## playing session with that session's own voter id, and the shell's [TmcNoticeOverlay]
## draws it as a [DotBallotPanel]: number keys, a click, and every voter's avatar on what
## they chose. A shell built before the field ignores it and still has the HUD line.
##
## [b]The lobby is excluded by default and that is a real decision.[/b] It is this
## server's home screen rather than a game, and "vote to go back to the menu" is not a
## thing anybody votes for. An operator who disagrees empties `vote_exclude`.

const CHANNEL := "tmc.vote"

## Games never offered on a ballot, unless `vote.yml` says otherwise.
const DEFAULT_EXCLUDED := ["lobby"]

## What every console command of the server-level vote is called.
##
## See the class documentation: a game's own vote gets the bare names.
const COMMAND_PREFIX := "game_"

## The two roles whose default name would be a lie on a vote about games.
##
## `nextmap` is not a map here, and `votefor` next to `game_` reads as a verb phrase
## nobody types twice. Everything else keeps dot-vote's own name behind the prefix.
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

var server: DotServer = null

## Whether clients have been told a line is up, so it is taken down exactly once.
var _notice_live := false

## What the line says, without its number: kept so a player who joins mid-countdown is
## shown the same sentence everybody else is looking at.
var _notice_text := ""


## Builds the whole thing and attaches it to [param p_server].
##
## Returns null when voting is turned off, or when fewer than [constant MIN_GAMES] games are
## on offer — both legitimate configurations, not errors: a single-game server has nothing
## to vote about, and its game's own map vote carries on regardless.
static func install(
	host: Node,
	p_server: DotServer,
	rules: DotVoteRules,
	excluded: PackedStringArray
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
		source.excluded.append(StringName(id))

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
	# DotRegistry is last-wins, so leaving this on means every game's own vote is
	# quietly displaced in the registry by the server's the moment the host boots —
	# and a HUD that resolves the service to draw the ballot in front of the player
	# would draw the wrong one. This director is reached through TmcVote, which the
	# host holds, so it needs no global name at all.
	votes.director.register_service = false

	votes._wire()

	host.add_child(votes)
	votes.add_child(votes.director)

	votes.commands = DotVoteCommands.new()
	votes.commands.director = votes.director
	votes.commands.prefix = COMMAND_PREFIX
	votes.commands.names = COMMAND_NAMES

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
	votes.feed.command = COMMAND_PREFIX + COMMAND_NAMES["vote"]
	votes.feed.people_fn = votes._person

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
##
## [b]By content id, not by game id[/b], because one game can register several: hungario's
## five modes are five game ids over one `tmc/hungry`, and its own map vote is already a
## vote over exactly those five. A server running only hungario counted as five games would
## put two ballots over the same choice on every screen. A descriptor with no content id is
## a game of its own.
static func votable_count(p_source: DotVoteGameSource, manager: DotGameManager) -> int:
	var games := {}

	for choice in p_source.choices():
		if not choice.enabled:
			continue

		var descriptor := manager.find_game(String(choice.id)) if manager != null else null
		var key := String(choice.id)

		if descriptor != null and descriptor.content_id != "":
			key = descriptor.content_id

		games[key] = true

	return games.size()


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

	# The map flag, which is what the vote's admin commands are gated on too. This asked
	# for "changelevel" — the name of a COMMAND, not a flag anybody holds — and
	# DotAdminFlags.granted matches exactly, so only root was ever an admin here: an
	# admin's nomination never bypassed a cap and rtv_admin_instant never fired.
	director.is_admin_fn = func(voter: StringName) -> bool:
		var session := _session_for(voter)
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)

	# A votekick on screen: a ballot opened on top of it would be two menus fighting for
	# the same number keys. The due vote waits, through dot-vote's own retry.
	director.busy_fn = func() -> bool:
		return server.votes != null and server.votes.is_active()

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


# --- The HUD ------------------------------------------------------------------

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
		"Vote for the next game: !%s%s 1-%d" % [
			COMMAND_PREFIX, COMMAND_NAMES["vote"], options.size()
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


## The id a session votes under.
##
## `u<userid>` matches [DotVoteCommands]'s default, which is what actually reads it —
## two spellings of one key is the shape of the bug where a module looks a session up
## by `peer_id` and gets null every time, silently.
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
	if director != null:
		director.advance(delta)
		_sync_notice()

		if feed != null:
			feed.poll()


func _on_game_loaded(_content_key: String) -> void:
	var current := server.games.current()

	if current == null:
		return

	director.begin(StringName(current.game_id))

	DotLog.info(CHANNEL, "the vote clock restarted for the new game", {
		"game": current.game_id, "limit": director.clock.formatted_remaining(),
	})


## Forgets a player who left.
##
## Their rock-the-vote goes and their nominations stay — dot-vote's asymmetry, and the
## reason for it is that a rock-the-vote is a fraction of the people who are here.
func _on_client_left(session: DotClientSession, _reason: String) -> void:
	director.forget_voter(_voter_id(session))


func describe_lines() -> PackedStringArray:
	if director == null:
		return PackedStringArray(["voting is off"])

	var out := director.describe_lines()
	out.append("hud line   %s" % (('"%s"' % _notice_text) if _notice_live else "none"))
	return out


## One phrase for the boot banner: how this server counts.
func rules_summary() -> String:
	var rules := director.rules

	return "%s, ties by %s" % [
		rules.enum_name("method").replace("_", " "),
		rules.enum_name("tie_break").replace("_", " "),
	]
