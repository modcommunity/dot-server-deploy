class_name TmcConfigKeys
extends RefCounted

## The key tables [TmcConfig] reads the `cfg/` files by: which setting lands on which property, and which file belongs to which addon.

## Operator-facing name -> boot config property, for what the console cannot reach. Two vocabularies are paid for deliberately:
## an operator writes `net_port`, GameSpice Server calls it `port`, and the alternative is renaming a published cvar.
const BOOT_KEYS := {
	"net_port": "port",
	"net_bind_ip": "bind_address",
	# dual (WebSocket for browsers + ENet over UDP for native clients, one match),
	# websocket, or enet. See DotServerConfig.transport_mode.
	"net_transport": "transport_mode",
	# ENet's UDP port; 0 is the game port's number, shared with A2S/DQP through a demux.
	"net_enet_port": "enet_port",
	# Empty follows query_bind_ip: behind nginx the UDP side must face the world itself.
	"net_enet_bind_ip": "enet_bind_address",
	"net_enet_share_udp": "enet_share_udp_port",
	"sv_name": "hostname",
	"sv_id": "server_id",
	"sv_maxplayers": "max_players",
	"sv_reserved_slots": "reserved_slots",
	"sv_tickrate": "tickrate",
	"sv_password": "password",
	"rcon_password": "rcon_password",
	"rcon_port": "rcon_port",
	"rcon_allowed": "rcon_allowed_addresses",
	"rcon_websocket": "rcon_websocket",
	"query_enabled": "query_enabled",
	"query_websocket": "query_websocket",
	"query_port": "query_port",
	# The one setting a reverse-proxied server cannot do without: nginx forwards the
	# game's WebSocket and cannot forward UDP, so a query listener sharing
	# `net_bind_ip` binds loopback and no tracker on earth can reach it.
	"query_bind_ip": "query_bind_address",
	"a2s_enabled": "a2s_enabled",
	"a2s_port": "a2s_port",
	"content_manifest_url": "content_manifest_url",
	# dot-server documents this as the one stdin decision that is a real decision, and it was unreachable because YAML is this deployment's only surface.
	# A server whose stdin carries something other than commands needs it, and so does anything running two servers in one process:
	# [DotStdinConsole] is a thread blocked in a read the engine cannot cancel, so the second keeps the process alive.
	"sv_stdin_console": "stdin_console_enabled",
	# And whether a PIPE counts (GameSpice Server 5f46687): off by default, because a reader blocked on a pipe whose writer never closes keeps the process from exiting.
	# TMC's panel talks RCON and neither the Docker image nor the systemd unit gives the server a stdin, so the default stands.
	"sv_stdin_console_pipes": "stdin_console_pipes",
	# log.yml. The level is the one an operator changes most often and the one they most
	# often cannot find: it is not a cvar, because it has to apply before the console
	# exists in order to cover the boot it is being raised to diagnose.
	"log_level": "log_level",
	"log_channels": "log_channel_levels",
	"log_mirror_level": "log_mirror_min_level",
	"log_file": "log_file_enabled",
	"log_dir": "log_directory",
	"log_name": "log_basename",
	"log_json": "log_json",
	"log_max_bytes": "log_max_file_bytes",
	"log_keep": "log_max_files",
}

## Operator-facing name -> netcode config property.
const NET_KEYS := {
	"net_max_bps": "per_client_budget",
	"net_max_pps": "per_client_packet_rate",
	"net_max_update_rate": "snapshot_rate",
	"net_mtu": "mtu",
	"net_interp_buffer": "interpolation_buffer",
	"net_max_entities": "max_entities_per_snapshot",
	# Relevance: who is sent what. The radius is a ceiling on the game's, the far pair replaces it.
	"net_interest_radius": "interest_radius",
	"net_far_every": "far_every",
	"net_far_distance": "far_distance",
	# Replaces the game's value (off unless written): peers spread over the ticks between snapshots.
	"net_stagger_snapshots": "stagger_snapshots",
}

## Operator-facing name -> [code]DotLogConfig[/code] property, only what dot-log adds: the level, channels, mirror threshold and file settings are in [constant BOOT_KEYS]
## already (a server without GameSpice Log has them through GameSpice Core's sink) and are copied across in [method build_log_router]; two lists for one fact is this tree's most repeated bug.
## [code]log_router[/code] is NOT here: it decides whether the router is built, and is handled by name in [method _apply_settings].
const LOG_KEYS := {
	"log_ring": "memory_enabled",
	"log_ring_size": "memory_capacity",
	"log_service": "service",
	"log_env": "env",
	"log_instance": "instance",
	"log_version": "version",
	"log_syslog": "syslog_enabled",
	"log_syslog_host": "syslog_host",
	"log_syslog_port": "syslog_port",
	"log_syslog_tcp": "syslog_tcp",
	"log_syslog_app": "syslog_app",
	"log_syslog_level": "syslog_level",
	"log_remote": "remote_enabled",
	"log_remote_format": "remote_format",
	"log_remote_url": "remote_url",
	"log_remote_token": "remote_token",
	"log_remote_level": "remote_level",
	"log_remote_batch": "remote_batch",
	"log_remote_tags": "remote_tags",
	"log_sentry_dsn": "sentry_dsn",
	"log_redact": "redact_enabled",
	"log_redact_ips": "redact_ips",
	"log_redact_emails": "redact_emails",
	"log_redact_keys": "redact_drop_keys",
	"log_dedupe_sec": "dedupe_window_sec",
	"log_rate_per_channel": "per_channel_rate",
}

## Each addon owns its key table, so this file keeps no second copy that goes stale.
const LAYERED := {
	"security.yml": "dot-server-security",
	"party.yml": "dot-party",
	"replay.yml": "dot-replay",
	"bot_record.yml": "dot-bot-record",
	"matchmaking.yml": "dot-matchmaking",
	"groups.yml": "dot-server",
	"permissions.yml": "dot-server",
	"admin_menu.yml": "dot-menu",
	"log.yml": "dot-log",
	"rcon.yml": "dot-console",
	"auth.yml": "dot-auth",
	"vote.yml": "dot-vote",
	"loading.yml": "dot-core",
	"radio.yml": "dot-radio",
	"trail.yml": "dot-trail",
}

## Key prefix in `server.yml` -> the addon folder that owns it now (`cfg/addons/<addon>/`). Still
## applied from `server.yml` until DotCfgLegacy's cutoff, with one WARN naming the keys.
## `rcon_password` stays where it is: a secret may live in `server.yml` or the addon's folder.
const LEGACY_KEYS := {
	"log_": "dot_log",
	"rcon_": "dot_console",
}
