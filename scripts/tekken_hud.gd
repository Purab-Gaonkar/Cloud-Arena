## tekken_hud.gd — Tekken-style arcade fighting game top HUD.
## Features:
## • P1 & P2 mirrored health bars with gold beveled borders
## • Red "damage ghost" lag bar that smoothly drains after taking hits
## • Center 99-second countdown round timer
## • "ROUND 1", "FIGHT!", and "K.O.!" announcements
extends CanvasLayer

signal time_up

const ROUND_SECONDS: float = 99.0
const PIPS_TO_WIN: int = 2

var _round_title: Label
var _p1_pips: Array[Panel] = []
var _p2_pips: Array[Panel] = []
var _round_running: bool = false

var _p1_bar: ProgressBar
var _p1_ghost: ProgressBar
var _p2_bar: ProgressBar
var _p2_ghost: ProgressBar
var _timer_label: Label
var _announcer_label: Label
var _p1_name: Label
var _p2_name: Label

var _p1_target_hp: float = 100.0
var _p1_current_hp: float = 100.0
var _p2_target_hp: float = 100.0
var _p2_current_hp: float = 100.0

var _round_time: float = ROUND_SECONDS
var _match_ended: bool = false

func _ready() -> void:
	layer = 10  # Topmost UI layer
	_build_hud()

func _process(delta: float) -> void:
	# Smoothly drain the red damage ghost bars (fighting game lag trail)
	if _p1_ghost:
		if _p1_ghost.value > _p1_target_hp:
			_p1_ghost.value = move_toward(_p1_ghost.value, _p1_target_hp, delta * 45.0)
	if _p2_ghost:
		if _p2_ghost.value > _p2_target_hp:
			_p2_ghost.value = move_toward(_p2_ghost.value, _p2_target_hp, delta * 45.0)

	# Round timer countdown
	if _round_running and not _match_ended and _round_time > 0.0:
		_round_time -= delta
		if _round_time <= 0.0:
			_round_time = 0.0
			_round_running = false
			show_announcement("TIME UP!", Color.GOLD)
			time_up.emit()
		if _timer_label:
			_timer_label.text = str(ceili(_round_time))
			if _round_time <= 10.0:
				_timer_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))

func _build_hud() -> void:
	var screen_size := get_viewport().get_visible_rect().size
	var bar_width := 480.0
	var bar_height := 28.0

	# ── TOP CONTAINER ───────────────────────────────────────────────────────
	var top_panel = Panel.new()
	top_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_panel.custom_minimum_size = Vector2(0, 100)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.04, 0.04, 0.06, 0.75)
	top_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(top_panel)

	# ── CENTER TIMER & ROUND ────────────────────────────────────────────────
	var center_box = VBoxContainer.new()
	center_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	center_box.offset_top = 8.0
	center_box.alignment = BoxContainer.ALIGNMENT_CENTER
	top_panel.add_child(center_box)

	var round_title = Label.new()
	_round_title = round_title
	round_title.text = "ROUND 1"
	round_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	round_title.add_theme_font_size_override("font_size", 14)
	round_title.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	center_box.add_child(round_title)

	var timer_bg = PanelContainer.new()
	var tbg_style = StyleBoxFlat.new()
	tbg_style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	tbg_style.border_width_left = 3
	tbg_style.border_width_right = 3
	tbg_style.border_width_top = 3
	tbg_style.border_width_bottom = 3
	tbg_style.border_color = Color(0.9, 0.75, 0.2)
	tbg_style.corner_radius_top_left = 4
	tbg_style.corner_radius_top_right = 4
	tbg_style.corner_radius_bottom_left = 4
	tbg_style.corner_radius_bottom_right = 4
	timer_bg.add_theme_stylebox_override("panel", tbg_style)
	center_box.add_child(timer_bg)

	_timer_label = Label.new()
	_timer_label.text = "99"
	_timer_label.custom_minimum_size = Vector2(64, 42)
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_timer_label.add_theme_font_size_override("font_size", 32)
	_timer_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
	timer_bg.add_child(_timer_label)

	# ── PLAYER 1 (LEFT) ─────────────────────────────────────────────────────
	var p1_box = Control.new()
	p1_box.position = Vector2(30, 20)
	top_panel.add_child(p1_box)

	_p1_name = Label.new()
	_p1_name.text = "P1"
	_p1_name.position = Vector2(0, 0)
	_p1_name.add_theme_font_size_override("font_size", 18)
	_p1_name.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	p1_box.add_child(_p1_name)

	# Ghost bar (damage lag trail behind yellow bar)
	_p1_ghost = _create_bar(Vector2(0, 26), Vector2(bar_width, bar_height), false, Color(0.9, 0.15, 0.15))
	p1_box.add_child(_p1_ghost)

	# Main yellow bar
	_p1_bar = _create_bar(Vector2(0, 26), Vector2(bar_width, bar_height), false, Color(1.0, 0.82, 0.1))
	p1_box.add_child(_p1_bar)

	# ── PLAYER 2 (RIGHT) ────────────────────────────────────────────────────
	var p2_box = Control.new()
	p2_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	p2_box.position = Vector2(-30 - bar_width, 20)
	top_panel.add_child(p2_box)

	_p2_name = Label.new()
	_p2_name.text = "P2"
	_p2_name.size = Vector2(bar_width, 24)
	_p2_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_p2_name.position = Vector2(0, 0)
	_p2_name.add_theme_font_size_override("font_size", 18)
	_p2_name.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	p2_box.add_child(_p2_name)

	# Ghost bar (inverted)
	_p2_ghost = _create_bar(Vector2(0, 26), Vector2(bar_width, bar_height), true, Color(0.9, 0.15, 0.15))
	p2_box.add_child(_p2_ghost)

	# Main yellow bar (inverted)
	_p2_bar = _create_bar(Vector2(0, 26), Vector2(bar_width, bar_height), true, Color(1.0, 0.82, 0.1))
	p2_box.add_child(_p2_bar)

	# ── ANNOUNCER BANNER ("FIGHT!", "K.O.!") ─────────────────────────────────
	_announcer_label = Label.new()
	_announcer_label.set_anchors_preset(Control.PRESET_CENTER)
	_announcer_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_announcer_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_announcer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announcer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_announcer_label.add_theme_font_size_override("font_size", 64)
	_announcer_label.text = ""
	add_child(_announcer_label)

	_p1_pips = _build_pips(p1_box, false)
	_p2_pips = _build_pips(p2_box, true)

func _create_bar(pos: Vector2, b_size: Vector2, inverted: bool, fill_c: Color) -> ProgressBar:
	var bar = ProgressBar.new()
	bar.position = pos
	bar.size = b_size
	bar.max_value = 100
	bar.value = 100
	bar.show_percentage = false
	if inverted:
		bar.fill_mode = 1 # FILL_END_TO_BEGIN

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.12, 0.16, 0.85)
	bg.border_width_left = 3
	bg.border_width_right = 3
	bg.border_width_top = 3
	bg.border_width_bottom = 3
	bg.border_color = Color(0.85, 0.72, 0.2)
	bar.add_theme_stylebox_override("background", bg)

	var fill = StyleBoxFlat.new()
	fill.bg_color = fill_c
	bar.add_theme_stylebox_override("fill", fill)
	return bar

func update_health(player_index: int, current_hp: int) -> void:
	## player_index: 0 = P1, 1 = P2  (works for both local and network modes)
	if player_index == 0:
		_p1_target_hp = float(current_hp)
		if _p1_bar:
			_p1_bar.value = _p1_target_hp
	else:
		_p2_target_hp = float(current_hp)
		if _p2_bar:
			_p2_bar.value = _p2_target_hp

func _build_pips(parent: Control, right_aligned: bool) -> Array[Panel]:
	var pips: Array[Panel] = []
	for i in range(PIPS_TO_WIN):
		var pip := Panel.new()
		pip.size = Vector2(16, 16)
		var x := (480.0 - 16.0 - i * 24.0) if right_aligned else (i * 24.0)
		pip.position = Vector2(x, 58)
		parent.add_child(pip)
		pips.append(pip)
		_style_pip(pip, false)
	return pips


func _style_pip(pip: Panel, filled: bool) -> void:
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1.0, 0.82, 0.1) if filled else Color(0.1, 0.1, 0.14, 0.9)
	st.border_color = Color(0.85, 0.72, 0.2)
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	pip.add_theme_stylebox_override("panel", st)


func set_fighters(p1_name: String, p1_color: Color, p2_name: String, p2_color: Color) -> void:
	_p1_name.text = "P1  " + p1_name
	_p1_name.add_theme_color_override("font_color", p1_color)
	_p2_name.text = p2_name + "  P2"
	_p2_name.add_theme_color_override("font_color", p2_color)


func set_round(n: int) -> void:
	if _round_title:
		_round_title.text = "ROUND %d" % n


func set_wins(p1_wins: int, p2_wins: int) -> void:
	for i in range(_p1_pips.size()):
		_style_pip(_p1_pips[i], i < p1_wins)
	for i in range(_p2_pips.size()):
		_style_pip(_p2_pips[i], i < p2_wins)


## Stops the clock (round over); the K.O./time-up banner stays up until the next reset.
func stop_round() -> void:
	_match_ended = true
	_round_running = false


func start_clock() -> void:
	_round_running = true


func reset_round() -> void:
	_match_ended = false
	_round_running = false
	_round_time = ROUND_SECONDS
	_p1_target_hp = 100.0
	_p1_current_hp = 100.0
	_p2_target_hp = 100.0
	_p2_current_hp = 100.0
	if _p1_bar: _p1_bar.value = 100
	if _p1_ghost: _p1_ghost.value = 100
	if _p2_bar: _p2_bar.value = 100
	if _p2_ghost: _p2_ghost.value = 100
	if _timer_label:
		_timer_label.text = str(int(ROUND_SECONDS))
		_timer_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
	_announcer_label.text = ""


func clear_announcement() -> void:
	_announcer_label.text = ""


func show_announcement(txt: String, color: Color) -> void:
	if not _announcer_label:
		return
	_announcer_label.text = txt
	_announcer_label.add_theme_color_override("font_color", color)
	_announcer_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_announcer_label.add_theme_constant_override("outline_size", 12)
	_announcer_label.pivot_offset = _announcer_label.size * 0.5
	_announcer_label.scale = Vector2(1.5, 1.5)
	var tween = create_tween()
	tween.tween_property(_announcer_label, "scale", Vector2(1.0, 1.0), 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
