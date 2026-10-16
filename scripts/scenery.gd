## scenery.gd -- One procedurally drawn world-building sprite (pagoda, torii, pine, lantern...).
## The node origin is the object's ground point; shapes extend upward (negative y).
extends Node2D

var kind:  String = ""
var c1:    Color  = Color.BLACK
var c2:    Color  = Color.WHITE
var c3:    Color  = Color.GRAY
var w:     float  = 100.0
var h:     float  = 100.0
var extra: float  = 0.0
var seed_val: int = 0

var _t: float = 0.0
var _stars: Array = []


func _ready() -> void:
	if kind == "stars":
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_val
		for i in range(110):
			_stars.append([Vector2(rng.randf() * w, rng.randf() * h), rng.randf_range(0.8, 2.4), rng.randf() * TAU, rng.randf_range(0.8, 3.0)])
	set_process(kind in ["lantern", "stars", "moon"])


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	match kind:
		"ridge":   _draw_ridge()
		"pagoda":  _draw_pagoda()
		"torii":   _draw_torii()
		"pine":    _draw_pine()
		"lantern": _draw_lantern()
		"bamboo":  _draw_bamboo()
		"sakura":  _draw_sakura()
		"floor":   _draw_floor()
		"mist":    _draw_mist()
		"cloud":   _draw_cloud()
		"grass":   _draw_grass()
		"stars":   _draw_stars()
		"moon":    _draw_moon()


func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in range(28):
		var a := TAU * i / 28.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)


func _draw_ridge() -> void:
	var pts := PackedVector2Array()
	var x := -w * 0.5
	while x <= w * 0.5:
		var n := sin(x * extra + seed_val) * 0.5 + sin(x * extra * 2.7 + seed_val * 2.0) * 0.3 + sin(x * extra * 6.1) * 0.12
		pts.append(Vector2(x, -h * (0.55 + 0.45 * n)))
		x += 40.0
	pts.append(Vector2(w * 0.5, 900.0))
	pts.append(Vector2(-w * 0.5, 900.0))
	draw_colored_polygon(pts, c1)


func _draw_pagoda() -> void:
	var tiers := 5
	var tier_h := 36.0
	for i in range(tiers):
		var bw := 86.0 - i * 11.0
		var y := -i * (tier_h + 12.0)
		draw_rect(Rect2(-bw * 0.5, y - tier_h, bw, tier_h), c1)
		for k in range(3):
			var wx := -bw * 0.3 + k * bw * 0.3
			draw_rect(Rect2(wx - 3.0, y - tier_h * 0.75, 6.0, 12.0), Color(c2.r, c2.g, c2.b, 0.85))
		var rw := bw * 0.98
		var roof := PackedVector2Array([
			Vector2(-rw - 8.0, y - tier_h - 6.0), Vector2(-bw * 0.6, y - tier_h + 2.0),
			Vector2(bw * 0.6, y - tier_h + 2.0), Vector2(rw + 8.0, y - tier_h - 6.0),
			Vector2(bw * 0.5, y - tier_h - 14.0), Vector2(-bw * 0.5, y - tier_h - 14.0)])
		draw_colored_polygon(roof, c1)
	var top := -tiers * (tier_h + 12.0)
	draw_line(Vector2(0, top), Vector2(0, top - 46.0), c1, 3.0)
	for k in range(3):
		draw_line(Vector2(-7 + k, top - 12.0 - k * 10.0), Vector2(7 - k, top - 12.0 - k * 10.0), c1, 2.5)


func _draw_torii() -> void:
	var half := 78.0
	var ph := 210.0
	for sx in [-1.0, 1.0]:
		draw_rect(Rect2(sx * half - 9.0, -ph, 18.0, ph), c1)
		draw_rect(Rect2(sx * half - 13.0, -16.0, 26.0, 16.0), c2)
	draw_rect(Rect2(-half - 4.0, -ph + 44.0, half * 2.0 + 8.0, 12.0), c1)
	var kasagi := PackedVector2Array([
		Vector2(-half - 44.0, -ph - 16.0), Vector2(half + 44.0, -ph - 16.0),
		Vector2(half + 22.0, -ph + 10.0), Vector2(-half - 22.0, -ph + 10.0)])
	draw_colored_polygon(kasagi, c1)
	draw_rect(Rect2(-half - 36.0, -ph - 24.0, half * 2.0 + 72.0, 8.0), c2)
	draw_rect(Rect2(-10.0, -ph + 12.0, 20.0, 32.0), c2)


func _draw_pine() -> void:
	draw_rect(Rect2(-w * 0.05, -h * 0.3, w * 0.1, h * 0.3), c1)
	for i in range(3):
		var ww := w * (1.0 - i * 0.26)
		var y := -h * (0.22 + i * 0.22)
		draw_colored_polygon(PackedVector2Array([Vector2(-ww * 0.5, y), Vector2(ww * 0.5, y), Vector2(0, y - h * 0.4)]), c1)


func _draw_lantern() -> void:
	var glow := 0.14 + 0.05 * sin(_t * 5.0 + seed_val)
	draw_circle(Vector2(0, -62), 74.0, Color(c2.r, c2.g, c2.b, glow * 0.6))
	draw_circle(Vector2(0, -62), 42.0, Color(c2.r, c2.g, c2.b, glow))
	draw_rect(Rect2(-18, -10, 36, 10), c1)
	draw_rect(Rect2(-6, -46, 12, 36), c1)
	draw_rect(Rect2(-16, -82, 32, 36), c1)
	draw_rect(Rect2(-9, -76, 18, 24), Color(c2.r, c2.g, c2.b, 0.7 + 0.2 * sin(_t * 7.0 + seed_val)))
	draw_colored_polygon(PackedVector2Array([Vector2(-28, -82), Vector2(28, -82), Vector2(10, -100), Vector2(-10, -100)]), c1)
	draw_circle(Vector2(0, -103), 5.0, c1)


func _draw_bamboo() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	for i in range(5):
		var x := (i - 2) * 22.0 + rng.randf_range(-6.0, 6.0)
		var hh := h * rng.randf_range(0.7, 1.15)
		draw_rect(Rect2(x - 4.5, -hh, 9.0, hh), c1)
		var y := -30.0
		while y > -hh:
			draw_rect(Rect2(x - 5.5, y, 11.0, 3.0), c2)
			y -= 46.0
		for l in range(3):
			var ly := -hh + 20.0 + l * 34.0
			var dir := -1.0 if (l + i) % 2 == 0 else 1.0
			draw_colored_polygon(PackedVector2Array([Vector2(x, ly), Vector2(x + dir * 44.0, ly - 14.0), Vector2(x + dir * 12.0, ly + 6.0)]), c1)


func _draw_sakura() -> void:
	draw_colored_polygon(PackedVector2Array([Vector2(-16, 0), Vector2(16, 0), Vector2(8, -h * 0.5), Vector2(-8, -h * 0.5)]), c3)
	draw_line(Vector2(0, -h * 0.4), Vector2(-w * 0.35, -h * 0.7), c3, 7.0)
	draw_line(Vector2(0, -h * 0.45), Vector2(w * 0.35, -h * 0.75), c3, 7.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	for i in range(9):
		var p := Vector2(rng.randf_range(-w * 0.5, w * 0.5), -h * rng.randf_range(0.62, 0.95))
		_ellipse(p, rng.randf_range(44.0, 70.0), rng.randf_range(32.0, 50.0), c1)
	for i in range(22):
		var p2 := Vector2(rng.randf_range(-w * 0.55, w * 0.55), -h * rng.randf_range(0.55, 1.0))
		draw_circle(p2, rng.randf_range(5.0, 11.0), c2)


func _draw_floor() -> void:
	var top := Color(c1.r * 1.25, c1.g * 1.25, c1.b * 1.25, 1.0).clamp()
	var pts := PackedVector2Array([Vector2(-w * 0.5, 0), Vector2(w * 0.5, 0), Vector2(w * 0.5, h), Vector2(-w * 0.5, h)])
	draw_polygon(pts, PackedColorArray([top, top, c1.darkened(0.55), c1.darkened(0.55)]))
	draw_rect(Rect2(-w * 0.5, 0, w, 6.0), c2)
	draw_rect(Rect2(-w * 0.5, 6.0, w, 3.0), Color(0, 0, 0, 0.35))
	var rows := [70.0, 160.0, 280.0]
	for r in rows:
		draw_line(Vector2(-w * 0.5, r), Vector2(w * 0.5, r), c3, 2.0)
	var x := -w * 0.5
	var row := 0
	while x < w * 0.5:
		for r_i in range(4):
			var y0: float = 9.0 if r_i == 0 else rows[r_i - 1]
			var y1: float = rows[r_i] if r_i < rows.size() else h
			var off := 60.0 if (r_i % 2 == 1) else 0.0
			draw_line(Vector2(x + off, y0), Vector2(x + off, y1), c3, 2.0)
		x += 120.0
		row += 1


func _draw_mist() -> void:
	var a0 := Color(c1.r, c1.g, c1.b, 0.0)
	var a1 := Color(c1.r, c1.g, c1.b, extra)
	draw_polygon(PackedVector2Array([Vector2(-w * 0.5, -h), Vector2(w * 0.5, -h), Vector2(w * 0.5, -h * 0.4), Vector2(-w * 0.5, -h * 0.4)]), PackedColorArray([a0, a0, a1, a1]))
	draw_polygon(PackedVector2Array([Vector2(-w * 0.5, -h * 0.4), Vector2(w * 0.5, -h * 0.4), Vector2(w * 0.5, 0), Vector2(-w * 0.5, 0)]), PackedColorArray([a1, a1, a0, a0]))


func _draw_cloud() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	for i in range(6):
		var p := Vector2((i - 2.5) * w * 0.18, rng.randf_range(-h * 0.3, 0.0))
		_ellipse(p, rng.randf_range(w * 0.12, w * 0.2), rng.randf_range(h * 0.25, h * 0.45), c1)
	_ellipse(Vector2(0, 8), w * 0.5, h * 0.18, Color(c1.r, c1.g, c1.b, c1.a * 0.7))


func _draw_grass() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var x := -w * 0.5
	while x < w * 0.5:
		var bh := rng.randf_range(h * 0.4, h)
		var lean := rng.randf_range(-16.0, 16.0)
		draw_colored_polygon(PackedVector2Array([Vector2(x - 6, 0), Vector2(x + 6, 0), Vector2(x + lean, -bh)]), c1)
		x += rng.randf_range(8.0, 16.0)


func _draw_stars() -> void:
	for s in _stars:
		var a := 0.45 + 0.55 * sin(_t * s[3] + s[2])
		draw_circle(s[0], s[1], Color(c1.r, c1.g, c1.b, clampf(a, 0.1, 1.0) * extra))


func _draw_moon() -> void:
	var pulse := 1.0 + 0.02 * sin(_t * 0.8)
	for i in range(5):
		draw_circle(Vector2.ZERO, w * (1.0 + 0.45 * (i + 1)) * pulse, Color(c2.r, c2.g, c2.b, 0.05))
	draw_circle(Vector2.ZERO, w, c1)
	draw_circle(Vector2(-w * 0.3, -w * 0.2), w * 0.18, Color(0, 0, 0, 0.07))
	draw_circle(Vector2(w * 0.25, w * 0.3), w * 0.12, Color(0, 0, 0, 0.07))
