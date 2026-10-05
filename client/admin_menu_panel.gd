class_name TmcAdminMenuPanel
extends CanvasLayer

## The admin menu on a player's screen: the page the server sent, numbered, chosen with a
## number key or a click. See `host/tmc_admin_menu.gd` for what is on it and why the
## server builds every page.
##
## [codeblock]
## 1-7  choose a row       8  back, or the previous page       9  next page       0  close
## [/codeblock]
##
## [b]It draws and it sends, and it decides nothing.[/b] A row carries the path the server
## gave it; choosing it hands the path to [member send_fn] — the shell sends it on the
## server's own envelope kind, or as the silent `/admin_menu <path>` chat command to a
## server that does not know the kind — and the server answers with the next page, a close,
## or a reply in chat. What an admin may do is never this panel's question, so a
## modified client that drew rows the server never sent would be sending commands the
## server refuses anyway.
##
## [b]Back is the client's.[/b] The server keeps no menu state per admin, so the panel
## keeps the paths it has been shown and Back re-asks for the previous one. Asking rather
## than re-drawing a cached page is deliberate: a player list from ten seconds ago is a
## list with somebody on it who has left.
##
## [b]The number keys are consumed while it is open[/b], like [DotBallotPanel]'s, so a game
## listening for them by event does not also switch weapon; a game that POLLS [Input] still
## sees them, which no Control can take back. It takes the keys from an open ballot while it
## is up, because an admin who opened a menu meant it.
##
## [b]The mouse is freed while it is open[/b] and given back the way it was found on close,
## so a row can be clicked. A click outside the panel goes to the game, which recaptures
## the mouse, and the number keys keep working.

const CHANNEL := "tmc.admin_menu"

const TOPIC := &"admin_menu"
const NAV_COMMAND := "admin_menu"

## The envelope kind a choice is sent on. `host/tmc_admin_menu.gd` registers the same name,
## and `host/` is not in the client build, so it is written twice; the live suite would
## fail on a mismatch, because the choices would fall back to chat and hit its limiter.
const KIND := &"tmc.admin_menu"

## Above the notices (20) and the loading screen (15): an admin acting mid-change still
## sees what they are doing.
const LAYER := 30

## Numbered rows on one screen; 8, 9 and 0 are the controls.
const PER_PAGE := 7

## Most paths kept for Back.
const MAX_HISTORY := 16

## Longest text an admin may type into a custom row. The server bounds it again.
const MAX_TEXT := 120

## `func(path: String)`: sends a choice to the server. See the class notes.
var send_fn: Callable = Callable()

## Shown when it opens and when it closes, for the shell to hand the number keys back.
signal opened()
signal closed()

var _page: Dictionary = {}
var _rows: Array = []
var _screen := 0
var _history: Array[String] = []
var _path := ""
var _input_path := ""
var _mouse_before: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
var _open := false

var _panel: PanelContainer = null
var _title: Label = null
var _subtitle: Label = null
var _list: VBoxContainer = null
var _footer: Label = null
var _text_box: LineEdit = null
var _input_hint: Label = null


func _ready() -> void:
	layer = LAYER
	_build_view()
	_panel.visible = false


func is_open() -> bool:
	return _open


## Takes a page from the server: the notice's `data["menu"]`. An empty page closes it.
func show_page(page: Dictionary) -> void:
	if page.is_empty():
		close()
		return

	var path := str(page.get("path", ""))
	# A page reached by choosing is pushed; the same path again (a refresh after an error,
	# a fresh player list after a command) replaces rather than stacking. A page already IN
	# the history is a return to it, so everything after it goes: otherwise Back from a
	# root the server sent after a command walks into the confirmation of the ban just
	# carried out, and two quick Backs left a page in the history twice.
	var at := _history.find(path)
	if at >= 0:
		_history.resize(at)
	elif _open and _path != "" and path != _path:
		_history.append(_path)
		if _history.size() > MAX_HISTORY:
			_history.pop_front()

	_page = page
	_path = path
	_screen = 0
	_rows = _clean_rows(page.get("rows", []))
	_cancel_input()

	if not _open:
		_open = true
		_mouse_before = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_panel.visible = true
		opened.emit()

	_render()

	if bool(page.get("input_now", false)):
		for row in _rows:
			if row.has("input"):
				_begin_input(row)
				break


## Takes it down and gives the mouse back. Safe when it is already closed.
func close() -> void:
	_cancel_input()
	if not _open:
		return
	_open = false
	_page = {}
	_rows = []
	_history.clear()
	_path = ""
	_panel.visible = false
	if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = _mouse_before
	closed.emit()


## Presses a number key: 1-7 a row, 8 back, 9 next, 0 close. True when it did something.
## Public so a suite can press keys without an event.
func press(number: int) -> bool:
	if not _open:
		return false

	if number == 0:
		close()
		return true

	if number == 8:
		return back()

	if number == 9:
		if (_screen + 1) * PER_PAGE < _numbered().size():
			_screen += 1
			_render()
			return true
		return false

	if number >= 1 and number <= PER_PAGE:
		var numbered := _numbered()
		var index := _screen * PER_PAGE + number - 1
		if index < numbered.size():
			choose(numbered[index])
			return true

	return false


## Back: the previous screen of this page, the previous page, or closed.
func back() -> bool:
	if not _open:
		return false
	if _screen > 0:
		_screen -= 1
		_render()
		return true
	if _history.is_empty():
		close()
		return true
	var previous: String = _history.pop_back()
	_path = previous
	_send_path(previous)
	return true


## Chooses one of [method rows]'s entries.
func choose(row: Dictionary) -> void:
	if row.has("go"):
		_send_path(str(row["go"]))
	elif row.has("input"):
		_begin_input(row)
	elif bool(row.get("back", false)):
		back()


## The rows of the page on screen, as sent and cleaned. For a suite.
func rows() -> Array:
	return _rows


## The numbered rows on the current screen, as drawn. For a suite and a screenshot.
func screen_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for child in _list.get_children():
		if child is Button:
			out.append((child as Button).text)
		elif child is Label:
			out.append((child as Label).text)
	return out


func title_text() -> String:
	return _title.text


func is_typing() -> bool:
	return _text_box != null and _text_box.visible


## Types into the custom row and sends it, as Enter would. For a suite.
func submit_text(text: String) -> void:
	if not is_typing():
		return
	_text_box.text = text
	_on_submit(text)


# --- Sending ---------------------------------------------------------------------

func _send_path(path: String) -> void:
	if path == "" or not send_fn.is_valid():
		return
	send_fn.call(path)


func _begin_input(row: Dictionary) -> void:
	_input_path = str(row["input"])
	_input_hint.text = "%s — Enter to send, Esc to cancel" % DotNotice.sanitised_string(row.get("prompt", "Type it"))
	_text_box.text = ""
	_text_box.visible = true
	_input_hint.visible = true
	_text_box.grab_focus()


func _cancel_input() -> void:
	_input_path = ""
	if _text_box != null:
		_text_box.visible = false
		_input_hint.visible = false
		if _text_box.has_focus():
			_text_box.release_focus()


func _on_submit(text: String) -> void:
	var clean := clean_text(text)
	var path := _input_path
	_cancel_input()
	if clean == "" or path == "":
		return
	_send_path("%s t:%s" % [path, clean])


## What a typed entry may carry: no quote, no semicolon, nothing below a space, bounded.
## The server cleans it again; this is so what is sent is what was meant.
static func clean_text(text: String) -> String:
	var out := DotChatManager.sanitise(text, MAX_TEXT)
	return out.replace("\"", "'").replace(";", ",").strip_edges()


# --- Input -----------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _open:
		return

	if not (event is InputEventKey) or not event.pressed or event.echo:
		return

	var key := (event as InputEventKey).keycode

	if is_typing():
		if key == KEY_ESCAPE:
			_cancel_input()
			get_viewport().set_input_as_handled()
		return

	# Somebody typing in chat or a console is typing, and "brb 1" is not a menu choice.
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return

	if key == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
		return

	var number := _number_of(key)
	if number >= 0 and press(number):
		get_viewport().set_input_as_handled()


static func _number_of(key: Key) -> int:
	if key >= KEY_0 and key <= KEY_9:
		return key - KEY_0
	if key >= KEY_KP_0 and key <= KEY_KP_9:
		return key - KEY_KP_0
	return -1


# --- Drawing ---------------------------------------------------------------------

func _clean_rows(given: Variant) -> Array:
	var out: Array = []
	if not (given is Array):
		return out
	for raw in given:
		if not (raw is Dictionary):
			continue
		var row := {"label": DotNotice.sanitised_string(raw.get("label", ""), 80)}
		if raw.has("go") and str(raw["go"]) != "":
			row["go"] = str(raw["go"])
		elif raw.has("input") and str(raw["input"]) != "":
			row["input"] = str(raw["input"])
			row["prompt"] = DotNotice.sanitised_string(raw.get("prompt", ""), 64)
		elif bool(raw.get("back", false)):
			row["back"] = true
		out.append(row)
	return out


func _numbered() -> Array:
	return _rows.filter(func(r: Dictionary) -> bool:
		return r.has("go") or r.has("input") or r.has("back"))


func _render() -> void:
	_title.text = DotNotice.sanitised_string(_page.get("title", "Admin menu"), 80)
	var sub := DotNotice.sanitised_string(_page.get("subtitle", ""), 120)
	_subtitle.text = sub
	_subtitle.visible = sub != ""

	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	var numbered := _numbered()
	var first := _screen * PER_PAGE
	var last := mini(first + PER_PAGE, numbered.size())
	var shown := numbered.slice(first, last)

	# Unnumbered rows (an info page's lines, a heading) are drawn where they fall, on the
	# first screen: they are what the page is ABOUT, and repeating them on every screen
	# would push the choices off it.
	var n := 0
	for row in _rows:
		if shown.has(row):
			n += 1
			var button := Button.new()
			button.text = "%d. %s" % [n, row["label"]]
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.focus_mode = Control.FOCUS_NONE
			button.flat = true
			# Clipped with an ellipsis rather than allowed to widen the panel: a long reason
			# made it 494 px on one page and 376 on the next, so it jumped sideways under
			# the admin's eyes on every choice. Seen in a frame, not in any check.
			button.clip_text = true
			button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			button.tooltip_text = row["label"]
			button.pressed.connect(choose.bind(row))
			_list.add_child(button)
		elif not numbered.has(row) and _screen == 0:
			var label := Label.new()
			label.text = row["label"]
			label.modulate = Color(1, 1, 1, 0.7)
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_list.add_child(label)

	var controls := PackedStringArray()
	controls.append("8. Back")
	if last < numbered.size():
		controls.append("9. More")
	controls.append("0. Close")
	if numbered.size() > PER_PAGE:
		controls.append("(%d/%d)" % [_screen + 1, ceili(float(numbered.size()) / PER_PAGE)])
	_footer.text = "   ".join(controls)


func _build_view() -> void:
	var root := Control.new()
	root.name = "AdminMenu"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = DotUiTheme.space().build()
	add_child(root)

	# Left and middle: the right-hand side is where ballots go, and the middle is where the
	# player is aiming. Offsets after anchors, every one, for the reason dot-ui gives.
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.anchor_left = 0.0
	_panel.anchor_right = 0.0
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = 16.0
	_panel.offset_right = 376.0
	_panel.offset_top = -190.0
	_panel.offset_bottom = 190.0
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.09, 0.88)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	_panel.add_theme_stylebox_override("panel", style)
	root.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_title)

	_subtitle = Label.new()
	_subtitle.modulate = Color(1, 1, 1, 0.75)
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_subtitle)

	box.add_child(HSeparator.new())

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 0)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_list)

	_input_hint = Label.new()
	_input_hint.modulate = Color(1, 1, 1, 0.75)
	_input_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_input_hint.visible = false
	box.add_child(_input_hint)

	_text_box = LineEdit.new()
	_text_box.max_length = MAX_TEXT
	_text_box.visible = false
	_text_box.text_submitted.connect(_on_submit)
	box.add_child(_text_box)

	box.add_child(HSeparator.new())

	_footer = Label.new()
	_footer.modulate = Color(1, 1, 1, 0.75)
	box.add_child(_footer)


func describe() -> Dictionary:
	return {
		"open": _open,
		"path": _path,
		"rows": _rows.size(),
		"screen": _screen,
		"history": _history.size(),
		"typing": is_typing(),
	}
