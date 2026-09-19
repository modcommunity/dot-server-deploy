class_name TmcGameRef
extends RefCounted

## What one entry of the games list means.
##
## [b]One rule, two readers, and they must not drift.[/b] `tools/install_games.gd` decides
## what to FETCH and `TmcHost` decides what to OFFER, and both are handed the same
## `TMC_GAMES` string. A server that installed `gamemann/game-g2gfast01` and then filtered
## its content directory against that same string would find no directory called that,
## report the game as missing, and offer nothing -- having just downloaded it.
##
## This project has shipped that bug in its smallest form twice already (the addon
## repository name, the pack owner table). Here is the third place it could have gone, so
## here is the one function.

## One entry of the games list, taken apart.
##
## [b]Three spellings, and the difference decides where a game comes from.[/b]
##
## [codeblock]
## g2gfast                         a content directory this build already carries
## gamemann/game-g2gfast01         a published pack, latest version
## gamemann/game-g2gfast01@1.2.0   a published pack, that version
## [/codeblock]
##
## The slash is the whole test, and it is safe to test on: a content id is
## `<owner>/<name>` by construction — the site refuses to hand out any other shape,
## because dot-cloud scopes a publisher's signing key with a glob over the id and a
## flattened `owner_name` would let `alice_*` sign for the member called `alice_bob`.
## A directory name cannot contain a slash, so nothing is ambiguous.
##
## `@` splits from the RIGHT. A version cannot contain one and an id can never end with
## one, so the last `@` is the separator even if somebody's name has one in it.
static func parse(raw: String) -> Dictionary:
	var name := raw.strip_edges()
	var version := ""
	var at := name.rfind("@")

	if at > 0:
		version = name.substr(at + 1).strip_edges()
		name = name.substr(0, at).strip_edges()

	# `@latest` is spelled out rather than being the absence of a version, because a
	# panel field that says what it means is worth the four characters -- and because
	# "no version" and "the newest one" are the same request here but are not the same
	# sentence, and somebody reading a config should not have to know that.
	if version == "latest":
		version = ""

	var is_pack := name.contains("/")

	return {
		"raw": raw.strip_edges(),
		"id": name,
		# The directory a descriptor lands in, and the id an operator types at the
		# console. The NAME half of a content id, not the whole thing: `changelevel
		# gamemann/game-g2gfast01` is not something anybody should have to type, and a
		# directory cannot hold a slash anyway.
		"dir": name.get_file() if is_pack else name,
		"version": version,
		"from_origin": is_pack,
	}

## Just the content directory an entry names.
##
## What `TmcHost` needs: a filter is over directories, and the id, the version and the
## owner are all somebody else's business by then.
static func dir_of(raw: String) -> String:
	return str(parse(raw)["dir"])


## Every directory a comma-separated list names, in order, without duplicates.
static func dirs_in(raw: String) -> PackedStringArray:
	var out := PackedStringArray()

	for entry in raw.split(",", false):
		var one := entry.strip_edges()

		if one == "":
			continue

		var dir := dir_of(one)

		if dir != "" and not dir in out:
			out.append(dir)

	return out
