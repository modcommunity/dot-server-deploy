extends RefCounted

## Stands in for an addon's fallback-root list (AwModelCache's shape) in the selftest.

static var roots: PackedStringArray = PackedStringArray()


static func add_fallback_root(root: String) -> void:
	if not root in roots:
		roots.append(root)


static func remove_fallback_root(root: String) -> void:
	var i := roots.find(root)
	if i >= 0:
		roots.remove_at(i)
