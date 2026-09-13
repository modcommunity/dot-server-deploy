extends SceneTree

# [b]Loaded out of the MOUNT, not preloaded, because the game is not in this build.[/b]
# game-g2gfast is a delivered pack: its scripts exist at
# `res://dot_cloud/g2gfast/<version>/game/…`, a path no constant here can name, because
# the version belongs to the game and this file belongs to the host. So the probe mounts
# the pack first -- which it was going to do anyway, since mounting is half of what it
# proves -- and loads them from where they landed.

## Does a client with NO maps get one from the content origin?
##
## `cloud_fetch_probe.gd` proved fetch-verify-mount for a pack. This proves the half that
## makes it matter for a timer server: `G2GGame.ensure_map_content` turning a map id the
## catalogue has never heard of into a map the catalogue can load, without the 66 MB of
## geometry the web export used to carry.
##
## [b]Run it with ONE map moved aside.[/b] A source tree has every map on disk and the
## catalogue finds them in `IMPORTED_ROOTS`, so a probe run against an intact tree passes
## by doing nothing at all -- which is the failure mode this whole check exists to avoid.
##
## One rather than all of them, and the smallest one: moving `maps/imported` wholesale
## takes ninety-eight textures out of the project, and Godot then reimports the tree on
## the way in and again on the way out. That is six minutes per run before a line of this
## file executes, which is long enough to read as a hang.
##
##     mv maps/imported/surf_kitsune /tmp/aside
##     godot --headless --path . --script res://tools/map_content_probe.gd -- surf_kitsune
##     mv /tmp/aside maps/imported/surf_kitsune
##
## Every step prints before it runs, not after. An await that never returns is the
## expected failure here -- it is what a content client with nowhere to fetch from does --
## and a probe that only prints results says nothing at all about where it stopped.

const CONTENT_CONFIG := "res://client/content.json"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var id := StringName(args[0] if args.size() > 0 else "surf_mesa")

	# The tree is not usable in _init; an HTTPRequest parented here is never polled.
	await process_frame

	print("-- building the content client")
	var failures := 0

	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config_file = CONTENT_CONFIG
	cloud.config.cache_dir = "user://map_probe_%d" % Time.get_ticks_msec()
	# The published tree on disk, which is what a CDN is serving a copy of. Using the
	# local source rather than HTTP keeps this probe about the map wiring; the network
	# half is cloud_fetch_probe.gd's job and is already proven.
	cloud.local_search_dirs = PackedStringArray([
		ProjectSettings.globalize_path("res://dist")
	])
	cloud.manifest_url_template = "{base}/{id}/manifest.json"
	# `register_service` is the default and is what `G2GGame.ensure_map_content` finds it
	# by -- `DotCloudClient.SERVICE`, which is what every other duck-typed consumer in the
	# family looks under. There is no `service_name` to set; a scope is the only thing
	# that changes the registered name.
	root.add_child(cloud)

	print("-- mounting g2gfast")

	# The version is read from the descriptor rather than written here: a probe carrying
	# its own copy of a version number is a probe that keeps passing against last week's
	# pack after somebody bumps it.
	var descriptor := TmcYaml.parse_file("res://content/g2gfast/game.yml")
	if not descriptor.ok:
		print("  [FAIL] could not read content/g2gfast/game.yml: ", str(descriptor.error))
		quit(1)
		return

	var version := String(TmcYaml.at(descriptor.value as Dictionary, "version", ""))

	var mounted: Variant = await cloud.ensure(&"g2gfast", version)
	if not (mounted is DotResult) or not (mounted as DotResult).ok:
		print("  [FAIL] could not mount g2gfast: ", str((mounted as DotResult).error))
		quit(1)
		return

	var prefix := DotCloudClient.mount_prefix_for(&"g2gfast", version)
	print("mounted at %s" % prefix)

	var G2GGame: GDScript = load(prefix.path_join("game/g2g_game.gd"))
	var G2GConfig: GDScript = load(prefix.path_join("game/g2g_config.gd"))

	if G2GGame == null or G2GConfig == null:
		print("  [FAIL] the pack mounted but its scripts did not load")
		quit(1)
		return

	print("-- building the game")

	# Typed Node rather than inferred: `G2GGame` is a GDScript loaded at runtime, so
	# `new()` is a Variant and inference on one is an error under this project's warning
	# settings. A G2GGame IS a Node, which is all this probe touches it as.
	var game: Node = G2GGame.new()
	game.name = "Game"
	game.config = G2GConfig.new()
	game.config.authoritative = false
	game.config.initial_map = &""
	root.add_child(game)

	await process_frame
	await process_frame

	print("-- reading the catalogue")

	if game.maps == null or game.maps.catalogue == null:
		print("  [FAIL] the game has no map session")
		quit(1)
		return

	var before: bool = game.maps.catalogue.has(id)
	print("catalogue has %s before: %s" % [id, before])

	if before:
		print("  [skipped] this tree still has the map on disk -- move maps/imported aside")
		quit(2)
		return

	# [b]Which client the game will actually find.[/b] `DotRegistry.register` replaces,
	# and `DotCloudClient.register_service` defaults to on -- so anything else in the tree
	# that builds one takes the name, and the configured client this probe made is still
	# in the tree, still started, and reachable by nobody. The symptom is a signature
	# failure, because the usurper has no `config_file` and therefore no trusted key.
	var found: Object = DotRegistry.get_service(&"dot_cloud_client")
	print("-- registered content client: %s (probe built %d)" % [
		"none" if found == null else str(found.get_instance_id()), cloud.get_instance_id()
	])

	print("-- ensure_map_content(%s)" % id)

	var got: DotResult = await game.ensure_map_content(id)

	if not got.ok:
		# Code and detail, not just the message. `wrap` keeps the cause in `detail`, and
		# the message alone is the outer sentence -- "could not fetch the map X" -- which
		# is the part that was already obvious from the line above it.
		print("  [FAIL] [%s] %s" % [got.error.code, got.error.message])
		print("         %s" % got.error.detail)
		quit(1)
		return

	if not game.maps.catalogue.has(id):
		print("  [FAIL] ensure_map_content succeeded and the catalogue still has no %s" % id)
		quit(1)
		return

	print("  ok   the catalogue has %s" % id)

	var def: DotMapDef = game.maps.catalogue.get_map(id)
	var manifest := str(def.meta.get("manifest", ""))

	if not FileAccess.file_exists(manifest):
		print("  [FAIL] its manifest is not readable: %s" % manifest)
		failures += 1
	else:
		print("  ok   its manifest reads: %s" % manifest)

	var mesh := "%s/%s.bin" % [manifest.get_base_dir(), id]

	if not FileAccess.file_exists(mesh):
		print("  [FAIL] its mesh is not readable: %s" % mesh)
		failures += 1
	else:
		print("  ok   its mesh reads: %s" % mesh)

	print("-- change_map(%s)" % id)

	# The change a joining client actually makes.
	var changed: DotResult = await game.change_map(id)

	if not changed.ok:
		print("  [FAIL] change_map: %s" % changed.error.message)
		failures += 1
	elif game.maps.current == null or game.maps.current.id != id:
		print("  [FAIL] change_map reported ok and the session is on something else")
		failures += 1
	else:
		print("  ok   the world changed to %s" % id)

	print("%s" % ("all checks passed" if failures == 0 else "%d failed" % failures))
	quit(0 if failures == 0 else 1)
