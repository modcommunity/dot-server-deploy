extends Node

## The client shell: connect to a server, be sent a game, play it.
##
## [b]This is the whole client.[/b] It knows nothing about any particular game — it opens a
## connection, lets dot-server take it through signon, and instantiates whatever scene the
## server said to load. A game shipped inside this build is instantiated by path; a game
## delivered as a dot-cloud pack is mounted first and instantiated out of the mount.
##
## In a browser the server comes from the query string (`?server=wss://host:port`), because
## a tab cannot listen and a person who followed a link has already chosen where they are
## going.
##
## [b]What a delivered game may not do.[/b] A mounted pack's `class_name` globals are not
## registered in this process — measured, not assumed — so every cross-file type reference
## inside a pack fails to compile: the pack mounts, its scenes load, and every script in it
## is dead. A game meant to be delivered references its own files by path
## (`preload("res://x.gd")`, `extends "res://x.gd"`), both of which resolve out of a mount.
## Games compiled into this build have no such restriction, which is why the lobby is one.

const CHANNEL := "tmc.shell"

## Where the game scene is added. Named so the server's scene and this shell's own UI
## cannot collide.
const GAME_ROOT := &"Game"

## Where an operator puts the public key a delivered game's manifest is signed with.
##
## Shipped inside the export beside the shell, because it must not be settable from the
## page — see [method _ensure_cloud].
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

## The player's party, when they are signed in. See [method _build_party].
var _party: DotPartyClient = null

## Which party this link has already told the server about, so a poll does not claim twice.
var _claimed_party: String = ""
var _party_line: Label = null

## Every sentence this shell shows a player goes through here. See [method _build_locale].
var _locale: DotLocale = null


func _ready() -> void:
	# Scoped to this subtree, for the reason the host scopes its own: Godot addresses an
	# RPC by the receiver's node path relative to its MultiplayerAPI root, and with the
	# default root of `/root` the two ends would have to agree on what each other's scene
	# is *called*. Scoped, both send and expect "Server" and neither knows the other's
	# tree.
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), get_path()
	)

	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.INFO
	)

	_game_root = Node.new()
	_game_root.name = GAME_ROOT
	add_child(_game_root)

	_build_locale()
	_build_menu()

	# Who is playing, before anything is dialled.
	#
	# Awaited rather than fired off, because the answer changes the name the
	# connection is opened with, and a name that arrives after the join is a
	# player who appears as "Guest 812" and is renamed a second later in front of
	# everybody. It costs one round trip inside the TMC player and nothing at all
	# anywhere else — `sign_in()` falls through immediately when there is no page
	# handoff to redeem.
	await _sign_in()

	var wanted := _requested_server()

	if wanted != "":
		# The box shows what we ACTUALLY dialled, before we dial it.
		#
		# It was seeded with a hardcoded localhost default, which is fine for
		# somebody who opened the shell cold and actively misleading for
		# everybody else: a failed auto-connect drops back to this menu, and the
		# address on screen was then not the address that failed. Every report of
		# "it says it cannot reach 127.0.0.1:6064" was about a connection to
		# somewhere else entirely — and pressing Connect retried the wrong thing.
		_address.text = wanted
		_connect_to(wanted)


## Where to connect: the command line, or the page's query string.
##
## The query string is how a browser player arrives. They followed a link that already
## named a server; asking them to type an address they were never shown is asking them to
## leave.
func _requested_server() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--connect")

	if index >= 0 and index + 1 < args.size():
		return args[index + 1]

	if DotPlatform.is_web():
		return DotWeb.query_param("server")

	return ""


## Signs in against the backbone, when the page we are embedded in offers a way.
##
## [b]Deliberately not a login screen.[/b] The only sign-in this shell performs is
## the one that needs no interaction: inside the TMC player, the site hands the
## frame a single-use code saying who pressed Play, and `DotAuthClient` redeems it
## ([DotAuthWebHandoff]). Opened anywhere else — a bare link, a desktop build —
## there is no code, `sign_in()` fails immediately, and the player stays the guest
## they already were.
##
## A device-code flow would be the alternative and it is the wrong trade here: it
## puts a code to read and a browser tab to open in front of somebody who wanted
## to press Play, on a shell whose whole job is to get out of the way.
##
## [b]The name this produces is a LABEL, not a proof.[/b] It travels to the
## server as `player_name` does, and a server that needs to know who somebody
## really is verifies that itself — a scope key handed over on join, or a
## `dot-auth` ticket. Nothing here asks a server to trust us.
func _sign_in() -> void:
	if not DotAuthWebHandoff.supported():
		return

	_auth = DotAuthClient.new()
	_auth.name = "Auth"
	# The shell drives sign-in itself, at the one moment it makes sense: nothing
	# here should start a login because a node entered the tree.
	_auth.auto_sign_in = false
	_auth.config = DotAuthConfig.new()
	_auth.config.client_name = "TMC Web Player"

	# [b]Which backbone, from a file that ships in the build.[/b] `DotAuthClient.start`
	# layers a JSON file, then the environment, then argv — and a browser has neither of
	# the last two, so without this a web player gets whatever `DotAuthConfig`'s exported
	# default happens to be and has no way to be told otherwise. That default was a
	# domain nobody owned; it is now the real site, and a deployment that is not the real
	# site still has to say so.
	#
	# Same file convention and the same reasoning as `client/content.json` below: a
	# shipped file rather than the page's query string, because this URL decides where a
	# single-use sign-in code is redeemed and a link that could aim it elsewhere would be
	# a credential-forwarding link. `config_file` defaults to `user://dot_auth.json`,
	# which on web is an IndexedDB path no operator can put anything in.
	_auth.config_file = AUTH_CONFIG if FileAccess.file_exists(AUTH_CONFIG) else ""

	if _auth.config_file == "":
		DotLog.info(
			CHANNEL,
			"no auth configuration; signing in against the default backbone",
			{"looked_for": AUTH_CONFIG, "backbone": _auth.config.backbone_url}
		)

	add_child(_auth)

	# [b]`try_web_handoff`, not `sign_in`.[/b] `sign_in()` tries the page handoff, then a
	# stored session, and then falls through to `start_device_login()` — so a shell
	# opened as a bare link, which is every standalone embed and every development page,
	# started a DEVICE-CODE login: two requests to the backbone on every page load, for a
	# flow whose code this shell has nowhere to display and nobody will ever read. The
	# comment above has said "there is no code, sign_in() fails immediately" since it was
	# written, and that was the intent rather than the behaviour.
	#
	# It is also what made the wrong backbone visible: those were the two failing requests
	# in the browser console, and a device flow nobody wanted is what was making them.
	var res: DotResult = await _auth.try_web_handoff()

	if not res.ok:
		DotLog.debug(
			"shell", "playing as a guest", {"why": res.code()}
		)
		return

	var identity := res.value as DotAuthIdentity

	_name.text = identity.display_name
	# Read-only rather than hidden: somebody signed in should be able to SEE who
	# the game thinks they are, and a field they can edit would let them type
	# somebody else's name over an identity we were just handed.
	_name.editable = false
	_identity.text = "• Signed in as %s" % identity.display_name
	_identity.visible = true

	_build_party(identity)


## The shell's translator, from the shipped messages and the player's language.
##
## [b]A refusal is a key, and this is what turns one into a sentence.[/b] The site refuses
## with keys (`party.join.deny.full`) and dot-party carries them in `DotError.detail`;
## [method DotLocale.explain] renders one when the catalogue has it and falls back to the
## error's own English message when it does not. So nothing here gets worse for a key the
## shell ships no translation of -- it gets the message it always showed.
##
## Layered like every config here: `--locale-language de` or `--locale-pseudo true` after a
## `--` on a desktop build, which is how a translator checks a build without a settings
## screen. A browser has neither argv nor environment and gets the page's language.
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
##
## The key itself is DotLocale's last resort and is right for a game under development; a
## player who connects to a server with a stripped build should still read a sentence.
func _text(key: String, args: Dictionary, fallback: String) -> String:
	if _locale == null or not _locale.has(key):
		return fallback
	return _locale.t(key, args)


## A refusal in the player's language, or its own message.
func _explain(error: DotError) -> String:
	if error == null:
		return ""
	return _locale.explain(error) if _locale != null else error.message


## The player's party, followed wherever it goes.
##
## [b]Only when signed in[/b], because a party is the site's and the site only knows who a
## signed-in player is. [code]connect_fn[/code] is this shell's own connect path -- the
## Connect button's -- so following the party to a server is exactly what the player would
## have done by hand, including dropping the link they are on.
##
## [b]The site does not serve the player's party routes yet[/b] (dot-party's
## docs/backbone-contract.md). Until it does, every poll is a 404; the first one switches
## this off for the session rather than asking again every twenty seconds for something
## the site has said it does not have.
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

	if p != null:
		_party_line.text = _text("shell.party.line", {"name": p.name, "count": p.size()},
			"Party: %s (%d)" % [p.name, p.size()])

	_claim_party()


func _on_left_party(_party_id: String, reason: String) -> void:
	_claimed_party = ""
	_say(_text("shell.party.left.%s" % reason, {}, "You are no longer in your party."))


func _on_party_request_failed(what: String, error: DotError) -> void:
	if error != null and error.http_status == 404 and _party != null:
		DotLog.info(CHANNEL, "the site does not serve party routes yet; parties are off", {
			"what": what,
		})
		_party.queue_free()
		_party = null
		return

	DotLog.debug(CHANNEL, "a party request failed", {"what": what, "why": _explain(error)})


## Tells the server which party this player is in, once per party per connection.
##
## A chat command rather than a handshake field -- see `TmcParty` on the server for why --
## and a slash command, which dot-server runs before any game's chat hook sees the line and
## never broadcasts. The server checks the party's roster before believing it.
func _claim_party() -> void:
	if _party == null or _party.party == null or link == null or not link.is_connected_to_server():
		return

	if link.phase != DotClientLink.Phase.PLAYING or _claimed_party == _party.party.id:
		return

	_claimed_party = _party.party.id
	link.send_chat("/party_claim %s" % _party.party.id)


## The menu's accent.
##
## The same blue the arena rings the local player with, deliberately: the menu and the
## game are one screen a second apart, and two accents makes them look like two products.
const ACCENT := Color(0.36, 0.68, 1.0)


## The theme every control in the menu inherits.
##
## [code]DotUiTheme.space()[/code] rather than a hand-styled widget per control: dot-ui
## already builds a Panel, a Button, a LineEdit and a ProgressBar out of one palette, and a
## menu that styled each of them here would drift from the panels the GAME builds for its
## own pause and settings screens — which use the same palette, on purpose.


func _build_menu() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Menu"
	add_child(layer)

	_menu = Control.new()
	_menu.name = "Shell"
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.theme = DotUiTheme.space().build()
	layer.add_child(_menu)

	_menu.add_child(MenuBackdrop.new())

	# CENTRED BY A CONTAINER, not by an offset from the middle. The menu used to be a box
	# placed at (-180, -100) from centre with a fixed width, which is centred at exactly one
	# window size and hangs off the top of a short one — and the browser player is a panel
	# whose size the page decides.
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(centre)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(392.0, 0.0)
	centre.add_child(panel)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 30)
	pad.add_theme_constant_override("margin_right", 30)
	pad.add_theme_constant_override("margin_top", 28)
	pad.add_theme_constant_override("margin_bottom", 26)
	panel.add_child(pad)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	pad.add_child(box)

	var title := Label.new()
	title.text = "TMC"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Sized here rather than through the palette's heading size: this is a wordmark, and
	# raising `heading_size` to fit it would also inflate every heading in the game.
	title.add_theme_font_size_override("font_size", 46)
	# The glow is an outline in the accent rather than a second label drawn behind it: one
	# node, and it follows the font size instead of needing a matching offset.
	title.add_theme_color_override(
		"font_outline_color", Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.30)
	)
	title.add_theme_constant_override("outline_size", 9)
	box.add_child(title)

	var blurb := Label.new()
	blurb.text = "Connect to a server. It decides what you play."
	blurb.theme_type_variation = &"DotDim"
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(blurb)

	box.add_child(_gap(16))

	box.add_child(_caption("Display name"))

	_name = LineEdit.new()
	_name.placeholder_text = "Your name"
	_name.text = "Guest %d" % (randi() % 900 + 100)
	_name.max_length = 32
	_name.custom_minimum_size = Vector2(0.0, 40.0)
	box.add_child(_name)

	# Who the backbone says you are, when it said anything. Its own line rather than the
	# status label: a status is the last thing that happened and this is a standing fact,
	# and the two were fighting over one label — "Signed in as X" was replaced by
	# "Connecting…" a frame later, which read as having been signed out.
	_identity = Label.new()
	_identity.visible = false
	_identity.add_theme_color_override("font_color", ACCENT)
	_identity.add_theme_font_size_override("font_size", 13)
	box.add_child(_identity)

	# The party, when there is one. A standing fact like the line above, so its own line.
	_party_line = Label.new()
	_party_line.visible = false
	_party_line.theme_type_variation = &"DotDim"
	_party_line.add_theme_font_size_override("font_size", 13)
	box.add_child(_party_line)

	box.add_child(_gap(4))

	box.add_child(_caption("Server"))

	_address = LineEdit.new()
	_address.placeholder_text = "host:port"
	_address.text = "127.0.0.1:6064"
	_address.custom_minimum_size = Vector2(0.0, 40.0)
	box.add_child(_address)

	box.add_child(_gap(6))

	_join = Button.new()
	_join.text = "Connect"
	_join.custom_minimum_size = Vector2(0.0, 46.0)
	_join.pressed.connect(func() -> void: _connect_to(_address.text))
	_primary(_join)
	box.add_child(_join)

	# THE LOADING BAR. Hidden until something is actually loading, because a bar sitting at
	# zero on a menu is a progress indicator for nothing.
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0.0, 6.0)
	_progress.visible = false
	box.add_child(_progress)

	_status = Label.new()
	_status.theme_type_variation = &"DotDim"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	# [b]The second line, and it is the one somebody waiting actually reads.[/b] A bar
	# and a percentage answer "how much"; they do not answer "how much longer" or "of
	# what", and a player watching a 200 MB map arrive has exactly those two questions.
	# So: the file being fetched, the bytes, the rate and the estimate -- and an empty
	# line rather than a stale one when there is nothing to say.
	_detail = Label.new()
	_detail.theme_type_variation = &"DotDim"
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.modulate = Color(1.0, 1.0, 1.0, 0.62)
	_detail.visible = false
	box.add_child(_detail)

	# No Host button: a browser tab cannot listen, and offering a control that fails on
	# the platform this shell exists for is worse than not offering it.
	if DotPlatform.is_web():
		box.add_child(_gap(2))

		var note := Label.new()
		note.text = "A browser tab cannot host. Follow a link to somebody's server."
		note.theme_type_variation = &"DotDim"
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override("font_size", 12)
		box.add_child(note)

	# Focused after it is in the tree. Grabbing focus on a node that is not yet there is a
	# menu that opens with nothing focused — unusable with a gamepad and invisible with a
	# mouse. game-arena shipped exactly that.
	_join.grab_focus.call_deferred()


## A small label over a field. Two words each, and they are what stops the panel reading as
## a form somebody forgot to label.
func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"DotDim"
	label.add_theme_font_size_override("font_size", 12)
	return label


func _gap(height: float) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, height)
	return spacer


## Makes a button read as the one thing on screen to press.
##
## dot-ui's Button is deliberately quiet — a surface fill and a thin outline — which is
## right for a settings panel with six of them and wrong for a screen with one. Overridden
## on the instance rather than in the theme, so every other button in this build keeps the
## quiet style.
func _primary(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _fill(ACCENT.darkened(0.10)))
	button.add_theme_stylebox_override("hover", _fill(ACCENT))
	button.add_theme_stylebox_override("pressed", _fill(ACCENT.darkened(0.30)))
	button.add_theme_stylebox_override("focus", _outline(Color(1.0, 1.0, 1.0, 0.35)))
	button.add_theme_stylebox_override("disabled", _fill(Color(0.16, 0.20, 0.29, 0.9)))
	# Dark text on a bright fill. White on this blue is under 3:1 and the first thing to
	# become unreadable on a phone in daylight.
	button.add_theme_color_override("font_color", Color(0.02, 0.05, 0.10))
	button.add_theme_color_override("font_hover_color", Color(0.02, 0.04, 0.09))
	button.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 1.0))
	button.add_theme_color_override("font_disabled_color", Color(0.55, 0.60, 0.70))
	button.add_theme_font_size_override("font_size", 17)


func _fill(colour: Color, radius: int = 12) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = colour
	box.set_corner_radius_all(radius)
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	return box


func _outline(colour: Color, radius: int = 12) -> StyleBoxFlat:
	var box := _fill(Color.TRANSPARENT, radius)
	box.border_color = colour
	box.set_border_width_all(2)
	return box


## Puts the menu into — or out of — "something is happening" state.
##
## One place, because the three ways a connection ends (it failed, the server dropped us,
## the game started) all have to undo the same two things, and a Connect button left
## disabled after a failure is a dead end with no error attached to it.
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
##
## [b]The trusted key is the whole of the security here and it comes from a file.[/b]
## `DotCloudConfig` refuses unsigned manifests by default and `validate()` will not boot
## without a key, which is deliberate — a mounted pack can contain scripts, so a client
## that mounts unsigned content runs whatever the server sent. `trusted_keys` is in
## `sensitive_keys`, so it cannot arrive from the environment or the command line: a
## page's query string must not be able to make itself a publisher.
##
## `res://client/content.json` is where an operator puts it, shipped inside the export
## beside the shell. With no such file the client boots with no trusted key, which is
## correct and means "this build plays servers whose games it already has" — and the
## failure a player then sees names the missing configuration rather than the server.
func _ensure_cloud() -> void:
	if _cloud != null and is_instance_valid(_cloud):
		return

	_cloud = DotCloudClient.new()
	_cloud.name = "Cloud"
	_cloud.config = DotCloudConfig.new()

	if ResourceLoader.exists(CONTENT_CONFIG) or FileAccess.file_exists(CONTENT_CONFIG):
		_cloud.config_file = CONTENT_CONFIG
	else:
		DotLog.info(
			CHANNEL,
			"no content configuration; this build can only play games it already has",
			{"looked_for": CONTENT_CONFIG}
		)
		_cloud.config_file = ""

	# [b]Where this build downloads maps from, and it is an operator's decision.[/b]
	#
	# The default is `/content`: the page's own origin, which is the one content layout
	# with no CORS headers to get right. `DotCloudClient` puts the page origin on the
	# front of it at request time — it has to, because [HTTPRequest] parses the URL
	# itself, in C++, before any of the browser sees it, and a root-relative string is
	# not a URL. That resolution was ASSUMED here for months and did not exist: the
	# console said `Error parsing URL: '/content/surf_mesa/manifest.json'`, an engine
	# message naming nothing anybody had configured, and no map ever downloaded.
	#
	# A deployment whose content is somewhere else says so in `content.json`, beside the
	# key it already keeps there:
	#
	#     "content_urls": ["https://games.example.net/content"]
	#
	# That host then needs `Access-Control-Allow-Origin` for the page, which is the cost
	# of not being same-origin and the reason the default is what it is.
	var configured := _configured_content_urls()
	_cloud.http_base_urls = (
		configured if not configured.is_empty() else PackedStringArray(["/content"])
	)

	# [b]No version segment, because the published layout has none.[/b] The default
	# template is `{base}/{id}/{version}/manifest.json`, and `DotCloudPublisher` writes
	# `<id>/manifest.json` — the version is INSIDE the document, and the mount still
	# namespaces by it, so nothing is lost by leaving it out of the path. With the
	# default, `ensure()` asks for `/content/surf_mesa/0.0.0/manifest.json`, gets a 404
	# from a CDN that is serving the map perfectly well one path segment up, and reports
	# "could not get surf_mesa's manifest" — which reads as missing content.
	#
	# [b]This is the path EVERYTHING takes now, not just maps.[/b] It used to say a
	# delivered game did not use it, because dot-server handed the client a manifest URL
	# an operator had written in `game.yml`. `manifest_url` is optional since packs became
	# findable by content id, and the tracked descriptors carry none -- so a game pack is
	# resolved through this template against the bases below, exactly as a map is. Getting
	# the template wrong would now break every game rather than only the maps.
	#
	# [b]Versioned first, flat as a fallback, and the same pair the SERVER uses.[/b] A
	# player is sent to whatever their server mounted, so a client resolving a different
	# shape from the server that told it what to fetch is a game that loads on one and not
	# the other. The site publishes `{id}/{version}/`; the flat form is what the imported
	# map packs were published under and is still asked for by name.
	_cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	_cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])

	# [b]Straight off the content client, not through the link.[/b] DotClientLink
	# forwards a fraction and a sentence, which is all a join needs -- but the payload
	# dot-cloud emits carries the file, the rate and the estimate, and that is the
	# difference between a bar that moves and a wait somebody can sit through. The
	# shell owns this node, so it can read the richer signal without widening anything
	# in the addon.
	_cloud.phase_changed.connect(_on_cloud_phase)
	_cloud.progress_changed.connect(_on_cloud_progress_detail)

	add_child(_cloud)


## The headline: what dot-cloud is doing at all.
##
## Every phase is worth saying out loud. Mounting a 200 MB pack is not instant and
## looks identical to a hang, and "Verifying" is the phase that takes the longest with
## nothing moving on the network -- a bar that sits at 100% through it is how a
## finished download reads as a freeze.
func _on_cloud_phase(phase: int, text: String) -> void:
	if _status != null and text != "":
		_status.text = text

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


## The second line: which file, how fast, how much longer.
func _on_cloud_progress_detail(p: Dictionary) -> void:
	if _progress != null:
		_indeterminate(false)
		_progress.visible = true
		_progress.value = clampf(float(p.get("fraction", 0.0)), 0.0, 1.0) * 100.0

	if _detail == null:
		return

	# [b]Two lines, in the order somebody actually asks the questions.[/b] First "how
	# much longer", then "of what" -- and they are separate lines because one joined
	# string wrapped three times in a 275 px panel and left the word "left" alone on a
	# row of its own. That is invisible to every assertion about the text and obvious
	# in a rendered frame, which is why there is a screenshot of it.
	var numbers := PackedStringArray()

	var total := int(p.get("total_bytes", 0))
	if total > 0:
		numbers.append(_bytes_pair(int(p.get("done_bytes", 0)), total))

	var rate := float(p.get("bytes_per_sec", 0.0))
	if rate > 1.0:
		numbers.append("%s/s" % DotPaths.format_bytes(int(rate)))

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
		what.append("%d of %d" % [mini(int(p.get("done_files", 0)) + 1, files_total), files_total])

	var lines := PackedStringArray()
	if not numbers.is_empty():
		lines.append(" · ".join(numbers))
	if not what.is_empty():
		lines.append(" · ".join(what))

	_detail.text = "\n".join(lines)
	_detail.visible = _detail.text != ""


## `23.5 / 63.0 MiB` rather than `23.5 MiB / 63.0 MiB`.
##
## The unit twice is nine characters that say nothing, and this panel is 215 px wide --
## the first version of this line wrapped and left the word "left" alone on a row.
## Dropped only when both sides land in the same unit, which is most of a download and
## never the interesting end of one.
static func _bytes_pair(done: int, total: int) -> String:
	var a := DotPaths.format_bytes(done)
	var b := DotPaths.format_bytes(total)
	var unit := b.get_slice(" ", 1) if b.contains(" ") else ""

	if unit != "" and a.ends_with(" " + unit):
		return "%s / %s" % [a.trim_suffix(" " + unit), b]

	return "%s / %s" % [a, b]


## A middle-elided name, because the end of a filename is the part that identifies it.
##
## `surf_mesa_geometry_lod0.bin` truncated from the right is `surf_mesa_geometr…`, which
## is every file in that map.
static func _elide(text: String, limit: int) -> String:
	if text.length() <= limit:
		return text
	var keep := (limit - 1) / 2
	return text.substr(0, keep) + "…" + text.substr(text.length() - keep)


## An estimate in the units a person would use for it.
static func _eta_text(seconds: float) -> String:
	# Short, because it shares a line with the bytes and the rate. "about 15s left" and
	# "15s left" carry the same information and one of them fits.
	if seconds < 10.0:
		return "a few seconds"
	if seconds < 90.0:
		return "%ds left" % int(round(seconds / 5.0) * 5)
	var minutes := int(round(seconds / 60.0))
	return "%d min left" % minutes


## `content_urls` out of `client/content.json`, or empty.
##
## Read here rather than through [DotCloudConfig], which has no field for it: the base
## URLs live on the client and the config file is the only thing in an export an
## operator can edit without rebuilding. Parsed defensively -- a file that is present
## but malformed must not stop a build that can still play the games it already has.
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

	_status.text = "Connecting to %s…" % target
	_set_busy(true)

	# Before a new one is built, never after: see [method _drop_link]. Every path that
	# ends a connection drops it too, so this is belt and braces -- except for the one
	# path that does not, which is a signon that failed after the socket came up
	# ([method _fail]), where the menu comes back with the link still connected.
	_drop_link()

	# [b]Without this a browser client cannot download anything, ever.[/b]
	# `DotClientLink._begin_content_sync` resolves `dot_cloud_client` from [DotRegistry]
	# and fails the join outright when it is null — "This server needs downloadable
	# content, which this build cannot fetch" — so a shell with no cloud client can only
	# ever join servers whose games ship inside this build. Every game in `content/` is
	# `kind: builtin` today, which is exactly why nothing noticed.
	_ensure_cloud()

	link = DotClientLink.new()
	# "Server", because Godot routes an RPC by the receiver's node path relative to its
	# MultiplayerAPI root and dot-server's node is called that. The name is the routing,
	# not a description — get it wrong and every RPC fails, handshake included, with a
	# timeout as the only symptom.
	link.name = "Server"
	link.player_name = _name.text.strip_edges()
	# Where the server's game scene is put. The shell never names a scene itself.
	link.game_root_ref = DotNodeRef.of_path(_game_root.get_path())
	add_child(link)

	link.phase_changed.connect(func(_phase: int, text: String) -> void:
		_status.text = text
	)
	link.download_progress.connect(func(fraction: float, text: String) -> void:
		_indeterminate(false)
		_progress.value = clampf(fraction, 0.0, 1.0) * 100.0
		_status.text = "%s  %d%%" % [text, int(fraction * 100.0)]
	)
	link.game_changed.connect(_on_game_changed)
	link.spawned.connect(_on_spawned)
	link.disconnected.connect(_on_disconnected)

	var connecting: DotResult = await link.connect_to_server(target)

	if not connecting.ok:
		_status.text = _text("shell.connect.failed", {"reason": _explain(connecting.error)},
			"Could not connect: %s" % _explain(connecting.error))
		_set_busy(false)
		_drop_link()


## The client scene for every game that ships inside this build.
##
## [b]The whole of what makes this shell multi-game.[/b] A game delivered through dot-cloud
## names its own client scene and [DotClientLink] builds it; a game shipped inside a build
## names none, because `DotClientLink._resolve_scene` refuses every absolute `res://` path
## outside dot-cloud's mount — so for those, the id is the only thing that says which of
## this build's clients to put on screen.
##
## A match, never a default. A shell that fell back to the lobby for an unknown id would
## put a player in a room the server is not running, with the netcode of a game nobody is
## playing — which looks like a working connection and is not one.
## Keyed on the game's CONTENT id, not on the id the operator types.
##
## `game_id` is a directory name under `content/` and is theirs to choose; renaming one
## would leave every client unable to find the scene for a game it still has. `content_id`
## is the game's own identity, and it is also how two game ids share one client — hungry's
## classic and frenzy are one `hungry`.
##
## [b]EMPTY, and that is the whole point of this build.[/b] It held five entries and five
## games were compiled in beside them, so playing a game meant shipping a client that
## already knew about it: a new game was a new export, an upload, and every player on the
## old build unable to join. Every one of the five is a pack now, and this shell downloads
## and mounts whatever the server it joined is running.
##
## The table is kept rather than deleted because the mechanism is still right for anybody
## building a client with a game inside it — a single-game product, a demo, an offline
## build. Add an entry and that content id stops needing a download. What must NOT go back
## is an entry for a game that is also published: the built-in copy would win for players
## on this build and the delivered one for everybody else, and the two would drift.
const BUILTIN_CLIENTS := {}


## The server told us which game it is running. Fires on the first load and on every
## change afterwards.
##
## [b]The old game comes down here, not in `_on_spawned`.[/b] `DotClientLink._unload_scene`
## only frees a scene *it* built, which for a built-in game is nothing — so a shell that
## left this to the link would stack every game an operator ever switched to on top of the
## last, each with its own netcode manager ticking the same tree.
func _on_game_changed(game_id: String, _content_id: String, display_name: String) -> void:
	_clear_game()
	_say("Loading %s…" % (display_name if display_name != "" else game_id))


## Signon finished. Put the game on screen.
func _on_spawned() -> void:
	_set_busy(false)
	_menu.visible = false
	# A new connection is a new session on the server, which knows nothing of the last
	# one's claim.
	_claimed_party = ""
	_claim_party.call_deferred()

	if _game_root.get_child_count() > 0:
		# The server named a scene and the link built it out of downloaded content.
		_say("")
		return

	var content_id := link.server_content_id

	if content_id == "":
		# A server running nothing at all. Legitimate — dot-server supports it — and said
		# out loud, because an empty screen is indistinguishable from a broken client.
		# There is no lobby to fall back to any more: the lobby is delivered like every
		# other game, so a server that is running none has nothing for this client to show.
		_fail("This server is not running a game yet.")
		return

	if not BUILTIN_CLIENTS.has(content_id):
		# [b]Say which side is behind, because the symptom points at neither.[/b] With an
		# empty BUILTIN_CLIENTS this is the only way to get here, and by far the most
		# likely cause is a server older than this client: a server that delivers its
		# games ALWAYS sends content, so "named a game and sent nothing" is what a
		# `kind: builtin` descriptor looks like from here -- or a deployment whose
		# dot-server addon was not pulled alongside its host, which is the same thing one
		# repository further down. The first version of this message said only that no
		# content arrived, which is true, unactionable, and reads as a broken client.
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


## Takes the current game off screen, whoever built it.
##
## `free()`, not `queue_free()`: the next game is added in the same frame, and two games in
## the tree at once means two netcode managers, two input handlers and two cameras — for a
## frame, which is long enough to send a packet from the wrong one.
func _clear_game() -> void:
	for child in _game_root.get_children():
		_game_root.remove_child(child)
		child.free()


## Takes the current link out of the tree, closing whatever it still has open.
##
## [b]Reconnecting without this signs on, downloads nothing, and renders an empty world.[/b]
## The link is named "Server" and that name is the routing: Godot addresses an RPC by the
## receiver's node path relative to the [MultiplayerAPI] root, so everything the server
## sends arrives addressed to "Server" and is delivered to whichever child of this shell
## has that name. A shell that left the dropped link in the tree -- which is what both
## ways out of a live connection used to do -- gets "Server2" for the replacement, because
## Godot renames a colliding sibling rather than refusing the add.
##
## Nothing then errors. The *old* node answers the handshake, because it is the one the
## server's calls resolve to, and its signals are still wired to this shell from the first
## connection, so the menu hides and the game loads. The *new* node is what
## [DotRegistry] hands out, and a delivered game asks the registry for its link and
## parents its own RPC node underneath it -- under "Server2", where a snapshot addressed
## to "Server/<game>" can never land. Signon completes, the pack is already mounted from
## the first connection so there is visibly no download, the scene instantiates, and the
## world stays empty. A page refresh "fixes" it because it is the second link, not the
## connection, that is broken.
##
## `remove_child` before `queue_free`, because a name is released when the node leaves the
## tree and `queue_free` defers that to the end of the frame -- long enough for a
## reconnect in the same frame to collide with a node that is already on its way out.
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


## Says something, whether or not the menu is on screen.
##
## [b]The status label lives inside the menu, and the menu is hidden while a game is
## running.[/b] So a failure written to it after signon — "this build has no client for
## that game", which is the whole of what a multi-game client can get wrong — was written
## to an invisible node and the page just sat there grey. Found by taking a screenshot and
## seeing nothing rather than by reading anything.
func _say(text: String) -> void:
	if _status != null:
		_status.text = text


## Reports something that stopped the game from starting, and puts the menu back.
##
## The menu is what makes the message visible and is also the only way out: a player who
## cannot be shown a game needs the address box back, not a frozen screen.
func _fail(text: String) -> void:
	DotLog.error(CHANNEL, text)
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

	# [b]The one disconnection a player can actually act on, and it needs a different
	# sentence from every other one.[/b] This build's `@rpc` surface does not match the
	# server's, so no amount of retrying will work -- and "Disconnected: ..." beside a
	# Connect button invites exactly that. See [DotSignon].
	if err != null and err.code == DotError.CODE_UNSUPPORTED and wanted != "":
		_report_build_mismatch(wanted)
		return

	# The error's key, when the server refused with one the catalogue can say in the
	# player's language; otherwise the reason it gave, which is what this always showed.
	var why := reason if reason != "" else _text("shell.connect.no_reason", {}, "no reason given")

	if err != null and err.detail != "" and _locale != null and _locale.has(err.detail):
		why = _explain(err)

	_claimed_party = ""
	_say(_text("shell.connect.disconnected", {"reason": why}, "Disconnected: %s" % why))


## Tells the player, and tells the page.
##
## [b]The page is the half that can do something about it.[/b] This build cannot become a
## different build; the thing embedding it can load one. Every build the site has ever
## published is still at its own immutable prefix, so "open the build this server needs"
## is a link the page can already form -- it just has to be told which revision is
## wanted, and there was no way to tell it.
##
## Posted rather than thrown: a shell running natively, or in a page that is not
## listening, must still show the player the sentence. It goes through [DotWeb] because
## the [code]JavaScriptBridge[/code] singleton is only REGISTERED on the web export --
## a script naming it directly does not resolve on desktop, which is the trap
## [DotWeb] exists to close.
func _report_build_mismatch(wanted: String) -> void:
	var ours := DotSignon.revision([DotClientLink, DotClientChat])

	_say(
		"This server needs a different build of the game (it wants %s, this is %s)."
		% [wanted, ours]
	)

	DotLog.error(CHANNEL, "build mismatch", {"server": wanted, "client": ours})

	if not DotPlatform.is_web():
		return

	# The shape the loader reads: one message, one type, the two revisions. Nothing
	# here decides WHICH build to offer -- the page knows what it published and this
	# does not, and a client naming a build URL would be a client that can be told to
	# load one.
	var payload := JSON.stringify({
		"type": "tmc.build.mismatch",
		"server_signon": wanted,
		"client_signon": ours,
	})

	DotWeb.eval(
		"window.parent && window.parent.postMessage(%s, '*')"
			% JSON.stringify(payload),
		true
	)
