## tekken_hud.gd -- Arcade fighting-game HUD: slanted health bars with portraits, round timer,
## win pips, hit-combo counters and big announcer banners.
extends CanvasLayer

signal time_up

const UiStyle  := preload("res://scripts/ui_style.gd")
const HudBar   := preload("res://scripts/hud_bar.gd")
const FighterData := preload("res://scripts/fighter_data.gd")

const ROUND_SECONDS: float = 99.0
const PIPS_TO_WIN:   int   = 2
const SIDE_W:        float = 560.0

var _bars:      Array = [null, null]
var _meters:    Array = [null, null]
var _names:     Array = [null, null]
var _portraits: Array = [null, null]
var _pips:      Array = [[], []]
var _combo:     Array = [null, null]
var _combo_tw:  Array = [null, null]

var _timer_label: Label
var _timer_ring:  Panel
var _round_label: Label
var _announcer:   Label
var _band:        ColorRect

var _round_time: float = ROUND_SECONDS
var _last_sec: int = 99
var _match_ended: bool = false
var _round_running: bool = false


func _ready() -> void:
	layer = 10
	_build_hud()


func _process(delta: float) -> void:
	if _round_running and not _match_ended and _round_time > 0.0:
		_round_time -= delta
		if _round_time <= 0.0:
			_round_time = 0.0
			_round_running = false
			show_announcement("TIME UP!", UiStyle.GOLD)
			time_up.emit()
		var sec := ceili(_round_time)
		_timer_label.text = str(sec)
		if sec != _last_sec:
			_last_sec = sec
			if sec <= 10:
				_timer_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.25))
				_timer_label.pivot_offset = _timer_label.size * 0.5
				_timer_label.scale = Vector2(1.35, 1.35)
				create_tween().tween_property(_timer_label, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ── Construction ────────────────────────────────────────────────────────────

func _build_hud() -> void:
	_build_side(0)
	_build_side(1)
	_build_center()

	_band = ColorRect.new()
	_band.color = Color(0, 0, 0, 0.0)
	_band.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_band.anchor_right = 1.0
	_band.offset_top = -80
	_band.offset_bottom = 80
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_band)

	_announcer = UiStyle.label("", 118, Color.WHITE, true, 18)
	_announcer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_announcer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announcer.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_announcer.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_announcer.add_theme_constant_override("shadow_offset_x", 6)
	_announcer.add_theme_constant_override("shadow_offset_y", 6)
	_announcer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_announcer)


func _build_side(i: int) -> void:
	var right := (i == 1)
	var accent: Color = UiStyle.P2 if right else UiStyle.P1
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if right:
		root.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		root.offset_left = -SIDE_W - 24
		root.offset_right = -24
	else:
		root.set_anchors_preset(Control.PRESET_TOP_LEFT)
		root.offset_left = 24
		root.offset_right = 24 + SIDE_W
	root.offset_top = 14
	root.offset_bottom = 134
	add_child(root)

	var frame := Panel.new()
	frame.size = Vector2(84, 84)
	frame.position = Vector2(SIDE_W - 84 if right else 0, 4)
	frame.clip_contents = true
	frame.add_theme_stylebox_override("panel", UiStyle.box(Color(0.06, 0.05, 0.12), accent, 4, 8))
	root.add_child(frame)
	var portrait := TextureRect.new()
	portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait.pivot_offset = Vector2(42, 42)
	if right:
		portrait.scale = Vector2(-1, 1)
	frame.add_child(portrait)
	_portraits[i] = portrait

	var bar_w := SIDE_W - 98.0
	var bar_x := 0.0 if right else 98.0
	var name_lbl := UiStyle.label("P%d" % (i + 1), 30, accent, true, 8)
	name_lbl.position = Vector2(bar_x, -4)
	name_lbl.size = Vector2(bar_w, 36)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	root.add_child(name_lbl)
	_names[i] = name_lbl

	var bar := HudBar.new()
	bar.mirrored = right
	bar.accent = UiStyle.GOLD
	bar.position = Vector2(bar_x, 36)
	bar.size = Vector2(bar_w, 32)
	root.add_child(bar)
	_bars[i] = bar

	var meter_w := bar_w - 72.0
	var meter := HudBar.new()
	meter.mirrored = right
	meter.meter_mode = true
	meter.skew = 10.0
	meter.accent = UiStyle.GOLD_DARK
	meter.meter_color = accent
	meter.position = Vector2(bar_x + (0.0 if right else 72.0), 72)
	meter.size = Vector2(meter_w, 18)
	root.add_child(meter)
	_meters[i] = meter

	for k in range(PIPS_TO_WIN):
		var pip := Panel.new()
		pip.size = Vector2(16, 16)
		pip.pivot_offset = Vector2(8, 8)
		pip.rotation = PI / 4.0
		pip.position = Vector2((bar_x + bar_w - 28 - k * 28) if right else (bar_x + 12 + k * 28), 78)
		root.add_child(pip)
		_pips[i].append(pip)
		_style_pip(pip, false, accent)

	var combo := UiStyle.label("", 46, UiStyle.GOLD, true, 10)
	combo.position = Vector2(bar_x, 108)
	combo.size = Vector2(bar_w, 52)
	combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	combo.modulate.a = 0.0
	root.add_child(combo)
	_combo[i] = combo


func _build_center() -> void:
	var center := Control.new()
	center.set_anchors_preset(Control.PRESET_CENTER_TOP)
	center.offset_left = -60
	center.offset_right = 60
	center.offset_top = 8
	center.offset_bottom = 130
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_timer_ring = Panel.new()
	_timer_ring.size = Vector2(92, 92)
	_timer_ring.position = Vector2(14, 0)
	_timer_ring.add_theme_stylebox_override("panel", UiStyle.box(Color(0.05, 0.04, 0.1, 0.95), UiStyle.GOLD, 5, 46))
	center.add_child(_timer_ring)

	_timer_label = UiStyle.label("99", 54, UiStyle.GOLD, true, 8)
	_timer_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_timer_ring.add_child(_timer_label)

	_round_label = UiStyle.label("ROUND 1", 22, UiStyle.TEXT, true, 6)
	_round_label.position = Vector2(0, 94)
	_round_label.size = Vector2(120, 26)
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(_round_label)


func _style_pip(pip: Panel, filled: bool, accent: Color) -> void:
	pip.add_theme_stylebox_override("panel", UiStyle.box(accent if filled else Color(0.06, 0.05, 0.12, 0.9), UiStyle.GOLD, 2, 2))


# ── Public API ──────────────────────────────────────────────────────────────

func update_health(player_index: int, current_hp: int) -> void:
	if _bars[player_index]:
		_bars[player_index].set_value(float(current_hp))


func update_meter(player_index: int, meter: int) -> void:
	if _meters[player_index]:
		_meters[player_index].set_value(float(meter))


func set_fighters(p1_name: String, p1_color: Color, p2_name: String, p2_color: Color) -> void:
	_names[0].text = p1_name
	_names[0].add_theme_color_override("font_color", p1_color)
	_names[1].text = p2_name
	_names[1].add_theme_color_override("font_color", p2_color)


func set_portraits(id1: String, id2: String) -> void:
	var ids := [id1, id2]
	for i in range(2):
		var sheet: Texture2D = load("%s%s/Idle.png" % [FighterData.BASE_DIR, ids[i]])
		if sheet:
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(36, 38, 56, 56)
			_portraits[i].texture = atlas


## Practice mode: no clock, no round counter.
func set_training() -> void:
	_timer_label.text = "--"
	_round_label.text = "TRAINING"


func set_round_text(txt: String) -> void:
	_round_label.text = txt


func set_round(n: int) -> void:
	_round_label.text = "ROUND %d" % n


func set_wins(p1_wins: int, p2_wins: int) -> void:
	var wins := [p1_wins, p2_wins]
	for i in range(2):
		var accent: Color = UiStyle.P2 if i == 1 else UiStyle.P1
		for k in range(_pips[i].size()):
			_style_pip(_pips[i][k], k < wins[i], accent)


## "N HITS" counter on the attacker's side.
func show_combo(player_index: int, hits: int) -> void:
	var lbl: Label = _combo[player_index]
	lbl.text = "%d HITS!" % hits
	lbl.pivot_offset = Vector2(0.0 if player_index == 0 else lbl.size.x, 26.0)
	lbl.modulate.a = 1.0
	lbl.scale = Vector2(1.4, 1.4)
	if _combo_tw[player_index]:
		_combo_tw[player_index].kill()
	var tw := create_tween()
	_combo_tw[player_index] = tw
	tw.tween_property(lbl, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.9)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.3)


func stop_round() -> void:
	_match_ended = true
	_round_running = false


func start_clock() -> void:
	_round_running = true


func reset_round() -> void:
	_match_ended = false
	_round_running = false
	_round_time = ROUND_SECONDS
	_last_sec = 99
	for b in _bars:
		b.reset()
	for m in _meters:
		m.reset()
	_timer_label.text = str(int(ROUND_SECONDS))
	_timer_label.add_theme_color_override("font_color", UiStyle.GOLD)
	clear_announcement()


func clear_announcement() -> void:
	_announcer.text = ""
	_band.color.a = 0.0


func show_announcement(txt: String, color: Color, font_size: int = 118) -> void:
	_announcer.add_theme_font_size_override("font_size", font_size)
	_announcer.text = txt
	_announcer.add_theme_color_override("font_color", color)
	_announcer.pivot_offset = _announcer.size * 0.5
	_announcer.scale = Vector2(2.2, 2.2)
	_announcer.modulate.a = 0.0
	_band.color.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_announcer, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_announcer, "modulate:a", 1.0, 0.12)
	tw.tween_property(_band, "color:a", 0.5, 0.2)
