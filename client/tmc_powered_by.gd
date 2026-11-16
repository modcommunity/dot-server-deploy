class_name TmcPoweredBy
extends PanelContainer

## "Powered by TMC", small, in the bottom-right corner of the shell's own screens (the menu
## and the loading screen), as a glass pill like the site's PoweredByTmc. Never over a game:
## it lives inside views that hide when a game starts, so it cannot take a click, the
## pointer lock or a gamepad's focus from play.
##
## A press opens [member url], the TMC site this build signs in against (client/auth.json's
## `backbone_url`), never a host written here. With no URL the pill is only text and ignores
## the mouse.

## Turns the pill off for a build that should not show it.
const SETTING := "tmc/shell/powered_by"

## The site a press opens. http(s) only; anything else leaves the pill unpressable.
var url := "":
	set(value):
		url = value.strip_edges()
		_sync()

## Opens a URL. Injected by a suite; [method OS.shell_open] when unset.
var open_url_fn: Callable = Callable()

var _lead: Label = null
var _mark: Label = null


## A pill anchored in [param parent]'s bottom-right corner, or null when the project turns it
## off. Added last by the caller so it draws over the backdrop.
static func add_to(parent: Control, site: String) -> TmcPoweredBy:
	if not enabled():
		return null
	var pill := TmcPoweredBy.new()
	pill.url = site
	parent.add_child(pill)
	return pill


static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING, true))


## True when [param value] is a web address the pill may open.
static func is_openable(value: String) -> bool:
	return value.begins_with("https://") or value.begins_with("http://")


func _init() -> void:
	name = "PoweredByTmc"
	focus_mode = Control.FOCUS_NONE
	add_theme_stylebox_override("panel", _pill())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	_lead = Label.new()
	_lead.text = "Powered by"
	_lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lead.add_theme_font_size_override("font_size", 11)
	_lead.add_theme_color_override("font_color", Color(TmcShellStyle.MUTED, 0.85))
	row.add_child(_lead)

	_mark = Label.new()
	_mark.text = "TMC"
	_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mark.add_theme_font_size_override("font_size", 11)
	_mark.add_theme_font_override("font", TmcShellStyle.bold())
	_mark.add_theme_color_override("font_color", TmcShellStyle.TMC_TEXT)
	row.add_child(_mark)

	modulate = Color(1.0, 1.0, 1.0, 0.72)
	mouse_entered.connect(_hover.bind(true))
	mouse_exited.connect(_hover.bind(false))
	_sync()


func _ready() -> void:
	# Anchored to the corner rather than placed by a size, so a phone-width window moves it
	# instead of clipping it.
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_right = -12.0
	offset_bottom = -10.0
	offset_left = -12.0
	offset_top = -10.0


func _gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		open()
		return
	var touch := event as InputEventScreenTouch
	if touch != null and touch.pressed:
		accept_event()
		open()


## Opens the site. Returns whether it did, so a suite can tell a press that went nowhere.
func open() -> bool:
	if not is_openable(url):
		return false
	if open_url_fn.is_valid():
		open_url_fn.call(url)
	else:
		OS.shell_open(url)
	return true


func describe() -> Dictionary:
	return {
		"text": "%s %s" % [_lead.text, _mark.text],
		"url": url,
		"pressable": mouse_filter == Control.MOUSE_FILTER_STOP,
	}


func _sync() -> void:
	var live := is_openable(url)
	mouse_filter = Control.MOUSE_FILTER_STOP if live else Control.MOUSE_FILTER_IGNORE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if live else Control.CURSOR_ARROW
	tooltip_text = url if live else ""


func _hover(on: bool) -> void:
	if not is_openable(url):
		return
	modulate.a = 1.0 if on else 0.72


static func _pill() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = TmcShellStyle.GLASS
	box.border_color = TmcShellStyle.GLASS_LINE
	box.set_border_width_all(1)
	box.set_corner_radius_all(999)
	box.anti_aliasing = true
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 3
	box.content_margin_bottom = 4
	return box
