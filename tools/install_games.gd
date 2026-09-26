extends SceneTree

## Install the games this server was told to run, from the content origin.
##
## [codeblock]
## godot --headless --path . --script res://tools/install_games.gd -- \
##     --games arena,g2gfast --base https://dotgames.org/content \
##     --content content --data data --config cfg
## [/codeblock]
##
## Driven by `./server install-games`, and by `./server run` when TMC_GAMES is set, which
## is how it runs on a panel that has no shell.
##
## [b]What "installing a game" actually is, and why it is two halves.[/b] A game on the
## origin is a signed dot-cloud pack: scenes, scripts and art, content-addressed, mounted
## at `res://dot_cloud/<id>/<version>/`. What the pack does NOT carry is the descriptor
## that starts it — which scene the server runs, which module drives it, how many players
## it takes, what its cvars are. That is `content/<id>/game.yml`, it lives beside the pack
## in the deploy repository, and every deployment used to get all ten of them by cloning.
## `tools/index.gd` publishes them beside the packs; this fetches the two or three a
## particular box was asked for:
##
## [codeblock]
## GET {base}/games.json                     the catalogue
## GET {base}/descriptors/<id>/game.yml  ->  content/<id>/game.yml
## DotCloudClient.ensure(content_id, ver) ->  data/content_cache/…
## [/codeblock]
##
## [b]The pack is fetched HERE, not on first join.[/b] Without this the download happens
## the first time somebody changes to that game, with players connected and waiting on a
## transfer that can be hundreds of megabytes — and on a panel the operator reads that as
## a hang. Fetching at startup makes the wait happen where a wait is expected, and makes
## a content origin that is down a startup failure with a message rather than a game
## nobody can switch to an hour later.
##
## [b]A descriptor that is already on the disk is never overwritten.[/b] `game.yml` is the
## file an operator edits — cvars, player counts, the map a server starts on — so a
## startup that re-downloaded it would quietly undo their work on every restart, which is
## the worst kind of bug to own: it only shows up on the reboot after the change, when
## nobody is looking at this. `--refresh` is the explicit way to take the origin's copy.
##
## [b]It removes nothing unless asked, and then only what it installed itself.[/b]
## `--prune` drops descriptors for games no longer in the list — but only the ones this
## tool recorded installing, in `data/installed-games.json`. A game an operator authored
## by hand under `content/` is not this tool's to delete, and the day those two cases get
## confused is the day somebody loses a game they wrote.
##
## Exit codes: 0 everything asked for is installed, 2 nothing could be, 3 some could not.

const EXIT_OK := 0
const EXIT_USAGE := 1
const EXIT_FAILED := 2
const EXIT_PARTIAL := 3

const CHANNEL := "tmc.install"

## The catalogue, at the root of a content origin.
const INDEX_FILE := "games.json"

## What this tool installed, so that `--prune` knows what is its to remove.
const STATE_FILE := "installed-games.json"

## Bumped when the state file's shape changes in a way an older tool would misread.
const STATE_VERSION := 1

## Where a verified manifest is kept so that a boot with no network can still find one.
##
## Under the DATA directory rather than under `content/`: it is a cache, it is derived, and
## a content directory is scanned for games -- a `tmc/` directory appearing in there would
## be reported as a half-finished upload at every boot.
const MANIFEST_DIR := "manifests"

## The descriptor, under a content directory and in the published tree alike.
const DESCRIPTOR := "game.yml"

## The pointer a publish writes beside a pack's versions, naming the newest.
const LATEST_FILE := "latest.json"


func _init() -> void:
	DotLog.timestamps = false

	var opts := _options()

	DotLog.set_level(
		DotLog.Level.DEBUG if opts.has("verbose") else DotLog.Level.INFO
	)

	var wanted := _list(str(opts.get("games", "")))

	if wanted.is_empty():
		# Not an error, and this is the ordinary case for a hand-run server: no list
		# means "run what is in the content directory", which needs no installer at all.
		print("  no games list; nothing to install")
		quit(EXIT_OK)
		return

	var content_dir := str(opts.get("content", "content"))
	var data_dir := str(opts.get("data", "data"))
	var config_dir := str(opts.get("config", "cfg"))
	var bases := _list(str(opts.get("base", "")))

	# [b]One statement of where content comes from, and it is the server's own.[/b]
	# Without this the launcher would have to carry a default origin of its own beside the
	# one in `cfg/server.yml`, and the day somebody repoints a deployment at a mirror they
	# would edit the YAML, restart, and watch the installer keep fetching from the address
	# they had just replaced.
	if bases.is_empty():
		bases = _bases_from_config(config_dir)
	var prune := opts.has("prune")
	var refresh := opts.has("refresh")

	# [b]`SceneTree._init` runs before the tree is usable.[/b] `root` exists but nothing
	# has processed a frame, and an HTTPRequest parented in here is never polled — the
	# request is not even attempted, and it surfaces as "could not download", which sends
	# you looking at the origin. One frame is the whole fix; `cloud_fetch_probe.gd` was
	# where this was learned.
	await process_frame

	# [b]Made before anything is written into it.[/b] A box whose games all arrive from an
	# origin has no reason to carry a content directory in advance, and a server handed a
	# `--content` that is not there exits 7 with "No content directory", which reads as a
	# broken install rather than as a directory nobody created yet.
	DirAccess.make_dir_recursive_absolute(content_dir)

	var state := _read_state(data_dir)
	var installed: Dictionary = state["installed"]

	# Every entry taken apart once, through the same reader TmcHost filters with. A
	# `g2gfast` and a `gamemann/game-g2gfast01@1.2.0` differ in where the descriptor comes
	# from and in nothing else afterwards -- both end up as a directory under content/.
	var wants: Array[Dictionary] = []

	for raw in wanted:
		wants.append(TmcGameRef.parse(raw))

	# Built once and shared. A published pack needs it to fetch and VERIFY a manifest
	# before its descriptor is trusted, and the prefetch below needs the same store, the
	# same trusted keys and the same bases -- two clients would download everything twice
	# and disagree about what was already here.
	var cloud := _build_cloud(content_dir, data_dir, config_dir, bases)

	# [b]Started here, because everything below reaches it by a route that does not.[/b]
	# `acquire` and `ensure` start the client themselves; `fetch_manifest` and
	# `verify_manifest` do not, and they are what a published pack's descriptor is read
	# through. Unstarted, the first has no HTTP client at all -- "Nonexistent function
	# 'get_bytes' in base 'Nil'" -- and the second would check a signature against a
	# `config_file` that has never been read, which is the failure dot-cloud's own
	# `ensure` has a paragraph about.
	if cloud != null:
		var started: DotResult = await cloud.start()

		if not started.ok:
			DotLog.error(CHANNEL, "the content client could not start", {
				"why": str(started.error),
			})
			cloud = null

	var missing := PackedStringArray()
	var added := PackedStringArray()
	var index := {}
	# The origin the catalogue came from. Descriptor paths in it are relative and must
	# resolve against THAT origin rather than against whichever base is first in the
	# list -- a mirror that is a version behind would otherwise hand out its own
	# descriptors for the packs a different origin is serving.
	var origin := ""

	# The catalogue is only fetched when something is actually missing. A box whose games
	# are all installed restarts without touching the network, which is what makes a
	# restart during an origin outage safe.
	var need_index := refresh

	for want in wants:
		if want["from_origin"]:
			continue

		if not FileAccess.file_exists(_descriptor_path(content_dir, str(want["dir"]))):
			need_index = true

	if need_index:
		var fetched := await _fetch_index(bases)

		if not fetched.ok:
			# Not fatal by itself: the games already on disk still work, and saying so is
			# the difference between "your origin is unreachable" and a server that looks
			# broken for a reason nobody can see.
			DotLog.error(CHANNEL, "could not read the games index", {
				"bases": bases,
				"why": str(fetched.error),
			})
		else:
			var catalogue := fetched.value as Dictionary
			index = catalogue.get("games", {})
			origin = str(catalogue.get("base", ""))

	for want in wants:
		var id := str(want["dir"])
		var path := _descriptor_path(content_dir, id)
		var have := FileAccess.file_exists(path)

		if have and not refresh:
			continue

		# --- A published pack carries its own descriptor ----------------------
		if want["from_origin"]:
			var got := await _install_from_pack(want, content_dir, bases, cloud)

			if not got.ok:
				DotLog.error(CHANNEL, "could not install a game", {
					"game": str(want["id"]),
					"why": str(got.error),
				})

				if not have:
					missing.append(str(want["raw"]))

				continue

			var what := got.value as Dictionary
			installed[id] = {
				"content_id": str(what["content_id"]),
				"version": str(what["version"]),
				"source": str(want["raw"]),
			}
			added.append(id)
			continue

		var row: Dictionary = index.get(id, {})

		if row.is_empty():
			if not have:
				missing.append(id)
			continue

		if str(row.get("kind", "pack")) == "builtin":
			# A builtin game's code is compiled into a particular build of the shell, so
			# its descriptor on a server running any other build names a scene that is not
			# there. Refused with the reason, rather than left out of the catalogue: an
			# id that is simply absent reads as a publishing mistake.
			DotLog.warn(CHANNEL, "that game is not delivered and cannot be installed", {
				"game": id,
				"hint": "its code ships inside a client build, not as a pack",
			})
			if not have:
				missing.append(id)
			continue

		var written := await _install_descriptor(id, row, content_dir, origin)

		if not written.ok:
			DotLog.error(CHANNEL, "could not install a game", {
				"game": id,
				"why": str(written.error),
			})
			if not have:
				missing.append(id)
			continue

		installed[id] = {
			"content_id": str(row.get("content_id", "")),
			"version": str(row.get("version", "")),
			"source": str(written.value),
		}
		added.append(id)

	# --- What this box should now have -------------------------------------
	var present := PackedStringArray()

	for want in wants:
		var dir_name := str(want["dir"])

		if FileAccess.file_exists(_descriptor_path(content_dir, dir_name)):
			present.append(dir_name)

	if not opts.has("no-prefetch"):
		await _prefetch(present, content_dir, data_dir, bases, index, cloud)

	if prune:
		_prune(present, installed, content_dir)

	state["installed"] = installed
	_write_state(data_dir, state)

	print("")
	print("  games    : %s" % ", ".join(present))

	if not added.is_empty():
		print("  installed: %s" % ", ".join(added))

	if not missing.is_empty():
		print("  MISSING  : %s" % ", ".join(missing))
		print("             not in the index at %s" % ", ".join(bases))

	if present.is_empty():
		quit(EXIT_FAILED)
		return

	quit(EXIT_PARTIAL if not missing.is_empty() else EXIT_OK)


# --- The catalogue ----------------------------------------------------------


## Reads `games.json` from the first origin that answers with one.
##
## [b]Tried in order and the first usable answer wins, which is not the same as the first
## answer.[/b] A mirror that is up and serving an empty or half-written index is a mirror
## that must not stop the real origin being asked — this is the case a LAN deployment
## produces the first time somebody points a base URL at a directory they have not
## finished uploading.
func _fetch_index(bases: PackedStringArray) -> DotResult:
	if bases.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No content origin to install from.",
			"set content_urls in cfg/server.yml, or TMC_CONTENT_URL"
		)

	var http := DotHttp.new()
	http.name = "InstallHttp"
	root.add_child(http)

	var last: DotError = null

	for base in bases:
		var url := "%s/%s" % [base.rstrip("/"), INDEX_FILE]
		DotLog.debug(CHANNEL, "reading the games index", {"url": url})

		var res: DotResult = await http.get_json(url)

		if not res.ok:
			last = res.error
			continue

		var body: Variant = res.value

		if not body is Dictionary or not (body as Dictionary).has("games"):
			last = DotError.make(
				DotError.CODE_INVALID, "%s is not a games index" % url
			)
			continue

		DotLog.info(CHANNEL, "games index read", {
			"url": url,
			"games": ((body as Dictionary)["games"] as Dictionary).size(),
		})

		# Kept, so a descriptor path in the index resolves against the origin it came
		# from rather than against whichever base happens to be first in the list.
		var index := body as Dictionary
		index["base"] = base.rstrip("/")

		http.queue_free()
		return DotResult.success(index)

	http.queue_free()

	return DotResult.failure(
		last if last != null else DotError.make(
			DotError.CODE_IO, "No origin answered."
		)
	)


## Downloads one descriptor and writes it into the content directory.
func _install_descriptor(
	id: String, row: Dictionary, content_dir: String, origin: String
) -> DotResult:
	var relative := str(row.get("descriptor", ""))

	if relative == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "%s has no descriptor in the index" % id
		)

	var url := relative if relative.contains("://") else "%s/%s" % [origin, relative]

	var http := DotHttp.new()
	http.name = "DescriptorHttp"
	root.add_child(http)

	var res: DotResult = await http.get_bytes(url)
	http.queue_free()

	if not res.ok:
		return res.wrap("could not download %s" % url)

	var bytes := res.value as PackedByteArray

	if bytes.is_empty():
		return DotResult.fail(DotError.CODE_IO, "%s is empty" % url)

	var written := _write_descriptor(content_dir, id, bytes)

	if not written.ok:
		return written

	DotLog.info(CHANNEL, "game installed", {"game": id, "from": url})

	return DotResult.success(url)


## Puts one descriptor under `content/<dir>/`, whole or not at all.
##
## [b]Written to a temporary name and moved into place.[/b] A descriptor half-written by a
## connection that dropped is a directory that scans as a game and fails to parse, and the
## server refuses to boot over it -- so the file under `content/` is either the old one or
## the new one and never a piece of either. Shared by both install paths, because the
## failure it prevents has nothing to do with where the bytes came from.
func _write_descriptor(
	content_dir: String, dir_name: String, bytes: PackedByteArray
) -> DotResult:
	var dir := content_dir.path_join(dir_name)
	var made := DirAccess.make_dir_recursive_absolute(dir)

	if made != OK and made != ERR_ALREADY_EXISTS:
		return DotResult.fail(DotError.CODE_IO, "could not create %s" % dir)

	var staging := dir.path_join("%s.part" % DESCRIPTOR)
	var file := FileAccess.open(staging, FileAccess.WRITE)

	if file == null:
		return DotResult.fail(
			DotError.CODE_IO,
			"could not write %s" % staging,
			error_string(FileAccess.get_open_error())
		)

	file.store_buffer(bytes)
	file.close()

	var target := dir.path_join(DESCRIPTOR)
	var renamed := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(staging),
		ProjectSettings.globalize_path(target)
	)

	if renamed != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(staging))
		return DotResult.fail(
			DotError.CODE_IO, "could not put %s in place" % target
		)

	return DotResult.success(target)


# --- The packs --------------------------------------------------------------


## Downloads and verifies every pack the installed games need.
##
## [b]Deduplicated by content id, and that matters more than it looks.[/b] Four of the
## ids here — the four Hungario modes — are four descriptors over ONE pack. Ensuring per
## game rather than per pack would ask the origin for the same 30 MB four times; dot-cloud
## would answer three of them out of the store, but the manifest fetch and the verify
## happen every time and the log then reads as four downloads of a game there is one of.
func _prefetch(
	ids: PackedStringArray,
	content_dir: String,
	data_dir: String,
	bases: PackedStringArray,
	index: Dictionary,
	cloud: DotCloudClient
) -> void:
	var targets := {}

	for id in ids:
		var content_id := ""
		var version := ""
		var row: Dictionary = index.get(id, {})

		if not row.is_empty():
			content_id = str(row.get("content_id", ""))
			version = str(row.get("version", ""))
		else:
			# Already on disk and not in the catalogue we read — a game an operator
			# authored, or an origin that has since dropped it. Its own descriptor is
			# the authority either way, and it is the same file the server will read.
			var parsed := TmcYaml.parse_file(_descriptor_path(content_dir, id))

			if not parsed.ok:
				DotLog.warn(CHANNEL, "could not read a descriptor", {
					"game": id, "why": str(parsed.error),
				})
				continue

			var tree := parsed.value as Dictionary
			content_id = str(TmcYaml.at(tree, "content_id", ""))
			version = str(TmcYaml.at(tree, "version", ""))

			if str(TmcYaml.at(tree, "kind", "builtin")) != "pack":
				continue

		if content_id == "":
			continue

		targets[content_id] = version

	if targets.is_empty() or cloud == null:
		return

	for content_id in targets.keys():
		var version: String = targets[content_id]

		print("  fetching %s@%s" % [content_id, version])

		var res: DotResult = await cloud.ensure(StringName(content_id), version)

		if not res.ok:
			# [b]Not fatal.[/b] A pack that could not be fetched now is fetched on first
			# use, exactly as it was before this tool existed — so an origin that is down
			# costs a slow first join rather than a server that will not start. The
			# operator gets the reason at the top of the log either way.
			DotLog.warn(CHANNEL, "could not prefetch content", {
				"content": content_id,
				"version": version,
				"why": str(res.error),
			})
			continue

		DotLog.info(CHANNEL, "content ready", {
			"content": content_id, "version": version,
		})

		await _cache_manifest(str(content_id), version, data_dir, bases)


## Installs a game from a PUBLISHED pack, descriptor and all.
##
## [b]The descriptor travels inside the pack, and for a pack somebody else published it
## is the only place it can be.[/b] `games.json` and `descriptors/` are this project's
## own index over first-party content; a member who publishes `alice/her-game` through
## the site writes no such thing and should not have to. What they DO ship is their
## repository, and a game's repository has its `game.yml` in it -- so the file that says
## how to start the game is already in the signed pack, addressed by hash like everything
## else in there.
##
## That also makes it as trustworthy as the rest of the pack: the manifest is verified
## against a key this server already trusts before a single object is read, and the
## descriptor is one of the objects the manifest names. A tampered `game.yml` is a
## tampered manifest, which is a signature that does not check.
##
## [b]The directory is the NAME half of the id.[/b] `gamemann/game-g2gfast01` installs
## into `content/game-g2gfast01/`, because the directory name is what an operator types at
## the console and `changelevel gamemann/game-g2gfast01` is not a thing to ask of anybody.
## A directory already holding a DIFFERENT content id is refused rather than overwritten:
## two owners may legitimately publish `arena`, and silently replacing one with the other
## is how a server ends up running content nobody chose.
func _install_from_pack(
	want: Dictionary,
	content_dir: String,
	bases: PackedStringArray,
	cloud: DotCloudClient
) -> DotResult:
	var content_id := str(want["id"])
	var version := str(want["version"])
	var dir_name := str(want["dir"])

	if cloud == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No content origin to install %s from." % content_id,
			"set content_urls in cfg/server.yml, or TMC_CONTENT_URL"
		)

	if version == "":
		var latest := await _resolve_latest(content_id, bases)

		if not latest.ok:
			return latest

		version = str(latest.value)

	# Fetched through the client rather than by hand, so this is the same fetch, the same
	# candidate URLs and the same trusted keys the server itself will use -- an installer
	# that verified content its own way would be a second opinion nobody asked for.
	var urls := cloud.manifest_urls_for(StringName(content_id), version)
	var manifest: DotCloudManifest = null
	var last: DotResult = null

	for url in urls:
		var fetched: DotResult = await cloud.fetch_manifest(url)

		if fetched.ok:
			manifest = fetched.value as DotCloudManifest
			break

		last = fetched

	if manifest == null:
		return (last if last != null else DotResult.fail(
			DotError.CODE_IO, "No origin has %s@%s." % [content_id, version]
		)).wrap("could not read the manifest for %s@%s" % [content_id, version])

	var verified := cloud.verify_manifest(manifest)

	if not verified.ok:
		return verified.wrap("%s@%s is not signed by a key this server trusts" % [
			content_id, version
		])

	var descriptor: DotCloudFile = null

	for file in manifest.files:
		if file.path == DESCRIPTOR:
			descriptor = file
			break

	if descriptor == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"%s@%s carries no %s." % [content_id, version, DESCRIPTOR],
			"that pack is content rather than a game: it can be mounted, "
			+ "but nothing in it says which scene a server should run"
		)

	var existing := _descriptor_path(content_dir, dir_name)

	if FileAccess.file_exists(existing):
		var parsed := TmcYaml.parse_file(existing)

		if parsed.ok:
			var have := str(TmcYaml.at(parsed.value as Dictionary, "content_id", ""))

			if have != "" and have != content_id:
				return DotResult.fail(
					DotError.CODE_STATE,
					"content/%s is already %s." % [dir_name, have],
					"%s wants the same directory; rename one of them" % content_id
				)

	# The object, by hash, under the version this manifest is for. `object_path()` is the
	# engine's own sharding -- two hex characters then the full digest -- so this asks for
	# exactly what the publisher wrote rather than a second spelling of it.
	var prefix := _version_prefix(content_id, version, manifest)
	var http := DotHttp.new()
	http.name = "DescriptorHttp"
	root.add_child(http)

	var got: DotResult = null

	for base in bases:
		var url := "%s/%s/objects/%s" % [
			base.rstrip("/"), prefix, descriptor.object_path()
		]
		got = await http.get_bytes(url)

		if got.ok:
			break

	http.queue_free()

	if got == null or not got.ok:
		return (got if got != null else DotResult.fail(
			DotError.CODE_IO, "nowhere to fetch the descriptor from"
		)).wrap("could not download %s out of %s@%s" % [DESCRIPTOR, content_id, version])

	var bytes := got.value as PackedByteArray

	# [b]The hash is checked HERE and not left to the mounter.[/b] Everything else in a
	# pack is verified when dot-cloud syncs it; this one file is pulled out early, by a
	# different path, and is then WRITTEN TO DISK as configuration the server obeys. A
	# proxy that served a different body would be handing this box a game descriptor of
	# its own choosing, and nothing downstream would look at it again.
	var digest := _sha256_hex(bytes)

	if digest != descriptor.sha256:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"the %s served for %s@%s is not the one the manifest names" % [
				DESCRIPTOR, content_id, version
			],
			"expected %s, got %s" % [descriptor.sha256, digest]
		)

	var stamped := stamp_identity(bytes.get_string_from_utf8(), content_id, version)

	if not stamped.ok:
		return stamped.wrap("%s out of %s@%s" % [DESCRIPTOR, content_id, version])

	var written := _write_descriptor(
		content_dir, dir_name, str(stamped.value).to_utf8_buffer()
	)

	if not written.ok:
		return written

	DotLog.info(CHANNEL, "game installed from a published pack", {
		"game": dir_name, "content": content_id, "version": version,
	})

	return DotResult.success({"content_id": content_id, "version": version})


## A pack's own descriptor, told which pack it is.
##
## [b]The descriptor in a pack cannot know its own address, so this writes it.[/b] A game
## repository commits one `game.yml` and is published by whoever owns it on the site:
## the content id is `<their username>/<repo>`, and a re-sync publishes `1.2.0+r2`. None
## of that is knowable when the file is written, and a descriptor that names a different
## id or version from the pack it came in makes the server mount a path that is not there
## -- every script "not found", from a game that installed without an error. The one
## party that DOES know is this installer, which has just verified that exact id and
## version against a trusted signature. So `content_id`, `version` and `kind` are set to
## what was installed, whatever the file said, and the result is parsed back to prove it.
##
## Text, not a re-serialised tree: TmcYaml reads and does not write, and the file is the
## one an operator edits afterwards -- its comments and order are worth keeping.
static func stamp_identity(text: String, content_id: String, version: String) -> DotResult:
	var want := {"content_id": content_id, "version": version, "kind": "pack"}
	var seen := {}
	var lines := text.split("\n")

	for i in range(lines.size()):
		var line := lines[i]

		for key in want:
			# Top level only: an indented `version:` belongs to some nested block.
			if line.begins_with("%s:" % key):
				lines[i] = "%s: %s" % [key, want[key]]
				seen[key] = true

	var head := PackedStringArray()

	for key in ["content_id", "version", "kind"]:
		if not seen.has(key):
			head.append("%s: %s" % [key, want[key]])

	var out := "\n".join(head) + ("\n" if not head.is_empty() else "") + "\n".join(lines)
	var parsed := TmcYaml.parse(out, DESCRIPTOR)

	if not parsed.ok:
		return parsed

	for key in want:
		if str(TmcYaml.at(parsed.value as Dictionary, key, "")) != want[key]:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"could not set %s in the descriptor" % key,
				"it may be written in a form this reader does not recognise"
			)

	return DotResult.success(out)


## The newest published version of a pack, from the pointer beside its versions.
##
## [b]A static origin cannot answer a question, so the answer is a file.[/b] The versions
## of a pack are directories and an S3 bucket behind a CDN has no way to say which is
## newest -- listing is not public, and should not be. So a publish writes
## `latest.json` next to them, which is one small document, cacheable, and readable by
## exactly the same anonymous GET everything else here uses.
##
## Deliberately NOT a guess at the newest directory name: without listing there is
## nothing to guess from, and with listing there would be a sort over version strings,
## which is how `0.10.0` ends up older than `0.9.0`.
func _resolve_latest(content_id: String, bases: PackedStringArray) -> DotResult:
	var http := DotHttp.new()
	http.name = "LatestHttp"
	root.add_child(http)

	var last := ""

	for base in bases:
		var url := "%s/%s/%s" % [base.rstrip("/"), content_id, LATEST_FILE]
		var res: DotResult = await http.get_json(url)

		if not res.ok:
			last = str(res.error)
			continue

		var body: Variant = res.value

		if body is Dictionary and str((body as Dictionary).get("version", "")) != "":
			var v := str((body as Dictionary)["version"])
			http.queue_free()
			DotLog.debug(CHANNEL, "resolved the newest version", {
				"content": content_id, "version": v, "from": url,
			})
			return DotResult.success(v)

		last = "%s named no version" % url

	http.queue_free()

	return DotResult.fail(
		DotError.CODE_IO,
		"Could not find out which version of %s is newest." % content_id,
		("name one explicitly -- %s@1.0.0 -- or publish %s beside its versions. %s"
			% [content_id, LATEST_FILE, last])
	)


## Where one published version lives, under a base.
##
## The manifest's own `mount_root` is not consulted: that is where content lands inside
## the client, and this is where it sits on the origin. They are the same two segments by
## convention and are not the same decision.
static func _version_prefix(
	content_id: String, version: String, manifest: DotCloudManifest
) -> String:
	var v := version if version != "" else manifest.version
	return "%s/%s" % [content_id, v]


## SHA-256 of a buffer, as lowercase hex.
static func _sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


## Keeps a copy of a pack's manifest where an offline boot can find it.
##
## [b]Without this, prefetching does not survive the thing it exists for.[/b] Every byte
## of a pack can be in the store and the server still cannot start it while the origin is
## unreachable, because dot-cloud resolves the MANIFEST before it looks at what it already
## has -- and a manifest is fetched from the network every single time. Measured, with the
## origin stopped and the pack fully cached: `Could not download the content manifest`,
## exit 7, on a box holding all 212 files. A game server that cannot restart while
## somebody else's web server is down is not deployable.
##
## [DotCloudClient] searches `local_search_dirs` BEFORE any URL, with the same
## `{base}/{id}/manifest.json` shape, so a copy under `data/manifests/` is found by the
## ordinary path with nothing special-cased. It is still verified against the trusted keys
## on every load, exactly as a downloaded one is -- this caches bytes, it does not grant
## them trust.
##
## Versions are namespaced, so a stale copy cannot shadow a new release: a republished
## pack means a new version in `game.yml`, and a version with no local manifest goes to
## the origin as it always did.
func _cache_manifest(
	content_id: String,
	version: String,
	data_dir: String,
	bases: PackedStringArray
) -> void:
	var dir := data_dir.path_join(MANIFEST_DIR).path_join(content_id)
	var target := dir.path_join("manifest.json")

	if FileAccess.file_exists(target):
		return

	var made := DirAccess.make_dir_recursive_absolute(dir)

	if made != OK and made != ERR_ALREADY_EXISTS:
		DotLog.warn(CHANNEL, "could not keep a manifest for offline starts", {
			"dir": dir,
		})
		return

	var http := DotHttp.new()
	http.name = "ManifestHttp"
	root.add_child(http)

	for base in bases:
		var url := "%s/%s/manifest.json" % [base.rstrip("/"), content_id]
		var res: DotResult = await http.get_bytes(url)

		if not res.ok:
			continue

		var file := FileAccess.open(target, FileAccess.WRITE)

		if file == null:
			break

		file.store_buffer(res.value as PackedByteArray)
		file.close()

		DotLog.debug(CHANNEL, "manifest kept for offline starts", {
			"content": content_id, "path": target,
		})
		break

	http.queue_free()


## A cloud client wired exactly as the server's own is.
##
## [b]Exactly, and that is the requirement rather than a nicety.[/b] The whole value of
## prefetching is that the server finds the pack already in its store, and the store is
## `data/content_cache` — so a client here with a cache of its own would download
## everything, verify everything, and leave the server to download it all again. The
## trusted keys are read from the same place for the same reason: a pack fetched against
## a permissive config is a pack the server will reject.
func _build_cloud(
	content_dir: String,
	data_dir: String,
	config_dir: String,
	bases: PackedStringArray
) -> DotCloudClient:
	if bases.is_empty():
		return null

	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = "%s/content_cache" % data_dir
	cloud.config_file = "%s/content.json" % config_dir

	if not FileAccess.file_exists(cloud.config_file):
		cloud.config_file = "res://client/content.json"

	# The content directory as it was given, exactly as `TmcContent.root` holds it and
	# exactly as the server hands it to its own client. A tool that helpfully absolutised
	# it would be searching a different directory from the server it is prefetching for
	# the moment anybody passes a relative `--content`.
	var searched := PackedStringArray([content_dir])
	var published := ProjectSettings.globalize_path("res://dist")

	if DirAccess.dir_exists_absolute(published):
		searched.append(published)

	var manifests := data_dir.path_join(MANIFEST_DIR)

	if DirAccess.dir_exists_absolute(manifests):
		searched.append(manifests)

	cloud.local_search_dirs = searched
	cloud.http_base_urls = bases
	# [b]The published layout is `{id}/{version}/`, and that is dot-cloud's own default.[/b]
	# This used to override it to a flat `{id}/manifest.json`, which was right when the
	# only origin was this project's own `dist/` and every pack had one version in it.
	# The site publishes `content/<owner>/<name>/<version>/manifest.json` -- a member may
	# have four versions of one game up at once -- so the versioned shape is the primary
	# one now.
	#
	# The flat form stays as a FALLBACK because an origin holds both: eight imported map
	# packs were published under it and are still the maps a game asks for by name.
	# Re-publishing everything in existence is not a precondition for this server starting.
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])

	root.add_child(cloud)

	return cloud


# --- Pruning and state ------------------------------------------------------


## Removes descriptors this tool installed and the list no longer asks for.
func _prune(
	keeping: PackedStringArray, installed: Dictionary, content_dir: String
) -> void:
	# [b]Compared against DIRECTORIES, not against the raw list.[/b] `TMC_GAMES` may say
	# `gamemann/game-g2gfast01@1.2.0` and the thing on disk is `content/game-g2gfast01/`,
	# so a prune that matched the raw entry would find no match for a game it had just
	# installed and would delete it on the next restart -- once per restart, for ever.
	for id in installed.keys():
		if id in keeping:
			continue

		var dir := content_dir.path_join(str(id))
		var removed := DotPaths.remove_tree(dir)

		if not removed.ok:
			DotLog.warn(CHANNEL, "could not remove a game", {
				"game": id, "why": str(removed.error),
			})
			continue

		installed.erase(id)
		DotLog.info(CHANNEL, "game removed", {"game": id})

	# [b]The cached PACK is deliberately left alone.[/b] dot-cloud's store is
	# content-addressed and objects are shared between packs, so deleting the objects of
	# one game can take files another game is using with it — the store has its own quota
	# and its own eviction, and this is not the place to second-guess either. Removing a
	# game frees its descriptor, not its download.


func _read_state(data_dir: String) -> Dictionary:
	var path := data_dir.path_join(STATE_FILE)
	var empty := {"format_version": STATE_VERSION, "installed": {}}

	if not FileAccess.file_exists(path):
		return empty

	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)

	if not parsed is Dictionary or not (parsed as Dictionary).has("installed"):
		# Unreadable state is treated as no state: the consequence is that `--prune`
		# forgets what was its to remove and therefore removes nothing, which is the
		# safe direction to fail in.
		DotLog.warn(CHANNEL, "unreadable install state; starting fresh", {"path": path})
		return empty

	return parsed as Dictionary


func _write_state(data_dir: String, state: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(data_dir)

	var path := data_dir.path_join(STATE_FILE)
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		DotLog.warn(CHANNEL, "could not record what was installed", {"path": path})
		return

	# Stamped fresh rather than carried through from the parse. [JSON] has no integers --
	# every number comes back as a float -- so a version read and written straight back
	# turns `1` into `1.0` on the second run and into a file that reads as though
	# something generated it wrong. The constant is an int and writing it again keeps it
	# one.
	state["format_version"] = STATE_VERSION

	file.store_string(JSON.stringify(state, "\t", true) + "\n")
	file.close()


# --- Arguments --------------------------------------------------------------


## `content_urls` out of `cfg/server.yml`, without loading the whole configuration.
##
## [b]The lean read is deliberate.[/b] `TmcConfig.load_dir` ends by VALIDATING a server
## configuration -- ports, RCON, admin groups -- and every one of those checks is a way
## for this tool to refuse to install a game because of something it does not use. It
## reads the same key out of the same file with the same parser, and nothing else.
static func _bases_from_config(config_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var path := config_dir.path_join("server.yml")

	if not FileAccess.file_exists(path):
		return out

	var parsed := TmcYaml.parse_file(path)

	if not parsed.ok:
		DotLog.warn(CHANNEL, "could not read the server configuration", {
			"path": path, "why": str(parsed.error),
		})
		return out

	var urls: Variant = TmcYaml.at(parsed.value as Dictionary, "content_urls", null)

	if urls is Array:
		for entry in (urls as Array):
			var url := String(entry).strip_edges()

			if url != "" and not url in out:
				out.append(url)
	elif urls != null:
		var one := String(urls).strip_edges()

		if one != "":
			out.append(one)

	return out


func _descriptor_path(content_dir: String, id: String) -> String:
	return content_dir.path_join(id).path_join(DESCRIPTOR)


## A comma-separated argument, trimmed, de-duplicated, order kept.
##
## Comma-separated rather than a repeated flag because what is on the other end of it is a
## panel text box and a unit file's `Environment=`, and neither can repeat a flag.
static func _list(raw: String) -> PackedStringArray:
	var out := PackedStringArray()

	for entry in raw.split(",", false):
		var one := entry.strip_edges()

		if one != "" and not one in out:
			out.append(one)

	return out


func _options() -> Dictionary:
	var out := {}
	var args := OS.get_cmdline_user_args()
	var i := 0

	while i < args.size():
		var a: String = args[i]

		if not a.begins_with("--"):
			i += 1
			continue

		var key := a.substr(2)

		if i + 1 < args.size() and not args[i + 1].begins_with("--"):
			out[key] = args[i + 1]
			i += 2
		else:
			out[key] = true
			i += 1

	return out
