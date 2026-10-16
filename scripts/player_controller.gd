## player_controller.gd -- Fighting character controller.
## LOCAL MODE: both players on same machine (or P2 driven by a simple CPU), no networking.
## NETWORK MODE: server-authoritative RPC input.
extends CharacterBody2D

const FighterData := preload("res://scripts/fighter_data.gd")
const FxSprite    := preload("res://scripts/fx_sprite.gd")

enum State { IDLE, MOVE, ATTACK, HIT, KO, BLOCK, HEAVY, SUPER }

const MOVE_SPEED:    float = 320.0
const JUMP_VELOCITY: float = -700.0
const GRAVITY:       float = 1700.0
const SPRITE_SCALE:  float = 1.6
const MAX_HP:        int   = 100
const BODY_SIZE:     Vector2 = Vector2(36, 120)
const FLOOR_Y:       float = 130.0
const ARENA_HALF_W:  float = 1000.0
const BLOCK_CHIP:    float = 0.15
const METER_MAX:     int   = 100
const SUPER_RANGE:   float = 170.0

## Heavy attack: long wind-up, big knockback. Same keys as COMBO plus "lunge_from" (when the lunge starts).
const HEAVY_MOVE: Dictionary = {"dur": 0.74, "active": [0.5, 0.8], "dmg": 22, "kb": Vector2(640.0, -380.0), "stun": 0.6,
	"lunge": 300.0, "lunge_from": 0.42, "hitstop": 0.16, "heavy": true}

## Three-hit combo. "active" is the fraction of the swing during which the hitbox is live.
const COMBO: Array[Dictionary] = [
	{"dur": 0.34, "active": [0.35, 0.70], "dmg": 8,  "kb": Vector2(220.0, -80.0),  "stun": 0.28, "lunge": 140.0, "hitstop": 0.05},
	{"dur": 0.34, "active": [0.35, 0.70], "dmg": 9,  "kb": Vector2(240.0, -90.0),  "stun": 0.30, "lunge": 160.0, "hitstop": 0.06},
	{"dur": 0.52, "active": [0.42, 0.72], "dmg": 15, "kb": Vector2(520.0, -360.0), "stun": 0.55, "lunge": 260.0, "hitstop": 0.12},
]

@export var player_index: int    = 0
@export var local_mode:   bool   = true
@export var health:       int    = MAX_HP
@export var char_id:      String = ""
@export var is_cpu:       bool   = false
@export var tint:         Color  = Color.WHITE
@export var meter:        int    = 0

var current_state:    int = State.IDLE
var facing_direction: int = 1

var input_locked:    bool  = false
var owning_peer_id:  int   = 1
var _fighter:        Dictionary = {}
var _attack_timer:   float = 0.0
var _attack_dur:     float = 0.0
var _combo_step:     int   = 0
var _combo_buffered: bool  = false
var _already_hit:    Array = []
var _hit_timer:      float = 0.0
var _hitstop:        float = 0.0
var _prev_health:    int   = MAX_HP
var _input_move_dir: float = 0.0
var _input_jump:     bool  = false
var _input_attack:   bool  = false
var _input_block:    bool  = false
var _input_heavy:    bool  = false
var _input_special:  bool  = false
var _cur_move:       Dictionary = {}
var _swing_fx_done:  bool  = false
var _super:          Dictionary = {}
var _super_phase:    int   = 0
var _super_t:        float = 0.0
var _super_hit_idx:  int   = 0
var _super_tp_idx:   int   = 0
var _super_landed:   bool  = false
var _super_end_started: bool = false
var _ko_by_super:    bool  = false
var _aura: Node = null
var _air_time: float = 0.0
var _combo_hits: int = 0
var _opponent = null  # the other fighter (untyped so we can read its state)

var _ai_mode:  String = "idle"
var _ai_timer: float  = 0.0
var _ai_atk_cd: float = 0.0

@onready var _hitbox:  Area2D = $Hitbox
@onready var _sprite:  AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	if not local_mode:
		owning_peer_id = name.to_int()
		set_multiplayer_authority(owning_peer_id)
		if has_node("MultiplayerSynchronizer"):
			$MultiplayerSynchronizer.set_multiplayer_authority(1)

	if char_id.is_empty():
		char_id = FighterData.ROSTER[player_index % FighterData.ROSTER.size()]["id"]
	_fighter = FighterData.get_fighter(char_id)

	# Fighters never collide with each other (the game manager nudges them apart),
	# so nobody can stand on an opponent's head. They only collide with the floor.
	collision_layer = 4
	collision_mask  = 1
	_setup_body()
	_sprite.sprite_frames   = FighterData.build_frames(char_id)
	_sprite.scale           = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	_sprite.position        = Vector2(0.0, BODY_SIZE.y * 0.5 - (FighterData.FRAME_SIZE - 0.5 - 64.0) * SPRITE_SCALE)
	_sprite.texture_filter  = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.self_modulate   = tint
	_sprite.play("idle")

	_hitbox.monitoring = local_mode or multiplayer.is_server()
	_set_hitbox_enabled(false)


## Per-instance collision shapes so size tweaks never leak between fighters.
func _setup_body() -> void:
	var body := RectangleShape2D.new()
	body.size = BODY_SIZE
	$CollisionShape2D.shape = body

	var hurt := RectangleShape2D.new()
	hurt.size = Vector2(BODY_SIZE.x + 8.0, BODY_SIZE.y - 6.0)
	$Hurtbox/CollisionShape2D.shape = hurt

	var reach: float = _fighter["reach"]
	var hit := RectangleShape2D.new()
	hit.size = Vector2(reach, 80.0)
	$Hitbox/CollisionShape2D.shape = hit
	$Hitbox/CollisionShape2D.position = Vector2(BODY_SIZE.x * 0.5 + reach * 0.5, -8.0)


func _physics_process(delta: float) -> void:
	if local_mode:
		if is_cpu:
			_sample_cpu_input(delta)
		else:
			_sample_local_input()
		_server_process(delta)
	else:
		if multiplayer.get_unique_id() == owning_peer_id:
			var is_p2   := (owning_peer_id != 1)
			var left_a  := "p2_left"   if is_p2 else "move_left"
			var right_a := "p2_right"  if is_p2 else "move_right"
			var jump_a  := "p2_jump"   if is_p2 else "jump"
			var atk_a   := "p2_attack" if is_p2 else "attack"
			var blk_a   := "p2_block"  if is_p2 else "block"
			var md := Input.get_axis(left_a, right_a)
			var jp := Input.is_action_just_pressed(jump_a)
			var at := Input.is_action_just_pressed(atk_a)
			var bl := Input.is_action_pressed(blk_a)
			var hv := Input.is_action_just_pressed("p2_heavy" if is_p2 else "heavy")
			var sp := Input.is_action_just_pressed("p2_special" if is_p2 else "special")
			if multiplayer.is_server():
				_input_move_dir = md
				_input_jump     = jp
				_input_attack   = at
				_input_block    = bl
				_input_heavy    = hv
				_input_special  = sp
			else:
				send_input.rpc_id(1, md, jp, at, bl, hv, sp)
		if multiplayer.is_server():
			_server_process(delta)

	_update_visuals()
	queue_redraw()


func _draw() -> void:
	# Soft ground shadow that stays on the floor while jumping.
	var height := maxf(0.0, FLOOR_Y - global_position.y - BODY_SIZE.y * 0.5)
	var squash := clampf(1.0 - height / 400.0, 0.4, 1.0)
	var pts := PackedVector2Array()
	for i in range(24):
		var a := TAU * i / 24.0
		pts.append(Vector2(cos(a) * 46.0 * squash, FLOOR_Y - global_position.y + sin(a) * 9.0 * squash))
	draw_colored_polygon(pts, Color(0, 0, 0, 0.35 * squash))


func _sample_local_input() -> void:
	if input_locked:
		_input_move_dir = 0.0
		_input_jump     = false
		_input_attack   = false
		_input_block    = false
		_input_heavy    = false
		_input_special  = false
		return
	if player_index == 0:
		_input_move_dir = Input.get_axis("move_left", "move_right")
		_input_jump     = Input.is_action_just_pressed("jump")
		_input_attack   = Input.is_action_just_pressed("attack")
		_input_block    = Input.is_action_pressed("block")
		_input_heavy    = Input.is_action_just_pressed("heavy")
		_input_special  = Input.is_action_just_pressed("special")
	else:
		_input_move_dir = Input.get_axis("p2_left", "p2_right")
		_input_jump     = Input.is_action_just_pressed("p2_jump")
		_input_attack   = Input.is_action_just_pressed("p2_attack")
		_input_block    = Input.is_action_pressed("p2_block")
		_input_heavy    = Input.is_action_just_pressed("p2_heavy")
		_input_special  = Input.is_action_just_pressed("p2_special")


## Very small CPU brain: closes distance, pokes in combos, blocks when the player swings.
func _sample_cpu_input(delta: float) -> void:
	_input_move_dir = 0.0
	_input_jump     = false
	_input_attack   = false
	_input_block    = false
	_input_heavy    = false
	_input_special  = false
	if input_locked or _opponent == null or _opponent.current_state == State.KO:
		return

	var dx: float = _opponent.global_position.x - global_position.x
	var dist := absf(dx)
	var dir := signf(dx)
	var range_px: float = BODY_SIZE.x + float(_fighter["reach"]) - 10.0

	_ai_timer  -= delta
	_ai_atk_cd -= delta
	var opp_swinging: bool = _opponent.current_state == State.ATTACK and dist < range_px + 60.0
	if _ai_timer <= 0.0 or (opp_swinging and _ai_mode != "block" and randf() < 0.04):
		_ai_decide(dist, range_px, opp_swinging)

	match _ai_mode:
		"approach":
			_input_move_dir = dir
			if dist < range_px * 0.9:
				_ai_timer = 0.0
		"retreat":
			_input_move_dir = -dir
		"block":
			_input_block = true
		"jump":
			_input_move_dir = dir
			_input_jump = is_on_floor()
		"attack":
			if dist > range_px:
				_input_move_dir = dir
			elif _ai_atk_cd <= 0.0:
				var roll := randf()
				if meter >= METER_MAX and roll < 0.6:
					_input_special = true
				elif roll < 0.2:
					_input_heavy = true
				else:
					_input_attack = true
				_ai_atk_cd = randf_range(0.28, 0.5)


func _ai_decide(dist: float, range_px: float, opp_swinging: bool) -> void:
	var r := randf()
	if opp_swinging and r < 0.6:
		_ai_mode  = "block"
		_ai_timer = randf_range(0.35, 0.6)
	elif dist <= range_px + 20.0:
		if r < 0.6:
			_ai_mode  = "attack"
			_ai_timer = randf_range(0.6, 1.1)
		elif r < 0.8:
			_ai_mode  = "retreat"
			_ai_timer = randf_range(0.25, 0.5)
		else:
			_ai_mode  = "idle"
			_ai_timer = randf_range(0.15, 0.35)
	else:
		if r < 0.1:
			_ai_mode  = "jump"
			_ai_timer = 0.6
		elif r < 0.9:
			_ai_mode  = "approach"
			_ai_timer = randf_range(0.4, 0.9)
		else:
			_ai_mode  = "idle"
			_ai_timer = randf_range(0.1, 0.3)


@rpc("any_peer", "call_local", "reliable")
func send_input(move_dir: float, jump: bool, attack: bool, block: bool = false, heavy: bool = false, special: bool = false) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != owning_peer_id and sender != 0:
		return
	_input_move_dir = move_dir
	_input_jump     = jump
	_input_attack   = attack
	_input_block    = block
	_input_heavy    = heavy
	_input_special  = special


func _server_process(delta: float) -> void:
	if _hitstop > 0.0:
		_hitstop -= delta
		return

	if not is_on_floor():
		velocity.y += GRAVITY * delta

	match current_state:
		State.IDLE:   _state_idle(delta)
		State.MOVE:   _state_move(delta)
		State.ATTACK, State.HEAVY: _state_attack(delta)
		State.SUPER:  _state_super(delta)
		State.HIT:    _state_hit(delta)
		State.BLOCK:  _state_block(delta)
		State.KO:     _state_ko(delta)
	move_and_slide()
	position.x = clampf(position.x, -ARENA_HALF_W, ARENA_HALF_W)

	if current_state in [State.IDLE, State.MOVE, State.BLOCK]:
		_face_opponent()


func _face_opponent() -> void:
	if _opponent and is_on_floor() and absf(_opponent.global_position.x - global_position.x) > 6.0:
		facing_direction = 1 if _opponent.global_position.x > global_position.x else -1
	elif _opponent == null and _input_move_dir != 0.0:
		facing_direction = 1 if _input_move_dir > 0.0 else -1


func _ground_move(delta: float, target_x: float) -> void:
	var accel := MOVE_SPEED * (14.0 if is_on_floor() else 4.0)
	velocity.x = move_toward(velocity.x, target_x, accel * delta)


func _try_start_actions() -> bool:
	if _input_special and meter >= METER_MAX:
		_enter_super()
		return true
	if _input_heavy:
		_enter_heavy()
		return true
	if _input_attack:
		_enter_attack(0)
		return true
	if _input_block and is_on_floor():
		current_state = State.BLOCK
		return true
	if _input_jump and is_on_floor():
		velocity.y = _fighter["jump"]
		AudioManager.play("jump", -8.0)
	return false


func _state_idle(delta: float) -> void:
	_ground_move(delta, 0.0)
	if _try_start_actions():
		return
	if _input_move_dir != 0.0:
		current_state = State.MOVE


func _state_move(delta: float) -> void:
	_ground_move(delta, _input_move_dir * float(_fighter["speed"]))
	if _try_start_actions():
		return
	if _input_move_dir == 0.0:
		current_state = State.IDLE


func _state_block(delta: float) -> void:
	_ground_move(delta, 0.0)
	if not _input_block or not is_on_floor():
		current_state = State.IDLE


func _state_attack(delta: float) -> void:
	var step: Dictionary = _cur_move
	var is_heavy: bool = current_state == State.HEAVY
	_attack_timer -= delta
	var progress := 1.0 - _attack_timer / _attack_dur
	var act: Array = step["active"]
	var lunge_from: float = step.get("lunge_from", 0.0)

	# Heavy: plant and charge first, lunge just before the strike. Light: lunge during wind-up.
	if progress < lunge_from:
		velocity.x = move_toward(velocity.x, 0.0, 2000.0 * delta)
	elif progress < act[0]:
		velocity.x = facing_direction * float(step["lunge"])
	else:
		velocity.x = move_toward(velocity.x, 0.0, 1400.0 * delta)

	if not is_heavy and _input_attack and _combo_step < COMBO.size() - 1:
		_combo_buffered = true

	_set_hitbox_enabled(progress >= act[0] and progress <= act[1])
	_resolve_hits(step)

	if not _swing_fx_done and progress >= act[0]:
		_swing_fx_done = true
		var big := is_heavy or _combo_step == COMBO.size() - 1
		AudioManager.play("swing_heavy" if big else "swing_light", -4.0)
		_notify_scene("spawn_fx", ["slash_heavy" if big else "slash_light", global_position + Vector2(facing_direction * 62.0, -14.0), facing_direction, Color.WHITE, 1.0])
		if is_heavy:
			_notify_scene("spawn_fx", ["shockwave", global_position + Vector2(facing_direction * 40.0, 50.0), facing_direction, Color(1, 0.85, 0.6), 0.9])
			_notify_scene("shake", [8.0])

	if not is_heavy and _combo_buffered and progress >= act[1]:
		_enter_attack(_combo_step + 1)
	elif _attack_timer <= 0.0:
		_set_hitbox_enabled(false)
		current_state = State.IDLE


func _state_hit(delta: float) -> void:
	if is_on_floor():
		velocity.x = move_toward(velocity.x, 0.0, 1100.0 * delta)
	_hit_timer -= delta
	if _hit_timer <= 0.0 and is_on_floor():
		current_state = State.IDLE


func _state_ko(delta: float) -> void:
	if is_on_floor():
		velocity.x = move_toward(velocity.x, 0.0, 1400.0 * delta)


func _enter_attack(step_index: int) -> void:
	_combo_step     = step_index
	_combo_buffered = false
	current_state   = State.ATTACK
	_cur_move       = COMBO[step_index]
	_swing_fx_done  = false
	_attack_dur     = float(COMBO[step_index]["dur"]) * float(_fighter["atk_speed"])
	_attack_timer   = _attack_dur
	_input_attack   = false
	_already_hit.clear()
	_set_hitbox_enabled(false)

	var anim := "attack_%d" % (step_index + 1)
	var frame_count := _sprite.sprite_frames.get_frame_count(anim)
	_sprite.sprite_frames.set_animation_speed(anim, frame_count / _attack_dur)
	_sprite.play(anim)


func _enter_heavy() -> void:
	_combo_buffered = false
	current_state   = State.HEAVY
	_cur_move       = HEAVY_MOVE
	_swing_fx_done  = false
	_attack_dur     = float(HEAVY_MOVE["dur"]) * (1.0 + (float(_fighter["atk_speed"]) - 1.0) * 0.5)
	_attack_timer   = _attack_dur
	_input_heavy    = false
	_input_attack   = false
	_already_hit.clear()
	_set_hitbox_enabled(false)
	_sprite.sprite_frames.set_animation_speed("heavy", _sprite.sprite_frames.get_frame_count("heavy") / _attack_dur)
	_sprite.play("heavy")


# ── Super (finisher) ────────────────────────────────────────────────────────

func _enter_super() -> void:
	meter           = 0
	_super          = _fighter["super"]
	current_state   = State.SUPER
	_super_phase    = 0
	_super_t        = 0.0
	_super_hit_idx  = 0
	_super_tp_idx   = 0
	_super_landed   = false
	_super_end_started = false
	_input_special  = false
	_input_attack   = false
	velocity        = Vector2.ZERO
	_set_hitbox_enabled(false)
	_sprite.sprite_frames.set_animation_speed("super_windup", 6.0)
	_sprite.play("super_windup")
	var gm := get_tree().current_scene
	if gm and gm.has_method("super_cinematic"):
		gm.super_cinematic(self, _super["name"], _fighter["color"])
	else:
		begin_super_strike()


## Called by the game manager when the freeze-frame cinematic ends (or immediately without one).
func begin_super_strike() -> void:
	if current_state != State.SUPER:
		return
	_super_phase = 1
	_super_t = 0.0
	var strike_len: float = float(_super["dur"]) * 0.75
	_sprite.sprite_frames.set_animation_speed("super_strike", _sprite.sprite_frames.get_frame_count("super_strike") / strike_len)
	_sprite.play("super_strike")
	_notify_scene("spawn_fx", ["super_flash", global_position + Vector2(0.0, -10.0), facing_direction, Color.WHITE, 1.3])
	_notify_scene("shake", [10.0])


func _state_super(delta: float) -> void:
	if _super_phase == 0:
		velocity = Vector2.ZERO
		return
	_super_t += delta
	var dur: float = _super["dur"]

	var vx := 0.0
	for seg in _super["speed"]:
		if _super_t >= seg[0] and _super_t < seg[1]:
			vx = facing_direction * float(seg[2])
	velocity.x = vx if vx != 0.0 else move_toward(velocity.x, 0.0, 2500.0 * delta)

	var tps: Array = _super["tp"]
	while _super_tp_idx < tps.size() and _super_t >= tps[_super_tp_idx][0]:
		_super_teleport(int(tps[_super_tp_idx][1]))
		_super_tp_idx += 1

	var hits: Array = _super["hits"]
	while _super_hit_idx < hits.size() and _super_t >= hits[_super_hit_idx][0]:
		_super_hit(hits[_super_hit_idx])
		_super_hit_idx += 1

	if not _super_end_started and _super_t >= dur * 0.75:
		_super_end_started = true
		_sprite.sprite_frames.set_animation_speed("super_end", _sprite.sprite_frames.get_frame_count("super_end") / (dur * 0.25))
		_sprite.play("super_end")
	if _super_t >= dur:
		current_state = State.IDLE


func _super_teleport(side: int) -> void:
	if _opponent == null:
		return
	_notify_scene("spawn_fx", ["dust", global_position + Vector2(0.0, 40.0), 1, Color(0.7, 0.5, 1.0), 2.0])
	position = Vector2(clampf(_opponent.position.x + side * 72.0, -ARENA_HALF_W, ARENA_HALF_W), _opponent.position.y)
	facing_direction = -side
	velocity = Vector2.ZERO
	_notify_scene("spawn_fx", ["dust", global_position + Vector2(0.0, 40.0), 1, Color(0.7, 0.5, 1.0), 2.0])


func _super_hit(entry: Array) -> void:
	if _opponent == null:
		return
	var final: bool = entry[2]
	var dx: float = _opponent.global_position.x - global_position.x
	var dy: float = _opponent.global_position.y - global_position.y
	var in_front: bool = dx * facing_direction > -30.0
	var in_range: bool = absf(dx) < SUPER_RANGE + float(_fighter["reach"]) * 0.4 and absf(dy) < 150.0 and in_front
	if not in_range:
		return
	_super_landed = true
	var kb := Vector2(760.0, -460.0) if final else Vector2(40.0, -30.0)
	_opponent.receive_hit(self, int(entry[1]), kb, 0.75 if final else 0.45, 0.18 if final else 0.05, final, true)


func _set_hitbox_enabled(enabled: bool) -> void:
	# Mirror the hitbox to whichever side we face.
	var shape: CollisionShape2D = $Hitbox/CollisionShape2D
	shape.position.x = absf(shape.position.x) * facing_direction
	shape.set_deferred("disabled", not enabled)


func _resolve_hits(step: Dictionary) -> void:
	if $Hitbox/CollisionShape2D.disabled:
		return
	for area in _hitbox.get_overlapping_areas():
		if area.name != "Hurtbox":
			continue
		var target := area.get_parent()
		if target == self or target in _already_hit or not target.has_method("receive_hit"):
			continue
		_already_hit.append(target)
		var dmg := int(round(float(step["dmg"]) * float(_fighter["damage"])))
		target.receive_hit(self, dmg, step["kb"], float(step["stun"]), float(step["hitstop"]), current_state == State.HEAVY or _combo_step == COMBO.size() - 1)


## Called on the defender by the attacker's hitbox.
func receive_hit(attacker, damage: int, knockback: Vector2, stun: float, hitstop: float, heavy: bool, unblockable: bool = false) -> void:
	if current_state == State.KO or current_state == State.SUPER:
		return
	var toward_attacker := signf(attacker.global_position.x - global_position.x)
	if toward_attacker == 0.0:
		toward_attacker = -float(attacker.facing_direction)
	var push_dir := -toward_attacker
	var contact := global_position + Vector2(toward_attacker * 24.0, -10.0)

	var blocked := current_state == State.BLOCK and int(toward_attacker) == facing_direction and not unblockable
	if blocked:
		var chip := maxi(1, int(round(damage * BLOCK_CHIP)))
		health = maxi(1, health - chip)
		velocity.x = push_dir * knockback.x * 0.6
		_hitstop = hitstop * 0.6
		attacker._hitstop = hitstop * 0.6
		attacker.velocity.x = -push_dir * 120.0
		_sprite.play("block")
		attacker.add_meter(2)
		add_meter(4)
		AudioManager.play("block")
		_notify_scene("hit_effect", [contact, 0, facing_direction])
		return

	var chained: bool = current_state == State.HIT
	attacker._combo_hits = attacker._combo_hits + 1 if chained else 1
	if attacker._combo_hits >= 2:
		_notify_scene("show_combo", [attacker.player_index, attacker._combo_hits])
	health -= damage
	if attacker.current_state == State.SUPER:
		AudioManager.play("hit_super_final" if heavy else "hit_super")
	elif heavy:
		AudioManager.play("hit_heavy")
	else:
		AudioManager.play("hit_light")
	if attacker.current_state != State.SUPER:
		attacker.add_meter(int(round(damage * 1.6)))
	add_meter(int(round(damage * 0.8)))
	_hitstop = hitstop
	attacker._hitstop = hitstop
	_set_hitbox_enabled(false)
	modulate = Color(2.5, 1.8, 1.8)
	velocity = Vector2(push_dir * knockback.x, knockback.y)
	_notify_scene("hit_effect", [contact, 2 if heavy else 1, facing_direction])
	if heavy:
		_notify_scene("shake", [14.0])
	if attacker.current_state == State.SUPER:
		_notify_scene("spawn_fx", ["slash_heavy" if heavy else "slash_light", contact + Vector2(0.0, -10.0), int(-toward_attacker), Color(1.0, 0.9, 0.7), 1.2])

	if health <= 0:
		health = 0
		_ko_by_super = attacker.current_state == State.SUPER
		_on_ko()
	else:
		current_state = State.HIT
		_hit_timer    = stun
		_sprite.play("hit")


func _on_ko() -> void:
	current_state = State.KO
	if velocity.y > -250.0:
		velocity.y = -250.0
	_notify_scene("shake", [20.0])
	print("[Player %d] KO!" % player_index)
	_notify_scene("on_player_ko", [player_index, _ko_by_super])


func add_meter(amount: int) -> void:
	var before := meter
	meter = clampi(meter + amount, 0, METER_MAX)
	if before < METER_MAX and meter >= METER_MAX:
		AudioManager.play("super_ready")


func _notify_scene(method: String, args: Array) -> void:
	var gm := get_tree().current_scene
	if gm and gm.has_method(method):
		gm.callv(method, args)


func _update_visuals() -> void:
	_sprite.flip_h = (facing_direction == -1)
	_sprite.speed_scale = 0.0 if _hitstop > 0.0 else 1.0
	var airborne := not is_on_floor()

	match current_state:
		State.KO:
			if _sprite.animation != "ko":
				_sprite.play("ko")
		State.HIT:
			if _sprite.animation != "hit":
				_sprite.play("hit")
		State.ATTACK:
			if not _sprite.animation.begins_with("attack"):
				_sprite.play("attack_%d" % (_combo_step + 1))
		State.HEAVY:
			if _sprite.animation != "heavy":
				_sprite.play("heavy")
		State.SUPER:
			pass  # driven by _enter_super / begin_super_strike / _state_super
		State.BLOCK:
			if _sprite.animation != "block":
				_sprite.play("block")
		_:
			if airborne:
				_show_jump_frame()
			elif current_state == State.MOVE:
				if _sprite.animation != "run":
					_sprite.play("run")
			elif _sprite.animation != "idle":
				_sprite.play("idle")

	if health < _prev_health and current_state != State.KO and modulate == Color.WHITE:
		modulate = Color(2.5, 1.8, 1.8)
	modulate = modulate.lerp(Color.WHITE, 0.15)
	_prev_health = health
	var hud = get_tree().root.get_node_or_null("Game/TekkenHUD")
	if hud and hud.has_method("update_health"):
		hud.update_health(player_index, health)
		hud.update_meter(player_index, meter)
	_update_aura()

	# Landing thud after a real fall.
	if airborne:
		_air_time += get_physics_process_delta_time()
	else:
		if _air_time > 0.3 and current_state != State.KO:
			AudioManager.play("land", -10.0)
		_air_time = 0.0


## A flickering aura while the super meter is full.
func _update_aura() -> void:
	var ready_for_super := meter >= METER_MAX and current_state != State.KO
	if ready_for_super and _aura == null:
		_aura = FxSprite.spawn(self, "aura_flame", Vector2(0.0, -6.0), 1, _fighter["color"], 1.9)
		if _aura:
			_aura.show_behind_parent = true
			_aura.z_index = 0
	elif not ready_for_super and _aura != null:
		_aura.queue_free()
		_aura = null


## Scrub the jump sheet by vertical speed: take-off -> apex -> fall.
func _show_jump_frame() -> void:
	if _sprite.animation != "jump":
		_sprite.play("jump")
	_sprite.pause()
	var count := _sprite.sprite_frames.get_frame_count("jump")
	var t := clampf(remap(velocity.y, float(_fighter["jump"]), -float(_fighter["jump"]), 0.0, 1.0), 0.0, 1.0)
	_sprite.frame = clampi(int(t * (count - 1) + 0.5), 0, count - 1)


func reset_for_new_round(spawn_pos: Vector2) -> void:
	health          = MAX_HP
	current_state   = State.IDLE
	_prev_health    = MAX_HP
	_attack_timer   = 0.0
	_hit_timer      = 0.0
	_hitstop        = 0.0
	_combo_buffered = false
	meter           = 0
	_ko_by_super    = false
	_combo_hits     = 0
	_ai_mode        = "idle"
	_ai_timer       = 0.0
	velocity        = Vector2.ZERO
	position        = spawn_pos
	modulate        = Color.WHITE
	_set_hitbox_enabled(false)
	_sprite.speed_scale = 1.0
	_sprite.play("idle")
