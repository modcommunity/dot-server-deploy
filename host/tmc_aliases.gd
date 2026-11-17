class_name TmcAliases
extends RefCounted

## The alias table of [TmcConfig]: three layers (addon defaults, the boot game, the server owner) merged into one `{alias: {target, source, layer}}` dictionary the caller owns.


## One layer's text -> {"set": {alias: {"target", "line"}}, "remove": [{"name", "line"}], "errors": PackedStringArray}.
## Syntax, the same in every layer: one `alias_name: target` per line (`#` starts a comment, quotes are optional), and the reserved `remove: name` or `remove: [a, b]` to drop an alias an earlier layer made.
## Writing a name an earlier layer already has REMAPS it. A file that cannot be understood is reported with `path:line`, never skipped: an alias that silently did not exist is a setting that silently did nothing.
static func parse_text(text: String, path: String) -> Dictionary:
	var out := {"set": {}, "remove": [], "errors": PackedStringArray()}
	var errors: PackedStringArray = out["errors"]
	var word_re := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_.]*$")
	var number := 0
	for raw in text.split("\n"):
		number += 1
		var line := raw.strip_edges()
		var hash_at := line.find(" #")
		if line.begins_with("#"):
			line = ""
		elif hash_at >= 0:
			line = line.substr(0, hash_at).strip_edges()
		if line == "":
			continue
		var colon := line.find(":")
		if colon <= 0:
			errors.append("%s:%d: expected `alias_name: target`, got `%s`" % [path, number, line])
			continue
		var alias_name := line.substr(0, colon).strip_edges().trim_prefix("\"").trim_suffix("\"")
		var target := line.substr(colon + 1).strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges()
		if alias_name == "remove":
			var inner := target.trim_prefix("[").trim_suffix("]")
			for piece in inner.split(","):
				var gone := piece.strip_edges().trim_prefix("\"").trim_suffix("\"")
				if gone != "":
					(out["remove"] as Array).append({"name": gone, "line": number})
			continue
		if word_re.search(alias_name) == null:
			errors.append("%s:%d: `%s` is not a usable alias name (letters, digits, _ and . only)" % [path, number, alias_name])
			continue
		if target == "":
			errors.append("%s:%d: alias `%s` has no target" % [path, number, alias_name])
			continue
		if (out["set"] as Dictionary).has(alias_name):
			errors.append("%s:%d: alias `%s` is defined twice in this file (first on line %d)" % [path, number, alias_name, (out["set"][alias_name] as Dictionary)["line"]])
			continue
		(out["set"] as Dictionary)[alias_name] = {"target": target, "line": number}
	return out


## Merges one layer into `aliases`: removals first, then additions and remaps. Layers are applied in order (addon defaults, game, server), so a later one overrides an earlier one.
## Returns the errors of this layer, already logged as ERR lines naming file and line.
static func merge_layer(aliases: Dictionary, layer: String, path: String, text: String) -> PackedStringArray:
	var parsed := parse_text(text, path)
	var errors: PackedStringArray = parsed["errors"]
	for removal: Dictionary in parsed["remove"]:
		if aliases.has(removal["name"]):
			aliases.erase(removal["name"])
		else:
			DotLog.warn(TmcConfig.CHANNEL, "%s:%d: remove: `%s` is not an alias an earlier layer made" % [path, removal["line"], removal["name"]])
	for alias_name: String in parsed["set"]:
		var entry: Dictionary = parsed["set"][alias_name]
		var first := String(entry["target"]).split(" ")[0]
		if first == alias_name:
			errors.append("%s:%d: alias `%s` points at itself" % [path, entry["line"], alias_name])
			continue
		if alias_name in TmcConfig.HOST_KEYS:
			errors.append("%s:%d: alias `%s` would shadow the setting of that name" % [path, entry["line"], alias_name])
			continue
		aliases[alias_name] = {"target": entry["target"], "source": "%s:%d" % [path, entry["line"]], "layer": layer}
	# Chains and loops, over the table as it now stands: an alias must name a real target, never another alias.
	for alias_name: String in aliases:
		var entry2: Dictionary = aliases[alias_name]
		var first2 := String(entry2["target"]).split(" ")[0]
		if aliases.has(first2) and String(entry2["layer"]) == layer:
			errors.append("%s: alias `%s` points at the alias `%s`; name the real target (chains and loops are refused)" % [entry2["source"], alias_name, first2])
	for message in errors:
		DotLog.error(TmcConfig.CHANNEL, message)
	return errors


## Layer 1, the defaults that ship: `host/aliases.yml` and every `aliases.yml` an addon carries (`res://addons/*/aliases.yml`). Layer 3, the owner's `cfg/server/alias.yml`, is `TmcConfig._load_aliases`.
static func default_layers(aliases: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var paths: Array[String] = ["res://host/aliases.yml"]
	var dir := DirAccess.open("res://addons")
	if dir != null:
		var names := Array(dir.get_directories())
		names.sort()
		for addon: String in names:
			paths.append("res://addons/%s/aliases.yml" % addon)
	for path in paths:
		if FileAccess.file_exists(path):
			errors.append_array(merge_layer(aliases, "addon", path, FileAccess.get_file_as_string(path)))
	return errors


## Effective aliases as lines, `name -> target  [layer, source]`, for the `aliases` command and the boot report.
static func lines_of(aliases: Dictionary) -> PackedStringArray:
	var names := Array(aliases.keys())
	names.sort()
	var out := PackedStringArray()
	for alias_name: String in names:
		var entry: Dictionary = aliases[alias_name]
		out.append("%-20s -> %s    [%s: %s]" % [alias_name, entry["target"], entry["layer"], entry["source"]])
	return out


## After the console is up: every alias target must be a real setting, command or cvar, and no alias may shadow one. Failures are ERR lines naming the file and line, and entries in the returned `unknown`.
## The valid ones are registered on the console too, so the alias works at a prompt and over RCON as well as in a file. Returns `{failures: int, unknown: PackedStringArray}`.
static func check(aliases: Dictionary, console: DotConsole) -> Dictionary:
	var failures := 0
	var unknown := PackedStringArray()
	for alias_name: String in aliases:
		var entry: Dictionary = aliases[alias_name]
		var first := String(entry["target"]).split(" ")[0]
		var problem := ""
		if console.find_cvar(alias_name) != null or console.find_command(alias_name) != null:
			problem = "alias `%s` shadows the console name of the same name" % alias_name
		elif not (first in TmcConfig.HOST_KEYS or TmcConfigKeys.LOG_KEYS.has(first) or TmcConfigKeys.BOOT_KEYS.has(first) or TmcConfigKeys.NET_KEYS.has(first)
				or console.find_cvar(first) != null or console.find_command(first) != null):
			problem = "alias `%s` points at `%s`, which is not a setting, cvar or command this server has" % [alias_name, first]
		if problem != "":
			DotLog.error(TmcConfig.CHANNEL, "%s: %s" % [entry["source"], problem])
			unknown.append("%s: %s" % [entry["source"], problem])
			if String(entry["layer"]) != "game":
				failures += 1
			continue
		if console.has_method("set_alias") and (console.find_command(first) != null or console.find_cvar(first) != null):
			console.set_alias(alias_name, String(entry["target"]))
	return {"failures": failures, "unknown": unknown}
