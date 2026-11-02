extends SceneTree

## Can a pack built by `--export-pack` deliver a SCENE that runs? `pack_probe.gd` beside this
## answered the class_name question with a hand-built pack of raw `.gd` files.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var pck := args[0] if args.size() > 0 else ""

	if pck == "" or not FileAccess.file_exists(pck):
		print("[scene] no pack at %s" % pck); quit(1); return

	# What the host thinks these are BEFORE the mount, so a collision is visible as a
	# change rather than inferred. An exported pack carries project.binary and the
	# global class cache, and both sit at paths the host also defines.
	var before_name := str(ProjectSettings.get_setting("application/config/name", "?"))

	if not ProjectSettings.load_resource_pack(pck, false):
		print("[scene] the pack did not mount"); quit(1); return

	var after_name := str(ProjectSettings.get_setting("application/config/name", "?"))
	print("[scene] mounted. project name before=%s after=%s%s" % [
		before_name, after_name,
		"" if before_name == after_name else "   <-- THE PACK OVERWROTE A HOST SETTING"])

	var scene: Variant = load("res://mode/mode.tscn")
	if scene == null:
		print("[scene] the scene did not load"); quit(1); return
	print("[scene] scene loaded")

	var node: Node = (scene as PackedScene).instantiate()
	if node == null:
		print("[scene] the scene did not instantiate"); quit(1); return

	# The exported value from the .tscn, not the script's default. If the script came
	# through but the scene's stored properties did not, this reads 3 rather than 7 --
	# a mode that silently runs on its defaults is worse than one that fails.
	print("[scene] exported property rounds=%d (7 means the scene's value survived)"
		% node.get("rounds"))

	if not node.has_method("probe"):
		print("[scene] the script did not attach to the node"); quit(1); return

	print("[scene] %s" % node.call("probe"))
	node.free()
	quit(0)
