## overlay_menu.gd -- Pause menu and end-of-match menu for local play.
## Lives under the Game scene with PROCESS_MODE_ALWAYS so it keeps listening while the tree is paused.
extends CanvasLayer

const MENU_SCENE:   String = "res://scenes/main.tscn"
const SELECT_SCENE: String = "res://scenes/character_select.tscn"

var _mode: String = "none"  # "none" | "pause" | "match_end"
var _panel: ColorRect
var _title: Label
var _hint:  Label


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_panel = ColorRect.new()
	_panel.color = Color(0.0, 0.0, 0.0, 0.62)
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.visible = false
	add_child(_panel)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical   = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 24)
	_panel.add_child(box)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 52)
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_title.add_theme_color_override("font_outline_color", Color.BLACK)
	_title.add_theme_constant_override("outline_size", 10)
	box.add_child(_title)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	box.add_child(_hint)


func show_match_end(text: String) -> void:
	_mode = "match_end"
	_title.text = text
	_hint.text = "ENTER  Rematch        C  Change fighters        M  Main menu"
	_panel.visible = true


func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	_mode = "pause" if paused else "none"
	_title.text = "PAUSED"
	_hint.text = "ESC  Resume      R  Restart match      C  Change fighters      M  Main menu"
	_panel.visible = paused


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key: int = event.keycode
	match _mode:
		"none":
			if key == KEY_ESCAPE:
				_set_paused(true)
		"pause":
			match key:
				KEY_ESCAPE: _set_paused(false)
				KEY_R:      _go("")
				KEY_C:      _go(SELECT_SCENE)
				KEY_M:      _go(MENU_SCENE)
		"match_end":
			match key:
				KEY_ENTER, KEY_KP_ENTER, KEY_R: _go("")
				KEY_C:                          _go(SELECT_SCENE)
				KEY_M, KEY_ESCAPE:              _go(MENU_SCENE)


## An empty path reloads the current match (same fighters).
func _go(scene_path: String) -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	if scene_path.is_empty():
		get_tree().reload_current_scene()
	else:
		get_tree().change_scene_to_file(scene_path)
