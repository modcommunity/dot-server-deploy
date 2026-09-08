@tool
class_name MenuBackdrop
extends Control

## The sky behind the shell's menu.
##
## [b]Why a drawn backdrop and not a colour.[/b] The shell is the first thing a player sees
## after a forty-megabyte download, and for most of them it is the only screen they will
## judge the whole thing by — a flat grey rectangle with two text fields says "unfinished"
## before a single frame of the game is on screen. This costs one node, no art, and about
## thirty draw calls.
##
## It is the same [DotStarfield] the arena uses, on the same palette, so the menu reads as the
## place the game happens rather than as a launcher bolted onto it. The field drifts on its
## own here: there is no camera to move it, and a sky that is completely still looks like a
## screenshot of a sky.
##
## Everything is generated at runtime — two small gradient textures and a hash. Nothing in
## this project ships art, for the reason dot-ui gives about imposing its own.

## How fast the field drifts, in world units per second. Slow on purpose: fast enough to
## see if you look, slow enough that it never pulls the eye off the button.
const DRIFT := Vector2(9.0, -3.5)

## The base colour, below everything.
var space := Color(0.031, 0.035, 0.062)

## The wash across the top, fading out downwards.
var wash_top := Color(0.13, 0.11, 0.30, 0.60)

## The glow behind the panel, which is what lifts it off the sky.
var glow := Color(0.22, 0.52, 0.95, 0.20)

## How dark the corners go. A vignette is what keeps a field of bright dots from fighting
## the text in front of it.
var vignette := Color(0.0, 0.0, 0.012, 0.55)

var _time := 0.0
var _wash: GradientTexture2D = null
var _radial: GradientTexture2D = null


func _ready() -> void:
	# ANCHORS AND OFFSETS, not anchors alone. `set_anchors_preset` adjusts the offsets to
	# preserve the rect the control currently has — and called from `_ready`, that rect is
	# 0x0, so the anchors say "fill the parent" while the offsets pin it to nothing and
	# `_draw` paints a sky the size of a point. It cost an export to find, because the panel
	# in front of it is laid out by a container and looked perfectly fine.
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

	# Behind the stars: the wash, then the clouds. Order is the whole of the depth here.
	draw_texture_rect(_wash, Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.72)), false, wash_top)

	var anchor := DRIFT * _time

	DotStarfield.draw_nebula(self, rect, anchor, 1.35)
	DotStarfield.draw_into(self, rect, anchor, _time)

	# The glow sits where the panel does — centred, and wider than it is tall so a wide
	# window does not put a circle behind a narrow card.
	var centre := rect.size * 0.5
	var halo := Vector2(minf(rect.size.x * 0.85, 900.0), minf(rect.size.y * 1.1, 620.0))
	draw_texture_rect(_radial, Rect2(centre - halo * 0.5, halo), false, glow)

	# Vignette last, over everything, drawn as four edge gradients would be four textures;
	# one inverted radial over the whole rect is one.
	draw_texture_rect(_vignette_texture(), rect, false, vignette)


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
