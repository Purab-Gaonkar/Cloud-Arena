## main_menu.gd - Animated main menu for CloudArena.
## Shows a living arena (parallax world + sparring fighters) behind a stylised button column.
extends Control

const UiStyle      := preload("res://scripts/ui_style.gd")
const FighterData  := preload("res://scripts/fighter_data.gd")
const WorldBuilder := preload("res://scripts/world_builder.gd")

const SELECT_SCENE: String = "res://scenes/character_select.tscn"
const FIGHTER_SCALE: float = 2.2

var _world: Node2D
var _t: float = 0.0
var _showcase: Array = []   # [{"sprite": AnimatedSprite2D, "timer": float}]

var _buttons: Array[Button] = []
var _modal_online: Control
var _modal_controls: Control
var _modal_options: Control
var _status_label: Label
var _ip_field: LineEdit
var _btn_matchmake: Button
var _http_request: HTTPRequest


func _ready() -> void:
	# Dedicated server builds skip the UI and go straight to hosting.
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		get_tree().root.set_meta("local_mode", false)
		get_tree().change_scene_to_file("res://scenes/game.tscn")
		return
	AudioManager.play_music("menu")
	_build_world()
	_build_ui()
	_play_intro()


func _process(delta: float) -> void:
	_t += delta
	if _world:
		_world.update_parallax(sin(_t * 0.12) * 380.0)
	for s in _showcase:
		s["timer"] -= delta
		if s["timer"] <= 0.0:
			s["timer"] = randf_range(1.4, 3.6)
			var sprite: AnimatedSprite2D = s["sprite"]
			var moves := ["attack_1", "attack_2", "attack_3", "block", "jump", "attack_1"]
			sprite.play(moves[randi() % moves.size()])


func _input(event: InputEvent) -> void:
	if _modal_online and event.is_action_pressed("ui_cancel") and (_modal_online.visible or _modal_controls.visible or _modal_options.visible):
		_close_modals()
		get_viewport().set_input_as_handled()


# ── World ───────────────────────────────────────────────────────────────────

func _build_world() -> void:
	_world = WorldBuilder.new()
	_world.position = Vector2(640, 640.0 - WorldBuilder.GROUND_Y)
	add_child(_world)
	_world.build(randi() % WorldBuilder.stage_count())

	# [fighter, world x, faces left]
	var cast := [["Samurai", 170.0, false], ["Shinobi", 360.0, true], ["Fighter", 520.0, true]]
	for c in cast:
		var sprite := AnimatedSprite2D.new()
		sprite.sprite_frames = FighterData.build_frames(c[0])
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.scale = Vector2(FIGHTER_SCALE, FIGHTER_SCALE)
		sprite.flip_h = c[2]
		sprite.position = Vector2(c[1], WorldBuilder.GROUND_Y - 63.5 * FIGHTER_SCALE)
		sprite.play("idle")
		sprite.animation_finished.connect(_on_showcase_finished.bind(sprite))
		_world.add_child(sprite)
		_showcase.append({"sprite": sprite, "timer": randf_range(0.5, 2.5)})


func _on_showcase_finished(sprite: AnimatedSprite2D) -> void:
	if sprite.animation != "idle":
		sprite.play("idle")


# ── UI ──────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.request_completed.connect(_on_matchmake_completed)

	# Left-side shade so the logo and buttons stay readable over any stage.
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.02, 0.01, 0.06, 0.82), Color(0.02, 0.01, 0.06, 0.0)])
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill_from = Vector2(0, 0)
	gtex.fill_to = Vector2(0.55, 0)
	var shade := TextureRect.new()
	shade.texture = gtex
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var sub := UiStyle.label("CLOUD-POWERED ARENA FIGHTER", 20, UiStyle.GOLD, true, 6)
	sub.position = Vector2(86, 42)
	sub.size = Vector2(500, 28)
	sub.name = "Sub"
	add_child(sub)

	var t1 := UiStyle.label("CLOUD", 118, UiStyle.GOLD, true, 18)
	t1.position = Vector2(78, 62)
	t1.size = Vector2(500, 130)
	t1.name = "Title1"
	var t2 := UiStyle.label("ARENA", 118, Color.WHITE, true, 18)
	t2.position = Vector2(78, 170)
	t2.size = Vector2(500, 130)
	t2.name = "Title2"
	for t in [t1, t2]:
		t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
		t.add_theme_constant_override("shadow_offset_x", 7)
		t.add_theme_constant_override("shadow_offset_y", 7)
		add_child(t)

	var items := [
		["VS  CPU",   Color(0.95, 0.4, 0.15), _on_cpu_pressed],
		["LOCAL  2P", Color(0.55, 0.3, 1.0),  _on_local_pressed],
		["ONLINE",    Color(0.15, 0.7, 0.55), _on_online_pressed],
		["CONTROLS",  Color(0.25, 0.55, 0.95), _on_controls_pressed],
		["OPTIONS",   Color(0.85, 0.7, 0.2),  _on_options_pressed],
		["QUIT",      Color(0.75, 0.2, 0.3),  _on_quit_pressed],
	]
	for i in range(items.size()):
		var btn := UiStyle.button(items[i][0], items[i][1])
		btn.position = Vector2(86, 304 + i * 56)
		btn.size = Vector2(380, 48)
		btn.pressed.connect(items[i][2])
		add_child(btn)
		_buttons.append(btn)

	var ver := UiStyle.label("v0.2.0   |   Fighter sprites: Craftpix", 13, UiStyle.MUTED, false, 4)
	ver.position = Vector2(86, 690)
	ver.size = Vector2(500, 20)
	add_child(ver)

	_build_online_modal()
	_build_controls_modal()
	_build_options_modal()


func _play_intro() -> void:
	var targets: Array[Control] = [get_node("Sub"), get_node("Title1"), get_node("Title2")]
	targets.append_array(_buttons)
	for i in range(targets.size()):
		var n := targets[i]
		var end_x := n.position.x
		n.position.x = end_x - 360.0
		n.modulate.a = 0.0
		var tw := create_tween().set_parallel(true)
		tw.tween_property(n, "position:x", end_x, 0.6).set_delay(0.12 * i).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(n, "modulate:a", 1.0, 0.35).set_delay(0.12 * i)
	await get_tree().create_timer(0.12 * targets.size() + 0.7).timeout
	if not (_modal_online.visible or _modal_controls.visible or _modal_options.visible):
		_buttons[0].grab_focus()


func _make_modal(title: String, size_v: Vector2) -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.visible = false
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var panel := Panel.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(640, 360) - size_v * 0.5
	panel.size = size_v
	panel.pivot_offset = size_v * 0.5
	var st := UiStyle.box(Color(0.07, 0.05, 0.13, 0.97), UiStyle.GOLD, 3, 10)
	st.shadow_size = 24
	st.shadow_color = Color(0, 0, 0, 0.5)
	panel.add_theme_stylebox_override("panel", st)
	root.add_child(panel)

	var head := UiStyle.label(title, 38, UiStyle.GOLD, true, 8)
	head.position = Vector2(30, 18)
	head.size = Vector2(size_v.x - 60, 46)
	panel.add_child(head)
	var line := ColorRect.new()
	line.color = UiStyle.GOLD_DARK
	line.position = Vector2(30, 68)
	line.size = Vector2(size_v.x - 60, 3)
	panel.add_child(line)
	return root


func _show_modal(m: Control) -> void:
	AudioManager.play("ui_open")
	m.visible = true
	var panel: Control = m.get_node("Panel")
	panel.scale = Vector2(0.9, 0.9)
	panel.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(panel, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "modulate:a", 1.0, 0.15)


func _close_modals() -> void:
	AudioManager.play("ui_back")
	_modal_online.visible = false
	_modal_controls.visible = false
	_modal_options.visible = false
	for b in _buttons:
		b.disabled = false
	_buttons[0].grab_focus()


func _build_online_modal() -> void:
	_modal_online = _make_modal("ONLINE MATCH", Vector2(620, 340))
	var panel: Control = _modal_online.get_node("Panel")

	var hint := UiStyle.label("Matchmaker API address", 15, UiStyle.MUTED, false)
	hint.position = Vector2(30, 90)
	panel.add_child(hint)

	_ip_field = LineEdit.new()
	_ip_field.text = "http://127.0.0.1:8000"
	_ip_field.position = Vector2(30, 116)
	_ip_field.size = Vector2(560, 46)
	_ip_field.add_theme_font_override("font", UiStyle.body_font())
	_ip_field.add_theme_font_size_override("font_size", 18)
	_ip_field.add_theme_stylebox_override("normal", UiStyle.box(Color(0.03, 0.02, 0.07), UiStyle.GOLD_DARK, 2, 6))
	_ip_field.add_theme_stylebox_override("focus", UiStyle.box(Color(0.03, 0.02, 0.07), UiStyle.GOLD, 2, 6))
	panel.add_child(_ip_field)

	_btn_matchmake = UiStyle.button("FIND MATCH", Color(0.15, 0.7, 0.55))
	_btn_matchmake.position = Vector2(30, 184)
	_btn_matchmake.size = Vector2(270, 52)
	_btn_matchmake.pressed.connect(_on_matchmake_pressed)
	panel.add_child(_btn_matchmake)

	var back := UiStyle.button("BACK", Color(0.6, 0.6, 0.75))
	back.position = Vector2(320, 184)
	back.size = Vector2(270, 52)
	back.pressed.connect(_close_modals)
	panel.add_child(back)

	_status_label = UiStyle.label("", 17, UiStyle.GOLD, false)
	_status_label.position = Vector2(30, 256)
	_status_label.size = Vector2(560, 60)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_status_label)


func _build_controls_modal() -> void:
	_modal_controls = _make_modal("CONTROLS", Vector2(760, 530))
	var panel: Control = _modal_controls.get_node("Panel")
	var rows := [
		["", "PLAYER 1", "PLAYER 2"],
		["Move", "A / D", "Left / Right"],
		["Jump", "W  or  Space", "Up"],
		["Attack  (tap x3 = combo)", "J  or  Left Click", "/  or  Numpad 0"],
		["Block  (face your enemy)", "S  or  K", "Down  or  ."],
		["Heavy attack", "U", ",  or  Numpad 1"],
		["Super finisher  (meter full)", "I", "M  or  Numpad 2"],
		["Pause", "Esc", "Esc"],
	]
	var xs := [30.0, 300.0, 530.0]
	for r in range(rows.size()):
		for c in range(3):
			var head: bool = (r == 0)
			var col: Color = UiStyle.TEXT if c > 0 else UiStyle.MUTED
			if head and c == 1:
				col = UiStyle.P1
			elif head and c == 2:
				col = UiStyle.P2
			var l := UiStyle.label(rows[r][c], 26 if head else 20, col, head, 5 if head else 0)
			if not head:
				l.add_theme_font_override("font", UiStyle.body_font())
			l.position = Vector2(xs[c], 90 + r * 44)
			panel.add_child(l)
	var back := UiStyle.button("BACK", Color(0.6, 0.6, 0.75))
	back.position = Vector2(30, 465)
	back.size = Vector2(240, 46)
	back.pressed.connect(_close_modals)
	panel.add_child(back)


# ── Actions ─────────────────────────────────────────────────────────────────

func _on_local_pressed() -> void:
	get_tree().root.set_meta("local_mode", true)
	get_tree().root.set_meta("vs_cpu", false)
	Transition.go(SELECT_SCENE)


func _on_cpu_pressed() -> void:
	get_tree().root.set_meta("local_mode", true)
	get_tree().root.set_meta("vs_cpu", true)
	Transition.go(SELECT_SCENE)


func _on_online_pressed() -> void:
	_status_label.text = ""
	for b in _buttons:
		b.disabled = true
	_show_modal(_modal_online)
	_ip_field.grab_focus()


func _on_controls_pressed() -> void:
	for b in _buttons:
		b.disabled = true
	_show_modal(_modal_controls)


func _on_options_pressed() -> void:
	for b in _buttons:
		b.disabled = true
	_show_modal(_modal_options)


func _build_options_modal() -> void:
	_modal_options = _make_modal("OPTIONS", Vector2(620, 330))
	var panel: Control = _modal_options.get_node("Panel")
	var rows := [["MUSIC", AudioManager.music_volume, 0], ["SOUND FX", AudioManager.sfx_volume, 1]]
	for r in rows:
		var y: float = 100.0 + float(r[2]) * 70.0
		var lbl := UiStyle.label(r[0], 24, UiStyle.TEXT, true, 5)
		lbl.position = Vector2(30, y)
		panel.add_child(lbl)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = r[1]
		slider.position = Vector2(210, y + 4)
		slider.size = Vector2(380, 30)
		slider.add_theme_stylebox_override("slider", UiStyle.box(Color(0.03, 0.02, 0.07), UiStyle.GOLD_DARK, 2, 6))
		slider.add_theme_stylebox_override("grabber_area", UiStyle.box(UiStyle.GOLD, UiStyle.GOLD, 2, 6))
		slider.add_theme_stylebox_override("grabber_area_highlight", UiStyle.box(UiStyle.GOLD.lightened(0.2), UiStyle.GOLD, 2, 6))
		if r[2] == 0:
			slider.value_changed.connect(func(v: float) -> void: AudioManager.set_music_volume(v))
		else:
			slider.value_changed.connect(func(v: float) -> void:
				AudioManager.set_sfx_volume(v)
				AudioManager.play("hit_light"))
		panel.add_child(slider)
	var back := UiStyle.button("BACK", Color(0.6, 0.6, 0.75))
	back.position = Vector2(30, 250)
	back.size = Vector2(240, 46)
	back.pressed.connect(_close_modals)
	panel.add_child(back)


func _on_quit_pressed() -> void:
	get_tree().quit()


# ── Online matchmaking (unchanged behaviour; backend work comes later) ──────

func _on_matchmake_pressed() -> void:
	_btn_matchmake.disabled = true
	var url := _ip_field.text.strip_edges()
	if url.is_empty():
		url = "http://127.0.0.1:8000"

	_status_label.text = "Requesting matchmaking..."

	var headers = ["Content-Type: application/json"]
	var body = JSON.stringify({"player_name": "Player_" + str(randi() % 1000)})

	var err = _http_request.request(url + "/match/join", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_status_label.text = "Failed to send matchmaking request."
		_btn_matchmake.disabled = false


func _on_matchmake_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		_status_label.text = "Matchmaking failed: HTTP " + str(response_code)
		_btn_matchmake.disabled = false
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY or not json.has("ws_url"):
		_status_label.text = "Invalid matchmaking response."
		_btn_matchmake.disabled = false
		return

	var ws_url: String = json["ws_url"]
	_status_label.text = "Joining " + ws_url + "..."

	get_tree().root.set_meta("local_mode", false)
	var net := _get_network_manager()
	if not net:
		_status_label.text = "ERROR: NetworkManager not found."
		_btn_matchmake.disabled = false
		return

	var err: Error = net.join_game(ws_url)
	if err != OK:
		_status_label.text = "Failed to join: %s" % error_string(err)
		_btn_matchmake.disabled = false
		return

	Transition.go("res://scenes/game.tscn")


func _get_network_manager() -> Node:
	return get_node_or_null("/root/NetworkManager")
