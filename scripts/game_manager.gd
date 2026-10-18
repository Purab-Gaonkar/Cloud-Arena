## game_manager.gd -- Match and spawn manager.
## LOCAL MODE: Both players spawned immediately (P2 may be a CPU), best-of-3 round flow.
## NETWORK MODE: Listens for peer connections.
extends Node2D

const FighterData := preload("res://scripts/fighter_data.gd")
const WorldBuilder := preload("res://scripts/world_builder.gd")
const FxSprite     := preload("res://scripts/fx_sprite.gd")
const UiStyle      := preload("res://scripts/ui_style.gd")

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
var _punch: float = 0.0   # brief camera zoom-in on big hits

@onready var _players_node: Node2D        = $Players
@onready var _spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var _camera: Camera2D            = $Camera2D

var _hud: Node = null
var _world: Node2D = null
var _intro_shown: bool = false
var _training: bool = false
var _stage_index: int = 0
var rounds_to_win: int = 2
var _stats: Dictionary = {"damage": [0, 0], "combo": [0, 0], "supers": [0, 0]}
var _match_start_ms: int = 0
var _cine_target: Node = null
var _cine_zoom: float = 1.5
var _cine_layer: CanvasLayer = null
var _cine_dim: ColorRect
var _cine_band: ColorRect
var _cine_name: Label
var _cine_who: Label
var _cine_fx: Node = null
var _cine_portrait: TextureRect
var _overlay: Node = null
var _online: bool = false
var _net: Node = null            # online_match.gd (RPC endpoint) when playing online
var _is_dedicated: bool = false  # true on the headless server process
var _status_layer: CanvasLayer = null
var _status_label: Label = null
var _leaving: bool = false
var _bot: Node = null
var _online_info: Dictionary = {}     # server: the match description sent to clients (re-sent on reconnect)
var _peer_ids: Array = []             # client: peer id of each slot, from the server
var _client_in_match: bool = false
var _client_match_over: bool = false
var _reconnecting: bool = false
var _resumed: bool = false
const RECONNECT_WINDOW_SEC: float = 30.0


func _ready() -> void:
	if get_tree().root.has_meta("local_mode"):
		local_mode = get_tree().root.get_meta("local_mode")
	_online = not local_mode
	_is_dedicated = _online and NetworkManager.is_server
	_training = local_mode and get_tree().root.has_meta("training") and get_tree().root.get_meta("training")
	_match_start_ms = Time.get_ticks_msec()
	rounds_to_win = GameSettings.rounds_to_win

	RenderingServer.set_default_clear_color(Color(0.05, 0.05, 0.09))
	if _online:
		_net = preload("res://scripts/online_match.gd").new()
		_net.name = "Net"
		add_child(_net)
	if local_mode:
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
		_setup_online()


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	AudioManager.set_slowmo(1.0)
	AudioManager.reset_pitch()


func _process(delta: float) -> void:
	_update_camera(delta)


func _process_music_tension() -> void:
	var low := 100
	for p in _players:
		if is_instance_valid(p):
			low = mini(low, int(p.health))
	AudioManager.set_music_pitch(1.06 if (low <= 25 and low > 0 and not _round_over) else 1.0)


func _physics_process(_delta: float) -> void:
	_process_music_tension()
	if local_mode or multiplayer.is_server():
		_separate_fighters()
	if _training:
		for p in _players:
			if is_instance_valid(p):
				p.meter = 100
				if p.health < 45:
					p.health = 100


var _last_hit: int = 0
var _last_combo: int = 0
var _combo_total: int = 0


func _unhandled_input(event: InputEvent) -> void:
	if _training and event.is_action_pressed("dummy_cycle") and _players.size() == 2:
		var dummy = _players[1]
		dummy.dummy_mode = (dummy.dummy_mode + 1) % 3
		AudioManager.play("ui_toggle")
		_refresh_training_info()


func _refresh_training_info() -> void:
	if not _training or _hud == null:
		return
	var modes := ["STAND", "BLOCK", "FIGHT BACK"]
	_hud.set_training_info("DUMMY: %s  (TAB / R3 to change)\nLAST HIT %d    COMBO %d HITS    COMBO DAMAGE %d" % [modes[_players[1].dummy_mode], _last_hit, _last_combo, _combo_total])


func stat_hit(attacker_index: int, damage: int, combo: int) -> void:
	if _training and attacker_index == 0:
		_last_hit = damage
		_last_combo = maxi(combo, 1)
		_combo_total = damage if combo <= 1 else _combo_total + damage
		_refresh_training_info()
	_stats["damage"][attacker_index] += damage
	_stats["combo"][attacker_index] = maxi(_stats["combo"][attacker_index], combo)


func stat_super(player_index: int) -> void:
	_stats["supers"][player_index] += 1


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
	target_zoom += _punch
	_punch = move_toward(_punch, 0.0, 0.35 * rd)
	if is_instance_valid(_cine_target):
		target_zoom = _cine_zoom
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


## On the dedicated server, cosmetic effects are sent to the clients instead of being drawn.
func _forwarded(method: String, args: Array) -> bool:
	if _is_dedicated and _net:
		_net.net_call.rpc(method, args)
		return true
	return false


func shake(amount: float) -> void:
	if _forwarded("shake", [amount]):
		return
	if GameSettings.screen_shake:
		_shake = maxf(_shake, amount)
		_punch = maxf(_punch, clampf(amount * 0.004, 0.0, 0.1))


## Floating text in the arena (damage numbers, COUNTER!, PARRY!, super names).
func popup_text(pos: Vector2, text: String, color: Color = Color.WHITE, font_size: int = 28, rise: float = 70.0, life: float = 0.8) -> void:
	if _forwarded("popup_text", [pos, text, color, font_size, rise, life]):
		return
	var lbl := UiStyle.label(text, font_size, color, true, 8)
	lbl.z_index = 60
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)
	lbl.reset_size()
	lbl.position = pos - lbl.size * 0.5
	lbl.pivot_offset = lbl.size * 0.5
	lbl.scale = Vector2(1.5, 1.5)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lbl, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "position:y", lbl.position.y - rise, life)
	tw.tween_property(lbl, "modulate:a", 0.0, life * 0.5).set_delay(life * 0.5)
	tw.chain().tween_callback(lbl.queue_free)


func spawn_fx(fx_name: String, pos: Vector2, facing: int = 1, tint: Color = Color.WHITE, fx_scale: float = 1.0) -> void:
	if _forwarded("spawn_fx", [fx_name, pos, facing, tint, fx_scale]):
		return
	# Looping sheets (aura_flame, speed_lines) get a short lifetime so one-off effects never linger.
	FxSprite.spawn(self, fx_name, pos, facing, tint, fx_scale, 0.45)


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

	_cine_portrait = TextureRect.new()
	_cine_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cine_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_cine_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_cine_portrait.size = Vector2(300, 300)
	_cine_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cine_layer.add_child(_cine_portrait)

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
	if _is_dedicated:
		_forwarded("_cine_remote", [fighter.player_index, move_name, color])
		return
	_run_cinematic(fighter, move_name, color, true)


## Client side of an online super: same banner and camera punch, but the match never freezes.
func _cine_remote(player_index: int, move_name: String, color: Color) -> void:
	if player_index < _players.size() and is_instance_valid(_players[player_index]):
		_run_cinematic(_players[player_index], move_name, color, false)


func _ko_cam(player_index: int) -> void:
	if player_index < _players.size() and is_instance_valid(_players[player_index]):
		_cine_target = _players[player_index]
		_cine_zoom = 1.3
		await _sleep(1.0)
		_cine_target = null


func _run_cinematic(fighter: Node, move_name: String, color: Color, freeze: bool) -> void:
	if _cine_layer == null:
		return
	_cine_target = fighter
	_cine_zoom = 1.5
	AudioManager.play("super_start", 0.0, 0.05, true)
	AudioManager.duck(-12.0, 1.4)
	if freeze:
		Engine.time_scale = 0.03
		AudioManager.set_slowmo(0.5)
	var vp := get_viewport_rect().size
	_cine_layer.visible = true
	_cine_band.color = Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 0.9)
	_cine_who.text = fighter.char_id.to_upper() + "  -  SUPER ART"
	_cine_who.add_theme_color_override("font_color", color.lightened(0.4))
	_cine_name.text = move_name
	var sheet := load("%s%s/Idle.png" % [FighterData.BASE_DIR, fighter.char_id]) as Texture2D
	if sheet:
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(34, 40, 64, 64)
		_cine_portrait.texture = atlas
	var on_left: bool = fighter.player_index == 0
	_cine_portrait.position = Vector2(60.0 if on_left else vp.x - 360.0, 30.0)
	_cine_portrait.modulate.a = 0.0
	create_tween().set_ignore_time_scale(true).tween_property(_cine_portrait, "modulate:a", 1.0, 0.2)
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
	if freeze:
		Engine.time_scale = 1.0
		AudioManager.set_slowmo(1.0)
	_cine_target = null


func show_combo(player_index: int, hits: int) -> void:
	if _forwarded("show_combo", [player_index, hits]):
		return
	if _hud:
		_hud.show_combo(player_index, hits)


## kind: 0 = blocked, 1 = hit, 2 = heavy hit.  dir is the defender's facing (sparks spray the other way).
func hit_effect(pos: Vector2, kind: int, dir: int) -> void:
	if _forwarded("hit_effect", [pos, kind, dir]):
		return
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
	_build_world(root.get_meta("stage") if root.has_meta("stage") else randi() % WorldBuilder.stage_count())


func _build_world(stage: int) -> void:
	if _world:
		_world.queue_free()
	_world = WorldBuilder.new()
	add_child(_world)
	_world.build(stage, get_viewport_rect().size, true)
	_stage_index = stage
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
	if _is_dedicated:
		var proxy := preload("res://scripts/hud_proxy.gd").new()
		proxy.name = "HudProxy"
		add_child(proxy)
		proxy.setup(_hud, _net)
		_hud = proxy
	if _hud.has_signal("time_up") and (local_mode or _is_dedicated):
		_hud.time_up.connect(_on_time_up)


# ── Local match flow ────────────────────────────────────────────────────────

func _spawn_local_players() -> void:
	var scene: PackedScene = preload("res://scenes/player.tscn")
	var root := get_tree().root
	var vs_cpu: bool = root.get_meta("vs_cpu") if root.has_meta("vs_cpu") else false
	var pals: Array[int] = [
		int(root.get_meta("p1_pal")) if root.has_meta("p1_pal") else 0,
		int(root.get_meta("p2_pal")) if root.has_meta("p2_pal") else 0,
	]
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
		p.palette       = pals[i]
		p.is_cpu        = (i == 1 and vs_cpu)
		p.is_dummy      = (i == 1 and _training)
		p.position      = SPAWN_POINTS[i]
		p.tint = WorldBuilder.actor_tint(_stage_index)
		if i == 1 and picks[0] == picks[1] and pals[0] == pals[1]:
			p.palette = (pals[0] + 1) % FighterData.PALETTE_HUES.size()  # mirror match: recolour P2 so they can be told apart
		if i == 1:
			p.facing_direction = -1
		_players_node.add_child(p)
		_players.append(p)

	_players[0]._opponent = _players[1]
	_players[1]._opponent = _players[0]

	var f1 := FighterData.get_fighter(picks[0])
	var f2 := FighterData.get_fighter(picks[1])
	_hud.set_portraits(picks[0], picks[1])
	if _training:
		f2 = f2.duplicate()
		f2["name"] = "DUMMY"
	_hud.set_fighters(f1["name"], f1["color"], ("CPU " if (vs_cpu and not _training) else "") + f2["name"], f2["color"])
	print("[GameManager] Local players spawned: %s vs %s%s" % [picks[0], picks[1], " (CPU)" if vs_cpu else ""])


func _sleep(seconds: float) -> void:
	# Real-time wait: unaffected by the K.O. slow-motion.
	await get_tree().create_timer(seconds, false, false, true).timeout


func _start_round() -> void:
	_round_over = false
	_hud.configure_rules(rounds_to_win, NetworkManager.server_round_seconds if _online else GameSettings.round_seconds())
	_hud.reset_round()
	_hud.set_round(_round)
	_hud.set_wins(_wins[0], _wins[1])
	for i in range(_players.size()):
		var p = _players[i]
		p.reset_for_new_round(SPAWN_POINTS[i])
		p.facing_direction = 1 if i == 0 else -1
		p.input_locked = true

	if _training:
		_hud.set_training()
		_refresh_training_info()
		for p in _players:
			p.input_locked = false
		return

	if _round == 1 and not _intro_shown and not GameSettings.seen_tips and local_mode:
		_show_first_time_tips()
	await _sleep(0.6)
	if _round == 1 and not _intro_shown:
		_intro_shown = true
		var n1: String = FighterData.get_fighter(_players[0].char_id)["name"]
		var n2: String = FighterData.get_fighter(_players[1].char_id)["name"]
		_hud.show_announcement("%s  VS  %s\n- %s -" % [n1, n2, WorldBuilder.stage_name(_stage_index)], UiStyle.GOLD, 56)
		await _sleep(1.6)
	AudioManager.play("round_bell")
	var final_round: bool = rounds_to_win > 1 and _wins[0] == rounds_to_win - 1 and _wins[1] == rounds_to_win - 1
	if final_round:
		_hud.set_round_text("FINAL ROUND")
	_hud.show_announcement("FINAL ROUND" if final_round else "ROUND %d" % _round, Color(1.0, 0.45, 0.3) if final_round else Color.WHITE)
	await _sleep(1.1)
	_hud.show_announcement("FIGHT!", Color(1.0, 0.85, 0.1))
	for p in _players:
		p.input_locked = false
	_hud.start_clock()
	await _sleep(0.8)
	if not _round_over:
		_hud.clear_announcement()


## One-off controls reminder on the very first match (re-readable any time in Controls / pause).
func _show_first_time_tips() -> void:
	GameSettings.mark_tips_seen()
	var layer := CanvasLayer.new()
	layer.layer = 11
	add_child(layer)
	var lbl := UiStyle.label("P1:  A / D move   W jump   J attack x3   U heavy   S block   I super          P2:  Arrows move/jump   /  attack   ,  heavy   Down  block   M  super
Double-tap a direction to dash   |   Attack + Block = throw   |   Gamepads work automatically   |   ESC = pause + move list", 17, UiStyle.TEXT, false, 6)
	lbl.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	lbl.offset_top = -64
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(lbl)
	var tw := create_tween().set_ignore_time_scale(true)
	tw.tween_interval(7.0)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.0)
	tw.tween_callback(layer.queue_free)


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
	if _online and not _is_dedicated:
		return
	if _round_over:
		return
	_round_over = true
	_hud.stop_round()
	_hud.show_announcement("SUPER K.O.!" if by_super else "K.O.!", Color(1.0, 0.85, 0.2) if by_super else Color(1.0, 0.2, 0.2))
	_lock_players()
	if by_super and is_instance_valid(_players[loser_index]):
		spawn_fx("ko_flash", _players[loser_index].global_position + Vector2(0.0, -20.0), 1, Color.WHITE, 3.2)
		shake(34.0)
	AudioManager.play("ko")
	if _online:
		# Online the clock never slows down; clients just zoom in on the loser.
		_forwarded("_ko_cam", [loser_index])
		await _sleep(2.0)
	else:
		AudioManager.set_slowmo(0.5)
		if is_instance_valid(_players[loser_index]):
			_cine_target = _players[loser_index]
			_cine_zoom = 1.3
		Engine.time_scale = 0.2 if by_super else 0.3
		await _sleep(0.7)
		Engine.time_scale = 1.0
		AudioManager.set_slowmo(1.0)
		_cine_target = null
		await _sleep(1.3)
	_finish_round(1 - loser_index)


func _lock_players() -> void:
	for p in _players:
		p.input_locked = true


func _conclude_match(winner: int) -> void:
	_match_over = true
	_hud.show_announcement("PLAYER %d WINS THE MATCH!" % (winner + 1), Color(1.0, 0.85, 0.1))
	var stats := _stats.duplicate(true)
	stats["rounds"] = [_wins[0], _wins[1]]
	stats["time"] = (Time.get_ticks_msec() - _match_start_ms) / 1000.0
	stats["names"] = [FighterData.get_fighter(_players[0].char_id)["name"], FighterData.get_fighter(_players[1].char_id)["name"]]
	if _online:
		var winner_name := "Player %d" % (winner + 1)
		if _net and winner < _net.order.size() and _net.regs.has(_net.order[winner]):
			winner_name = _net.regs[_net.order[winner]]["name"]
			stats["names"] = [_net.regs[_net.order[0]]["name"] if _net.order.size() > 0 else "P1", _net.regs[_net.order[1]]["name"] if _net.order.size() > 1 else "P2"]
		var loser_name := ""
		if _net and (1 - winner) < _net.order.size() and _net.regs.has(_net.order[1 - winner]):
			loser_name = _net.regs[_net.order[1 - winner]]["name"]
		NetworkManager.report_result(winner_name, loser_name, stats["time"])
		NetworkManager.room_event("match_over", {"winner": winner_name, "rounds": stats["rounds"]})
		_net.net_match_end.rpc("%s WINS!" % winner_name.to_upper(), stats)
		return
	AudioManager.stop_music(0.4)
	AudioManager.play_jingle("jingle_win", 6.0)
	_overlay.show_match_end("PLAYER %d WINS!" % (winner + 1), stats)


func _finish_round(winner: int) -> void:
	_hud.stop_round()
	if winner >= 0:
		_wins[winner] += 1
		_hud.set_wins(_wins[0], _wins[1])
		var nm: String = _players[winner].get("char_id").to_upper()
		if int(_players[winner].health) >= 100:
			_hud.show_announcement("PERFECT!", Color(0.4, 1.0, 0.8))
		else:
			_hud.show_announcement("%s WINS" % nm, Color(1.0, 0.85, 0.1))
	else:
		_hud.show_announcement("DRAW", Color.WHITE)
	await _sleep(2.0)

	if winner >= 0 and _wins[winner] >= rounds_to_win:
		_conclude_match(winner)
		return
	AudioManager.play_jingle("jingle_round", 1.5)
	_round += 1
	_start_round()


# ── Online play ─────────────────────────────────────────────────────────────

func _setup_online() -> void:
	if _spawner:
		_spawner.spawn_path = NodePath("../Players")
		_spawner.add_spawnable_scene("res://scenes/player.tscn")
	if _is_dedicated:
		# Gameplay sounds are sent to the clients; the server itself is silent.
		AudioManager.net_forward = Callable(self, "_forward_sfx")
		return

	_build_cinematic()
	_overlay = preload("res://scripts/overlay_menu.gd").new()
	_overlay.name = "OverlayMenu"
	_overlay.online = true
	add_child(_overlay)
	_players_node.child_entered_tree.connect(func(_n: Node) -> void: _refresh_players.call_deferred())
	_players_node.child_exiting_tree.connect(func(_n: Node) -> void: _refresh_players.call_deferred())
	_build_status_label()
	online_set_status("CONNECTING")

	NetworkManager.server_lost.connect(_on_server_lost)
	NetworkManager.connect_failed.connect(_on_server_lost)
	if NetworkManager.is_connected_to_server():
		_register_with_server()
	else:
		NetworkManager.network_ready.connect(_register_with_server, CONNECT_ONE_SHOT)
	if NetworkManager.bot_mode:
		_bot = preload("res://scripts/online_bot.gd").new()
		_bot.name = "Bot"
		add_child(_bot)


func _forward_sfx(sound: String, volume_db: float) -> void:
	if _net:
		_net.net_sfx.rpc(sound, volume_db)


func _register_with_server() -> void:
	var root := get_tree().root
	var char_id: String = root.get_meta("p1_char") if root.has_meta("p1_char") else "Fighter"
	var pal: int = int(root.get_meta("p1_pal")) if root.has_meta("p1_pal") else 0
	_net.register.rpc_id(1, NetworkManager.join_ticket, char_id, pal)
	online_set_status("WAITING FOR OPPONENT")


func _refresh_players() -> void:
	var list: Array = []
	for c in _players_node.get_children():
		if c.has_method("receive_hit") and not c.is_queued_for_deletion():
			list.append(c)
	list.sort_custom(func(x, y) -> bool: return int(x.player_index) < int(y.player_index))
	_players = list
	if not _is_dedicated:
		for p in list:
			if int(p.player_index) < _peer_ids.size():
				p.owning_peer_id = int(_peer_ids[int(p.player_index)])


func _build_status_label() -> void:
	_status_layer = CanvasLayer.new()
	_status_layer.layer = 9
	add_child(_status_layer)
	_status_label = UiStyle.label("", 54, UiStyle.GOLD, true, 12)
	_status_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_layer.add_child(_status_label)
	var tw := create_tween().set_loops()
	tw.tween_property(_status_label, "modulate:a", 0.45, 0.8)
	tw.tween_property(_status_label, "modulate:a", 1.0, 0.8)


func online_set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text + "..."
		_status_layer.visible = true


func _on_server_lost() -> void:
	if _leaving or _reconnecting:
		return
	if _client_in_match and not _client_match_over:
		_reconnect_loop()
		return
	online_set_status("CONNECTION LOST")
	await _sleep(2.0)
	online_leave()


func online_leave() -> void:
	if _leaving:
		return
	_leaving = true
	NetworkManager.disconnect_game()
	AudioManager.net_forward = Callable()
	Transition.go("res://scenes/main.tscn")


func online_request_rematch() -> void:
	if _net:
		_net.request_rematch.rpc_id(1)


## SERVER: spawn both fighters and describe the match for the clients.
func online_build_match(regs: Dictionary, order: Array) -> Dictionary:
	_stage_index = randi() % WorldBuilder.stage_count()
	rounds_to_win = clampi(NetworkManager.server_rounds, 1, 3)
	var scene: PackedScene = preload("res://scenes/player.tscn")
	var names: Array = []
	var chars: Array = []
	var pals: Array = []
	var peers: Array = []
	for i in range(2):
		var peer_id: int = order[i]
		var reg: Dictionary = regs[peer_id]
		var pal: int = reg["pal"]
		if i == 1 and regs[order[0]]["char"] == reg["char"] and regs[order[0]]["pal"] == pal:
			pal = (pal + 1) % FighterData.PALETTE_HUES.size()
		var p = scene.instantiate()
		p.name          = "P%d" % i               # stable across reconnects (the peer id changes)
		p.owning_peer_id = peer_id
		p.player_index  = i
		p.local_mode    = false
		p.char_id       = reg["char"]
		p.palette       = pal
		p.tint          = WorldBuilder.actor_tint(_stage_index)
		p.position      = SPAWN_POINTS[i]
		p.facing_direction = 1 if i == 0 else -1
		_players_node.add_child(p, true)
		_players.append(p)
		names.append(reg["name"])
		chars.append(reg["char"])
		pals.append(pal)
		peers.append(peer_id)
	_players[0]._opponent = _players[1]
	_players[1]._opponent = _players[0]
	_online_info = {
		"stage": _stage_index, "rounds": rounds_to_win, "seconds": NetworkManager.server_round_seconds,
		"names": names, "chars": chars, "pals": pals, "peers": peers,
	}
	return _online_info


## SERVER: the match description with the current peer ids (they change when a player reconnects).
func online_info() -> Dictionary:
	var info := _online_info.duplicate()
	info["peers"] = _net.order.duplicate()
	return info


## SERVER: freeze / thaw the whole simulation (clock, physics, round flow) while a player is away.
func online_freeze(frozen: bool) -> void:
	get_tree().paused = frozen


## SERVER: a reconnected client now owns the fighter in this slot.
func online_rebind(slot: int, peer_id: int) -> void:
	if slot >= 0 and slot < _players.size():
		_players[slot].owning_peer_id = peer_id


## SERVER: run the shared round flow (same code as local play).
func online_start_flow() -> void:
	_match_start_ms = Time.get_ticks_msec()
	_intro_shown = false
	_hud.configure_rules(rounds_to_win, NetworkManager.server_round_seconds)
	_start_round()


## SERVER: a player dropped. The remaining fighter takes the match.
func online_player_left(slot: int) -> void:
	if _match_over:
		_hud.show_announcement("OPPONENT LEFT", Color(1.0, 0.5, 0.3), 70)
		return
	_round_over = true
	_lock_players()
	_hud.stop_round()
	_hud.show_announcement("OPPONENT LEFT", Color(1.0, 0.5, 0.3), 70)
	await _sleep(1.5)
	if slot >= 0 and slot < 2:
		_wins[1 - slot] = rounds_to_win
		_conclude_match(1 - slot)


## SERVER: both players asked for a rematch.
func online_rematch() -> void:
	_wins = [0, 0]
	_round = 1
	_match_over = false
	_round_over = false
	_stats = {"damage": [0, 0], "combo": [0, 0], "supers": [0, 0]}
	_intro_shown = true
	_match_start_ms = Time.get_ticks_msec()
	NetworkManager.room_event("rematch", {})
	_start_round()


## CLIENT: the server announced the match (stage, fighters, rules).
## CLIENT: the link dropped mid-match. The server holds our slot for RECONNECT_WINDOW_SEC; keep asking
## the API for a fresh ticket and try to get back in.
func _reconnect_loop() -> void:
	_reconnecting = true
	_resumed = false
	for c in _players_node.get_children():
		c.queue_free()                  # the server spawns fresh copies for the new connection
	var deadline := Time.get_ticks_msec() + int(RECONNECT_WINDOW_SEC * 1000.0)
	while not _leaving and Time.get_ticks_msec() < deadline:
		online_set_status("CONNECTION LOST - RECONNECTING %d" % ceili((deadline - Time.get_ticks_msec()) / 1000.0))
		var r: int = await NetworkManager.try_rejoin()
		if r == 0:
			_register_with_server()
			var waited := 0.0
			while waited < 6.0 and not _resumed and NetworkManager.is_connected_to_server():
				await get_tree().create_timer(0.2).timeout
				waited += 0.2
			if _resumed:
				_reconnecting = false
				return
			NetworkManager.disconnect_game()
		elif r == 2:
			break
		await get_tree().create_timer(1.5).timeout
	_reconnecting = false
	if _leaving:
		return
	online_set_status("CONNECTION LOST")
	await _sleep(2.0)
	online_leave()


## CLIENT: the server accepted our reconnect.
func online_client_resume(info: Dictionary) -> void:
	_peer_ids = info["peers"]
	_resumed = true
	print("@@BOT resumed")
	online_clear_status()
	_refresh_players()


func online_clear_status() -> void:
	if _status_layer:
		_status_layer.visible = false


func online_client_start(info: Dictionary) -> void:
	_client_in_match = true
	_client_match_over = false
	_peer_ids = info["peers"]
	if _bot:
		_bot.match_started()
	_stage_index = int(info["stage"])
	rounds_to_win = int(info["rounds"])
	_build_world(_stage_index)
	var chars: Array = info["chars"]
	var names: Array = info["names"]
	_hud.set_portraits(chars[0], chars[1])
	var f1 := FighterData.get_fighter(chars[0])
	var f2 := FighterData.get_fighter(chars[1])
	_hud.set_fighters(str(names[0]).to_upper(), f1["color"], str(names[1]).to_upper(), f2["color"])
	_hud.configure_rules(rounds_to_win, int(info["seconds"]))
	_hud.reset_round()
	if _status_layer:
		_status_layer.visible = false
	_refresh_players()


func online_client_rematch() -> void:
	_client_match_over = false
	if _bot:
		_bot.rematch_started()
	if _overlay:
		_overlay.hide_overlay()
	AudioManager.play_music("battle_%d" % posmod(_stage_index, 3))


func online_client_match_end(text: String, stats: Dictionary) -> void:
	_client_match_over = true
	AudioManager.stop_music(0.4)
	AudioManager.play_jingle("jingle_win", 6.0)
	if _bot:
		_bot.match_finished()
	_overlay.show_match_end(text, stats)


func _get_network_manager() -> Node:
	return get_node_or_null("/root/NetworkManager")
