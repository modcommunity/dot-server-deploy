class_name TmcCloudLimit
extends RefCounted

## How big this server lets its content cache grow: `cache_bytes` in server.yml, `--cache-bytes`, TMC_CACHE_BYTES. 0, the default, is unlimited. A server mounts every map it offers, and dot-cloud never evicts an object mounted content references, so a ceiling below what the offered maps add up to is not a cache policy: it is maps that fail to load ("The content cache is full and everything in it is in use"). dot-cloud's own default (4 GiB) is a player's; a server that wants a ceiling says so here. The disk is the real limit, and every boot logs how much of it is free.

## Where the setting is written, for refusals and for dot-cloud's own quota message (`DotCloudConfig.limit_hint`, dot-cloud API 31).
const WHERE := "cache_bytes in cfg/server/server.yml, --cache-bytes or TMC_CACHE_BYTES"

const _UNITS := {"": 1, "B": 1, "K": 1024, "KB": 1024, "KIB": 1024, "M": 1048576, "MB": 1048576, "MIB": 1048576,
	"G": 1073741824, "GB": 1073741824, "GIB": 1073741824, "T": 1099511627776, "TB": 1099511627776, "TIB": 1099511627776}


## A byte count from the file, the flag or the variable: a whole number of bytes, or one with a binary unit (`20G`, `512 MiB`).
## Empty is the default, 0. Anything else -- negative, fractional, an unknown unit -- refuses boot rather than becoming some other ceiling.
static func parse(raw: Variant) -> DotResult:
	var text := str(raw).strip_edges().to_upper().replace(" ", "")

	if text == "":
		return DotResult.success(0)

	var digits := 0

	while digits < text.length() and text[digits] >= "0" and text[digits] <= "9":
		digits += 1

	var unit := text.substr(digits)

	if digits == 0 or not _UNITS.has(unit):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"cache_bytes is '%s', not a whole number of bytes (0 for unlimited, or with K, M, G or T)" % str(raw).strip_edges(),
			WHERE
		)

	return DotResult.success(text.substr(0, digits).to_int() * int(_UNITS[unit]))


## [param raw] as `--print-config` shows it: "unlimited", a size, or why it would refuse boot.
static func describe(raw: Variant) -> String:
	var limit := parse(raw)

	if not limit.ok:
		return str(limit.error)

	return "unlimited" if int(limit.value) == 0 else DotPaths.format_bytes(int(limit.value))


## Puts [param bytes] on a server's cloud config before it starts and says, once, what the ceiling is and how much disk it has to fill.
## A `cache_bytes` in the cloud config file ([param config_file], the client's) or DOT_CLOUD_CACHE_BYTES still wins (dot-cloud applies those at start), and the line says so.
static func apply(cloud_config: Object, bytes: int, channel: String, config_file: String = "") -> void:
	cloud_config.cache_bytes = bytes

	# dot-cloud API 31 names this in a quota refusal; an older dot-cloud has no such property and gets nothing.
	if "limit_hint" in cloud_config:
		cloud_config.limit_hint = WHERE

	var cache_dir := ProjectSettings.globalize_path(str(cloud_config.cache_dir))
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var dir := DirAccess.open(cache_dir)
	var free := int(dir.get_space_left()) if dir != null else -1
	var fields := {
		"limit": DotPaths.format_bytes(bytes) if bytes > 0 else "unlimited",
		"disk_free": DotPaths.format_bytes(free) if free >= 0 else "unknown",
		"dir": cache_dir,
		"set_by": WHERE,
	}
	var overridden := _file_override(config_file)

	if overridden != "":
		fields["overridden_by"] = overridden

	if OS.get_environment("DOT_CLOUD_CACHE_BYTES") != "":
		fields["overridden_by"] = "DOT_CLOUD_CACHE_BYTES"

	DotLog.info(channel, "content cache limit", fields)


## The cloud config file's own `cache_bytes`, which dot-cloud applies over this one, as "<file> cache_bytes=<n>"; empty when it has none.
static func _file_override(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))

	if parsed is Dictionary and (parsed as Dictionary).has("cache_bytes"):
		return "%s cache_bytes=%s" % [path, str((parsed as Dictionary)["cache_bytes"])]

	return ""
