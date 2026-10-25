class_name TmcRadioLink
extends Node

## The shell's half of dot-radio: a `DotRadioClient` pointed at the station URL the server sends.
##
## Nothing plays until the player presses the `radio_toggle` key (the client's own input
## handler calls tune_in from that gesture); this never tunes in itself. A shell built
## without dot-radio ignores the notice.

const TOPIC := "tmc.radio"

var radio: Node = null


## Handles the server's notice. Returns true when a radio client now exists.
func adopt(data: Dictionary) -> bool:
	var url := str(data.get("url", "")).rstrip("/")
	if url.is_empty():
		return false
	if radio != null:
		radio.base_url = url
		return true
	var client_script := _script_named("DotRadioClient")
	var sink_script := _script_named("DotRadioSinkGodot")
	if client_script == null or sink_script == null:
		return false
	radio = client_script.new()
	radio.name = "RadioClient"
	var sink: RefCounted = sink_script.new()
	radio.sink = sink
	radio.base_url = url
	add_child(radio)
	sink.attach(self)
	return true


## Back to nothing when the game is left: stops playback and frees the client.
func reset() -> void:
	if radio != null:
		radio.tune_out()
		radio.queue_free()
		radio = null


func _script_named(class_name_: String) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_:
			return load(str(entry.get("path", ""))) as Script
	return null
