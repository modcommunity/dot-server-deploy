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

var director: DotVoteDirector = null
var source: DotVoteGameSource = null
var commands: DotVoteCommands = null

var server: DotServer = null


## Builds the whole thing and attaches it to [param p_server].
##
## Returns null when voting is turned off, which is a legitimate configuration and not
## an error: a single-game server has nothing to vote about.
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

	var votes := TmcVote.new()
	votes.name = "Votes"
	votes.server = p_server

	votes.source = DotVoteGameSource.of(p_server.games)

	for id in excluded:
		votes.source.excluded.append(StringName(id))

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

	p_server.games.game_loaded.connect(votes._on_game_loaded)
	p_server.client_disconnected.connect(votes._on_client_left)

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

	director.is_admin_fn = func(voter: StringName) -> bool:
		var session := _session_for(voter)
		return session != null and session.has_permission("changelevel")

	director.is_spectator_fn = func(voter: StringName) -> bool:
		var session := _session_for(voter)
		# Not "is a spectator" — "is not playing". A voter this server has never heard
		# of is the console, and the console is not a spectator either; the guard that
		# matters is the one on a connected client that has not entered the game.
		return session != null and not session.is_playing()

	director.announce_fn = func(line: String) -> void:
		if server.chat != null:
			server.chat.broadcast_system(line)


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

	return director.describe_lines()


## One phrase for the boot banner: how this server counts.
func rules_summary() -> String:
	var rules := director.rules

	return "%s, ties by %s" % [
		rules.enum_name("method").replace("_", " "),
		rules.enum_name("tie_break").replace("_", " "),
	]
