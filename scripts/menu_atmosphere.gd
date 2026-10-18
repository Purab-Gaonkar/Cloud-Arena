## menu_atmosphere.gd -- Dark, quiet backdrop for the main menu.
## Layers (back to front): deep gradient + faint top light, three desaturated ridge silhouettes with
## slow drift and mouse parallax, hanging vines framing the top corners, slow fog banks, drifting dust
## motes, and a heavy vignette.
extends Control

const Scenery := preload("res://scripts/scenery.gd")

const RIDGES: Array = [
	# [color, height, frequency, seed, parallax, drift speed, baseline y]
	[Color(0.075, 0.085, 0.13), 250.0, 0.0042, 3, 10.0, 6.0, 640.0],
	[Color(0.052, 0.058, 0.095), 190.0, 0.0070, 8, 22.0, 10.0, 680.0],
	[Color(0.032, 0.036, 0.062), 130.0, 0.0105, 5, 40.0, 14.0, 720.0],
]

var _ridges: Array = []     # [{"node": Node2D, "parallax": float, "speed": float}]
var _fog: Array = []        # [{"node": TextureRect, "speed": float}]
var _vines: Node2D
var _t: float = 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_backdrop()
	_build_ridges()
	_build_vines()
	_build_fog()
	_build_dust()
	_build_vignette()


func _gradient_rect(colors: Array, vertical: bool = true) -> TextureRect:
	var g := Gradient.new()
	g.colors = PackedColorArray(colors)
	var offs := PackedFloat32Array()
	for i in range(colors.size()):
		offs.append(float(i) / float(colors.size() - 1))
	g.offsets = offs
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _radial(color: Color, w: int, h: int) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([color, Color(color.r, color.g, color.b, 0.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = w
	t.height = h
	return t


func _build_backdrop() -> void:
	add_child(_gradient_rect([Color(0.012, 0.016, 0.034), Color(0.03, 0.038, 0.07), Color(0.02, 0.024, 0.045)]))
	# A pale, barely-there light falling from above the title.
	var light := TextureRect.new()
	light.texture = _radial(Color(0.5, 0.58, 0.82, 0.10), 512, 256)
	light.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	light.stretch_mode = TextureRect.STRETCH_SCALE
	light.set_anchors_preset(Control.PRESET_CENTER_TOP)
	light.offset_left = -700
	light.offset_right = 700
	light.offset_top = -160
	light.offset_bottom = 420
	light.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(light)


func _build_ridges() -> void:
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)
	for r in RIDGES:
		var node := Node2D.new()
		holder.add_child(node)
		var s := Scenery.new()
		s.kind = "ridge"
		s.c1 = r[0]
		s.w = 3600.0
		s.h = r[1]
		s.extra = r[2]
		s.seed_val = r[3]
		s.position = Vector2(640, r[6])
		node.add_child(s)
		_ridges.append({"node": node, "parallax": r[4], "speed": r[5]})


func _build_vines() -> void:
	_vines = Node2D.new()
	add_child(_vines)
	var dark := Color(0.012, 0.014, 0.028)
	var leaf := Color(0.02, 0.026, 0.045)
	for spec in [[70.0, 430.0, 1], [210.0, 300.0, 2], [1210.0, 470.0, 3], [1080.0, 310.0, 4], [-10.0, 250.0, 5], [1290.0, 260.0, 6]]:
		var v := Scenery.new()
		v.kind = "vine"
		v.c1 = dark
		v.c2 = leaf
		v.w = 120.0
		v.h = spec[1]
		v.seed_val = spec[2]
		v.position = Vector2(spec[0], -20.0)
		_vines.add_child(v)


func _build_fog() -> void:
	for spec in [[Color(0.45, 0.52, 0.75, 0.05), 1900, 300, 470.0, 7.0], [Color(0.4, 0.47, 0.7, 0.05), 2300, 360, 560.0, -5.0], [Color(0.55, 0.6, 0.8, 0.035), 2100, 250, 380.0, 3.5]]:
		var f := TextureRect.new()
		f.texture = _radial(spec[0], 512, 128)
		f.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		f.stretch_mode = TextureRect.STRETCH_SCALE
		f.size = Vector2(spec[1], spec[2])
		f.position = Vector2(randf_range(-600.0, 0.0), spec[3])
		f.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(f)
		_fog.append({"node": f, "speed": spec[4]})


func _build_dust() -> void:
	var p := CPUParticles2D.new()
	p.position = Vector2(640, 380)
	p.amount = 90
	p.lifetime = 16.0
	p.preprocess = 16.0
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(700, 380)
	p.direction = Vector2(0.3, -1.0)
	p.spread = 60.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 12.0
	p.gravity = Vector2(1.5, -1.0)
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.2
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	ramp.colors = PackedColorArray([Color(0.75, 0.82, 1.0, 0.0), Color(0.75, 0.82, 1.0, 0.55), Color(0.75, 0.82, 1.0, 0.45), Color(0.75, 0.82, 1.0, 0.0)])
	p.color_ramp = ramp
	add_child(p)


func _build_vignette() -> void:
	var v := TextureRect.new()
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.28, 0.85])
	g.colors = PackedColorArray([Color(0, 0, 0, 0.0), Color(0.0, 0.0, 0.008, 0.94)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 512
	t.height = 512
	v.texture = t
	v.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	v.stretch_mode = TextureRect.STRETCH_SCALE
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)


func _process(delta: float) -> void:
	_t += delta
	var vp := get_viewport_rect().size
	var mouse := get_viewport().get_mouse_position()
	var m: Vector2 = Vector2((mouse.x / maxf(vp.x, 1.0) - 0.5), (mouse.y / maxf(vp.y, 1.0) - 0.5))
	for r in _ridges:
		var drift: float = sin(_t * 0.05 * (float(r["speed"]) / 6.0)) * float(r["speed"]) * 6.0
		r["node"].position = Vector2(-m.x * r["parallax"] + drift, -m.y * r["parallax"] * 0.4)
	_vines.position = Vector2(-m.x * 6.0, -m.y * 3.0)
	for f in _fog:
		var n: TextureRect = f["node"]
		n.position.x += f["speed"] * delta
		if n.position.x > vp.x:
			n.position.x = -n.size.x
		elif n.position.x < -n.size.x:
			n.position.x = vp.x
