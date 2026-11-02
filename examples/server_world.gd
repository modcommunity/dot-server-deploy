extends RefCounted

## Puts a suite's server in a World3D of its own, away from the client in the same process.
## [b]Why.[/b] A suite that runs a server and a client in one process builds the delivered game
## twice: the server's copy and the client's.

const NAME := "ServerWorld"


## Adds [param host] under [param parent] inside a new world of its own, and returns the world.
static func add(parent: Node, host: Node) -> SubViewport:
	var world := SubViewport.new()
	world.name = NAME
	world.own_world_3d = true
	world.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(world)
	world.add_child(host)
	return world


## Takes [param host] out of the tree, and the world [method add] made for it with it. The host is
## left for the caller to free, as `remove_child` would.
static func remove(host: Node) -> void:
	if host == null or not is_instance_valid(host):
		return

	var world := host.get_parent()

	if world == null:
		return

	world.remove_child(host)

	if world is SubViewport and String(world.name).begins_with(NAME):
		var parent := world.get_parent()
		if parent != null:
			parent.remove_child(world)
		world.queue_free()
