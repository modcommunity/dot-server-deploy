extends RefCounted

## Puts a suite's server in a World3D of its own, away from the client in the same process.
##
## [codeblock]
## const ServerWorld := preload("res://examples/server_world.gd")
## ServerWorld.add(self, _host)      # instead of add_child(_host)
## ServerWorld.remove(_host)         # instead of remove_child(_host)
## [/codeblock]
##
## [b]Why.[/b] A suite that runs a server and a client in one process builds the delivered game
## twice: the server's copy and the client's. In the root's World3D both copies are in one physics
## space, so the server's bodies collide with the client's copies of themselves. Buses' server bus
## hit its client twin and the bowl, was thrown out and fell for ever (y=-2120 at 30 s), in a suite
## that only passed elsewhere because it asserted nothing about physics. A deployed server and its
## clients never share a process, so a suite must not let them share a world.
##
## A [SubViewport] with [member Viewport.own_world_3d] gives the server its own World3D, and, as
## every Viewport does, its own World2D. It renders nothing ([constant SubViewport.UPDATE_DISABLED]):
## physics is stepped per space whether or not anything draws it.
##
## No [code]class_name[/code]: a suite helper is not worth a global name in every consumer's class
## cache.

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
