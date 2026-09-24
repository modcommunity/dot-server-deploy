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

var audio: DotAudioManager = null

var _root: Control = null
var _box: VBoxContainer = null

## topic -> {"notice": DotNotice, "at": float, "panel": Control, "label": Label}.
var _lines: Dictionary = {}
var _anonymous := 0


func _ready() -> void:
	layer = LAYER
	_build_view()
	_build_audio()


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


## Takes everything down. The shell calls this when a connection ends: a countdown from
## a server this client has left is a promise nobody is keeping.
func clear_all() -> void:
	for key in _lines.keys():
		_remove(key)


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

	# Across the top and centred by a container rather than offset from the middle, for
	# the reason the menu gives: the browser player is a panel whose size the page decides.
	# Down from the edge by enough to clear the one-line bars games put there.
	var top := MarginContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.add_theme_constant_override("margin_top", 56)
	top.add_theme_constant_override("margin_left", 16)
	top.add_theme_constant_override("margin_right", 16)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(top)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(centre)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 6)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(_box)


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

	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
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
	return {
		"lines": lines,
		"audio": audio.describe() if audio != null else {},
	}
