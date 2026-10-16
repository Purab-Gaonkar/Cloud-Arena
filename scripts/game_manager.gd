## game_manager.gd -- Match and spawn manager.
## LOCAL MODE: Both players spawned immediately (P2 may be a CPU), best-of-3 round flow.
## NETWORK MODE: Listens for peer connections.
extends Node2D

const FighterData := preload("res://scripts/fighter_data.gd")
const WorldBuilder := preload("res://scripts/world_builder.gd")
const FxSprite     := preload("res://scripts/fx_sprite.gd")
const UiStyle      := preload("res://scripts/ui_style.gd")

const ROUNDS_TO_WIN: int = 2
const SPAWN_POINTS: Array[Vector2] = [
	Vector2(-300.0, 70.0),
	Vector2( 300.0, 70.0),
]
const FLOOR_HALF_W: float = 1800.0
const MIN_FIGHTER_GAP: float = 44.0
const CAMERA_FLOOR_Y: float = 130.0

var local_mode: bool = true

var _players: Array = []
var _next_spawn_index: int = 0
var _network_players: Dictionary = {}

var _wins: Array[int] = [0, 0]
var _round: int = 1
var _round_over: bool = false
var _match_over: bool = false
var _shake: float = 0.0

@onready var _players_node: Node2D        = $Players
@onready var _spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var _camera: Camera2D            = $Camera2D

var _hud: Node = null
var _world: Node2D = null
var _intro_shown: bool = false
var _cine_target: Node = null
var _cine_layer: CanvasLayer = null
var _cine_dim: ColorRect
var _cine_band: ColorRect
var _cine_name: Label
var _cine_who: Label
var _cine_fx: Node = null
var _overlay: Node = null


func _ready() -> void:
	if get_tree().root.has_meta("local_mode"):
		local_mode = get_tree().root.get_meta("local_mode")

	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.09))
	_setup_background()
	_setup_platform()
	_setup_hud()

	if local_mode:
		_build_cinematic()
		_overlay = preload("res://scripts/overlay_menu.gd").new()
		_overlay.name = "OverlayMenu"
		add_child(_overlay)
		_spawn_local_players()
		_start_round()
	else:
		_setup_network()


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	AudioManager.set_slowmo(1.0)


func _process(delta: float) -> void:
	_update_camera(delta)


func _physics_process(_delta: float) -> void:
	if local_mode or multiplayer.is_server():
		_separate_fighters()


## Fighters have no body-vs-body collision (so nobody can stand on a head);
## instead anyone overlapping the other's body is nudged sideways out of it.
func _separate_fighters() -> void:
	if _players.size() < 2:
		return
	var a = _players[0]
	var b = _players[1]
	if not is_instance_valid(a) or not is_instance_valid(b):
		return
	var dx: float = b.position.x - a.position.x
	if absf(b.position.y - a.position.y) >= 112.0 or absf(dx) >= MIN_FIGHTER_GAP:
		return
	var dir := signf(dx)
	if dir == 0.0:
		dir = 1.0
	var push := (MIN_FIGHTER_GAP - absf(dx)) * 0.5
	var limit := 1000.0
	var ax: float = a.position.x - dir * push
	var bx: float = b.position.x + dir * push
	# Pinned against a wall: the other fighter takes the whole shove.
	if absf(ax) > limit:
		bx += (absf(ax) - limit) * dir
		ax = clampf(ax, -limit, limit)
	if absf(bx) > limit:
		ax -= (absf(bx) - limit) * dir
		bx = clampf(bx, -limit, limit)
	a.position.x = ax
	b.position.x = bx


# ── Camera ──────────────────────────────────────────────────────────────────

func _update_camera(delta: float) -> void:
	if _players.size() < 2 or not is_instance_valid(_players[0]) or not is_instance_valid(_players[1]):
		return
	# Real-time delta so the camera keeps moving during slow-motion / super freeze frames.
	var rd := delta / maxf(Engine.time_scale, 0.02)
	var a: Vector2 = _players[0].global_position
	var b: Vector2 = _players[1].global_position
	var vp := get_viewport_rect().size
	var dist := absf(a.x - b.x)

	var target_zoom := clampf(vp.x / (dist + 700.0), 0.75, 1.15)
	if is_instance_valid(_cine_target):
		target_zoom = 1.5
	var z := lerpf(_camera.zoom.x, target_zoom, clampf(5.0 * rd, 0.0, 1.0))
	_camera.zoom = Vector2(z, z)

	var half_w := vp.x / (2.0 * z)
	var limit := maxf(0.0, FLOOR_HALF_W - half_w)
	var tx := clampf((a.x + b.x) * 0.5, -limit, limit)
	var ty := CAMERA_FLOOR_Y - vp.y / z * 0.27
	if is_instance_valid(_cine_target):
		tx = clampf(_cine_target.global_position.x, -limit, limit)
		ty = _cine_target.global_position.y - 10.0
	_camera.position = _camera.position.lerp(Vector2(tx, ty), clampf(6.0 * rd, 0.0, 1.0))
	if _world:
		_world.update_parallax(_camera.position.x, _camera.position.y)

	_shake = move_toward(_shake, 0.0, 60.0 * rd)
	_camera.offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake


func shake(amount: float) -> void:
	if GameSettings.screen_shake:
		_shake = maxf(_shake, amount)


func spawn_fx(fx_name: String, pos: Vector2, facing: int = 1, tint: Color = Color.WHITE, fx_scale: float = 1.0) -> void:
	FxSprite.spawn(self, fx_name, pos, facing, tint, fx_scale)


# ── Super (finisher) cinematic ──────────────────────────────────────────────

func _build_cinematic() -> void:
	_cine_layer = CanvasLayer.new()
	_cine_layer.layer = 12
	_cine_layer.visible = false
	add_child(_cine_layer)

	_cine_dim = ColorRect.new()
	_cine_dim.color = Color(0.0, 0.0, 0.05, 0.0)
	_cine_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cine_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cine_layer.add_child(_cine_dim)

	_cine_band = ColorRect.new()
	_cine_band.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_cine_band.anchor_right = 1.0
	_cine_band.offset_top = -255
	_cine_band.offset_bottom = -105
	_cine_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cine_layer.add_child(_cine_band)

	_cine_who = UiStyle.label("", 30, Color.WHITE, true, 8)
	_cine_who.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_cine_who.anchor_right = 1.0
	_cine_who.offset_top = -249
	_cine_who.offset_bottom = -213
	_cine_who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cine_layer.add_child(_cine_who)

	_cine_name = UiStyle.label("", 100, Color.WHITE, true, 16)
	_cine_name.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_cine_name.anchor_right = 1.0
	_cine_name.offset_top = -217
	_cine_name.offset_bottom = -93
	_cine_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cine_name.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_cine_name.add_theme_constant_override("shadow_offset_x", 6)
	_cine_name.add_theme_constant_override("shadow_offset_y", 6)
	_cine_layer.add_child(_cine_name)


## Freeze-frame super intro: world dims, camera punches in on the attacker, banner slams in,
## then the fighter's strike script starts (begin_super_strike).
func super_cinematic(fighter: Node, move_name: String, color: Color) -> void:
	if _cine_layer == null:
		fighter.begin_super_strike()
		return
	_cine_target = fighter
	Engine.time_scale = 0.03
	AudioManager.play("super_start")
	AudioManager.duck(-12.0, 1.4)
	AudioManager.set_slowmo(0.5)
	var vp := get_viewport_rect().size
	_cine_layer.visible = true
	_cine_band.color = Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 0.9)
	_cine_who.text = fighter.char_id.to_upper() + "  -  SUPER ART"
	_cine_who.add_theme_color_override("font_color", color.lightened(0.4))
	_cine_name.text = move_name
	_cine_fx = FxSprite.spawn(_cine_layer, "speed_lines", Vector2(vp.x * 0.5, vp.y * 0.5), 1, Color(1, 1, 1, 0.5), 6.0)

	_cine_dim.color.a = 0.0
	_cine_band.modulate.a = 0.0
	_cine_name.modulate.a = 0.0
	_cine_name.pivot_offset = Vector2(vp.x * 0.5, 62)
	_cine_name.scale = Vector2(2.2, 2.2)
	_cine_name.position.x = 300.0
	var tw := create_tween().set_parallel(true).set_ignore_time_scale(true)
	tw.tween_property(_cine_dim, "color:a", 0.6, 0.15)
	tw.tween_property(_cine_band, "modulate:a", 1.0, 0.12)
	tw.tween_property(_cine_name, "modulate:a", 1.0, 0.1)
	tw.tween_property(_cine_name, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_cine_name, "position:x", 0.0, 0.25).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	shake(12.0)

	await _sleep(1.0)

	_cine_layer.visible = false
	if is_instance_valid(_cine_fx):
		_cine_fx.queue_free()
	Engine.time_scale = 1.0
	AudioManager.set_slowmo(1.0)
	_cine_target = null
	if is_instance_valid(fighter):
		fighter.begin_super_strike()


func show_combo(player_index: int, hits: int) -> void:
	if _hud:
		_hud.show_combo(player_index, hits)


## kind: 0 = blocked, 1 = hit, 2 = heavy hit.  dir is the defender's facing (sparks spray the other way).
func hit_effect(pos: Vector2, kind: int, dir: int) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.z_index = 20
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = [8, 14, 26][kind]
	p.lifetime = [0.2, 0.3, 0.45][kind]
	p.direction = Vector2(-dir, -0.3)
	p.spread = [70.0, 110.0, 160.0][kind]
	p.initial_velocity_min = [80.0, 160.0, 220.0][kind]
	p.initial_velocity_max = [180.0, 380.0, 560.0][kind]
	p.gravity = Vector2(0, 600)
	p.scale_amount_min = [3.0, 4.0, 5.0][kind]
	p.scale_amount_max = [5.0, 8.0, 12.0][kind]
	var base: Color = [Color(0.6, 0.9, 1.0), Color(1.0, 0.85, 0.3), Color(1.0, 0.35, 0.2)][kind]
	var ramp := Gradient.new()
	ramp.set_color(0, base)
	ramp.set_color(1, Color(base.r, base.g, base.b, 0.0))
	p.color_ramp = ramp
	add_child(p)
	p.emitting = true
	get_tree().create_timer(1.0).timeout.connect(p.queue_free)
	match kind:
		0: FxSprite.spawn(self, "block_spark", pos, dir, Color.WHITE, 1.0)
		1: FxSprite.spawn(self, "impact_burst", pos, dir, Color.WHITE, 0.8)
		_:
			FxSprite.spawn(self, "impact_burst", pos, dir, Color(1.0, 0.8, 0.6), 1.3)
			FxSprite.spawn(self, "dust", pos + Vector2(0.0, 50.0), dir, Color.WHITE, 1.6)


# ── Scene dressing ──────────────────────────────────────────────────────────

func _setup_background() -> void:
	var root := get_tree().root
	var stage: int = root.get_meta("stage") if root.has_meta("stage") else randi() % WorldBuilder.stage_count()
	_world = WorldBuilder.new()
	add_child(_world)
	_world.build(stage, get_viewport_rect().size)
	AudioManager.play_music("battle_%d" % posmod(stage, 3))


func _setup_platform() -> void:
	# The scene's StaticBody2D keeps the collision; the WorldBuilder draws the floor art.
	var floor_node := get_node_or_null("Floor")
	if floor_node:
		var old := floor_node.get_node_or_null("ColorRect")
		if old:
			old.queue_free()


func _setup_hud() -> void:
	_hud = get_node_or_null("TekkenHUD")
	if not _hud:
		_hud = preload("res://scripts/tekken_hud.gd").new()
		_hud.name = "TekkenHUD"
		add_child(_hud)
	if _hud.has_signal("time_up") and local_mode:
		_hud.time_up.connect(_on_time_up)


# ── Local match flow ────────────────────────────────────────────────────────

func _spawn_local_players() -> void:
	var scene: PackedScene = preload("res://scenes/player.tscn")
	var root := get_tree().root
	var vs_cpu: bool = root.get_meta("vs_cpu") if root.has_meta("vs_cpu") else false
	var picks: Array[String] = [
		root.get_meta("p1_char") if root.has_meta("p1_char") else "Fighter",
		root.get_meta("p2_char") if root.has_meta("p2_char") else "Samurai",
	]
	for i in range(2):
		var p = scene.instantiate()
		p.name          = "Player%d" % i
		p.player_index  = i
		p.local_mode    = true
		p.char_id       = picks[i]
		p.is_cpu        = (i == 1 and vs_cpu)
		p.position      = SPAWN_POINTS[i]
		if i == 1 and picks[0] == picks[1]:
			p.tint = Color(1.0, 0.6, 0.6)  # mirror match: tint P2 so they can be told apart
		if i == 1:
			p.facing_direction = -1
		_players_node.add_child(p)
		_players.append(p)

	_players[0]._opponent = _players[1]
	_players[1]._opponent = _players[0]

	var f1 := FighterData.get_fighter(picks[0])
	var f2 := FighterData.get_fighter(picks[1])
	_hud.set_portraits(picks[0], picks[1])
	_hud.set_fighters(f1["name"], f1["color"], ("CPU " if vs_cpu else "") + f2["name"], f2["color"])
	print("[GameManager] Local players spawned: %s vs %s%s" % [picks[0], picks[1], " (CPU)" if vs_cpu else ""])


func _sleep(seconds: float) -> void:
	# Real-time wait: unaffected by the K.O. slow-motion.
	await get_tree().create_timer(seconds, false, false, true).timeout


func _start_round() -> void:
	_round_over = false
	_hud.reset_round()
	_hud.set_round(_round)
	_hud.set_wins(_wins[0], _wins[1])
	for i in range(_players.size()):
		var p = _players[i]
		p.reset_for_new_round(SPAWN_POINTS[i])
		p.facing_direction = 1 if i == 0 else -1
		p.input_locked = true

	await _sleep(0.6)
	if _round == 1 and not _intro_shown:
		_intro_shown = true
		var n1: String = FighterData.get_fighter(_players[0].char_id)["name"]
		var n2: String = FighterData.get_fighter(_players[1].char_id)["name"]
		_hud.show_announcement("%s  VS  %s" % [n1, n2], UiStyle.GOLD, 64)
		await _sleep(1.6)
	AudioManager.play("round_bell")
	_hud.show_announcement("ROUND %d" % _round, Color.WHITE)
	await _sleep(1.1)
	_hud.show_announcement("FIGHT!", Color(1.0, 0.85, 0.1))
	for p in _players:
		p.input_locked = false
	_hud.start_clock()
	await _sleep(0.8)
	if not _round_over:
		_hud.clear_announcement()


func _on_time_up() -> void:
	if _round_over:
		return
	_round_over = true
	_lock_players()
	var h0: int = _players[0].health
	var h1: int = _players[1].health
	await _sleep(1.2)
	_finish_round(0 if h0 > h1 else (1 if h1 > h0 else -1))


## Called by a fighter the moment its health hits zero.
func on_player_ko(loser_index: int, by_super: bool = false) -> void:
	if not local_mode:
		end_round(loser_index)
		return
	if _round_over:
		return
	_round_over = true
	_hud.stop_round()
	_hud.show_announcement("SUPER K.O.!" if by_super else "K.O.!", Color(1.0, 0.85, 0.2) if by_super else Color(1.0, 0.2, 0.2))
	_lock_players()
	if by_super and is_instance_valid(_players[loser_index]):
		FxSprite.spawn(self, "ko_flash", _players[loser_index].global_position + Vector2(0.0, -20.0), 1, Color.WHITE, 3.2)
		shake(34.0)
	AudioManager.play("ko")
	AudioManager.set_slowmo(0.5)
	Engine.time_scale = 0.2 if by_super else 0.3
	await _sleep(0.7)
	Engine.time_scale = 1.0
	AudioManager.set_slowmo(1.0)
	await _sleep(1.3)
	_finish_round(1 - loser_index)


func _lock_players() -> void:
	for p in _players:
		p.input_locked = true


func _finish_round(winner: int) -> void:
	_hud.stop_round()
	if winner >= 0:
		_wins[winner] += 1
		_hud.set_wins(_wins[0], _wins[1])
		var nm: String = _players[winner].get("char_id").to_upper()
		_hud.show_announcement("%s WINS" % nm, Color(1.0, 0.85, 0.1))
	else:
		_hud.show_announcement("DRAW", Color.WHITE)
	await _sleep(2.0)

	if winner >= 0 and _wins[winner] >= ROUNDS_TO_WIN:
		_match_over = true
		_hud.show_announcement("PLAYER %d WINS THE MATCH!" % (winner + 1), Color(1.0, 0.85, 0.1))
		AudioManager.stop_music(0.4)
		AudioManager.play_jingle("jingle_win", 6.0)
		_overlay.show_match_end("PLAYER %d WINS!" % (winner + 1))
		return
	AudioManager.play_jingle("jingle_round", 1.5)
	_round += 1
	_start_round()


# ── Network mode (unchanged behaviour) ──────────────────────────────────────

func _setup_network() -> void:
	_hud.start_clock()
	if _spawner:
		_spawner.spawn_path = NodePath("../Players")
		_spawner.add_spawnable_scene("res://scenes/player.tscn")

	var net := _get_network_manager()
	if net:
		net.player_connected.connect(_on_player_connected)
		net.player_disconnected.connect(_on_player_disconnected)
		net.network_ready.connect(_on_network_ready)
		if multiplayer.is_server():
			_spawn_network_player(1)


func _on_network_ready() -> void:
	if multiplayer.is_server():
		_spawn_network_player(1)


func _on_player_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_spawn_network_player(peer_id)


func _on_player_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if peer_id in _network_players:
		_network_players[peer_id].queue_free()
		_network_players.erase(peer_id)


func _spawn_network_player(peer_id: int) -> void:
	if peer_id in _network_players or _next_spawn_index >= SPAWN_POINTS.size():
		return
	var scene: PackedScene = preload("res://scenes/player.tscn")
	var p = scene.instantiate()
	p.name         = str(peer_id)
	p.player_index = _next_spawn_index
	p.local_mode   = false
	p.position     = SPAWN_POINTS[_next_spawn_index]
	p.set_multiplayer_authority(peer_id)
	var sync = p.get_node_or_null("MultiplayerSynchronizer")
	if sync:
		sync.set_multiplayer_authority(1)
	_next_spawn_index += 1
	_players_node.add_child(p, true)
	_network_players[peer_id] = p
	_players.append(p)
	if _players.size() == 2:
		_players[0]._opponent = _players[1]
		_players[1]._opponent = _players[0]


func end_round(loser_index: int) -> void:
	print("[GameManager] Round ended. Player %d lost." % loser_index)
	await get_tree().create_timer(4.0).timeout
	_reset_network_round()


func _reset_network_round() -> void:
	if _hud and _hud.has_method("reset_round"):
		_hud.reset_round()
	for i in range(_players.size()):
		var p = _players[i]
		if is_instance_valid(p):
			p.reset_for_new_round(SPAWN_POINTS[i % SPAWN_POINTS.size()])
			p.facing_direction = 1 if i == 0 else -1


func _get_network_manager() -> Node:
	return get_node_or_null("/root/NetworkManager")
