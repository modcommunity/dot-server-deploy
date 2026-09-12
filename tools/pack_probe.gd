extends SceneTree

## Does a script inside a MOUNTED pack see the HOST's `class_name` globals?
##
## The whole platform shape turns on this. It is already measured that a pack's OWN
## `class_name` globals are not registered, so a pack's scripts must find each other by
## path. What was never measured is whether the HOST's globals still resolve from inside
## one -- and if they do not, a creator cannot call a single dot-* API from delivered
## content and every mode needs its own engine build.
##
##     godot --headless --path . --script res://tools/pack_probe.gd
##
## MEASURED 2026-09-12, on this project with the whole dot-* family in it:
##
##     host class_name    resolved DotResult, value 42
##     pack class_name    SCRIPT DID NOT COMPILE
##     pack by path       by path ok: true
##
## So the rule is narrower than "a pack cannot carry code". A pack's scripts cannot
## find EACH OTHER by `class_name`; everything the BUILD ships they can call freely.
## That is what makes delivered content worth having -- a game mode shipped as a pack
## gets the entire addon API, and only its own files have to be reached by path.
##
## Takes about two minutes: `--script` on this project boots every addon in it first.

const OUT := "user://packprobe.pck"
const ROOT := "res://packprobe"


func _init() -> void:
	var cases := {
		# 1. The question. `DotResult` is the host's, registered in the host's global
		#    class list at export; the pack does not contribute to that list, but it does
		#    not empty it either -- so this should resolve if anything does.
		"host class_name": ("extends RefCounted\nfunc probe() -> String:\n"
			+ "\tvar r := DotResult.success(42)\n"
			+ "\treturn \"resolved DotResult, value \" + str(r.value)\n"),
		# 2. The known failure, re-run here so the test proves it can TELL them apart
		#    rather than reporting whatever the engine happens to do today.
		"pack class_name": "extends RefCounted\nfunc probe() -> String:\n\tvar x := PackProbeLocal.new()\n\treturn \"pack class ok: %s\" % x\n",
		# 3. The documented workaround, for the same reason.
		# Concatenated rather than formatted: the staged SOURCE contains its own `%s`,
		# so formatting the outer string makes the two fight over one argument.
		"pack by path": ("extends RefCounted\nfunc probe() -> String:\n\tvar L = load(\""
			+ ROOT + "/local.gd\")\n\treturn \"by path ok: \" + str(L != null)\n"),
	}

	var packer := PCKPacker.new()
	if packer.pck_start(OUT) != OK:
		print("[probe] could not start a pack"); quit(1); return

	# The pack-internal class the second case looks for by name and the third by path.
	_stage("local.gd", "class_name PackProbeLocal\nextends RefCounted\n", packer)
	for name: String in cases:
		_stage("%s.gd" % name.replace(" ", "_"), cases[name], packer)

	if packer.flush(false) != OK:
		print("[probe] could not flush the pack"); quit(1); return

	# Mounted the way dot-cloud mounts: a path nothing in the host uses, so a hit
	# cannot be the host's own copy of the file answering.
	if not ProjectSettings.load_resource_pack(OUT, false):
		print("[probe] the pack did not mount"); quit(1); return

	print("[probe] pack mounted at %s" % ROOT)
	print("")

	var failed := 0
	for name: String in cases:
		var path := "%s/%s.gd" % [ROOT, name.replace(" ", "_")]
		var script: Variant = load(path)

		if script == null:
			print("  %-18s SCRIPT DID NOT COMPILE" % name)
			failed += 1
			continue

		# [b]A script that failed to COMPILE still loads as a non-null GDScript.[/b] The
		# null check above does not catch it, and `.new()` on one aborts the whole run --
		# which is how case 2's known failure took cases 3 and the summary with it.
		if not (script as GDScript).can_instantiate():
			print("  %-18s SCRIPT DID NOT COMPILE" % name)
			failed += 1
			continue

		var obj: Object = (script as GDScript).new()
		if not obj.has_method("probe"):
			print("  %-18s compiled but has no probe()" % name)
			failed += 1
			continue

		print("  %-18s %s" % [name, obj.call("probe")])

	print("")
	print("[probe] %d of %d cases failed to compile" % [failed, cases.size()])
	quit(0)


func _stage(name: String, source: String, packer: PCKPacker) -> void:
	var tmp := "user://_probe_%s" % name
	var fh := FileAccess.open(tmp, FileAccess.WRITE)
	fh.store_string(source)
	fh.close()
	packer.add_file("%s/%s" % [ROOT, name], ProjectSettings.globalize_path(tmp))
