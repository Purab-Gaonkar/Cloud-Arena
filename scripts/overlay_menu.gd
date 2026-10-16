## overlay_menu.gd -- Pause menu and end-of-match menu for local play.
## Lives under the Game scene with PROCESS_MODE_ALWAYS so it keeps listening while the tree is paused.
extends CanvasLayer

const UiStyle := preload("res://scripts/ui_style.gd")

const MENU_SCENE:   String = "res://scenes/main.tscn"
const SELECT_SCENE: String = "res://scenes/character_select.tscn"

var _mode: String = "none"  # "none" | "pause" | "match_end"
var _panel: Control
var _title: Label
var _sub: Label
var _hint: Label


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.visible = false
	add_child(_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.01, 0.06, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	_panel.add_child(box)

	_title = UiStyle.label("", 110, UiStyle.GOLD, true, 18)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_title.add_theme_constant_override("shadow_offset_x", 7)
	_title.add_theme_constant_override("shadow_offset_y", 7)
	box.add_child(_title)

	_sub = UiStyle.label("", 34, UiStyle.TEXT, true, 8)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_sub)

	var line := ColorRect.new()
	line.color = UiStyle.GOLD_DARK
	line.custom_minimum_size = Vector2(0, 3)
	box.add_child(line)

	_hint = UiStyle.label("", 22, UiStyle.TEXT, false, 6)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_hint)


func _pop() -> void:
	_panel.visible = true
	_title.pivot_offset = _title.size * 0.5
	_title.scale = Vector2(1.6, 1.6)
	_panel.modulate.a = 0.0
	var tw := create_tween().set_parallel(true).set_pause_mode(Tween.TWEEN_PAUSE_PROCESS).set_ignore_time_scale(true)
	tw.tween_property(_title, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "modulate:a", 1.0, 0.2)


func show_match_end(text: String) -> void:
	_mode = "match_end"
	_title.text = "VICTORY"
	_sub.text = text
	_hint.text = "ENTER / A  Rematch        C / X  Change fighters        M / B  Main menu"
	_pop()


func _set_paused(paused: bool) -> void:
	AudioManager.play("ui_open" if paused else "ui_back")
	get_tree().paused = paused
	_mode = "pause" if paused else "none"
	_title.text = "PAUSED"
	_sub.text = ""
	_hint.text = "ESC / START  Resume      R / Y  Restart      C / X  Change fighters      M / B  Main menu"
	if paused:
		_pop()
	else:
		_panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	match _mode:
		"none":
			if event.is_action_pressed("ui_pause"):
				_set_paused(true)
		"pause":
			if event.is_action_pressed("ui_pause"):
				_set_paused(false)
			elif event.is_action_pressed("ov_restart"):
				Transition.reload()
			elif event.is_action_pressed("ov_select"):
				Transition.go(SELECT_SCENE)
			elif event.is_action_pressed("ov_menu"):
				Transition.go(MENU_SCENE)
		"match_end":
			if event.is_action_pressed("ui_accept") or event.is_action_pressed("ov_restart"):
				Transition.reload()
			elif event.is_action_pressed("ov_select"):
				Transition.go(SELECT_SCENE)
			elif event.is_action_pressed("ov_menu") or event.is_action_pressed("ui_pause"):
				Transition.go(MENU_SCENE)
