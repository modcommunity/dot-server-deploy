extends SceneTree

## Renders the client shell's download progress panel and saves a picture of it.
##
## [b]Because an interface is one of the two things no assertion reaches.[/b] Every
## check in this tree asserts a value; a progress line that formats correctly and lands
## off the bottom of the panel, or under the Connect button, or as white-on-white, is a
## pass in every one of them. So a frame gets rendered and a person looks at it.
##
## Drives the REAL scene with a synthetic payload, rather than building the widgets
## again here: the thing under test is the shell's own layout and formatting, and a
## copy of the widgets would be a test of the copy.
##
##   xvfb-run -a godot --path . --resolution 900x760 \
##       --script tools/progress_shot.gd -- --out screenshots/progress.png
##
## NOT --headless: that is a null renderer and every frame it saves is empty, which is
## worse than no screenshot because it looks like one.

const SHELL := "res://client/shell.tscn"


func _init() -> void:
	var out := "screenshots/progress.png"
	var stage := "downloading"

	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--out" and i + 1 < args.size():
			out = args[i + 1]
		if args[i] == "--stage" and i + 1 < args.size():
			stage = args[i + 1]

	var packed: PackedScene = load(SHELL)
	if packed == null:
		printerr("could not load ", SHELL)
		quit(1)
		return

	var shell: Node = packed.instantiate()
	root.add_child(shell)

	# Two frames before touching it: the shell builds its widgets in _ready, and the
	# first frame is where the theme and the container sizes land.
	await process_frame
	await process_frame

	match stage:
		"downloading":
			shell.call("_on_cloud_phase", 4, "Downloading game content…")
			shell.call("_on_cloud_progress_detail", {
				"fraction": 0.37,
				"done_files": 3,
				"total_files": 12,
				"done_bytes": 24_641_536,
				"total_bytes": 66_060_288,
				"bytes_per_sec": 3_250_000.0,
				"eta_sec": 12.7,
				"active": 2,
				"current_file": "surf_mesa_geometry.bin",
			})
		"mounting":
			shell.call("_on_cloud_phase", 6, "Mounting surf_mesa 1.0.0…")
		"verifying":
			shell.call("_on_cloud_phase", 5, "Checking downloaded content…")

	await process_frame
	await process_frame
	await process_frame

	var image := get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var err := image.save_png(out)
	if err != OK:
		printerr("could not write ", out, ": ", err)
		quit(1)
		return

	print("wrote ", out, " (", image.get_width(), "x", image.get_height(), ")")
	quit(0)
