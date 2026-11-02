extends Logger
## Every RPC that arrived addressed to a node the receiving end does not have.

## The engine's spellings of "an RPC named a node this end does not have".
const PATTERNS: PackedStringArray = [
	"Failed to get path from RPC",
	"Requested node was not found",
	"Node not found: \"Server/",
]

const KEEP := 8

## The engine logs from any thread.
var _mutex := Mutex.new()
var _seen := PackedStringArray()
var _count := 0


func _log_error(
	_function: String,
	_file: String,
	_line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	_error_type: int,
	_script_backtraces: Array[ScriptBacktrace],
) -> void:
	var text := code if rationale == "" else "%s: %s" % [code, rationale]

	if not _matches(text):
		return

	_mutex.lock()
	_count += 1
	if _seen.size() < KEEP:
		_seen.append(text)
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass


## How many such errors the engine logged since this was installed.
func count() -> int:
	_mutex.lock()
	var n := _count
	_mutex.unlock()
	return n


## The first few, for a failure's detail line.
func summary() -> String:
	_mutex.lock()
	var text := " | ".join(_seen)
	_mutex.unlock()
	return text


static func _matches(text: String) -> bool:
	for pattern in PATTERNS:
		if text.contains(pattern):
			return true
	return false
