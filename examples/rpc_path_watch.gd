extends Logger
## Every RPC that arrived addressed to a node the receiving end does not have.
##
## [codeblock]
## const RpcPathWatch := preload("res://examples/rpc_path_watch.gd")
## var watch := RpcPathWatch.new()
## OS.add_logger(watch)
## # ... the run ...
## _check(watch.count() == 0, "no RPC was addressed to a node the other end lacks", watch.summary())
## [/codeblock]
##
## [b]Why a suite listens to the engine's log for this.[/b] Godot reports an RPC whose path the
## receiver cannot resolve with three C++ errors (`Node not found: "Server/@Node@2370"`, `Failed
## to get path from RPC`, `Invalid packet received`), drops the packet, and carries on: no
## signal, no return value, no exit code. A game whose link was renamed `@Node@<n>` by a name
## collision after a game change lost every request its client sent, and every suite that
## switched games passed with those lines in its stderr. Only the log says it happened, so the
## suites that change games with a client attached read the log. No `class_name`: an example
## helper, preloaded where it is used.

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
