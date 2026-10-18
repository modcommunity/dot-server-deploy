extends Node3D

## A game root on the older duck-typed contract, for admin_loading_selftest's cover section.

signal ready_to_show()

var ready_now := false


func is_ready_to_show() -> bool:
	return ready_now
