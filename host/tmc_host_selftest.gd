class_name TmcHostSelftest
extends RefCounted

## What `./server --check` asserts after a real boot: the operator's console and the scripts the boot touched.
## Held apart from [code]tmc_host.gd[/code] so the boot path stays readable; it reads the host's state through [member host] and changes none of it.

var host: Node


func _init(p_host: Node) -> void:
	host = p_host


## Whether every script this boot touched compiled and loaded.
## A script that fails to parse is logged and handed back uninstantiable, and every later step can still succeed, so "selftest ok" printed over a module that never compiled; the engine's log is the only record, so it is read.
func scripts_loaded() -> bool:
	var watch: TmcScriptWatch = host._script_watch

	if watch == null or watch.count() == 0:
		return true

	printerr("")
	printerr("selftest FAILED: %d script error(s) while booting; the first:" % watch.count())

	for line in watch.lines():
		printerr("  %s" % line)

	printerr("  A missing base class is usually an addon setup.sh did not link or vendor.")
	return false


## The operator's console, asserted on a REAL server rather than on a fixture.
## These addons were installed and reached no console at all (dot-log's commands could not plug into a server console, the guard was instantiated nowhere), and an absent command reports nothing.
## Checked here and not in `examples/selftest.tscn` because a fixture has no console.
func operator_surface() -> bool:
	return _commands_present() and _web_cvars_present() and _addons_advertised() \
		and _web_loader_present() and _party_status_answers() and _replay_recording()


func _commands_present() -> bool:
	var server: DotServer = host.server
	var config: TmcConfig = host.config
	var expected := PackedStringArray(["status", "sec_status", "sec_why", "party_status", "mm_status"])

	if host.log_router != null:
		expected.append("log")

	if config.replay_enabled:
		expected.append("replay")

	var missing := PackedStringArray()

	for name in expected:
		if server.console.find_command(name) == null:
			missing.append(name)

	if not missing.is_empty():
		printerr("selftest FAILED: the console is missing %s" % " ".join(Array(missing)))
		return false

	if host.log_router != null and not host.log_router.is_started():
		printerr("selftest FAILED: the log router was built and never started")
		return false

	return true


## `sv_web_build`, `sv_web_requires` and `sv_pack_pins`: NOTIFY cvars the query reports.
func _web_cvars_present() -> bool:
	var server: DotServer = host.server
	var config: TmcConfig = host.config
	# Registered ALWAYS, empty unless the operator pinned a shell, so rcon can set it and the query reports it (a cvar without NOTIFY is not in the rules).
	var pinned := server.console.find_cvar("sv_web_build")

	if pinned == null or not pinned.has_flag(DotConVar.FLAG_NOTIFY) \
			or pinned.get_string() != host._release_label(config.web_build):
		printerr("selftest FAILED: sv_web_build is not a NOTIFY cvar reporting the configured pin (%s)" % config.web_build)
		return false

	print("sv_web_build: %s" % (pinned.get_string() if pinned.get_string() != "" else "(latest shell)"))

	var requires := server.console.find_cvar("sv_web_requires")

	if requires == null or not requires.has_flag(DotConVar.FLAG_NOTIFY):
		printerr("selftest FAILED: sv_web_requires is not a NOTIFY cvar the query reports")
		return false

	var pack_pins := server.console.find_cvar("sv_pack_pins")

	if pack_pins == null or not pack_pins.has_flag(DotConVar.FLAG_NOTIFY):
		printerr("selftest FAILED: sv_pack_pins is not a NOTIFY cvar the query reports")
		return false

	return true


## The addon versions a joining client is told about. Empty on a box with a lock means every player keeps the addons their shell was exported with, however old.
## Through `get`, not the property: a box's dot-server may predate it, and a typed access would stop this whole script compiling there.
func _addons_advertised() -> bool:
	var announced: Variant = (host.server as DotServer).get("addon_set")

	if not (announced is Array) or OS.get_environment("TMC_ADDONS_LOCK") == "off" \
			or not FileAccess.file_exists(host.ADDONS_LOCK):
		return true

	if (announced as Array).is_empty():
		printerr("selftest FAILED: %s names addons and none are advertised to clients" % host.ADDONS_LOCK)
		return false

	for entry in announced:
		if str(entry.get("dir", "")) == "dot_server" \
				and not (str(entry.get("id", "")) in ["modcommunity/dot-server", "gamespice-platform/server"]):
			printerr("selftest FAILED: dot_server is advertised as %s" % str(entry.get("id", "")))
			return false

	print("addons advertised: %d" % (announced as Array).size())
	return true


## Registered ALWAYS, empty or not, so an operator can move a running server with rcon.
## A cvar that only exists when the config named a version is one `sv_web_loader x`
## answers "unknown command" to on every server that has not needed it yet.
func _web_loader_present() -> bool:
	var loader := (host.server as DotServer).console.find_cvar("sv_web_loader")

	if loader == null or not loader.has_flag(DotConVar.FLAG_NOTIFY):
		printerr("selftest FAILED: sv_web_loader is not a NOTIFY cvar the query reports")
		return false

	if loader.get_string() != host._web_loader_value():
		printerr("selftest FAILED: sv_web_loader reports %s, the configuration says %s" % [
			loader.get_string(), host._web_loader_value(),
		])
		return false

	print("sv_web_loader: %s" % (loader.get_string() if loader.get_string() != "" else "(site default)"))
	return true


## Asked, not only looked up: a command that is registered and answers nothing is the same absent command one layer down.
func _party_status_answers() -> bool:
	var server: DotServer = host.server
	var config: TmcConfig = host.config
	# An Array rather than a PackedStringArray: a lambda captures by value, and only a container's contents survive the copy (docs/gdscript-hazards.md).
	var answered: Array = []
	var asking := DotCmdContext.internal("party_status", PackedStringArray())
	asking.reply_sink = func(line: String) -> void: answered.append(line)

	var said := server.console.execute("party_status", asking)

	if not said.ok or answered.is_empty():
		printerr("selftest FAILED: party_status did not answer (%s)" % str(said.error))
		return false

	if config.party_enabled and (host.parties == null or host.parties.reservations == null):
		printerr("selftest FAILED: cfg/party.yml asked for parties and none were built")
		return false

	for line in answered:
		print("party_status: %s" % line)

	return true


## [b]The ring, recording on the server that booted.[/b] dot-replay was the other addon
## linked here and built nowhere; an absent `replay` command is caught above, and a ring
## that was built and never started is the same failure one layer down.
func _replay_recording() -> bool:
	var replay: TmcReplay = host.replay

	if (host.config as TmcConfig).replay_enabled and (replay == null or not replay.recorder.is_recording()):
		printerr("selftest FAILED: cfg/replay.yml asked for the replay ring and it is not recording")
		return false

	if replay != null:
		for line in replay.describe_lines():
			print("replay: %s" % line)

	return true
