## world_builder.gd -- Builds a layered, parallax arena (sky, ridges, temples, trees, floor, particles).
## Used by the game, the main menu and the loading screen so they all share one look.
## Layer positions follow layer.x = camera_x * (1 - factor): factor 1 = moves with the world, 0 = glued to the camera.
extends Node2D

const Scenery := preload("res://scripts/scenery.gd")

const GROUND_Y: float = 130.0

const STAGES: Array[Dictionary] = [
	{
		"name": "TWILIGHT TEMPLE",
		"sky": [Color(0.07, 0.05, 0.2), Color(0.46, 0.2, 0.42), Color(1.0, 0.58, 0.32)],
		"stars": 0.5, "orb": Color(1.0, 0.93, 0.8), "orb_glow": Color(1.0, 0.75, 0.5), "orb_pos": Vector2(0.72, 0.24), "orb_r": 58.0,
		"cloud": Color(0.95, 0.55, 0.55, 0.28),
		"far": Color(0.33, 0.18, 0.42), "mid": Color(0.2, 0.11, 0.3), "near": Color(0.12, 0.07, 0.2),
		"pagoda": Color(0.16, 0.09, 0.25), "glow": Color(1.0, 0.75, 0.35), "mist": Color(0.9, 0.5, 0.55),
		"torii": Color(0.78, 0.16, 0.14), "torii_dark": Color(0.1, 0.05, 0.1),
		"floor": Color(0.34, 0.24, 0.36), "floor_edge": Color(0.78, 0.6, 0.55), "floor_line": Color(0.16, 0.1, 0.2),
		"leaf": Color(0.96, 0.62, 0.72), "leaf2": Color(1.0, 0.85, 0.9), "bark": Color(0.2, 0.12, 0.18),
		"bamboo": Color(0.16, 0.3, 0.26), "fx": "petal", "fx_color": Color(1.0, 0.72, 0.8),
	},
	{
		"name": "MOONLIT BAMBOO",
		"sky": [Color(0.02, 0.04, 0.14), Color(0.06, 0.14, 0.3), Color(0.14, 0.32, 0.45)],
		"stars": 1.0, "orb": Color(0.92, 0.96, 1.0), "orb_glow": Color(0.6, 0.8, 1.0), "orb_pos": Vector2(0.28, 0.22), "orb_r": 52.0,
		"cloud": Color(0.5, 0.65, 0.9, 0.2),
		"far": Color(0.08, 0.17, 0.3), "mid": Color(0.05, 0.12, 0.22), "near": Color(0.03, 0.08, 0.15),
		"pagoda": Color(0.04, 0.09, 0.17), "glow": Color(0.6, 1.0, 0.8), "mist": Color(0.4, 0.65, 0.9),
		"torii": Color(0.55, 0.14, 0.18), "torii_dark": Color(0.04, 0.05, 0.1),
		"floor": Color(0.16, 0.24, 0.3), "floor_edge": Color(0.5, 0.68, 0.75), "floor_line": Color(0.06, 0.1, 0.15),
		"leaf": Color(0.3, 0.55, 0.5), "leaf2": Color(0.6, 0.85, 0.75), "bark": Color(0.06, 0.1, 0.14),
		"bamboo": Color(0.1, 0.32, 0.26), "fx": "firefly", "fx_color": Color(0.85, 1.0, 0.5),
	},
	{
		"name": "CRIMSON DAWN",
		"sky": [Color(0.25, 0.08, 0.22), Color(0.85, 0.28, 0.25), Color(1.0, 0.78, 0.42)],
		"stars": 0.0, "orb": Color(1.0, 0.86, 0.55), "orb_glow": Color(1.0, 0.5, 0.25), "orb_pos": Vector2(0.5, 0.52), "orb_r": 96.0,
		"cloud": Color(1.0, 0.7, 0.5, 0.32),
		"far": Color(0.62, 0.2, 0.28), "mid": Color(0.42, 0.12, 0.22), "near": Color(0.24, 0.07, 0.15),
		"pagoda": Color(0.3, 0.09, 0.18), "glow": Color(1.0, 0.85, 0.4), "mist": Color(1.0, 0.65, 0.5),
		"torii": Color(0.9, 0.2, 0.12), "torii_dark": Color(0.14, 0.04, 0.08),
		"floor": Color(0.44, 0.22, 0.26), "floor_edge": Color(1.0, 0.7, 0.5), "floor_line": Color(0.2, 0.08, 0.12),
		"leaf": Color(1.0, 0.45, 0.45), "leaf2": Color(1.0, 0.8, 0.7), "bark": Color(0.2, 0.07, 0.12),
		"bamboo": Color(0.3, 0.2, 0.18), "fx": "ember", "fx_color": Color(1.0, 0.7, 0.3),
	},
]

var theme: Dictionary = {}
var _layers: Array = []    # [{"node": Node2D, "f": float}]
var _clouds: Array = []


static func stage_count() -> int:
	return STAGES.size()


static func stage_name(index: int) -> String:
	return STAGES[posmod(index, STAGES.size())]["name"]


func build(stage_index: int, viewport_size: Vector2 = Vector2(1280, 720)) -> void:
	theme = STAGES[posmod(stage_index, STAGES.size())]
	z_index = -100
	_build_sky(viewport_size)

	# Far to near.
	var l_clouds := _layer(0.08)
	for i in range(7):
		var c := _spawn(l_clouds, "cloud", Vector2(-2400 + i * 760, GROUND_Y - 520 + (i % 3) * 70), theme["cloud"], Color.WHITE, 420.0 + (i % 3) * 120.0, 90.0, 1.0, 0.0, i * 7)
		c.set_meta("speed", 6.0 + (i % 4) * 3.0)
		_clouds.append(c)

	var l_far := _layer(0.14)
	_spawn(l_far, "ridge", Vector2(0, GROUND_Y), theme["far"], Color.WHITE, 7000.0, 330.0, 1.0, 0.0045, 2)

	var l_pag := _layer(0.26)
	_spawn(l_pag, "pagoda", Vector2(-950, GROUND_Y + 10), theme["pagoda"], theme["glow"], 100.0, 100.0, 1.25)
	_spawn(l_pag, "pagoda", Vector2(1100, GROUND_Y + 10), theme["pagoda"], theme["glow"], 100.0, 100.0, 0.95)
	_spawn(l_pag, "pagoda", Vector2(-120, GROUND_Y + 10), theme["pagoda"], theme["glow"], 100.0, 100.0, 0.7)

	var l_mid := _layer(0.4)
	_spawn(l_mid, "ridge", Vector2(0, GROUND_Y), theme["mid"], Color.WHITE, 7000.0, 200.0, 1.0, 0.0085, 5)

	var l_pine := _layer(0.55)
	for i in range(18):
		var x := -2600 + i * 300 + (i * 97) % 140
		_spawn(l_pine, "pine", Vector2(x, GROUND_Y + 6), theme["near"], Color.WHITE, 90.0 + (i % 4) * 22.0, 170.0 + (i % 3) * 50.0)

	var l_mist := _layer(0.62)
	_spawn(l_mist, "mist", Vector2(0, GROUND_Y + 10), theme["mist"], Color.WHITE, 7000.0, 220.0, 1.0, 0.34)

	var l_obj := _layer(0.86)
	_spawn(l_obj, "torii", Vector2(0, GROUND_Y + 4), theme["torii"], theme["torii_dark"], 100.0, 100.0, 1.55)
	for sx in [-1.0, 1.0]:
		_spawn(l_obj, "lantern", Vector2(sx * 560, GROUND_Y + 4), theme["pagoda"].lightened(0.15), theme["glow"], 100.0, 100.0, 1.45, 0.0, int(sx * 3))
		_spawn(l_obj, "sakura", Vector2(sx * 1280, GROUND_Y + 4), theme["leaf"], theme["leaf2"], 420.0, 380.0, 1.0, 0.0, 11, theme["bark"])
		_spawn(l_obj, "bamboo", Vector2(sx * 900, GROUND_Y + 4), theme["bamboo"], theme["bamboo"].lightened(0.25), 100.0, 300.0, 1.0, 0.0, int(absf(sx) * 5 + 2))
		_spawn(l_obj, "lantern", Vector2(sx * 1700, GROUND_Y + 4), theme["pagoda"].lightened(0.15), theme["glow"], 100.0, 100.0, 1.45, 0.0, 9)

	var l_floor := _layer(1.0)
	_spawn(l_floor, "floor", Vector2(0, GROUND_Y), theme["floor"], theme["floor_edge"], 3600.0, 800.0, 1.0, 0.0, 0, theme["floor_line"])

	_build_particles()

	var l_fg := _layer(1.35)
	l_fg.z_index = 220
	for sx in [-1.0, 1.0]:
		_spawn(l_fg, "grass", Vector2(sx * 760, GROUND_Y + 150), theme["torii_dark"], Color.WHITE, 700.0, 60.0, 1.0, 0.0, int(absf(sx) * 4))


func _layer(factor: float) -> Node2D:
	var n := Node2D.new()
	add_child(n)
	_layers.append({"node": n, "f": factor})
	return n


func _spawn(parent: Node, kind: String, pos: Vector2, c1: Color, c2: Color, w: float, h: float, sc: float = 1.0, extra: float = 0.0, rseed: int = 0, c3: Color = Color.GRAY) -> Node2D:
	var s := Scenery.new()
	s.kind = kind
	s.position = pos
	s.c1 = c1
	s.c2 = c2
	s.c3 = c3
	s.w = w
	s.h = h
	s.extra = extra
	s.seed_val = rseed
	s.scale = Vector2(sc, sc)
	parent.add_child(s)
	return s


func _build_sky(vp: Vector2) -> void:
	var sky_layer := CanvasLayer.new()
	sky_layer.layer = -110
	add_child(sky_layer)

	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray(theme["sky"])
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill_from = Vector2(0, 0)
	gtex.fill_to = Vector2(0, 1)
	var sky := TextureRect.new()
	sky.texture = gtex
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky_layer.add_child(sky)

	if float(theme["stars"]) > 0.0:
		var stars := Scenery.new()
		stars.kind = "stars"
		stars.w = vp.x
		stars.h = vp.y * 0.65
		stars.c1 = Color.WHITE
		stars.extra = theme["stars"]
		stars.seed_val = 42
		sky_layer.add_child(stars)

	var orb := Scenery.new()
	orb.kind = "moon"
	orb.w = theme["orb_r"]
	orb.c1 = theme["orb"]
	orb.c2 = theme["orb_glow"]
	orb.position = Vector2(vp.x * theme["orb_pos"].x, vp.y * theme["orb_pos"].y)
	sky_layer.add_child(orb)


func _build_particles() -> void:
	var p := CPUParticles2D.new()
	p.z_index = 150
	p.local_coords = false
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.color = theme["fx_color"]
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.15, 0.85, 1.0])
	var base: Color = theme["fx_color"]
	ramp.colors = PackedColorArray([Color(base.r, base.g, base.b, 0.0), base, base, Color(base.r, base.g, base.b, 0.0)])
	p.color_ramp = ramp
	match theme["fx"]:
		"petal":
			p.position = Vector2(0, GROUND_Y - 700)
			p.emission_rect_extents = Vector2(1900, 10)
			p.amount = 60
			p.lifetime = 10.0
			p.direction = Vector2(0.5, 1.0)
			p.spread = 25.0
			p.initial_velocity_min = 25.0
			p.initial_velocity_max = 70.0
			p.gravity = Vector2(12, 14)
			p.angular_velocity_min = -120.0
			p.angular_velocity_max = 120.0
			p.scale_amount_min = 3.0
			p.scale_amount_max = 6.0
		"firefly":
			p.position = Vector2(0, GROUND_Y - 160)
			p.emission_rect_extents = Vector2(1500, 150)
			p.amount = 40
			p.lifetime = 6.0
			p.direction = Vector2(0, -1)
			p.spread = 180.0
			p.initial_velocity_min = 6.0
			p.initial_velocity_max = 26.0
			p.gravity = Vector2.ZERO
			p.scale_amount_min = 2.0
			p.scale_amount_max = 4.0
		_:
			p.position = Vector2(0, GROUND_Y + 20)
			p.emission_rect_extents = Vector2(1500, 10)
			p.amount = 45
			p.lifetime = 5.0
			p.direction = Vector2(0.2, -1)
			p.spread = 20.0
			p.initial_velocity_min = 40.0
			p.initial_velocity_max = 110.0
			p.gravity = Vector2(0, -10)
			p.scale_amount_min = 2.0
			p.scale_amount_max = 4.0
	p.preprocess = p.lifetime
	add_child(p)


func update_parallax(cam_x: float) -> void:
	for l in _layers:
		l["node"].position.x = cam_x * (1.0 - float(l["f"]))


func _process(delta: float) -> void:
	for c in _clouds:
		c.position.x += float(c.get_meta("speed")) * delta
		if c.position.x > 2800.0:
			c.position.x -= 5600.0
