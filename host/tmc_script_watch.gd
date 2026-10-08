class_name TmcScriptWatch
extends Logger
## Every script that failed to compile or load while `./server check` ran.
##
## [b]A parse failure takes no exit path.[/b] Godot prints `SCRIPT ERROR: Parse Error: Could
## not find base class "DotGameModule"`, hands back a script that cannot be instantiated,
## and carries on — so a boot whose game module never compiled still reached the end of
## the selftest and printed `selftest ok`. That is exactly what a fresh clone did when
## `./setup.sh --only-games <one game>` left `addons/dot_game` unlinked. Nothing the host asks
## afterwards can see it: the error went to the engine's log and nowhere else.
##
## So the check listens to the engine's log itself. Installed with [method OS.add_logger]
## for the length of a selftest and read once at the end; any script error, and any load
## failure spelled the ways the engine spells them, fails the check.
##
## [b]Not installed on a normal run.[/b] A server that is already serving should say what
## broke and keep serving; a CHECK exists to refuse exactly this.

## The engine's own spellings of "a script did not load". Matched on the error's text
## because a load failure reported from C++ (`Failed to load script ...`) arrives as a
## plain error, not as a script error.
const PATTERNS: PackedStringArray = [
	"Parse Error",
	"Could not find base class",
	"Could not resolve super class",
	"Failed to load script",
]

## How many are kept for the report. The count is exact; the list is enough to act on.
const KEEP := 16

## The engine logs from any thread.
var _mutex := Mutex.new()
var _seen := PackedStringArray()
var _count := 0


func _log_error(
	_function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_script_backtraces: Array[ScriptBacktrace],
) -> void:
	var text := code if rationale == "" else "%s: %s" % [code, rationale]

	if error_type != ERROR_TYPE_SCRIPT and not _matches(text):
		return

	_mutex.lock()
	_count += 1

	if _seen.size() < KEEP:
		_seen.append("%s (%s:%d)" % [text, file, line])

	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass


## How many script errors have been logged since this was installed.
func count() -> int:
	_mutex.lock()
	var n := _count
	_mutex.unlock()
	return n


## The first [constant KEEP] of them, one line each.
func lines() -> PackedStringArray:
	_mutex.lock()
	var copy := _seen.duplicate()
	_mutex.unlock()
	return copy


static func _matches(text: String) -> bool:
	for pattern in PATTERNS:
		if text.contains(pattern):
			return true

	return false
