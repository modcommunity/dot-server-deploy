class_name TmcNativeStatus
extends RefCounted

## One line saying which dot-sim modules run native (the Rust GDExtension) and which run their
## GDScript twins, for the server's and the shell's startup log. Both give the same results; the
## twins are slower, which a 32-player server with bots pays for, and nothing else says which
## one a process got.
##
## The native classes are reached only through ClassDB by name, and DotSim itself is loaded by
## path, so this compiles in a build without dot-sim (the line then says so) and in a web
## export, where the library is never shipped.

const DOT_SIM_SCRIPT := "res://addons/dot_sim/dot_sim.gd"


## "dot-sim native: bots=yes motor=yes snapshot=no", or a line saying dot-sim is absent.
static func line() -> String:
	if not ResourceLoader.exists(DOT_SIM_SCRIPT):
		return "dot-sim native: no (dot-sim is not in this build)"

	var script := load(DOT_SIM_SCRIPT) as Script
	if script == null:
		return "dot-sim native: no (%s did not load)" % DOT_SIM_SCRIPT

	var modules: Variant = script.get_script_constant_map().get("MODULES", {})
	if not (modules is Dictionary) or (modules as Dictionary).is_empty():
		return "dot-sim native: unknown (DotSim names no MODULES)"

	return describe(modules as Dictionary)


## Pure part: `modules` maps a module name to its native class name.
static func describe(modules: Dictionary) -> String:
	# Sorted as Strings: DotSim's keys are StringNames, which Array.sort() orders by pointer.
	var names := PackedStringArray()
	for key in modules:
		names.append(str(key))
	names.sort()
	var parts := PackedStringArray()
	for module_name in names:
		var value: Variant = modules.get(module_name, modules.get(StringName(module_name)))
		var native := ClassDB.class_exists(StringName(str(value)))
		parts.append("%s=%s" % [module_name, "yes" if native else "no"])
	return "dot-sim native: " + " ".join(parts)
