class_name TmcLoadingScreen
extends CanvasLayer

## The screen over a game or map change: the server owner's picture, music and tips, with
## the download's own progress on top. Configured by `cfg/loading.yml` on the server and
## sent by `TmcLoading`; see that file for what the document holds and why it is URLs.
##
## [b]It covers two things, and they end differently.[/b]
##
## - [code]game[/code]: a changelevel. Starts when the server says one is coming (or the
##   link starts downloading or loading a game) and ends when the new game has spawned.
##   The old game is still on screen while its replacement downloads, which is exactly the
##   stretch this exists to cover.
## - [code]content[/code]: anything the content client fetches while a game is running —
##   in practice a map. Starts when a fetch has been going for [member show_delay_sec],
##   so a map already on the disk does not flash a screen, and ends when it is mounted.
##
## The screen is up while either is. Neither on the first connect: the shell's own menu
## (or the page that launched the player) has that, and the shell only calls [method begin]
## once a game has spawned.
##
## [b]Media is fetched ahead of time and kept for the session.[/b] When a document arrives
## every URL in it is queued, one request at a time, while the player is still playing —
## so the picture is there when the change starts, rather than racing the game's own
## download for the same link. A URL that fails is not retried this session, and a screen
## whose picture never arrived is a plain dark screen with the progress on it, which is
## what it was before any of this existed.
##
## [b]Only http(s), and only what the bytes say they are.[/b] A server must not be able to
## make a client read `res://` or `user://`, so anything else is refused here whatever the
## server checked. An image is decoded by its magic number — PNG, JPEG, WebP — and audio
## likewise — Ogg, MP3, WAV — because a URL is often a route with no extension.
##
## [b]The music is the player's to silence.[/b] M on the screen mutes it, and the choice is
## kept in `user://tmc_loading.cfg`: a loading theme on every map change of a long evening
## is exactly what somebody wants off, and a setting they have to find in a menu between
## two changes is one they never find.

const CHANNEL := "tmc.loading"

const TOPIC := &"loading_screen"
const VERSION := 1

## Under the admin menu (30) and the notices (20), over the game.
const LAYER := 15

const MAX_IMAGE_BYTES := 4 * 1024 * 1024
const MAX_AUDIO_BYTES := 12 * 1024 * 1024
const MAX_URL := 512

## Longest side a picture is kept at, in pixels.
const MAX_IMAGE_SIDE := 2560

## Most URLs fetched per document. Eight images, four songs and a sound for each of a
## handful of games is already more than anybody needs on one evening.
const MAX_PREFETCH := 24

## Seconds a "next" hint is believed for. A map vote that named a map and then lost.
const HINT_TTL_SEC := 120.0

## Seconds after which a screen with nothing happening under it is taken down. A change the
## server abandoned without saying so must not leave a player behind a picture.
const STALE_SEC := 90.0

const FADE_SEC := 0.25
const MUSIC_FADE_IN_SEC := 1.2
const MUSIC_FADE_OUT_SEC := 0.6
const TIP_SEC := 6.0

const PREFS := "user://tmc_loading.cfg"

## Reasons a screen is up. See the class notes.
const REASON_GAME := &"game"
const REASON_CONTENT := &"content"

## `func() -> bool`: whether a game is on screen at all. The shell answers "has spawned
## and the menu is hidden"; without it, a screen never goes up.
var in_game_fn: Callable = Callable()

## Seconds a content fetch waits before showing. The server's document may change it.
var show_delay_sec := 0.25

## Whether the music is muted. Kept across sessions.
var music_muted := false

var _doc: Dictionary = {}
var _next: Dictionary = {}
var _next_at := -1.0

var _reasons: Dictionary = {}
var _pending_content_at := -1.0
var _last_activity := 0.0
var _visible := false
var _shown_at := 0.0
var _game_id := ""
var _game_name := ""
var _entry: Dictionary = {}
var _tips: Array = []
var _tip_index := 0
var _tip_at := 0.0

## url -> Texture2D / AudioStream once fetched, null while queued or in flight, false when
## it failed.
var _media: Dictionary = {}
var _queue: Array[String] = []
var _fetching := false

var _root: Control = null
var _backdrop: ColorRect = null
var _image: TextureRect = null
var _title: Label = null
var _status: Label = null
var _detail: Label = null
var _bar: ProgressBar = null
var _tip: Label = null
var _hint: Label = null
var _music: AudioStreamPlayer = null
var _done: AudioStreamPlayer = null
var _fade: Tween = null
var _music_fade: Tween = null


func _ready() -> void:
	layer = LAYER
	_load_prefs()
	_build_view()
	_root.visible = false
	_root.modulate.a = 0.0


# --- The document ------------------------------------------------------------------

## Takes a notice's data under [constant TOPIC]: a document, a hint about what is coming
## next, or a cancel. Anything else is ignored.
func adopt(data: Dictionary) -> void:
	if data.has("default") or data.has("games"):
		if int(data.get("v", VERSION)) > VERSION:
			DotLog.debug(CHANNEL, "a loading screen from a newer server; reading what this build knows", {})
		_doc = {
			"default": _clean_entry(data.get("default", {})),
			"games": {},
		}
		var games: Variant = data.get("games", {})
		if games is Dictionary:
			for id in (games as Dictionary).keys():
				(_doc["games"] as Dictionary)[str(id)] = _clean_entry(games[id])
		if data.has("delay"):
			show_delay_sec = clampf(float(data["delay"]), 0.0, 5.0)
		_prefetch_entry(_doc["default"])
		for id in (_doc["games"] as Dictionary).keys():
			_prefetch_entry(_doc["games"][id])

	var next: Variant = data.get("next", null)
	if next is Dictionary:
		_next = {
			"game": str(next.get("game", "")),
			"map": str(next.get("map", "")),
			"entry": _clean_entry(next.get("entry", {})),
		}
		_next_at = _now()
		_prefetch_entry(_next["entry"])
		if _visible:
			_apply_entry()

	if bool(data.get("show", false)):
		begin(REASON_GAME, str(_next.get("game", "")))

	if bool(data.get("cancel", false)):
		_next = {}
		end(REASON_GAME)


## Forgets the document: a new connection is a new server, with its own screen or none.
func reset() -> void:
	_doc = {}
	_next = {}
	_reasons.clear()
	_pending_content_at = -1.0
	_hide(false)


func has_document() -> bool:
	return not _doc.is_empty()


# --- When ------------------------------------------------------------------------

## Something started that the screen should cover. [param game_id] and [param game_name]
## name what is loading, when that is known.
func begin(reason: StringName, game_id: String = "", game_name: String = "") -> void:
	if not _in_game() and not _visible:
		return
	if game_id != "":
		_game_id = game_id
	if game_name != "":
		_game_name = game_name
	_last_activity = _now()

	if reason == REASON_CONTENT and not _reasons.has(REASON_CONTENT):
		# Delayed: see [member show_delay_sec].
		_reasons[REASON_CONTENT] = true
		if not _visible:
			_pending_content_at = _now()
		return

	_reasons[reason] = true
	_show()


## Something the screen was covering finished.
func end(reason: StringName) -> void:
	_reasons.erase(reason)
	if reason == REASON_CONTENT:
		_pending_content_at = -1.0
	if _reasons.is_empty():
		_hide(true)


func is_showing() -> bool:
	return _visible


## The download's progress, 0..1, and what it is doing. Negative is "no fraction".
func set_progress(fraction: float, text: String = "", detail: String = "") -> void:
	_last_activity = _now()
	if _bar == null:
		return
	if fraction >= 0.0:
		_bar.value = clampf(fraction, 0.0, 1.0) * 100.0
		if "indeterminate" in _bar:
			_bar.indeterminate = false
	elif "indeterminate" in _bar:
		_bar.indeterminate = true
	if text != "":
		_status.text = text
	_detail.text = detail
	_detail.visible = detail != ""


func _in_game() -> bool:
	return in_game_fn.is_valid() and bool(in_game_fn.call())


func _process(_delta: float) -> void:
	var now := _now()

	if _pending_content_at >= 0.0 and now - _pending_content_at >= show_delay_sec:
		_pending_content_at = -1.0
		if _reasons.has(REASON_CONTENT) and _in_game():
			_show()

	if _visible:
		if now - _last_activity > STALE_SEC:
			DotLog.info(CHANNEL, "the loading screen had nothing under it for a while; taking it down", {})
			_reasons.clear()
			_hide(false)
			return
		if _tips.size() > 1 and now - _tip_at > TIP_SEC:
			_tip_index = (_tip_index + 1) % _tips.size()
			_tip_at = now
			_tip.text = _tips[_tip_index]
		# A picture that was still downloading when the screen went up.
		if _image.texture == null and not (_entry.get("images", []) as Array).is_empty():
			_apply_image()

	if _next_at >= 0.0 and now - _next_at > HINT_TTL_SEC and not _visible:
		_next = {}
		_next_at = -1.0


# --- Which screen ------------------------------------------------------------------

## The entry for what is loading now: the map's, over the game's, over the default, one
## field at a time.
func current_entry() -> Dictionary:
	var layers: Array = []
	if not _next.is_empty() and str(_next.get("map", "")) != "":
		layers.append(_next["entry"])
	var game := _game_id
	if not _next.is_empty() and str(_next.get("game", "")) != "":
		game = str(_next["game"])
		layers.append(_next["entry"])
	if game != "" and (_doc.get("games", {}) as Dictionary).has(game):
		layers.append(_doc["games"][game])
	layers.append(_doc.get("default", {}))

	var out := {}
	for key in ["images", "music", "tips", "title", "volume", "done"]:
		for layer_entry in layers:
			if (layer_entry as Dictionary).has(key):
				out[key] = layer_entry[key]
				break
	return out


func _apply_entry() -> void:
	_entry = current_entry()
	_title.text = str(_entry.get("title", ""))
	_title.visible = _title.text != ""
	_tips = (_entry.get("tips", []) as Array).duplicate()
	_tips.shuffle()
	_tip_index = 0
	_tip_at = _now()
	_tip.text = _tips[0] if not _tips.is_empty() else ""
	_tip.visible = not _tips.is_empty()
	_apply_image()


func _apply_image() -> void:
	var images: Array = _entry.get("images", [])
	var ready: Array = images.filter(func(u: String) -> bool: return _media.get(u) is Texture2D)
	_image.texture = _media[ready.pick_random()] if not ready.is_empty() else null


# --- Showing -----------------------------------------------------------------------

func _show() -> void:
	if _visible:
		return
	_visible = true
	_shown_at = _now()
	_last_activity = _shown_at
	_apply_entry()
	_status.text = "Loading %s…" % _game_name if _game_name != "" else "Loading…"
	_detail.visible = false
	_bar.value = 0.0
	if "indeterminate" in _bar:
		_bar.indeterminate = true
	_root.visible = true
	_fade_to(1.0)
	_start_music()
	# Only offered when there is something to mute.
	_hint.visible = not (_entry.get("music", []) as Array).is_empty()


func _hide(finished: bool) -> void:
	_pending_content_at = -1.0
	if not _visible:
		return
	_visible = false
	_next = {}
	_next_at = -1.0
	_stop_music()
	if finished and _now() - _shown_at > 1.0:
		_play_done()
	_fade_to(0.0)


func _fade_to(alpha: float) -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	if not is_inside_tree():
		_root.modulate.a = alpha
		_root.visible = alpha > 0.0
		return
	_fade = create_tween()
	_fade.tween_property(_root, "modulate:a", alpha, FADE_SEC)
	if alpha == 0.0:
		_fade.tween_callback(func() -> void:
			if not _visible:
				_root.visible = false)


# --- Music -------------------------------------------------------------------------

func _start_music() -> void:
	var songs: Array = (_entry.get("music", []) as Array).filter(
		func(u: String) -> bool: return _media.get(u) is AudioStream)
	if songs.is_empty():
		return
	_music.stream = _media[songs.pick_random()]
	_music.volume_db = -60.0
	_music.play()
	_fade_music(_music_db(), MUSIC_FADE_IN_SEC)


func _stop_music() -> void:
	if not _music.playing:
		return
	_fade_music(-60.0, MUSIC_FADE_OUT_SEC, true)


func _music_db() -> float:
	if music_muted:
		return -80.0
	return linear_to_db(maxf(float(_entry.get("volume", 0.6)), 0.0001))


func _fade_music(db: float, seconds: float, then_stop: bool = false) -> void:
	if _music_fade != null and _music_fade.is_valid():
		_music_fade.kill()
	if not is_inside_tree():
		_music.volume_db = db
		if then_stop:
			_music.stop()
		return
	_music_fade = create_tween()
	_music_fade.tween_property(_music, "volume_db", db, seconds)
	if then_stop:
		_music_fade.tween_callback(_music.stop)


func _on_music_finished() -> void:
	# Looped by hand: the three formats each spell looping differently, and WAV needs a
	# loop end the file may not carry.
	if _visible:
		_music.play()


func _play_done() -> void:
	var url := str(_entry.get("done", ""))
	if url == "" or music_muted or not (_media.get(url) is AudioStream):
		return
	_done.stream = _media[url]
	_done.volume_db = _music_db()
	_done.play()


## M on the loading screen. Public for a suite.
func toggle_mute() -> void:
	music_muted = not music_muted
	_save_prefs()
	_update_hint()
	if _music.playing:
		_fade_music(_music_db(), 0.2)


func _unhandled_input(event: InputEvent) -> void:
	if not _visible or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if (event as InputEventKey).keycode == KEY_M:
		toggle_mute()
		get_viewport().set_input_as_handled()


func _update_hint() -> void:
	if _hint != null:
		_hint.text = "M  unmute music" if music_muted else "M  mute music"


func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS) == OK:
		music_muted = bool(cfg.get_value("loading", "music_muted", false))


func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("loading", "music_muted", music_muted)
	if cfg.save(PREFS) != OK:
		DotLog.debug(CHANNEL, "could not keep the music setting", {"path": PREFS})
		return
	# user:// in a browser is an IndexedDB mirror that is only written when asked.
	DotWeb.sync_filesystem()


# --- Fetching ----------------------------------------------------------------------

## Whether [param url] is one this client will fetch: absolute http(s), one token, bounded.
##
## `TmcLoading.is_safe_url` on the server is the same rule, written twice because `host/`
## is not in the client build. The server's is so an owner hears about a bad URL at boot;
## this one is the one that counts, because a server is not where a client gets to decide
## what it reads.
static func is_safe_url(url: String) -> bool:
	if url == "" or url.length() > MAX_URL:
		return false
	for bad in [" ", "\n", "\r", "\t", "\"", "\\"]:
		if url.contains(bad):
			return false
	var lower := url.to_lower()
	if not (lower.begins_with("https://") or lower.begins_with("http://")):
		return false
	var host := url.substr(url.find("//") + 2)
	return host != "" and not host.begins_with("/")


func _clean_entry(raw: Variant) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	var d := raw as Dictionary
	for key in ["images", "music"]:
		var urls: Array = []
		for u in (d.get(key, []) if d.get(key, []) is Array else []):
			if is_safe_url(str(u)):
				urls.append(str(u))
		if not urls.is_empty():
			out[key] = urls
	if is_safe_url(str(d.get("done", ""))):
		out["done"] = str(d["done"])
	var tips: Array = []
	for t in (d.get("tips", []) if d.get("tips", []) is Array else []):
		var clean := DotNotice.sanitised_string(t, 160)
		if clean != "":
			tips.append(clean)
	if not tips.is_empty():
		out["tips"] = tips
	var title := DotNotice.sanitised_string(d.get("title", ""), 64)
	if title != "":
		out["title"] = title
	if d.has("volume") and (d["volume"] is float or d["volume"] is int):
		out["volume"] = clampf(float(d["volume"]), 0.0, 1.0)
	return out


func _prefetch_entry(entry: Dictionary) -> void:
	var urls: Array = []
	urls.append_array(entry.get("images", []))
	urls.append_array(entry.get("music", []))
	if entry.has("done"):
		urls.append(entry["done"])
	for url in urls:
		if _media.has(url) or _media.size() >= MAX_PREFETCH:
			continue
		_media[url] = null
		_queue.append(url)
	_pump()


func _pump() -> void:
	if _fetching or _queue.is_empty() or not is_inside_tree():
		return
	var url: String = _queue.pop_front()
	_fetching = true

	var request := HTTPRequest.new()
	var audio := _is_audio_url(url)
	request.body_size_limit = MAX_AUDIO_BYTES if audio else MAX_IMAGE_BYTES
	request.timeout = 30.0
	add_child(request)
	request.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		request.queue_free()
		_fetching = false
		var media: Variant = null
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			media = decode(body)
		if media == null:
			DotLog.info(CHANNEL, "a loading screen file could not be used", {
				"url": url, "result": result, "status": code, "bytes": body.size(),
			})
			_media[url] = false
		else:
			_media[url] = media
		_pump()
	)
	if request.request(url) != OK:
		request.queue_free()
		_fetching = false
		_media[url] = false
		_pump()


func _is_audio_url(url: String) -> bool:
	for entry in _all_entries():
		if (entry.get("music", []) as Array).has(url) or str(entry.get("done", "")) == url:
			return true
	return false


func _all_entries() -> Array:
	var out: Array = [_doc.get("default", {})]
	out.append_array((_doc.get("games", {}) as Dictionary).values())
	if not _next.is_empty():
		out.append(_next["entry"])
	return out


## A texture or a stream out of bytes, by what the bytes are. Null for anything else.
static func decode(body: PackedByteArray) -> Variant:
	if body.size() < 12:
		return null

	var image := Image.new()
	var loaded := ERR_FILE_UNRECOGNIZED

	if body[0] == 0x89 and body[1] == 0x50 and body[2] == 0x4E and body[3] == 0x47:
		loaded = image.load_png_from_buffer(body)
	elif body[0] == 0xFF and body[1] == 0xD8:
		loaded = image.load_jpg_from_buffer(body)
	elif body.slice(0, 4).get_string_from_ascii() == "RIFF" and body.slice(8, 12).get_string_from_ascii() == "WEBP":
		loaded = image.load_webp_from_buffer(body)
	elif body.slice(0, 4).get_string_from_ascii() == "OggS":
		return AudioStreamOggVorbis.load_from_buffer(body)
	elif body.slice(0, 4).get_string_from_ascii() == "RIFF" and body.slice(8, 12).get_string_from_ascii() == "WAVE":
		return AudioStreamWAV.load_from_buffer(body)
	elif body.slice(0, 3).get_string_from_ascii() == "ID3" or (body[0] == 0xFF and (body[1] & 0xE0) == 0xE0):
		var mp3 := AudioStreamMP3.new()
		mp3.data = body
		return mp3 if mp3.get_length() > 0.0 else null
	else:
		return null

	if loaded != OK or image.is_empty():
		return null
	# A 4 MB JPEG can be 8000 pixels wide, which is a quarter of a gigabyte of video memory
	# for a picture drawn at the window's size.
	if image.get_width() > MAX_IMAGE_SIDE or image.get_height() > MAX_IMAGE_SIDE:
		var scale := float(MAX_IMAGE_SIDE) / maxf(image.get_width(), image.get_height())
		image.resize(maxi(int(image.get_width() * scale), 1), maxi(int(image.get_height() * scale), 1))
	return ImageTexture.create_from_image(image)


# --- The view ----------------------------------------------------------------------

func _build_view() -> void:
	_root = Control.new()
	_root.name = "LoadingScreen"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.offset_left = 0.0
	_root.offset_top = 0.0
	_root.offset_right = 0.0
	_root.offset_bottom = 0.0
	# Takes the mouse while it is up: a click on a screen that says "loading" is not a shot.
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.theme = DotUiTheme.space().build()
	add_child(_root)

	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.02, 0.025, 0.05, 1.0)
	_full(_backdrop)
	_root.add_child(_backdrop)

	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full(_image)
	_root.add_child(_image)

	# Darker toward the bottom, where the text is: a bright screenshot behind white text is
	# white text nobody can read, and the owner's picture is not ours to choose.
	var shade := TextureRect.new()
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0, 0, 0, 0.05))
	gradient.set_color(1, Color(0, 0, 0, 0.85))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0, 0.35)
	texture.fill_to = Vector2(0, 1)
	shade.texture = texture
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full(shade)
	_root.add_child(shade)

	var bottom := MarginContainer.new()
	bottom.anchor_left = 0.0
	bottom.anchor_right = 1.0
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_left = 0.0
	bottom.offset_right = 0.0
	bottom.offset_top = -170.0
	bottom.offset_bottom = 0.0
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	for side in ["left", "right"]:
		bottom.add_theme_constant_override("margin_" + side, 40)
	bottom.add_theme_constant_override("margin_bottom", 32)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bottom)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.alignment = BoxContainer.ALIGNMENT_END
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 30)
	box.add_child(_title)

	_tip = Label.new()
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.modulate = Color(1, 1, 1, 0.85)
	box.add_child(_tip)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 18)
	box.add_child(_status)

	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0.0, 6.0)
	box.add_child(_bar)

	_detail = Label.new()
	_detail.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_detail)

	_hint = Label.new()
	_hint.anchor_left = 1.0
	_hint.anchor_right = 1.0
	_hint.offset_left = -220.0
	_hint.offset_right = -24.0
	_hint.offset_top = 20.0
	_hint.offset_bottom = 44.0
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.modulate = Color(1, 1, 1, 0.6)
	_root.add_child(_hint)
	_update_hint()

	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	_music.bus = &"Master"
	_music.finished.connect(_on_music_finished)
	add_child(_music)

	_done = AudioStreamPlayer.new()
	_done.name = "Done"
	_done.bus = &"Master"
	add_child(_done)


static func _full(control: Control) -> void:
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func describe() -> Dictionary:
	var fetched := 0
	var failed := 0
	for v in _media.values():
		if v is Object:
			fetched += 1
		elif v is bool:
			failed += 1
	return {
		"document": not _doc.is_empty(),
		"showing": _visible,
		"reasons": _reasons.keys().map(func(r: StringName) -> String: return String(r)),
		"game": _game_id,
		"next": _next.duplicate(),
		"media": {"known": _media.size(), "ready": fetched, "failed": failed, "queued": _queue.size()},
		"muted": music_muted,
		"image": _image.texture != null if _image != null else false,
	}
