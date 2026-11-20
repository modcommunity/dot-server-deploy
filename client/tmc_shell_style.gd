class_name TmcShellStyle
extends RefCounted

## The shell's look: GameSpice's tokens, in one place, for every view the shell draws (menu, loading screen, notices, admin menu, dialogs). The values are the site's own (website-gs src/app/globals.css and docs/brand.md, hue 14): the shell runs inside the site's game stage, which is dark in both of the site's themes, so the shell is dark only. A [DotUiTheme] configured here, not a fork of it: GameSpice UI builds the Theme, this file only chooses the palette and adds the few styleboxes a palette cannot express (the glass card, the primary button's glow, the focus ring).

## The site's accent (SITE_ACCENT).
const ACCENT := Color(0.949, 0.329, 0.176)
## `--accent-strong`: the accent mixed toward white, for hover.
const ACCENT_STRONG := Color(0.965, 0.455, 0.333)
## `--accent-text` on dark: the accent readable as text.
const ACCENT_TEXT := Color(0.976, 0.553, 0.443)
## The flame's ends (brand.md): gold to crimson through the accent.
const FLAME_HOT := Color(1.0, 0.784, 0.239)
const FLAME_DEEP := Color(0.722, 0.098, 0.235)

## hsl(14 30% 6%), hsl(14 24% 10%), hsl(14 20% 14%), hsl(14 16% 22%).
const BG := Color(0.078, 0.050, 0.042)
const PANEL := Color(0.124, 0.087, 0.076)
const PANEL_2 := Color(0.168, 0.125, 0.112)
const LINE := Color(0.255, 0.201, 0.185)
## hsl(14 20% 96%) and hsl(14 12% 70%).
const INK := Color(0.968, 0.956, 0.952)
const MUTED := Color(0.736, 0.681, 0.664)
## `--glass` and `--glass-strong`, and `--glass-line` (white at 10%).
const GLASS := Color(0.156, 0.101, 0.084, 0.55)
const GLASS_STRONG := Color(0.117, 0.076, 0.063, 0.78)
const GLASS_LINE := Color(1.0, 1.0, 1.0, 0.10)

## TMC's green (`--tmc`, `--tmc-text` on dark): the "TMC" in Powered by TMC.
const TMC := Color(0.133, 0.773, 0.369)
const TMC_TEXT := Color(0.290, 0.871, 0.502)

const DANGER := Color(1.0, 0.420, 0.388)

## The site's radius for buttons and fields (0.75rem) and for cards.
const RADIUS := 12
const CARD_RADIUS := 20


## The palette as a [DotUiTheme], for a view to adjust before building (the ballots make
## the background opaque).
static func palette() -> DotUiTheme:
	var t := DotUiTheme.new()
	t.background = Color(GLASS_STRONG, 0.90)
	t.surface = Color(PANEL_2, 0.92)
	t.surface_hover = Color(PANEL_2.lightened(0.08), 0.96)
	t.surface_pressed = Color(BG, 0.92)
	t.outline = Color(LINE, 0.95)
	t.accent = ACCENT
	t.text = INK
	t.text_dim = MUTED
	t.danger = DANGER
	t.good = TMC_TEXT
	t.highlight = FLAME_HOT
	t.corner = float(RADIUS)
	t.border = 1.0
	t.padding = 13.0
	t.font_size = 15
	t.heading_size = 24
	return t


## The Theme every shell view sets on its root: the palette built, plus the glass card for
## PanelContainer and a visible focus ring for keyboard and gamepad.
static func theme() -> Theme:
	return dress(palette().build())


## Adds the shell's own pieces to a Theme GameSpice UI built. Public so a view that changed the
## palette first ([method palette]) gets the same card and focus ring.
static func dress(t: Theme) -> Theme:
	t.set_stylebox("panel", "PanelContainer", card())
	var ring := focus_ring()
	for type in ["Button", "CheckBox", "CheckButton", "OptionButton", "LinkButton"]:
		t.set_stylebox("focus", type, ring)
	t.set_color("font_hover_color", "CheckBox", INK)
	t.set_color("font_pressed_color", "CheckBox", INK)
	t.set_color("font_focus_color", "Button", INK)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.35))
	t.set_type_variation(&"TmcEyebrow", &"Label")
	t.set_color("font_color", "TmcEyebrow", ACCENT_TEXT)
	t.set_font_size("font_size", "TmcEyebrow", 12)
	t.set_font("font", "TmcEyebrow", bold())
	t.set_font("font", "DotHeading", bold())
	# Dialogs (the clear-content confirmation): the card, opaque, and a title bar to match.
	# The window's border below is the card; the panel inside is flat, so the two do not
	# draw a second outline and shadow inside the first (a frame showed the double edge).
	var inside := StyleBoxFlat.new()
	inside.bg_color = PANEL
	inside.set_content_margin_all(16)
	t.set_stylebox("panel", "AcceptDialog", inside)
	var border := StyleBoxFlat.new()
	border.bg_color = PANEL
	border.border_color = GLASS_LINE
	border.set_border_width_all(1)
	border.set_corner_radius_all(16)
	border.expand_margin_left = 6
	border.expand_margin_right = 6
	border.expand_margin_bottom = 6
	border.expand_margin_top = 34
	border.shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	border.shadow_size = 24
	t.set_stylebox("embedded_border", "Window", border)
	t.set_stylebox("embedded_unfocused_border", "Window", border)
	t.set_color("title_color", "Window", INK)
	t.set_font("title_font", "Window", bold())
	return t


## Dresses a confirmation in the shell's look: the theme, a primary OK, a ghost Cancel, and
## a wrapping message so a phone-width window wraps it instead of growing past the screen.
static func dialog(box: ConfirmationDialog) -> ConfirmationDialog:
	box.theme = theme()
	box.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	primary(box.get_ok_button())
	ghost(box.get_cancel_button())
	return box


## The width a dialog gets: [param preferred], or the window's width less [param margin] on
## each side when that is narrower (a phone held upright). Never under 1.
static func dialog_width(window: Vector2, preferred: float, margin: float) -> int:
	return maxi(1, int(minf(preferred, window.x - margin * 2.0)))


## The glass card: `--glass-strong` with the white hairline and the site's long soft shadow.
static func card(radius: int = CARD_RADIUS, fill: Color = Color(GLASS_STRONG, 0.86)) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(radius)
	box.border_color = GLASS_LINE
	box.set_border_width_all(1)
	box.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	box.shadow_size = 28
	box.shadow_offset = Vector2(0.0, 12.0)
	box.anti_aliasing = true
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 12
	box.content_margin_bottom = 12
	return box


## A small glass plate for a line over a game (a notice, the admin menu): the card without
## the long shadow, which over a 3D world reads as a smudge.
static func plate(alpha: float = 0.82, radius: int = 14) -> StyleBoxFlat:
	var box := card(radius, Color(GLASS_STRONG, alpha))
	box.shadow_size = 10
	box.shadow_offset = Vector2(0.0, 4.0)
	box.shadow_color = Color(0.0, 0.0, 0.0, 0.30)
	return box


## A 2 px accent ring drawn outside the control's own box, for keyboard and gamepad focus.
static func focus_ring(radius: int = RADIUS) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_corner_radius_all(radius + 2)
	box.border_color = Color(ACCENT_TEXT, 0.95)
	box.set_border_width_all(2)
	box.expand_margin_left = 3
	box.expand_margin_right = 3
	box.expand_margin_top = 3
	box.expand_margin_bottom = 3
	box.anti_aliasing = true
	return box


## The engine's font made heavier, for headings and the primary button: the only font the
## web export can count on is the built-in one, and embolden costs no download.
static func bold(weight: float = 0.6) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = weight
	return font


## The site's `.btn-accent`: the accent filled, white bold text, and the glow under it.
## Overridden on the instance so every other button keeps the quiet style.
static func primary(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _fill(ACCENT, true))
	button.add_theme_stylebox_override("hover", _fill(ACCENT_STRONG, true))
	button.add_theme_stylebox_override("pressed", _fill(ACCENT.darkened(0.18), false))
	button.add_theme_stylebox_override("focus", focus_ring())
	button.add_theme_stylebox_override("disabled", _fill(Color(PANEL_2, 0.9), false))
	button.add_theme_color_override("font_color", Color.WHITE)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_focus_color", Color.WHITE)
	button.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 1.0, 0.85))
	button.add_theme_color_override("font_disabled_color", MUTED)
	button.add_theme_font_override("font", bold())
	button.add_theme_font_size_override("font_size", 17)


## The site's `.btn-ghost`: glass, the hairline, the accent on hover.
static func ghost(button: Button) -> void:
	var normal := _fill(GLASS, false)
	normal.border_color = Color(1.0, 1.0, 1.0, 0.14)
	normal.set_border_width_all(1)
	var hover := _fill(Color(GLASS, 0.75), false)
	hover.border_color = ACCENT
	hover.set_border_width_all(1)
	var pressed := _fill(Color(BG, 0.9), false)
	pressed.border_color = ACCENT
	pressed.set_border_width_all(1)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", focus_ring())
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", ACCENT_TEXT)
	button.add_theme_font_override("font", bold(0.35))


## A label in the eyebrow style: small, bold, the accent's text colour, spaced capitals.
static func eyebrow(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.theme_type_variation = &"TmcEyebrow"
	return label


## The flame (gold, the accent, crimson) left to right, for a strip or a bar's fill.
static func flame_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, FLAME_HOT)
	gradient.set_color(1, FLAME_DEEP)
	gradient.add_point(0.5, ACCENT)
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 1
	return tex


## A progress bar's fill in the flame. A texture box, so the gradient spans the filled part.
static func flame_fill() -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = flame_texture()
	return box


## A progress bar's track: the glass line, rounded, no padding.
static func track() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1.0, 1.0, 1.0, 0.08)
	box.set_corner_radius_all(4)
	return box


## A one-pixel rule in the glass line, for an HSeparator.
static func hairline() -> StyleBoxLine:
	var line := StyleBoxLine.new()
	line.color = GLASS_LINE
	line.thickness = 1
	return line


## How much to scale the canvas so a card of [param card] canvas pixels reads at [param text_scale] times the desktop's size on a window of [param window] physical pixels at [param dpr] device pixels per CSS pixel, with the project's canvas [param base] and the canvas grown to the window's shape. Never below 1 (a big desktop window keeps the layout it was drawn for) and never so far that the card and [param margin] stop fitting. Pure, so a suite can ask it about a phone without one.
static func fit_factor(window: Vector2, dpr: float, base: Vector2, card: Vector2, margin: float, text_scale: float) -> float:
	if window.x <= 0.0 or window.y <= 0.0 or base.x <= 0.0 or base.y <= 0.0:
		return 1.0
	var ratio := minf(window.x / base.x, window.y / base.y)
	# The canvas the window shows at factor 1 once grown to its shape, and the scale of one
	# canvas pixel in CSS pixels.
	var shown := window / ratio
	var css := ratio / maxf(dpr, 0.01)
	var want := text_scale / css
	var room := minf(shown.x / (card.x + 2.0 * margin), shown.y / (card.y + 2.0 * margin))
	return maxf(1.0, minf(want, room))


static func _fill(colour: Color, glow: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = colour
	box.set_corner_radius_all(RADIUS)
	box.content_margin_left = 18
	box.content_margin_right = 18
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	box.anti_aliasing = true
	if glow:
		box.shadow_color = Color(ACCENT, 0.32)
		box.shadow_size = 14
		box.shadow_offset = Vector2(0.0, 6.0)
	return box
