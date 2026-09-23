class_name TmcParty
extends Node

## Parties on this server: who from which party is here, a booking kept, party chat, and
## an optional matchmaking queue.
##
## [b]Three addons that were built and wired into nothing.[/b] dot-party had a server half
## that reports parties to the backbone and a node that keeps a booking, dot-matchmaking a
## whole queue, and no server this tool runs constructed any of them — the same shape
## `_build_logging` and `_build_security` in [code]tmc_host.gd[/code] were written to close,
## and this follows them: built for every game the host runs, configured from `cfg/`,
## never fatal.
##
## [b]What is built, and when.[/b]
##
## - [DotPartyReservations], always (unless `party_enabled: false`). With no booking it
##   admits everybody, so it costs nothing; with one it is the only thing that keeps a
##   private booking private. Bookings come from the backbone when there is one and from
##   `party_reserve` at the console either way.
## - [DotPartyServer], only with a backbone client — [TmcReport]'s, which exists when
##   `data/listing.json` carries an integration token. Every route it speaks is an
##   integration route, so without a credential it has nobody to report to.
## - [DotMatchmaker], only with `mm_enabled: true` in `cfg/matchmaking.yml`.
##
## [b]How a player says which party they are in: a chat command, not the handshake.[/b]
## The site has no "which party is this person in" route for a server, so the client has
## to say. The handshake payload would be the natural place and is the invasive one: the
## server reads a fixed set of keys out of it, and teaching it a new one is a change to
## dot-server's signon on both ends, in every project that links it, for one optional
## feature. A chat command is already a client-to-server channel with permissions, a rate
## limit and an audit line, and dot-server runs it before any game's chat hook can take
## the line. So the client shell sends `/party_claim <id>` once it has spawned, and
## [method DotPartyServer.claim] checks the roster before believing it — naming a party
## you are not in changes nothing.

const CHANNEL := "tmc.party"

## The seam dot-server asks on every join. See [method _rechain].
const BAN_SOURCE := &"dot_ban_source"

## Every chat router a game registers is under this name, or a scoped form of it.
const CHAT_SERVICE := "dot_chat_router"

## The grouped channel added to each game's router.
const PARTY_CHANNEL := &"party"

## How often one player may ask the backbone about a party. A claim is a network call
## on the server's credential, and a chat command is something anybody can type.
const CLAIM_EVERY_MS := 10000

var server: DotServer = null

## Reports parties to the backbone. Null without a backbone client.
var tracker: DotPartyServer = null

## Keeps a booking. Null only when `party_enabled` is off.
var reservations: DotPartyReservations = null

## The queue. Null unless `mm_enabled`.
var matchmaker: DotMatchmaker = null

var _config: TmcConfig = null

## userid -> Time.get_ticks_msec() of their last claim.
var _claims: Dictionary = {}

## Instance ids of chat routers already given the party channel.
var _wired_routers: Dictionary = {}

var _warned_fetch: bool = false


## Builds everything `cfg/party.yml` and `cfg/matchmaking.yml` ask for and attaches it
## to [param p_server]. [param backbone] is any object with `post_integration` and
## `get_integration` — dot-auth's backbone client — or null.
static func install(
	host: Node,
	p_server: DotServer,
	config: TmcConfig,
	backbone: Object,
	data_dir: String
) -> TmcParty:
	var node := TmcParty.new()
	node.name = "Parties"
	node.server = p_server
	node._config = config
	host.add_child(node)

	if config.party_enabled:
		node._build_reservations(backbone)
		node._build_tracker(backbone)
	else:
		DotLog.info(CHANNEL, "parties are off in cfg/party.yml")

	if config.mm_enabled:
		node._build_matchmaker(data_dir)

	node._register_commands()

	p_server.client_spawned.connect(node._on_spawned)
	p_server.client_disconnected.connect(node._on_left)

	# A game's module builds its chat router and its moderation manager when it loads,
	# which is after this on a `changelevel` and before it at boot. Watching the registry
	# catches both orders without this node having to know when a module finished loading.
	DotRegistry.signals().service_registered.connect(node._on_service_registered)
	DotRegistry.signals().service_unregistered.connect(node._on_service_unregistered)
	node._wire_chat_routers.call_deferred()

	DotLog.info(CHANNEL, "parties are up", {
		"tracking": node.tracker != null,
		"bookings": "backbone and console" if backbone != null else "console only",
		"chat": config.party_chat,
		"matchmaking": node.matchmaker != null,
	})

	return node


func _exit_tree() -> void:
	var bus := DotRegistry.signals()

	if bus.service_registered.is_connected(_on_service_registered):
		bus.service_registered.disconnect(_on_service_registered)

	if bus.service_unregistered.is_connected(_on_service_unregistered):
		bus.service_unregistered.disconnect(_on_service_unregistered)


# --- Building -----------------------------------------------------------------

func _build_reservations(backbone: Object) -> void:
	reservations = DotPartyReservations.new()
	reservations.name = "PartyReservations"
	reservations.config = _config.party
	reservations.policy = _config.party_policy
	reservations.server_id = _config.party_server_id

	# Seats a joining session would compete for: everybody past authentication. The one
	# being judged is still AUTHENTICATING and is not counted against itself.
	reservations.seats_fn = func() -> Vector2i:
		var occupied := 0

		for session in server.sessions():
			if session.state in [
				DotClientSession.State.DOWNLOADING,
				DotClientSession.State.LOADING,
				DotClientSession.State.SPAWNED,
			]:
				occupied += 1

		return Vector2i(occupied, server.config.max_players)

	# An owner locked out of their own server by a party is a support ticket. Admins are
	# resolved before dot-server asks the ban seam, so the flag is already on the session.
	reservations.bypass_fn = func(uid: String) -> bool:
		for session in server.sessions():
			if session.uid() == uid and session.has_permission(DotAdminFlags.RESERVATION):
				return true
		return false

	if backbone != null:
		reservations.use_backbone(backbone)
		_quiet_first_fetch_failure()

	reservations.reservation_started.connect(_on_booking_started)
	reservations.reservation_ending.connect(_on_booking_ending)
	reservations.reservation_ended.connect(_on_booking_ended)

	# Added under this node, so its `_ready` captures whatever already holds the ban seam
	# -- dot-moderation, from the game that is loaded -- and chains to it.
	add_child(reservations)


## `GET party/reservation` is a route the site does not serve yet (dot-party's
## docs/backbone-contract.md). Every sync is then a refusal, every 30 seconds, forever --
## so the first one is said once at INFO, with what it means, and the rest are left to
## the transport's own log.
func _quiet_first_fetch_failure() -> void:
	var fetch := reservations.fetch_fn

	reservations.fetch_fn = func() -> DotResult:
		var res: DotResult = await fetch.call()

		if not res.ok and not _warned_fetch:
			_warned_fetch = true
			DotLog.info(CHANNEL, "the backbone would not say whether this server is booked", {
				"why": str(res.error),
				"meaning": "bookings come from party_reserve at the console until it does",
			})

		return res


func _build_tracker(backbone: Object) -> void:
	if backbone == null:
		DotLog.info(CHANNEL, "no backbone client; parties are not reported to the site", {
			"hint": "an integration token in data/listing.json turns it on",
		})
		return

	tracker = DotPartyServer.new()
	tracker.name = "PartyTracker"
	tracker.config = _config.party
	tracker.client = backbone
	tracker.players_fn = _players
	tracker.report_failed.connect(func(what: String, error: DotError) -> void:
		DotLog.debug(CHANNEL, "a party report was refused", {"what": what, "why": str(error)})
	)
	add_child(tracker)


func _build_matchmaker(data_dir: String) -> void:
	matchmaker = DotMatchmaker.new()
	matchmaker.name = "Matchmaker"
	matchmaker.config = _config.matchmaking

	# Under `data/`, beside the bans and the audit log, unless the operator named a file.
	# `user://` is the addon's default and is a directory no operator of this tool looks in.
	if matchmaker.config.ratings_file == DotMatchmakingConfig.new().ratings_file:
		matchmaker.config.ratings_file = _absolute(data_dir).path_join("matchmaking/ratings.json")

	for pl in _config.mm_playlists:
		matchmaker.playlists.append(pl)

	if not _config.mm_servers.is_empty():
		var list := DotMmAllocatorList.new()

		for id in _config.mm_servers.keys():
			var row: Variant = _config.mm_servers[id]
			var d: Dictionary = row if row is Dictionary else {"address": str(row)}
			var allowed: Array = d.get("playlists", []) if d.get("playlists") is Array else []
			list.add_server(
				str(id), str(d.get("address", "")), str(d.get("region", _config.mm_region)), allowed
			)

		matchmaker.allocator = list

	var started := matchmaker.setup()

	if not started.ok:
		DotLog.error(CHANNEL, "the matchmaker would not start; matchmaking is off", {
			"why": str(started.error),
		})
		matchmaker = null
		return

	add_child(matchmaker)

	matchmaker.match_found.connect(_on_match_found)
	matchmaker.match_ready.connect(_on_match_ready)
	matchmaker.match_cancelled.connect(_on_match_cancelled)


static func _absolute(path: String) -> String:
	if path.contains("://") or path.begins_with("/"):
		return ProjectSettings.globalize_path(path)

	return ProjectSettings.globalize_path("res://").path_join(path)


# --- The ban seam, kept chained ------------------------------------------------

## A game's module registers dot-moderation under `dot_ban_source` when it loads, and the
## registry is last-wins — so the first `changelevel` after boot would quietly take the
## booking out of every admission. Re-registering on top, chained to whoever just arrived,
## keeps both asked.
func _on_service_registered(service: StringName, instance: Object) -> void:
	if service == BAN_SOURCE and reservations != null and instance != reservations:
		_rechain.call_deferred()
	elif String(service).begins_with(CHAT_SERVICE):
		_wire_chat_routers.call_deferred()


## The holder left (a module unloading): take the seam back so the booking still holds
## while the next game loads.
func _on_service_unregistered(service: StringName) -> void:
	if service == BAN_SOURCE and reservations != null:
		_rechain.call_deferred()


func _rechain() -> void:
	if reservations == null or not is_instance_valid(reservations):
		return

	var holder := DotRegistry.get_service(BAN_SOURCE)

	if holder == reservations:
		return

	# Already asked, somewhere down a chain that itself chains (dot-server-security's
	# feeds do). Putting this on top again would make the chain a loop and every
	# admission would recurse until the stack gave out.
	if _chain_reaches(holder, reservations):
		return

	if holder != null and is_instance_valid(holder) and holder.has_method("check_admission"):
		reservations.previous_source = holder
	elif reservations.previous_source != null and not is_instance_valid(reservations.previous_source):
		reservations.previous_source = null

	DotRegistry.register(BAN_SOURCE, reservations)
	DotLog.debug(CHANNEL, "party bookings chained onto the ban seam", {
		"previous": reservations.previous_source.get_class() if reservations.previous_source != null else "none",
	})


static func _chain_reaches(start: Object, target: Object) -> bool:
	var at := start

	for i in range(8):
		if at == null or not is_instance_valid(at):
			return false
		if at == target:
			return true
		var next: Variant = at.get("previous_source")
		at = next as Object if next is Object else null

	return false


# --- Party chat ------------------------------------------------------------------

## Gives every game chat router a grouped `party` channel, once each.
##
## [b]Only where the game has not said anything itself.[/b] A game that ships its own
## `party` channel, or its own `group_fn`, is the better-informed party and is left alone.
func _wire_chat_routers() -> void:
	if not _config.party_chat or reservations == null:
		return

	for service in DotRegistry.names():
		if not service.begins_with(CHAT_SERVICE):
			continue

		var router := DotRegistry.get_service(StringName(service))

		if router == null or not is_instance_valid(router) or not router.has_method("add_channel"):
			continue

		var key := router.get_instance_id()

		if _wired_routers.has(key):
			continue

		_wired_routers[key] = true

		if not router.call("has_channel", PARTY_CHANNEL):
			var added: Variant = router.call("add_channel", DotChatChannel.group(PARTY_CHANNEL, "Party"))

			if added is DotResult and not (added as DotResult).ok:
				DotLog.warn(CHANNEL, "the game's chat would not take a party channel", {
					"router": service, "why": str((added as DotResult).error),
				})
				continue

		var current: Variant = router.get("group_fn")

		if current is Callable and (current as Callable).is_valid():
			continue

		router.set("group_fn", func(peer: int, _channel: StringName) -> StringName:
			var session := server.session_of(peer)
			return StringName(party_id_of(session.uid())) if session != null else &""
		)

		DotLog.debug(CHANNEL, "party chat is on in the game's chat", {"router": service})


## Which party [param uid] is in on this server, or "".
##
## The tracker's answer when there is a tracker — it has checked a roster — and otherwise
## the booked party's, which a console booking fills from who was here.
func party_id_of(uid: String) -> String:
	if uid == "":
		return ""

	if tracker != null:
		var tracked := tracker.party_of(uid)
		if tracked != "":
			return tracked

	if reservations != null and reservations.is_member(uid):
		return reservations.party.id

	return ""


func _chat_router() -> Object:
	for service in DotRegistry.names():
		if service.begins_with(CHAT_SERVICE):
			var router := DotRegistry.get_service(StringName(service))
			if router != null and is_instance_valid(router) and router.has_method("submit"):
				return router
	return null


# --- Sessions -------------------------------------------------------------------

func _players() -> Array:
	var out := []

	for session in server.playing_sessions():
		out.append({
			"name": session.display_name,
			"uid": session.uid(),
			"score": session.score,
			"seconds": session.connected_seconds(),
		})

	return out


func _on_spawned(session: DotClientSession) -> void:
	var uid := session.uid()

	if reservations != null:
		reservations.note_arrival(uid)

	if tracker != null and not tracker.parties.is_empty():
		tracker.player_joined({"name": session.display_name, "uid": uid})


func _on_left(session: DotClientSession, _reason: String) -> void:
	var uid := session.uid()
	_claims.erase(session.userid)

	if reservations != null:
		reservations.note_departure(uid)

	if tracker == null:
		return

	var pid := tracker.party_of(uid)

	if not tracker.parties.is_empty():
		tracker.player_left({"name": session.display_name, "uid": uid})

	# The last of a party gone: stop reporting it, unless it is the one this server is
	# booked for, which is still expected.
	if pid != "" and not _anyone_here_from(pid, session) \
			and not (reservations != null and reservations.current != null \
				and reservations.current.party_id == pid):
		tracker.untrack(pid)

	if matchmaker != null:
		matchmaker.cancel(_ticket_id(session))


func _anyone_here_from(pid: String, leaving: DotClientSession) -> bool:
	for other in server.sessions():
		if other != leaving and other.is_active() and tracker.party_of(other.uid()) == pid:
			return true
	return false


func _on_booking_started(r: DotPartyReservation, p: DotParty) -> void:
	if tracker != null and p != null:
		tracker.track(p)

	_announce("This server is booked for %s%s until %s UTC." % [
		"a private party" if r.is_private else "a party",
		(" (%s)" % p.name) if p != null and p.name != "" else "",
		Time.get_datetime_string_from_unix_time(r.ends_at, true).substr(11, 5),
	])


func _on_booking_ending(_r: DotPartyReservation, seconds_left: int) -> void:
	_announce("The party booking ends in %d minutes." % ceili(seconds_left / 60.0))


func _on_booking_ended(_r: DotPartyReservation, reason: String) -> void:
	_announce("The party booking is over (%s)." % reason)


func _announce(line: String) -> void:
	DotLog.info(CHANNEL, line)

	if server.chat != null:
		server.chat.broadcast_system(line)


# --- Console --------------------------------------------------------------------

func _register_commands() -> void:
	var console := server.console

	if console == null:
		return

	console.command(
		"party_status", _cmd_status, "Parties on this server, the booking, and the queue",
		DotAdminFlags.GENERIC
	).with_chat()

	# Everybody: this is how the client shell says which party it is in. The roster
	# check is the boundary, not the permission.
	console.command(
		"party_claim", _cmd_claim, "Say which party you are in: party_claim <partyId>", ""
	).with_args(1, 1).with_chat()

	console.command(
		"party_say", _cmd_say, "Talk to your party: party_say <text>", ""
	).with_args(1).with_chat()

	# The owner's act, gated as configuration is. RCON and the terminal are where an
	# owner books their own server for a group of friends.
	console.command(
		"party_reserve", _cmd_reserve,
		"Book this server for a party: party_reserve <partyId> <minutes> [private]",
		DotAdminFlags.CONFIG
	).with_args(2, 3)

	console.command(
		"party_release", _cmd_release, "End the party booking now", DotAdminFlags.CONFIG
	)

	console.command(
		"mm_status", _cmd_mm_status, "The matchmaking queues", DotAdminFlags.GENERIC
	).with_chat()

	if matchmaker != null:
		console.command(
			"mm_queue", _cmd_mm_queue, "Queue for a playlist, with your party: mm_queue <playlist>", ""
		).with_args(1, 1).with_chat()
		console.command("mm_leave", _cmd_mm_leave, "Leave the matchmaking queue", "").with_chat()
		console.command(
			"mm_accept", _cmd_mm_accept, "Accept a match you were offered: mm_accept <matchId>", ""
		).with_args(1, 1).with_chat()
		console.command(
			"mm_decline", _cmd_mm_decline, "Decline a match: mm_decline <matchId>", ""
		).with_args(1, 1).with_chat()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if not _config.party_enabled:
		out.append("parties: off (cfg/party.yml)")
	else:
		out.append("parties: %s, chat %s" % [
			"reported to the site" if tracker != null else "not reported (no backbone client)",
			"on" if _config.party_chat else "off",
		])

		if tracker != null:
			out.append_array(tracker.describe_lines())

		if reservations != null:
			out.append_array(reservations.describe_lines())

	out.append(
		"matchmaking: off (cfg/matchmaking.yml)" if matchmaker == null
		else "matchmaking: %d queue(s)" % matchmaker.playlists.size()
	)

	return out


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(describe_lines())


func _cmd_claim(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if session == null:
		ctx.reply("party_claim is for a player in the game.")
		return

	if tracker == null:
		# Not an error from the player's side. Their party still works on the site; this
		# server just has nobody to ask about it.
		ctx.reply("This server does not track parties.")
		return

	var now := Time.get_ticks_msec()

	if now - int(_claims.get(session.userid, -CLAIM_EVERY_MS)) < CLAIM_EVERY_MS:
		ctx.reply("Please wait a moment before claiming a party again.")
		return

	_claims[session.userid] = now

	var res: DotResult = await tracker.claim(session.uid(), ctx.arg(0))

	if not res.ok:
		DotLog.info(CHANNEL, "a party claim was refused", {
			"user": session.label(), "party": ctx.arg(0), "why": res.error.message,
		})
		ctx.reply(res.error.message)
		return

	var p: DotParty = res.value
	ctx.reply("You are playing with your party%s." % ((" %s" % p.name) if p.name != "" else ""))


func _cmd_say(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if session == null:
		ctx.reply("party_say is for a player in the game.")
		return

	var pid := party_id_of(session.uid())

	if pid == "":
		ctx.reply("You are not in a party on this server.")
		return

	var text := ctx.rest(0)
	var router := _chat_router()

	if router != null and bool(router.call("has_channel", PARTY_CHANNEL)):
		var sent: Variant = router.call("submit", session.peer_id, PARTY_CHANNEL, text)

		if sent is DotResult and not (sent as DotResult).ok:
			ctx.reply((sent as DotResult).error.message)
		return

	# A game with no dot-chat router. dot-server's own chat has no channels, so the line
	# goes to each party member as a system line — the same audience, a plainer look.
	if server.chat == null:
		ctx.reply("This game has no chat.")
		return

	var line := "(PARTY) %s: %s" % [session.display_name, DotChatManager.sanitise(text, 200)]

	for other in server.playing_sessions():
		if party_id_of(other.uid()) == pid:
			server.chat.send_system_to(other, line)


func _cmd_reserve(ctx: DotCmdContext) -> void:
	if reservations == null:
		ctx.reply("Parties are off in cfg/party.yml.")
		return

	var party_id := ctx.arg(0)
	var minutes := ctx.arg_int(1)
	var want_private := ctx.arg(2).to_lower() in ["private", "1", "true", "yes"]

	if not DotParty.is_id(party_id):
		ctx.reply("That is not a party id (a number, as the site shows it).")
		return

	var p: DotParty = null

	if tracker != null:
		var fetched: DotResult = await tracker.refresh(party_id)

		if not fetched.ok:
			ctx.reply("Could not read that party from the site: %s" % fetched.error.message)
			return

		p = fetched.value
	else:
		# No backbone to ask for a roster, so the party is everybody here who is signed
		# in: "book this server for us". A guest cannot be recognised on the way back in
		# -- a guest uid is a random per-device string -- so a guest is not counted.
		p = _party_of_everybody_here(party_id)
		ctx.reply("No backbone to read the roster from; booking for the %d signed-in player(s) here." % p.size())

	# [b]The owner is not held to the terms they offer parties.[/b] `party_reserve_*` in
	# cfg/party.yml is what a party booking on the site may ask for; an owner at their own
	# console booking their own server is a different act. So the owner's terms stand in
	# for this one booking with the gates opened and the ceiling kept.
	var terms := reservations.policy
	var owner := terms.duplicate() as DotPartyReservePolicy
	owner.enabled = true
	owner.lobbies = DotPartyReservePolicy.Lobbies.PUBLIC_AND_PRIVATE
	owner.empty_only = false
	owner.cooldown_minutes = 0
	owner.days = []
	owner.from_minute = 0
	owner.to_minute = 0
	reservations.policy = owner
	var booked := reservations.book(p, minutes, want_private)
	reservations.policy = terms

	if not booked.ok:
		ctx.reply("Not booked: %s" % booked.error.message)
		return

	var r: DotPartyReservation = booked.value
	ctx.reply("Booked for party %s, %s, until %s UTC." % [
		p.id, "private" if r.is_private else "public",
		Time.get_datetime_string_from_unix_time(r.ends_at, true).substr(11, 5),
	])


func _party_of_everybody_here(party_id: String) -> DotParty:
	var p := DotParty.new()
	p.id = party_id
	p.name = "party %s" % party_id

	for session in server.sessions():
		var uid := session.uid()
		if session.is_active() and uid.begins_with("backbone:"):
			p.roster.append(DotPartyMember.of(uid.trim_prefix("backbone:"), session.display_name))

	p.max_users = maxi(p.roster.size(), 2)
	return p


func _cmd_release(ctx: DotCmdContext) -> void:
	if reservations == null or reservations.current == null:
		ctx.reply("There is no party booking.")
		return

	reservations.release("released")
	ctx.reply("The party booking is released.")


# --- Matchmaking ----------------------------------------------------------------

func _cmd_mm_status(ctx: DotCmdContext) -> void:
	if matchmaker == null:
		ctx.reply("Matchmaking is off (mm_enabled in cfg/matchmaking.yml).")
		return

	ctx.reply_lines(matchmaker.describe_lines())


## A session's id in the queue. The account uid when there is one, because a rating
## belongs to a person; `u<userid>` for a guest, whose rating belongs to nobody.
func _player_id(session: DotClientSession) -> String:
	var uid := session.uid()
	return uid if uid.begins_with("backbone:") else "u%d" % session.userid


func _ticket_id(session: DotClientSession) -> String:
	var pid := party_id_of(session.uid())
	return "party-%s" % pid if pid != "" else "solo-%d" % session.userid


func _session_for(player_id: String) -> DotClientSession:
	for session in server.sessions():
		if _player_id(session) == player_id:
			return session
	return null


func _cmd_mm_queue(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if session == null:
		ctx.reply("mm_queue is for a player in the game.")
		return

	# A party queues whole, or not at all: everybody from it who is here goes on one
	# ticket, and the matchmaker's promise is never to split one.
	var ids := PackedStringArray()
	var latencies := []
	var pid := party_id_of(session.uid())

	for other in server.playing_sessions():
		if other == session or (pid != "" and party_id_of(other.uid()) == pid):
			ids.append(_player_id(other))
			latencies.append({_config.mm_region: maxi(other.ping_ms, 0)})

	var res := matchmaker.enqueue(
		_ticket_id(session), StringName(ctx.arg(0)), ids, latencies, pid
	)

	if not res.ok:
		ctx.reply(res.error.message)
		return

	ctx.reply("Queued for %s%s." % [ctx.arg(0), " with your party" if ids.size() > 1 else ""])


func _cmd_mm_leave(ctx: DotCmdContext) -> void:
	if ctx.session == null:
		return

	ctx.reply("Left the queue." if matchmaker.cancel(_ticket_id(ctx.session)) else "You are not queued.")


func _cmd_mm_accept(ctx: DotCmdContext) -> void:
	if ctx.session == null:
		return

	var res := matchmaker.accept(ctx.arg(0), _player_id(ctx.session))
	ctx.reply("Accepted." if res.ok else res.error.message)


func _cmd_mm_decline(ctx: DotCmdContext) -> void:
	if ctx.session == null:
		return

	var res := matchmaker.decline(ctx.arg(0), _player_id(ctx.session))
	ctx.reply("Declined." if res.ok else res.error.message)


func _tell(player_ids: PackedStringArray, line: String) -> void:
	if server.chat == null:
		return

	for id in player_ids:
		var session := _session_for(id)
		if session != null:
			server.chat.send_system_to(session, line)


func _on_match_found(m: DotMmMatch, _deadline: float) -> void:
	_tell(m.player_ids(), "A match was found. Type /mm_accept %s to play." % m.id)


func _on_match_ready(m: DotMmMatch) -> void:
	var where := str(m.allocation.get("address", ""))
	_tell(m.player_ids(), "Your match is ready%s." % ((" on %s" % where) if where != "" else ""))


func _on_match_cancelled(m: DotMmMatch, reason: String, _requeued: PackedStringArray) -> void:
	_tell(m.player_ids(), "The match fell through (%s)." % reason)
