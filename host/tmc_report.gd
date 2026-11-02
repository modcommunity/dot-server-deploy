class_name TmcReport
extends Node

## Reports this server's own state to its listing on the site.

const CHANNEL := "tmc.listing"

## The reporter, or null when this server has no token.
var backbone: DotBackboneClient = null

var _server: DotServer = null
var _content: TmcContent = null
var _config: DotAuthConfig = null
var _path := ""


## Builds the reporter, or explains why it did not. Never fails the boot: a server that cannot be
## listed is still a server, and an operator who has not created an integration yet has not made a
## mistake.
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
	# The listing borrows dot-auth's config for its backbone URL and token and never authenticates a
	# player, so the strategy means nothing here -- but it is VALIDATED, and the default (`ticket`)
	# demands a server_id and a public key.
	_config.strategy = DotAuthConfig.Strategy.INTROSPECT
	# On by default: the site draws a player's play time from the roster (join, leave, score),
	# and enrollment already grants SERVER_USERS. `report_roster: false` in listing.json opts out.
	_config.report_roster = true

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


## What this server looks like from outside. [method DotServer.to_stats_report] answers everything a
## single-game server has to say. The one field added here is the one only this host knows:
## [code]games[/code], the ids this server can be switched to without anybody reconnecting.
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
