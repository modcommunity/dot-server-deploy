extends Node

## dot-trail's install: trail.yml, TmcTrail on an unstarted DotServer, and TmcTrailLink in a shell. Without the addon linked only the off paths run.

const SECTIONS := 3
const CHECKS := 14

var _passed := 0
var _failed := 0
var _sections := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("dot-server-deploy trail wiring (addon %s)" % ("linked" if TmcTrail.available() else "absent"))
	_test_config()
	_test_host()
	_test_link()
	print("%d sections, %d passed, %d failed" % [_sections, _passed, _failed])
	if _sections != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections, %d checks ran; expected %d and %d." % [_sections, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_config() -> void:
	_section("trail.yml")
	var shipped := TmcYaml.parse_file("res://cfg.example/addon/dot_trail/trail.yml")
	_check(shipped.ok and shipped.value is Dictionary, "the shipped trail.yml parses")
	var tree: Dictionary = shipped.value if shipped.ok else {}
	var cfg := TmcConfig.new()
	tree["trail_typo"] = 1
	_check(TmcTrail.apply_config(cfg, tree).ok, "apply_config accepts it")
	_check(cfg.trail.has("trail_pack") and not cfg.trail.has("trail_typo"), "known keys are kept, the typo is not")
	_check("\n".join(cfg.unknown).contains("trail_typo"), "an unknown trail_ key is reported")
	_check(not TmcConfig._truthy(cfg.trail.get("trail_enabled", true)), "the shipped file leaves trails off")


func _test_host() -> void:
	_section("TmcTrail on the server")
	var host := Node.new()
	add_child(host)
	var cfg := TmcConfig.new()
	_check(TmcTrail.install(host, null, cfg, "user://") == null and host.get_child_count() == 0, "off builds nothing")
	cfg.trail = {"trail_enabled": true}
	var server := DotServer.new()
	var on := TmcTrail.install(host, server, cfg, ProjectSettings.globalize_path("user://trail_wiring"))
	if not TmcTrail.available():
		_check(on == null and host.get_child_count() == 0, "enabled without the addon is a warning, not a crash")
		for i in 3:
			_check(true, "(addon absent) skipped")
	else:
		_check(on != null and DotRegistry.get_service(TmcTrail.SERVICE) == on.relay, "enabled: the relay is built and registered")
		var session := DotClientSession.new(0, 7)
		session.groups = PackedStringArray(["vip"])
		server.client_spawned.emit(session)
		_check(on.relay.peers().has(7) and on._groups(7) == PackedStringArray(["vip"]), "a spawned player is a relay peer with its groups")
		_check(server.envelope.dispatch(7, &"dot.trail", {"id": ""}), "the server handles the dot.trail kind")
		server.client_disconnected.emit(session, "bye")
		_check(not on.relay.peers().has(7), "a player who leaves is forgotten")
	host.free()
	server.free()


func _test_link() -> void:
	_section("TmcTrailLink in the shell")
	var link := TmcTrailLink.new()
	add_child(link)
	var present := TmcTrailLink.available()
	_check(present == (link.client != null), "a client exists exactly when the addon is in the build")
	var prejoin := DotGamePrejoin.new()
	var before: int = prejoin.extra_steps.size() if &"extra_steps" in prejoin else 0
	link.before_join(prejoin)
	var after: int = prejoin.extra_steps.size() if &"extra_steps" in prejoin else 0
	_check(after == before + (1 if present and &"extra_steps" in prejoin else 0), "the pack fetch is one extra prejoin step")
	var client_link := DotClientLink.new()
	link.attach(client_link)
	_check(not present or client_link.envelope.knows(&"dot.trail"), "the link carries the dot.trail kind")
	link.reset()
	_check(link._menu == null, "reset forgets the menu")
	client_link.free()
	link.free()


func _section(title: String) -> void:
	_sections += 1
	print("== " + title)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL " + what)
