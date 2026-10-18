## hk_menu_list.gd -- Text-only vertical menu: no boxes, no buttons.
## The focused entry brightens with a faint glow, a thin underline draws in beneath it and small
## crests appear on either side. Supports plain entries, "value" entries (name | value, cycled with
## left/right) and slider entries. Works with keyboard, gamepad (ui_* actions) and mouse.
extends Control

signal activated(index: int)
signal adjusted(index: int, direction: int)
signal slider_changed(index: int, value: float)
signal cancelled

const UiStyle := preload("res://scripts/ui_style.gd")

const LIST_W: float = 900.0
const ROW_H: float = 62.0
const SLIDER_W: float = 260.0

var items: Array = []        # [{"text", "value"?, "slider"?: float, "disabled"?: bool}]
var focus_index: int = -1
var active: bool = false     # accepts input only when true (off during page transitions)
var font_size: int = 30

var _rows: Array = []
static var _glow_tex: GradientTexture2D


# ── One row ─────────────────────────────────────────────────────────────────
class Row extends Control:
	var kind: String = "item"
	var slider_value: float = 0.0
	var disabled: bool = false
	var name_label: Label
	var value_label: Label
	var underline: ColorRect
	var crest_l: Polygon2D
	var crest_r: Polygon2D
	var glow: TextureRect
	var focused: bool = false
	var _tw: Tween

	func _draw() -> void:
		if kind != "slider":
			return
		var x0 := size.x * 0.5 + 24.0
		var y := size.y * 0.5 + 3.0
		var col := Color(0.8, 0.86, 1.0, 0.95 if focused else 0.55)
		draw_line(Vector2(x0, y), Vector2(x0 + 260.0, y), Color(0.45, 0.5, 0.65, 0.35), 1.0)
		draw_line(Vector2(x0, y), Vector2(x0 + 260.0 * slider_value, y), col, 2.0)
		var k := Vector2(x0 + 260.0 * slider_value, y)
		draw_colored_polygon(PackedVector2Array([k + Vector2(0, -6), k + Vector2(5, 0), k + Vector2(0, 6), k + Vector2(-5, 0)]), col)

	func set_focused(on: bool) -> void:
		focused = on
		if _tw:
			_tw.kill()
		_tw = create_tween().set_parallel(true)
		var idle := Color(0.35, 0.37, 0.45) if disabled else UiStyle.ASH
		var target := idle if not on else UiStyle.BONE
		_tw.tween_property(name_label, "modulate", target, 0.2)
		if value_label:
			_tw.tween_property(value_label, "modulate", target, 0.2)
		_tw.tween_property(underline, "scale:x", 1.0 if on else 0.0, 0.28).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		_tw.tween_property(underline, "modulate:a", 1.0 if on else 0.0, 0.2)
		_tw.tween_property(glow, "modulate:a", 0.2 if on else 0.0, 0.3)
		var spread := 0.0 if on else 14.0
		_tw.tween_property(crest_l, "position:x", crest_l.get_meta("x") + (0.0 if on else spread), 0.28).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		_tw.tween_property(crest_r, "position:x", crest_r.get_meta("x") - (0.0 if on else spread), 0.28).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		_tw.tween_property(crest_l, "modulate:a", 1.0 if on else 0.0, 0.2)
		_tw.tween_property(crest_r, "modulate:a", 1.0 if on else 0.0, 0.2)
		var glow_c := Color(0.8, 0.88, 1.0, 0.28 if on else 0.0)
		name_label.add_theme_color_override("font_outline_color", glow_c)
		if value_label:
			value_label.add_theme_color_override("font_outline_color", glow_c)
		queue_redraw()


# ── Build ───────────────────────────────────────────────────────────────────

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


static func _glow() -> GradientTexture2D:
	if _glow_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 1.0])
		g.colors = PackedColorArray([Color(0.75, 0.85, 1.0, 1.0), Color(0.75, 0.85, 1.0, 0.0)])
		_glow_tex = GradientTexture2D.new()
		_glow_tex.gradient = g
		_glow_tex.fill = GradientTexture2D.FILL_RADIAL
		_glow_tex.fill_from = Vector2(0.5, 0.5)
		_glow_tex.fill_to = Vector2(1.0, 0.5)
		_glow_tex.width = 256
		_glow_tex.height = 128
	return _glow_tex


func set_items(list: Array, start_focus: int = 0) -> void:
	for r in _rows:
		r.queue_free()
	_rows.clear()
	items = list
	focus_index = -1
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_left = -LIST_W * 0.5
	offset_right = LIST_W * 0.5
	custom_minimum_size = Vector2(LIST_W, ROW_H * list.size())
	size = Vector2(LIST_W, ROW_H * list.size())
	for i in range(list.size()):
		var row := _make_row(i, list[i])
		add_child(row)
		_rows.append(row)
	if start_focus >= 0 and not list.is_empty():
		set_focus(start_focus, false)


func _make_row(i: int, item: Dictionary) -> Control:
	var row := Row.new()
	row.position = Vector2(0, i * ROW_H)
	row.size = Vector2(LIST_W, ROW_H)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.disabled = bool(item.get("disabled", false))
	row.slider_value = float(item.get("slider", 0.0))
	var has_value: bool = item.has("value")
	row.kind = "slider" if item.has("slider") else ("value" if has_value else "item")

	var font := UiStyle.serif_font()
	var idle := Color(0.35, 0.37, 0.45) if row.disabled else UiStyle.ASH
	var half := LIST_W * 0.5

	row.name_label = UiStyle.serif_label(str(item["text"]), font_size, Color.WHITE)
	row.name_label.add_theme_constant_override("outline_size", 7)
	row.name_label.add_theme_color_override("font_outline_color", Color(0.8, 0.88, 1.0, 0.0))
	row.name_label.modulate = idle
	row.name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.name_label.size = Vector2(LIST_W, ROW_H)
	var text_w := font.get_string_size(str(item["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var total_w := text_w
	if row.kind == "item":
		row.name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		row.name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.name_label.size = Vector2(half - 24.0, ROW_H)
		var val_text := str(item.get("value", ""))
		var vw := SLIDER_W if row.kind == "slider" else font.get_string_size(val_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		total_w = text_w + vw + 48.0
		if row.kind == "value":
			row.value_label = UiStyle.serif_label(val_text, font_size, Color.WHITE)
			row.value_label.add_theme_constant_override("outline_size", 7)
			row.value_label.add_theme_color_override("font_outline_color", Color(0.8, 0.88, 1.0, 0.0))
			row.value_label.modulate = idle
			row.value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.value_label.position = Vector2(half + 24.0, 0)
			row.value_label.size = Vector2(half - 24.0, ROW_H)
	# glow, underline, crests (order = draw order)
	row.glow = TextureRect.new()
	row.glow.texture = _glow()
	row.glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.glow.stretch_mode = TextureRect.STRETCH_SCALE
	row.glow.size = Vector2(total_w + 260.0, ROW_H * 1.6)
	row.glow.position = Vector2(half - row.glow.size.x * 0.5, ROW_H * 0.5 - row.glow.size.y * 0.5)
	row.glow.modulate.a = 0.0
	row.glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(row.glow)
	row.add_child(row.name_label)
	if row.value_label:
		row.add_child(row.value_label)

	var line_w := total_w + 56.0
	row.underline = ColorRect.new()
	row.underline.color = Color(0.78, 0.84, 1.0, 0.6)
	row.underline.size = Vector2(line_w, 1.0)
	row.underline.position = Vector2(half - line_w * 0.5, ROW_H * 0.5 + font_size * 0.62)
	row.underline.pivot_offset = Vector2(line_w * 0.5, 0.5)
	row.underline.scale.x = 0.0
	row.underline.modulate.a = 0.0
	row.underline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(row.underline)

	row.crest_l = _crest(false)
	row.crest_r = _crest(true)
	row.crest_l.set_meta("x", half - line_w * 0.5 - 30.0)
	row.crest_r.set_meta("x", half + line_w * 0.5 + 30.0)
	row.crest_l.position = Vector2(row.crest_l.get_meta("x") + 14.0, ROW_H * 0.5)
	row.crest_r.position = Vector2(row.crest_r.get_meta("x") - 14.0, ROW_H * 0.5)
	row.add_child(row.crest_l)
	row.add_child(row.crest_r)

	row.gui_input.connect(_on_row_input.bind(i))
	row.mouse_entered.connect(func() -> void:
		if active and not row.disabled:
			set_focus(i))
	return row


## Slim ornament: a small diamond with a hair-line tail pointing toward the text.
func _crest(right: bool) -> Polygon2D:
	var p := Polygon2D.new()
	var d := -1.0 if right else 1.0
	p.polygon = PackedVector2Array([Vector2(0, -6), Vector2(6, 0), Vector2(0, 6), Vector2(-6, 0)])
	p.color = Color(0.85, 0.9, 1.0, 0.9)
	var tail := Polygon2D.new()
	tail.polygon = PackedVector2Array([Vector2(8 * d, -0.5), Vector2(22 * d, -0.5), Vector2(22 * d, 0.5), Vector2(8 * d, 0.5)])
	tail.color = Color(0.85, 0.9, 1.0, 0.5)
	p.add_child(tail)
	p.modulate.a = 0.0
	return p


# ── Focus / input ───────────────────────────────────────────────────────────

func set_focus(i: int, sound: bool = true) -> void:
	if i == focus_index or i < 0 or i >= _rows.size():
		return
	if focus_index >= 0 and focus_index < _rows.size():
		_rows[focus_index].set_focused(false)
	focus_index = i
	_rows[i].set_focused(true)
	if sound:
		AudioManager.play("ui_move", -8.0, 0.02)


func set_value_text(i: int, text: String) -> void:
	if i < _rows.size() and _rows[i].value_label:
		_rows[i].value_label.text = text


func set_slider(i: int, v: float) -> void:
	if i < _rows.size():
		_rows[i].slider_value = clampf(v, 0.0, 1.0)
		_rows[i].queue_redraw()


## Fade the rows in one after another (used right after a page change).
func reveal() -> void:
	for i in range(_rows.size()):
		var r: Control = _rows[i]
		r.modulate.a = 0.0
		r.position.y = i * ROW_H + 10.0
		var tw := create_tween().set_parallel(true)
		tw.tween_property(r, "modulate:a", 1.0, 0.45).set_delay(0.06 * i)
		tw.tween_property(r, "position:y", i * ROW_H, 0.45).set_delay(0.06 * i).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)


func _step(dir: int) -> void:
	if _rows.is_empty():
		return
	var i := focus_index
	for _n in range(_rows.size()):
		i = wrapi(i + dir, 0, _rows.size())
		if not bool(items[i].get("disabled", false)):
			set_focus(i)
			return


func _activate() -> void:
	if focus_index < 0 or bool(items[focus_index].get("disabled", false)):
		return
	var kind: String = _rows[focus_index].kind
	if kind == "slider":
		return
	AudioManager.play("ui_confirm", -4.0)
	activated.emit(focus_index)


func _adjust(dir: int) -> void:
	if focus_index < 0:
		return
	var row: Control = _rows[focus_index]
	if row.kind == "slider":
		row.slider_value = clampf(row.slider_value + 0.05 * dir, 0.0, 1.0)
		row.queue_redraw()
		slider_changed.emit(focus_index, row.slider_value)
	elif row.kind == "value":
		adjusted.emit(focus_index, dir)


func _input(event: InputEvent) -> void:
	if not active or not is_visible_in_tree() or event is InputEventMouse:
		return
	if event.is_action_pressed("ui_down"):
		_step(1)
	elif event.is_action_pressed("ui_up"):
		_step(-1)
	elif event.is_action_pressed("ui_accept"):
		_activate()
	elif event.is_action_pressed("ui_left"):
		_adjust(-1)
	elif event.is_action_pressed("ui_right"):
		_adjust(1)
	elif event.is_action_pressed("ui_cancel"):
		cancelled.emit()
	else:
		return
	get_viewport().set_input_as_handled()


func _on_row_input(event: InputEvent, i: int) -> void:
	if not active:
		return
	var row: Control = _rows[i]
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		set_focus(i)
		if row.kind == "slider":
			_slider_from_mouse(row, event.position.x)
		else:
			_activate()
	elif event is InputEventMouseMotion and row.kind == "slider" and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_slider_from_mouse(row, event.position.x)


func _slider_from_mouse(row: Control, x: float) -> void:
	var x0 := row.size.x * 0.5 + 24.0
	row.slider_value = clampf((x - x0) / SLIDER_W, 0.0, 1.0)
	row.queue_redraw()
	slider_changed.emit(focus_index, row.slider_value)
