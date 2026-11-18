class_name TmcShellMenu
extends RefCounted

## The shell's connect menu: the card, its fields and the phone-width fit around it.

## The shell this works for. Its state stays there.
var shell: Node = null


func _init(owner_shell: Node) -> void:
	shell = owner_shell


func _build_menu() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Menu"
	shell.add_child(layer)

	shell._menu = Control.new()
	shell._menu.name = "Shell"
	shell._menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	shell._menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shell._menu.theme = TmcShellStyle.theme()
	layer.add_child(shell._menu)

	shell._menu.add_child(MenuBackdrop.new())

	# CENTRED BY A CONTAINER, not an offset from the middle: an offset is centred at one window size and hangs off a short one.
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shell._menu.add_child(centre)

	# The glass card. Its width is a minimum, not a size: on a phone the window is scaled up
	# around it ([method _fit_menu]) rather than the card squeezed into a column of 8 px text.
	shell._menu_card = PanelContainer.new()
	shell._menu_card.name = "Card"
	shell._menu_card.custom_minimum_size = Vector2(shell.menu_card_width, 0.0)
	centre.add_child(shell._menu_card)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 0)
	shell._menu_card.add_child(stack)

	# The flame along the card's top edge: the brand's gradient, the one place it is used.
	stack.add_child(_flame_strip())

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 18)
	pad.add_theme_constant_override("margin_right", 18)
	pad.add_theme_constant_override("margin_top", 18)
	pad.add_theme_constant_override("margin_bottom", 8)
	stack.add_child(pad)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	_build_identity_fields(box)
	_build_actions(box)
	_build_status_lines(box)
	_build_footer(stack)
	_wire_menu()


func _build_identity_fields(box: VBoxContainer) -> void:
	box.add_child(TmcShellStyle.eyebrow("GameSpice"))

	var title := Label.new()
	title.name = "Title"
	title.text = "Ready to play"
	# Sized here rather than through the palette's heading size: this is the screen's one
	# headline, and raising `heading_size` to fit it would inflate every heading in a game.
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_font_override("font", TmcShellStyle.bold(0.8))
	box.add_child(title)

	shell._blurb = Label.new()
	shell._blurb.theme_type_variation = &"DotDim"
	shell._blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(shell._blurb)

	box.add_child(_gap(8))

	shell._name_caption = _caption("Display name")
	box.add_child(shell._name_caption)

	shell._name = LineEdit.new()
	shell._name.placeholder_text = "Your name"
	shell._name.text = "Guest %d" % (randi() % 900 + 100)
	shell._name.max_length = 32
	shell._name.custom_minimum_size = Vector2(0.0, 44.0)
	box.add_child(shell._name)

	# Its own line rather than the status label: a status is the last thing that happened and the two fought
	# ("Signed in as X" was replaced by "Connecting…" a frame later, which read as signed out).
	shell._identity = Label.new()
	shell._identity.visible = false
	shell._identity.add_theme_color_override("font_color", shell.ACCENT)
	shell._identity.add_theme_font_size_override("font_size", 13)
	box.add_child(shell._identity)

	# The party, when there is one. A standing fact like the line above, so its own line.
	shell._party_line = Label.new()
	shell._party_line.visible = false
	shell._party_line.theme_type_variation = &"DotDim"
	shell._party_line.add_theme_font_size_override("font_size", 13)
	box.add_child(shell._party_line)

	# Friends who are online, and a Join beside the ones that can be followed. Filled by
	# [method _render_friends]; hidden for a guest, who has no friends list to show.
	shell._friends_box = VBoxContainer.new()
	shell._friends_box.visible = false
	shell._friends_box.add_theme_constant_override("separation", 2)
	box.add_child(shell._friends_box)

	box.add_child(_gap(4))

	shell._address_caption = _caption("Server")
	box.add_child(shell._address_caption)

	shell._address = LineEdit.new()
	shell._address.placeholder_text = "host:port"
	shell._address.text = "127.0.0.1:6064"
	shell._address.custom_minimum_size = Vector2(0.0, 44.0)
	box.add_child(shell._address)

	box.add_child(_gap(6))


func _build_actions(box: VBoxContainer) -> void:
	shell._join = Button.new()
	shell._join.name = "Connect"
	shell._join.text = "Connect"
	shell._join.custom_minimum_size = Vector2(0.0, 50.0)
	shell._join.pressed.connect(func() -> void: shell._connect_to(shell._address.text))
	shell._primary(shell._join)
	box.add_child(shell._join)

	# Play the game this shell was opened for, here, with no server. Hidden until there is
	# one: a solo launch names its game, and a shell opened cold has no way to know which
	# games exist. After Leave it is how the player goes again without reloading the page.
	shell._solo_button = Button.new()
	shell._solo_button.text = "Play solo"
	shell._solo_button.custom_minimum_size = Vector2(0.0, 50.0)
	shell._solo_button.visible = false
	TmcShellStyle.ghost(shell._solo_button)
	shell._solo_button.pressed.connect(shell._solo_flow._on_solo_pressed)
	box.add_child(shell._solo_button)

	# The player's say over the maps pack a solo game fetches before it starts. On by
	# default; shown with the solo button, because it only means something to a solo game.
	shell._solo_maps_check = CheckBox.new()
	shell._solo_maps_check.text = "Download this game's maps"
	shell._solo_maps_check.tooltip_text = "Off: solo play starts with only the maps built into the game."
	shell._solo_maps_check.button_pressed = true
	shell._solo_maps_check.visible = false
	shell._solo_maps_check.toggled.connect(func(on: bool) -> void: TmcSolo.set_skip_maps(shell._solo_id, not on))
	box.add_child(shell._solo_maps_check)



func _build_status_lines(box: VBoxContainer) -> void:
	# THE LOADING BAR. Hidden until something is actually loading, because a bar sitting at
	# zero on a menu is a progress indicator for nothing.
	shell._progress = ProgressBar.new()
	shell._progress.show_percentage = false
	shell._progress.custom_minimum_size = Vector2(0.0, 4.0)
	shell._progress.add_theme_stylebox_override("fill", TmcShellStyle.flame_fill())
	shell._progress.add_theme_stylebox_override("background", TmcShellStyle.track())
	shell._progress.visible = false
	box.add_child(shell._progress)

	shell._status = Label.new()
	shell._status.theme_type_variation = &"DotDim"
	shell._status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(shell._status)

	# The second line is the one a waiting player reads: file, bytes, rate and estimate answer "how much longer" and "of what"; empty rather than stale.
	shell._detail = Label.new()
	shell._detail.theme_type_variation = &"DotDim"
	shell._detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	shell._detail.modulate = Color(1.0, 1.0, 1.0, 0.62)
	shell._detail.visible = false
	box.add_child(shell._detail)



func _build_footer(stack: VBoxContainer) -> void:
	# The card's footer, under a hairline: the quiet things a player reaches for when
	# something went wrong, kept apart from the one button that matters.
	var rule := HSeparator.new()
	rule.add_theme_stylebox_override("separator", TmcShellStyle.hairline())
	stack.add_child(rule)

	var foot := MarginContainer.new()
	foot.add_theme_constant_override("margin_left", 10)
	foot.add_theme_constant_override("margin_right", 10)
	foot.add_theme_constant_override("margin_top", 4)
	foot.add_theme_constant_override("margin_bottom", 6)
	stack.add_child(foot)

	var foot_box := VBoxContainer.new()
	foot_box.add_theme_constant_override("separation", 2)
	foot.add_child(foot_box)

	# The way out of a client that holds the wrong thing: a mounted pack cannot be unmounted, so a game or map that will not load is fixed by deleting the downloads.
	# Always here, under the status line, because that is when a player needs it (this shell has no settings screen).
	shell._clear = Button.new()
	shell._clear.name = "ClearContent"
	shell._clear.text = "Clear downloaded content\u2026"
	shell._clear.flat = true
	shell._clear.focus_mode = Control.FOCUS_ALL
	shell._clear.alignment = HORIZONTAL_ALIGNMENT_LEFT
	shell._clear.add_theme_font_size_override("font_size", 13)
	shell._clear.add_theme_color_override("font_color", TmcShellStyle.MUTED)
	shell._clear.add_theme_color_override("font_hover_color", TmcShellStyle.ACCENT_TEXT)
	shell._clear.add_theme_color_override("font_focus_color", TmcShellStyle.ACCENT_TEXT)
	shell._clear.pressed.connect(shell._ask_clear)
	foot_box.add_child(shell._clear)

	# No Host button: a browser tab cannot listen, and offering a control that fails on
	# the platform this shell exists for is worse than not offering it.
	if DotPlatform.is_web():
		var note := Label.new()
		note.text = "A browser tab cannot host. Follow a link to somebody's server."
		note.theme_type_variation = &"DotDim"
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override("font_size", 12)
		note.modulate = Color(1.0, 1.0, 1.0, 0.7)
		var note_pad := MarginContainer.new()
		note_pad.add_theme_constant_override("margin_left", 8)
		note_pad.add_theme_constant_override("margin_right", 8)
		note_pad.add_theme_constant_override("margin_bottom", 4)
		note_pad.add_child(note)
		foot_box.add_child(note_pad)

	_add_corner_labels()


func _add_corner_labels() -> void:
	# The corners, added last so they draw over the backdrop: which client this is
	# (bottom-left) and Powered by TMC (bottom-right), linked to the site this build signs
	# in against. Both live in the menu, so neither is on screen during a game.
	TmcShellVersion.add_corner_label(shell._menu)
	shell._powered_by = TmcPoweredBy.add_to(shell._menu, shell._workshop_site())



func _wire_menu() -> void:
	# Up and down walk the card in order with a keyboard or a gamepad's d-pad, including
	# from a text field, where the engine's own guess skips past the field below.
	_chain_focus([shell._name, shell._address, shell._join, shell._solo_button, shell._solo_maps_check, shell._clear])

	# A phone's window is scaled up around the card while the menu shows (see the method).
	# Guarded so a suite can build the menu on a shell it never adds to the tree.
	shell._menu.visibility_changed.connect(_fit_menu)
	if shell.is_inside_tree():
		shell.get_viewport().size_changed.connect(_fit_menu)
	_fit_menu.call_deferred()

	# Focused after it is in the tree: grab_focus out of the tree is an engine error, and a shell told to join at once has taken the panel down by the time the deferred call runs.
	# A solo launch never shows the form: the site sent the player to play one game, not to type a name and address.
	shell._show_connect_form(str(TmcSolo.requested()["id"]) == "")
	shell._focus_when_shown(shell._join)


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


## The brand's flame as a thin strip, full width, along the top of the menu's card.
func _flame_strip() -> Control:
	var strip := TextureRect.new()
	strip.name = "Flame"
	strip.texture = TmcShellStyle.flame_texture()
	strip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	strip.stretch_mode = TextureRect.STRETCH_SCALE
	strip.custom_minimum_size = Vector2(0.0, 3.0)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return strip


## Links [param controls] top to bottom for ui_up and ui_down, skipping none: a hidden one
## is passed over by the engine's own focus walk, so the chain holds when the solo button
## or the connect form is hidden.
func _chain_focus(controls: Array) -> void:
	var live: Array[Control] = []
	for c: Variant in controls:
		if c is Control:
			live.append(c as Control)
	for i in range(live.size()):
		var here := live[i]
		if i > 0:
			here.focus_neighbor_top = here.get_path_to(live[i - 1])
			here.focus_previous = here.focus_neighbor_top
		if i < live.size() - 1:
			here.focus_neighbor_bottom = here.get_path_to(live[i + 1])
			here.focus_next = here.focus_neighbor_bottom


## While the menu or the loading cover shows, lets the window grow its canvas to the screen's shape and scales the canvas so the card reads at a phone's size ([method TmcShellStyle.fit_factor]). Put back as the project had it the moment both are down: a game starting under the cover sees the change only as a resize. Off with [member menu_fit] (a suite, or a build that wants the letterbox).
func _fit_menu() -> void:
	if shell._menu == null or not shell.is_inside_tree():
		return
	var window := shell.get_window()
	if window == null:
		return
	var card := _fit_card()
	if not shell.menu_fit or card == Vector2.ZERO:
		if not shell._fit_saved.is_empty():
			# Cleared before restoring: setting the aspect emits size_changed, which calls
			# this again re-entrantly (a frame caught the second call reading an empty dict).
			var saved = shell._fit_saved
			shell._fit_saved = {}
			window.content_scale_aspect = saved["aspect"]
			window.content_scale_factor = saved["factor"]
		return
	# Kept on the way in, not once: a game may have changed them while the menu was hidden.
	if shell._fit_saved.is_empty():
		shell._fit_saved = {"aspect": window.content_scale_aspect, "factor": window.content_scale_factor}
	var base := Vector2(window.content_scale_size)
	if base.x <= 0.0 or base.y <= 0.0:
		base = Vector2(
			float(ProjectSettings.get_setting("display/window/size/viewport_width", 1280)),
			float(ProjectSettings.get_setting("display/window/size/viewport_height", 720)))
	var factor := TmcShellStyle.fit_factor(
		Vector2(window.size), DisplayServer.screen_get_scale(window.current_screen),
		base, card, shell.menu_fit_margin, shell.menu_text_scale)
	var scale := factor * float(shell._fit_saved["factor"])
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.content_scale_factor = scale


## What [method _fit_menu] fits around: the menu's card over the cover's words; zero when neither shows.
func _fit_card() -> Vector2:
	if shell._menu.visible and shell._menu_card != null:
		return shell._menu_card.get_combined_minimum_size()
	if shell.loading != null and shell.loading.is_showing():
		return shell.loading.fit_card()
	return Vector2.ZERO
