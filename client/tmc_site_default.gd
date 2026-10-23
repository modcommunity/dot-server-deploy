class_name TmcSiteDefault
extends RefCounted

## The site a hand-started shell lists servers from, when nobody named one.
##
## A game's server browser lists a site only when `--browser-backbone-url` or
## `DOT_BROWSER_BACKBONE_URL` names it (dot-browser's layered config). tmc-app passes the
## flag, but a shell started by hand has no app, and a web build has neither argv nor
## environment, so both listed nothing. The shell already ships the site's origin in
## `client/auth.json`, so it publishes that as the environment variable, which every game's
## browser reads without knowing the shell exists.
##
## [b]Why not leave the web to the page's origin.[/b] The game origin is a different
## registrable domain from the site on purpose (docs/web-client.md), and a published game
## origin is a static bucket that answers `/api/...` with 403, so "same origin as the page"
## lists nothing there. The shipped file is the one place the site is written down.
##
## Anything an operator or player set wins: argv, the environment, and (web) `?backbone=`.

const ENV_KEY := "DOT_BROWSER_BACKBONE_URL"
const ARG_PREFIX := "--browser-backbone-url"


## The origin to publish, or "" when something already names a site or the file names none.
## Pure, so a suite can ask without touching the process environment.
static func resolve(auth_text: String, env_value: String, argv: PackedStringArray, query: String) -> String:
	if env_value.strip_edges() != "" or query.strip_edges() != "":
		return ""

	for arg in argv:
		if arg == ARG_PREFIX or arg.begins_with(ARG_PREFIX + "="):
			return ""

	if auth_text.strip_edges() == "":
		return ""

	var parsed: Variant = JSON.parse_string(auth_text)
	if not (parsed is Dictionary):
		return ""

	var url := str((parsed as Dictionary).get("backbone_url", "")).strip_edges().rstrip("/")
	return url if url.begins_with("http://") or url.begins_with("https://") else ""


## The audiences in the site's `play/first-party` answer, as a PackedStringArray, or a
## failure when the answer is not that shape (the caller keeps the shipped list).
static func first_party_from(answer: Variant) -> DotResult:
	var list: Variant = (answer as Dictionary).get("audiences") if answer is Dictionary else null
	if not (list is Array):
		return DotResult.fail(DotError.CODE_PARSE, "The site sent no first-party server list.")

	var out := PackedStringArray()
	for entry in list:
		if DotAuthConfig.is_audience(str(entry)):
			out.append(str(entry))
	return DotResult.success(out)


## Publishes the shipped site to the process environment. Returns what it set, or "".
static func apply(auth_path: String) -> String:
	if not FileAccess.file_exists(auth_path):
		return ""

	var query := DotWeb.query_param("backbone") if DotPlatform.is_web() else ""
	var url := resolve(
		FileAccess.get_file_as_string(auth_path),
		OS.get_environment(ENV_KEY),
		OS.get_cmdline_user_args(),
		query
	)

	if url != "":
		OS.set_environment(ENV_KEY, url)
		DotLog.info("tmc.shell", "server browsers list the site from client/auth.json", {"site": url})

	return url
