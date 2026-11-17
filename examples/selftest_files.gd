class_name SelftestFiles
extends RefCounted

## Folder helpers the selftest's replay section uses to start clean and count the clips it wrote.


static func remove_tree(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		remove_tree(dir.path_join(sub))
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


static func count_replays(dir: String) -> int:
	var da := DirAccess.open(dir)
	var n := 0
	if da != null:
		for f in da.get_files():
			if f.ends_with(".dreplay"):
				n += 1
	return n
