extends Node

## Parties on a real server: the booking keeper, the tracker, party chat and the console.
##
## [codeblock]
## godot --headless --path . res://examples/party_live.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## Drives the real [TmcHost] boot, as `multigame` does, because every part of [TmcParty]
## is about ORDER — the booking has to be on the ban seam after the game's module put
## dot-moderation there, and still on it after a `changelevel` put a new one there — and a
## fixture that built the pieces itself would have an order of its own.
##
## The backbone is a stand-in that answers `GET party/{id}` with a roster, because the
## routes a party tracker speaks are integration routes and this suite has no site. It is
## duck-typed exactly as the real client is: [TmcParty] never names dot-auth.

const CONFIG := "res://examples/fixtures/multigame"
const CONTENT := "res://content"
const DATA := "user://tmc_party_live"

const CHECKS := 25

const BAN_SOURCE := &"dot_ban_source"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _host: Node = null


## The site, as far as a party tracker can tell: one party, one member.
class FakeBackbone extends RefCounted:
	var posted: Array = []

	func get_integration(path: String, _query: Dictionary = {}) -> DotResult:
		if path == "party/123":
			return DotResult.success({
				"party": {"id": "123", "name": "Friends", "maxUsers": 4, "stage": "PLAYING"},
				"members": [
					{"userId": "7", "displayName": "Ada", "role": "HOST"},
					{"userId": "8", "displayName": "Bo"},
				],
			})
		return DotResult.fail(DotError.CODE_HTTP, "no such party", path)

	func post_integration(path: String, body: Dictionary) -> DotResult:
		posted.append({"path": path, "body": body})
		return DotResult.success({"ok": true})


## What a session reads its uid from. dot-auth's identity has more; this is what is asked.
class FakeIdentity extends RefCounted:
	var uid: String = ""
	var display_name: String = ""


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: parties")

	DotPaths.remove_tree(DATA)

	if await _boot():
		_test_built()
		_test_party_chat()
		await _test_claim()
		await _test_booking()
		await _test_survives_a_game_change()

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

	# The total the section counter cannot be. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

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


func _parties() -> TmcParty:
	return _host.get("parties") as TmcParty


## Runs a console line as [param session] would from chat, and returns what it said.
##
## An Array, because a lambda captures by value and only a container's contents survive.
func _say(line: String, session: DotClientSession = null) -> Array:
	var answered: Array = []
	var ctx := DotCmdContext.internal("", PackedStringArray())
	ctx.session = session
	ctx.reply_sink = func(text: String) -> void: answered.append(text)
	_server().console.execute(line, ctx)
	return answered


func _until(condition: Callable, seconds: float = 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame

	return bool(condition.call())


func _session(userid: int, uid: String, display: String) -> DotClientSession:
	var s := DotClientSession.new(userid, 9000 + userid)
	var id := FakeIdentity.new()
	id.uid = uid
	id.display_name = display
	s.identity = id
	s.display_name = display
	return s


func _chat_router() -> Object:
	for service in DotRegistry.names():
		if service.begins_with("dot_chat_router"):
			return DotRegistry.get_service(StringName(service))
	return null


# --- Boot ------------------------------------------------------------------

func _boot() -> bool:
	print("")
	print("booting")

	var packed: Variant = load("res://host/host.tscn")
	_host = (packed as PackedScene).instantiate()
	_host.auto_start = false
	add_child(_host)

	var started: DotResult = await _host.start(CONFIG, CONTENT, DATA)

	if not _check(started.ok, "the host boots on a fixture config", str(started.error)):
		return false

	# One frame, for the deferred wiring of the game's chat router.
	await get_tree().process_frame
	return true


func _teardown() -> void:
	if _host != null and is_instance_valid(_host):
		if _host.server != null and is_instance_valid(_host.server):
			_host.server.shutdown("test over")

		remove_child(_host)
		_host.free()


# --- Sections --------------------------------------------------------------

func _test_built() -> void:
	_section("what the host built")

	var p := _parties()

	_check(p != null and p.reservations != null, "a booking keeper, with no party.yml at all")
	_check(p.tracker == null, "and no tracker, because this fixture has no backbone")
	_check(
		DotRegistry.get_service(BAN_SOURCE) == p.reservations,
		"the booking is on the ban seam dot-server asks"
	)
	_check(
		p.reservations.previous_source != null
			and p.reservations.previous_source.has_method("check_admission"),
		"and chained to what the lobby's module put there, so its bans still hold"
	)

	var said := _say("party_status")
	_check(
		said.size() >= 3 and str(said[0]).begins_with("parties:"),
		"party_status answers (%s)" % " / ".join(PackedStringArray(said))
	)

	_done()


func _test_party_chat() -> void:
	_section("party chat in the game's own chat")

	var router := _chat_router()

	_check(router != null, "the lobby registered a chat router")
	_check(
		router != null and bool(router.call("has_channel", &"party"))
			and (router.call("channel", &"party") as DotChatChannel).grouped,
		"and it has a grouped party channel"
	)

	var group_fn: Variant = router.get("group_fn") if router != null else null
	_check(
		group_fn is Callable and (group_fn as Callable).is_valid(),
		"with the host's group rule on it"
	)
	_check(
		group_fn is Callable and String((group_fn as Callable).call(4242, &"party")) == "",
		"and a peer with no session is in nobody's party"
	)

	_done()


func _test_claim() -> void:
	_section("a player says which party they are in")

	var p := _parties()

	# The tracker a deployment with an integration token gets, over a stand-in site.
	var site := FakeBackbone.new()
	p.call("_build_tracker", site)

	var ada := _session(7, "backbone:7", "Ada")
	var said := _say("party_claim 123", ada)
	await _until(func() -> bool: return not said.is_empty())

	_check(
		p.tracker.party_of("backbone:7") == "123",
		"a member's claim is believed once the roster agrees (%s)" % " / ".join(PackedStringArray(said))
	)
	_check(p.party_id_of("backbone:8") == "123", "and the rest of the roster is known too")

	var stranger := _session(9, "backbone:9", "Cy")
	var refused := _say("party_claim 123", stranger)
	await _until(func() -> bool: return not refused.is_empty())

	_check(
		p.party_id_of("backbone:9") == "" and not refused.is_empty()
			and str(refused[0]).contains("not in that party"),
		"a stranger naming the party changes nothing (%s)" % " / ".join(PackedStringArray(refused))
	)

	var again := _say("party_claim 123", ada)
	_check(
		not again.is_empty() and str(again[0]).contains("wait"),
		"and one person cannot hammer the site with claims"
	)

	p.tracker.untrack("123")
	_done()


func _test_booking() -> void:
	_section("a booking kept")

	var p := _parties()
	var seam := DotRegistry.get_service(BAN_SOURCE)

	# First as a deployment with no backbone: there is no roster to read, so a console
	# booking's party is whoever is here and signed in -- nobody, here -- and a private
	# booking then admits only people allowed past it.
	var tracker := p.tracker
	p.tracker = null
	var said := _say("party_reserve 555 30 private")
	p.tracker = tracker

	_check(
		p.reservations.current != null and p.reservations.current.is_private,
		"party_reserve books the server privately (%s)" % " / ".join(PackedStringArray(said))
	)

	var refused: Variant = seam.call("check_admission", "backbone:1", "127.0.0.1")
	_check(
		refused is DotResult and not (refused as DotResult).ok,
		"a stranger is refused at the door dot-server asks"
	)
	_check(
		(seam.call("check_admission", "", "127.0.0.1") as DotResult).ok,
		"and the address-only pass is still admitted — a booking is about people"
	)

	_say("party_release")
	_check(p.reservations.current == null, "party_release lifts it")

	# Then with a site to read the roster from: the booking admits the party's members.
	var booked := _say("party_reserve 123 30 private")
	_check(
		p.reservations.current != null and p.reservations.current.party_id == "123",
		"with a backbone the booking is for the party the site knows (%s)" % " / ".join(PackedStringArray(booked))
	)
	_check(
		(seam.call("check_admission", "backbone:8", "127.0.0.1") as DotResult).ok,
		"a member of that party is admitted"
	)
	_check(
		not (seam.call("check_admission", "backbone:9", "127.0.0.1") as DotResult).ok,
		"and somebody else is not"
	)

	_say("party_release")
	p.tracker.untrack("123")

	_done()


func _test_survives_a_game_change() -> void:
	_section("a game change does not take the booking off the seam")

	var p := _parties()
	var before: Object = p.reservations.previous_source

	_server().console.execute("changelevel hungry_classic")

	var arrived := await _until(func() -> bool:
		var current := _server().games.current()
		return current != null and current.game_id == "hungry_classic" \
			and _server().games.phase == DotGameManager.Phase.IDLE \
			and _server().modules.has_module("hungry"), 20.0)

	_check(arrived, "the server changed to hungry")

	# The new module registered its own moderation on the seam; the host puts the booking
	# back on top of it, deferred.
	await get_tree().process_frame
	await get_tree().process_frame

	_check(
		DotRegistry.get_service(BAN_SOURCE) == p.reservations,
		"the booking is still what dot-server asks"
	)
	_check(
		p.reservations.previous_source != null and p.reservations.previous_source != before
			and is_instance_valid(p.reservations.previous_source),
		"chained to the NEW game's ban list, not the unloaded one's"
	)

	_done()
