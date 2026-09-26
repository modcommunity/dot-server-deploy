class_name TmcFriends
extends Node

## The signed-in player's friends: who is online and where, this player's own presence kept
## posted as they connect, change game and leave, and "join my friend".
##
## [b]dot-friends was the other addon in the family that nothing constructed.[/b] The site's
## friends and presence routes were specified with it and it had a client, a backend for the
## site and a suite -- and no game, no tool and no shell built one, so a friend could not
## see that anybody was playing, let alone where. The shell already runs a dot-party client
## the same way; this sits beside it and is built at the same moment, from the same
## sign-in, over the same dot-auth client.
##
## [b]Why a node of this project's rather than a [DotFriendsClient] inside `shell.gd`.[/b]
## Everything here is decided by the shell's connection -- which server, which game, which
## party, whether the player is in a match or on the menu -- and none of it needs the menu.
## As its own node the suite can drive the whole of it against a local hub and a stand-in
## 404, with no window, no sign-in and no server; inside the shell it could only be reached
## by booting the shell, which signs in against a real site.
##
## [b]A 404 switches it off for the session, quietly.[/b] The routes are on website-city's
## `feat/game-backbone` branch, unmerged. Until they are deployed every request is a 404,
## and the party client beside this one already made the call for the family: the first
## one turns the feature off with one INFO line (dot-friends' own, naming the missing routes;
## this file's is DEBUG for that case) rather than asking every thirty seconds for
## something the site has said it does not have. A keyed 404 (a refusal the site explained)
## is not the site lacking routes, and does not.
##
## [b]Where a friend can be followed.[/b] A presence carries the site's server id, and the
## shell only knows addresses. So "join my friend" prefers the party -- dot-party's own join,
## which already follows a party to its server -- and falls back to the server only when
## this shell has been on that server itself and so knows its address. Anything else is
## refused with the site's own `friends.join.deny.unsupported`, honestly, rather than by
## inventing a lookup the site does not offer: the address of a server is gated on that
## server's own `showNetInfo`, and a presence that leaked it would bypass the gate.

const CHANNEL := "tmc.friends"

## The list or a presence in it changed. For the menu.
signal list_changed(friends: Array)

## The feature turned itself off for the session. [param why] is for a log, not a player.
signal switched_off(why: String)

var client: DotFriendsClient = null

## True once a 404 has turned this off. Nothing is polled or posted after that.
var off: bool = false
var off_reason: String = ""

## [code]func(party_id: String, friend: DotFriend) -> DotResult[/code], awaited. The shell's
## party client's join. Unset without a party client, and then a friend's party is not a
## route.
var join_party_fn: Callable = Callable()

## [code]func(address: String) -> void[/code], awaited. The shell's own Connect.
var connect_address_fn: Callable = Callable()

## Site server id -> the address this shell reached it at. Learned, never asked for.
var _known_servers: Dictionary = {}
var _playing: bool = false


## A friends node over [param backend], with [param config] or the addon's defaults.
static func build(backend: DotFriendsBackend, config: DotFriendsConfig = null) -> TmcFriends:
	var node := TmcFriends.new()
	node.name = "Friends"
	node.client = DotFriendsClient.new()
	node.client.name = "Client"
	node.client.backend = backend
	node.client.config = config if config != null else DotFriendsConfig.new()
	node.add_child(node.client)
	return node


func _ready() -> void:
	client.join_party_fn = _join_party
	client.connect_fn = _connect_server
	client.request_failed.connect(_on_request_failed)
	client.friends_changed.connect(func(list: Array) -> void: list_changed.emit(list))
	client.friend_presence_changed.connect(func(_f: DotFriend, _old: DotPresence) -> void:
		list_changed.emit(client.friends))
	# On the menu, not joinable: there is nowhere to follow this player to yet.
	client.set_status(DotPresence.Status.ONLINE)
	client.set_joinable(false)


# --- This player's presence -------------------------------------------------------

## Signon finished on [param address]. [param site_server_id] is what the server's
## challenge named (`auth.yml`'s `server_id`) -- the site's id for a server that issues
## tickets, and nothing a presence can use otherwise.
func on_playing(address: String, site_server_id: String, game_name: String, hostname: String) -> void:
	if client == null:
		return
	_playing = true
	var sid := int(site_server_id) if site_server_id.is_valid_int() else 0
	if sid > 0:
		_known_servers[sid] = address
	client.set_status(DotPresence.Status.IN_GAME)
	client.set_server(sid)
	client.set_joinable(true)
	_set_detail(game_name, hostname)


## The server changed game under a connected player.
func on_game_changed(game_name: String, hostname: String) -> void:
	if client == null or not _playing:
		return
	_set_detail(game_name, hostname)


## The connection ended, whichever way. Back on the menu, and not followable.
func on_disconnected() -> void:
	if client == null:
		return
	_playing = false
	client.set_status(DotPresence.Status.ONLINE)
	client.set_server(0)
	client.set_joinable(false)
	client.set_detail("")


## [param party_id] is the player's party, "" for none. A friend can then follow them into
## it, which is the route that works whether or not the site's server id is known.
func on_party(party_id: String) -> void:
	if client != null:
		client.set_party(party_id)


func _set_detail(game_name: String, hostname: String) -> void:
	var line := "Playing %s" % game_name if game_name != "" else "Playing"
	if hostname != "":
		line += " on %s" % hostname
	# Cut here rather than refused: the addon refuses an over-long line so that a game says
	# it better, and a server's hostname is the operator's to choose, not this shell's.
	client.set_detail(line.left(DotPresence.DETAIL_MAX))


## Posts "offline" now. The shell awaits it on quit, so friends do not see a player who
## has gone for the two minutes a presence otherwise lives.
func go_offline() -> DotResult:
	if off or client == null or client.backend == null:
		return DotResult.success(null)
	return await client.go_offline()


# --- Following a friend -------------------------------------------------------------

## Takes the player to [param user_id], through [method DotFriendsClient.join].
func join(user_id: String) -> DotResult:
	if off or client == null:
		return DotResult.fail(DotError.CODE_STATE, "Friends are not available right now.")
	return await client.join(user_id)


func _join_party(party_id: String, friend: DotFriend) -> DotResult:
	if not join_party_fn.is_valid():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "No party client.", "friends.join.deny.unsupported")
	var res: Variant = await join_party_fn.call(party_id, friend)
	return res if res is DotResult else DotResult.success(res)


func _connect_server(server_id: int, friend: DotFriend) -> DotResult:
	if not _known_servers.has(server_id) or not connect_address_fn.is_valid():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This game cannot follow %s there." % friend.display_name,
			"friends.join.deny.unsupported"
		)
	await connect_address_fn.call(str(_known_servers[server_id]))
	return DotResult.success(null)


# --- Switching off ------------------------------------------------------------------

func _on_request_failed(what: String, error: DotError) -> void:
	if error == null:
		return

	if error.http_status == 404 and error.detail == "":
		# At DEBUG, because `DotFriendsBackendApp` has just said this at INFO — once, as
		# the one line a site without the routes costs. Two INFO lines for one fact was
		# what this file's note used to apologise for.
		switch_off("the site does not serve friends routes yet", what, DotLog.Level.DEBUG)
		return

	DotLog.debug(CHANNEL, "a friends request failed", {"what": what, "why": error.message})


## Stops everything. The node stays -- a request already in flight resumes into it, and a
## freed one would be a coroutine resuming on nothing -- but with no backend it polls,
## posts and follows nobody.
func switch_off(why: String, what: String = "", level: int = DotLog.Level.INFO) -> void:
	if off:
		return
	off = true
	off_reason = why
	client.backend = null
	client.set_process(false)
	DotLog.at(level, CHANNEL, "friends are off for this session", {"why": why, "what": what})
	switched_off.emit(why)
	list_changed.emit([])


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if off:
		out.append("friends: off (%s)" % off_reason)
		return out
	if client == null:
		out.append("friends: not built")
		return out
	out.append_array(client.describe_lines())
	out.append("  follows: party %s, servers known %d" % [
		"yes" if join_party_fn.is_valid() else "no", _known_servers.size(),
	])
	return out
