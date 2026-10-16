## game_settings.gd -- Autoload "GameSettings": gameplay/display options saved to user://settings.cfg
## (audio volumes are stored by AudioManager in the same file).
extends Node

const PATH: String = "user://settings.cfg"
const LEVEL_NAMES: Array = ["EASY", "NORMAL", "HARD"]

var cpu_level: int = 1
var screen_shake: bool = true
var fullscreen: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		cpu_level = clampi(int(cfg.get_value("game", "cpu_level", cpu_level)), 0, 2)
		screen_shake = bool(cfg.get_value("game", "screen_shake", screen_shake))
		fullscreen = bool(cfg.get_value("game", "fullscreen", fullscreen))
	_apply_fullscreen()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		set_fullscreen(not fullscreen)


func cycle_cpu_level() -> void:
	cpu_level = (cpu_level + 1) % LEVEL_NAMES.size()
	_save()


func set_screen_shake(on: bool) -> void:
	screen_shake = on
	_save()


func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_apply_fullscreen()
	_save()


func _apply_fullscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value("game", "cpu_level", cpu_level)
	cfg.set_value("game", "screen_shake", screen_shake)
	cfg.set_value("game", "fullscreen", fullscreen)
	cfg.save(PATH)
