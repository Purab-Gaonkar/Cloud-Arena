## transition.gd -- Autoload "Transition": fade-to-black scene changes.
extends CanvasLayer

var _rect: ColorRect
var _busy: bool = false


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rect = ColorRect.new()
	_rect.color = Color(0.02, 0.01, 0.05, 0.0)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


func go(path: String) -> void:
	_run(path)


func reload() -> void:
	_run("")


func _run(path: String) -> void:
	if _busy:
		return
	_busy = true
	_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	var out := create_tween().set_ignore_time_scale(true)
	out.tween_property(_rect, "color:a", 1.0, 0.28)
	await out.finished

	get_tree().paused = false
	Engine.time_scale = 1.0
	if path.is_empty():
		get_tree().reload_current_scene()
	else:
		get_tree().change_scene_to_file(path)
	await get_tree().process_frame
	await get_tree().process_frame

	var back := create_tween().set_ignore_time_scale(true)
	back.tween_property(_rect, "color:a", 0.0, 0.4)
	await back.finished
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_busy = false
