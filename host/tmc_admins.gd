class_name TmcAdmins
extends RefCounted

## `groups.yml` and `permissions.yml`, as a [DotAdminManager] source.
##
## dot-server's permission model is **flags, not roles** — deliberately, because operators
## do not agree on what a "moderator" is, and because a game adds `slay` or `noclip`
## without coordinating with anybody. What an operator writes, just as deliberately, is
## roles: a group with a list of things it may do, and a list of people in it.
##
## This is the translation, and it is the only place the two vocabularies meet.
##
## [b]It is a source, not a replacement.[/b] `DotAdminManager` merges every source rather
## than taking the first match, so a player named here *and* in a site group gets the union
## of both flag sets and the higher immunity. A source that returned "no, and stop looking"
## would silently demote somebody an operator had promoted somewhere else.
##
## Registered by duck type: `lookup()` and `source_name()` are the whole contract, and
## `DotAdminManager.add_source` validates it at registration — so a mistyped source is a
## startup error rather than an absence of permissions discovered during an incident.

const CHANNEL := "tmc.admins"

## Group name -> [PackedStringArray] of flags.
var _group_flags: Dictionary = {}

## Group name -> immunity.
var _group_immunity: Dictionary = {}

## Lower-cased identifier -> {flags, immunity}.
##
## Lower-cased because an operator typing a name into a config file and a player typing one
## into a client will not agree about capitalisation, and a permission that depended on
## that would be a permission that works on Tuesday.
var _users: Dictionary = {}


## Builds a source from the two parsed files.
##
## An unknown group named by a user is a **warning, not a refusal**: it is exactly what a
## typo looks like and exactly what a group removed from `groups.yml` last week looks like,
## and refusing to boot over it leaves a server unmoderated rather than under-moderated.
static func from(groups: Dictionary, users: Dictionary) -> DotResult:
	var source := TmcAdmins.new()

	for name in groups.keys():
		var group_name := String(name)
		var body: Variant = groups[name]

		if not (body is Dictionary):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Group '%s' must be a mapping." % group_name
			)

		var row := body as Dictionary
		var flags := PackedStringArray()

		# `is_root: true` is every flag there is, present and future.
		# [constant DotAdminFlags.ROOT] is what dot-server checks, and expanding it into a
		# list here would silently stop covering a flag added later.
		if bool(row.get("is_root", false)):
			flags.append(DotAdminFlags.ROOT)

		for flag in TmcAdmins._as_list(row.get("permissions", [])):
			flags.append(flag)

		source._group_flags[group_name] = flags
		source._group_immunity[group_name] = int(
			row.get("immunity", 100 if bool(row.get("is_root", false)) else 0)
		)

	for name in users.keys():
		var user := String(name).to_lower()
		var body: Variant = users[name]
		var flags := PackedStringArray()
		var immunity := 0

		if body is Dictionary:
			var row := body as Dictionary
			var group := String(row.get("group", ""))

			if group != "":
				if not source._group_flags.has(group):
					DotLog.warn(CHANNEL, "a user names a group that does not exist", {
						"user": user, "group": group,
					})
				else:
					flags.append_array(source._group_flags[group])
					immunity = int(source._group_immunity[group])

			for flag in TmcAdmins._as_list(row.get("permissions", [])):
				flags.append(flag)

			# An explicit immunity beats the group's, in either direction. An operator who
			# writes one has a reason, and "only upward" would make demoting one person
			# require a whole group.
			if row.has("immunity"):
				immunity = int(row["immunity"])
		else:
			# `gamemann: owner` — the short form, because naming a group is the common case
			# and making it the only form nobody writes would be a config file people
			# resent.
			var group := String(body)

			if source._group_flags.has(group):
				flags.append_array(source._group_flags[group])
				immunity = int(source._group_immunity[group])
			elif group != "":
				DotLog.warn(CHANNEL, "a user names a group that does not exist", {
					"user": user, "group": group,
				})

		source._users[user] = {"flags": flags, "immunity": immunity}

	DotLog.info(CHANNEL, "admins loaded", {
		"groups": source._group_flags.size(), "users": source._users.size(),
	})

	return DotResult.success(source)


## `DotAdminManager`'s duck-typed contract: `lookup(identity) -> DotResult`.
##
## [param identity] is the object dot-server holds for the player — `DotAuthIdentity` on
## an authenticated server, `DotGuestIdentity` without dot-auth — and both carry `uid`,
## `username` and `display_name`. All three are tried, because an operator writes into
## `permissions.yml` whichever of them they know, and asking them to know which one the
## server will match on is asking them to get it wrong.
##
## [b]A failure means "nothing for this player", not an error.[/b] That is
## `DotAdminManager`'s reading of it and it is the normal case for almost everybody.
##
## Note that `DotAdminManager.resolve` returns before consulting any source when a session
## is not authenticated — a guest uid is a random per-device string, so granting anything
## to one grants it to anyone. On a server with no dot-auth the local console is therefore
## the only administrator, which is the correct answer and worth knowing before wondering
## why `permissions.yml` appears to do nothing.
func lookup(identity: Object) -> DotResult:
	if identity == null:
		return DotResult.fail(DotError.CODE_STATE, "No identity.")

	for property in ["uid", "username", "display_name"]:
		var value: Variant = identity.get(property)

		if value == null:
			continue

		var key := String(value).to_lower()

		if key != "" and _users.has(key):
			var row: Dictionary = _users[key]
			return DotResult.success({
				"flags": row["flags"],
				"immunity": row["immunity"],
				"source": source_name(),
			})

	return DotResult.fail(DotError.CODE_STATE, "Not listed.")


func source_name() -> String:
	return "cfg/permissions.yml"


func group_names() -> PackedStringArray:
	var out := PackedStringArray(_group_flags.keys())
	out.sort()
	return out


func user_count() -> int:
	return _users.size()


static func _as_list(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()

	if value is Array:
		for entry in (value as Array):
			var flag := str(entry).strip_edges()

			if flag != "":
				out.append(flag)
	elif str(value).strip_edges() != "":
		out.append(str(value).strip_edges())

	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	for name in group_names():
		out.append("group %-12s %s" % [
			name, " ".join(_group_flags[name]) if not (_group_flags[name] as PackedStringArray).is_empty() else "-"
		])

	for key in _users.keys():
		var row: Dictionary = _users[key]
		out.append("user  %-12s %s (immunity %d)" % [
			key, " ".join(row["flags"]), int(row["immunity"])
		])

	return out
