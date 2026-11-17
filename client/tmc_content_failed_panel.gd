class_name TmcContentFailedPanel
extends RefCounted
## The "Content problem" card the shell shows over a running game: what failed, "Clear downloaded content…" and Dismiss.
## Built once under [param parent]; the shell owns showing, hiding and the mouse.


## Returns {"panel": PanelContainer, "text": Label, "clear": Button}. [param on_dismiss] and [param on_clear] are what the two buttons do.
static func build(parent: Node, on_dismiss: Callable, on_clear: Callable) -> Dictionary:
	var layer := CanvasLayer.new()
	layer.name = "ContentFailed"
	layer.layer = 90
	parent.add_child(layer)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_TOP_WIDE)
	centre.offset_top = 24.0
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(centre)
	var panel := PanelContainer.new()
	panel.theme = TmcShellStyle.theme()
	panel.add_theme_stylebox_override("panel", TmcShellStyle.card(16, Color(TmcShellStyle.PANEL, 0.96)))
	panel.custom_minimum_size = Vector2(420.0, 0.0)
	centre.add_child(panel)
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)
	var heading := TmcShellStyle.eyebrow("Content problem")
	heading.add_theme_color_override("font_color", TmcShellStyle.DANGER)
	box.add_child(heading)
	var text := Label.new()
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size = Vector2(392.0, 0.0)
	box.add_child(text)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var dismiss := Button.new()
	dismiss.text = "Dismiss"
	dismiss.pressed.connect(on_dismiss)
	TmcShellStyle.ghost(dismiss)
	row.add_child(dismiss)
	var clear := Button.new()
	clear.name = "Clear"
	clear.text = "Clear downloaded content…"
	clear.pressed.connect(on_clear)
	row.add_child(clear)
	return {"panel": panel, "text": text, "clear": clear}
