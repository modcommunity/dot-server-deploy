class_name TmcShellVersion
extends RefCounted

## Which client a player is running, as one small line: `shell 20261016-0230 · c09533b`.
##
## [b]Two numbers, because they are known at different times.[/b] The commit is stamped by
## `./server export-web` and `export-native` into `res://client/build_stamp.gd` (generated,
## git-ignored) just before exporting. The BUILD ID cannot be: it is chosen when the export
## is uploaded, after the files exist, so no file in the export can name it. On the web the
## page that loaded the engine can, because the publisher serves every build from a folder
## named for it (`/game/<app>/<id>/`, `/godot/<id>/`), so it is read back from the page's
## own path. A native build has no such folder and shows the commit only.
##
## [b]Strict patterns, and nothing otherwise.[/b] Both values come from outside this script
## (a URL anybody can link to, a file a script wrote) and end up on screen over a login
## menu. Anything that is not exactly the expected shape is dropped, not trimmed.

const STAMP := "res://client/build_stamp.gd"

## `YYYYMMDD-HHMM`, as deploy-web-shell.sh writes it.
const BUILD_PATTERN := "^[0-9]{8}-[0-9]{4}$"

## A short git hash, optionally marked for uncommitted changes at export time.
const COMMIT_PATTERN := "^[0-9a-f]{7,12}(-dirty)?$"


## The commit this shell was exported from, or "" when the export was not stamped (a run
## from the editor or from source).
static func commit() -> String:
	if not ResourceLoader.exists(STAMP):
		return ""

	var script := load(STAMP) as Script

	if script == null:
		return ""

	return _checked(str(script.get_script_constant_map().get("COMMIT", "")), COMMIT_PATTERN)


## The web build id from the page's path, or "" anywhere else.
static func build_id() -> String:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return ""

	# By singleton name, because the identifier does not exist outside a web export (the same
	# reason dot_cloud_boot.gd does it).
	var path: Variant = Engine.get_singleton("JavaScriptBridge").call("eval", "location.pathname", true)

	return id_from_path(str(path) if path != null else "")


## The build id in a URL path: the one segment that is exactly an id, or "". Public so a
## suite can feed it paths without a browser.
static func id_from_path(path: String) -> String:
	for part in path.split("/"):
		if _checked(part, BUILD_PATTERN) != "":
			return part

	return ""


static func label_text() -> String:
	var parts: Array[String] = []
	var id := build_id()
	var short := commit()

	if id != "":
		parts.append(id)

	if short != "":
		parts.append(short)

	if parts.is_empty():
		return ""

	return "shell " + " · ".join(parts)


## A small, dim label in the bottom-right corner of [param parent]. Added last by the caller
## so it is drawn over the backdrop; ignores the mouse so it never takes a click. Returns
## null when there is nothing to say, so an unstamped run shows no label at all.
static func add_corner_label(parent: Control) -> Label:
	var text := label_text()

	if text == "":
		return null

	var label := Label.new()
	label.name = "ShellVersion"
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.45))
	# Anchored to the corner rather than placed by a size, so a narrow panel moves it
	# instead of clipping it.
	label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.offset_right = -10.0
	label.offset_bottom = -6.0
	parent.add_child(label)

	return label


static func _checked(value: String, pattern: String) -> String:
	var re := RegEx.new()
	re.compile(pattern)

	return value if re.search(value) != null else ""
