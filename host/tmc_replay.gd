class_name TmcReplay
extends Node

## The last minute of every server, kept in memory, so that "save that" is possible and a
## kick or a ban can carry a hash of what happened before it.
##
## [b]dot-replay was the second addon in the family that nothing constructed.[/b] It had a
## ring for exactly this, a tap for exactly dot-server's event bus, and `evidence()` shaped
## for exactly a punishment record -- and no server built one, the same "installed,
## documented, wired into nothing" that `_build_logging` and `_build_security` in
## [code]tmc_host.gd[/code] were written to close. This follows them: built for every game
## the host runs, configured from `cfg/replay.yml`, never fatal.
##
## [b]What is recorded is the server's event bus and a roster, not the netcode.[/b] Every
## event dot-server or a game fires -- connects, spawns, chat (blocked lines included),
## commands, kicks, game changes, votes, admin actions -- goes on the `events` channel
## through [DotReplayEventTap], and a keyframe every `replay_keyframe_seconds` holds who is
## connected. That is what a moderator reviewing a report asks: who was there and what did
## they do. A game's snapshots are deliberately NOT recorded here: [DotReplayNetTap] records
## one peer's view, a view is a choice the game has to make, and a server tool that picked
## one for every game would be recording the wrong player in most of them.
##
## [b]The clock is the wall clock, at the configured tick rate.[/b] dot-server drops to
## `sv_hibernate_tickrate` when nobody is connected, so a count of physics ticks would make
## "the last sixty seconds" mean sixty seconds at one rate and several minutes at another,
## and a clip saved just after somebody joined would reach back into an empty hour.
## `tick = elapsed ms * sv_tickrate / 1000` is monotonic, which is all the recorder asks
## ("ticks only move forward"), and it means the same thing whoever is connected.
##
## [b]What it costs a server, per tick[/b]: one `Time.get_ticks_msec()` and the recorder's
## `advance()`, which is three integer comparisons when nothing is due. Once per
## `replay_chunk_seconds` that something was recorded, the pending records are compressed
## into a chunk (zstd over a few hundred bytes) and pushed onto the ring; once per
## `replay_keyframe_seconds`, the session list is walked into a roster. An event costs its
## `describe()`d data and one `var_to_bytes`. Memory is capped by `replay_ring_max_mib`
## (32) and in practice is kilobytes: an idle server holds six roster chunks a minute. The
## only work that is not O(1) is `replay save`, which writes what the ring holds -- on the
## main thread, once, when an admin or a punishment asks.

const CHANNEL := "tmc.replay"

## Under [member directory]. Separate so a manual clip never pushes evidence off the disk.
const MATCHES := "matches"
const CLIPS := "clips"
const EVIDENCE := "evidence"

const EXTENSION := ".dreplay"

## dot-moderation's `DotPunishment.Kind.BAN` and `.KICK`. Numbers rather than the enum,
## because this project does not link dot-moderation for its own scripts -- a game does,
## and the manager is reached through [DotRegistry] like dot-server-security reaches it.
const MOD_KIND_BAN := 0
const MOD_KIND_KICK := 1

## The service a game's dot-moderation registers under.
const MODERATION_SERVICE := &"dot_moderation"

var recorder: DotReplayRecorder = null
var tap: DotReplayEventTap = null

## Null in the suite, which drives this with no server at all.
var server: DotServer = null

## Where `matches/`, `clips/` and `evidence/` go. Absolute.
var directory: String = ""

## Ticks per second of the replay clock. The server's configured rate, not its hibernate one.
var tick_rate: int = 64

var record_matches: bool = false
var clip_on_punish: bool = true
var clip_seconds: float = 0.0
var evidence_cooldown_sec: float = 10.0
var keep_files: int = 50
var keep_bytes: int = 512 << 20

## [code]func() -> int[/code], milliseconds. The suite drives time with it.
var now_ms_fn: Callable = Callable(Time, "get_ticks_msec")

## [code]func() -> String[/code]: the game being recorded, for headers and file names.
var game_fn: Callable = Callable()

## [code]func() -> Array[/code]: who is connected, as plain data. The keyframe.
var roster_fn: Callable = Callable()

var _config: DotReplayConfig = null
var _started_ms: int = 0
var _last_evidence: Dictionary = {}
var _last_evidence_ms: int = -1
var _clips: int = 0
var _evidence_saved: int = 0
var _evidence_attached: int = 0
var _evidence_failed: int = 0
var _pruned: int = 0
var _moderation: Object = null


## Builds the recorder `cfg/replay.yml` asks for and attaches it to [param p_server]. Null
## when it is off, or when the addon refused the configuration -- said, never fatal.
static func install(host: Node, p_server: DotServer, config: TmcConfig, data_dir: String) -> TmcReplay:
	if not config.replay_enabled:
		DotLog.info(CHANNEL, "the replay ring is off in cfg/replay.yml")
		return null

	var node := TmcReplay.new()
	node.name = "Replay"
	node.server = p_server
	var built := node.configure(config, data_dir, p_server.config.tickrate)

	if not built.ok:
		# ERROR rather than fatal: a server with no ring is a server that runs, and one that
		# refused to boot over a chunk size costs the players what they came for.
		DotLog.error(CHANNEL, "the replay ring was not built", {"why": str(built.error)})
		node.free()
		return null

	node.game_fn = func() -> String:
		return p_server.games.current_content_key() if p_server.games != null else ""
	node.roster_fn = node._roster
	host.add_child(node)

	if p_server.events != null:
		DotLog.result(CHANNEL, "the event tap", node.attach_bus(p_server.events), DotLog.Level.WARN)

	node.begin()

	if p_server.games != null:
		p_server.games.game_loaded.connect(node._on_game_loaded)

	if p_server.bans != null:
		p_server.bans.ban_added.connect(node._on_ban_added)

	if p_server.audit != null:
		p_server.audit.action_recorded.connect(node._on_audit)

	# A game's moderation is built when its module loads and replaced on every change, so
	# the registry is watched rather than asked once. Same reason as TmcParty's.
	DotRegistry.signals().service_registered.connect(node._on_service_registered)
	node.watch_moderation(DotRegistry.get_service(MODERATION_SERVICE))

	node._register_commands()

	DotLog.info(CHANNEL, "the replay ring is recording", {
		"ring_seconds": config.replay.ring_seconds,
		"ring_max_mib": config.replay.ring_max_mib,
		"matches_to_disk": node.record_matches,
		"evidence": node.clip_on_punish,
		"directory": node.directory,
	})

	return node


## Everything that does not need a server. The suite calls this directly.
func configure(config: TmcConfig, data_dir: String, p_tick_rate: int) -> DotResult:
	_config = config.replay
	tick_rate = clampi(p_tick_rate, 1, 1000)
	record_matches = config.replay_record
	clip_on_punish = config.replay_clip_on_punish
	clip_seconds = config.replay_clip_seconds
	evidence_cooldown_sec = config.replay_evidence_cooldown_sec
	keep_files = maxi(config.replay_keep_files, 1)
	keep_bytes = maxi(config.replay_keep_mib, 1) << 20

	directory = _config.directory
	if directory == "":
		directory = TmcReplay._absolute(data_dir).path_join("replays")

	if _config.ring_seconds <= 0.0 and not record_matches:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Nothing to record to.",
			"replay_ring_seconds is 0 and replay_record is off; set replay_enabled: false instead"
		)

	recorder = DotReplayRecorder.new()
	var configured := recorder.configure(_config, tick_rate)
	if not configured.ok:
		return configured

	recorder.keyframe_fn = func(_tick: int) -> Variant:
		return {
			"game": _game(),
			"players": roster_fn.call() if roster_fn.is_valid() else [],
			"unix": int(Time.get_unix_time_from_system()),
		}

	_started_ms = int(now_ms_fn.call())
	return DotResult.success(self)


## Records [param bus]'s events on the `events` channel from now on.
func attach_bus(bus: Object) -> DotResult:
	if tap != null:
		tap.detach()
	tap = DotReplayEventTap.new()
	tap.recorder = recorder
	tap.tick_fn = tick_now
	return tap.attach(bus)


## The replay clock. See the class notes for why it is not the physics tick.
func tick_now() -> int:
	return int(float(int(now_ms_fn.call()) - _started_ms) * float(tick_rate) / 1000.0)


## Starts recording the game now running: to the ring, and to a file too when
## `replay_record` is on.
func begin() -> DotResult:
	if recorder.is_recording():
		recorder.stop()

	var header := DotReplayHeader.make(
		_game(), "", tick_rate, roster_fn.call() if roster_fn.is_valid() else [],
		{"server": server.config.hostname if server != null else ""}
	)
	var path := ""

	if record_matches:
		var dir := directory.path_join(MATCHES)
		# Before the new file, so the cap is never exceeded by the file it is about to write.
		_prune(dir, keep_files - 1, keep_bytes, false)
		path = _unique(dir, _game())

	var started := recorder.start(header, path)

	if not started.ok and path != "":
		# The disk refused the file. The ring is the half that matters for moderation, so it
		# is kept rather than going down with the file.
		DotLog.warn(CHANNEL, "could not record this match to a file; the ring carries on", {
			"path": path, "why": str(started.error),
		})
		started = recorder.start(header, "")

	return started


func _physics_process(_delta: float) -> void:
	if recorder != null and recorder.is_recording():
		recorder.advance(tick_now())


func _exit_tree() -> void:
	var bus := DotRegistry.signals()

	if bus.service_registered.is_connected(_on_service_registered):
		bus.service_registered.disconnect(_on_service_registered)

	if tap != null:
		tap.detach()

	# A match file finished rather than left for the reader to recover as truncated. A
	# server shutting down is the one moment there is time to write the index.
	if recorder != null and recorder.is_recording():
		recorder.stop()


func _on_game_loaded(_content_key: String) -> void:
	# A file per game, because a header names one. The ring is not cleared: a clip that
	# spans a change of game is still what happened, and the change is on the events channel.
	begin()


# --- Clips --------------------------------------------------------------------

## Writes the last [param seconds] of the ring (0: all of it) under `clips/`, or under
## `evidence/` when [param evidence] -- the directory decides which cap it counts against,
## and a moderator's manual saves must never push evidence off the disk. Value: the
## file's evidence Dictionary, [method DotReplayWriter.evidence] plus when and why.
func save_clip(seconds: float = 0.0, label: String = "", evidence: bool = false) -> DotResult:
	if recorder == null or recorder.ring == null:
		return DotResult.fail(
			DotError.CODE_STATE, "This server keeps no ring to save from.",
			"replay_ring_seconds is 0 in cfg/replay.yml"
		)

	var dir := directory.path_join(EVIDENCE if evidence else CLIPS)
	_prune(dir, keep_files - 1, keep_bytes, evidence)
	var path := _unique(dir, "%s_%s" % [_game(), label] if label != "" else _game())

	var saved := recorder.save_clip(path, seconds)

	if not saved.ok:
		return saved.wrap("The clip was not saved.")

	var ev := (saved.value as Dictionary).duplicate()
	ev["saved_unix"] = int(Time.get_unix_time_from_system())
	if label != "":
		ev["label"] = label
	_clips += 1
	# After the write, so a clip that is itself over the byte cap is not deleted by the
	# prune that made room for it: the next save's prune takes it.
	return DotResult.success(ev)


## A clip for a punishment, or the one saved for the previous punishment when that was
## less than `replay_evidence_cooldown_sec` ago.
##
## [b]Shared on purpose.[/b] `ban` records the ban and then kicks, a guard removes a wave of
## bots in one tick, and an admin kicks three people who were spamming together: each of
## those is one incident, and ten identical files of the same minute is ten times the disk
## for no more evidence.
func evidence_clip(why: String) -> DotResult:
	var now := int(now_ms_fn.call())

	if not _last_evidence.is_empty() and _last_evidence_ms >= 0 \
			and now - _last_evidence_ms < int(evidence_cooldown_sec * 1000.0):
		return DotResult.success(_last_evidence)

	var saved := save_clip(clip_seconds, _slug(why), true)

	if not saved.ok:
		_evidence_failed += 1
		DotLog.warn(CHANNEL, "a punishment went on record without a clip", {
			"why": why, "error": str(saved.error),
		})
		return saved

	_last_evidence = saved.value as Dictionary
	_last_evidence_ms = now
	_evidence_saved += 1
	return saved


## dot-server's own bans: the record is the Dictionary it just stored, emitted by reference.
##
## [b]Attached after the write, and written again.[/b] `DotBanManager` persists before it
## emits and has no hook before, so the evidence goes on the stored Dictionary and the file
## store is asked to save once more -- the file store writes the whole document, so the
## second write carries it. A custom ban store persisted per ban and would not see it,
## which is why the audit line below is written as well: the audit log is append-only, and
## the final hash is only worth anything somewhere the file's holder cannot rewrite.
func _on_ban_added(ban: Dictionary) -> void:
	if not clip_on_punish:
		return

	var target := str(ban.get("target", ""))
	var got := evidence_clip("ban %s" % target)

	if not got.ok:
		return

	ban["evidence"] = (got.value as Dictionary).duplicate()
	_evidence_attached += 1

	if server != null and server.bans != null:
		server.bans.save_bans()

	_audit(target, got.value as Dictionary)


## A kick is not a record in dot-server -- it is an audit line and a closed socket -- so
## the evidence is a second audit line, naming the same target.
##
## Kicks by an admin only: `kick` and `kickid` audit themselves, and a kick that is a
## refused admission or the second half of a ban does not, which is the distinction wanted.
func _on_audit(entry: Dictionary) -> void:
	if not clip_on_punish or str(entry.get("action", "")) != "kick":
		return

	var target := str(entry.get("target", ""))
	var got := evidence_clip("kick %s" % target)

	if got.ok:
		_evidence_attached += 1
		_audit(target, got.value as Dictionary)


func _audit(target: String, ev: Dictionary) -> void:
	if server == null or server.audit == null:
		return

	server.audit.record("replay_evidence", "replay", target, {
		"replay": str(ev.get("replay", "")),
		"final_hash": str(ev.get("final_hash", "")),
	})


# --- dot-moderation -----------------------------------------------------------

func _on_service_registered(service: StringName, instance: Object) -> void:
	if service == MODERATION_SERVICE:
		watch_moderation(instance)


## Listens to [param manager]'s `punished`. Duck-typed: anything with that signal.
func watch_moderation(manager: Object) -> void:
	if _moderation != null and is_instance_valid(_moderation) \
			and _moderation.is_connected("punished", _on_punished):
		_moderation.disconnect("punished", _on_punished)

	_moderation = null

	if manager == null or not manager.has_signal("punished"):
		return

	_moderation = manager
	manager.connect("punished", _on_punished)


## dot-moderation's bans and kicks, whoever issued them: a game's `sm_ban`, a moderator
## tool, or dot-server-security acting outside dry run.
##
## [b]After the record is stored, and stored again.[/b] `DotModerationManager.issue` takes
## an `evidence` argument and none of its callers here pass one -- dot-server-security's
## `_issue` does not, and nothing can hand it a clip before the punishment exists. So the
## clip is merged into the record's own `evidence` field once it is emitted and the store
## is asked to put it again, which every store answers as an upsert by id. A read-only
## store is a centrally managed list: the record stays as it was, and the audit line
## carries the hash instead.
func _on_punished(punishment: Object) -> void:
	if not clip_on_punish or punishment == null:
		return

	var kind := int(punishment.get("kind"))

	if kind != MOD_KIND_BAN and kind != MOD_KIND_KICK:
		return

	var subject := str(punishment.get("subject"))
	var got := evidence_clip("%s %s" % ["ban" if kind == MOD_KIND_BAN else "kick", subject])

	if not got.ok:
		return

	var evidence: Dictionary = punishment.get("evidence")
	# Merged without overwriting: a moderator tool's own keys stay the moderator's.
	evidence.merge(got.value as Dictionary, false)
	punishment.set("evidence", evidence)
	_evidence_attached += 1
	_audit(subject, got.value as Dictionary)

	var store: Object = _moderation.get("store") if _moderation != null and is_instance_valid(_moderation) else null

	if store != null and store.has_method("is_writable") and bool(store.call("is_writable")):
		var put: Variant = await store.call("put", punishment)
		if put is DotResult and not (put as DotResult).ok:
			DotLog.warn(CHANNEL, "the clip's hash did not reach the punishment store", {
				"subject": subject, "why": str((put as DotResult).error),
			})


# --- Disk ---------------------------------------------------------------------

## Deletes the oldest `.dreplay` files in [param dir] until at most [param max_files] and
## [param max_bytes] remain. Evidence going is said at WARN, because a punishment names it.
func _prune(dir: String, max_files: int, max_bytes: int, evidence: bool) -> void:
	var da := DirAccess.open(dir)

	if da == null:
		return

	var files: Array = []
	var total := 0

	for f in da.get_files():
		if not f.ends_with(EXTENSION):
			continue
		var full := dir.path_join(f)
		var size := 0
		var fa := FileAccess.open(full, FileAccess.READ)
		if fa != null:
			size = int(fa.get_length())
			fa.close()
		files.append({"path": full, "size": size, "mtime": int(FileAccess.get_modified_time(full))})
		total += size

	# Oldest first; the name breaks a tie, and the name begins with a UTC stamp.
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["mtime"]) != int(b["mtime"]):
			return int(a["mtime"]) < int(b["mtime"])
		return str(a["path"]) < str(b["path"]))

	while not files.is_empty() and (files.size() > maxi(max_files, 0) or total > max_bytes):
		var oldest: Dictionary = files.pop_front()
		if DirAccess.remove_absolute(str(oldest["path"])) != OK:
			break
		total -= int(oldest["size"])
		_pruned += 1
		if evidence:
			DotLog.warn(CHANNEL, "an evidence clip was deleted to stay under the disk cap", {
				"path": oldest["path"], "keep_files": keep_files, "keep_mib": keep_bytes >> 20,
			})
		else:
			DotLog.debug(CHANNEL, "pruned", {"path": oldest["path"]})


## `<dir>/<UTC stamp>_<name>.dreplay`, with a counter when two land in one second.
func _unique(dir: String, name: String) -> String:
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "")
	var base := dir.path_join("%s_%s" % [stamp, _slug(name)])
	var path := base + EXTENSION
	var n := 1
	while FileAccess.file_exists(path):
		n += 1
		path = "%s_%d%s" % [base, n, EXTENSION]
	return path


static func _slug(s: String) -> String:
	var out := ""
	for ch in s.strip_edges().left(48):
		out += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch == "-") else "_"
	return out if out != "" else "unnamed"


static func _absolute(path: String) -> String:
	if path.contains("://") or path.begins_with("/"):
		return path
	return ProjectSettings.globalize_path("res://").path_join(path)


func _game() -> String:
	var g := str(game_fn.call()) if game_fn.is_valid() else ""
	return g if g != "" else "none"


## Who is connected, as plain data -- the keyframe, and the header's player list.
func _roster() -> Array:
	var out: Array = []
	if server == null:
		return out
	for s in server.sessions():
		out.append({
			"userid": s.userid,
			"name": s.display_name,
			"uid": s.uid(),
			"state": int(s.state),
		})
	return out


# --- The console ----------------------------------------------------------------

## `replay`, `replay save [seconds] [label]`, `replay list`.
##
## GENERIC, like `log`: saving what just happened is what being staff is for, and what it
## writes is bounded by the same caps as everything else here.
func _register_commands() -> void:
	if server == null or server.console == null:
		return

	server.console.command(
		"replay", _cmd_replay,
		"The replay ring: replay [status], replay save [seconds] [label], replay list",
		DotAdminFlags.GENERIC
	).with_usage("[status|save [seconds] [label]|list]").with_chat()


func _cmd_replay(ctx: DotCmdContext) -> void:
	match ctx.arg(0, "status"):
		"status":
			ctx.reply_lines(describe_lines())
		"save":
			# The seconds are optional, so `replay save griefing` is a label rather than
			# zero seconds and a lost word.
			var timed := ctx.arg(1).is_valid_float()
			var seconds := maxf(ctx.arg_float(1, 0.0), 0.0) if timed else 0.0
			var label := ctx.rest(2 if timed else 1)
			if label == "":
				label = ctx.caller_label()
			var saved := save_clip(seconds, label)
			if not saved.ok:
				ctx.reply_error(saved)
				return
			var ev := saved.value as Dictionary
			ctx.reply("Saved %s (%d chunk(s), ticks %d-%d, %d bytes). Final hash %s" % [
				ev.get("replay", ""), int(ev.get("chunks", 0)), int(ev.get("first_tick", 0)),
				int(ev.get("last_tick", 0)), int(ev.get("bytes", 0)), ev.get("final_hash", ""),
			])
			if server != null and server.audit != null:
				server.audit.record("replay_save", ctx.caller_label(), str(ev.get("replay", "")), {
					"final_hash": str(ev.get("final_hash", "")),
				})
		"list":
			for sub in [EVIDENCE, CLIPS, MATCHES]:
				var da := DirAccess.open(directory.path_join(sub))
				var names := PackedStringArray()
				if da != null:
					for f in da.get_files():
						if f.ends_with(EXTENSION):
							names.append(f)
				names.sort()
				ctx.reply("%s/ (%d): %s" % [sub, names.size(), ", ".join(names.slice(maxi(names.size() - 5, 0)))])
		_:
			ctx.reply("Usage: replay [status|save [seconds] [label]|list]")


func describe() -> Dictionary:
	return {
		"directory": directory,
		"tick_rate": tick_rate,
		"tick": tick_now(),
		"matches_to_disk": record_matches,
		"clips": _clips,
		"evidence_saved": _evidence_saved,
		"evidence_attached": _evidence_attached,
		"evidence_failed": _evidence_failed,
		"pruned": _pruned,
		"watching_moderation": _moderation != null and is_instance_valid(_moderation),
		"recorder": recorder.describe() if recorder != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray([
		"replay: tick %d at %d/s, to %s, %d clip(s), evidence %d saved / %d attached / %d failed, %d pruned, keep %d files / %d MiB%s%s" % [
			tick_now(), tick_rate, directory, _clips, _evidence_saved, _evidence_attached,
			_evidence_failed, _pruned, keep_files, keep_bytes >> 20,
			", every match to a file" if record_matches else "",
			", watching dot-moderation" if _moderation != null and is_instance_valid(_moderation) else "",
		],
	])
	if recorder != null:
		out.append_array(recorder.describe_lines())
	if tap != null:
		out.append_array(tap.describe_lines())
	return out
