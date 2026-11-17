class_name TmcJoinTimings
extends RefCounted
## Where a join's time went: the shell notes Time.get_ticks_usec() at each stage by name, and this turns the notes into milliseconds between stages.

const ORDER := ["start", "CONNECTING", "AUTHENTICATING", "DOWNLOADING", "dl_first", "dl_last", "LOADING", "PLAYING"]


## Milliseconds from each stage that was marked to the next, then to "spawned" at [param now], and the total. [param marks] must hold "start".
static func stages(marks: Dictionary, now: int) -> Dictionary:
	var out := {}
	var last: int = marks["start"]
	var last_name := "start"
	for key in ORDER.slice(1):
		if marks.has(key):
			out["%s>%s" % [last_name, key]] = int((int(marks[key]) - last) / 1000.0)
			last = marks[key]
			last_name = key
	out["%s>spawned" % last_name] = int((now - last) / 1000.0)
	out["total"] = int((now - int(marks["start"])) / 1000.0)
	return out
