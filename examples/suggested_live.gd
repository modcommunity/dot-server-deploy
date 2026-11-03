extends Node

## Live proof that a game's suggested packs mount from a real content origin. Runs the real shell's
## [code]_sync_workshop[/code] as a guest with a clean cache, the way a solo start does, and prints
## one [code]RESULT[/code] line: the packs mounted and the suggested summary.

const SHELL := "res://client/shell.tscn"
const WORK := "user://suggested_live"

var _asked := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _run() -> void:
	var yml := _arg("--game-yml", "")
	if yml == "" or FileAccess.open(yml, FileAccess.READ) == null:
		print("RESULT error=no game.yml (--game-yml) yml=%s err=%d" % [yml, FileAccess.get_open_error()])
		get_tree().quit(1)
		return
	var desc := TmcSolo.parse_descriptor(FileAccess.get_file_as_string(yml))
	DotPaths.remove_tree(WORK)

	var shell: Node = (load(SHELL) as PackedScene).instantiate()
	shell.set("workshop_backbone_url", "")
	shell.call("_ensure_cloud")
	var cloud: DotCloudClient = shell.get("_cloud")
	cloud.config.cache_dir = WORK.path_join("cache")
	cloud.http_base_urls = PackedStringArray([_arg("--content-url", "https://dotgames.org/content")])
	var ws: DotCloudWorkshop = shell.call("_ensure_workshop")
	ws.config_file = ""
	ws.cache_dir = WORK.path_join("workshop")
	shell.set("workshop_ask_override", func(_summary: Dictionary) -> bool:
		_asked += 1
		return true)
	add_child(shell)
	await get_tree().process_frame

	var res: Variant = await shell.call("_sync_workshop", str(desc["content_id"]), desc["suggested"])
	var summary: Dictionary = res if res is Dictionary else {}
	var mounted: PackedStringArray = []
	for m in summary.get("mounted", []):
		mounted.append("%s@%s" % [m["content_id"], m["version"]])
	var failed: PackedStringArray = []
	for f in summary.get("failed", []):
		failed.append(str(f))
	print("RESULT game=%s declared=%d mode=%s kept=%d asked=%d mounted=[%s] failed=[%s]" % [
		desc["content_id"], (desc["suggested"] as PackedStringArray).size(),
		(summary.get("suggested", {}) as Dictionary).get("mode", "?"),
		int((summary.get("suggested", {}) as Dictionary).get("kept", -1)), _asked,
		", ".join(mounted), "; ".join(failed)])
	DotPaths.remove_tree(WORK)
	get_tree().quit(0 if not summary.is_empty() else 1)
