class_name TmcAddonEntry
extends RefCounted

## Starts the extra packs a server owner added to a game (`cfg/addons.yml`).
##
## A pack declares what to start in its signed manifest metadata, written by `tools/pack.gd`
## from `pack.json`'s `addon` key: [code]entry[/code], a scene relative to the pack's mount
## root, and [code]side[/code], `server`, `client` or `both` (the default). After the game
## has loaded, the server and each client call [method attach] with the dependency keys
## they mounted, and every pack naming an entry for that side gets it instantiated under
## the node given. A pack with no entry is just mounted.
##
## [b]Lives in client/ because the shell has to carry it.[/b] `host/` is not in the client
## build, and the client half runs there. The host calls the same function, so the two
## sides cannot read the metadata two ways.
##
## [b]Not the manifest's `entry_scene`.[/b] That names a game's client scene or a map pack's
## scene, and every dependency a game lists already has one it expects to load itself.
## Instantiating those here would start a map pack's level inside the game.
##
## [b]A failing entry never stops the game.[/b] The pack is the owner's, the game is what
## the players came for: the failure is an ERROR naming the pack and the loop moves on.

const CHANNEL := "tmc.content"

const SIDES: PackedStringArray = ["server", "client", "both"]


## Instantiates the entry scene of every pack in [param keys] (`owner/pack@version`) that
## runs on [param side] (`server` or `client`) as a child of [param parent]. [param cloud]
## is the [DotCloudClient] that mounted them. Returns how many were attached.
static func attach(parent: Node, cloud: Object, keys: PackedStringArray, side: String) -> int:
	var attached := 0

	if parent == null or cloud == null:
		return 0

	for key in keys:
		var manifest: DotCloudManifest = cloud.call("manifest_for", key)

		if manifest == null:
			continue

		var meta := manifest.metadata
		var entry := str(meta.get("entry", ""))

		if entry == "":
			continue

		var wants := str(meta.get("side", "both"))

		if wants != "both" and wants != side:
			continue

		var node := _instantiate(manifest, entry)

		if node == null:
			continue

		node.name = "Addon_" + str(manifest.content_id).replace("/", "_")
		parent.add_child(node)
		attached += 1
		DotLog.info(CHANNEL, "an extra pack started", {
			"pack": manifest.key(), "side": side, "entry": entry,
		})

	return attached


## The scene at [param entry] under the pack's mount prefix, or null after logging why not.
static func _instantiate(manifest: DotCloudManifest, entry: String) -> Node:
	var safe := DotPaths.safe_relative(entry)

	if not safe.ok:
		DotLog.error(CHANNEL, "an extra pack's entry is not a safe relative path", {
			"pack": manifest.key(), "entry": entry, "why": safe.error.message,
		})
		return null

	# Through the mount prefix and nothing else: the version is in the path, so two
	# versions of a pack never answer to one name.
	var path := manifest.mount_prefix().path_join(entry)

	if not ResourceLoader.exists(path):
		DotLog.error(CHANNEL, "an extra pack's entry scene is not in the pack", {
			"pack": manifest.key(), "entry": entry,
		})
		return null

	var scene: Variant = load(path)

	if not (scene is PackedScene):
		DotLog.error(CHANNEL, "an extra pack's entry did not load as a scene", {
			"pack": manifest.key(), "entry": entry,
		})
		return null

	var node: Node = (scene as PackedScene).instantiate()

	if node == null:
		DotLog.error(CHANNEL, "an extra pack's entry scene would not instantiate", {
			"pack": manifest.key(), "entry": entry,
		})

	return node
