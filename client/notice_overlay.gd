class_name TmcNoticeOverlay
extends CanvasLayer

## The shell's own HUD: the lines and sounds the SERVER sends, over whatever game is on
## screen.
##
## [b]Why the shell draws these and not the game.[/b] A [DotNotice] is dot-server's
## message to the client application — the game vote's countdown, a restart warning —
## and what sends it (TmcVote, a host, an operator) outlives the game it is shown over.
## The game on screen is a delivered pack that knows nothing about the server's vote and
## is replaced by the change that vote causes, so a line it drew would go with it. The
## shell is the one thing on the client that is there before, during and after.
##
## [b]One line per topic.[/b] Two notices with the same topic are one line that changed,
## which is how a countdown is one line counting rather than ten stacked; a topic and
## nothing else takes the line down. A notice without a topic is a line of its own that
## goes after [constant HOLD_SEC].
##
## [b]The countdown is counted here.[/b] The server sends a number and the moment it
## arrived is the zero; between messages this counts down on its own clock and a later
## message simply replaces it. A line whose countdown runs out is taken down a moment
## later, so a countdown the server stopped caring about — a lost clear, a server that
## went away — does not sit on screen at 0:00.
##
## [b]Sounds are dot-audio ids, played through this overlay's own catalogue.[/b] The ids
## are named by the server's configuration (`cfg/vote.yml`'s `cue_*`) and must be in
## [method sound_catalogue]; the selftest checks every id the template names is. An id
## this build does not have is silence — dot-audio's rule, and the right one: a newer
## server naming a cue an older shell lacks should cost a sound, not an error.

## [b]A notice can also carry a ballot[/b] — the game vote's, and a game's map vote — in its
## [code]data[/code], and that is drawn as a [DotBallotPanel] per topic down the right-hand
## side, under the lines. A player chooses with a number key or a click,
## and the choice goes back as the same command they could type, through [member vote_fn].
## With two ballots open the number keys belong to the one that opened last; the other is
## still clickable. Each voter's avatar is fetched from its URL once and kept, and a voter
## whose picture cannot be fetched — no URL, a host that refuses a browser, a format this
## build cannot read — is drawn as an initial, never as a gap.

## [b]Everything here is in one column down the right-hand side, and nothing is at the top
## centre.[/b] The lines were a bar across the top centre, 56 px down, and that is where
## nearly every game puts its own second line: the round clock's, the map's name, "between
## rounds", the portraits under the scores. Rendered over all thirteen games at 1280x720 the
## game vote's line hid one of them in ten. The right-hand column under 110 px was already
## the ballots' and already clear of them, so the lines go at its head. The column narrows
## with the frame ([method column_width]): at a fixed 360 px a ballot on a phone in
## landscape was nearly half the screen and over the crosshair.
##
## [b]A ballot names the line it stands for[/b] ([code]data["line"][/code], a topic), and
## that line is not drawn while the ballot is open: the ballot already says what the line
## says (the title, how to vote, the time), and two copies were the second-tallest thing on
## the HUD. The line still exists, for [method line_text] and for a shell older than this
## that draws no ballot.

const CHANNEL := "tmc.notice"

## Where real cue sounds go when somebody makes them. Nothing is there yet, and the
## synthesiser stands in — see [method sound_recipes].
const SOUND_DIR := "res://client/sounds"

## Seconds a line with no countdown stays up.
const HOLD_SEC := 6.0

## Seconds a line whose countdown reached zero stays up, so "0" is seen rather than
## skipped.
const EXPIRED_HOLD_SEC := 1.0

## The game vote's cues. [b]Spelled here once[/b]; `cfg.example/vote.yml` names the same
## ids and `examples/selftest.tscn` fails if the two drift apart.
const CUE_VOTE_START := &"tmc_vote_start"
const CUE_VOTE_END := &"tmc_vote_end"
const CUE_VOTE_WARNING := &"tmc_vote_warning"
const CUE_VOTE_COUNT := &"tmc_vote_count"

## Above the menu's layer, so a line the server sends while the menu is up is still seen.
const LAYER := 20

## The column: [constant COLUMN_TOP] px down (clear of the one-line bars and the first rows of
## a kill feed games put at the top right), [constant COLUMN_MARGIN] px in from the right.
const COLUMN_TOP := 110.0
const COLUMN_MARGIN := 16.0

var audio: DotAudioManager = null

## [code]func(line: String)[/code] that sends a chat line as this player. The shell points it
## at the link; a ballot choice is sent as [code]/<command> <n>[/code], the silent prefix,
## because a vote is not something to say to the room.
var vote_fn: Callable = Callable()

## topic -> DotBallotPanel.
var _ballots: Dictionary = {}
var _ballot_box: VBoxContainer = null

## url -> Texture2D, or null while it is being fetched or after it failed.
var _avatars: Dictionary = {}
var _fetching := 0

## Most avatar downloads at once. A ballot of thirty people is thirty requests, and a browser
## allows six per host before it queues the rest behind the game's own traffic.
const MAX_FETCHES := 4

## Largest avatar accepted, in bytes. A profile picture, not a wallpaper.
const MAX_AVATAR_BYTES := 512 * 1024

var _root: Control = null
var _column: VBoxContainer = null
var _box: VBoxContainer = null

## topic -> {"notice": DotNotice, "at": float, "panel": Control, "label": Label}.
var _lines: Dictionary = {}
var _anonymous := 0


func _ready() -> void:
	layer = LAYER
	_build_view()
	_build_audio()
	get_viewport().size_changed.connect(_fit_column)
	_fit_column()


# --- What a line says ---------------------------------------------------------

## Takes a notice from the server. Connect [signal DotClientLink.notice_received] here.
func show_notice(notice: DotNotice) -> void:
	if notice == null:
		return

	if notice.cue != &"" and audio != null:
		audio.play(notice.cue)

	if notice.is_clear():
		_remove(notice.topic)
		return

	if notice.topic != &"" and (notice.data.has("options") or notice.data.has("open")):
		show_ballot(notice.topic, notice.data)
		return

	if notice.text == "" and not notice.has_countdown():
		# A cue and nothing else. Heard, not drawn.
		return

	var key := notice.topic

	if key == &"":
		_anonymous += 1
		key = StringName("_line_%d" % _anonymous)

	var line: Dictionary = _lines.get(key, {})

	if line.is_empty():
		line = _make_line()
		_lines[key] = line

	line["notice"] = notice
	line["at"] = _now()
	_render(line)
	_cover_lines()


## Takes everything down. The shell calls this when a connection ends: a countdown from
## a server this client has left is a promise nobody is keeping.
func clear_all() -> void:
	for key in _lines.keys():
		_remove(key)

	for key in _ballots.keys():
		(_ballots[key] as DotBallotPanel).dismiss()


# --- Ballots --------------------------------------------------------------------

## Draws, updates or takes down the ballot for [param topic]. See the class notes.
func show_ballot(topic: StringName, data: Dictionary) -> void:
	var panel: DotBallotPanel = _ballots.get(topic, null)
	var open := bool(data.get("open", false))

	if panel == null:
		if not open:
			return
		panel = _make_ballot(topic)

	var opening := open and not panel.is_open()
	panel.local_voter = str(data.get("you", panel.local_voter))
	panel.show_state(data)
	_cover_lines()

	if opening:
		# Arrived mid-ballot or not, what was already cast is not news.
		panel.snap_avatars()
		_give_numbers_to(panel)
		_dismiss_results_except(panel)


## Takes down every ballot that is only showing its result, other than [param keep]. A
## closed ballot holds "X won" for a few seconds, and a game's own ballot often opens inside
## them, right after the game vote keeps the game: the two panels then stacked down the
## column to y~650 at 1280x720, over the bottom-right HUD of three games. The result is
## news only until something else asks a question.
func _dismiss_results_except(keep: DotBallotPanel) -> void:
	for other: DotBallotPanel in _ballots.values():
		if other != keep and not other.is_open() and other.visible:
			other.dismiss()


func ballot(topic: StringName) -> DotBallotPanel:
	return _ballots.get(topic, null)


## Every ballot panel, open or not. The shell takes their number keys while the admin menu
## is up.
func ballots() -> Array:
	return _ballots.values()


## Gives the number keys back to the last open ballot, after something else had them.
func restore_numbers() -> void:
	var last: DotBallotPanel = null
	for panel: DotBallotPanel in _ballots.values():
		if panel.is_open():
			last = panel
	if last != null:
		_give_numbers_to(last)


func _make_ballot(topic: StringName) -> DotBallotPanel:
	var panel := DotBallotPanel.new()
	panel.name = "Ballot_%s" % String(topic)
	panel.ui_theme = ballot_theme()
	panel.panel_width = column_width(_frame_width())
	panel.avatar_fn = _avatar_texture
	panel.chosen.connect(func(index: int, _id: String, command: String) -> void:
		if vote_fn.is_valid() and command != "":
			vote_fn.call("/%s %d" % [command, index + 1])
	)
	panel.dismissed.connect(func() -> void:
		# The keys go back to whichever ballot is still open.
		for other: DotBallotPanel in _ballots.values():
			if other.is_open():
				_give_numbers_to(other)
	)
	_ballot_box.add_child(panel)
	_ballots[topic] = panel
	return panel


## The ballots' theme: the shell's, with an opaque background. The theme's 0.92 is right for
## a panel over a 3D world, but a ballot is drawn over whatever HUD a game has, and over a
## menu of bright text (a lot screen's prices) that text read through it, under the result.
static func ballot_theme() -> DotUiTheme:
	var t := DotUiTheme.space()
	t.background.a = 1.0
	return t


func _give_numbers_to(owner: DotBallotPanel) -> void:
	for panel: DotBallotPanel in _ballots.values():
		panel.take_numbers = panel == owner


## A voter's picture, or null until it has arrived. Fetched once per URL.
func _avatar_texture(_voter: String, url: String) -> Texture2D:
	if _avatars.has(url):
		return _avatars[url]

	if not (url.begins_with("https://") or url.begins_with("http://")) or _fetching >= MAX_FETCHES:
		return null

	_avatars[url] = null
	_fetching += 1

	var request := HTTPRequest.new()
	request.body_size_limit = MAX_AVATAR_BYTES
	request.timeout = 10.0
	add_child(request)
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
		_fetching -= 1
		request.queue_free()

		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return

		var image := Image.new()
		var loaded := ERR_FILE_UNRECOGNIZED

		# By content, not by extension: an avatar URL is often a route with no extension.
		if body.size() > 8 and body[0] == 0x89 and body[1] == 0x50:
			loaded = image.load_png_from_buffer(body)
		elif body.size() > 3 and body[0] == 0xFF and body[1] == 0xD8:
			loaded = image.load_jpg_from_buffer(body)
		elif body.size() > 12 and body.slice(8, 12).get_string_from_ascii() == "WEBP":
			loaded = image.load_webp_from_buffer(body)

		if loaded == OK and not image.is_empty():
			_avatars[url] = ImageTexture.create_from_image(image)
	)

	if request.request(url) != OK:
		_fetching -= 1
		request.queue_free()

	return null


## What the line for [param topic] says right now, or empty. For a suite, and for a bug
## report: "what did the HUD say" is otherwise a screenshot.
func line_text(topic: StringName) -> String:
	var line: Dictionary = _lines.get(topic, {})
	return "" if line.is_empty() else (line["label"] as Label).text


func has_line(topic: StringName) -> bool:
	return _lines.has(topic)


## Seconds left on [param topic]'s countdown, or -1 when it has none.
func seconds_left(topic: StringName) -> float:
	var line: Dictionary = _lines.get(topic, {})
	if line.is_empty():
		return -1.0
	return _remaining(line)


static func format_seconds(seconds: float) -> String:
	var total := int(ceil(maxf(seconds, 0.0)))
	if total < 60:
		return "%ds" % total
	return "%d:%02d" % [total / 60, total % 60]


func _process(_delta: float) -> void:
	if _lines.is_empty():
		return

	# A ballot closes on its own clock, with no message to hang this on.
	_cover_lines()

	var now := _now()

	for key in _lines.keys():
		var line: Dictionary = _lines[key]
		var notice: DotNotice = line["notice"]
		var age := now - float(line["at"])

		var gone := (
			age > notice.seconds + EXPIRED_HOLD_SEC if notice.has_countdown()
			else age > HOLD_SEC
		)

		if gone:
			_remove(key)
		elif notice.has_countdown():
			_render(line)


func _render(line: Dictionary) -> void:
	var notice: DotNotice = line["notice"]
	var label: Label = line["label"]

	if notice.has_countdown():
		var left := format_seconds(_remaining(line))
		label.text = left if notice.text == "" else "%s  %s" % [notice.text, left]
	else:
		label.text = notice.text


func _remaining(line: Dictionary) -> float:
	var notice: DotNotice = line["notice"]
	if not notice.has_countdown():
		return -1.0
	return maxf(notice.seconds - (_now() - float(line["at"])), 0.0)


func _remove(key: StringName) -> void:
	var line: Dictionary = _lines.get(key, {})
	if line.is_empty():
		return
	_lines.erase(key)
	var panel: Control = line["panel"]
	if is_instance_valid(panel):
		panel.queue_free()


## Whether [param topic]'s line is drawn: not while an open ballot names it as the line it
## stands for. See the class notes.
func is_line_shown(topic: StringName) -> bool:
	var line: Dictionary = _lines.get(topic, {})
	return not line.is_empty() and (line["panel"] as Control).visible


func _cover_lines() -> void:
	var covered := {}
	for panel: DotBallotPanel in _ballots.values():
		if panel.is_open():
			var named := str(panel.state.get("line", ""))
			if named != "":
				covered[StringName(named)] = true
	for key: StringName in _lines.keys():
		var panel: Control = _lines[key]["panel"]
		if is_instance_valid(panel):
			panel.visible = not covered.has(key)


## The column's width on a frame [param frame_width] wide: a third of it, between 240 and
## 360 px. 240 still fits a game's name, its count and two avatars on a ballot row.
static func column_width(frame_width: float) -> float:
	return clampf(frame_width * 0.34, 240.0, 360.0)


func _frame_width() -> float:
	return get_viewport().get_visible_rect().size.x if is_inside_tree() else 1280.0


func _fit_column() -> void:
	if _column == null:
		return
	var width := column_width(_frame_width())
	_column.offset_left = -COLUMN_MARGIN - width
	_column.offset_right = -COLUMN_MARGIN
	# A panel lays itself out in `show_state`, so an open one takes the new width with the
	# next state the server sends (every vote cast sends one). Re-showing the old state here
	# would restart its clock from the seconds it arrived with.
	for panel: DotBallotPanel in _ballots.values():
		panel.panel_width = width


## Wall time, in seconds. Not the engine's process time: a browser tab that was hidden
## stopped its frames, and a countdown should read what is true when it comes back.
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# --- The view -----------------------------------------------------------------

func _build_view() -> void:
	_root = Control.new()
	_root.name = "Notices"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Never takes input: this is drawn over a game that wants every click.
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = DotUiTheme.space().build()
	add_child(_root)

	# One column down the right-hand side: the lines, then the ballots. See the class notes.
	# Offsets set after the anchors, every one, for the reason dot-ui's docs/hud.md gives;
	# the width is [method _fit_column]'s.
	_column = VBoxContainer.new()
	_column.name = "Column"
	_column.add_theme_constant_override("separation", 10)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.anchor_left = 1.0
	_column.anchor_right = 1.0
	_column.anchor_top = 0.0
	_column.anchor_bottom = 1.0
	_column.offset_left = -COLUMN_MARGIN - column_width(1280.0)
	_column.offset_right = -COLUMN_MARGIN
	_column.offset_top = COLUMN_TOP
	_column.offset_bottom = -COLUMN_MARGIN
	_root.add_child(_column)

	_box = VBoxContainer.new()
	_box.name = "Lines"
	_box.add_theme_constant_override("separation", 6)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_box)

	_ballot_box = VBoxContainer.new()
	_ballot_box.name = "Ballots"
	_ballot_box.add_theme_constant_override("separation", 10)
	_ballot_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_ballot_box)


func _make_line() -> Dictionary:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.09, 0.78)
	style.set_corner_radius_all(10)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	# Wrapped: the column is a third of the frame, and a line is a sentence.
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 18)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)

	_box.add_child(panel)
	return {"panel": panel, "label": label}


# --- The sound ------------------------------------------------------------------

## Every cue this shell can play. Flat, on Master, one at a time each.
##
## [b]Master, not a UI bus[/b], because this project declares no bus layout and a bus
## name that does not exist is not one a player's volume slider reaches either. A game
## that brings a layout brings its own sliders for its own sounds.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	for id in [CUE_VOTE_START, CUE_VOTE_END, CUE_VOTE_WARNING, CUE_VOTE_COUNT]:
		var def := DotAudioDef.new()
		def.id = id
		def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
		def.bus = &"Master"
		def.max_concurrent = 1
		def.priority = 70
		c.add(def)

	return c


## Which synthesised voice stands in for each cue until a real file is in
## [constant SOUND_DIR]. The same choices a game's map vote makes, so a ballot sounds like
## a ballot whichever vote opened it: up for opening, because up reads as "on", a blip for
## the warning and a click per second, so a countdown is not mistaken for a hit marker.
static func sound_recipes() -> Dictionary:
	return {
		CUE_VOTE_START: DotAudioSynth.Voice.SPAWN,
		CUE_VOTE_END: DotAudioSynth.Voice.PICKUP,
		CUE_VOTE_WARNING: DotAudioSynth.Voice.BLIP,
		CUE_VOTE_COUNT: DotAudioSynth.Voice.CLICK,
	}


func _build_audio() -> void:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.voices = 4
	# [b]Not in the registry, and not on the buses.[/b] A delivered game registers its own
	# `dot_audio` manager and sets its own bus volumes from its own settings; a shell that
	# registered or applied a default mixer would displace the one or reset the other the
	# moment it started, which is a game whose volume slider stops working for no reason
	# anybody could find.
	audio.register_as_service = false
	audio.apply_mixer_to_buses = false
	add_child(audio)

	var res := audio.setup()

	if not res.ok:
		# Not fatal. The lines still draw; a HUD with no sound is still a HUD.
		DotLog.warn(CHANNEL, "the notice sounds are off", {"why": str(res.error)})
		return

	var godot_sink := audio.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(audio.catalogue, sound_recipes())


func describe() -> Dictionary:
	var lines := {}
	for key in _lines.keys():
		lines[String(key)] = line_text(key)
	var ballots := {}
	for key in _ballots.keys():
		ballots[String(key)] = (_ballots[key] as DotBallotPanel).describe()
	return {
		"lines": lines,
		"ballots": ballots,
		"audio": audio.describe() if audio != null else {},
	}
