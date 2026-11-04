extends Node

## Process 1 of tools/audio_overlay_proof.sh: fetch the site's dot-audio pack the way the shell does and build the overlay.

const CONTENT_CONFIG := "res://content.json"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.DEBUG if OS.get_environment("AO_DEBUG") != "" else DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var base := args[0]
	var version := args[1]
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = "user://audio_overlay_cache"
	cloud.config.parallel_downloads = 3
	cloud.config_file = CONTENT_CONFIG
	# Objects sit under the pack's versioned directory; the second base is that directory.
	cloud.http_base_urls = PackedStringArray([base, "%s/modcommunity/dot-audio/%s" % [base, version]])
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])
	add_child(cloud)

	var set := DotCloudAddonSet.new(cloud)
	set.namespaces = PackedStringArray(["modcommunity/"])
	var decided := set.plan_for([{"dir": "dot_audio", "repo": "dot-audio", "id": "modcommunity/dot-audio", "version": version}])
	var wanted: Dictionary = decided["wanted"]
	print("BUILD wanted=", wanted.keys(), " refused=", decided["refused"])
	if wanted.is_empty():
		get_tree().quit(2)
		return

	print("BUILD bases=", cloud.resolved_http_base_urls(), " mirrors=", cloud.config.use_mirrors)
	var built := await set.build(wanted)
	print("BUILD ok=", built.ok, " ", "" if built.ok else str(built.error))
	get_tree().quit(0 if built.ok else 1)
