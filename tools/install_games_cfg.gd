extends RefCounted

## What install_games reads out of the server's own configuration: the sign-in site (auth.yml), the
## content origins and the cache ceiling (server.yml). Statics only; install_games preloads it.


## The site an operator already named for sign-in: `backbone_url` in the last auth.yml under [param config_dir], or empty.
## One key for one value, so `--site` and `TMC_SITE_URL` stay overrides, not a second setting.
static func site_from(config_dir: String) -> String:
	var site := ""
	for path in TmcAuth.auth_files(config_dir):
		var parsed := TmcYaml.parse_file(path)
		if parsed.ok:
			var url := str(TmcYaml.at(parsed.value as Dictionary, "backbone_url", "")).strip_edges()
			if url != "":
				site = url
	return site


## `cache_bytes` out of `cfg/server/server.yml` as written, empty when it has none (unlimited).
static func cache_bytes(config_dir: String) -> String:
	var value: Variant = TmcYaml.at(server_yml(config_dir), "cache_bytes", null)
	return "" if value == null else str(value)


## `cfg/server/server.yml` (or the old flat `cfg/server.yml`), parsed; empty when there is none or it does not parse.
static func server_yml(config_dir: String) -> Dictionary:
	# The singular layout keeps it in cfg/server/server.yml; the flat cfg/server.yml is the old one.
	var path := config_dir.path_join("server/server.yml")

	if not FileAccess.file_exists(path):
		path = config_dir.path_join("server.yml")

	if not FileAccess.file_exists(path):
		return {}

	var parsed := TmcYaml.parse_file(path)

	if not parsed.ok:
		DotLog.warn("tmc.install", "could not read the server configuration", {
			"path": path, "why": str(parsed.error),
		})
		return {}

	return parsed.value as Dictionary


## `content_urls` out of `cfg/server.yml`, without loading the whole configuration.
static func bases(config_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var urls: Variant = TmcYaml.at(server_yml(config_dir), "content_urls", null)

	if urls is Array:
		for entry in (urls as Array):
			var url := String(entry).strip_edges()

			if url != "" and not url in out:
				out.append(url)
	elif urls != null:
		var one := String(urls).strip_edges()

		if one != "":
			out.append(one)

	return out
