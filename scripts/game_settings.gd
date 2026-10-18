## game_settings.gd -- Autoload "GameSettings": gameplay/display options saved to user://settings.cfg
## (audio volumes are stored by AudioManager in the same file).
extends Node

const PATH: String = "user://settings.cfg"
const LEVEL_NAMES: Array = ["EASY", "NORMAL", "HARD"]
const ROUND_TIMES: Array = [99, 60, 30, 0]     # 0 = no time limit

var cpu_level: int = 1
var screen_shake: bool = true
var fullscreen: bool = false
var rounds_to_win: int = 2
var round_time_index: int = 0
var fg_blur: bool = true
var seen_tips: bool = false
const DEFAULT_API: String = "https://cloud-arena-matchmaking-api-uqc74rpzbq-uc.a.run.app"
var online_api: String = DEFAULT_API
var player_name: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		cpu_level = clampi(int(cfg.get_value("game", "cpu_level", cpu_level)), 0, 2)
		screen_shake = bool(cfg.get_value("game", "screen_shake", screen_shake))
		fullscreen = bool(cfg.get_value("game", "fullscreen", fullscreen))
		rounds_to_win = clampi(int(cfg.get_value("game", "rounds_to_win", rounds_to_win)), 1, 3)
		round_time_index = clampi(int(cfg.get_value("game", "round_time_index", round_time_index)), 0, ROUND_TIMES.size() - 1)
		fg_blur = bool(cfg.get_value("game", "fg_blur", fg_blur))
		seen_tips = bool(cfg.get_value("game", "seen_tips", seen_tips))
		online_api = str(cfg.get_value("online", "api", online_api))
		online_api = Account.clean_url(online_api)
		if online_api == "http://127.0.0.1:8000":   # old local-dev default saved by earlier versions
			online_api = DEFAULT_API
		player_name = str(cfg.get_value("online", "name", player_name))
	_apply_fullscreen()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		set_fullscreen(not fullscreen)


func cycle_cpu_level() -> void:
	cpu_level = (cpu_level + 1) % LEVEL_NAMES.size()
	_save()


func cycle_rounds() -> void:
	rounds_to_win = rounds_to_win % 3 + 1
	_save()


func cycle_round_time() -> void:
	round_time_index = (round_time_index + 1) % ROUND_TIMES.size()
	_save()


func round_seconds() -> int:
	return ROUND_TIMES[round_time_index]


func set_online(api: String, name: String) -> void:
	online_api = Account.clean_url(api)
	player_name = name.strip_edges()
	_save()


func mark_tips_seen() -> void:
	seen_tips = true
	_save()


func set_fg_blur(on: bool) -> void:
	fg_blur = on
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
	cfg.set_value("game", "rounds_to_win", rounds_to_win)
	cfg.set_value("game", "round_time_index", round_time_index)
	cfg.set_value("game", "fg_blur", fg_blur)
	cfg.set_value("game", "seen_tips", seen_tips)
	cfg.set_value("online", "api", online_api)
	cfg.set_value("online", "name", player_name)
	cfg.save(PATH)
