## hud_bar.gd -- Slanted fighting-game health bar with a red "damage ghost" trail.
extends Control

const SKEW: float = 20.0
const GHOST_DRAIN: float = 45.0

var max_value: float = 100.0
var value:     float = 100.0
var ghost:     float = 100.0
var mirrored:  bool  = false
var accent:    Color = Color(1.0, 0.82, 0.25)

var _time: float = 0.0


func set_value(v: float) -> void:
	value = clampf(v, 0.0, max_value)
	if ghost < value:
		ghost = value
	queue_redraw()


func reset() -> void:
	value = max_value
	ghost = max_value
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	if ghost > value:
		ghost = move_toward(ghost, value, delta * GHOST_DRAIN)
		queue_redraw()
	elif value / max_value < 0.3:
		queue_redraw()


func _p(x: float, y: float) -> Vector2:
	return Vector2(size.x - x if mirrored else x, y)


## Parallelogram covering the first `frac` of the bar's length.
func _strip(frac: float, y0: float = 0.0, y1: float = -1.0) -> PackedVector2Array:
	var hh := size.y
	var bot := hh if y1 < 0.0 else y1
	var span := size.x - SKEW
	var fw := span * clampf(frac, 0.0, 1.0)
	var lx0 := SKEW * (1.0 - y0 / hh)
	var lx1 := SKEW * (1.0 - bot / hh)
	return PackedVector2Array([_p(lx0, y0), _p(lx0 + fw, y0), _p(lx1 + fw, bot), _p(lx1, bot)])


func _draw() -> void:
	var frac := value / max_value
	var gfrac := ghost / max_value

	draw_colored_polygon(_strip(1.0), Color(0.05, 0.04, 0.1, 0.9))
	if gfrac > frac:
		draw_colored_polygon(_strip(gfrac), Color(0.9, 0.15, 0.2))
	if frac > 0.0:
		var col := Color(1.0, 0.85, 0.15)
		if frac < 0.5:
			col = Color(1.0, 0.85, 0.15).lerp(Color(1.0, 0.3, 0.1), (0.5 - frac) / 0.5)
		if frac < 0.3:
			col = col.lerp(Color.WHITE, 0.25 * (0.5 + 0.5 * sin(_time * 10.0)))
		draw_colored_polygon(_strip(frac), col)
		draw_colored_polygon(_strip(frac, 0.0, size.y * 0.45), Color(1, 1, 1, 0.22))

	var full := _strip(1.0)
	for i in range(1, 4):
		var f := i / 4.0
		var a := _p(SKEW + (size.x - SKEW) * f, 0.0)
		var b := _p((size.x - SKEW) * f, size.y)
		draw_line(a, b, Color(0, 0, 0, 0.35), 2.0)
	full.append(full[0])
	draw_polyline(full, accent, 3.0, true)
