class_name TmcWorkshopPanel
extends VBoxContainer

## The Subscriptions page of a solo game: what the player subscribed to that this game takes,
## whether it is on, and the switches. Drawn into the game's own menu by the shell (see
## `TmcWorkshopPanel.add_to_menu`), so it is where the player already looks for the maps.
##
## [b]It draws and it asks; the decisions are elsewhere.[/b] What is on comes from the last
## sync's summary and [method DotCloudWorkshop.last_list]; a switch is a call on
## [DotCloudWorkshop] (the site for a scope, this device's file for the device switch). Nothing
## here mounts or unmounts: a mounted pack cannot be taken back, so every change says it applies
## at the next launch, and the row shows the new answer at once from [member _pending].
##
## [b]Phone width is the design width.[/b] No row has a minimum width, every label wraps, and a
## card's switches are in a flow container that drops to a second line, because the browser
## player is a panel whose size the page decides.
##
## [b]Words go through [member text_fn][/b] (the shell's `_text`), with the English as the
## fallback, so a language file that lacks a key reads as a sentence, not as a key.

const CHANNEL := "tmc.workshop_panel"

## The page's id in a DotMenu.
const PAGE_ID := &"subscriptions"

## A change was made (or refused). For a suite and for the shell to log.
signal changed(what: String)

## The Workshop node whose list is shown. Null reads as "the Workshop is off in this build".
var workshop: DotCloudWorkshop = null

## The last [method DotCloudWorkshop.sync] summary, `{}` before the first.
var summary: Dictionary = {}

## False when the game's manifest has no `provides.accepts`.
var takes_subscriptions: bool = true

## The game's name, for the heading.
var game_name: String = ""

## True with the web handoff's game-bound token, which the site refuses an all-games change
## for. The panel then offers the asset page instead of the switch.
var game_bound: bool = false

## True on a build that has no way to sign in at all (a desktop build without the native
## sign-in): says so rather than leaving a player to wonder why the list is empty.
var no_sign_in: bool = false

## The site's origin, for "Open on the site" when no item has a page of its own.
var site_url: String = ""

## `func(key: String, args: Dictionary, fallback: String) -> String`. The shell's `_text`.
var text_fn: Callable = Callable()

## `func(url: String)`. Null opens it with [method OS.shell_open]; a suite records instead.
var open_url_fn: Callable = Callable()

## Switches flipped in this panel since the list was fetched: `subscription id` or
## `device:<content id>` -> the new answer. The list on disk is the site's, so showing the
## change without waiting for it to be fetched again is this panel's job.
var _pending: Dictionary = {}

var _notice: String = ""
var _busy: bool = false


func _init() -> void:
	name = "WorkshopPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)


func _ready() -> void:
	refresh()


## Adds the page to [param menu] (a DotMenu), built from [param make] each time it opens.
##
## A page is data and is drawn fresh every time it is shown, so the panel is made when the
## page opens and freed when it closes, and reads the Workshop's state as it is then.
static func add_to_menu(menu: Object, make: Callable) -> void:
	var page := DotMenuPage.make(PAGE_ID, "Subscriptions", "Packs you subscribed to on the site.")
	page.build = func(_kit: Object, body: VBoxContainer) -> void:
		var panel: TmcWorkshopPanel = make.call()
		body.add_child(panel)
	menu.call(&"add_page", page)


## Words: the shell's translation of [param key], else [param fallback] with `{name}` filled.
func _t(key: String, fallback: String, args: Dictionary = {}) -> String:
	if text_fn.is_valid():
		return str(text_fn.call(key, args, fallback.format(args)))
	return fallback.format(args)


func refresh() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_add_heading()

	if workshop == null or not _enabled():
		_add_line(_t("workshop.off", "The Workshop is off in this build."))
		return

	if not takes_subscriptions:
		_add_line(_t("workshop.takes_none", "This game takes no subscriptions."))
		_add_site_button()
		return

	if bool(summary.get("guest", false)) or str(summary.get("reason", "")) == "guest":
		_add_line(_t("workshop.sign_in", "Sign in to use your subscriptions"), true)
		_add_line(_t("workshop.sign_in_why",
			"Subscriptions belong to your account, so a guest has none."), false, true)
		if no_sign_in:
			_add_line(_t("workshop.no_native_sign_in",
				"This build cannot sign in yet. Play in the browser to use them."), false, true)
		_add_site_button()
		return

	var list := workshop.last_list()
	if list == null:
		_add_line(_t("workshop.no_list",
			"The list could not be fetched and none is saved on this device."))
		_add_site_button()
		return

	_add_line(_t("workshop.applies_next", "Changes apply the next time you start the game."), false, true)

	if bool(summary.get("offline", false)):
		_add_line(_t("workshop.offline",
			"The site could not be reached. This is the last list saved on this device."), false, true)

	if not _notice.is_empty():
		_add_line(_notice, true)

	var items := list.items()
	var removed := list.removed()

	if items.is_empty() and removed.is_empty():
		_add_line(_t("workshop.none", "You have no subscriptions this game can use."))
		_add_site_button()
		return

	for item in items:
		add_child(_item_card(item))

	for gone in removed:
		add_child(_removed_card(gone))

	_add_site_button()


func _enabled() -> bool:
	return workshop.config == null or workshop.config.workshop_enabled


# --- Drawing --------------------------------------------------------------------

func _add_heading() -> void:
	var title := Label.new()
	title.text = _t("workshop.title", "Subscriptions") + (" - " + game_name if game_name != "" else "")
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 20)
	add_child(title)


func _add_line(text: String, strong: bool = false, quiet: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if quiet:
		l.modulate = Color(1, 1, 1, 0.7)
	if strong:
		l.add_theme_font_size_override("font_size", 16)
	add_child(l)
	return l


func _add_site_button() -> void:
	var b := Button.new()
	b.text = _t("workshop.open_site", "Open on the site")
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed.connect(func() -> void: _open(site_url))
	b.disabled = site_url == ""
	add_child(b)


func _item_card(item: Dictionary) -> Control:
	var pack := DotCloudWorkshopList.pack_of(item)
	var content_id := str(pack.get("contentId", ""))
	var sub_id := str(item.get("subscriptionId", ""))
	var state := item_state(item)

	var card := PanelContainer.new()
	card.name = "Item_" + content_id.replace("/", "_")
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	card.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	pad.add_child(box)

	var name_label := Label.new()
	name_label.text = str(item.get("name", content_id))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 16)
	box.add_child(name_label)

	var status := Label.new()
	status.name = "State"
	status.text = state_text(state)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.modulate = Color(0.55, 0.9, 0.6) if str(state["id"]) == "on" else Color(1.0, 0.85, 0.5)
	box.add_child(status)

	var notes := PackedStringArray()
	if bool(pack.get("runsCode", false)):
		notes.append(_t("workshop.runs_code", "Runs code"))
	var via: Variant = item.get("via", null)
	if via is Dictionary:
		notes.append(_t("workshop.via", "From the collection {name}", {"name": str((via as Dictionary).get("name", ""))}))
	if not notes.is_empty():
		var n := _label(", ".join(notes))
		n.modulate = Color(1, 1, 1, 0.7)
		box.add_child(n)

	var flow := HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 12)
	flow.add_theme_constant_override("v_separation", 6)
	box.add_child(flow)

	var this_game := CheckButton.new()
	this_game.name = "ThisGame"
	this_game.text = _t("workshop.this_game", "On for this game")
	this_game.button_pressed = not _scope_off(sub_id)
	this_game.toggled.connect(func(on: bool) -> void: _set_scope(sub_id, on))
	flow.add_child(this_game)

	if game_bound:
		var site := Button.new()
		site.name = "EveryGameOnSite"
		site.text = _t("workshop.change_all_on_site", "Change for every game on the site")
		site.pressed.connect(func() -> void: _open(str(item.get("webUrl", site_url))))
		flow.add_child(site)
	else:
		var all := CheckButton.new()
		all.name = "AllGames"
		all.text = _t("workshop.all_games", "On for every game")
		all.button_pressed = bool(_pending.get("all:" + sub_id, str(item.get("scope", "")) == "all"))
		all.toggled.connect(func(on: bool) -> void: _set_all(sub_id, on))
		flow.add_child(all)

	var device := CheckButton.new()
	device.name = "ThisDevice"
	device.text = _t("workshop.this_device", "On on this device")
	device.button_pressed = not _device_off(content_id)
	device.toggled.connect(func(on: bool) -> void: _set_device(content_id, not on))
	flow.add_child(device)

	var open := Button.new()
	open.name = "OpenOnSite"
	open.text = _t("workshop.open_asset", "Open on the site")
	open.pressed.connect(func() -> void: _open(str(item.get("webUrl", site_url))))
	flow.add_child(open)

	return card


func _removed_card(gone: Dictionary) -> Control:
	var sub_id := str(gone.get("subscriptionId", ""))
	var content_id := str(gone.get("contentId", sub_id))
	var card := PanelContainer.new()
	card.name = "Removed_" + content_id.replace("/", "_")
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	card.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	pad.add_child(box)
	box.add_child(_label(content_id))
	var status := _label(_t("workshop.state.off_game", "Off for this game"))
	status.modulate = Color(1.0, 0.85, 0.5)
	box.add_child(status)
	if sub_id != "":
		var on := CheckButton.new()
		on.name = "ThisGame"
		on.text = _t("workshop.this_game", "On for this game")
		on.button_pressed = bool(_pending.get(sub_id, false))
		on.toggled.connect(func(v: bool) -> void: _set_scope(sub_id, v))
		box.add_child(on)
	return card


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# --- State ----------------------------------------------------------------------

## What an item is right now: `{id, reason}` where id is `on`, `off_here` (this game's switch
## was just turned off), `off_device`, `skipped` (with a reason) or `failed`. Pure on the
## summary, so a suite can ask it without a tree.
func item_state(item: Dictionary) -> Dictionary:
	var pack := DotCloudWorkshopList.pack_of(item)
	var content_id := str(pack.get("contentId", ""))
	var sub_id := str(item.get("subscriptionId", ""))

	if _scope_off(sub_id):
		return {"id": "off_here", "reason": ""}
	if _device_off(content_id):
		return {"id": "off_device", "reason": ""}

	for s in summary.get("skipped", []):
		if str((s as Dictionary).get("content_id", "")) == content_id:
			return {"id": "skipped", "reason": str((s as Dictionary).get("reason", ""))}
	for f in summary.get("failed", []):
		if str((f as Dictionary).get("content_id", "")) == content_id:
			return {"id": "failed", "reason": str((f as Dictionary).get("message", ""))}
	for m in summary.get("mounted", []):
		if str((m as Dictionary).get("content_id", "")) == content_id:
			return {"id": "on", "reason": ""}

	# Not in the summary at all: a list read after the last sync. It is subscribed and loads
	# at the next launch.
	return {"id": "later", "reason": ""}


func state_text(state: Dictionary) -> String:
	match str(state["id"]):
		"on":
			return _t("workshop.state.on", "On in this game")
		"off_here":
			return _t("workshop.state.off_here", "Off for this game from the next launch")
		"off_device":
			return _t("workshop.state.off_device", "Off on this device")
		"failed":
			return _t("workshop.state.failed", "Could not load: {why}", {"why": str(state["reason"])})
		"skipped":
			return _t("workshop.state.skipped", "Not loaded: {why}",
				{"why": skip_reason_text(str(state["reason"]))})
	return _t("workshop.state.later", "Subscribed; loads at the next launch")


func skip_reason_text(reason: String) -> String:
	match reason:
		DotCloudWorkshop.REASON_DEVICE_OFF:
			return _t("workshop.reason.device_off", "turned off on this device")
		DotCloudWorkshop.REASON_METERED:
			return _t("workshop.reason.metered", "you are on a metered connection")
		DotCloudWorkshop.REASON_SCRIPT_POLICY:
			return _t("workshop.reason.script_policy", "it runs code that has not been approved")
		DotCloudWorkshop.REASON_QUOTA:
			return _t("workshop.reason.quota", "there is no room to store it")
		DotCloudWorkshop.REASON_TOO_MANY:
			return _t("workshop.reason.too_many", "too many subscriptions to load at once")
		DotCloudWorkshop.REASON_INCOMPATIBLE:
			return _t("workshop.reason.incompatible", "this game cannot use it")
	return reason


func _scope_off(sub_id: String) -> bool:
	return _pending.has(sub_id) and _pending[sub_id] == false


func _device_off(content_id: String) -> bool:
	if _pending.has("device:" + content_id):
		return bool(_pending["device:" + content_id])
	return workshop != null and workshop.device != null and workshop.device.is_off(content_id)


# --- Switches -------------------------------------------------------------------

func _set_scope(sub_id: String, on: bool) -> void:
	if _busy or workshop == null:
		return
	_busy = true
	var res := await workshop.set_scope(sub_id, on)
	_busy = false
	_after("scope", res, func() -> void: _pending[sub_id] = on)


func _set_all(sub_id: String, on: bool) -> void:
	if _busy or workshop == null:
		return
	_busy = true
	var res := await workshop.set_all_games(sub_id, on)
	_busy = false
	_after("all", res, func() -> void: _pending["all:" + sub_id] = on)


func _set_device(content_id: String, off: bool) -> void:
	if workshop == null:
		return
	var res := workshop.set_device_off(content_id, off)
	_after("device", res, func() -> void: _pending["device:" + content_id] = off)


func _after(what: String, res: DotResult, apply: Callable) -> void:
	if res.ok:
		apply.call()
		_notice = ""
		DotLog.info(CHANNEL, "subscription changed", {"what": what})
	elif res.error != null and res.error.code == DotError.CODE_FORBIDDEN:
		_notice = _t("workshop.forbidden",
			"This sign-in can only change this game. Use the site to change every game.")
	elif res.error != null and res.error.code == DotError.CODE_AUTH:
		_notice = _t("workshop.sign_in", "Sign in to use your subscriptions")
	else:
		_notice = _t("workshop.failed", "The change was not saved: {why}",
			{"why": res.error.message if res.error != null else ""})
		DotLog.info(CHANNEL, "subscription change refused", {"what": what})
	changed.emit(what)
	if is_inside_tree():
		refresh()


func _open(url: String) -> void:
	if url == "":
		return
	# Only a web address: the item's page comes from the site, and a value that is not an
	# http(s) URL is not something to hand to the operating system.
	if not (url.begins_with("https://") or url.begins_with("http://")):
		return
	if open_url_fn.is_valid():
		open_url_fn.call(url)
	else:
		OS.shell_open(url)
