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
		"ingame":
			# A map the server changed to that would not mount, in a running game.
			shell.get("_menu").visible = false
			shell.call("show_content_failed", "bhop_aztec 0.0.0-1f2f144e0c4c: a downloaded file does not match its manifest.")
		"failed", "clear":
			# A join that failed on the content, which is when the clear button is the
			# answer; "clear" then presses it, to show the question it asks.
			shell.call("_fail", "Could not mount g2gfast 0.0.0-1f2f144e0c4c: a downloaded "
				+ "file does not match its manifest.")
			if stage == "clear":
				shell.call("_ask_clear")
		"friends":
			# The menu a signed-in player sees: a party line, then the friends list. The
			# friends node is a stand-in over an in-process hub; only the drawing is real.
			var party_line: Label = shell.get("_party_line")
			party_line.text = "Party: Tuesday crew (3 members)"
			party_line.visible = true
			var stand_in := TmcFriends.build(DotFriendsLocalHub.new().as_user("me", "Me"))
			shell.add_child(stand_in)   # in the tree, so it is freed with it
			shell.set("_friends", stand_in)
			var list: Array = []
			var rows := [
				["Ann", "in_game", "Playing Arena on TMC Deathmatch #1 (EU, 64 tick, long hostname)", 12, "", true],
				["Bo", "in_game", "Playing Smash Copter", 0, "5123", true],
				["Cy", "online", "", 0, "", false],
				["Dee", "in_game", "Playing Surf on g2gfast", 7, "", false],
				["Eve", "in_game", "Playing Arena", 3, "", true],
				["Fin", "offline", "", 0, "", false],
			]
			for r in rows:
				var p := DotPresence.from_dict({
					"status": r[1], "detail": r[2], "serverId": r[3] if r[3] > 0 else null,
					"partyId": r[4] if r[4] != "" else null, "joinable": r[5],
				})
				list.append(DotFriend.of(str(r[0]).to_lower(), r[0], p))
			shell.call("_render_friends", list)
		"admin", "admin_info":
			# The admin menu over a game: a reason step, and a player's info page. Pages as
			# `host/tmc_admin_menu.gd` builds them, handed straight to the panel.
			shell.get("_menu").visible = false
			var panel: Node = shell.get("admin_menu")
			panel.call("show_page", {"title": "Player commands", "path": "c:players", "rows": [{"label": "Kick", "go": "i:kick"}]})
			if stage == "admin":
				panel.call("show_page", {
					"title": "Ban", "subtitle": "Bob (#12) · 1 day — Reason", "path": "i:ban #12 4",
					"rows": [
						{"label": "Spamming", "go": "i:ban #12 4 1"},
						{"label": "Abusive language", "go": "i:ban #12 4 2"},
						{"label": "Cheating", "go": "i:ban #12 4 3"},
						{"label": "Griefing", "go": "i:ban #12 4 4"},
						{"label": "Ignoring an admin", "go": "i:ban #12 4 5"},
						{"label": "Inappropriate name", "go": "i:ban #12 4 6"},
						{"label": "Mic spam in the spawn area, repeatedly, after a warning", "go": "i:ban #12 4 7"},
						{"label": "Custom…", "input": "i:ban #12 4", "prompt": "Reason"},
					],
				})
			else:
				panel.call("show_page", {
					"title": "Bob", "subtitle": "Player info", "path": "i:info #12",
					"rows": [
						{"label": "User id: #12"}, {"label": "Account: backbone:clx8f2k0kd"},
						{"label": "Username: bob"}, {"label": "Address: 203.0.113.12"},
						{"label": "Connected 41:07 · ping 38 ms"},
						{"label": "On record: 2 warnings, 1 kick; 0 in force"},
						{"label": "— Actions —"},
						{"label": "Kick", "go": "i:kick #12"}, {"label": "Ban", "go": "i:ban #12"},
						{"label": "Warn", "go": "i:warn #12"}, {"label": "Mute (voice and chat)", "go": "i:mute #12"},
						{"label": "Gag (chat only)", "go": "i:gag #12"}, {"label": "Slay", "go": "i:slay #12"},
						{"label": "Freeze", "go": "i:freeze #12"}, {"label": "Bring to me", "go": "i:bring #12"},
					],
				})
		"loading":
			# A game change under a player, with an owner's picture, title and tip. The
			# picture is a game's own screenshot put straight into the screen's cache, so no
			# fetch is involved: what is under test is the drawing.
			shell.get("_menu").visible = false
			shell.set("_has_spawned", true)
			var screen: Node = shell.get("loading")
			var url := "http://127.0.0.1:9/bg.png"
			var picture := Image.load_from_file(ProjectSettings.globalize_path("res://../game-arena/screenshots/dm_atrium_overview.png"))
			if picture != null and not picture.is_empty():
				screen.get("_media")[url] = ImageTexture.create_from_image(picture)
			screen.call("adopt", {"v": 1, "default": {
				"images": [url], "title": "TMC Community",
				"tips": ["Type /admin for the admin menu, if you are an admin."],
			}})
			screen.call("begin", &"game", "arena", "Arena")
			screen.call("set_progress", 0.42, "Downloading Arena…", "23.5 / 63.0 MiB · 3.1 MiB/s")
			for i in 30:
				await process_frame

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
