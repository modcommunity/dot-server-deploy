extends Node

## Process 2 of tools/audio_overlay_proof.sh: started through dot-cloud's boot scene, plays a stock footstep and a bed.
## Names no DotAudio class in typed code: the build's own copy predates stream_at, and the overlay supplies it.

const FOOTSTEP := "res://addons/dot_audio/stock/footsteps/footstep_carpet_0.ogg"
const BED := "res://addons/dot_audio/stock/ambience/amb_indoor.ogg"


func _ready() -> void:
	var info := {"overlay": str(ProjectSettings.get_setting("dot_cloud/addon_overlay", ""))}
	var sink: Script = null
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == "DotAudioSinkGodot":
			sink = load(str(entry.get("path", ""))) as Script
	info["has_stream_at"] = sink != null and sink.has_method("stream_at")
	var players: Array[AudioStreamPlayer] = []
	for path: String in [FOOTSTEP, BED]:
		var stream: AudioStream = sink.call("stream_at", path) if bool(info["has_stream_at"]) else null
		info[path.get_file()] = stream != null and stream.get_length() > 0.0
		if stream != null:
			var p := AudioStreamPlayer.new()
			p.stream = stream
			add_child(p)
			p.play()
			players.append(p)
	# A footstep is short, so ask each player every frame whether it has ever advanced.
	var advanced := {}
	for i in 30:
		await get_tree().process_frame
		await get_tree().create_timer(0.02).timeout
		for p in players:
			if p.playing and p.get_playback_position() > 0.0:
				advanced[p] = true
	info["advanced"] = players.size() == 2 and advanced.size() == 2
	DotCloudAddonSet.confirm_boot()
	print("CHECK ", JSON.stringify(info))
	get_tree().quit()
