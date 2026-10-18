extends Node3D

## The smallest game that takes subscriptions, for workshop_solo.gd: a client scene whose map
## catalogue follows the content index the way a real game's does (`accepts.map_kinds`).
##
## It lives in the build and not in the fixture pack on purpose: a script inside a pack is
## loaded by mount path, and what is under test is the shell's order of events, not mounting.

const ACCEPTED := ["sandbox"]

var catalogue: DotMapCatalogue = null


func _ready() -> void:
	add_to_group(&"ws_test_game")
	catalogue = DotMapCatalogue.new()
	catalogue.follow_content(DotContentIndex.shared(), PackedStringArray(ACCEPTED))
	if "--shots" in OS.get_cmdline_user_args():
		_draw_list()


## Only for the pictures: what the catalogue lists, on screen, since a bare scene shows nothing.
func _draw_list() -> void:
	var layer := CanvasLayer.new()
	var label := Label.new()
	var names := PackedStringArray()
	for map in catalogue.available():
		names.append("%s  (from %s)" % [map.display_name, map.pack_title])
	label.text = "Workshop Game, %s session\nMaps: %s" % [
		DotContentIndex.shared().session(), ", ".join(names) if not names.is_empty() else "none"]
	label.position = Vector2(24, 24)
	label.add_theme_font_size_override("font_size", 22)
	layer.add_child(label)
	add_child(layer)
