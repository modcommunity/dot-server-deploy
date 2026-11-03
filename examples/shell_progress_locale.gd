extends Node

## The shell's aggregate download line in two languages, and every locale carrying every progress key.
## `-- --shot out.png` (under a display) saves the frame with the German line up.

const SHELL := "res://client/shell.tscn"
const LOCALES := "res://client/locales"
const CHECKS := 29
const KEYS := ["job.line", "progress.file_of", "size", "rate", "eta.few", "eta.seconds", "eta.minutes", "solo.fetching", "solo.have", "solo.fetching_size"]

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy: the shell's download line, localised")
	_test_every_locale_has_every_key()
	await _test_two_languages()
	print("%d passed, %d failed (expected %d checks)" % [_passed, _failed, CHECKS])
	get_tree().quit(0 if _failed == 0 and _passed == CHECKS else 1)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL: ", what)


func _flat(d: Dictionary, prefix: String, out: Dictionary) -> void:
	for k in d:
		if d[k] is Dictionary:
			_flat(d[k], prefix + str(k) + ".", out)
		else:
			out[prefix + str(k)] = d[k]


func _test_every_locale_has_every_key() -> void:
	var langs := DirAccess.get_directories_at(LOCALES)
	_check(langs.has("en") and langs.size() >= 2, "English and at least one more language ship (%s)" % ", ".join(langs))
	for lang in langs:
		var f := FileAccess.open("%s/%s/shell.json" % [LOCALES, lang], FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
		var flat := {}
		if parsed is Dictionary:
			_flat(parsed, "", flat)
		for key in KEYS:
			_check(flat.has(key), "%s has shell.%s" % [lang, key])


func _test_two_languages() -> void:
	var shell: Node = (load(SHELL) as PackedScene).instantiate()
	add_child(shell)
	await get_tree().process_frame
	await get_tree().process_frame

	var snap := {"total_packs": 40, "done_packs": 3, "total_bytes": 400 * 1048576, "done_bytes": int(63.5 * 1048576),
		"fraction": 0.16, "bytes_per_sec": 2.5 * 1048576, "eta_sec": 130.0}
	shell._job = snap

	shell._locale.set_locale("en")
	var en: String = shell._job_line()
	_check(en.contains("63.5 / 400 MiB") and en.contains("3 of 40 packs"), "English line: " + en.replace("\n", " | "))
	_check(en.contains("2.5 MiB/s") and en.contains("2 min left"), "English rate and ETA")

	shell._locale.set_locale("de")
	var de: String = shell._job_line()
	_check(de.contains("63,5 / 400 MiB") and de.contains("3 von 40 Paketen"), "German line: " + de.replace("\n", " | "))
	_check(de.contains("2,5 MiB/s") and de.contains("noch 2 Min."), "German rate and ETA")
	_check(de != en, "the two languages differ")

	var one := snap.duplicate()
	one["total_packs"] = 1
	shell._job = one
	shell._locale.set_locale("en")
	_check(shell._job_line().contains("3 of 1 pack") and not shell._job_line().contains("packs"), "English plural: one pack, not packs")

	shell._locale = DotLocale.new()
	shell._job = snap
	_check(shell._job_line().contains("3 of 40 packs") and shell._job_line().contains("2.5 MiB/s"), "no catalogue: the English fallback still renders")

	shell._build_locale()
	shell._locale.set_locale("de")
	shell._on_cloud_job(snap)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(shell._detail != null and shell._detail.visible and shell._detail.text.contains("Paketen"), "the on-screen detail label shows the German line")

	var args := OS.get_cmdline_user_args()
	var at := args.find("--shot")
	if at >= 0 and at + 1 < args.size():
		await get_tree().create_timer(0.5).timeout
		get_viewport().get_texture().get_image().save_png(args[at + 1])
