extends Node

## The browser half of tools/audio_overlay_web_proof.sh. First load: the build's dot-audio predates stream_at, so fetch the
## site's pack from the page's own origin (/content, the proof's content host), build the overlay and reload. Second load: boot
## mounted the overlay; play a stock footstep and bed and print one CHECK line the page driver reads from the console.

const FOOTSTEP := "res://addons/dot_audio/stock/footsteps/footstep_carpet_0.ogg"
const BED := "res://addons/dot_audio/stock/ambience/amb_indoor.ogg"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _sink() -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == "DotAudioSinkGodot":
			return load(str(entry.get("path", ""))) as Script
	return null


func _run() -> void:
	var sink := _sink()
	if sink != null and sink.has_method("stream_at"):
		await _play(sink)
		return
	print("AO first load: no stream_at, building the overlay")
	var origin := str(DotWeb.get_global("location").origin)
	var version := FileAccess.get_file_as_string("res://version.txt").strip_edges()
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = "user://audio_overlay_cache"
	cloud.config.parallel_downloads = 3
	cloud.config_file = "res://content.json"
	var base := origin + "/content"
	cloud.http_base_urls = PackedStringArray([base, "%s/modcommunity/dot-audio/%s" % [base, version]])
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])
	add_child(cloud)
	var set := DotCloudAddonSet.new(cloud)
	set.namespaces = PackedStringArray(["modcommunity/"])
	var decided := set.plan_for([{"dir": "dot_audio", "repo": "dot-audio", "id": "modcommunity/dot-audio", "version": version}])
	var wanted: Dictionary = decided["wanted"]
	if wanted.is_empty():
		print("AO BUILD refused ", decided["refused"])
		return
	var built := await set.build(wanted)
	print("AO BUILD ok=", built.ok, " ", "" if built.ok else str(built.error))
	if not built.ok:
		return
	var kept := await DotCloudAddonSet.persisted(PackedStringArray([DotCloudAddonSet.PLAN, str((built.value as Dictionary)["pack"])]), 60.0)
	print("AO PERSISTED ok=", kept.ok)
	if kept.ok:
		DotWeb.get_global("location").reload()


func _play(sink: Script) -> void:
	var info := {"overlay": str(ProjectSettings.get_setting("dot_cloud/addon_overlay", "")), "has_stream_at": true}
	var players: Array[AudioStreamPlayer] = []
	for path: String in [FOOTSTEP, BED]:
		var stream: AudioStream = sink.call("stream_at", path)
		info[path.get_file()] = stream != null and stream.get_length() > 0.0
		if stream != null:
			var p := AudioStreamPlayer.new()
			p.stream = stream
			add_child(p)
			p.play()
			players.append(p)
	print("AO PLAYING")
	var advanced := {}
	for i in 100:
		await get_tree().create_timer(0.05).timeout
		for p in players:
			if p.playing and p.get_playback_position() > 0.0:
				advanced[p] = true
	info["advanced"] = players.size() == 2 and advanced.size() == 2
	DotCloudAddonSet.confirm_boot()
	print("CHECK ", JSON.stringify(info))
