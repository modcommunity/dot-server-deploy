@tool
class_name MenuBackdrop
extends Control

## The backdrop behind the shell's menu: GameSpice's dark, warmed by two slow glows in the
## flame's colours, with embers rising through it. All drawn here, a handful of rects a
## frame and no textures beyond three gradients, and only while the menu shows.

## The base colour, below everything (the site's `--bg`).
var space := TmcShellStyle.BG

## The wash up from the bottom edge, fading out upwards: the fire the embers rise from.
var wash_top := Color(TmcShellStyle.FLAME_DEEP, 0.38)

## The glow behind the card, which is what lifts it off the dark.
var glow := Color(TmcShellStyle.ACCENT, 0.22)

## The second glow, gold, drifting slowly around the upper left.
var glow_hot := Color(TmcShellStyle.FLAME_HOT, 0.10)

## How dark the corners go.
var vignette := Color(0.0, 0.0, 0.0, 0.6)

## How many embers rise at once. 0 draws none.
var embers := 46

## How fast an ember rises, in canvas pixels per second, before its own variation.
var ember_speed := 26.0

var _time := 0.0
var _wash: GradientTexture2D = null
var _radial: GradientTexture2D = null


func _ready() -> void:
	# ANCHORS AND OFFSETS, not anchors alone.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The sky is scenery. Every press belongs to whatever is in front of it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wash = _linear()
	_radial = _radial_fade()


func _process(delta: float) -> void:
	# The menu is hidden for the whole of a game, and a sky nobody can see should not be
	# asking for a frame.
	if not is_visible_in_tree():
		return

	_time += delta
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)

	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return

	draw_rect(rect, space)

	# The wash, flipped so it rises from the bottom edge.
	var wash_height := rect.size.y * 0.6
	draw_set_transform(Vector2(0.0, rect.size.y), 0.0, Vector2(1.0, -1.0))
	draw_texture_rect(_wash, Rect2(Vector2.ZERO, Vector2(rect.size.x, wash_height)), false, wash_top)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# The gold glow wanders on a slow ellipse; the accent sits behind the card. Sized from
	# the window, so a phone gets the same picture smaller rather than a crop of it.
	var reach := maxf(rect.size.x, rect.size.y)
	var hot_centre := rect.size * Vector2(0.24 + 0.05 * sin(_time * 0.11), 0.22 + 0.04 * cos(_time * 0.13))
	var hot := Vector2(reach, reach) * 0.75
	draw_texture_rect(_radial, Rect2(hot_centre - hot * 0.5, hot), false, glow_hot)

	var centre := rect.size * 0.5
	var halo := Vector2(rect.size.x * 0.9, rect.size.y * 1.15)
	var breathe := 1.0 + 0.04 * sin(_time * 0.5)
	draw_texture_rect(_radial, Rect2(centre - halo * 0.5 * breathe, halo * breathe), false, glow)

	_draw_embers(rect)

	# Vignette last, over everything: one inverted radial over the whole rect.
	draw_texture_rect(_vignette_texture(), rect, false, vignette)


## Embers: each a small square on its own column, rising and swaying, fading in at the
## bottom and out near the top. Placed by a hash of its index, not stored, so there is no
## list to keep and the field is the same every time the menu opens.
func _draw_embers(rect: Rect2) -> void:
	for i in range(maxi(embers, 0)):
		var seed_a := _hash(i * 3 + 1)
		var seed_b := _hash(i * 3 + 2)
		var seed_c := _hash(i * 3 + 3)
		var speed := ember_speed * (0.55 + seed_b)
		var travel := rect.size.y + 40.0
		var risen := fposmod(_time * speed + seed_c * travel, travel)
		var life := risen / travel
		var x := seed_a * rect.size.x + sin(_time * (0.4 + seed_b) + seed_c * TAU) * 18.0
		var y := rect.size.y + 20.0 - risen
		var fade := minf(life * 6.0, 1.0) * (1.0 - life) * (1.0 - life)
		var colour := TmcShellStyle.FLAME_HOT.lerp(TmcShellStyle.ACCENT, seed_b)
		var side := 1.5 + seed_c * 2.0
		draw_rect(Rect2(x - side * 2.0, y - side * 2.0, side * 4.0, side * 4.0), Color(colour, 0.08 * fade))
		draw_rect(Rect2(x - side * 0.5, y - side * 0.5, side, side), Color(colour, 0.85 * fade))


## A number in [0, 1) from an integer, stable across runs.
static func _hash(n: int) -> float:
	var h := (n * 374761393 + 668265263) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return float(h % 10007) / 10007.0


## Top-down fade, white to transparent. Tinted by the `modulate` passed at draw time, so
## one texture serves any colour.
func _linear() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))

	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 4
	tex.height = 256
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	return tex


## Bright in the middle, transparent at the edge.
func _radial_fade() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	# Pulled in so the falloff is soft rather than a disc with a fuzzy rim.
	gradient.add_point(0.45, Color(1, 1, 1, 0.35))

	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 256
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex


var _vignette: GradientTexture2D = null


## The inverse of [method _radial_fade]: clear in the middle, solid at the corners.
func _vignette_texture() -> GradientTexture2D:
	if _vignette != null:
		return _vignette

	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 0))
	gradient.set_color(1, Color(1, 1, 1, 1))
	gradient.add_point(0.55, Color(1, 1, 1, 0.10))

	_vignette = GradientTexture2D.new()
	_vignette.gradient = gradient
	_vignette.width = 256
	_vignette.height = 256
	_vignette.fill = GradientTexture2D.FILL_RADIAL
	_vignette.fill_from = Vector2(0.5, 0.5)
	_vignette.fill_to = Vector2(1.0, 0.5)
	return _vignette
