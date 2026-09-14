class_name TmcAuth
extends RefCounted

## `cfg/auth.yml` turned into a running [DotAuthServer].
##
## [b]The file was parsed and handed to nothing.[/b] [member TmcConfig.auth] has said
## "handed to TmcAuth, which is the only thing that reads it" since it was written, and
## TmcAuth did not exist — this family's own detector for a setting nothing reads, sitting
## in a doc comment naming the reader. What it cost is the whole authenticated half of the
## server:
##
## [codeblock]
## inf client  server challenge auth=none hostname="TMC Demo - G2g Fast01"
## WRN platform could not resolve a profile (guest:4fb3eb7b4a9912b7)
## [/codeblock]
##
## `DotServer._auth_strategy_name()` answers "none" when no `dot_auth_server` service is
## registered, the client then attaches no credential because nothing asked for one, and
## everybody — including the site's owner, signed in, with their name showing in the
## menu — arrives as a guest. `DotAdminManager` refuses permissions to an unauthenticated
## session on purpose (a guest uid is a random per-device string), so `cfg/permissions.yml`
## did nothing and the local console was the only administrator. All of that is correct
## behaviour for a server with no authentication; none of it was a choice anybody made.
##
## [b]Off unless the file says otherwise.[/b] A deployment with no `auth.yml`, or one
## carrying the pre-existing example, behaves exactly as it did before this existed.
## Turning authentication on changes who may administer a server, which is not a thing to
## acquire by upgrading.

const CHANNEL := "tmc.auth"

## YAML `strategy:` values, to [enum DotAuthConfig.Strategy].
const STRATEGIES := {
	"ticket": DotAuthConfig.Strategy.TICKET,
	"introspect": DotAuthConfig.Strategy.INTROSPECT,
	"local": DotAuthConfig.Strategy.LOCAL,
	"anonymous": DotAuthConfig.Strategy.ANONYMOUS,
}


## The auth server this configuration asks for, or null when it asks for none.
##
## [param auth] is [member TmcConfig.auth]; [param config_dir] is where relative paths in
## it resolve, so an operator writes `issuer.pub.pem` and not an absolute path that only
## works on the box it was typed on.
##
## Fails only on a configuration that is WRONG. Absent and disabled are both success with
## a null value, because a server without authentication is a supported deployment and the
## simplest one there is.
static func build(auth: Dictionary, config_dir: String) -> DotResult:
	if auth.is_empty():
		return DotResult.success(null)

	# [b]The shape this file used to have, which named a shared secret.[/b] It is still
	# on disk wherever somebody copied the old example, and reading it as "disabled" and
	# saying nothing is how an operator spends an afternoon on a JWT secret that
	# configures nothing. Named rather than tolerated.
	if auth.has("backend") and not auth.has("strategy"):
		DotLog.warn(CHANNEL, "auth.yml is the old example and configures nothing", {
			"fix": "see cfg.example/auth.yml: strategy, server_id and issuer_public_key",
		})

	if not bool(auth.get("enabled", false)):
		DotLog.info(CHANNEL, "authentication is off; everybody is a guest", {
			"consequence": "cfg/permissions.yml cannot apply; the console is the only admin",
		})
		return DotResult.success(null)

	var named := str(auth.get("strategy", "ticket")).to_lower()

	if not STRATEGIES.has(named):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"auth.yml: unknown strategy '%s'." % named,
			"expected one of: %s" % ", ".join(PackedStringArray(STRATEGIES.keys()))
		)

	var cfg := DotAuthConfig.new()
	cfg.strategy = STRATEGIES[named]
	cfg.server_id = str(auth.get("server_id", ""))
	cfg.allow_guests = bool(auth.get("allow_guests", false))

	if auth.has("backbone_url"):
		cfg.backbone_url = str(auth["backbone_url"])

	# [b]A PATH in the YAML and a PEM on the config.[/b] `ticket_public_key` is the key
	# itself, and a multi-line PEM inside a YAML value is the kind of thing that survives
	# one edit and not two. The file also keeps the key out of anything that prints the
	# configuration.
	var key_file := str(auth.get("issuer_public_key_file", ""))

	if key_file != "":
		var path := key_file if key_file.is_absolute_path() else config_dir.path_join(key_file)

		if not FileAccess.file_exists(path):
			return DotResult.fail(
				DotError.CODE_IO,
				"auth.yml: the issuer public key is not there.",
				path
			)

		cfg.ticket_public_key = FileAccess.get_file_as_string(path)

		if not cfg.ticket_public_key.contains("PUBLIC KEY"):
			# [b]A PRIVATE key here would verify and mint.[/b] Every operator holding one
			# could forge any player's identity, which is the single thing the ticket
			# design exists to prevent -- so it is worth refusing by name rather than
			# letting it work.
			return DotResult.fail(
				DotError.CODE_INVALID,
				"auth.yml: that is not a public key.",
				"%s -- an operator holds the issuer's PUBLIC half and nothing else" % path
			)

	var accounts := str(auth.get("local_accounts_file", ""))

	if accounts != "":
		cfg.local_accounts_path = accounts if accounts.is_absolute_path() \
			else config_dir.path_join(accounts)

	var valid := cfg.validate()

	if not valid.ok:
		return valid.wrap("auth.yml is incomplete")

	var node := DotAuthServer.new()
	node.name = "Auth"
	node.config = cfg
	# Empty, not the exported default. `DotAuthServer` layers a JSON file over the config
	# it was handed, and its default points into `user://` -- a file no operator of this
	# tool writes, in a directory they would not think to look in, silently outranking the
	# YAML that is the documented surface.
	node.config_file = ""

	DotLog.info(CHANNEL, "authentication is on", {
		"strategy": named,
		"server_id": cfg.server_id,
		"guests": cfg.allow_guests,
	})

	return DotResult.success(node)
