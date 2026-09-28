## main_menu.gd - Cinematic main menu for CloudArena.
extends Control

var _status_label: Label
var _ip_field:     LineEdit
var _btn_local:    Button
var _btn_matchmake: Button
var _http_request: HTTPRequest


func _ready() -> void:
	_build_ui()
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		get_tree().root.set_meta("local_mode", false)
		get_tree().change_scene_to_file("res://scenes/game.tscn")


func _build_ui() -> void:
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.request_completed.connect(_on_matchmake_completed)

	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.04, 0.07, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var grad := ColorRect.new()
	grad.set_anchors_preset(Control.PRESET_FULL_RECT)
	grad.color = Color(0.06, 0.0, 0.14, 0.45)
	add_child(grad)

	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical   = Control.GROW_DIRECTION_BOTH
	center.custom_minimum_size = Vector2(440, 0)
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 16)
	add_child(center)

	var sub := Label.new()
	sub.text = "CLOUD-POWERED FIGHTING GAME"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.6, 0.4, 1.0, 0.85))
	center.add_child(sub)

	var title := Label.new()
	title.text = "CLOUD  ARENA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color.WHITE)
	center.add_child(title)

	var tw := create_tween().set_loops()
	tw.tween_property(title, "scale", Vector2(1.04, 1.04), 1.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(title, "scale", Vector2(1.0,  1.0),  1.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	var div := ColorRect.new()
	div.color = Color(0.55, 0.25, 1.0, 0.6)
	div.custom_minimum_size = Vector2(0, 2)
	center.add_child(div)

	_add_spacer(center, 10)

	_btn_local = _make_button("LOCAL PLAY  (2 Players, Same PC)", Color(0.45, 0.1, 0.9))
	_btn_local.pressed.connect(_on_local_pressed)
	center.add_child(_btn_local)

	var hint := Label.new()
	hint.text = "P1: WASD + J    |    P2: Arrow Keys + Numpad 0"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.75))
	center.add_child(hint)

	_add_spacer(center, 8)

	var or_lbl := Label.new()
	or_lbl.text = "--- ONLINE MULTIPLAYER ---"
	or_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	or_lbl.add_theme_font_size_override("font_size", 11)
	or_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.55))
	center.add_child(or_lbl)

	_ip_field = LineEdit.new()
	_ip_field.placeholder_text = "Matchmaker API URL"
	_ip_field.text = "http://127.0.0.1:8000"
	_ip_field.custom_minimum_size = Vector2(0, 44)
	_ip_field.add_theme_font_size_override("font_size", 15)
	center.add_child(_ip_field)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	center.add_child(row)

	_btn_matchmake = _make_button("MATCHMAKE", Color(0.1, 0.55, 0.4))
	_btn_matchmake.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_matchmake.pressed.connect(_on_matchmake_pressed)
	row.add_child(_btn_matchmake)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	center.add_child(_status_label)

	var ver := Label.new()
	ver.text = "v0.1.0  |  Powered by GCP"
	ver.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ver.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	ver.add_theme_font_size_override("font_size", 10)
	ver.add_theme_color_override("font_color", Color(0.35, 0.35, 0.45))
	add_child(ver)


func _add_spacer(parent: Control, h: int) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	parent.add_child(s)


func _make_button(txt: String, accent: Color) -> Button:
	var btn := Button.new()
	btn.text = txt
	btn.custom_minimum_size = Vector2(0, 52)
	btn.add_theme_font_size_override("font_size", 16)

	var base_col := Color(accent.r * 0.28, accent.g * 0.28, accent.b * 0.28, 0.95)

	var normal := StyleBoxFlat.new()
	normal.bg_color = base_col
	normal.border_color = accent
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		normal.set_border_width(side, 2)
	for c in [CORNER_TOP_LEFT, CORNER_TOP_RIGHT, CORNER_BOTTOM_LEFT, CORNER_BOTTOM_RIGHT]:
		normal.set_corner_radius(c, 8)
	btn.add_theme_stylebox_override("normal", normal)

	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(accent.r * 0.5, accent.g * 0.5, accent.b * 0.5, 1.0)
	hover.border_color = Color(accent.r + 0.15, accent.g + 0.15, accent.b + 0.15).clamp()
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		hover.set_border_width(side, 2)
	for c in [CORNER_TOP_LEFT, CORNER_TOP_RIGHT, CORNER_BOTTOM_LEFT, CORNER_BOTTOM_RIGHT]:
		hover.set_corner_radius(c, 8)
	btn.add_theme_stylebox_override("hover", hover)

	var pressed_sty := StyleBoxFlat.new()
	pressed_sty.bg_color = accent
	for c in [CORNER_TOP_LEFT, CORNER_TOP_RIGHT, CORNER_BOTTOM_LEFT, CORNER_BOTTOM_RIGHT]:
		pressed_sty.set_corner_radius(c, 8)
	btn.add_theme_stylebox_override("pressed", pressed_sty)

	return btn


func _on_local_pressed() -> void:
	get_tree().root.set_meta("local_mode", true)
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_matchmake_pressed() -> void:
	_set_all_disabled(true)
	var url := _ip_field.text.strip_edges()
	if url.is_empty():
		url = "http://127.0.0.1:8000"
	
	_status_label.text = "Requesting matchmaking..."
	
	var headers = ["Content-Type: application/json"]
	var body = JSON.stringify({"player_name": "Player_" + str(randi() % 1000)})
	
	var err = _http_request.request(url + "/match/join", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_status_label.text = "Failed to send matchmaking request."
		_set_all_disabled(false)


func _on_matchmake_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		_status_label.text = "Matchmaking failed: HTTP " + str(response_code)
		_set_all_disabled(false)
		return
		
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY or not json.has("ws_url"):
		_status_label.text = "Invalid matchmaking response."
		_set_all_disabled(false)
		return
		
	var ws_url: String = json["ws_url"]
	_status_label.text = "Joining " + ws_url + "..."
	
	get_tree().root.set_meta("local_mode", false)
	var net := _get_network_manager()
	if not net:
		_status_label.text = "ERROR: NetworkManager not found."
		_set_all_disabled(false)
		return
		
	var err: Error = net.join_game(ws_url)
	if err != OK:
		_status_label.text = "Failed to join: %s" % error_string(err)
		_set_all_disabled(false)
		return
		
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _set_all_disabled(d: bool) -> void:
	_btn_local.disabled = d
	_btn_matchmake.disabled = d


func _get_network_manager() -> Node:
	return get_node_or_null("/root/NetworkManager")