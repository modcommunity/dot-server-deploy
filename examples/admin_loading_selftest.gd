extends Node

## The admin menu and the loading screen, both halves, without a server.

const CHECKS := 224

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var console: DotConsole = null

## Every stand-in command that ran: [name, args].
var calls: Array = []

## What the menu sent: [session, page].
var sent: Array = []

## What the admin was told.
var replies := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("admin menu and loading screen")

	_build_console()
	_test_menu_config()
	_test_menu_visibility()
	_test_menu_flow()
	await _test_menu_info_and_warn()
	_test_menu_bounds()
	_test_menu_fun()
	_test_menu_layers()
	_test_review_fixes()
	_test_panel()
	_test_loading_server()
	_test_loading_client()
	_test_shell_version()
	_test_shell_style()
	await _test_loading_fetch()
	await AdminLoadingCover.new(self)._test_cover_gate()
	await AdminLoadingCover.new(self)._test_cover_draw_budget()
	await AdminLoadingCover.new(self)._test_cover_contract()
	await AdminLoadingCover.new(self)._test_cover_fallback()
	await _test_slice_preload()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition



func _build_console() -> void:
	console = DotConsole.new()
	console.log_commands = false
	add_child(console)
	for spec in [
		["kick", "kick"], ["ban", "ban"], ["mute", "mute"], ["gag", "mute"],
		["unmute", "mute"], ["slay", "slay"], ["say", "chat"], ["quit", "root"],
		["changelevel", "changemap"],
	]:
		var name: String = spec[0]
		console.command(name, func(ctx: DotCmdContext) -> void:
			calls.append([name, Array(ctx.args)]), "", spec[1]
		).with_chat()
	# A map change a game refuses to take from chat: the menu must not offer it.
	console.command("map", func(ctx: DotCmdContext) -> void:
		calls.append(["map", Array(ctx.args)]), "", "changemap"
	).no_chat()


func _session(userid: int, name: String, perms: Array, immunity: int = 0) -> DotClientSession:
	var s := DotClientSession.new(userid, userid + 100)
	s.display_name = name
	s.permissions = PackedStringArray(perms)
	s.immunity = immunity
	s.address = "203.0.113.%d" % userid
	return s


func _menu(tree: Dictionary, people: Array) -> TmcAdminMenu:
	var menu := TmcAdminMenu.new().configure(tree)
	menu.console = console
	menu.sessions_fn = func() -> Array: return people
	menu.send_fn = func(session: DotClientSession, page: Dictionary) -> bool:
		sent.append([session, page])
		return true
	menu.games_fn = func() -> Array: return [["fc", "Fatal Contact"], ["airdrift", "Surf"]]
	menu.maps_fn = func() -> Array: return [["surf_mesa", "Mesa"]]
	add_child(menu)
	return menu


func _ctx(session: DotClientSession, args: Array = []) -> DotCmdContext:
	return session.make_context("admin_menu", PackedStringArray(args), DotCmdContext.Source.CHAT,
		func(line: String) -> void: replies.append(line))


func _last_page() -> Dictionary:
	return sent.back()[1] if not sent.is_empty() else {}


func _labels(page: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for row in page.get("rows", []):
		out.append(str(row["label"]))
	return out


func _go_of(page: Dictionary, label: String) -> String:
	for row in page.get("rows", []):
		if str(row["label"]) == label:
			return str(row.get("go", ""))
	return ""


func _nav(menu: TmcAdminMenu, who: DotClientSession, path: String) -> void:
	menu.handle(_ctx(who), DotConsole.tokenize(path))



func _test_menu_config() -> void:
	_section("admin_menu.yml")

	var parsed := TmcYaml.parse_file("res://cfg.example/addon/dot_menu/admin_menu.yml")
	_check(parsed.ok, "the shipped admin_menu.yml parses", str(parsed.error) if not parsed.ok else "")
	var shipped := TmcAdminMenu.new().configure(parsed.value if parsed.ok else {})
	_check(shipped.problems.is_empty(), "and configures with nothing to report", ", ".join(shipped.problems))
	_check(shipped.categories.keys() == ["players", "fun", "powers", "teleport", "server"] and shipped.items.has("warn"),
		"the default layout is the built-in one, warn included", str(shipped.categories.keys()))
	shipped.free()

	var tree := TmcYaml.parse("""
admin_menu_title: "Staff"
admin_menu_after_run: sideways
items:
  kick:
    label: "Boot"
  slap:
    enabled: false
  rules:
    label: "Rules"
    command: "say Read the rules"
  broken:
    command: "kick {player}"
    steps: [player, nonsense]
  early_text:
    command: "say {text} {player}"
    steps: [text, player]
lists:
  duration:
    options: [1h, 1d, 0]
""", "<test>")
	var menu := TmcAdminMenu.new().configure(tree.value)
	_check(menu.title == "Staff" and menu.after_run == "close",
		"settings apply, and a bad after_run is refused back to close", menu.after_run)
	_check(String(menu.items["kick"]["label"]) == "Boot" and String(menu.items["kick"]["command"]).begins_with("kick {player}"),
		"an item merges by key: a new label keeps the built-in command")
	_check(not menu.items.has("slap"), "enabled: false takes a built-in off the menu")
	_check((menu.categories.get("other", {}).get("items", PackedStringArray()) as PackedStringArray).has("rules"),
		"an added item placed nowhere lands under Other")
	_check(not menu.items.has("broken") and Array(menu.problems).any(func(p: String) -> bool: return p.contains("nonsense")),
		"a step that is neither built in nor a list disables the item and says so")
	_check(not menu.items.has("early_text"), "a text step that is not the last one is refused")
	_check(Array(menu.problems).any(func(p: String) -> bool: return p.contains("after_run")),
		"and the bad after_run is reported")
	var durations: Array = menu.lists["duration"]["options"]
	_check(durations.size() == 3 and durations[0]["label"] == "1 hour" and durations[1]["label"] == "1 day" and durations[2]["label"] == "Permanent",
		"duration options are labelled the way a person reads them", str(durations))
	_check(TmcAdminMenu.human_duration(90) == "1 minute 30 seconds" and TmcAdminMenu.human_duration(30) == "30 seconds",
		"and seconds read as words", TmcAdminMenu.human_duration(90))
	menu.free()

	var replaced := TmcAdminMenu.new().configure(TmcYaml.parse("""
categories:
  mods:
    title: "Moderation"
    items: [kick, warn, nothing_like_this]
""", "<test>").value)
	_check(replaced.categories.keys() == ["mods"] and Array(replaced.categories["mods"]["items"]) == ["kick", "warn"],
		"a categories block replaces the layout whole", str(replaced.categories))
	_check(Array(replaced.problems).any(func(p: String) -> bool: return p.contains("nothing_like_this")),
		"and naming an item that does not exist is reported")
	replaced.free()
	_done()


func _test_menu_visibility() -> void:
	_section("what each admin sees")

	var mod := _session(1, "Mod", ["kick"], 10)
	var owner := _session(2, "Owner", ["root"], 99)
	var player := _session(3, "Player", [], 0)
	var menu := _menu({}, [mod, owner, player])
	menu.register_commands()

	_check(console.find_command("warn") != null and console.find_command("admin") != null,
		"/admin and warn are registered (nothing here had a warn)")

	sent.clear()
	menu._cmd_open(_ctx(mod))
	var page := _last_page()
	var labels := _labels(page)
	_check(labels.has("Kick") and labels.has("Warn") and labels.has("Player info"),
		"a moderator with kick sees kick, warn and info", ", ".join(labels))
	_check(not labels.has("Ban") and not labels.has("Slay"),
		"and nothing they hold no flag for", ", ".join(labels))
	_check(str(page.get("title", "")) == "Player commands",
		"one category with anything in it opens directly", str(page.get("title")))

	sent.clear()
	menu._cmd_open(_ctx(owner))
	page = _last_page()
	_check(_labels(page) == PackedStringArray(["Player commands", "Fun commands", "Server commands"]) and str(page["path"]) == "root",
		"root sees every category it can use, on a page with a path of its own", str(page))
	_nav(menu, owner, "c:server")
	labels = _labels(_last_page())
	_check(labels.has("Announce") and labels.has("Change game"),
		"the server category lists what exists", ", ".join(labels))
	_check(not labels.has("Change map"),
		"a map command that refuses chat is not offered, even to root", ", ".join(labels))
	_nav(menu, owner, "c:fun")
	labels = _labels(_last_page())
	_check(not labels.has("Freeze") and labels.has("Slay"),
		"a game's live tool shows only when the game registered it", ", ".join(labels))

	replies.clear()
	sent.clear()
	menu._cmd_open(_ctx(player))
	_check(sent.is_empty() and replies.size() == 1 and replies[0].contains("nothing"),
		"a player with no flags is told so and sent no page", str(replies))

	var console_ctx := DotCmdContext.console("admin", PackedStringArray())
	console_ctx.reply_sink = func(line: String) -> void: replies.append(line)
	replies.clear()
	menu._cmd_open(console_ctx)
	_check(replies.size() == 1 and replies[0].contains("player's screen"),
		"from the server console it explains rather than failing", str(replies))

	menu.queue_free()
	await_free()
	_check(console.find_command("admin") == null and console.find_command("warn") == null,
		"its commands go with it")
	_done()


func await_free() -> void:
	# queue_free'd menus leave their commands until _exit_tree; free now for the next section.
	for child in get_children():
		if child is TmcAdminMenu and child.is_queued_for_deletion():
			remove_child(child)
			child.free()


func _test_menu_flow() -> void:
	_section("choosing, all the way to a command")

	var admin := _session(1, "Admin", ["kick", "ban"], 50)
	var bob := _session(2, "Bob", [], 0)
	var carol := _session(3, "Carol", ["kick"], 99)
	var people := [admin, bob, carol]
	var menu := _menu({}, people)

	sent.clear()
	_nav(menu, admin, "i:kick")
	var page := _last_page()
	var labels := _labels(page)
	_check(labels.size() == 1 and labels[0] == "Bob (#2)",
		"the player list is who this admin outranks, and not themselves", ", ".join(labels))
	_check(_go_of(page, "Bob (#2)") == "i:kick #2", "a player row's path is the item and the userid")

	_nav(menu, admin, "i:kick #2")
	page = _last_page()
	labels = _labels(page)
	_check(labels[0] == "Spamming" and labels[labels.size() - 1] == "Custom…",
		"the reason step lists the reasons and a custom row last", ", ".join(labels))
	_check(str(page["subtitle"]).begins_with("Bob"), "and says who it is about", str(page["subtitle"]))

	calls.clear()
	sent.clear()
	_nav(menu, admin, "i:kick #2 1")
	_check(calls.size() == 1 and calls[0] == ["kick", ["#2", "Spamming"]],
		"the last choice runs `kick #2 Spamming` as the admin", str(calls))
	_check(not sent.is_empty() and (_last_page() as Dictionary).is_empty(), "and closes the menu")

	calls.clear()
	_nav(menu, admin, "i:kick #2 t:being \"rude\"; quit")
	# The console's tokenizer has already eaten the quotes by the time the menu sees them;
	# what matters is that what is left is one argument and the semicolon ended nothing.
	_check(calls.size() == 1 and calls[0][0] == "kick" and calls[0][1] == ["#2", "being rude, quit"],
		"typed text is ONE argument, with no quote or semicolon to break out of it", str(calls))

	calls.clear()
	_nav(menu, admin, "i:ban #2 4 1")
	page = _last_page()
	_check(calls.is_empty() and _labels(page).has("Yes, do it"),
		"a ban asks first", str(_labels(page)))
	_check(_go_of(page, "Yes, do it") == "y:ban #2 4 1" and _labels(page)[0] == "ban #2 1d Spamming",
		"showing the line it will run", str(page["rows"]))
	_nav(menu, admin, _go_of(page, "Yes, do it"))
	_check(calls.size() == 1 and calls[0] == ["ban", ["#2", "1d", "Spamming"]],
		"and yes runs it", str(calls))

	calls.clear()
	replies.clear()
	_nav(menu, admin, "i:kick #3 1")
	_check(calls.is_empty() and replies.size() == 1 and replies[0].contains("higher immunity"),
		"a player above the admin cannot be reached by typing a path", str(replies))
	_nav(menu, admin, "i:kick #2 99")
	_check(calls.is_empty() and replies[replies.size() - 1].contains("not on the list"),
		"nor can a list entry that does not exist", str(replies))
	_nav(menu, admin, "i:kick #7 1")
	_check(calls.is_empty() and replies[replies.size() - 1].contains("not here"),
		"a player who left is a reply, not a kick on whoever is #7 next", str(replies))
	_nav(menu, admin, "i:kick #1 1")
	_check(calls.is_empty(), "nor is the admin themselves")

	admin.permissions = PackedStringArray(["ban"])
	replies.clear()
	_nav(menu, admin, "i:kick #2 1")
	_check(calls.is_empty() and replies.size() == 1 and replies[0].contains("not on your menu"),
		"a flag taken away between two key presses is checked on the second", str(replies))
	admin.permissions = PackedStringArray(["kick", "ban"])

	menu.after_run = "back"
	sent.clear()
	_nav(menu, admin, "i:kick #2 2")
	_check(str(_last_page().get("path", "")) == "i:kick" and _labels(_last_page()).has("Bob (#2)"),
		"after_run: back sends a fresh player list", str(_last_page()))

	_check(TmcAdminMenu.fill("say {text}", {"text": "a; b \"c\""}) == "say \"a, b 'c'\"",
		"fill() quotes a value with a space and strips what would end it")

	menu.free()
	_done()


func _test_menu_info_and_warn() -> void:
	_section("player info and warn")

	var admin := _session(1, "Admin", ["kick"], 50)
	var bob := _session(2, "Bob", [], 0)
	var menu := _menu({}, [admin, bob])

	var issued: Array = []
	var record := MenuModerationStandIn.new()
	record.issued = issued
	menu.moderation_fn = func() -> Object: return record
	menu.register_commands()

	sent.clear()
	_nav(menu, admin, "i:info #2")
	var page := _last_page()
	var labels := _labels(page)
	_check(str(page["title"]) == "Bob" and labels.has("User id: #2") and labels.has("Address: 203.0.113.2"),
		"info shows the ids, and the address to a kick holder", ", ".join(labels))
	_check(labels.has("On record: 1 warning; 0 in force"), "and their record, read from dot-moderation", ", ".join(labels))
	_check(_go_of(page, "Kick") == "i:kick #2" and _go_of(page, "Warn") == "i:warn #2",
		"with the actions already pointed at them", str(page["rows"]))
	_check(str(page["path"]) == "i:info #2", "an info page has a path, so Back returns to it")

	replies.clear()
	var ctx := admin.make_context("warn", PackedStringArray(), DotCmdContext.Source.CHAT,
		func(line: String) -> void: replies.append(line))
	console.execute("warn #2 stop spawn camping", ctx)
	await get_tree().process_frame
	_check(issued.size() == 1 and int(issued[0][0]) == TmcAdminMenu.PUNISHMENT_WARN and issued[0][2] == "stop spawn camping",
		"warn files a WARN record against the player", str(issued))
	_check(replies.size() == 1 and replies[0].begins_with("Warned Bob: stop spawn camping"),
		"and tells the admin", str(replies))

	var plain := _session(4, "Plain", ["slay"], 5)
	replies.clear()
	console.execute("warn #2 x", plain.make_context("warn", PackedStringArray(), DotCmdContext.Source.CHAT,
		func(line: String) -> void: replies.append(line)))
	_check(issued.size() == 1 and replies.size() == 1 and replies[0].contains("permission"),
		"warn needs its flag like any command", str(replies))

	menu.free()
	_done()


class MenuModerationStandIn:
	extends RefCounted
	var issued: Array = []

	func subject_for_peer(peer: int) -> String:
		return "uid:%d" % peer

	func issue(kind: int, subject: String, reason: String, _by: String, _secs: int, _imm: int) -> DotResult:
		issued.append([kind, subject, reason])
		return DotResult.success(null)

	func history_for(_subject: String) -> Array:
		var p := MenuPunishmentStandIn.new()
		return [p]


class MenuPunishmentStandIn:
	extends RefCounted
	var kind := TmcAdminMenu.PUNISHMENT_WARN

	func is_active() -> bool:
		return false


func _test_menu_bounds() -> void:
	_section("a page always fits a notice")

	var admin := _session(1, "Admin", ["root"], 99)
	var people: Array = [admin]
	for i in 200:
		people.append(_session(10 + i, "A player with a long name number %d" % i, [], 0))
	var menu := _menu({}, people)

	sent.clear()
	_nav(menu, admin, "i:kick")
	var page := _last_page()
	var bytes := JSON.stringify({"menu": page}).length()
	_check(bytes < DotNotice.MAX_DATA_BYTES, "two hundred players still make a page DotNotice will carry (%d bytes)" % bytes)
	_check(str(page["rows"].back()["label"]).begins_with("…and"), "and the page says how many it left off")
	_check(DotNotice.make(&"", "", -1.0, TmcAdminMenu.TOPIC, {"menu": page}).data.has("menu"),
		"the notice keeps it rather than dropping the tree")
	menu.free()
	_done()


## A live-tool command's handler object, as dot-moderation's DotModToolCommands is one:
## something with `tools` that answer `supports`, and `items_fn` for give.
class ToolHolder:
	extends RefCounted
	var tools: ToolsStandIn = null
	var items_fn: Callable = Callable()
	var calls: Array = []

	func run(ctx: DotCmdContext) -> void:
		calls.append([ctx.command, Array(ctx.args)])


class ToolsStandIn:
	extends RefCounted
	var supported: Array = []
	var teleport_fn: Callable = Callable()

	func supports(action: StringName) -> bool:
		return supported.has(String(action))


var _holder: ToolHolder = null


func _test_menu_fun() -> void:
	_section("fun commands, as far as the game goes")

	_holder = ToolHolder.new()
	_holder.calls = calls
	_holder.tools = ToolsStandIn.new()
	_holder.tools.supported = ["slap", "noclip", "give"]
	_holder.items_fn = func() -> PackedStringArray: return PackedStringArray(["rocket_launcher", "bat", "two words"])
	for spec in [["slap", "slay"], ["noclip", "cheats"], ["give", "cheats"], ["burn", "slay"], ["goto", "teleport"], ["bring", "teleport"]]:
		console.command(spec[0], _holder.run, "", spec[1]).with_chat()

	var admin := _session(1, "Admin", ["root"], 50)
	var bob := _session(2, "Bob", [], 0)
	var carol := _session(3, "Carol", [], 99)
	var menu := _menu({}, [admin, bob, carol])

	sent.clear()
	_nav(menu, admin, "c:fun")
	var labels := _labels(_last_page())
	_check(labels.has("Slap") and not labels.has("Set on fire"),
		"a fun command shows when the game supports it, and not when it only registered the command",
		", ".join(labels))
	_nav(menu, admin, "root")
	_check(not _labels(_last_page()).has("Teleport"),
		"teleport is hidden while the game gives no way to move a player", ", ".join(_labels(_last_page())))
	_holder.tools.teleport_fn = func(_id: StringName, _to: Variant) -> void: pass
	_nav(menu, admin, "c:teleport")
	_check(_labels(_last_page()).has("Go to") and _labels(_last_page()).has("Bring to me"),
		"and shown once it does", ", ".join(_labels(_last_page())))

	_nav(menu, admin, "i:slap")
	labels = _labels(_last_page())
	_check(labels.size() >= 3 and labels[0] == "Everyone" and labels[1] == "Everyone else",
		"slap offers everybody at once, first", ", ".join(labels))
	_nav(menu, admin, "i:slap @others")
	_check(_labels(_last_page())[0] == "Just a shove", "then how hard", ", ".join(_labels(_last_page())))
	calls.clear()
	_nav(menu, admin, "i:slap @others 3")
	_check(calls.size() == 1 and calls[0] == ["slap", ["@others", "10"]],
		"and runs `slap @others 10`, the command's own immunity rule doing the skipping", str(calls))
	calls.clear()
	replies.clear()
	_nav(menu, admin, "i:kick @all 1")
	_check(calls.is_empty() and replies.size() == 1 and replies[0].contains("everybody at once"),
		"a group is refused where the item does not take one: nobody kicks the server", str(replies))

	_nav(menu, admin, "i:goto")
	_check(_labels(_last_page()).has("Carol (#3)"),
		"goto lists people the admin does not outrank: going to them acts on nobody", ", ".join(_labels(_last_page())))

	_nav(menu, admin, "i:give #2")
	var page := _last_page()
	_check(_labels(page).has("Rocket Launcher") and _go_of(page, "Rocket Launcher") == "i:give #2 =rocket_launcher"
			and not _labels(page).has("Two words"),
		"give lists what the game's own give can hand out, by value, and drops what is not one word",
		str(page["rows"]))
	calls.clear()
	_nav(menu, admin, "i:give #2 =rocket_launcher")
	_check(calls.size() == 1 and calls[0] == ["give", ["#2", "rocket_launcher"]], "and gives it", str(calls))
	calls.clear()
	_nav(menu, admin, "i:give #2 =nuke")
	_check(calls.is_empty(), "something the game does not offer is refused")

	_nav(menu, admin, "i:noclip")
	_check(_labels(_last_page()).has("Admin (#1) — you"), "a power lists the admin themselves")
	calls.clear()
	_nav(menu, admin, "i:noclip #1 1")
	_check(calls.size() == 1 and calls[0] == ["noclip", ["#1", "on"]], "and noclip on yourself is `noclip #1 on`", str(calls))

	for name in ["slap", "noclip", "give", "burn", "goto", "bring"]:
		console.unregister_command(name)
	menu.free()
	_done()


class GameStandIn:
	extends RefCounted
	var metadata: Dictionary = {}

	func display_name_or_id() -> String:
		return "Fatal Contact"


func _test_menu_layers() -> void:
	_section("games extend the menu, and the owner has the last word")

	var admin := _session(1, "Admin", ["root"], 50)
	var menu := _menu({}, [admin])

	var game := GameStandIn.new()
	game.metadata = {"admin_menu": {
		"items": {
			"restart": {"label": "Restart the match", "command": "say restarting"},
			"vote": {"label": "Start a map vote", "command": "say voting", "category": "server"},
		},
	}}
	menu.adopt_game(game)
	sent.clear()
	_nav(menu, admin, "root")
	_check(_labels(_last_page()).has("Fatal Contact"), "a game's game.yml items get a category named after the game",
		", ".join(_labels(_last_page())))
	_nav(menu, admin, "c:game")
	_check(_labels(_last_page()) == PackedStringArray(["Restart the match"]), "holding its unplaced item",
		", ".join(_labels(_last_page())))
	_nav(menu, admin, "c:server")
	_check(_labels(_last_page()).has("Start a map vote"), "and an item can name an existing category")
	calls.clear()
	_nav(menu, admin, "i:restart")
	_check(calls.size() == 1 and calls[0] == ["say", ["restarting"]], "a game's item runs its line", str(calls))

	menu.configure({"items": {"restart": {"enabled": false}}})
	_check(not menu.items.has("restart") and menu.items.has("vote"),
		"the owner's admin_menu.yml takes a game's item off")
	menu.configure({"admin_menu_game_items": false})
	_check(not menu.items.has("vote"), "or all of them")
	menu.configure({})
	_check(menu.items.has("vote") and menu.game_items, "and a file without the switch puts them back")

	menu.adopt_game(null)
	_check(not menu.items.has("restart") and not menu.categories.has("game"),
		"a game change takes the last game's items with it")

	# The code half: a module registering through the registry, and leaving.
	var module := Node.new()
	add_child(module)
	menu.set_layer("fc", {"title": "Fatal Contact", "items": {"round": {"label": "End the round", "command": "say {team}", "steps": ["team"]}}}, module)
	menu.add_list("fc", "team", func() -> Array: return [["red", "Red team"], ["blue", "Blue team"], ["bad value", "x"]], "Which team")
	sent.clear()
	_nav(menu, admin, "i:round")
	var page := _last_page()
	_check(_labels(page) == PackedStringArray(["Red team", "Blue team"]) and _go_of(page, "Blue team") == "i:round =blue",
		"a list a game computes is offered by value, and an unusable value dropped", str(page.get("rows")))
	calls.clear()
	_nav(menu, admin, "i:round =blue")
	_check(calls.size() == 1 and calls[0] == ["say", ["blue"]], "and the chosen value reaches the command", str(calls))
	_nav(menu, admin, "i:round =green")
	_check(calls.size() == 1, "a value the game no longer offers is refused")
	_check(DotRegistry.get_service(TmcAdminMenu.SERVICE) == null,
		"(the suite's menus are not installed, so the registry is the host's alone)")

	remove_child(module)
	module.free()
	_check(not menu.items.has("round"), "a module leaving the tree takes its layer with it")

	menu.free()
	_done()


## One check per finding of the review of 9d78565, each of which failed on that commit.
func _test_review_fixes() -> void:
	_section("what the review found")

	# 1. Bytes, not characters.
	var admin := _session(1, "Admin", ["root"], 99)
	var people: Array = [admin]
	for i in 61:
		people.append(_session(10 + i, "这是一位名字非常非常长的玩家他来自很远的地方第%d号" % i, [], 0))
	var menu := _menu({}, people)
	sent.clear()
	_nav(menu, admin, "i:kick")
	var page := _last_page()
	_check(TmcAdminMenu.encoded_size(page) <= TmcAdminMenu.MAX_PAGE_BYTES
			and DotNotice.make(&"", "", -1.0, TmcAdminMenu.TOPIC, {"menu": page}).data.has("menu"),
		"sixty players with CJK names still make a page the notice keeps (%d bytes)" % TmcAdminMenu.encoded_size(page))

	var big := {"images": [], "tips": []}
	for i in 8:
		(big["images"] as Array).append("https://cdn.example.com/%s/%d.jpg" % ["x".repeat(400), i])
	for i in 12:
		(big["tips"] as Array).append("ヒント".repeat(50))
	var loading := TmcLoading.new().configure({"loading_games": {"fc": big}})
	var hint := loading._hint({"game": "fc"}, loading.games["fc"], true)
	_check(TmcLoading.encoded_size(hint) <= TmcLoading.MAX_DOC_BYTES and hint.get("show", false),
		"an oversized game screen is cut to fit, and keeps the show that matters (%d bytes)" % TmcLoading.encoded_size(hint))
	_check(Array(loading.problems).any(func(p: String) -> bool: return p.contains("too big to send whole")),
		"and the owner is told at boot")
	loading.free()

	# 2. The content delay holds across phases.
	var in_game := [true]
	var screen := TmcLoadingScreen.new()
	screen.in_game_fn = func() -> bool: return in_game[0]
	add_child(screen)
	screen.show_delay_sec = 5.0
	screen.begin(TmcLoadingScreen.REASON_CONTENT)
	screen.begin(TmcLoadingScreen.REASON_CONTENT)
	screen.begin(TmcLoadingScreen.REASON_CONTENT)
	_check(not screen.is_showing(), "fetching, verifying and mounting one map do not show the screen before the delay")

	# 3. A decode bomb is refused from its header.
	var small := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var png := small.save_png_to_buffer()
	_check(TmcLoadingScreen.declared_size(png) == Vector2i(4, 4), "a PNG's declared size is read from its header")
	var bomb := png.duplicate()
	for i in 4:
		bomb[16 + i] = [0, 0, 0x40, 0][i]
		bomb[20 + i] = [0, 0, 0x40, 0][i]
	var refused_before := TmcLoadingScreen.refused_oversized
	_check(TmcLoadingScreen.declared_size(bomb) == Vector2i(16384, 16384) and TmcLoadingScreen.decode(bomb) == null
			and TmcLoadingScreen.refused_oversized == refused_before + 1,
		"one that declares 16384 x 16384 is refused for its size, before a decoder sees it")
	var jpg := Image.create(37, 21, false, Image.FORMAT_RGB8).save_jpg_to_buffer()
	_check(TmcLoadingScreen.declared_size(jpg) == Vector2i(37, 21), "and a JPEG's, from its frame header",
		str(TmcLoadingScreen.declared_size(jpg)))
	var webp := Image.create(33, 17, false, Image.FORMAT_RGBA8).save_webp_to_buffer(true)
	_check(TmcLoadingScreen.declared_size(webp) == Vector2i(33, 17), "and a WebP's", str(TmcLoadingScreen.declared_size(webp)))

	# 3b. Nobody's own network.
	var private := ["http://127.0.0.1/x.png", "http://localhost:8080/x.png", "https://192.168.1.1/a", "http://10.0.0.5/a",
		"http://[::1]/a", "http://172.20.0.1/a", "http://user@169.254.169.254/latest", "http://printer.local/a"]
	var leaked := private.filter(func(u: String) -> bool: return not TmcLoadingScreen.is_private_host(u))
	_check(leaked.is_empty() and not TmcLoadingScreen.is_private_host("https://cdn.example.com/a.png")
			and not TmcLoadingScreen.is_private_host("http://172.32.0.1/a"),
		"loopback, LAN and link-local addresses are recognised, public ones are not", str(leaked))
	screen.adopt({"default": {"images": ["http://192.168.1.1/bg.png"]}})
	_check(screen.describe()["media"]["failed"] == 1 and screen.describe()["media"]["queued"] == 0,
		"and a server naming one gets nothing fetched", str(screen.describe()["media"]))

	# 4. The budget is per server, and a song stays a song.
	for i in 30:
		screen._media["http://203.0.113.1/failed_%d.png" % i] = false
	screen.adopt({"default": {"images": ["http://203.0.113.9/next.png"]}})
	_check(screen._media.has("http://203.0.113.9/next.png") and screen._media["http://203.0.113.9/next.png"] == null,
		"failures do not use up the prefetch budget")
	screen.adopt({"next": {"map": "m", "entry": {"music": ["http://203.0.113.9/song.ogg"]}}})
	var queued_song := screen._queue.filter(func(q: Array) -> bool: return q[0] == "http://203.0.113.9/song.ogg")
	_check(queued_song.size() == 1 and queued_song[0][1] == true, "a hint's song is queued as a song, whenever its turn comes")

	# 8. Nothing of the last server survives a reset.
	screen.begin(TmcLoadingScreen.REASON_GAME, "fc", "Fatal Contact")
	screen.reset()
	_check(screen.describe()["game"] == "" and screen._queue.is_empty(), "a reset forgets the last server's game and its queue")
	screen.free()

	# 5. Back history.
	var lines := PackedStringArray()
	var panel := TmcAdminMenuPanel.new()
	panel.send_fn = func(line: String) -> void: lines.append(line)
	add_child(panel)
	for path in ["root", "c:players", "i:ban", "i:ban #2", "i:ban #2 4"]:
		panel.show_page({"title": path, "path": path, "rows": [{"label": "x", "go": "y"}]})
	panel.show_page({"title": "root", "path": "root", "rows": [{"label": "x", "go": "y"}]})
	_check(panel.describe()["history"] == 0, "a page already in the history is a return to it, and what followed goes",
		str(panel.describe()))
	panel.press(8)
	_check(not panel.is_open(), "so Back from a root sent after a command closes, rather than walking into the ban")
	panel.free()

	# 7. A category's flag holds for a typed path.
	var owner_tree := {"categories": {"staff": {"title": "Staff", "flag": "ban", "items": ["kick", "info"]}}}
	var gated := _menu(owner_tree, [_session(1, "Mod", ["kick"], 50), _session(2, "Bob", [], 0)])
	var mod: DotClientSession = gated.sessions_fn.call()[0]
	sent.clear()
	replies.clear()
	_nav(gated, mod, "i:info #2")
	_check(_last_page().get("title", "") != "Bob" and replies.size() == 1,
		"a typed path cannot reach an item under a category the admin cannot see", str(replies))
	_nav(gated, mod, "i:ban")
	_check(not str(_last_page().get("title", "")).begins_with("Ban"), "nor one the owner left off the menu")
	gated.free()
	menu.free()
	_done()



func _test_panel() -> void:
	_section("the panel on a player's screen")

	var lines := PackedStringArray()
	var panel := TmcAdminMenuPanel.new()
	panel.send_fn = func(line: String) -> void: lines.append(line)
	add_child(panel)

	var rows: Array = []
	for i in 10:
		rows.append({"label": "Player %d" % i, "go": "i:kick #%d" % i})
	panel.show_page({"title": "Root", "path": "root", "rows": [{"label": "A", "go": "c:a"}]})
	panel.show_page({"title": "Kick", "path": "i:kick", "rows": rows})
	_check(panel.is_open() and panel.screen_lines().size() == 7 and panel.screen_lines()[0] == "1. Player 0",
		"seven numbered rows to a screen", str(panel.screen_lines()))
	_check(panel.press(9) and panel.screen_lines().size() == 3 and panel.screen_lines()[0] == "1. Player 7",
		"9 is the next screen", str(panel.screen_lines()))
	_check(panel.press(2) and lines[lines.size() - 1] == "i:kick #8",
		"a number sends that row's path", str(lines))
	panel.press(8)
	_check(panel.screen_lines()[0] == "1. Player 0", "8 goes back a screen first")
	lines.clear()
	panel.press(8)
	_check(lines.size() == 1 and lines[0] == "root", "and then back a page, by asking for it", str(lines))

	panel.show_page({"title": "Reason", "path": "i:kick #2", "rows": [
		{"label": "Spamming", "go": "i:kick #2 1"},
		{"label": "Custom…", "input": "i:kick #2", "prompt": "Reason"},
	]})
	lines.clear()
	panel.press(2)
	_check(panel.is_typing(), "a custom row opens a text box")
	panel.submit_text("said \"x\"; quit")
	_check(lines.size() == 1 and lines[0] == "i:kick #2 t:said 'x', quit" and not panel.is_typing(),
		"what is typed is sent after t:, with nothing that could end the argument", str(lines))

	panel.show_page({"title": "Info", "path": "i:info #2", "rows": [
		{"label": "User id: #2"}, {"label": "— Actions —"}, {"label": "Kick", "go": "i:kick #2"},
	]})
	_check(panel.screen_lines() == PackedStringArray(["User id: #2", "— Actions —", "1. Kick"]),
		"lines without a path are drawn and not numbered", str(panel.screen_lines()))

	panel.show_page({"title": "Bad", "path": "x", "rows": [42, {"label": "[b]x[/b]\u202e", "go": "c:a"}, "no"]})
	_check(panel.rows().size() == 1, "a row that is not a mapping is dropped", str(panel.rows()))

	panel.press(0)
	_check(not panel.is_open(), "0 closes it")
	panel.show_page({"title": "Again", "path": "root", "rows": [{"label": "A", "go": "c:a"}]})
	panel.show_page({})
	_check(not panel.is_open(), "an empty page from the server closes it")
	_check(TmcAdminMenuPanel.clean_text("  a;b\"c\n ") == "a,b'c", "clean_text strips what a console reads as structure")

	panel.free()
	_done()



func _test_loading_server() -> void:
	_section("loading.yml")

	var parsed := TmcYaml.parse_file("res://cfg.example/addon/dot_core/loading.yml")
	_check(parsed.ok, "the shipped loading.yml parses", str(parsed.error) if not parsed.ok else "")
	var shipped := TmcLoading.new().configure(parsed.value if parsed.ok else {})
	_check(shipped.problems.is_empty() and shipped.enabled and shipped.is_empty(),
		"and, everything in it commented, is on with nothing to send", ", ".join(shipped.problems))
	shipped.free()

	var tree := TmcYaml.parse("""
loading_images:
  - "https://cdn.example.com/a.jpg"
  - "res://icon.svg"
  - "file:///etc/passwd"
loading_music: "https://cdn.example.com/theme.ogg"
loading_music_volume: 3
loading_tips: [one, two]
loading_colour: red
loading_games:
  airdrift:
    image: "https://cdn.example.com/surf.jpg"
loading_maps:
  surf_mesa:
    image: "https://cdn.example.com/mesa.jpg"
""", "<test>")
	var node := TmcLoading.new().configure(tree.value)
	_check(node.default_entry.get("images", []) == ["https://cdn.example.com/a.jpg"],
		"only http(s) URLs survive", str(node.default_entry))
	_check(Array(node.problems).filter(func(p: String) -> bool: return p.contains("not an http")).size() == 2,
		"and each refused one is reported", ", ".join(node.problems))
	_check(Array(node.problems).any(func(p: String) -> bool: return p.contains("loading_colour")),
		"an unknown key is reported by the name it was written as")
	_check(float(node.default_entry["volume"]) == 1.0, "volume is clamped to 0..1")

	var doc := node.document()
	_check(doc.has("default") and doc.has("games") and not doc.has("maps"),
		"the document carries the default and the games, not the maps", str(doc.keys()))

	var out: Array = []
	node.send_fn = func(_s: DotClientSession, data: Dictionary) -> bool:
		out.append(data)
		return true
	node.broadcast_fn = func(data: Dictionary) -> int:
		out.append(data)
		return 1
	node._on_client_spawned(_session(5, "Joiner", []))
	_check(out.size() == 1 and out[0].has("default"), "a spawning player is sent it")

	out.clear()
	node._hint_map(MapStandIn.new("surf_mesa"))
	node._hint_map(MapStandIn.new("nowhere"))
	_check(out.size() == 1 and out[0]["next"]["map"] == "surf_mesa" and out[0]["next"]["entry"]["images"] == ["https://cdn.example.com/mesa.jpg"],
		"a map with a screen is hinted when it starts loading; one without is not", str(out))

	out.clear()
	node._on_game_load_failed("x", null)
	_check(out.size() == 1 and out[0].get("cancel", false), "a failed game change takes the screen down")

	var many := {}
	for i in 60:
		many["game_%d" % i] = {"images": ["https://cdn.example.com/a-very-long-path/to/a/picture/number/%d.jpg" % i], "tips": ["A tip that is long enough to count for something %d" % i]}
	var big := TmcLoading.new().configure({"loading_image": "https://cdn.example.com/a.jpg", "loading_games": many})
	_check(not big.document().has("games") and JSON.stringify(big.document()).length() <= TmcLoading.MAX_DOC_BYTES,
		"too many games to fit: they are left to the hints, and the document still fits")
	_check(Array(big.problems).any(func(p: String) -> bool: return p.contains("instead of ahead")),
		"and the owner is told", ", ".join(big.problems))
	big.free()
	node.free()
	_done()


class MapStandIn:
	extends RefCounted
	var id: StringName

	func _init(p_id: String) -> void:
		id = StringName(p_id)



func _test_loading_client() -> void:
	_section("the loading screen")

	var in_game := [false]
	var screen := TmcLoadingScreen.new()
	screen.in_game_fn = func() -> bool: return in_game[0]
	add_child(screen)

	screen.adopt({
		"v": 1,
		"default": {"images": ["http://127.0.0.1:9/a.jpg"], "music": ["http://127.0.0.1:9/t.ogg"], "tips": ["default tip"], "title": "My Server"},
		"games": {"airdrift": {"images": ["http://127.0.0.1:9/surf.jpg"], "tips": ["surf tip"]}},
		"delay": 0.0,
	})
	_check(screen.has_document(), "a document is adopted")

	screen.begin(TmcLoadingScreen.REASON_GAME, "airdrift", "Surf")
	_check(not screen.is_showing(), "nothing is shown before a game has been played (the first connect)")

	var covers := []
	screen.cover_changed.connect(func(up: bool) -> void: covers.append(up))
	in_game[0] = true
	screen.begin(TmcLoadingScreen.REASON_GAME, "airdrift", "Surf")
	_check(screen.is_showing(), "a game change shows it at once")
	_check(covers == [true], "and says the cover went up, so the shell can fit a phone's window round it", str(covers))
	var block := screen.fit_card()
	_check(block.x > 0.0 and block.y > 0.0 and block.y < 720.0, "its words and bar are what a window is fitted round", str(block))
	var entry := screen.current_entry()
	_check(entry["images"] == ["http://127.0.0.1:9/surf.jpg"] and entry["music"] == ["http://127.0.0.1:9/t.ogg"] and entry["title"] == "My Server",
		"the game's picture, with the default's music and title falling through", str(entry))

	screen.adopt({"next": {"map": "surf_mesa", "entry": {"images": ["http://127.0.0.1:9/mesa.jpg"]}}})
	entry = screen.current_entry()
	_check(entry["images"] == ["http://127.0.0.1:9/mesa.jpg"] and entry["tips"] == ["surf tip"],
		"a map's screen goes over the game's, field by field", str(entry))

	screen.end(TmcLoadingScreen.REASON_GAME)
	_check(not screen.is_showing(), "and goes when the game has spawned")
	_check(covers == [true, false], "saying so, so the shell hands the window back to the game", str(covers))
	_check(screen.current_entry()["images"] == ["http://127.0.0.1:9/surf.jpg"],
		"the map hint is forgotten once the change it was for is over")

	screen.show_delay_sec = 0.5
	screen.begin(TmcLoadingScreen.REASON_CONTENT)
	_check(not screen.is_showing(), "a map download waits before showing")
	screen.end(TmcLoadingScreen.REASON_CONTENT)
	screen._process(0.0)
	_check(not screen.is_showing(), "and one over in a blink never shows")
	screen.show_delay_sec = 0.0
	screen.begin(TmcLoadingScreen.REASON_CONTENT)
	screen._process(0.0)
	_check(screen.is_showing(), "one that takes longer does")
	screen.begin(TmcLoadingScreen.REASON_GAME)
	screen.end(TmcLoadingScreen.REASON_CONTENT)
	_check(screen.is_showing(), "and while a game change is also under way it stays")
	screen.adopt({"cancel": true})
	_check(not screen.is_showing(), "until the server says the change was abandoned")

	screen.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
	_check(screen.is_showing() and screen._root.modulate.a == 1.0 and screen._root.visible,
		"a game not ready to be seen is covered at once, not faded in over")
	screen.begin(TmcLoadingScreen.REASON_GAME)
	screen.end(TmcLoadingScreen.REASON_WARM)
	_check(screen.is_showing(), "the warm-up ending leaves a game change's screen up")
	screen.end(TmcLoadingScreen.REASON_GAME)
	_check(not screen.is_showing(), "and both over takes it down")

	# A live solo game, or the late sync of suggested packs, is never walled off by a fetch.
	_check(not TmcLoadingScreen.may_block_live_game(true, true, false), "a live solo game is not covered by a fetch")
	_check(not TmcLoadingScreen.may_block_live_game(true, false, true), "nor by the suggested packs' late sync")
	_check(TmcLoadingScreen.may_block_live_game(false, true, true), "but the launch (not live yet) is covered")
	_check(TmcLoadingScreen.may_block_live_game(true, false, false), "and an online map change keeps its screen")

	# Every reason that starts is timed for its begin/end log line.
	screen.begin(TmcLoadingScreen.REASON_WARM, "", "", true)
	_check(screen._reason_at.has(TmcLoadingScreen.REASON_WARM), "a reason that began is timed")
	screen.end(TmcLoadingScreen.REASON_WARM)
	_check(screen._reason_at.is_empty(), "and no longer once it ended")

	screen.adopt({"next": {"game": "fc", "entry": {}}, "show": true})
	_check(screen.is_showing() and screen.describe()["next"]["game"] == "fc",
		"the server's hint can put it up itself, naming the game")
	screen.reset()
	_check(not screen.is_showing() and not screen.has_document(), "a new connection forgets the old server's screen")
	_loading_media_guards(screen)
	_done()


## What the loading screen refuses to fetch or decode, and the music it keeps muted.
func _loading_media_guards(screen: TmcLoadingScreen) -> void:
	for bad in ["res://icon.svg", "user://x.png", "file:///etc/passwd", "javascript:alert(1)", "http:///x", "https://a b", ""]:
		if TmcLoadingScreen.is_safe_url(bad):
			_check(false, "%s is refused" % bad)
	_check(TmcLoadingScreen.is_safe_url("https://cdn.example.com/x.png") and TmcLoading.is_safe_url("https://cdn.example.com/x.png"),
		"an https URL is accepted, and the two copies of the rule agree on it")
	_check(TmcLoading.is_safe_url("res://icon.svg") == TmcLoadingScreen.is_safe_url("res://icon.svg")
			and TmcLoading.is_safe_url("http:///x") == TmcLoadingScreen.is_safe_url("http:///x"),
		"and on what they refuse")
	var known_before: int = screen.describe()["media"]["known"]
	screen.adopt({"default": {"images": ["res://icon.svg", "user://a.png"], "music": ["file:///x.ogg"]}})
	_check(screen.current_entry().get("images", []).is_empty() and screen.describe()["media"]["known"] == known_before,
		"a document naming local files fetches none of them", str(screen.describe()["media"]))

	var image := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	_check(TmcLoadingScreen.decode(image.save_png_to_buffer()) is Texture2D, "PNG bytes decode to a texture")
	_check(TmcLoadingScreen.decode(image.save_jpg_to_buffer()) is Texture2D, "and JPEG")
	var wide := Image.create(4000, 10, false, Image.FORMAT_RGBA8)
	var tex: Variant = TmcLoadingScreen.decode(wide.save_png_to_buffer())
	_check(tex is Texture2D and (tex as Texture2D).get_width() == TmcLoadingScreen.MAX_IMAGE_SIDE,
		"a huge picture is scaled down to a sane size", str((tex as Texture2D).get_width()) if tex is Texture2D else "null")
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.data = PackedByteArray()
	wav.data.resize(4410)
	var wav_path := "user://admin_loading_selftest.wav"
	wav.save_to_wav(wav_path)
	_check(TmcLoadingScreen.decode(FileAccess.get_file_as_bytes(wav_path)) is AudioStream, "WAV bytes decode to a stream")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(wav_path))
	_check(TmcLoadingScreen.decode("<!doctype html><html>404</html>".to_utf8_buffer()) == null,
		"an error page served with a 200 is not a picture")

	var muted := screen.music_muted
	screen.toggle_mute()
	var again := TmcLoadingScreen.new()
	add_child(again)
	_check(again.music_muted != muted, "muting the music is remembered by the next screen")
	screen.toggle_mute()
	again.free()

	screen.free()


## The corner line naming the client. The id is only ever read from a URL path, so what
## the path parser accepts is what can reach a player's screen.
## The shell's pre-load list for a scene, and the slice loader filling the cache from it.
func _test_slice_preload() -> void:
	_section("slice preload before a scene load")

	var deps: PackedStringArray = (load("res://client/tmc_shell_solo_packs.gd") as GDScript)._scene_dependency_paths("res://client/boot.tscn")
	_check(not deps.is_empty(), "a scene's dependencies are listed", str(deps))

	var loader := DotCloudSliceLoader.new()
	var res: DotResult = await loader.load_all(get_tree(), deps, false)
	_check(res.ok, "the slice loader loads them without threads", "" if res.ok else str(res.error))
	_check(ResourceLoader.has_cached(deps[0]) if not deps.is_empty() else false,
		"the first is in the cache, so the plain load() is a hit")

	# The solo path's warm: forced (this runner has threads), an unknown key warms nothing and
	# still returns the loader the shell reads frames_yielded from.
	var cloud := DotCloudClient.new()
	_check(cloud.has_method("warm_content"), "the cloud client offers warm_content")
	var warmed: DotCloudSliceLoader = await cloud.warm_content(get_tree(), PackedStringArray(["no/such@0"]), true)
	_check(warmed != null and warmed.frames_yielded >= 0, "warm_content returns its loader for a key it does not hold")
	cloud.free()
	_done()


func _test_shell_version() -> void:
	_section("the shell's version line")

	_check(TmcShellVersion.id_from_path("/game/tmc/20261016-0230/index.html") == "20261016-0230",
		"the build id is found in a publisher path")
	_check(TmcShellVersion.id_from_path("/godot/20261016-0230/") == "20261016-0230",
		"and in the shell's own folder")
	_check(TmcShellVersion.id_from_path("/game/tmc/20261016-0230x/index.html") == "",
		"an id with anything after it is not one")
	_check(TmcShellVersion.id_from_path("/game/tmc/<b>20261016-0230/") == "",
		"markup is not an id")

	var screen := TmcLoadingScreen.new()
	add_child(screen)
	var line := str(screen.describe().get("shell_version", "x"))
	_check(line == TmcShellVersion.label_text(),
		"the loading screen reports the line it shows", line)
	screen.free()

	_check(TmcShellVersion.label_text() == "" or TmcShellVersion.label_text().begins_with("shell "),
		"the line is empty or starts with shell")
	_done()


## The GameSpice look: the palette, the Powered by TMC pill in the bottom-right corner
## (linked to the configured site, never a host of its own), the version line moved to the
## bottom-left, the menu's card and its focus chain, and the phone fit's arithmetic.
func _test_shell_style() -> void:
	_section("the shell's GameSpice look and Powered by TMC")

	var site := "https://site.example/"
	_shell_pill_on_loading_screen(site)

	var opened: Array[String] = []
	var bare := TmcPoweredBy.new()
	bare.open_url_fn = func(u: String) -> void: opened.append(u)
	_check(not bare.describe()["pressable"] and not bare.open() and opened.is_empty(),
		"with no site the pill is text that opens nothing")
	bare.url = "javascript:alert(1)"
	_check(not bare.describe()["pressable"] and not bare.open() and opened.is_empty(),
		"nor does it open anything but a web address")
	bare.url = " " + site + " "
	_check(bare.open() and opened.size() == 1 and opened[0] == site, "a press opens the site through the injected opener", str(opened))
	bare.free()

	var before: Variant = ProjectSettings.get_setting(TmcPoweredBy.SETTING, true)
	ProjectSettings.set_setting(TmcPoweredBy.SETTING, false)
	var host := Control.new()
	_check(TmcPoweredBy.add_to(host, site) == null and host.get_child_count() == 0, "the project setting turns the pill off")
	ProjectSettings.set_setting(TmcPoweredBy.SETTING, before)
	host.free()

	# The menu, built on a shell that never enters the tree (its _ready connects to servers).
	var shell: Node = (load("res://client/shell.gd") as GDScript).new()
	shell.set("workshop_backbone_url", site)
	shell._menu_ui.call("_build_menu")
	var menu := shell.get("_menu") as Control
	var card := menu.find_child("Card", true, false) as PanelContainer
	_check(card != null and card.custom_minimum_size.x == float(shell.get("menu_card_width")),
		"the menu is one glass card, its width a setting")
	var join := shell.get("_join") as Button
	_check(join != null and join.has_theme_stylebox_override("normal") and join.has_theme_stylebox_override("focus"),
		"Connect is the accent button, with its own focus ring")
	var menu_pill := menu.find_child("PoweredByTmc", true, false) as TmcPoweredBy
	_check(menu_pill != null and menu_pill.url == site, "the menu has the pill too, linked to the configured site")
	var name_field := shell.get("_name") as LineEdit
	var address := shell.get("_address") as LineEdit
	var clear := shell.get("_clear") as Button
	_check(name_field.get_node_or_null(name_field.focus_neighbor_bottom) == address
		and address.get_node_or_null(address.focus_neighbor_bottom) == join
		and join.get_node_or_null(join.focus_neighbor_top) == address,
		"down and up walk name, server and Connect in order")
	_check(clear.focus_mode == Control.FOCUS_ALL and clear.focus_neighbor_top != NodePath(),
		"and reach the footer's Clear downloaded content")
	# The window is fitted round the menu's card, else the loading cover's words, else handed back.
	var cover := TmcLoadingScreen.new()
	cover.in_game_fn = func() -> bool: return true
	add_child(cover)
	shell.set("loading", cover)
	cover.begin(TmcLoadingScreen.REASON_GAME, "g", "Game")
	menu.visible = false
	var fitted: Vector2 = shell._menu_ui.call("_fit_card")
	_check(fitted != Vector2.ZERO and fitted == cover.fit_card(), "with the menu down, a portrait phone is fitted round the loading cover", str(fitted))
	cover.end(TmcLoadingScreen.REASON_GAME)
	_check(shell._menu_ui.call("_fit_card") == Vector2.ZERO, "and handed back when the cover lifts for the game")
	shell.set("loading", null)
	cover.free()
	menu.visible = true
	# Deferred, after the menu's own deferred focus and fit calls, which hold the shell.
	shell.call_deferred("free")
	_shell_phone_fit()
	_done()


## The loading screen's palette, buttons and Powered by TMC pill: where it sits and what it links to.
func _shell_pill_on_loading_screen(site: String) -> void:
	_check(TmcShellStyle.ACCENT.to_html(false) == "f2542d" and TmcShellStyle.palette().accent == TmcShellStyle.ACCENT,
		"the palette's accent is GameSpice's", TmcShellStyle.ACCENT.to_html(false))
	_check(TmcShellStyle.theme().has_stylebox("focus", "Button"), "buttons have a focus ring for a keyboard or a pad")

	var screen := TmcLoadingScreen.new()
	screen.site_url = site
	add_child(screen)
	var badge: Dictionary = screen.describe().get("powered_by", {})
	_check(str(badge.get("text", "")) == "Powered by TMC" and str(badge.get("url", "")) == site and bool(badge.get("pressable", false)),
		"the loading screen shows Powered by TMC, linked to the site it was given", str(badge))
	var pill := screen.find_child("PoweredByTmc", true, false) as TmcPoweredBy
	_check(pill != null and pill.anchor_left == 1.0 and pill.anchor_top == 1.0 and pill.offset_right < 0.0 and pill.offset_bottom < 0.0,
		"in the bottom-right corner, inset from the edge")
	_check(pill != null and pill.focus_mode == Control.FOCUS_NONE, "and never takes a keyboard or pad's focus")
	var version := screen.find_child("ShellVersion", true, false) as Label
	_check(version == null or (version.anchor_left == 0.0 and version.anchor_top == 1.0),
		"the version line, when there is one, has moved to the bottom-left")
	screen.free()


## The phone fit of the menu card, and the dialogs a phone-width window narrows.
func _shell_phone_fit() -> void:
	# The phone fit. Desktop keeps its layout; a portrait phone is scaled until the card fills
	# its width; a small or landscape window stops where the card stops fitting.
	var base := Vector2(1280.0, 720.0)
	var size := Vector2(420.0, 500.0)
	var desk := TmcShellStyle.fit_factor(Vector2(1280.0, 720.0), 1.0, base, size, 16.0, 1.0)
	_check(is_equal_approx(desk, 1.0), "a 1280x720 desktop window is not scaled", str(desk))
	var phone := TmcShellStyle.fit_factor(Vector2(1170.0, 2532.0), 3.0, base, size, 16.0, 1.0)
	_check(absf(phone - 1280.0 / 452.0) < 0.01, "a 390x844 phone at 3x scales the card to its width", str(phone))
	var small := TmcShellStyle.fit_factor(Vector2(640.0, 360.0), 1.0, base, size, 16.0, 1.0)
	_check(absf(small - 720.0 / 532.0) < 0.01, "a half-size window grows only until the card stops fitting", str(small))
	var big := TmcShellStyle.fit_factor(Vector2(3840.0, 2160.0), 1.0, base, size, 16.0, 1.0)
	_check(is_equal_approx(big, 1.0), "a big desktop window is never scaled up", str(big))
	# Dialogs: a phone-width window narrows the confirmation, and its message wraps, because a
	# frame at 390x844 showed the clear-content question running off the screen.
	_check(TmcShellStyle.dialog_width(Vector2(1280.0, 720.0), 420.0, 16.0) == 420,
		"a desktop confirmation keeps its width")
	_check(TmcShellStyle.dialog_width(Vector2(300.0, 600.0), 420.0, 16.0) == 268,
		"a narrow window's confirmation fits inside its margins")
	var ask := TmcShellStyle.dialog(ConfirmationDialog.new())
	_check(ask.get_label().autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and ask.theme != null,
		"a dressed confirmation wraps its message and carries the shell's theme")
	ask.free()


## One real fetch: a socket this suite serves a PNG from, the screen's own HTTPRequest,
## and the picture on the screen when it goes up.
func _test_loading_fetch() -> void:
	_section("a picture fetched over HTTP")

	var server := TCPServer.new()
	var port := 0
	for candidate in range(18431, 18451):
		if server.listen(candidate, "127.0.0.1") == OK:
			port = candidate
			break
	if not _check(port != 0, "a local port to serve from"):
		_check(false, "skipped: nothing to fetch from")
		_check(false, "skipped")
		_done()
		return

	var image := Image.create(16, 9, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLUE)
	var png := image.save_png_to_buffer()

	var in_game := [true]
	var screen := TmcLoadingScreen.new()
	screen.in_game_fn = func() -> bool: return in_game[0]
	# A private address is refused by default (see is_private_host); this suite serves itself.
	screen.allow_private_hosts = true
	add_child(screen)
	var url := "http://127.0.0.1:%d/bg.png" % port
	screen.adopt({"default": {"images": [url, "http://127.0.0.1:%d/missing.png" % port]}})

	var served := 0
	var on_worker := false
	var deadline := Time.get_ticks_msec() + 8000
	var peers: Array[StreamPeerTCP] = []
	while Time.get_ticks_msec() < deadline:
		on_worker = on_worker or screen._step.has("task")
		if server.is_connection_available():
			peers.append(server.take_connection())
		for peer in peers.duplicate():
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or peer.get_available_bytes() == 0:
				continue
			var request: String = peer.get_utf8_string(peer.get_available_bytes())
			var body := png if request.begins_with("GET /bg.png") else "nope".to_utf8_buffer()
			var status := "200 OK" if request.begins_with("GET /bg.png") else "404 Not Found"
			peer.put_data(("HTTP/1.1 %s\r\nContent-Type: image/png\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, body.size()]).to_utf8_buffer())
			peer.put_data(body)
			served += 1
			peers.erase(peer)
			peer.disconnect_from_host()
		var media: Dictionary = screen.describe()["media"]
		if media["ready"] + media["failed"] >= 2:
			break
		await get_tree().process_frame

	var media: Dictionary = screen.describe()["media"]
	_check(media["ready"] == 1 and media["failed"] == 1,
		"prefetched one at a time: the picture arrived and the 404 was given up on (%d served)" % served, str(media))
	_check(on_worker == DotPlatform.has_threads(),
		"decoded on a worker thread where there are threads (%s), so a picture is not a dropped frame" % DotPlatform.has_threads())
	screen.begin(TmcLoadingScreen.REASON_GAME, "x", "X")
	_check(screen.describe()["image"], "and the screen that goes up shows the picture that arrived")

	# A NAME that leads somewhere private. `ip6-loopback` is ::1 in a stock /etc/hosts and is
	# neither an address nor `localhost`, so only a lookup can tell; a box without the entry
	# cannot run the check and says so.
	var private_name := not IP.resolve_hostname_addresses("ip6-loopback").is_empty()
	var strict := TmcLoadingScreen.new()
	strict.in_game_fn = func() -> bool: return true
	add_child(strict)
	strict.adopt({"default": {"images": ["http://ip6-loopback:%d/bg.png" % port]}})
	await _until_frames(func() -> bool: return strict.describe()["media"]["failed"] == 1, 240)
	_check(not private_name or (strict.describe()["media"]["failed"] == 1 and strict.last_refusal.contains("private address")),
		"a hostname that resolves to a private address is looked up and never fetched%s" % ("" if private_name else " (skipped: no ip6-loopback here)"),
		str(strict.describe()["media"]))
	var judged := {
		"::1": true, "0:0:0:0:0:0:0:1": true, "::": true, "::ffff:192.168.0.4": true,
		"0:0:0:0:0:ffff:c0a8:4": true, "fe80::1": true, "fd12:3456::1": true, "127.0.0.1": true,
		"2606:4700::1111": false, "::ffff:8.8.8.8": false, "8.8.8.8": false, "2001:db8::1": false,
	}
	var wrong := judged.keys().filter(func(a: String) -> bool: return TmcLoadingScreen.is_private_address(a) != judged[a])
	_check(wrong.is_empty(),
		"addresses are judged in both families and every spelling, the engine's uncompressed IPv6 included", str(wrong))
	strict.free()
	server.stop()
	screen.free()
	_done()


func _until_frames(condition: Callable, frames: int) -> void:
	for i in frames:
		if bool(condition.call()):
			return
		await get_tree().process_frame
