## ui_style.gd -- Shared look & feel: palette, fonts and styled widget builders.
extends RefCounted

const GOLD:      Color = Color(1.0, 0.82, 0.25)
const GOLD_DARK: Color = Color(0.72, 0.46, 0.1)
const INK:       Color = Color(0.04, 0.03, 0.08)
const PANEL:     Color = Color(0.08, 0.06, 0.14, 0.92)
const P1:        Color = Color(0.3, 0.85, 1.0)
const P2:        Color = Color(1.0, 0.35, 0.4)
const TEXT:      Color = Color(0.93, 0.92, 0.98)
const MUTED:     Color = Color(0.62, 0.6, 0.75)

static var _display: SystemFont
static var _body: SystemFont


## Heavy poster-style face for titles and buttons (falls back gracefully off Windows).
static func display_font() -> Font:
	if _display == null:
		_display = SystemFont.new()
		_display.font_names = PackedStringArray(["Impact", "Haettenschweiler", "Arial Black", "Bahnschrift"])
	return _display


static func body_font() -> Font:
	if _body == null:
		_body = SystemFont.new()
		_body.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Arial"])
	return _body


static func label(text: String, size: int = 20, color: Color = TEXT, display: bool = true, outline: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", display_font() if display else body_font())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", INK)
		l.add_theme_constant_override("outline_size", outline)
	return l


static func box(bg: Color, border: Color, border_w: int = 2, radius: int = 6) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	st.border_color = border
	st.set_border_width_all(border_w)
	st.set_corner_radius_all(radius)
	return st


static func button(text: String, accent: Color, height: float = 54.0) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, height)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_override("font", display_font())
	btn.add_theme_font_size_override("font_size", 26)
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_focus_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", INK)
	btn.add_theme_color_override("font_disabled_color", MUTED)

	var normal := box(Color(accent.r * 0.14, accent.g * 0.14, accent.b * 0.14, 0.88), Color(accent.r, accent.g, accent.b, 0.35), 1, 4)
	normal.border_width_left = 6
	normal.border_color = accent
	normal.content_margin_left = 24
	var hover := box(Color(accent.r * 0.42, accent.g * 0.42, accent.b * 0.42, 0.96), accent, 1, 4)
	hover.border_width_left = 14
	hover.content_margin_left = 24
	var pressed := box(accent, accent, 1, 4)
	pressed.border_width_left = 14
	pressed.content_margin_left = 24
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("focus", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("disabled", normal)

	btn.pivot_offset = Vector2(0, height * 0.5)
	var grow := func(on: bool) -> void:
		var tw := btn.create_tween()
		tw.tween_property(btn, "scale", Vector2(1.05, 1.05) if on else Vector2.ONE, 0.12)
	btn.mouse_entered.connect(grow.bind(true))
	btn.focus_entered.connect(grow.bind(true))
	btn.mouse_exited.connect(grow.bind(false))
	btn.focus_exited.connect(grow.bind(false))
	return btn
