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

	# Same origin as the page, so there is no CORS to configure. A root-relative URL is
	# resolved against the page by the browser and is the one content layout that works
	# with no headers at all — which is why `DotCloudClient` treats a scheme-less string
	# as a URL unless the file is genuinely on disk.
	_cloud.http_base_urls = PackedStringArray(["/content"])

	add_child(_cloud)


func _connect_to(address: String) -> void:
	var target := address.strip_edges()

	if target == "":
		_status.text = "Type an address first."
		return

	_status.text = "Connecting to %s…" % target
	_set_busy(true)

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
		_status.text = "Could not connect: %s" % str(connecting.error)
		_set_busy(false)
		link.queue_free()
		link = null


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
const BUILTIN_CLIENTS := {
	"a_room": "res://scenes/room_client.tscn",
	"hungry": "res://game/client/hungry_client.tscn",
	"g2gfast": "res://game/g2g.tscn",
	"playground": "res://game/playground.tscn",
	"arena": "res://game/arena.tscn",
}


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

	if _game_root.get_child_count() > 0:
		# The server named a scene and the link built it out of downloaded content.
		_say("")
		return

	var content_id := link.server_content_id

	if content_id == "":
		# A server running nothing at all. Legitimate — dot-server supports it — and the
		# only case where falling back to the lobby is right rather than a guess, because
		# there is no game to be wrong about.
		content_id = "a_room"

	if not BUILTIN_CLIENTS.has(content_id):
		_fail("This build has no client for '%s'." % content_id)
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
	_clear_game()
	_set_busy(false)
	_menu.visible = true
	_say("Disconnected: %s" % (reason if reason != "" else "no reason given"))
