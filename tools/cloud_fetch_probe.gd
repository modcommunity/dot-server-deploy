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
	var delivered: Array[DotCloudManifest] = [null]
	client.content_ready.connect(func(m: DotCloudManifest, prefix: String) -> void:
		mount_prefix[0] = prefix
		delivered[0] = m)

	var url := "%s/%s/manifest.json" % [base, id]
	print("[fetch] %s" % url)

	var res: DotResult = await client.acquire(url)

	if not res.ok:
		print("[fetch] ACQUIRE FAILED: %s" % res.error.message)
		quit(1)
		return

	# [b]Ask about the version that was delivered, not a version this probe assumed.[/b]
	# It asked for "1.0.0" whatever it had just downloaded, so every pack on any other
	# version printed `mounted=false` directly underneath the line where the mounter
	# said it had mounted it.
	var got: DotCloudManifest = delivered[0]
	var got_version := got.version if got != null else "?"
	print("[fetch] acquired. mounted=%s (%s@%s)" % [
		client.is_mounted(StringName(id), got_version), id, got_version])

	# The bytes, through the engine's own filesystem rather than through the client that
	# just claimed to have put them there.
	if mount_prefix[0] == "":
		print("[fetch] mounted but no prefix was reported")
		quit(1)
		return

	# [b]Read back a file the manifest actually names.[/b] This probed
	# `<prefix>/<id>.json`, which is a file `surf_mesa` happens to have and nothing else
	# does -- so every other pack reported "mounted but not readable" for content that
	# was mounted and readable. It is worse than a false alarm now that an id can be
	# `<owner>/<name>`: the guessed path picked up the slash and probed
	# `.../tmc/arena.json`, which never existed under any naming scheme.
	if got == null or got.files.is_empty():
		print("[fetch] mounted but the manifest named no files")
		quit(1)
		return

	var want: DotCloudFile = null
	for f in got.wanted_files():
		if f.required:
			want = f
			break

	if want == null:
		print("[fetch] mounted but nothing in the manifest is required on this platform")
		quit(1)
		return

	var probe_path := got.resource_path(want)

	if not FileAccess.file_exists(probe_path):
		print("[fetch] mounted but %s is not readable" % probe_path)
		quit(1)
		return

	# The bytes, not just the entry: a pack whose file table is right and whose contents
	# are empty would pass a file_exists check on its own.
	var bytes := FileAccess.get_file_as_bytes(probe_path)

	if bytes.size() != want.size:
		print("[fetch] %s is %d bytes, the manifest says %d" % [
			probe_path, bytes.size(), want.size])
		quit(1)
		return

	print("[fetch] read %d bytes back out of the mount: %s" % [bytes.size(), probe_path])
	print("[fetch] OK -- fetched over HTTP, signature verified, mounted, read back")
	quit(0)
