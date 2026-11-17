extends Node

## The client shell: connect to a server, be sent a game, play it. It knows no particular game.
## A delivered pack brings no class list, so its scripts must reference each other by path (`preload("res://x.gd")`);
## addons are laid over `res://addons/` at boot instead, see [DotCloudAddonSet] and [method _on_server_info].

const CHANNEL := "tmc.shell"

var _menu_ui := TmcShellMenu.new(self)
var _solo_flow := TmcShellSolo.new(self)
var _solo_packs := TmcShellSoloPacks.new(self)

## Where the game scene is added. Named so the server's scene and this shell's own UI
## cannot collide.
const GAME_ROOT := &"Game"

## Where an operator puts the public key a delivered game's manifest is signed with.
## Shipped beside the shell and not settable from the page, see [method _ensure_cloud].
const CONTENT_CONFIG := "res://client/content.json"

## Where an operator names the backbone this build signs in against. See [method _sign_in].
const AUTH_CONFIG := "res://client/auth.json"

## The shell's own messages, in the website's locale layout: one directory per language,
## one JSON file per namespace. English ships; a language without a file falls back to it.
const LOCALE_DIR := "res://client/locales"

var link: DotClientLink = null

var _game_root: Node = null
var _auth: DotAuthClient = null

## The content client. Created on the first connection, and kept — a second one would
## displace the first in [DotRegistry] and the link would fetch through a client whose
## cache the mounted packs do not belong to.
var _cloud: DotCloudClient = null
var _menu: Control = null
var _status: Label = null
var _address: LineEdit = null
var _name: LineEdit = null
var _identity: Label = null
var _join: Button = null
var _progress: ProgressBar = null
var _detail: Label = null
## Latest overall snapshot of a many-pack download (DotCloudJobProgress); empty when none runs.
var _job: Dictionary = {}
var _clear: Button = null
var _clear_confirm: ConfirmationDialog = null
var _content_failed: PanelContainer = null
var _content_failed_text: Label = null
var _mouse_before_prompt: Input.MouseMode = Input.MOUSE_MODE_VISIBLE

## Solo play (see [TmcSolo]): the pack this shell was asked to run with no server, the
## version it resolved to, and the session object a game and its menu find in [DotRegistry].
var _solo_id: String = ""
var _solo_version: String = ""
## The map the solo game was asked to start on (`?map=`), "" for its own first map.
var _solo_map: String = ""
var _solo_button: Button = null

## The restart count Retry forgets ([method _attempt_key]), set when [method _solo_overlay] would not start a game without its addons; "" otherwise.
var _solo_retry: String = ""

## What [method _mount_in_place] did: the overlay runs; the engine refused it (restart onto it instead); or it is mounted but an
## addon still runs a compiled copy (blocked, as a failed boot is).
enum InPlace { RUNNING, REFUSED, STALE }
## Where dot-cloud's boot script records the overlay it mounted ([method DotCloudAddonSet.mounted_this_boot] reads it).
const OVERLAY_SETTING := "dot_cloud/addon_overlay"
## Whether to fetch this game's maps pack in solo; see [method TmcSolo.skip_maps].
var _solo_maps_check: CheckBox = null
## What the pack being fetched is, said in the status line over every cloud phase text.
var _solo_pack_label: String = ""
## True while a solo launch holds one outer job: the total line replaces every per-pack text and the bar never restarts.
var _launch_job := false
var _solo_key_cache: Dictionary = {}
## This launch's map packs ([method _solo_map_packs]), worked out once: null until then.
var _solo_map_packs_memo: Variant = null
var _deferred_workshop := false
var _late_sync := false
var _solo_session: TmcSoloSession = null

## The connect form's own pieces beyond [member _name], [member _address] and [member _join],
## kept so [method _show_connect_form] can take the whole form away for a solo launch.
var _blurb: Label = null

## The menu's glass card ([method _build_menu]).
var _menu_card: PanelContainer = null
## Powered by TMC, in the menu's bottom-right corner; null when the project turns it off.
var _powered_by: TmcPoweredBy = null
## The window's own aspect and scale, kept while [method _fit_menu] has them.
var _fit_saved: Dictionary = {}

## The menu card's width, in the project's 1280x720 canvas.
var menu_card_width := 420.0
## Scale the window up around the menu on a small screen (a phone). Off keeps the letterbox.
var menu_fit := true
## The space kept between the card and the window's edge while fitting, in canvas pixels.
var menu_fit_margin := 16.0
## How large the menu's text should look on a small screen, against the desktop's (1.0).
## Fitting never makes the card bigger than the window, whatever this asks for.
var menu_text_scale := 1.0
## A confirmation's width, in canvas pixels; narrower when the window is (see _popup_dialog).
var dialog_width := 420.0
var _name_caption: Label = null
var _address_caption: Label = null

## The Workshop's sync client (see [method _ensure_workshop]): the subscribed packs a solo
## start mounts. Never synced for an online join.
var _workshop: DotCloudWorkshop = null

## The site origin the Workshop talks to when it is not the one in `client/auth.json`. For a
## suite pointing it at a fake site; a player's page can never set it.
var workshop_backbone_url: String = ""

## Answers the download question without a dialog. For a suite.
var workshop_ask_override: Callable = Callable()

signal _download_answered(yes: bool)

## What restarting looks like, for a suite: called instead of reloading the page or
## re-executing the process. Unset in a real client.
var restart_fn: Callable = Callable()

## The player's party, when they are signed in. See [method _build_party].
var _party: DotPartyClient = null

## Which party this link has already told the server about, so a poll does not claim twice.
var _claimed_party: String = ""
var _party_line: Label = null

## The player's friends, when they are signed in. See [method _build_friends].
var _friends: TmcFriends = null
var _friends_box: VBoxContainer = null

## How many online friends the menu lists before it says "and N more". The panel is 392
## wide and the Connect button has to stay on screen in a short browser frame.
const FRIENDS_SHOWN := 4

## Every sentence this shell shows a player goes through here. See [method _build_locale].
var _locale: DotLocale = null

## What the server puts on the HUD over whatever game is showing: the game vote's
## countdown and its cues. See [TmcNoticeOverlay] for why the shell draws it.
var notices: TmcNoticeOverlay = null

## `/admin`, drawn. The server sends each page as a notice under its topic; see
## [TmcAdminMenuPanel] and `host/tmc_admin_menu.gd`.
var admin_menu: TmcAdminMenuPanel = null

## The server owner's screen over a game or map change. See [TmcLoadingScreen].
var loading: TmcLoadingScreen = null

## dot-radio's client, made when a server that runs a station says where it is. See [TmcRadioLink].
var radio_link: TmcRadioLink = null
## dot-trail's client and menu page. See [TmcTrailLink].
var trail_link: TmcTrailLink = null
var inventory_link: TmcInventoryLink = null

## Whether this connection has put a game on screen yet.
var _has_spawned := false

## Between pressing Connect and the first spawn; the loading screen covers it (a browser join blocks the page for half a minute).
## The other half of the screen's rule, with [member _has_spawned].
var _joining := false

## Time.get_ticks_usec() at each stage of the current join, by name, for [method _log_join].
## The stages are the ones the link reports; the blocking load inside `LOADING` is one
## number here because the link does it in one synchronous call.
var _join_marks: Dictionary = {}

## Whose packs may replace this build's addons is [TmcAddonNamespaces] (first-party defaults plus the operator's `cfg/addons/namespaces.txt`). See [DotCloudAddonSet].

## Set while newer addons are being fetched for the server just left.
var _addons_updating := false

## Servers whose addon update failed this session, so they are joined on this build's
## addons rather than left and re-joined for ever.
var _addons_skipped := {}


func _ready() -> void:
	# Scoped to this subtree: an RPC is addressed by node path relative to the MultiplayerAPI root, so with `/root`
	# both ends would have to agree on what each other's scene is called.
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), get_path()
	)

	# `?log=debug` on the page URL raises the level in a browser build, which has no command line.
	var verbose := "--verbose" in OS.get_cmdline_user_args() or DotWeb.query_param("log") == "debug"
	DotLog.set_level(DotLog.Level.DEBUG if verbose else DotLog.Level.INFO)
	DotLog.info(CHANNEL, TmcNativeStatus.line())

	TmcSiteDefault.apply(AUTH_CONFIG)

	_game_root = Node.new()
	_game_root.name = GAME_ROOT
	add_child(_game_root)

	# A solo game's own server process: no menu, no sign-in, nothing on screen.
	if TmcSolo.is_sim_child():
		await _solo_flow._start_sim_child()
		return

	_build_locale()
	_menu_ui._build_menu()

	# Before anything can be mounted: once a pack is mounted its files cannot be released
	# in this process, and on Windows cannot even be deleted. See [method request_clear].
	if FileAccess.file_exists(CLEAR_PENDING):
		await clear_pending()

	_build_notice_panels()

	loading = TmcLoadingScreen.new()
	loading.name = "Loading"
	loading.site_url = _workshop_site()
	loading.in_game_fn = func() -> bool:
		return _joining or (_has_spawned and _menu != null and not _menu.visible)
	add_child(loading)
	# A portrait phone sees the cover fitted, not letterboxed; it is handed back as the game takes over.
	loading.cover_changed.connect(func(_up: bool) -> void: _menu_ui._fit_menu())

	radio_link = TmcRadioLink.new()
	radio_link.name = "RadioLink"
	add_child(radio_link)
	trail_link = TmcTrailLink.new()
	trail_link.name = "TrailLink"
	trail_link.site_fn = _workshop_site
	trail_link.token_fn = _workshop_token
	trail_link.cloud_fn = func() -> Object:
		_ensure_cloud()
		return _cloud
	add_child(trail_link)
	inventory_link = TmcInventoryLink.new()
	inventory_link.name = "InventoryLink"
	inventory_link.origins = _configured_inventory_origins()
	inventory_link.cloud_fn = trail_link.cloud_fn
	inventory_link.clear_fn = request_clear
	add_child(inventory_link)
	inventory_link.start()

	# Claims the covering job for every DotLoadGate a game makes under the game root, so
	# only the loading screen shows, never the gate's own cover as well.
	_cover = TmcGameCover.new()
	_cover.name = "GameCover"
	_cover.loading = loading
	_cover.warm_wait_sec = WARM_WAIT_SEC
	_cover.claim(_game_root)
	add_child(_cover)

	# The shell is built, so a start on the addon overlay arrived. Until this line a broken
	# addon is still a start that died, and the boot script comes up without the overlay
	# next time. See [DotCloudAddonSet].
	DotCloudAddonSet.confirm_boot()

	# Awaited, because the answer changes the name the connection is opened with; one arriving after the join renames a "Guest 812" in front of everybody.
	# Read before signing in: a restart onto newer addons says who was signed in (see [method _sign_in]).
	var resumed := _take_resume()

	# Show where this start is going BEFORE the sign-in is awaited; it can take round trips and the box showed the localhost placeholder meanwhile.
	var going := _requested_server()
	if going == "":
		going = str(resumed.get("server", ""))
	if going != "":
		_address.text = going

	await _sign_in(resumed)

	# Solo: the page (the site's direct Play) or the command line named a game to run here,
	# with no server. See [TmcSolo]. Checked before the server, because `embed.html` sends
	# one or the other and a solo launch has no address to dial.
	var solo := TmcSolo.requested()

	# A restart that carries a join (see [method _restart_for_online]) goes to the server,
	# not back into the solo game the page's address still names.
	if str(resumed.get("server", "")) != "":
		solo = {"id": "", "version": "", "map": ""}
		_show_connect_form(true)

	# A restart into a solo game's addons (see [method _solo_overlay]) goes back into that game,
	# which a launch from the menu left in no address.
	if str(solo["id"]) == "" and str(resumed.get("solo", "")) != "":
		solo = {"id": str(resumed["solo"]), "version": str(resumed.get("solo_version", "")),
			"map": str(resumed.get("solo_map", ""))}

	if solo.has("refused"):
		_say("'%s' is not a game this client can start." % str(solo["refused"]))

	if str(solo["id"]) != "":
		_solo_flow._start_solo(str(solo["id"]), str(solo["version"]), str(solo.get("map", "")))
		return

	var wanted := _requested_server()

	# Restarted onto newer addons: back to the server that asked for them. A page whose
	# link names a server already goes there; one where the address was typed would
	# otherwise come back to an empty menu.
	if wanted == "":
		wanted = str(resumed.get("server", ""))

	if wanted != "":
		# The box shows what we ACTUALLY dialled: a hardcoded default made a failed auto-connect show an address that was not the one that failed.
		_address.text = wanted
		_connect_to(wanted)


## The notice overlay (ballots) and the admin menu, wired to send through `link`.
func _build_notice_panels() -> void:
	notices = TmcNoticeOverlay.new()
	notices.name = "Notices"
	# A drawn ballot's choice, sent as the command a player could type. Read through
	# `link` at the moment of the click, because the link is rebuilt on every connection.
	notices.vote_fn = func(line: String) -> void:
		if link != null:
			link.send_chat(line)
	add_child(notices)

	admin_menu = TmcAdminMenuPanel.new()
	admin_menu.name = "AdminMenu"
	# Read through `link` at the moment of the choice, as the ballot's is. The menu's own
	# kind first; the typed command for a server that does not know it, which costs a
	# chat line per choice against chat's flood limit -- see `host/tmc_admin_menu.gd`.
	admin_menu.send_fn = func(path: String) -> void:
		if link == null:
			return
		if not link.send_kind(TmcAdminMenuPanel.KIND, {"path": path}, DotEnvelope.Lane.EVENT):
			link.send_chat("/%s %s" % [TmcAdminMenuPanel.NAV_COMMAND, path])
	# An admin who opened a menu meant the number keys for it, not for a ballot.
	admin_menu.opened.connect(func() -> void:
		for panel in notices.ballots():
			panel.take_numbers = false
	)
	admin_menu.closed.connect(notices.restore_numbers)
	add_child(admin_menu)


## Where to connect: the command line, or the page's query string (a browser player followed a link that already named a server).
func _requested_server() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--connect")

	if index >= 0 and index + 1 < args.size():
		return args[index + 1]

	if DotPlatform.is_web():
		return DotWeb.query_param("server")

	return ""


## A user argument's value ([code]--name value[/code]), or "".
func _user_arg(name: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(name)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return ""


## The launcher's sign-in code from `--auth-code <code>`, or "". A well-formed `tmc_gh_` code only (closed character set), so a stray value never reaches the backbone.
func _launcher_auth_code() -> String:
	if DotPlatform.is_web():
		return ""

	var code := _user_arg("--auth-code").strip_edges()

	if not code.begins_with("tmc_gh_"):
		return ""

	for i in code.length():
		var c := code.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95
		if not ok:
			return ""

	return code


## Signs in against the backbone when the page offers a way: inside the TMC player the site hands over a single-use code ([DotAuthWebHandoff]);
## elsewhere `sign_in()` fails at once and the player stays a guest, because a device-code flow puts a code to read in front of someone who wanted Play.
## The name is a LABEL, not proof: a server that needs to know who somebody is verifies that itself.
func _sign_in(resumed: Dictionary = {}) -> void:
	# The desktop app's single-use code (`--auth-code`), minted by the site's /play/launch for a signed-in player. Native only: the page handoff is the web's.
	var launcher_code := _launcher_auth_code()

	if launcher_code == "" and not DotAuthWebHandoff.supported():
		return

	_auth = DotAuthClient.new()
	_auth.name = "Auth"
	# The shell drives sign-in itself, at the one moment it makes sense: nothing
	# here should start a login because a node entered the tree.
	_auth.auto_sign_in = false
	_auth.config = DotAuthConfig.new()
	_auth.config.client_name = "TMC Web Player"

	# The backbone comes from a file shipped in the build, like `client/content.json`: a browser has neither env nor argv, and a query-string URL
	# would decide where the single-use sign-in code is redeemed, a credential-forwarding link. (`config_file`'s default is an IndexedDB path no operator can fill.)
	_auth.config_file = AUTH_CONFIG if FileAccess.file_exists(AUTH_CONFIG) else ""

	if _auth.config_file == "":
		DotLog.info(
			CHANNEL,
			"no auth configuration; signing in against the default backbone",
			{"looked_for": AUTH_CONFIG, "backbone": _auth.config.backbone_url}
		)

	add_child(_auth)

	# `try_web_handoff`, not `sign_in`: `sign_in()` falls through to a device-code login, which cost every bare-link shell
	# two backbone requests per page load for a code nobody can read.
	var res: DotResult
	if launcher_code != "":
		# Redeemed at this client's own backbone (`--auth-backbone-url` / auth.json), never a URL argv names. Single-use, 60 s: a failure leaves a guest.
		res = await _auth.redeem_handoff(launcher_code)
	else:
		res = await _auth.try_web_handoff()

	# A restart onto newer addons must not sign a member out: the page's code is single-use and already spent, so the handoff fails here;
	# the stored credentials are used only for the member the update recorded (a guest stays a guest).
	if not res.ok and str(resumed.get("member", "")) != "":
		var restored: DotResult = await _auth.restore_session()

		if restored.ok and (restored.value as DotAuthIdentity).uid == str(resumed["member"]):
			res = restored
		elif restored.ok:
			_auth.sign_out(true)

	if not res.ok:
		DotLog.debug(
			"shell", "playing as a guest", {"why": res.code()}
		)
		return

	var identity := res.value as DotAuthIdentity

	# Said once per start with the member's uid, because "is this player still the same
	# member after the addon restart" is the question an operator asks and the one
	# tools/browser_update_check.mjs asserts on; the label is drawn, not logged.
	DotLog.info(CHANNEL, "signed in", {"member": identity.uid, "name": identity.display_name})

	_name.text = identity.display_name
	# Read-only rather than hidden: somebody signed in should be able to SEE who
	# the game thinks they are, and a field they can edit would let them type
	# somebody else's name over an identity we were just handed.
	_name.editable = false
	_identity.text = "• Signed in as %s" % identity.display_name
	_identity.visible = true

	_build_party(identity)
	_build_friends()
	_refresh_first_party()


## Asks the site which INTROSPECT servers this shell may hand a join token to. The site
## also enforces the list when minting, so a server it adds works without a new build;
## when it cannot answer, the list from `client/auth.json` (if any) stays.
func _refresh_first_party() -> void:
	var res: DotResult = await _auth.get_app("play/first-party")
	if res.ok:
		res = TmcSiteDefault.first_party_from(res.value)

	if not res.ok:
		DotLog.warn(CHANNEL, "the site's first-party servers are unavailable; keeping the shipped list", {
			"why": res.code(), "shipped": _auth.config.first_party_audiences,
		})
		return

	_auth.config.first_party_audiences = res.value
	DotLog.debug(CHANNEL, "first-party servers from the site", {"audiences": res.value})


## The shell's translator, from the shipped messages and the player's language (`--locale-language` on desktop, the page's in a browser).
## A refusal is a key; [method DotLocale.explain] renders it when the catalogue has it, else the error's own English message.
func _build_locale() -> void:
	var cfg := DotLocaleConfig.new()
	cfg.directory = LOCALE_DIR
	var layered := cfg.load_layered()

	if not layered.ok:
		DotLog.warn(CHANNEL, "the locale settings were not usable; using the defaults", {
			"why": str(layered.error),
		})
		cfg = DotLocaleConfig.new()
		cfg.directory = LOCALE_DIR

	var made := cfg.make()
	_locale = made.value as DotLocale if made.ok else DotLocale.new()


## A player's text for [param key], or [param fallback] when no language has the key.
## The key itself is DotLocale's last resort; a player on a stripped build should still read a sentence.
func _text(key: String, args: Dictionary, fallback: String) -> String:
	if _locale == null or not _locale.has(key):
		return fallback
	return _locale.t(key, args)


## A refusal in the player's language, or its own message.
func _explain(error: DotError) -> String:
	if error == null:
		return ""
	return _locale.explain(error) if _locale != null else error.message


## The player's party, followed wherever it goes. Only when signed in, because the site only knows signed-in players.
## The site does not serve party routes yet (dot-party's docs/backbone-contract.md), so the first 404 switches polling off for the session.
## [code]connect_fn[/code] is this shell's Connect path, so following the party is what the player would have done by hand.
func _build_party(identity: DotAuthIdentity) -> void:
	if _auth == null or identity == null:
		return

	var backend := DotPartyBackendApp.new()
	backend.client = _auth

	_party = DotPartyClient.new()
	_party.name = "Party"
	_party.backend = backend
	_party.user_id = identity.uid.trim_prefix("backbone:")
	_party.connect_fn = _follow_party
	add_child(_party)

	_party.party_changed.connect(_on_party_changed)
	_party.left_party.connect(_on_left_party)
	_party.request_failed.connect(_on_party_request_failed)
	_party.refresh()


## The player's friends list and presence, built with the party client over the same dot-auth client. See [TmcFriends].
## Quitting waits two seconds for "offline" (see [method _notification]): a presence lives two minutes and would show a closed game joinable; a closed tab never asks and expires.
func _build_friends() -> void:
	if _auth == null:
		return

	var backend := DotFriendsBackendApp.new()
	backend.client = _auth

	_friends = TmcFriends.build(backend)
	_friends.join_party_fn = func(party_id: String, _friend: DotFriend) -> DotResult:
		if _party == null:
			return DotResult.fail(DotError.CODE_UNSUPPORTED, "No party client.", "friends.join.deny.unsupported")
		return await _party.join(party_id)
	_friends.connect_address_fn = func(address: String) -> void:
		_address.text = address
		await _connect_to(address)
	add_child(_friends)

	_friends.list_changed.connect(_render_friends)
	_friends.switched_off.connect(func(_why: String) -> void: _render_friends([]))

	if _party != null and _party.party != null:
		_friends.on_party(_party.party.id)

	get_tree().auto_accept_quit = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and content_cache_off():
		# Best effort: a pack still mounted may hold its file open on some platforms,
		# which is why the next launch empties the folder first as well.
		DotPaths.remove_tree(SESSION_CACHE)

	if what == NOTIFICATION_WM_CLOSE_REQUEST and _friends != null:
		_quit_after_offline()


## Frames the last [method _slice_load] yielded across; the selftest reads it.
var slice_frames_yielded: int = 0

## The loader that warmed the running solo game's scripts; held so its cache stays warm.
var _warm_hold: Variant = null

const SESSION_CACHE := "user://dot_cloud_session"


## Whether `--content-cache off` (or `=off`, `0`, `false`, `no`) was passed after `--`.
static func content_cache_off() -> bool:
	var args := OS.get_cmdline_user_args()

	for i in args.size():
		var value := ""

		if args[i].begins_with("--content-cache="):
			value = args[i].substr("--content-cache=".length())
		elif args[i] == "--content-cache" and i + 1 < args.size():
			value = args[i + 1]
		else:
			continue

		return value.strip_edges().to_lower() in ["off", "0", "false", "no"]

	return false


## Posts "offline", waits at most two seconds for it, and quits either way: a site that is
## down must not be able to hold a player's window open.
func _quit_after_offline() -> void:
	var done: Array = []
	var post := func() -> void:
		await _friends.go_offline()
		done.append(true)
	post.call()

	var deadline := Time.get_ticks_msec() + 2000
	while done.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	get_tree().quit()


## The online half of the list, under the party line. Hidden until there is a list, and for
## good once friends have switched themselves off.
func _render_friends(list: Array) -> void:
	if _friends_box == null:
		return

	for child in _friends_box.get_children():
		_friends_box.remove_child(child)
		child.queue_free()

	var online: Array = []
	for f in list:
		if f is DotFriend and (f as DotFriend).is_online():
			online.append(f)

	_friends_box.visible = _friends != null and not _friends.off and not list.is_empty()

	if not _friends_box.visible:
		return

	var head := Label.new()
	head.text = _text("shell.friends.line", {"online": online.size(), "count": list.size()},
		"Friends: %d of %d online" % [online.size(), list.size()])
	head.theme_type_variation = &"DotDim"
	head.add_theme_font_size_override("font_size", 13)
	_friends_box.add_child(head)

	for i in range(mini(online.size(), FRIENDS_SHOWN)):
		_friends_box.add_child(_friend_row(online[i] as DotFriend))

	if online.size() > FRIENDS_SHOWN:
		var more := Label.new()
		more.text = _text("shell.friends.more", {"count": online.size() - FRIENDS_SHOWN},
			"and %d more" % (online.size() - FRIENDS_SHOWN))
		more.theme_type_variation = &"DotDim"
		more.add_theme_font_size_override("font_size", 12)
		_friends_box.add_child(more)


func _friend_row(f: DotFriend) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	# The height a Join button needs, on every row: rendered, rows with a button and rows
	# without alternated between two heights and the list read as ragged.
	row.custom_minimum_size = Vector2(0.0, 26.0)

	var who := Label.new()
	who.text = f.display_name
	who.add_theme_color_override("font_color", ACCENT)
	who.add_theme_font_size_override("font_size", 13)
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(who)

	# Elided rather than wrapped: a hostname is the operator's to choose and can be long,
	# and a row that wraps pushes Connect down in a frame the page sized.
	var where := Label.new()
	where.text = f.presence.detail if f.presence.detail != "" else DotPresence.status_name(f.presence.status)
	where.theme_type_variation = &"DotDim"
	where.add_theme_font_size_override("font_size", 12)
	where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	where.clip_text = true
	where.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	where.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(where)

	if f.presence.joinable and f.presence.has_destination():
		var join := Button.new()
		join.text = _text("shell.friends.join", {}, "Join")
		join.add_theme_font_size_override("font_size", 12)
		join.pressed.connect(_join_friend.bind(f.user_id, f.display_name))
		row.add_child(join)

	return row


func _join_friend(user_id: String, display_name: String) -> void:
	if _friends == null:
		return
	_say(_text("shell.friends.joining", {"name": display_name}, "Joining %s…" % display_name))
	var res: DotResult = await _friends.join(user_id)
	if not res.ok:
		_say(_locale.explain(res.error, {"name": display_name}) if _locale != null else res.error.message)


func _follow_party(url: String, info: Dictionary) -> DotResult:
	# Already there: a poll in the middle of a ready round must not reconnect a player who
	# is on the right server, which would drop them and put them back.
	if link != null and link.is_connected_to_server() and _address.text.strip_edges() == url:
		return DotResult.success(null)

	_say(_text("shell.party.following", {"server": str(info.get("serverName", url))},
		"Your party is playing on %s. Joining…" % str(info.get("serverName", url))))
	_address.text = url
	await _connect_to(url)

	if link == null:
		return DotResult.fail(DotError.CODE_NETWORK, "Could not follow the party.", url)

	return DotResult.success(null)


func _on_party_changed(p: DotParty) -> void:
	if _party_line == null:
		return

	_party_line.visible = p != null

	if _friends != null:
		_friends.on_party(p.id if p != null else "")

	if p != null:
		_party_line.text = _text("shell.party.line", {"name": p.name, "count": p.size()},
			"Party: %s (%d)" % [p.name, p.size()])

	_claim_party()


func _on_left_party(_party_id: String, reason: String) -> void:
	_claimed_party = ""
	if _friends != null:
		_friends.on_party("")
	_say(_text("shell.party.left.%s" % reason, {}, "You are no longer in your party."))


func _on_party_request_failed(what: String, error: DotError) -> void:
	if error != null and error.http_status == 404 and _party != null:
		DotLog.info(CHANNEL, "the site does not serve party routes yet; parties are off", {
			"what": what,
		})
		_party.queue_free()
		_party = null
		if _friends != null:
			_friends.on_party("")
		return

	DotLog.debug(CHANNEL, "a party request failed", {"what": what, "why": _explain(error)})


## Tells the server which party this player is in, once per party per connection, as a chat command (see `TmcParty` on the server).
## A slash command, which dot-server runs before any game's chat hook and never broadcasts; the server checks the roster before believing it.
func _claim_party() -> void:
	if _party == null or _party.party == null or link == null or not link.is_connected_to_server():
		return

	if link.phase != DotClientLink.Phase.PLAYING or _claimed_party == _party.party.id:
		return

	_claimed_party = _party.party.id
	link.send_chat("/party_claim %s" % _party.party.id)


## The menu's accent as text (friend names, the signed-in line): GameSpice's, from
## [TmcShellStyle], so the menu and the site around it read as one product.
const ACCENT := TmcShellStyle.ACCENT_TEXT


## The connect form (name, server, Connect) or, for a shell opened to play one game with no
## server, only that game. Not given back after a solo game's Leave: Play solo is the way on,
## and a server the player follows from there (a friend's Join) fills the address itself.
func _show_connect_form(shown: bool) -> void:
	for control: Control in [_name_caption, _name, _address_caption, _address, _join]:
		if control != null:
			control.visible = shown
	if _blurb != null:
		_blurb.text = "Connect to a server. It decides what you play." if shown else "Playing solo, with no server."
	if not shown and _solo_button != null:
		_solo_button.visible = true
		_primary(_solo_button)
		_refresh_solo_maps_check()


## Shows the maps choice for the solo game this shell was opened for, as last kept.
func _refresh_solo_maps_check() -> void:
	if _solo_maps_check == null:
		return
	var has_maps := _solo_id != "" and not TmcSolo.map_packs(_solo_id).is_empty()
	_solo_maps_check.visible = has_maps
	_solo_maps_check.set_pressed_no_signal(not TmcSolo.skip_maps(_solo_id))


## Deferred grab_focus that re-checks at call time: by then the control may be freed or out
## of the tree (a shell told to join at once), and grab_focus out of the tree is an engine error.
func _focus_when_shown(control: Control) -> void:
	(func() -> void:
		if is_instance_valid(control) and control.is_visible_in_tree():
			control.grab_focus()
	).call_deferred()


## Makes a button read as the one thing on screen to press: the site's accent button
## ([method TmcShellStyle.primary]). On the instance, so every other button stays quiet.
func _primary(button: Button) -> void:
	TmcShellStyle.primary(button)


## Puts the menu into or out of "something is happening" state. One place, because every way a connection ends must undo the same two things, and a Connect button left disabled is a dead end.
func _set_busy(busy: bool) -> void:
	if _join != null:
		_join.disabled = busy
		_join.text = "Connecting…" if busy else "Connect"

	if _progress == null:
		return

	_progress.visible = busy

	if busy:
		_progress.value = 0.0
		# Signon has phases with no fraction to report — a handshake is not 40% done — so
		# the bar sweeps until there is a real number to show, and switches to it the
		# moment a download starts.
		_indeterminate(true)


func _indeterminate(on: bool) -> void:
	# Guarded rather than assumed: `indeterminate` arrived in 4.3, and a shell that only
	# builds on the newest engine is a shell an operator cannot build.
	if _progress != null and "indeterminate" in _progress:
		_progress.indeterminate = on


## Creates the content client, once, before the first connection.
## The trusted key comes from a file and is the whole of the security here: a mounted pack can contain scripts. `trusted_keys` is in `sensitive_keys`, so no query string can make itself a publisher;
## with no `res://client/content.json` the build plays only the games it already has.
func _ensure_cloud() -> void:
	if _cloud != null and is_instance_valid(_cloud):
		return

	_cloud = _new_cloud()

	# Straight off the content client, not the link: the link forwards a fraction and a sentence, but dot-cloud's payload carries file, rate and estimate.
	_cloud.phase_changed.connect(_on_cloud_phase)
	_cloud.failed.connect(_on_cloud_failed)
	_cloud.progress_changed.connect(_on_cloud_progress_detail)
	_cloud.job_progress_changed.connect(_on_cloud_job)

	add_child(_cloud)


## A content client configured as this shell's, not yet in the tree and with nothing listening: a solo game's server process ([method _start_sim_child]) has no screen to report to.
func _new_cloud() -> DotCloudClient:
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	# Who a pack's requires.json refusal names: "...; this CLIENT has level 2" -- the
	# player's cue that this shell, not the server, is the one to update.
	cloud.host_role = "client"
	cloud.config = DotCloudConfig.new()
	# The shell is a player's client even headless, where dot-cloud's `auto` would read "server" and leave client-only files (API 8) behind.
	# A solo game runs its server here too, so [method _start_solo] widens this to both.
	cloud.config.side = "client"
	cloud.add_child(_new_cloud_scheduler())

	# A player may keep nothing: `--content-cache off` points the store at a session folder emptied now and on quit.
	# An explicit `--cloud-cache-dir` wins; DotCloudConfig already reads the cache dir and size off the command line.
	if content_cache_off():
		cloud.config.cache_dir = SESSION_CACHE
		DotPaths.remove_tree(SESSION_CACHE)
		DotLog.info(CHANNEL, "downloads are kept for this session only", {"dir": SESSION_CACHE})

	if ResourceLoader.exists(CONTENT_CONFIG) or FileAccess.file_exists(CONTENT_CONFIG):
		cloud.config_file = CONTENT_CONFIG
	else:
		DotLog.info(
			CHANNEL,
			"no content configuration; this build can only play games it already has",
			{"looked_for": CONTENT_CONFIG}
		)
		cloud.config_file = ""

	# Maps download from `/content` by default: the page's own origin, with no CORS headers to get right. `DotCloudClient` prepends the origin
	# because [HTTPRequest] parses the URL in C++ and a root-relative string is not a URL.
	# Content elsewhere is set in `content.json` (`"content_urls": [...]`) and then needs `Access-Control-Allow-Origin`.
	var configured := _configured_content_urls()
	# Natively there is no page origin to resolve `/content` against: HTTPRequest rejects it ("Error parsing URL"), so a desktop shell
	# has no default and takes its address from `content.json` or `--content-url`.
	var default_bases := PackedStringArray(["/content"]) if DotPlatform.is_web() else PackedStringArray()
	cloud.http_base_urls = configured if not configured.is_empty() else default_bases

	# No version segment, because the published layout has none: the version is INSIDE the manifest and the mount namespaces by it; the default template 404ed on a CDN serving the map fine.
	# This is the path EVERYTHING takes (games resolve through it as maps do).
	# Versioned first, flat as fallback, the same pair the SERVER uses, so both ends resolve the same shape.
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])
	return cloud


## The hashing scheduler [DotCloudClient] finds as its `CloudScheduler` child, made here so the web never hashes on worker threads.
## On the threaded web engine a worker's `user://` reads are proxied to the browser's main thread one call a frame, so each mount-time
## [DotHashJob] took ~0.7 s and FC's ~700 objects sat at "Unpacking 0 of 1" for minutes (web-mt-shell-unpack-hang-1).
## On the main thread the same jobs share the frame budget, as they always have on the single-threaded engine.
static func _new_cloud_scheduler() -> DotScheduler:
	var scheduler := DotScheduler.new()
	scheduler.name = "CloudScheduler"
	scheduler.use_threads = not DotPlatform.is_web()
	return scheduler


## A pack this client is too old to run (CODE_VERSION), told plainly and passed to the page.
## Branches on the code, never the sentence; before dot-cloud API 3 the refusal came after the download, and either way the fix is a newer client.
func _on_cloud_failed(error: DotError) -> void:
	if error == null or error.code != DotError.CODE_VERSION:
		return
	_report_client_behind(error.message)


func _report_client_behind(sentence: String) -> void:
	var early := DotAddonApi.build_level("dot_cloud") >= 3

	DotLog.warn(CHANNEL, "this client is older than the game it was asked to run", {
		"why": sentence, "early": early,
	})

	_say(sentence)
	if _menu != null and not _menu.visible:
		show_content_failed(sentence)

	if not DotPlatform.is_web():
		return

	var payload := {
		"type": "tmc.build.mismatch",
		"reason": "client_behind",
		"message": sentence,
		"early": early,
	}
	DotWeb.post_to_parent(payload)


func _on_cloud_phase(phase: int, text: String) -> void:
	if _launch_job and phase != DotCloudClient.Phase.FAILED:
		# One job owns the bar, the loading cover and the text; a pack finishing is not the end of anything.
		if loading != null:
			loading.begin(TmcLoadingScreen.REASON_CONTENT)
		return
	if _status != null and text != "":
		_status.text = _solo_pack_label if _solo_pack_label != "" else text

	# In a game a failed download or mount has nowhere to be said (the menu is hidden), leaving a player on the old map with no way out; clearing downloads fixes exactly those.
	if phase == DotCloudClient.Phase.FAILED and _menu != null and not _menu.visible:
		show_content_failed(text)

	# A fetch while a game is on screen is a map (or the next game's pack, which the game
	# reason is already covering). The screen waits a moment before it shows, so a map
	# already on the disk does not flash one.
	if loading != null:
		match phase:
			DotCloudClient.Phase.IDLE, DotCloudClient.Phase.READY, DotCloudClient.Phase.FAILED:
				loading.end(TmcLoadingScreen.REASON_CONTENT)
			_:
				# A solo game, or the suggested packs fetched after the scene is up, never
				# walls the live game off: the game covers its own map change with its gate.
				if _cover_may_block():
					loading.begin(TmcLoadingScreen.REASON_CONTENT)
					loading.set_progress(-1.0, text)
				else:
					DotLog.info(CHANNEL, "[TMC] cover skipped: content fetch during live play", {"phase": phase, "text": text})

	if phase == DotCloudClient.Phase.IDLE or phase == DotCloudClient.Phase.READY or phase == DotCloudClient.Phase.FAILED:
		_job = {}

	# The detail line belongs to the download. Anything else and it is stale.
	if _detail != null and phase != DotCloudClient.Phase.DOWNLOADING:
		_detail.visible = false

	if _progress == null:
		return

	match phase:
		DotCloudClient.Phase.IDLE, DotCloudClient.Phase.READY, DotCloudClient.Phase.FAILED:
			_progress.visible = false
		DotCloudClient.Phase.DOWNLOADING:
			_progress.visible = true
			_indeterminate(false)
		_:
			# Fetching a manifest, verifying a signature, planning, verifying files,
			# mounting: real work with no fraction to report, which is what an
			# indeterminate bar is for.
			_progress.visible = true
			_indeterminate(true)


## One bar for the whole job: a snapshot with a single pack is the per-pack bar again, so it is ignored.
func _on_cloud_job(snap: Dictionary) -> void:
	if _launch_job:
		_on_launch_job(snap)
		return
	_job = snap if int(snap.get("total_packs", 0)) > 1 and int(snap.get("done_packs", 0)) < int(snap.get("total_packs", 0)) else {}
	if _job.is_empty():
		return
	var frac := float(_job.get("fraction", 0.0))
	if loading != null and loading.is_showing():
		loading.set_progress(frac, "", _job_line())
	if _progress != null:
		_indeterminate(false)
		_progress.visible = true
		_progress.value = clampf(frac, 0.0, 1.0) * 100.0
	if _detail != null:
		_detail.text = _job_line()
		_detail.visible = true


## The launch's one bar: bytes while downloading, an indeterminate "Unpacking n of N" afterwards.
func _on_launch_job(snap: Dictionary) -> void:
	_job = snap
	var unpacking := str(snap.get("phase", "download")) == "unpack"
	var frac := float(snap.get("fraction", 0.0))
	var line := ""
	if unpacking:
		line = _text("shell.job.unpacking", {"done": int(snap.get("unpack_done", 0)), "total": int(snap.get("unpack_total", 0))},
			"%d of %d" % [int(snap.get("unpack_done", 0)), int(snap.get("unpack_total", 0))])
	elif int(snap.get("total_bytes", 0)) > 0:
		line = _job_line()
	var title := _text("shell.job.unpacking_title", {}, "Unpacking…") if unpacking else _text("shell.job.downloading_title", {}, "Downloading…")
	if loading != null:
		loading.begin(TmcLoadingScreen.REASON_CONTENT)
		loading.set_progress(-1.0 if unpacking else frac, title, line)
	if _status != null:
		_status.text = title
	if _progress != null:
		_progress.visible = true
		_indeterminate(unpacking)
		if not unpacking:
			_progress.value = clampf(frac, 0.0, 1.0) * 100.0
	if _detail != null:
		_detail.text = line
		_detail.visible = line != ""


## "63 / 400 MiB · 3 of 40 packs" then "rate · ETA", the answer to "how much of everything".
func _job_line() -> String:
	var total_packs := int(_job.get("total_packs", 0))
	var line := _text("shell.job.line", {
		"bytes": _bytes_pair(int(_job.get("done_bytes", 0)), int(_job.get("total_bytes", 0))),
		"done": int(_job.get("done_packs", 0)), "total": total_packs,
	}, "%s · %d of %d packs" % [_bytes_pair(int(_job.get("done_bytes", 0)), int(_job.get("total_bytes", 0))), int(_job.get("done_packs", 0)), total_packs])
	var rate := float(_job.get("bytes_per_sec", 0.0))
	var eta := float(_job.get("eta_sec", -1.0))
	var tail := PackedStringArray()
	if rate > 1.0:
		tail.append(_rate_text(rate))
	if eta > 0.0 and rate > 1.0 and float(_job.get("fraction", 0.0)) > 0.02:
		tail.append(_eta_text(eta))
	return line if tail.is_empty() else line + "\n" + " · ".join(tail)


## The second line: which file, how fast, how much longer.
func _on_cloud_progress_detail(p: Dictionary) -> void:
	# A many-pack job owns the bar and the detail; per-file numbers would jump back to zero with every pack.
	if not _job.is_empty():
		return
	if loading != null and loading.is_showing():
		var total := int(p.get("total_bytes", 0))
		loading.set_progress(float(p.get("fraction", 0.0)), "",
			_bytes_pair(int(p.get("done_bytes", 0)), total) if total > 0 else "")

	if _progress != null:
		_indeterminate(false)
		_progress.visible = true
		_progress.value = clampf(float(p.get("fraction", 0.0)), 0.0, 1.0) * 100.0

	if _detail == null:
		return

	# Two lines, "how much longer" then "of what": one joined string wrapped three times in a 275 px panel, which no assertion catches but a rendered frame shows.
	var numbers := PackedStringArray()

	var total := int(p.get("total_bytes", 0))
	if total > 0:
		numbers.append(_bytes_pair(int(p.get("done_bytes", 0)), total))

	var rate := float(p.get("bytes_per_sec", 0.0))
	if rate > 1.0:
		numbers.append(_rate_text(rate))

	# [b]Only once it means something.[/b] An estimate computed from the first two
	# hundred milliseconds of a transfer says four hours, and a player reads that
	# before it settles and closes the tab.
	var eta := float(p.get("eta_sec", 0.0))
	if eta > 0.0 and rate > 1.0 and float(p.get("fraction", 0.0)) > 0.02:
		numbers.append(_eta_text(eta))

	var what := PackedStringArray()

	var file := str(p.get("current_file", ""))
	if file != "":
		what.append(_elide(file, 30))

	var files_total := int(p.get("total_files", 0))
	if files_total > 1:
		var n := mini(int(p.get("done_files", 0)) + 1, files_total)
		what.append(_text("shell.progress.file_of", {"n": n, "total": files_total}, "%d of %d" % [n, files_total]))

	var lines := PackedStringArray()
	if not numbers.is_empty():
		lines.append(" · ".join(numbers))
	if not what.is_empty():
		lines.append(" · ".join(what))

	_detail.text = "\n".join(lines)
	_detail.visible = _detail.text != ""


## `23.5 / 63.0 MiB` rather than `23.5 MiB / 63.0 MiB`: the panel is 215 px wide and the repeated unit wrapped.
## Dropped only when both sides land in the same unit.
func _bytes_pair(done: int, total: int) -> String:
	var a := _size_text(done)
	var b := _size_text(total)
	var unit := b.get_slice(" ", b.count(" ")) if b.contains(" ") else ""

	if unit != "" and a.ends_with(" " + unit):
		return "%s / %s" % [a.trim_suffix(" " + unit), b]

	return "%s / %s" % [a, b]


## A byte count with the locale's decimal separator; the unit symbols (KiB, MiB) are the same in every language.
func _size_text(n: int) -> String:
	if n < 0:
		return "?"
	var units := ["B", "KiB", "MiB", "GiB", "TiB"]
	var v := float(n)
	var i := 0
	while v >= 1024.0 and i < units.size() - 1:
		v /= 1024.0
		i += 1
	var shown := snappedf(v, 0.1) if i > 0 else v
	return _text("shell.size", {"value": shown, "unit": units[i]}, DotPaths.format_bytes(n))


func _rate_text(rate: float) -> String:
	var size := _size_text(int(rate))
	return _text("shell.rate", {"size": size}, "%s/s" % size)


## A middle-elided name, because the end of a filename identifies it: `surf_mesa_geometry_lod0.bin` cut from the right is every file in that map.
static func _elide(text: String, limit: int) -> String:
	if text.length() <= limit:
		return text
	var keep := (limit - 1) / 2
	return text.substr(0, keep) + "…" + text.substr(text.length() - keep)


## An estimate in the units a person would use for it. Short, because it shares a line with the bytes and the rate.
func _eta_text(seconds: float) -> String:
	if seconds < 10.0:
		return _text("shell.eta.few", {}, "a few seconds")
	if seconds < 90.0:
		var s := int(round(seconds / 5.0) * 5)
		return _text("shell.eta.seconds", {"n": s}, "%ds left" % s)
	var minutes := int(round(seconds / 60.0))
	return _text("shell.eta.minutes", {"n": minutes}, "%d min left" % minutes)


## Origins allowed to use the inventory bridge; empty (the default) leaves it off.
func _configured_inventory_origins() -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(CONTENT_CONFIG):
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONTENT_CONFIG))
	if not (parsed is Dictionary):
		return out
	var list: Variant = (parsed as Dictionary).get("inventory_origins", null)
	if list is Array:
		for o in (list as Array):
			var one := str(o).strip_edges()
			if one != "" and one != "*" and one != "null":
				out.append(one)
	return out


## `content_urls` out of `client/content.json`, or empty. Read here because DotCloudConfig has no field for it and this file is all an operator can edit in an export;
## parsed defensively, since a malformed file must not stop a build that can play the games it already has.
func _configured_content_urls() -> PackedStringArray:
	var out := PackedStringArray()

	if not FileAccess.file_exists(CONTENT_CONFIG):
		return out

	var text := FileAccess.get_file_as_string(CONTENT_CONFIG)
	if text == "":
		return out

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return out

	var urls: Variant = (parsed as Dictionary).get("content_urls", null)
	if not (urls is Array):
		return out

	for u in (urls as Array):
		var one := str(u).strip_edges()
		if one != "":
			out.append(one)

	if not out.is_empty():
		DotLog.info(
			CHANNEL,
			"content will be fetched from the URLs in content.json",
			{"urls": ", ".join(out)}
		)

	return out


func _connect_to(address: String) -> void:
	var target := address.strip_edges()

	if target == "":
		_status.text = "Type an address first."
		return

	# Online never sees a subscription: the index's session filters every catalogue and the cloud client's tag stamps a mount, so both go to `online` before anything is fetched.
	# A pack that runs code stays resident after its game is freed, so a process that mounted one restarts first.
	# So does one whose overlay holds a subscribed addon: the restart drops that overlay.
	if (_workshop != null and _workshop.requires_restart_before_online()) or TmcShellSolo.plan_holds_subscription(DotCloudAddonSet.read_plan()):
		_restart_for_online(target)
		return

	_enter_online_session()

	_status.text = "Connecting to %s…" % target
	_set_busy(true)
	_joining = true
	_join_marks = {"start": Time.get_ticks_usec()}
	loading.reset()
	loading.set_server(target)
	loading.begin(TmcLoadingScreen.REASON_GAME)
	loading.set_progress(-1.0, _text("shell.loading.connecting", {"server": target}, "Connecting to %s…" % target))

	# Avatar files and the trail pack come down before the socket opens; bounded, never fatal.
	var prejoin := DotGamePrejoin.new()
	prejoin.site_url = _workshop_site()
	prejoin.progress_fn = func(fraction: float, text: String) -> void:
		loading.set_progress(fraction, text)
	trail_link.before_join(prejoin)
	await prejoin.prepare(self, target)
	if not _joining:
		return

	# Off a solo game first: a server's game goes under the same root, and a solo session
	# left registered would hand the server's game the solo maps and the menu's Leave.
	if _solo_session != null:
		_end_solo_session()
		_clear_game()

	# Before a new one is built, never after ([method _drop_link]). Belt and braces, except for a signon that failed after the socket came up ([method _fail]), where the menu returns with the link still connected.
	_drop_link()

	# Without this a browser client cannot download anything: `DotClientLink._begin_content_sync` resolves `dot_cloud_client` from [DotRegistry] and fails the join when it is null.
	_ensure_cloud()
	_enter_online_session()

	link = DotClientLink.new()
	# "Server", because Godot routes an RPC by the receiver's node path and dot-server's node is called that; a wrong name fails every RPC, handshake included, with only a timeout to show.
	link.name = "Server"
	link.player_name = _name.text.strip_edges()
	# `--udp host:port` joins over ENet (the launcher passes enet_port); `--transport auto|udp|ws` overrides. See DotClientLink.
	link.udp_address = _user_arg("--udp")
	var preference := _user_arg("--transport")
	if preference in ["auto", "udp", "ws"]:
		link.transport_preference = preference
	# Declared before the connect so the credentials advertise them. See TmcAdminMenuPanel.KIND.
	link.envelope.register(TmcAdminMenuPanel.KIND)
	trail_link.attach(link)
	# Where the server's game scene is put. The shell never names a scene itself.
	link.game_root_ref = DotNodeRef.of_path(_game_root.get_path())
	add_child(link)

	link.phase_changed.connect(func(phase: int, text: String) -> void:
		_status.text = text
		_mark_join(phase)
		# A first join and a game change under a player who is already in: the link goes
		# through connecting, downloading and loading, and the loading screen covers all.
		if (_has_spawned or _joining) and phase in [
				DotClientLink.Phase.CONNECTING, DotClientLink.Phase.AUTHENTICATING,
				DotClientLink.Phase.DOWNLOADING, DotClientLink.Phase.LOADING]:
			loading.begin(TmcLoadingScreen.REASON_GAME)
			loading.set_progress(-1.0, text)
	)
	link.download_progress.connect(func(fraction: float, text: String) -> void:
		if _joining:
			# First and last progress report: the gap after the last is verifying and
			# mounting, which the link awaits inside DOWNLOADING.
			if not _join_marks.has("dl_first"):
				_join_marks["dl_first"] = Time.get_ticks_usec()
			_join_marks["dl_last"] = Time.get_ticks_usec()
		_indeterminate(false)
		_progress.value = clampf(fraction, 0.0, 1.0) * 100.0
		_status.text = "%s  %d%%" % [text, int(fraction * 100.0)]
		loading.set_progress(fraction, text)
	)
	link.game_changed.connect(_on_game_changed)
	link.spawned.connect(_on_spawned)
	link.disconnected.connect(_on_disconnected)
	# The first thing a server says, and it says which addon versions it runs.
	link.server_info.connect(_on_server_info.bind(target))
	# The server's HUD lines. Connected per link rather than once, because the link is
	# rebuilt on every connection -- see [method _drop_link].
	link.notice_received.connect(_on_notice)

	var connecting: DotResult = await link.connect_to_server(target)

	if not connecting.ok:
		_joining = false
		loading.end(TmcLoadingScreen.REASON_GAME)
		_status.text = _text("shell.connect.failed", {"reason": _explain(connecting.error)},
			"Could not connect: %s" % _explain(connecting.error))
		_set_busy(false)
		_drop_link()


## The server's challenge: if it runs newer addons than this build, leave, fetch them, and restart into them.
## Before the join, because after it the old addons have run and a newer one fetched later cannot replace the compiled copy (see [DotCloudAddonSet]).
## Never twice for one set: after a failed start or update the join proceeds on this build's addons, because a loop is worse.
func _on_server_info(_challenge: Dictionary, target: String) -> void:
	if link == null or _addons_updating or _addons_skipped.has(target):
		return

	var addons := DotCloudAddonSet.new(_cloud)
	addons.namespaces = TmcAddonNamespaces.load_shell()
	var decided := addons.plan_for(link.server_addons)
	var refused: Dictionary = decided["refused"]

	if not refused.is_empty():
		DotLog.debug(CHANNEL, "addons this server runs that are not taken", {"refused": refused})

	var wanted: Dictionary = decided["wanted"]
	var plan := DotCloudAddonSet.read_plan()
	var running: Dictionary = plan if DotCloudAddonSet.mounted_this_boot(plan) else {}
	# A dot-cloud before download groups (0.1.47) has no `groups` and takes every group.
	var grouped := "groups" in addons

	if wanted.is_empty() and grouped:
		wanted = _groups_top_up(running, target)

	if wanted.is_empty():
		_clear_update_attempts(target)
		return

	if _overlay_failed_here(wanted):
		DotLog.warn(CHANNEL, "the server's addons failed to start here before; joining on this build's", {
			"server": target,
		})
		return

	var attempt := _attempt_key(target, wanted)

	if _update_attempts(attempt) >= MAX_UPDATE_RESTARTS:
		DotLog.warn(CHANNEL, "restarting for this server's addons did not take; joining on this build's", {
			"server": target, "restarts": _update_attempts(attempt),
		})
		return

	if grouped:
		addons.set("groups", TmcAddonGroups.wanted_groups(link.server_addons, wanted, running))

	DotLog.info(CHANNEL, "this server runs newer addons; updating before joining", {
		"server": target, "addons": wanted.keys(), "groups": addons.get("groups") if grouped else "*",
	})

	_addons_updating = true
	# Deferred: this runs inside the link's challenge handler, which goes on to send
	# credentials on the socket after it returns.
	_update_addons.call_deferred(addons, wanted, target, attempt)


## The running overlay's addons again when this server's game needs download groups that overlay was built without, else nothing.
## A deferred group cannot be fetched into a mounted overlay, so the overlay is rebuilt at the same versions with the union (a restart, bounded like an update's).
func _groups_top_up(running: Dictionary, target: String) -> Dictionary:
	var held: Dictionary = running.get("addons", {})
	# Only what this server runs: an addon the overlay raised that the server does not mention needs nothing from it.
	var listed := {}

	for raw: Variant in link.server_addons:
		if raw is Dictionary and held.has(str((raw as Dictionary).get("dir", ""))):
			listed[str((raw as Dictionary)["dir"])] = true

	if listed.is_empty():
		return {}

	var needed := TmcAddonGroups.needed_groups(link.server_addons, listed)
	var have := TmcAddonGroups.plan_groups(running)

	if TmcAddonGroups.covers(have, needed):
		return {}

	DotLog.info(CHANNEL, "this server's game needs download groups the overlay lacks; rebuilding it", {
		"server": target, "have": have, "needed": needed,
	})
	return held.duplicate(true)


func _update_addons(addons: DotCloudAddonSet, wanted: Dictionary, target: String, attempt: String) -> void:
	# Quietly: `_drop_link` closes without a reason, so no "Disconnected" is said about a server we rejoin at once.
	# A release build logs one harmless engine line here (`Attempt to disconnect a nonexistent connection from 'Server'`), the same with the drop deferred.
	_drop_link()
	_set_busy(true)
	_indeterminate(true)
	_say(_text("shell.addons.updating", {}, "Updating the game for this server…"))
	loading.set_progress(-1.0, _text("shell.addons.updating", {}, "Updating the game for this server…"))

	# Where to come back to, and who was signed in -- the page's sign-in code will
	# already have been spent by the time the restart asks for it.
	var resume := {"server": target}
	if _auth != null and _auth.is_signed_in() and _auth.identity() != null:
		resume["member"] = _auth.identity().uid

	var built: DotResult = await addons.build(wanted, resume)

	if not built.ok:
		DotLog.error(CHANNEL, "could not update the addons; joining on this build's", {
			"server": target, "why": str(built.error),
		})
		_addons_updating = false
		_addons_skipped[target] = true
		_connect_to(target)
		return

	_stamp_plan()

	if _join_in_place(built.value, target):
		_addons_updating = false
		_connect_to(target)
		return

	_say(_text("shell.addons.restarting", {}, "Restarting to finish the update…"))
	_note_update_attempt(attempt)

	# What the next start reads: the plan (where to come back to, who was signed in), the
	# overlay's files it mounts, and the stored session that keeps the player signed in.
	var keep := DotCloudAddonSet.plan_files(built.value)
	if resume.has("member"):
		var tokens := _auth.config.token_store_path
		for path in [tokens, tokens + ".salt"]:
			if FileAccess.file_exists(path):
				keep.append(path)

	if not await _restart(keep):
		# A platform that cannot restart itself: the overlay applies on the next launch,
		# and this one plays on what it has.
		_addons_updating = false
		_addons_skipped[target] = true
		_say(_text("shell.addons.next_start", {},
			"The update finishes the next time the game starts."))
		_connect_to(target)


## Whether a server's overlay just built ([param plan]) was taken without a restart, so the join goes on now: mounted in this
## process ([method _clear_update_attempts]), or mounted but stale (the join goes on the build's own addons, as after a failed
## restart). A first visit, or the first join on a new shell build, has none of these addons in this process; mounting them here
## skips the IndexedDB wait, the page reload, the second fetch of the shell and the second engine boot (about 20 s of a Fast 4G
## join measured on 2026-11-17). False leaves the restart: an overlay that would replace a mounted addon (a compiled script is
## never read again), a workshop subscription (only a restart unmounts it), or a pack the engine refused, as on the solo path.
func _join_in_place(plan: Dictionary, target: String) -> bool:
	if not _overlay_additive(plan) or TmcShellSolo.plan_holds_subscription(plan):
		return false

	match _mount_in_place():
		InPlace.RUNNING:
			_clear_update_attempts(target)
			return true
		InPlace.STALE:
			_addons_skipped[target] = true
			return true

	return false


## Restarts for one server's addons before giving up on them for the session.
const MAX_UPDATE_RESTARTS := 2

## How long a browser restart waits for IndexedDB to hold the files the next start reads.
## A sync walks the whole of `user://`, so a player with a large cache waits longer; past
## this the update is left for the next start rather than reloading into nothing.
const PERSIST_TIMEOUT_SEC := 60.0

## Bytes a second IndexedDB is counted on to take on top of [constant PERSIST_TIMEOUT_SEC]:
## a solo game's weapon overlay is over 200 MB, which no browser stores within a minute.
const PERSIST_BYTES_PER_SEC := 2 * 1024 * 1024

## Seconds a game that declared `ready_to_show` has, after it is on screen, to say so before
## the loading screen lifts anyway. See [method _watch_game_ready].
const WARM_WAIT_SEC := 20.0

## Covers a game until it is ready to be seen. See [method _watch_game_ready].
var _cover: TmcGameCover = null

## The `sessionStorage` key restarts are counted under.
const UPDATE_ATTEMPTS_KEY := "tmc.addon_updates"


func _attempt_key(target: String, wanted: Dictionary) -> String:
	var parts := PackedStringArray()
	for dir: String in wanted:
		parts.append("%s@%s" % [dir, str((wanted[dir] as Dictionary).get("version", ""))])
	parts.sort()
	return "%s|%s" % [target, ",".join(parts)]


## Where restarts are counted, for a suite: an object with `getItem` and `setItem`, as `sessionStorage` has. Unset in a real client.
var attempt_storage: Object = null

## This shell's build id (`YYYYMMDD-HHMM`, "" off the web). A suite sets it to stand in for a redeploy.
var shell_build: String = TmcShellVersion.build_id()


## How many times this tab has restarted for [param key] in this shell build. Kept in `sessionStorage`, not `user://`: in a browser files reach IndexedDB only through an asynchronous sync,
## so a write that did not land is a reload with no plan that updates and reloads for ever (six reloads in seventy seconds measured).
## A desktop build writes files synchronously and has the plan's own guard; it counts nothing here.
## The counts are kept under the shell build and its addons.lock, so a redeploy starts them again, and a set's counts go once its addons are running
## ([method _clear_update_attempts]): a tab that had spent its two restarts on two updates that worked once refused the third and started PLAYLOT without its weapons.
func _update_attempts(key: String) -> int:
	var counts := _read_update_attempts()
	return int(counts.get(key, 0))


func _note_update_attempt(key: String) -> void:
	var counts := _read_update_attempts()
	counts[key] = int(counts.get(key, 0)) + 1
	_write_update_attempts(counts)


## Forgets the restarts counted for [param target] (every addon set), once its addons are running: a restart that worked is not one that failed.
## Without this every update that worked counted against the next, and two games with different sets in one tab used up each other's restarts.
func _clear_update_attempts(target: String) -> void:
	var counts := _read_update_attempts()
	var kept := {}
	for key: String in counts:
		if not key.begins_with(target + "|"):
			kept[key] = counts[key]
	if kept.size() != counts.size():
		_write_update_attempts(kept)


## Forgets one count, for the player's Retry.
func _forget_update_attempt(key: String) -> void:
	var counts := _read_update_attempts()
	if counts.erase(key):
		_write_update_attempts(counts)


## What the counts are kept under: this shell build and the addons it was exported with.
func _attempts_build() -> String:
	return "%s/%s" % [shell_build, DotCloudAddonSet.build_fingerprint()]


func _attempts_storage() -> Variant:
	if attempt_storage != null:
		return attempt_storage
	return DotWeb.get_global("sessionStorage") if DotPlatform.is_web() else null


func _write_update_attempts(counts: Dictionary) -> void:
	var storage: Variant = _attempts_storage()
	if storage == null:
		return
	storage.setItem(UPDATE_ATTEMPTS_KEY, JSON.stringify({"build": _attempts_build(), "counts": counts}))


## The counts for this build: empty for another build's, and for the flat map shells kept before these were keyed.
func _read_update_attempts() -> Dictionary:
	var storage: Variant = _attempts_storage()
	if storage == null:
		return {}
	var raw: Variant = storage.getItem(UPDATE_ATTEMPTS_KEY)
	var parsed: Variant = JSON.parse_string(str(raw)) if raw != null else null
	if not (parsed is Dictionary) or not DotValue.same((parsed as Dictionary).get("build"), _attempts_build()):
		return {}
	var counts: Variant = (parsed as Dictionary).get("counts")
	return (counts as Dictionary).duplicate() if counts is Dictionary else {}


## Whether [param wanted] failed to start in THIS shell build. [method DotCloudAddonSet.failed_before] keys the mark by addons.lock alone,
## so a redeploy that kept the lock kept the mark, and the tab never tried that set again. The plan is stamped with the shell build that
## built it ([method _stamp_plan]); a mark from another build, or from a shell before the stamp, gets one more try.
func _overlay_failed_here(wanted: Dictionary) -> bool:
	return DotCloudAddonSet.failed_before(wanted) \
		and DotValue.same(DotCloudAddonSet.read_plan().get("shell", ""), shell_build)


## Whether the overlay [param attempt] names must not be built again in this tab: it failed to start in this shell build, or it has had
## its [constant MAX_UPDATE_RESTARTS] restarts. [method _solo_overlay] then blocks the game instead of starting it without its addons.
func _overlay_blocked(attempt: String, wanted: Dictionary) -> bool:
	return _overlay_failed_here(wanted) or _update_attempts(attempt) >= MAX_UPDATE_RESTARTS


## Stamps the plan just built with this shell build. See [method _overlay_failed_here].
func _stamp_plan() -> void:
	var plan := DotCloudAddonSet.read_plan()
	if plan.is_empty():
		return
	plan["shell"] = shell_build
	DotCloudAddonSet.write_plan(plan)


## Whether [param plan]'s overlay only adds to this process: no overlay is mounted yet and none of its addons is here. Such an
## overlay can be mounted without a restart ([method _mount_in_place]); one that replaces an addon cannot.
static func _overlay_additive(plan: Dictionary) -> bool:
	if str(ProjectSettings.get_setting(OVERLAY_SETTING, "")) != "":
		return false
	var addons: Variant = plan.get("addons", {})
	if not (addons is Dictionary) or (addons as Dictionary).is_empty():
		return false
	for dir: String in addons:
		if DirAccess.dir_exists_absolute("res://addons/%s" % dir):
			return false
	return true


## Mounts the overlay the plan on disk names in this process and confirms it, through [method DotCloudAddonSet.mount_now] (the
## boot script may name no class, so the shell makes the call). Only for an [method _overlay_additive] plan: mounting
## refreshes the global class list, and with no compiled copy of these addons in memory their scripts load from it.
## [constant InPlace.REFUSED] leaves the plan ready for a restart.
func _mount_in_place() -> InPlace:
	match DotCloudAddonSet.mount_now():
		DotCloudAddonSet.MountNow.RUNNING:
			return InPlace.RUNNING
		DotCloudAddonSet.MountNow.STALE:
			return InPlace.STALE
	return InPlace.REFUSED


## Where the last restart onto newer addons was going and who was signed in, taken once:
## `{server, member}`, or empty.
func _take_resume() -> Dictionary:
	var plan := DotCloudAddonSet.read_plan()
	var resume: Variant = plan.get("resume", {})

	if not (resume is Dictionary) or (resume as Dictionary).is_empty():
		return {}

	plan["resume"] = {}
	DotCloudAddonSet.write_plan(plan)
	return resume as Dictionary


## Seconds [method _restart] waits for [param keep] to reach IndexedDB: the base, plus the time their size takes.
static func _persist_timeout(keep: PackedStringArray) -> float:
	var total := 0
	for path in keep:
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			total += file.get_length()
	return PERSIST_TIMEOUT_SEC + float(total) / float(PERSIST_BYTES_PER_SEC)


## Restarts this client, by its platform's means; false when it cannot. [member restart_fn] stands in under test.
## [param keep] is what the next start has to find: a browser reloads only once each file is in IndexedDB.
func _restart(keep: PackedStringArray = PackedStringArray()) -> bool:
	if restart_fn.is_valid():
		restart_fn.call()
		return true

	if not DotPlatform.can_self_restart():
		return false

	if DotPlatform.is_web():
		# Waits for IndexedDB to hold what the next load reads, by reading it back: one `FS.syncfs` walks every file in `user://` and takes seconds,
		# a reload inside it loses the plan and addons, and a sync can fail outright, so no count of requests is right.
		# See [method DotCloudAddonSet.persisted].
		var kept: DotResult = await DotCloudAddonSet.persisted(keep, _persist_timeout(keep))
		if not kept.ok:
			# A reload now would come back without them: no plan is no overlay and no
			# sign-in, and the same update again. Play on, and the next start takes it if
			# the browser got there by then.
			DotLog.warn(CHANNEL, "not restarting: the browser has not saved what the next start needs", {
				"why": str(kept.error),
			})
			return false
		# Through the location object rather than `eval`, which a strict CSP refuses (`DotWeb.get_global`).
		# Called as a method, not `Object.call("reload")`: on a JavaScriptObject that asks for a method named `call`.
		var location: Variant = DotWeb.get_global("location")
		if location == null:
			return false
		# dot-game's DotGameClient arms a "Leave site?" prompt while a game is live; this reload is ours, so it is disarmed (by property, not eval, same CSP reason).
		# The flag is absent when no game client installed it.
		var tab_guard: Variant = DotWeb.get_global("__dotTabGuard")
		if tab_guard != null:
			tab_guard.armed = false
		location.reload()
		return true

	# Both halves of the command line: `get_cmdline_args()` stops at the bare `--`, and everything this shell reads (`--connect`, `--udp`, ...) is after it.
	var args := OS.get_cmdline_args()
	var user := OS.get_cmdline_user_args()

	if not user.is_empty():
		args.append("--")
		args.append_array(user)

	OS.set_restart_on_exit(true, args)
	get_tree().quit()
	return true


## The client scene for every game that ships inside this build, keyed on the game's CONTENT id (`game_id` is the operator's directory name).
## A match, never a default: falling back to another game for an unknown id would show a working connection to a room the server is not running.
## EMPTY on purpose: every game is a downloaded pack, so a new game needs no new export. An entry for a game that is also published would win on this build and drift from the delivered copy.
const BUILTIN_CLIENTS := {}


## This process is playing alone: packs mounted from here on are `solo`, and the index offers
## solo entries to the catalogues that follow it.
func _enter_solo_session() -> void:
	DotContentIndex.shared().set_session(DotContentIndex.SESSION_SOLO)
	if _cloud != null:
		_cloud.session_tag = DotContentIndex.SESSION_SOLO


## This process is joining a server: nothing subscribed is visible from here, and what the
## server's game mounts is tagged `online` (a pack already mounted at the same id and version
## is reused and tagged, by dot-cloud, not downloaded again).
func _enter_online_session() -> void:
	DotContentIndex.shared().set_session(DotContentIndex.SESSION_ONLINE)
	if _cloud != null:
		_cloud.session_tag = DotContentIndex.SESSION_ONLINE


## What the game says it takes from a subscription: `accepts` in the `provides.json` at the
## root of its own pack. Read from the mount, because the content index keeps a pack's entries
## and not its manifest. Empty means none, and the Workshop is not asked.
func _game_accepts(mount: String) -> Dictionary:
	var path := mount.path_join("provides.json")
	if not FileAccess.file_exists(path):
		return {}
	return _accepts_from_text(FileAccess.get_file_as_string(path))


func _accepts_from_text(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var accepts: Variant = (parsed as Dictionary).get("accepts", null)
		if accepts is Dictionary:
			return accepts
	return {}


## The site the Workshop reads from: the one this build signs in against, from the same
## shipped file the sign-in reads, never from the page.
func _workshop_site() -> String:
	if workshop_backbone_url != "":
		return workshop_backbone_url
	if _auth != null and _auth.config != null and _auth.config.backbone_url != "":
		return _auth.config.backbone_url
	if FileAccess.file_exists(AUTH_CONFIG):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(AUTH_CONFIG))
		if parsed is Dictionary:
			return str((parsed as Dictionary).get("backbone_url", ""))
	return ""


## Places the Workshop beside the content client. Idempotent.
func _ensure_workshop() -> DotCloudWorkshop:
	if _workshop != null and is_instance_valid(_workshop):
		return _workshop

	_ensure_cloud()
	_workshop = DotCloudWorkshop.new()
	_workshop.name = "Workshop"
	_workshop.cloud = _cloud
	_workshop.config = DotCloudWorkshopConfig.new()
	_workshop.config.workshop_backbone_url = _workshop_site()
	# The bearer is read when asked, so a refresh between launches is picked up; a guest, and
	# a build with no sign-in at all, answers "".
	_workshop.token_fn = _workshop_token
	_workshop.ask_fn = _ask_download
	_workshop.progress.connect(_on_workshop_progress)
	_workshop.pack_failed.connect(func(id: String, _v: String, error: DotError) -> void:
		DotLog.warn(CHANNEL, "a subscribed pack could not be mounted", {"pack": id, "why": str(error)}))
	add_child(_workshop)
	return _workshop


func _workshop_token() -> String:
	if _auth == null or _auth.store == null or not _auth.store.has_credentials():
		return ""
	return _auth.store.access_token()


## Runs the sync for a solo game behind the loading screen. The value is the summary; a
## refusal or a programmer error is an empty one, because nothing here may stop a game.
func _sync_workshop(content_id: String, suggested: PackedStringArray = PackedStringArray()) -> Dictionary:
	var workshop := _ensure_workshop()
	workshop.suggested = DotCloudSuggested.from_entries(suggested)
	workshop.config.workshop_backbone_url = _workshop_site()

	# Refresh the bearer first: `token_fn` is synchronous and a token that has just expired
	# would read as a guest.
	if _auth != null and _auth.is_signed_in():
		await _auth.valid_access_token()

	var res: DotResult = await workshop.sync(content_id)

	if not res.ok:
		DotLog.warn(CHANNEL, "the Workshop sync did not run", {"why": str(res.error)})
		return {}

	return res.value as Dictionary if res.value is Dictionary else {}


## Declares the game's suggested packs for the Subscriptions page and fetches them in the
## background only when this device or the command line chose "all" (or groups). By default the
## game fetches each map when it is picked: a bulk sync of every map pack (~1 GB) never starts unasked.
func _sync_suggested_later(content_id: String, suggested: PackedStringArray) -> void:
	if suggested.is_empty():
		return
	var workshop := _ensure_workshop()
	var declared := DotCloudSuggested.from_entries(suggested)
	workshop.suggested = declared
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	var device_mode := workshop.device.suggested_mode() if workshop.device != null else ""
	var mode := late_suggested_mode(device_mode, args, DotCloudSuggested.groups_of(declared))
	if mode == DotCloudSuggested.MODE_NONE:
		DotLog.debug(CHANNEL, "suggested packs are fetched one map at a time", {"content": content_id, "declared": suggested.size()})
		return
	var kept_config := workshop.config.workshop_suggested
	workshop.config.workshop_suggested = mode
	_late_sync = true
	await _sync_workshop(content_id, suggested)
	_late_sync = false
	workshop.config.workshop_suggested = kept_config


## The suggested-pack mode once a solo game is on screen: none unless the device or the command
## line asked for all (or groups). "ask" is none too: a question there lands on top of play.
static func late_suggested_mode(device_mode: String, args: PackedStringArray, groups: PackedStringArray) -> String:
	var base := device_mode if device_mode != "" else DotCloudSuggested.MODE_NONE
	var mode := DotCloudSuggested.mode_from_args(args, groups, base)
	if mode == "" or DotCloudSuggested.asks(mode):
		return DotCloudSuggested.MODE_NONE
	return mode


## Whether a download that starts now may put the blocking loading cover over the game.
func _cover_may_block() -> bool:
	var live := _has_spawned and _menu != null and not _menu.visible
	return TmcLoadingScreen.may_block_live_game(live, _solo_session != null, _late_sync)


func _on_workshop_progress(done: int, total: int, bytes_done: int, bytes_total: int, current: String) -> void:
	if _launch_job or _late_sync or loading == null or total <= 0:
		return
	if not _cover_may_block():
		return
	if not loading.is_showing():
		loading.begin(TmcLoadingScreen.REASON_GAME)
	var fraction := float(done) / float(total)
	if bytes_total > 0:
		fraction = (float(done) + clampf(float(bytes_done) / float(bytes_total), 0.0, 1.0)) / float(total)
	loading.set_progress(clampf(fraction, 0.0, 1.0), _text("workshop.progress",
		{"done": mini(done + 1, total), "total": total, "title": current},
		"Subscribed content %d/%d, %s" % [mini(done + 1, total), total, current]))


## "Download 120 MB of subscribed content?", awaited by the sync before it fetches. A late sync
## never opens it over a running game: the player chose "all", so it goes on unless metered.
func _ask_download(summary: Dictionary) -> bool:
	if workshop_ask_override.is_valid():
		return bool(await workshop_ask_override.call(summary))
	if _late_sync:
		return not bool(summary.get("metered", false))

	var dialog := TmcShellStyle.dialog(ConfirmationDialog.new())
	dialog.title = _text("workshop.ask.title", {}, "Subscribed content")
	dialog.dialog_text = _text("workshop.ask.text", {"size": DotPaths.format_bytes(int(summary.get("bytes", 0)))},
		"Download %s of subscribed content?" % DotPaths.format_bytes(int(summary.get("bytes", 0))))
	dialog.confirmed.connect(func() -> void: _download_answered.emit(true))
	dialog.canceled.connect(func() -> void: _download_answered.emit(false))
	add_child(dialog)
	_popup_dialog(dialog)
	var yes: bool = await _download_answered
	dialog.queue_free()
	return yes


## The Subscriptions page for the game on screen.
func _make_workshop_panel() -> TmcWorkshopPanel:
	var panel := TmcWorkshopPanel.new()
	panel.workshop = _workshop
	panel.text_fn = _text
	panel.site_url = _workshop_site()
	# The web's sign-in is a game-bound handoff; the site refuses it an all-games change.
	panel.game_bound = DotPlatform.is_web()
	panel.no_sign_in = _auth == null
	if _solo_session != null:
		panel.summary = _solo_session.workshop_summary
		panel.takes_subscriptions = _solo_session.takes_subscriptions
		panel.game_name = _solo_session.display_name
	return panel


## A restart that comes back to this join, for a process that has a script pack resident.
## A browser reloads and a desktop build relaunches (see [method _restart]); the plan's
## `resume` is what the next start reads to join [param target] as the addon update does.
func _restart_for_online(target: String) -> void:
	_say(_text("workshop.restarting", {}, "Restarting to leave your subscribed content behind…"))

	var resume := {"server": target}
	if _auth != null and _auth.is_signed_in() and _auth.identity() != null:
		resume["member"] = _auth.identity().uid

	var plan := DotCloudAddonSet.read_plan()
	if TmcShellSolo.plan_holds_subscription(plan):
		# A state the boot does not mount: the next start comes up on the build alone and resumes the join,
		# whose own addon update builds the server's overlay if it announces one.
		plan = {"format": int(plan.get("format", 1)), "build": plan.get("build", ""), "state": "dropped"}
	plan["resume"] = resume
	var keep := PackedStringArray([DotCloudAddonSet.PLAN])
	if resume.has("member"):
		var tokens := _auth.config.token_store_path
		for path in [tokens, tokens + ".salt"]:
			if FileAccess.file_exists(path):
				keep.append(path)

	var written := DotCloudAddonSet.write_plan(plan)
	if written.ok and await _restart(keep):
		return

	# Never join with a subscribed script resident: the player restarts by hand.
	DotLog.warn(CHANNEL, "not joining: a subscribed pack that runs code is loaded and this platform cannot restart itself", {
		"server": target,
	})
	_status.text = _text("workshop.restart_by_hand", {},
		"Close and reopen the game to join a server: a subscribed pack that runs code is loaded.")


## `--content-url <base>` on a desktop launch: one more place to ask for packs, after `content.json`'s. Only an address (every manifest still verifies against this build's key), never read from the page.
func _adopt_content_url_arg() -> void:
	var url := _user_arg("--content-url").strip_edges()
	if url == "" or _cloud == null:
		return
	var bases := _cloud.http_base_urls
	if not bases.has(url):
		bases.insert(0, url)
		_cloud.http_base_urls = bases


## Every menu a solo game builds leaves to the shell: dot-menu's stock Leave disconnects `leave_link` when connected, and offline in a browser hides itself.
## Pointed at the session it reads "Back to menu" and comes here; watched with `node_added` because games build menus when they like.
func _on_solo_node_added(node: Node) -> void:
	if _solo_session == null or not (node is DotMenu) or not _game_root.is_ancestor_of(node):
		return
	var menu := node as DotMenu
	menu.leave_link = _solo_session
	menu.leave_on_its_own = true
	(func() -> void:
		if is_instance_valid(menu):
			menu.apply_server_rules({"leave_text": "Back to menu"})
			TmcWorkshopPanel.add_to_menu(menu, _make_workshop_panel)
	).call_deferred()


## Leave in a solo game: the game comes down and the menu comes back, with Play solo on it.
func _leave_solo() -> void:
	_clear_game()
	_end_solo_session()
	_leave_game_ui()
	_set_busy(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_menu.visible = true
	if _friends != null:
		_friends.on_disconnected()
	_say("")
	if _solo_button != null and is_instance_valid(_solo_button):
		_focus_when_shown(_solo_button)


func _end_solo_session() -> void:
	if get_tree().node_added.is_connected(_on_solo_node_added):
		get_tree().node_added.disconnect(_on_solo_node_added)
	if _cloud != null and is_instance_valid(_cloud):
		_cloud.config.side = "client"
	if _solo_session == null:
		return
	DotRegistry.unregister_instance(TmcSolo.MAPS_SERVICE, _solo_session)
	if is_instance_valid(_solo_session):
		remove_child(_solo_session)
		_solo_session.queue_free()
	_solo_session = null


## Whether a solo game is on screen. For a suite.
func is_solo() -> bool:
	return _solo_session != null


## The server told us which game it is running; fires on the first load and on every change.
## The old game comes down here, not in `_on_spawned`: `DotClientLink._unload_scene` frees only a scene *it* built, so built-in games would stack, each with its own netcode manager.
func _on_game_changed(game_id: String, _content_id: String, display_name: String) -> void:
	_join_marks["game_changed"] = Time.get_ticks_usec()
	if _joining and display_name != "":
		loading.set_progress(-1.0, _text("shell.loading.game", {"game": display_name}, "Loading %s…" % display_name))
	if _has_spawned or _joining:
		loading.begin(TmcLoadingScreen.REASON_GAME, game_id, display_name)
	# What is on the menu depends on the game -- its live tools, its own items -- so a page
	# from the last one is a page of choices that may not exist any more. Seen in a browser:
	# "Player commands" still open over the new game after a change made from the menu.
	if admin_menu != null:
		admin_menu.close()
	_clear_game()
	if _friends != null:
		_friends.on_game_changed(display_name if display_name != "" else game_id, link.server_hostname if link != null else "")
	_say("Loading %s…" % (display_name if display_name != "" else game_id))


## Signon finished. Put the game on screen.
func _on_spawned() -> void:
	_log_join()
	_joining = false
	_set_busy(false)
	_menu.visible = false
	_has_spawned = true
	# Both: the new game is on screen, and whatever the content client was doing for it is
	# done whether or not its last phase said so.
	loading.end(TmcLoadingScreen.REASON_GAME)
	loading.end(TmcLoadingScreen.REASON_CONTENT)
	# A new connection is a new session on the server, which knows nothing of the last
	# one's claim.
	_claimed_party = ""
	_claim_party.call_deferred()

	if _friends != null and link != null:
		_friends.on_playing(
			_address.text.strip_edges(), link.server_id,
			link.server_game_name if link.server_game_name != "" else link.server_game_id,
			link.server_hostname
		)

	if _game_root.get_child_count() > 0:
		# The server named a scene and the link built it out of downloaded content.
		_say("")
		_start_addon_entries()
		_watch_game_ready()
		return

	var content_id := link.server_content_id

	if content_id == "":
		# A server running nothing at all is legitimate, and said out loud because an empty screen is indistinguishable from a broken client.
		_fail("This server is not running a game yet.")
		return

	if not BUILTIN_CLIENTS.has(content_id):
		# Say which side is behind, because the symptom points at neither: with an empty BUILTIN_CLIENTS the likely cause is a server older than this client,
		# or a deployment whose dot-server addon was not pulled with its host; "named a game and sent nothing" is what a `kind: builtin` descriptor looks like from here.
		DotLog.error(CHANNEL, "the server sent no content for the game it named", {
			"content_id": content_id,
			"builtin_clients": BUILTIN_CLIENTS.size(),
			"hint": "this build ships no game; the server needs updating "
				+ "(git pull in the deploy repo AND in ../dot-*, then restart)",
		})
		_fail(
			"'%s' could not be loaded: this server sent no content to download.\n"
			% content_id
			+ "It is probably running an older build than this client."
		)
		return

	var path := String(BUILTIN_CLIENTS[content_id])
	await _solo_packs._slice_load(TmcShellSoloPacks._scene_dependency_paths(path))
	var packed: Variant = load(path)

	if packed == null:
		_fail("The client scene for '%s' would not load." % content_id)
		return

	var instance := (packed as PackedScene).instantiate()

	# The link is handed over explicitly rather than looked up in DotRegistry, so that two
	# shells in one process — which is what a test does — do not both find the same one.
	if "link" in instance:
		instance.set("link", link)

	_game_root.add_child(instance)
	_say("")
	_watch_game_ready()


## Holds the loading screen over a game until it is ready: [TmcGameCover] uses a game's [DotLoadGate], else the root contract (`ready_to_show`), else a camera-and-settle wait.
## The shell does it because a shader compiles synchronously at first draw under Compatibility, and a game is on screen before its map and players are.
func _watch_game_ready() -> void:
	_cover.watch()


## Starts the client side of the extra packs this server added (`cfg/addons.yml`), reported as `content_extra`; children of the game root, so [method _clear_game] frees them.
## Once per game (a second call finds its own children and stops). Only a shell exported after this existed does it; older shells mount the packs and never start their entry.
func _start_addon_entries() -> void:
	if link == null or _cloud == null or link.content_extra.is_empty():
		return

	for child in _game_root.get_children():
		if str(child.name).begins_with("Addon_"):
			return

	TmcAddonEntry.attach(_game_root, _cloud, link.content_extra, "client")


## Takes the current game off screen, whoever built it. `free()`, not `queue_free()`: the next game is added in the same frame, and two games at once are two netcode managers and cameras, long enough to send a packet from the wrong one.
func _clear_game() -> void:
	for child in _game_root.get_children():
		_game_root.remove_child(child)
		child.free()


## Takes the current link out of the tree, closing whatever it still has open.
## `remove_child` before `queue_free`: the link's name "Server" is the routing and a colliding sibling is renamed ("Server2"), so the OLD node answers the handshake while [DotRegistry] hands out the new one,
## whose snapshots addressed to "Server/<game>" never land: no error, an empty world. `queue_free` alone defers the name's release to the end of the frame.
func _drop_link() -> void:
	if link == null or not is_instance_valid(link):
		link = null
		return

	# Closes the socket and clears the peer. A link freed while still connected leaves the
	# server holding a session it can only reap on timeout, and leaves this end believing
	# it is still on a network.
	link.disconnect_from_server()
	remove_child(link)
	link.queue_free()
	link = null


## Routes a server notice: the admin menu's pages, the loading screen's document, and
## everything else to the HUD overlay.
func _on_notice(notice: DotNotice) -> void:
	if notice == null:
		return
	match notice.topic:
		TmcAdminMenuPanel.TOPIC:
			if notice.is_clear():
				admin_menu.close()
			else:
				var page: Variant = notice.data.get("menu", {})
				admin_menu.show_page(page if page is Dictionary else {})
		TmcLoadingScreen.TOPIC:
			loading.adopt(notice.data)
		TmcRadioLink.TOPIC:
			radio_link.adopt(notice.data)
		_:
			notices.show_notice(notice)


## What goes when a game does: the menu an admin had open, and the loading screen with
## whatever server it belonged to.
func _leave_game_ui() -> void:
	_has_spawned = false
	_joining = false
	if admin_menu != null:
		admin_menu.close()
	if loading != null:
		loading.reset()
	if radio_link != null:
		radio_link.reset()
	if trail_link != null:
		trail_link.reset()


## Notes when the link entered a phase, for [method _log_join].
func _mark_join(phase: int) -> void:
	if not _joining:
		return
	var key: String = DotClientLink.Phase.keys()[phase]
	if not _join_marks.has(key):
		_join_marks[key] = Time.get_ticks_usec()


## One line saying where a first join's time went, in milliseconds, for a browser console. `load` is `LOADING` to `PLAYING`, so the game's own `_ready` is inside it.
func _log_join() -> void:
	if not _joining or not _join_marks.has("start"):
		return
	var now := Time.get_ticks_usec()
	var order := ["start", "CONNECTING", "AUTHENTICATING", "DOWNLOADING", "dl_first", "dl_last", "LOADING", "PLAYING"]
	var stages := {}
	var last: int = _join_marks["start"]
	var last_name := "start"
	for key in order.slice(1):
		if _join_marks.has(key):
			stages["%s>%s" % [last_name, key]] = int((int(_join_marks[key]) - last) / 1000.0)
			last = _join_marks[key]
			last_name = key
	stages["%s>spawned" % last_name] = int((now - last) / 1000.0)
	stages["total"] = int((now - int(_join_marks["start"])) / 1000.0)
	DotLog.info(CHANNEL, "join timings (ms)", stages)
	_join_marks = {}


## Says something whether or not the menu is on screen: the status label lives in the menu, which is hidden while a game runs,
## so a failure after signon was written to an invisible node and the page sat grey.
func _say(text: String) -> void:
	if _status != null:
		_status.text = text


## A small panel over a running game: what failed, "Clear downloaded content…" and
## Dismiss. Frees the mouse while it is up (the game is likely captured it) and gives it
## back the way it found it.
func show_content_failed(reason: String) -> void:
	if _content_failed == null:
		var layer := CanvasLayer.new()
		layer.name = "ContentFailed"
		layer.layer = 90
		add_child(layer)
		var centre := CenterContainer.new()
		centre.set_anchors_preset(Control.PRESET_TOP_WIDE)
		centre.offset_top = 24.0
		centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(centre)
		_content_failed = PanelContainer.new()
		_content_failed.theme = TmcShellStyle.theme()
		_content_failed.add_theme_stylebox_override("panel", TmcShellStyle.card(16, Color(TmcShellStyle.PANEL, 0.96)))
		_content_failed.custom_minimum_size = Vector2(420.0, 0.0)
		centre.add_child(_content_failed)
		var pad := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + side, 14)
		_content_failed.add_child(pad)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)
		pad.add_child(box)
		var heading := TmcShellStyle.eyebrow("Content problem")
		heading.add_theme_color_override("font_color", TmcShellStyle.DANGER)
		box.add_child(heading)
		_content_failed_text = Label.new()
		_content_failed_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_content_failed_text.custom_minimum_size = Vector2(392.0, 0.0)
		box.add_child(_content_failed_text)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		var dismiss := Button.new()
		dismiss.text = "Dismiss"
		dismiss.pressed.connect(_hide_content_failed)
		TmcShellStyle.ghost(dismiss)
		row.add_child(dismiss)
		var clear := Button.new()
		clear.name = "Clear"
		clear.text = "Clear downloaded content\u2026"
		clear.pressed.connect(func() -> void:
			_hide_content_failed()
			_ask_clear())
		_primary(clear)
		row.add_child(clear)

	_content_failed_text.text = "Could not load the content this server needs.\n%s" % reason
	if not _content_failed.visible:
		_mouse_before_prompt = Input.mouse_mode
	_content_failed.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func content_failed_visible() -> bool:
	return _content_failed != null and _content_failed.visible


func _hide_content_failed() -> void:
	if _content_failed == null or not _content_failed.visible:
		return
	_content_failed.visible = false
	Input.mouse_mode = _mouse_before_prompt


## Where a "clear downloaded content" waits for the next start. See [method request_clear].
const CLEAR_PENDING := "user://dot_cloud_clear_pending"

## dot-cloud's default cache. Cleared as well as whichever one this session uses, so a
## player who switched "keep downloaded games" off is not left with the kept ones.
const DEFAULT_CACHE := "user://dot_cloud"


## Bytes of downloaded content on disk: the cache this session uses, the default one and
## the session-only one, each counted once.
func downloaded_bytes() -> int:
	var total := 0
	for dir in _cache_dirs():
		for rel in DotPaths.list_files_recursive(dir):
			# The addon directory's plan and saved class list are bookkeeping, not content;
			# only its overlays are something a player downloaded.
			if dir == DotCloudAddonSet.DIR and not rel.ends_with(".pck"):
				continue
			total += maxi(DotPaths.file_size(dir.path_join(rel)), 0)
	return total


func _cache_dirs() -> PackedStringArray:
	var dirs := PackedStringArray([DEFAULT_CACHE, SESSION_CACHE, DotCloudAddonSet.DIR])
	if _cloud != null and _cloud.config != null and not _cloud.config.cache_dir in dirs:
		dirs.append(_cloud.config.cache_dir)
	return dirs


func _ask_clear() -> void:
	if _clear_confirm == null:
		_clear_confirm = ConfirmationDialog.new()
		_clear_confirm.title = "Clear downloaded content"
		_clear_confirm.ok_button_text = "Clear and restart" if DotPlatform.can_self_restart() \
			else "Clear on next start"
		_clear_confirm.confirmed.connect(request_clear)
		TmcShellStyle.dialog(_clear_confirm)
		# The shell's own child, not the menu's: it is also asked for in a game, with the
		# menu hidden, and a dialog under a hidden Control is hidden with it.
		add_child(_clear_confirm)

	# Under 4 KiB is an empty store's index, not anything a player downloaded.
	var bytes := downloaded_bytes()
	_clear_confirm.dialog_text = (
		("Delete %s of downloaded games and maps?\n\n" % DotPaths.format_bytes(bytes)
			if bytes >= 4096 else "Nothing is downloaded yet.\n\n")
		+ ("The game restarts, and anything you play downloads again."
			if DotPlatform.can_self_restart()
			else "They are deleted the next time the game starts.")
	)
	_popup_dialog(_clear_confirm)


## Centres [param dialog] at [member dialog_width], or narrower on a window that is narrower
## (a phone held upright), so its message wraps on screen instead of running off it.
func _popup_dialog(dialog: AcceptDialog) -> void:
	var area := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1280, 720)
	dialog.popup_centered(Vector2i(TmcShellStyle.dialog_width(area, dialog_width, menu_fit_margin), 0))


## Deletes every download, by restarting into a start that deletes them first. Not now: a pack mounted this session stays merged into `res://` until exit,
## and on Windows the open `.pck` cannot be deleted. So a marker is written and [method clear_pending] empties the cache on the way back up.
## In a browser the marker must reach IndexedDB before the reload ([method _restart]); one that did not land costs a second press.
func request_clear() -> void:
	DotPaths.write_text(CLEAR_PENDING, Time.get_datetime_string_from_system(true))
	# The addon overlay is downloaded content too. Forgotten now, so the restart below
	# comes up on this build's own addons and nothing has it mounted when it is deleted.
	DotCloudAddonSet.forget()
	DotWeb.sync_filesystem()
	DotLog.info(CHANNEL, "downloaded content will be cleared on restart",
		{"bytes": downloaded_bytes()})

	if not restart_fn.is_valid() and not DotPlatform.can_self_restart():
		_say("Downloaded content will be cleared the next time the game starts.")
		return

	if not restart_fn.is_valid():
		_say("Restarting to clear downloaded content\u2026")
		# Not `_set_busy`, which says "Connecting".
		_join.disabled = true

	if not await _restart(PackedStringArray([CLEAR_PENDING])):
		_join.disabled = false
		_say("Reload the page to finish clearing downloaded content.")


## Empties every download cache if [method request_clear] asked for it. Returns the bytes
## freed. Called from `_ready`, before this session has mounted anything.
func clear_pending() -> int:
	var freed := downloaded_bytes()

	# The store first, through dot-cloud, so its index agrees with the empty disk; then
	# the directories whole, for the caches this session is not using.
	_ensure_cloud()
	var started: DotResult = await _cloud.start()
	if started.ok and _cloud.store != null:
		_cloud.store.clear_all()
	for dir in _cache_dirs():
		if dir != _cloud.config.cache_dir:
			DotPaths.remove_tree(dir)

	# No flush of its own: `remove_tree` flushes, and two `FS.syncfs` in flight at once is
	# what once lost downloads in a browser (see DotHttp). A marker that survives costs a
	# second, empty clear on the next start.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CLEAR_PENDING))

	DotLog.info(CHANNEL, "cleared downloaded content", {"bytes": freed})
	_say("Cleared %s of downloaded content." % DotPaths.format_bytes(freed))
	return freed


## Reports something that stopped the game from starting, and puts the menu back: the only way out, since a player who cannot be shown a game needs the address box.
func _fail(text: String) -> void:
	DotLog.error(CHANNEL, text)
	_leave_game_ui()
	_set_busy(false)
	_menu.visible = true
	_say(text)


func _on_disconnected(reason: String) -> void:
	# [b]Read BEFORE the link is dropped.[/b] `_drop_link` frees the node the error is
	# on, and a build-mismatch report assembled afterwards names nothing.
	var err: DotError = link.last_error if link != null else null
	var wanted: String = link.server_signon if link != null else ""

	_clear_game()
	_drop_link()
	_set_busy(false)
	_menu.visible = true

	if _friends != null:
		_friends.on_disconnected()
	# A countdown from a server this player has left is a promise nobody is keeping.
	notices.clear_all()
	_leave_game_ui()

	# The one disconnection a player can act on, and it needs its own sentence: this build's `@rpc` surface does not match the server's, so retrying is useless (see [DotSignon]).
	if err != null and err.code == DotError.CODE_UNSUPPORTED and wanted != "" \
			and wanted != DotSignon.revision([DotClientLink]):
		_report_build_mismatch(wanted)
		return

	# The same revision and still refused: the kinds or message types differ. The server's CODE_VERSION sentence says who has to update, and is the whole message.
	if err != null and err.code == DotError.CODE_VERSION and reason != "":
		DotLog.error(CHANNEL, "refused: this build and the server cannot play together", {
			"why": reason, "detail": err.detail,
		})
		_claimed_party = ""
		_say(reason)
		return

	# The error's key, when the server refused with one the catalogue can say in the
	# player's language; otherwise the reason it gave, which is what this always showed.
	var why := reason if reason != "" else _text("shell.connect.no_reason", {}, "no reason given")

	if err != null and err.detail != "" and _locale != null and _locale.has(err.detail):
		why = _explain(err)

	_claimed_party = ""
	_say(_text("shell.connect.disconnected", {"reason": why}, "Disconnected: %s" % why))


## Tells the player, and tells the page. The page can load another build (every published build stays at its immutable prefix), so it is told which revision is wanted.
## Posted rather than thrown, through [DotWeb] because the `JavaScriptBridge` singleton is only REGISTERED on the web export, so naming it fails to resolve on desktop.
func _report_build_mismatch(wanted: String) -> void:
	var ours := DotSignon.revision([DotClientLink])

	_say(
		"This server needs a different build of the game (it wants %s, this is %s)."
		% [wanted, ours]
	)

	DotLog.error(CHANNEL, "build mismatch", {"server": wanted, "client": ours})

	if not DotPlatform.is_web():
		return

	# The shape the loader reads: one message, one type, the two revisions. The page knows what it published; a client naming a build URL could be told to load one.
	var payload := {
		"type": "tmc.build.mismatch",
		"server_signon": wanted,
		"client_signon": ours,
	}

	DotWeb.post_to_parent(payload)
