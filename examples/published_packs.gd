extends RefCounted

## Whether a delivered game's pack is on this box, for a suite that boots it.
## [b]Why.[/b] No game is in this build: a pack is published into `dist/` by `./setup.sh` or `./server pack`, or installed
## into `content/<owner>/<name>/` by `./server install-games`. A clean checkout has neither, and a suite that boots the game
## then fails on a missing manifest instead of saying what it needs.


## True when [param content_id] (`tmc/buses`) is published in `dist/` or installed under the content directory.
static func has(content_id: String) -> bool:
	for root in ["res://dist", "res://content"]:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("%s/%s" % [root, content_id])):
			return true

	return false
