extends SceneTree

## Does a client actually FETCH, VERIFY and MOUNT a published pack over HTTP?
##
## Publishing was proven by `dot_cloud_cli publish`; mounting was proven by
## `pack_probe.gd` with a pack already on disk. The half between them -- fetch the
## manifest over the wire, check its signature against the trusted key in
## `client/content.json`, download the objects, build the pack and mount it -- was
## never exercised, and it is the half that carries the cache, the signature check and
## every CORS and quota rule.
##
##     python3 -m http.server 8777 --directory dist &
##     godot --headless --path . --script res://tools/cloud_fetch_probe.gd -- http://127.0.0.1:8777

const CONTENT_CONFIG := "res://client/content.json"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var base := args[0] if args.size() > 0 else "http://127.0.0.1:8777"
	var id := args[1] if args.size() > 1 else "surf_mesa"

	# [b]`SceneTree._init` runs before the tree is usable.[/b] `root` exists but nothing
	# has processed a frame, and an HTTPRequest parented in here never gets polled -- the
	# request is never even attempted, and the failure surfaces as "could not download",
	# which sends you looking at the server. One frame is the whole fix.
	await process_frame

	var client := DotCloudClient.new()
	client.name = "Cloud"
	client.config = DotCloudConfig.new()
	# The REAL shipped config, not a permissive one built here. The whole point is to
	# find out whether the key we published with is the key this client trusts -- a probe
	# that turned signing off would pass while the product failed.
	client.config_file = CONTENT_CONFIG
	# [b]The base points at the CONTENT's own directory, not at the host.[/b] Objects are
	# resolved relative to it, so a base one level up asks for /objects/<hash> when they
	# live at /<id>/objects/<hash> -- the manifest fetches and verifies fine and every
	# object 404s, which reads as "some required content could not be downloaded" and
	# sends you looking at the content rather than at the URL. `--mirror` in the publish
	# docs has the same shape: https://cdn.example.com/dm_arena, id included.
	client.http_base_urls = PackedStringArray(["%s/%s" % [base, id]])
	# A cache of its own, so a pass cannot be a previous run's leftovers.
	client.config.cache_dir = "user://probe_cache_%d" % Time.get_ticks_msec()
	root.add_child(client)

	client.failed.connect(func(e: DotError) -> void:
		print("  [failed] %s" % e.message))

	# The prefix comes from the client, not from a guess. `mount_root` is not a property
	# of the config -- reading one that does not exist threw AFTER a successful mount,
	# which made a working download look like a broken one.
	# An ARRAY, not a String. GDScript lambdas capture locals BY VALUE, so assigning to a
	# captured `var mount_prefix := ""` writes to the lambda's own copy and the outer one
	# stays empty -- which reads as "the signal never fired" for a mount that worked. This
	# tree's own hazards list calls it out; capturing a reference type is the fix.
	var mount_prefix: Array[String] = [""]
	client.content_ready.connect(func(_m: DotCloudManifest, prefix: String) -> void:
		mount_prefix[0] = prefix)

	var url := "%s/%s/manifest.json" % [base, id]
	print("[fetch] %s" % url)

	var res: DotResult = await client.acquire(url)

	if not res.ok:
		print("[fetch] ACQUIRE FAILED: %s" % res.error.message)
		quit(1)
		return

	print("[fetch] acquired. mounted=%s" % client.is_mounted(StringName(id), "1.0.0"))

	# The bytes, through the engine's own filesystem rather than through the client that
	# just claimed to have put them there.
	if mount_prefix[0] == "":
		print("[fetch] mounted but no prefix was reported")
		quit(1)
		return

	var probe_path := "%s/%s.json" % [mount_prefix[0], id]

	if not FileAccess.file_exists(probe_path):
		print("[fetch] mounted but %s is not readable" % probe_path)
		quit(1)
		return

	var text := FileAccess.get_file_as_string(probe_path)
	var parsed: Variant = JSON.parse_string(text)

	if typeof(parsed) != TYPE_DICTIONARY:
		print("[fetch] the mounted manifest did not parse")
		quit(1)
		return

	var doc: Dictionary = parsed
	print("[fetch] read the map out of the mount: id=%s surfaces=%d" % [
		doc.get("id", "?"), (doc.get("surfaces", []) as Array).size()])
	print("[fetch] OK -- fetched over HTTP, signature verified, mounted, read back")
	quit(0)
