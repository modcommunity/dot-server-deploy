class_name TmcReport
extends Node

## Reports this server's own state to its listing on the site.
##
## [b]Why this exists at all.[/b] The other way for a listing to know a server is up is
## for a scanner to send it a query packet, and there are three ways that fails for a
## server like this one and only one of them is fixable from here:
##
## - A server behind a reverse proxy has its game port on loopback, and a reverse proxy
##   forwards a WebSocket and not UDP. That one is fixed — [code]query_bind_ip[/code].
## - A scanner will not query a private address, and it is right not to: dialling
##   whatever a hostname resolves to is a request-forgery primitive aimed at somebody's
##   own network. A development or LAN deployment is therefore unscannable by design.
## - A query packet is lossy, rate-limited, and truncates a player list.
##
## A server that reports itself has none of those problems, and it is the only thing that
## knows two facts a packet cannot carry: how many of its players are bots, and
## [b]which games it can run[/b] — which for a multi-game server is the interesting half,
## because the game it happens to be running right now is not what it is.
##
## [b]The token is a path, never a value.[/b] [code]DotAuthConfig.sensitive_keys[/code]
## refuses [code]integration_token[/code] from the environment and from argv, because both
## are readable by other processes and end up in [code]ps[/code] output and pasted bug
## reports. So this takes a file, and the file is per-server: several servers share one
## [code]cfg/[/code] directory here and each has its own listing.
##
## Absent a token nothing here runs and the server is simply not listed, which is the
## correct behaviour for a LAN game and for every test.

const CHANNEL := "tmc.listing"

## The reporter, or null when this server has no token.
var backbone: DotBackboneClient = null

var _server: DotServer = null
var _content: TmcContent = null
var _config: DotAuthConfig = null
var _path := ""


## Builds the reporter, or explains why it did not.
##
## Never fails the boot: a server that cannot be listed is still a server, and an
## operator who has not created an integration yet has not made a mistake.
static func install(
	host: Node, server: DotServer, content: TmcContent, config_path: String
) -> TmcReport:
	var node := TmcReport.new()
	node.name = "Listing"
	node._server = server
	node._content = content
	node._path = config_path
	host.add_child(node)
	node._build()

	return node


func _build() -> void:
	_config = DotAuthConfig.new()

	if _path == "" or not FileAccess.file_exists(_path):
		DotLog.info(CHANNEL, "no listing configuration; this server will not be listed", {
			"path": _path
		})
		return

	var loaded := _config.load_layered(_path)

	if not loaded.ok:
		DotLog.warn(CHANNEL, "could not read the listing configuration", {
			"path": _path, "error": str(loaded.error)
		})
		return

	if _config.integration_token.strip_edges() == "":
		DotLog.info(CHANNEL, "no integration token; this server will not be listed", {
			"path": _path
		})
		return

	backbone = DotBackboneClient.new()
	backbone.name = "Backbone"
	backbone.config = _config
	# Callables rather than pushed state, because a report is a snapshot of NOW and not
	# of the last time somebody joined.
	backbone.stats_provider = stats_report
	backbone.roster_provider = roster_report
	add_child(backbone)

	var started := backbone.start()

	if not started.ok:
		DotLog.warn(CHANNEL, "listing reports did not start", {"error": str(started.error)})
		remove_child(backbone)
		backbone.queue_free()
		backbone = null
		return

	DotLog.info(CHANNEL, "reporting to the site listing", {
		"url": _config.backbone_url,
		"every": _config.report_interval_sec,
		"games": _content.ids().size() if _content != null else 0,
	})


## What this server looks like from outside.
##
## [method DotServer.to_stats_report] answers everything a single-game server has to say.
## The one field added here is the one only this host knows: [code]games[/code], the ids
## this server can be switched to without anybody reconnecting. A listing that files a
## multi-game server under whatever it is running this minute is a listing that moves the
## server every time somebody votes.
func stats_report() -> Dictionary:
	var report := _server.to_stats_report()

	if _content != null:
		report["games"] = _content.ids()

	return report


func roster_report() -> Array:
	return _server.to_roster_report()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if backbone == null:
		out.append("listing      not reporting (no integration token)")
		return out

	out.append("listing      %s every %.0fs" % [
		_config.backbone_url, _config.report_interval_sec
	])
	out.append("games        %s" % ", ".join(_content.ids()) if _content != null else "")

	return out
