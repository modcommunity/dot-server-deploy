class_name TmcYaml
extends RefCounted

## The server's name for dot-core's [DotYaml], the family's one YAML subset reader.
##
## Kept as a wrapper rather than replaced at every call site so TmcConfig, TmcContent,
## install_games and the rest keep one name for "read an operator's file", and so a second
## parser cannot grow back here. The subset, what it refuses (anchors, tags, block scalars,
## an unquoted value starting with `*`, flow mappings, duplicate keys) and the reasons are
## documented on [DotYaml]; change them there.

## Longest line accepted, in characters. Mirrors [constant DotYaml.MAX_LINE].
const MAX_LINE := DotYaml.MAX_LINE

## Deepest nesting accepted. Mirrors [constant DotYaml.MAX_DEPTH].
const MAX_DEPTH := DotYaml.MAX_DEPTH


## Parses YAML text into a [Dictionary]. See [method DotYaml.parse].
static func parse(text: String, source: String = "<string>") -> DotResult:
	return DotYaml.parse(text, source)


## Parses a file; a missing file is a failure. See [method DotYaml.parse_file].
static func parse_file(path: String) -> DotResult:
	return DotYaml.parse_file(path)


## Fetches a nested value by a dotted path. See [method DotYaml.at].
static func at(tree: Dictionary, path: String, fallback: Variant = null) -> Variant:
	return DotYaml.at(tree, path, fallback)
