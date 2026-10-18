## audio_manager.gd -- Autoload "AudioManager": music with crossfades, pooled SFX, volume settings.
## Missing audio files are skipped silently so the game runs fine without them.
## Credits: assets/audio/CREDITS.md (all CC0).
extends Node

const SFX_DIR:   String = "res://assets/audio/sfx/"
const MUSIC_DIR: String = "res://assets/audio/music/"
const SETTINGS_PATH: String = "user://settings.cfg"
const POOL_SIZE: int = 14
const SILENT_DB: float = -60.0

## Logical sound -> file variants in assets/audio/sfx (one is picked at random).
const SFX: Dictionary = {
	"hit_light":  ["hit_light_1", "hit_light_2", "hit_light_3"],
	"hit_heavy":  ["hit_heavy_1", "hit_heavy_2"],
	"hit_super":  ["hit_super"],
	"hit_super_final": ["hit_super_final"],
	"block":      ["block_1", "block_2"],
	"swing_light": ["swing_light"],
	"swing_heavy": ["swing_heavy"],
	"jump":       ["jump"],
	"step":       ["step_1", "step_2", "step_3"],
	"land":       ["land"],
	"ko":         ["ko", "ko_boom"],
	"round_bell": ["round_bell"],
	"super_start": ["super_start"],
	"super_ready": ["super_ready"],
	"ui_move":    ["ui_move"],
	"ui_confirm": ["ui_confirm"],
	"ui_back":    ["ui_back"],
	"ui_open":    ["ui_open"],
	"ui_error":   ["ui_error"],
	"ui_toggle":  ["ui_toggle"],
	"ui_select":  ["ui_select"],
	"jingle_win":   ["jingle_win"],
	"jingle_round": ["jingle_round"],
}

## Logical track -> file in assets/audio/music.
const MUSIC: Dictionary = {
	"menu":     "menu.mp3",
	"battle_0": "battle_twilight.ogg",
	"battle_1": "battle_bamboo.ogg",
	"battle_2": "battle_dawn.ogg",
}

var music_volume: float = 0.7   # linear 0-1
var sfx_volume:   float = 0.9

var _cache: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _music: Array[AudioStreamPlayer] = []
var _active: int = 0
var _current_track: String = ""
var _duck_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_bus("Music")
	_ensure_bus("SFX")
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool.append(p)
	for i in range(2):
		var m := AudioStreamPlayer.new()
		m.bus = "Music"
		m.volume_db = SILENT_DB
		add_child(m)
		_music.append(m)
	_load_settings()
	_apply_volumes()


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) == -1:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")


func _load_stream(path: String) -> AudioStream:
	if _cache.has(path):
		return _cache[path]
	var stream: AudioStream = null
	if ResourceLoader.exists(path):
		stream = load(path) as AudioStream
	_cache[path] = stream
	return stream


# ── SFX ─────────────────────────────────────────────────────────────────────

## Set on the dedicated server so gameplay sounds are sent to clients instead of played locally.
var net_forward: Callable = Callable()


func play(sound: String, volume_db: float = 0.0, pitch_jitter: float = 0.05, local_only: bool = false) -> void:
	if net_forward.is_valid() and not local_only:
		net_forward.call(sound, volume_db)
		return
	var variants: Array = SFX.get(sound, [])
	if variants.is_empty():
		return
	var stream := _load_stream("%s%s.ogg" % [SFX_DIR, variants[randi() % variants.size()]])
	if stream == null:
		return
	for p in _pool:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
			p.play()
			return


## Short fanfare: ducks the music while it plays.
func play_jingle(sound: String, duck_seconds: float = 2.5) -> void:
	play(sound, 0.0, 0.0)
	duck(-14.0, duck_seconds)


# ── Music ───────────────────────────────────────────────────────────────────

func play_music(track: String, fade: float = 0.8) -> void:
	if track == _current_track:
		return
	_current_track = track
	var path: String = MUSIC_DIR + str(MUSIC.get(track, ""))
	var stream := _load_stream(path)
	var old := _music[_active]
	_active = 1 - _active
	var incoming := _music[_active]

	var fade_out := create_tween().set_ignore_time_scale(true)
	fade_out.tween_property(old, "volume_db", SILENT_DB, fade)
	fade_out.tween_callback(old.stop)

	if stream == null:
		return
	if "loop" in stream:
		stream.loop = true
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.play()
	create_tween().set_ignore_time_scale(true).tween_property(incoming, "volume_db", 0.0, fade)


func stop_music(fade: float = 0.6) -> void:
	_current_track = ""
	for m in _music:
		if m.playing:
			var tw := create_tween().set_ignore_time_scale(true)
			tw.tween_property(m, "volume_db", SILENT_DB, fade)
			tw.tween_callback(m.stop)


## Temporarily lower the music bus (jingles, super cinematic).
func duck(db: float, seconds: float) -> void:
	var idx := AudioServer.get_bus_index("Music")
	if _duck_tween:
		_duck_tween.kill()
	var base := linear_to_db(maxf(music_volume, 0.0001))
	AudioServer.set_bus_volume_db(idx, base + db)
	_duck_tween = create_tween().set_ignore_time_scale(true)
	_duck_tween.tween_interval(seconds)
	_duck_tween.tween_method(func(v: float) -> void: AudioServer.set_bus_volume_db(idx, v), base + db, base, 0.6)


## Subtle tension: music plays a touch faster while a fighter is nearly KO'd (1.0 = normal).
func set_music_pitch(p: float) -> void:
	for m in _music:
		m.pitch_scale = lerpf(m.pitch_scale, p, 0.05)


func reset_pitch() -> void:
	for m in _music:
		m.pitch_scale = 1.0


## Dramatic slow-motion for the audio itself (1.0 = normal).
func set_slowmo(speed: float) -> void:
	AudioServer.playback_speed_scale = speed


# ── Settings ────────────────────────────────────────────────────────────────

func set_music_volume(v: float) -> void:
	music_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()
	_save_settings()


func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()
	_save_settings()


func _apply_volumes() -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(maxf(music_volume, 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(maxf(sfx_volume, 0.0001)))


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		music_volume = float(cfg.get_value("audio", "music", music_volume))
		sfx_volume = float(cfg.get_value("audio", "sfx", sfx_volume))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.save(SETTINGS_PATH)
