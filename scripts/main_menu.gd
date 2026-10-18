## main_menu.gd - Quiet, dark main menu: the title, three words, a fog-filled valley.
##
## Root:      Play / Settings / Quit
## Play:      Versus CPU / Two Players / Training / Online / Back
## Settings:  Audio / Video / Gameplay / Controls / Credits / Back
## Pages cross-fade into each other; Esc / B (ui_cancel) steps back one page.
extends Control

const UiStyle      := preload("res://scripts/ui_style.gd")
const ControlsPanel := preload("res://scripts/controls_panel.gd")
const MenuList     := preload("res://scripts/hk_menu_list.gd")
const Atmosphere   := preload("res://scripts/menu_atmosphere.gd")

const SELECT_SCENE: String = "res://scenes/character_select.tscn"
const GAME_TITLE: String = "CLOUD ARENA"
const COMPACT_PAGES: Array = ["controls", "board", "credits"]
const LIST_TOP: float = 330.0

var _title: Label
var _divider: Control
var _pages: Dictionary = {}        # id -> {"root": Control, "list": MenuList or null}
var _stack: Array[String] = []
var _current: String = ""
var _busy: bool = true
var _compact: bool = false
var _title_y0: float = INF

# online page widgets
var _server_url: String = ""
var _user_name: String = ""
var _user_pass: String = ""
var _status_label: Label
var _auth_busy: bool = false
var _board_label: Label
var _board_http: HTTPRequest
var _last_sfx_preview: int = 0


class Divider extends Control:
	func _draw() -> void:
		var cx := size.x * 0.5
		var half := 190.0
		var c := Color(0.75, 0.82, 1.0, 0.55)
		var clear := Color(0.75, 0.82, 1.0, 0.0)
		draw_polygon(PackedVector2Array([Vector2(cx - half, 0), Vector2(cx - 14, 0), Vector2(cx - 14, 1), Vector2(cx - half, 1)]), PackedColorArray([clear, c, c, clear]))
		draw_polygon(PackedVector2Array([Vector2(cx + 14, 0), Vector2(cx + half, 0), Vector2(cx + half, 1), Vector2(cx + 14, 1)]), PackedColorArray([c, clear, clear, c]))
		var d := Vector2(cx, 0.5)
		draw_colored_polygon(PackedVector2Array([d + Vector2(0, -5), d + Vector2(5, 0), d + Vector2(0, 5), d + Vector2(-5, 0)]), c)


func _ready() -> void:
	# Dedicated server builds skip the UI and go straight to hosting.
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		if NetworkManager.is_server:
			get_tree().root.set_meta("local_mode", false)
			get_tree().change_scene_to_file.call_deferred("res://scenes/game.tscn")
		# A headless client (bot) is moved to the game scene by NetworkManager once connected.
		return
	AudioManager.play_music("menu")
	RenderingServer.set_default_clear_color(Color(0.012, 0.016, 0.034))
	_build_scene()
	_intro()


func _input(event: InputEvent) -> void:
	if _busy:
		return
	if event.is_action_pressed("ui_cancel") and not _is_typing():
		if _stack.size() > 1:
			_back()
			get_viewport().set_input_as_handled()


func _is_typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit


# ── Scene construction ──────────────────────────────────────────────────────

func _build_scene() -> void:
	var atmosphere := Atmosphere.new()
	add_child(atmosphere)

	_title = UiStyle.serif_label(GAME_TITLE, 92, Color(0.87, 0.9, 0.98, 0.0), 16)
	_title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_title.offset_left = -640
	_title.offset_right = 640
	_title.offset_top = 70
	_title.offset_bottom = 200
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.pivot_offset = Vector2(640, 65)
	_title.add_theme_constant_override("outline_size", 12)
	_title.add_theme_color_override("font_outline_color", Color(0.7, 0.8, 1.0, 0.07))
	add_child(_title)

	_divider = Divider.new()
	_divider.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_divider.offset_left = -300
	_divider.offset_right = 300
	_divider.offset_top = 222
	_divider.offset_bottom = 232
	_divider.pivot_offset = Vector2(300, 5)
	_divider.modulate.a = 0.0
	_divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_divider)

	_board_http = HTTPRequest.new()
	_board_http.timeout = 8.0
	add_child(_board_http)
	_board_http.request_completed.connect(_on_leaderboard_response)
	Account.request_done.connect(_on_account_result)


func _intro() -> void:
	# Fade up from black: the title first, slowly, then the options.
	var veil := ColorRect.new()
	veil.color = Color(0.005, 0.007, 0.015, 1.0)
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(veil, "color:a", 0.0, 1.6)
	tw.tween_property(_title, "theme_override_colors/font_color", Color(0.87, 0.9, 0.98, 0.95), 2.4).set_delay(0.5)
	tw.tween_property(_divider, "modulate:a", 1.0, 1.8).set_delay(1.4)
	await get_tree().create_timer(1.9).timeout
	veil.queue_free()
	_stack = ["root"]
	_current = ""
	await _show_page("root")
	_start_title_breath()


func _start_title_breath() -> void:
	var tw := create_tween().set_loops()
	tw.tween_property(_title, "modulate:a", 0.82, 4.0).set_trans(Tween.TRANS_SINE)
	tw.tween_property(_title, "modulate:a", 1.0, 4.0).set_trans(Tween.TRANS_SINE)


# ── Page system ─────────────────────────────────────────────────────────────

func _push(id: String) -> void:
	if _busy:
		return
	_stack.append(id)
	_show_page(id)


func _back() -> void:
	if _busy or _stack.size() <= 1:
		return
	_stack.pop_back()
	AudioManager.play("ui_back", -6.0)
	_show_page(_stack.back())


func _show_page(id: String) -> void:
	_busy = true
	var old: Dictionary = _pages.get(_current, {})
	if not old.is_empty():
		if old["list"]:
			old["list"].active = false
		var out := create_tween().set_parallel(true)
		out.tween_property(old["root"], "modulate:a", 0.0, 0.22)
		out.tween_property(old["root"], "position:y", -8.0, 0.22)
		await out.finished
		old["root"].visible = false
	_current = id
	if not _pages.has(id):
		_pages[id] = _build_page(id)
	var pg: Dictionary = _pages[id]
	_set_compact(id in COMPACT_PAGES)
	pg["root"].visible = true
	pg["root"].modulate.a = 0.0
	pg["root"].position.y = 8.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(pg["root"], "modulate:a", 1.0, 0.4)
	tw.tween_property(pg["root"], "position:y", 0.0, 0.4).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	if pg["list"]:
		pg["list"].reveal()
	await get_tree().create_timer(0.35).timeout
	if pg["list"]:
		pg["list"].active = true
		pg["list"].set_focus(0, false)
	_busy = false
	if id == "online" and Account.is_signed_in():
		Account.verify(_server_url if _server_url != "" else GameSettings.online_api)


## Deep pages (controls, leaderboard...) need the room, so the title shrinks and rises.
func _set_compact(on: bool) -> void:
	if on == _compact:
		return
	_compact = on
	if _title_y0 == INF:
		_title_y0 = _title.position.y
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_title, "scale", Vector2(0.5, 0.5) if on else Vector2.ONE, 0.5).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(_title, "position:y", _title_y0 - 78.0 if on else _title_y0, 0.5).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(_divider, "modulate:a", 0.0 if on else 1.0, 0.4)


func _new_page(items: Array, top: float = LIST_TOP) -> Dictionary:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.visible = false
	add_child(root)
	var list := MenuList.new()
	root.add_child(list)
	list.set_items(items, -1)
	list.offset_top = top
	list.cancelled.connect(_back)
	return {"root": root, "list": list}


func _build_page(id: String) -> Dictionary:
	match id:
		"root":     return _page_root()
		"play":     return _page_play()
		"settings": return _page_settings()
		"audio":    return _page_audio()
		"video":    return _page_video()
		"gameplay": return _page_gameplay()
		"controls": return _page_controls()
		"credits":  return _page_credits()
		"online":   return _page_online()
		"board":    return _page_board()
	push_error("Unknown menu page " + id)
	return _page_root()


# ── Pages ───────────────────────────────────────────────────────────────────

func _page_root() -> Dictionary:
	var pg := _new_page([{"text": "Play"}, {"text": "Settings"}, {"text": "Quit"}], 340.0)
	pg["list"].activated.connect(_on_root_item)
	return pg


func _on_root_item(i: int) -> void:
	match i:
		0: _push("play")
		1: _push("settings")
		2: _quit()


func _quit() -> void:
	_busy = true
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.6)
	await tw.finished
	get_tree().quit()


func _page_play() -> Dictionary:
	var pg := _new_page([{"text": "Versus CPU"}, {"text": "Two Players"}, {"text": "Training"}, {"text": "Online"}, {"text": "Back"}], 300.0)
	pg["list"].activated.connect(_on_play_item)
	return pg


func _on_play_item(i: int) -> void:
	match i:
		0: _start_mode(true, false)
		1: _start_mode(false, false)
		2: _start_mode(true, true)
		3: _push("online")
		4: _back()


func _start_mode(vs_cpu: bool, training: bool) -> void:
	var root := get_tree().root
	root.set_meta("online", false)
	root.set_meta("local_mode", true)
	root.set_meta("vs_cpu", vs_cpu)
	root.set_meta("training", training)
	_busy = true
	Transition.go(SELECT_SCENE)


func _page_settings() -> Dictionary:
	var pg := _new_page([{"text": "Audio"}, {"text": "Video"}, {"text": "Gameplay"}, {"text": "Controls"}, {"text": "Credits"}, {"text": "Back"}], 300.0)
	pg["list"].activated.connect(_on_settings_item)
	return pg


func _on_settings_item(i: int) -> void:
	match i:
		0: _push("audio")
		1: _push("video")
		2: _push("gameplay")
		3: _push("controls")
		4: _push("credits")
		5: _back()


func _page_audio() -> Dictionary:
	var pg := _new_page([
		{"text": "Music", "slider": AudioManager.music_volume},
		{"text": "Sound", "slider": AudioManager.sfx_volume},
		{"text": "Back"}], 340.0)
	pg["list"].slider_changed.connect(func(i: int, v: float) -> void:
		if i == 0:
			AudioManager.set_music_volume(v)
		else:
			AudioManager.set_sfx_volume(v)
			var now := Time.get_ticks_msec()
			if now - _last_sfx_preview > 220:
				_last_sfx_preview = now
				AudioManager.play("hit_light", -4.0))
	pg["list"].activated.connect(func(i: int) -> void:
		if i == 2:
			_back())
	return pg


func _on_off(v: bool) -> String:
	return "On" if v else "Off"


func _page_video() -> Dictionary:
	var pg := _new_page([
		{"text": "Fullscreen", "value": _on_off(GameSettings.fullscreen)},
		{"text": "Screen Shake", "value": _on_off(GameSettings.screen_shake)},
		{"text": "Foreground Haze", "value": _on_off(GameSettings.fg_blur)},
		{"text": "Back"}], 320.0)
	var list = pg["list"]
	var toggle := func(i: int) -> void:
		match i:
			0: GameSettings.set_fullscreen(not GameSettings.fullscreen)
			1: GameSettings.set_screen_shake(not GameSettings.screen_shake)
			2: GameSettings.set_fg_blur(not GameSettings.fg_blur)
		list.set_value_text(0, _on_off(GameSettings.fullscreen))
		list.set_value_text(1, _on_off(GameSettings.screen_shake))
		list.set_value_text(2, _on_off(GameSettings.fg_blur))
	list.activated.connect(func(i: int) -> void:
		if i == 3:
			_back()
		else:
			toggle.call(i))
	list.adjusted.connect(func(i: int, _d: int) -> void: toggle.call(i))
	return pg


func _page_gameplay() -> Dictionary:
	var pg := _new_page([
		{"text": "CPU Difficulty", "value": str(GameSettings.LEVEL_NAMES[GameSettings.cpu_level]).capitalize()},
		{"text": "Rounds To Win", "value": str(GameSettings.rounds_to_win)},
		{"text": "Round Time", "value": _time_text()},
		{"text": "Back"}], 320.0)
	var list = pg["list"]
	var cycle := func(i: int) -> void:
		match i:
			0: GameSettings.cycle_cpu_level()
			1: GameSettings.cycle_rounds()
			2: GameSettings.cycle_round_time()
		list.set_value_text(0, str(GameSettings.LEVEL_NAMES[GameSettings.cpu_level]).capitalize())
		list.set_value_text(1, str(GameSettings.rounds_to_win))
		list.set_value_text(2, _time_text())
	list.activated.connect(func(i: int) -> void:
		if i == 3:
			_back()
		else:
			cycle.call(i))
	list.adjusted.connect(func(i: int, _d: int) -> void: cycle.call(i))
	return pg


func _time_text() -> String:
	return str(GameSettings.round_seconds()) if GameSettings.round_seconds() > 0 else "None"


func _page_controls() -> Dictionary:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.visible = false
	add_child(root)
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_CENTER_TOP)
	holder.offset_left = -500
	holder.offset_right = 500
	holder.offset_top = 96
	holder.offset_bottom = 696
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(holder)
	var panel := ControlsPanel.new()
	panel.back_requested.connect(_back)
	holder.add_child(panel)
	return {"root": root, "list": null}


func _page_credits() -> Dictionary:
	var pg := _new_page([{"text": "Back"}], 560.0)
	var lines := [
		["Fighter sprites", "Craftpix.net"],
		["Music", "wipics  -  Kistol  -  pmiller  -  Xythe / mutkanto  (OpenGameArt)"],
		["Sound", "Kenney.nl  (CC0)"],
		["Engine", "Godot"],
	]
	for i in range(lines.size()):
		var h := UiStyle.serif_label(lines[i][0], 17, Color(0.5, 0.54, 0.68))
		h.set_anchors_preset(Control.PRESET_CENTER_TOP)
		h.offset_left = -400
		h.offset_right = 400
		h.offset_top = 150 + i * 88
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pg["root"].add_child(h)
		var d := UiStyle.serif_label(lines[i][1], 24, UiStyle.ASH)
		d.set_anchors_preset(Control.PRESET_CENTER_TOP)
		d.offset_left = -500
		d.offset_right = 500
		d.offset_top = 176 + i * 88
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pg["root"].add_child(d)
	pg["list"].activated.connect(func(_i: int) -> void: _back())
	return pg


## Invisible LineEdit that captures typing for one list row; the row's value text mirrors it.
## Keeps the whole form keyboard / pad friendly: activate the row, type, press Enter.
func _hook_field(root: Control, list, row: int, initial: String, secret: bool, max_len: int, on_change: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.text = initial
	le.secret = false
	le.max_length = max_len
	le.modulate.a = 0.0
	le.size = Vector2(240, 30)
	le.mouse_filter = Control.MOUSE_FILTER_IGNORE
	le.focus_mode = Control.FOCUS_CLICK
	root.add_child(le)
	var show := func(editing: bool) -> void:
		var t: String = "*".repeat(le.text.length()) if secret else le.text
		if editing:
			t += "_"
		list.set_value_text(row, t if t != "" else "-")
		on_change.call(le.text)
	show.call(false)
	le.text_changed.connect(func(_t: String) -> void: show.call(true))
	le.focus_entered.connect(func() -> void:
		list.active = false
		show.call(true))
	le.focus_exited.connect(func() -> void:
		list.active = true
		show.call(false))
	le.text_submitted.connect(func(_t: String) -> void:
		le.release_focus()
		list.set_focus(mini(row + 1, list.items.size() - 1)))
	return le


func _status_line(root: Control, top: float) -> Label:
	var l := UiStyle.serif_label("", 18, Color(0.75, 0.6, 0.55))
	l.set_anchors_preset(Control.PRESET_CENTER_TOP)
	l.offset_left = -420
	l.offset_right = 420
	l.offset_top = top
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(l)
	return l


func _page_online() -> Dictionary:
	if _server_url == "":
		_server_url = GameSettings.online_api
	var signed := Account.is_signed_in()
	var items: Array
	if signed:
		items = [{"text": "Server", "value": "-"}, {"text": "Find Match"}, {"text": "Leaderboard"}, {"text": "Sign Out"}, {"text": "Back"}]
	else:
		items = [{"text": "Server", "value": "-"}, {"text": "Name", "value": "-"}, {"text": "Password", "value": "-"},
			{"text": "Sign In"}, {"text": "Create Account"}, {"text": "Back"}]
	var pg := _new_page(items, 330.0 if signed else 296.0)
	var root: Control = pg["root"]
	var list = pg["list"]

	var head := UiStyle.serif_label(("Signed in as  " + Account.username) if signed else "An account is needed to play online.", 22, UiStyle.ASH)
	head.set_anchors_preset(Control.PRESET_CENTER_TOP)
	head.offset_left = -420
	head.offset_right = 420
	head.offset_top = 258
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(head)
	_status_label = _status_line(root, 664.0)

	var fields: Array = []
	fields.append(_hook_field(root, list, 0, _server_url, false, 100, func(t: String) -> void: _server_url = t.strip_edges()))
	if not signed:
		fields.append(_hook_field(root, list, 1, _user_name, false, 16, func(t: String) -> void: _user_name = t.strip_edges()))
		fields.append(_hook_field(root, list, 2, "", true, 64, func(t: String) -> void: _user_pass = t))
		_user_pass = ""
	list.activated.connect(func(i: int) -> void: _on_online_item(i, fields))
	return pg


func _on_online_item(i: int, fields: Array) -> void:
	if i == 0 or (not Account.is_signed_in() and (i == 1 or i == 2)):
		fields[i].grab_focus()
		fields[i].caret_column = fields[i].text.length()
		return
	if Account.is_signed_in():
		match i:
			1: _on_matchmake_pressed()
			2: _on_leaderboard_pressed()
			3: _sign_out()
			4: _back()
	else:
		match i:
			3: _submit_account(false)
			4: _submit_account(true)
			5: _back()


func _submit_account(create: bool) -> void:
	if _auth_busy:
		return
	var problem := Account.validate(_user_name, _user_pass)
	if not problem.is_empty():
		_status_label.text = problem
		AudioManager.play("ui_error")
		return
	GameSettings.set_online(_server_url, "")
	_auth_busy = true
	_status_label.text = "Creating the account..." if create else "Signing in..."
	if create:
		Account.create_account(_server_url, _user_name, _user_pass)
	else:
		Account.sign_in(_server_url, _user_name, _user_pass)


func _sign_out() -> void:
	Account.sign_out()
	_user_pass = ""
	_refresh_online("You have signed out.")


func _on_account_result(ok: bool, message: String) -> void:
	var was_busy := _auth_busy
	_auth_busy = false
	if _current != "online":
		return
	if ok and was_busy:
		_user_pass = ""
		_refresh_online("")
	elif not ok:
		if not Account.is_signed_in() and not was_busy and message != "":
			_refresh_online(message)         # stored session was rejected
		elif _status_label:
			_status_label.text = message
			AudioManager.play("ui_error")


## Rebuild the online page after signing in/out (its rows depend on the account state).
func _refresh_online(message: String) -> void:
	if not _pages.has("online"):
		return
	var old: Dictionary = _pages["online"]
	_pages.erase("online")
	old["root"].queue_free()
	await _show_page("online")
	if _status_label:
		_status_label.text = message


func _page_board() -> Dictionary:
	var pg := _new_page([{"text": "Back"}], 560.0)
	_board_label = UiStyle.serif_label("", 26, UiStyle.ASH)
	_board_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_board_label.offset_left = -300
	_board_label.offset_right = 300
	_board_label.offset_top = 140
	_board_label.offset_bottom = 540
	_board_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_board_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pg["root"].add_child(_board_label)
	pg["list"].activated.connect(func(_i: int) -> void: _back())
	return pg


# ── Online ──────────────────────────────────────────────────────────────────

func _on_matchmake_pressed() -> void:
	var url := _server_url.strip_edges()
	if url.is_empty():
		url = "http://127.0.0.1:8000"
	GameSettings.set_online(url, "")
	NetworkManager.player_name = Account.username
	var root := get_tree().root
	root.set_meta("online", true)
	root.set_meta("online_api", url)
	root.set_meta("local_mode", false)
	root.set_meta("training", false)
	_busy = true
	Transition.go(SELECT_SCENE)


func _on_leaderboard_pressed() -> void:
	var url := _server_url.strip_edges().trim_suffix("/")
	_push("board")
	_board_label.text = "..."
	if _board_http.request(url + "/stats/leaderboard?top=10") != OK:
		_board_label.text = "The server cannot be reached."


func _on_leaderboard_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _board_label == null:
		return
	if code != 200:
		_board_label.text = "The ledger is unavailable (%d)." % code
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY or not json.has("leaderboard"):
		_board_label.text = "The ledger is unreadable."
		return
	var rows: Array = json["leaderboard"]
	if rows.is_empty():
		_board_label.text = "No victories have been recorded."
		return
	var txt := ""
	for r in rows:
		txt += "%d.   %s   -   %d\n" % [int(r["rank"]), str(r["player_name"]), int(r["wins"])]
	_board_label.text = txt
