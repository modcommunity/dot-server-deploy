class_name TmcEnroll
extends Node
## Gets this server its integration credential from the site, with nobody pasting a token.
##
## [b]Why it exists.[/b] Everything this server is to the site -- listed, reporting stats
## and records, resolving a signed-in player (`auth.yml`'s `introspect`) and reading their
## avatar -- runs on the integration token in `data/listing.json`. It used to be made by
## hand in the site's dashboard and copied onto the box, and a box without one admitted
## every member as a guest while looking perfectly healthy.
##
## [b]How it proves who it is.[/b] The site already knows this server's address: it found
## it by scanning, and claiming it on the site proved a person controls it. So this asks
## the site for an enrollment, gets back a public CHALLENGE and a SECRET, publishes the
## challenge as the A2S rule `tmc_enroll`, and completes with the secret. The site queries
## the address IT has stored for the server -- never one this request names -- and issues
## the credential only if the challenge is there. Answering on that address is being this
## server; holding the secret is being the process that asked. The challenge is public the
## moment it is published (anyone can read a server's rules), which is why it completes
## nothing on its own.
##
## [b]When it runs.[/b] At boot, before [TmcReport] reads `listing.json`, and only when
## that file has no token: an operator's own token is never replaced. It waits up to
## [constant BOOT_WAIT_SEC] so the first game loads WITH the credential (the game's identity
## layer looks for it as its module loads); after that the boot goes on and this keeps
## asking until the enrollment expires, then [signal enrolled] lets the host pick the
## token up live. `TMC_ENROLL=off` turns it off.
##
## [b]What it needs from the operator.[/b] The server added and claimed on the site, and
## A2S answering on the address the site has for it -- both true of any server already
## listed there.

const CHANNEL := "tmc.enroll"

## The A2S rule the challenge is published as. The site looks for the VALUE, so the name
## is only for a person reading the rules.
const RULE := "tmc_enroll"

const START_PATH := "/api/integration/v1/server/enroll"
const COMPLETE_PATH := "/api/integration/v1/server/enroll/complete"

## How long the boot waits. The site queries the server directly on every completion, so
## the first one normally succeeds; this is for a site that is slow, not for a scan.
const BOOT_WAIT_SEC := 30.0

## Between completions. The site rate-limits these per address.
const POLL_SEC := 3.0

## The token, once the site has issued it and it is written to `listing.json`.
signal enrolled(token: String)

## True once a token is written. The host reads it after [method at_boot] returns.
var done := false

var _server: DotServer
var _path := ""
var _backbone_url := ""
var _http: DotHttp
var _secret := ""
var _expires_ms := 0
var _cvar: DotConVar


## Whether this boot should enroll: no token in the listing file, and not turned off.
static func wanted(listing_path: String) -> bool:
	if OS.get_environment("TMC_ENROLL").to_lower() in ["off", "0", "false", "no"]:
		return false

	return str(_read(listing_path).get("integration_token", "")).strip_edges() == ""


## Enrolls, waiting at most [constant BOOT_WAIT_SEC]. Null when there was nothing to do or
## nothing can be done; otherwise the node, which keeps trying after the wait if it has
## not finished ([member done] says which).
static func at_boot(
	host: Node, server: DotServer, listing_path: String, backbone_url: String, public_address: String
) -> TmcEnroll:
	if not wanted(listing_path):
		return null

	if server == null or server.config == null or not server.config.a2s_enabled:
		DotLog.warn(CHANNEL, "cannot enroll with the site: A2S is off, and the site proves who this server is through it", {
			"fix": "turn A2S on (a2s_enabled), or put an integration token in %s yourself" % listing_path,
		})
		return null

	var node := TmcEnroll.new()
	node.name = "Enroll"
	node._server = server
	node._path = listing_path
	node._backbone_url = str(_read(listing_path).get("backbone_url", backbone_url)).trim_suffix("/")
	host.add_child(node)

	if not await node._start(public_address):
		node.queue_free()
		return null

	var deadline := Time.get_ticks_msec() + int(BOOT_WAIT_SEC * 1000.0)

	while not node.done and node._secret != "" and Time.get_ticks_msec() < deadline:
		await node._complete_once()
		if not node.done and node._secret != "":
			await host.get_tree().create_timer(POLL_SEC).timeout

	if not node.done and node._secret != "":
		DotLog.info(CHANNEL, "still waiting for the site; starting without the credential and asking in the background")
		node._keep_trying.call_deferred()

	return node


func _start(public_address: String) -> bool:
	_http = DotHttp.new()
	_http.name = "Http"
	add_child(_http)

	var host := public_address.strip_edges()
	var ports: Array[int] = []

	# `public_address` may carry the port a player types (behind a proxy it is not the one
	# bound here). Sent as a candidate: it only helps the site FIND the row, never decides
	# where the site looks.
	if host.contains(":") and not host.begins_with("["):
		var tail := host.get_slice(":", host.get_slice_count(":") - 1)
		if tail.is_valid_int():
			ports.append(tail.to_int())
			host = host.substr(0, host.length() - tail.length() - 1)

	var cfg := _server.config
	for p in [cfg.port, cfg.a2s_port if cfg.a2s_port > 0 else cfg.port, cfg.query_port]:
		if p > 0 and not ports.has(p):
			ports.append(p)

	var res := await _http.post_json(_backbone_url + START_PATH, {
		"host": host if host != "" else null,
		"ports": ports.slice(0, 4),
	})

	if not res.ok:
		DotLog.warn(CHANNEL, "the site would not start an enrollment; signed-in players join as guests until this server has a credential", {
			"why": str(res.error),
			"fix": "add and claim this server on the site, then restart -- or put an integration token in %s" % _path,
		})
		return false

	var body: Dictionary = res.value if res.value is Dictionary else {}
	_secret = str(body.get("enrollment", ""))
	var challenge := str(body.get("challenge", ""))

	if _secret == "" or challenge == "":
		DotLog.warn(CHANNEL, "the site's enrollment answer was missing its challenge", {"body": body.keys()})
		return false

	_expires_ms = Time.get_ticks_msec() + 9 * 60 * 1000
	_publish(challenge)

	DotLog.info(CHANNEL, "enrolling with the site", {
		"server_id": body.get("server_id", ""),
		"checked_at": body.get("query_address", ""),
	})
	return true


## The challenge as an A2S rule. `force_set`, because a notify cvar changed the ordinary
## way is announced to every player, and this is nobody's business but the site's.
func _publish(value: String) -> void:
	var console := _server.console
	_cvar = console.find_cvar(RULE)

	if _cvar == null:
		_cvar = console.register_cvar(DotConVar.new(
			RULE, "", "The site's enrollment challenge, while this server proves who it is.",
			DotConVar.FLAG_NOTIFY
		))

	_cvar.force_set(value)


func _complete_once() -> void:
	var res := await _http.post_json(_backbone_url + COMPLETE_PATH, {"enrollment": _secret})

	if not res.ok:
		# 4xx other than "not seen yet" is final: expired, unclaimed, already used.
		DotLog.warn(CHANNEL, "the site refused to finish the enrollment", {"why": str(res.error)})
		_finish()
		return

	var body: Dictionary = res.value if res.value is Dictionary else {}
	var token := str(body.get("token", ""))

	if token == "":
		DotLog.debug(CHANNEL, "the site has not seen the challenge yet", {"why": body.get("code", "")})
		return

	var wrote := _write_token(token)
	_finish()

	if not wrote.ok:
		DotLog.error(CHANNEL, "enrolled, but the credential could not be saved", {"path": _path, "why": str(wrote.error)})
		return

	done = true
	DotLog.info(CHANNEL, "enrolled with the site; this server has its own credential now", {
		"path": _path, "scopes": body.get("scopes", []),
	})
	enrolled.emit(token)


func _keep_trying() -> void:
	while _secret != "" and Time.get_ticks_msec() < _expires_ms and is_inside_tree():
		await get_tree().create_timer(POLL_SEC * 3.0).timeout
		await _complete_once()

	if not done:
		_finish()


## Stops publishing the challenge and forgets the secret, done or not.
func _finish() -> void:
	_secret = ""
	if _cvar != null:
		_cvar.force_set("")


## Adds the token to `listing.json`, keeping whatever else the operator wrote there.
func _write_token(token: String) -> DotResult:
	var data := _read(_path)
	data["integration_token"] = token
	if not data.has("backbone_url"):
		data["backbone_url"] = _backbone_url

	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		return DotResult.fail(DotError.CODE_IO, error_string(FileAccess.get_open_error()))

	f.store_string(JSON.stringify(data, "\t") + "\n")
	f.close()

	# A credential: readable by this server's user and nobody else.
	FileAccess.set_unix_permissions(
		ProjectSettings.globalize_path(_path),
		FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
	)
	return DotResult.success(true)


static func _read(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func describe() -> Dictionary:
	return {"done": done, "waiting": _secret != "", "site": _backbone_url, "listing": _path}
