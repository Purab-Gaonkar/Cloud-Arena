## controls_panel.gd -- Rebinding UI (keyboard + gamepad, per player). Lives inside a menu modal panel.
extends Control

signal back_requested

const UiStyle := preload("res://scripts/ui_style.gd")

var _player: int = 0
var _capture: Dictionary = {}          # {"id": String, "kind": "key" | "pad"} while waiting for input
var _key_btns: Dictionary = {}
var _pad_btns: Dictionary = {}
var _tab_btns: Array[Button] = []
var _info: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh()
	Input.joy_connection_changed.connect(func(_d: int, _c: bool) -> void: _refresh_info())
	InputConfig.bindings_changed.connect(_refresh)


func _build() -> void:
	for i in range(2):
		var tab := UiStyle.button("PLAYER %d" % (i + 1), UiStyle.P1 if i == 0 else UiStyle.P2, 44.0)
		tab.add_theme_font_size_override("font_size", 22)
		tab.position = Vector2(560 + i * 190, 16)
		tab.size = Vector2(180, 44)
		tab.pressed.connect(_select_player.bind(i))
		add_child(tab)
		_tab_btns.append(tab)

	var heads := [["ACTION", 30.0], ["KEYBOARD", 330.0], ["GAMEPAD", 640.0]]
	for h in heads:
		var l := UiStyle.label(h[0], 20, UiStyle.MUTED, true)
		l.position = Vector2(h[1], 84)
		add_child(l)

	var rows: Array = InputConfig.ACTIONS
	for r in range(rows.size()):
		var id: String = rows[r][0]
		var y := 116.0 + r * 50.0
		var lbl := UiStyle.label(rows[r][1], 24, UiStyle.TEXT, true, 5)
		lbl.position = Vector2(30, y + 6)
		add_child(lbl)

		var kb := _slot_button(Vector2(330, y), Color(0.45, 0.5, 0.65))
		kb.pressed.connect(_begin_capture.bind(id, "key"))
		add_child(kb)
		_key_btns[id] = kb

		var pb := _slot_button(Vector2(640, y), Color(0.25, 0.7, 0.55))
		pb.pressed.connect(_begin_capture.bind(id, "pad"))
		add_child(pb)
		_pad_btns[id] = pb

	var reset := UiStyle.button("RESET DEFAULTS", Color(0.85, 0.5, 0.2), 46.0)
	reset.add_theme_font_size_override("font_size", 22)
	reset.position = Vector2(30, 486)
	reset.size = Vector2(280, 46)
	reset.pressed.connect(func() -> void:
		_capture = {}
		InputConfig.reset_defaults())
	add_child(reset)

	var back := UiStyle.button("BACK", Color(0.6, 0.6, 0.75), 46.0)
	back.add_theme_font_size_override("font_size", 22)
	back.position = Vector2(330, 486)
	back.size = Vector2(200, 46)
	back.pressed.connect(func() -> void: back_requested.emit())
	add_child(back)

	_info = UiStyle.label("", 15, UiStyle.MUTED, false)
	_info.position = Vector2(30, 546)
	_info.size = Vector2(940, 40)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_info)


func _slot_button(pos: Vector2, accent: Color) -> Button:
	var b := UiStyle.button("", accent, 42.0)
	b.add_theme_font_size_override("font_size", 20)
	b.position = pos
	b.size = Vector2(290, 42)
	return b


func _select_player(p: int) -> void:
	_player = p
	_capture = {}
	_refresh()


func _begin_capture(id: String, kind: String) -> void:
	_capture = {"id": id, "kind": kind}
	_refresh()
	AudioManager.play("ui_open")


func _refresh() -> void:
	for i in range(_tab_btns.size()):
		_tab_btns[i].modulate = Color.WHITE if i == _player else Color(1, 1, 1, 0.45)
	for row in InputConfig.ACTIONS:
		var id: String = row[0]
		var waiting_key: bool = not _capture.is_empty() and _capture["id"] == id and _capture["kind"] == "key"
		var waiting_pad: bool = not _capture.is_empty() and _capture["id"] == id and _capture["kind"] == "pad"
		_key_btns[id].text = "PRESS A KEY..." if waiting_key else InputConfig.key_label(_player, id)
		_pad_btns[id].text = "PRESS A BUTTON..." if waiting_pad else InputConfig.pad_label(_player, id)
	_refresh_info()


func _refresh_info() -> void:
	var pads := Input.get_connected_joypads()
	var txt := "Click a slot, then press the key or gamepad input you want (ESC cancels). Dash = double-tap left/right; dashing away is an invulnerable backdash.   "
	if pads.is_empty():
		txt += "No gamepad detected - plug one in and it works automatically (Player 1 = first pad, Player 2 = second)."
	else:
		txt += "Gamepads: %d connected (%s)." % [pads.size(), Input.get_joy_name(pads[0])]
	_info.text = txt


func _input(event: InputEvent) -> void:
	if _capture.is_empty() or not is_visible_in_tree():
		return
	var id: String = _capture["id"]
	if _capture["kind"] == "key":
		if event is InputEventKey and event.pressed and not event.echo:
			get_viewport().set_input_as_handled()
			if event.physical_keycode != KEY_ESCAPE:
				InputConfig.set_key(_player, id, int(event.physical_keycode))
				AudioManager.play("ui_confirm")
			_capture = {}
			_refresh()
	else:
		if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_capture = {}
			_refresh()
			return
		var pad := InputConfig.pad_from_event(event)
		if not pad.is_empty():
			get_viewport().set_input_as_handled()
			InputConfig.set_pad(_player, id, pad)
			AudioManager.play("ui_confirm")
			_capture = {}
			_refresh()
