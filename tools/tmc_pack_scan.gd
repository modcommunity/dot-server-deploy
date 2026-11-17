class_name TmcPackScan
extends RefCounted
## Looks at a source tree before it is packed: the globals it declares and how many files it holds.


## Every `class_name` declared under [param root], up to a handful worth naming. Text search rather
## than a parse: this runs over a tree that is about to be published and the question is only
## whether the declaration is there.
static func class_names_in(root: String) -> PackedStringArray:
	var out := PackedStringArray()

	for rel in DotPaths.list_files_recursive(root):
		if not rel.ends_with(".gd"):
			continue
		# The host's own addons legitimately declare globals; they are not in the pack.
		if rel.begins_with("addons/") or rel.contains("/addons/"):
			continue
		# A linked git worktree inside the source (a `.git` file) is not part of the game.
		if rel.contains("/") and FileAccess.file_exists(root.path_join(rel.get_slice("/", 0)).path_join(".git")):
			continue

		for line in FileAccess.get_file_as_string(root.path_join(rel)).split("\n"):
			if not line.begins_with("class_name "):
				continue

			var name := line.substr(11).strip_edges().split(" ")[0]

			if name != "" and not out.has(name):
				out.append("%s (%s)" % [name, rel])

			if out.size() >= 6:
				return out

	return out


static func count_files(root: String) -> int:
	var abs_root := ProjectSettings.globalize_path(root)
	var dir := DirAccess.open(abs_root)

	if dir == null:
		return 0

	var count := 0

	dir.list_dir_begin()
	var name := dir.get_next()

	while name != "":
		if name != "." and name != "..":
			var child := root.path_join(name)

			if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(child)):
				count += count_files(child)
			else:
				count += 1

		name = dir.get_next()

	dir.list_dir_end()

	return count
