## player_controller.gd -- Fighting character controller.
## LOCAL MODE: both players on same machine (or P2 driven by a simple CPU), no networking.
## NETWORK MODE: server-authoritative RPC input.
extends CharacterBody2D

const FighterData := preload("res://scripts/fighter_data.gd")
const FxSprite    := preload("res://scripts/fx_sprite.gd")

enum State { IDLE, MOVE, ATTACK, HIT, KO, BLOCK, HEAVY, SUPER, DASH }

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
const DASH_SPEED:    float = 780.0
const DASH_TIME:     float = 0.2
const DASH_COOLDOWN: float = 0.3
const BACKDASH_IFRAMES: float = 0.14   # backdashes dodge everything for this long
const SUPER_RANGE:   float = 170.0
const PARRY_WINDOW:  float = 0.14   # block right before impact = parry
const SUPER_STARTUP: float = 0.45    # telegraph before the lunge; the attacker can still be hit (and cancelled) here

## Throw: ATTACK + BLOCK together at close range. Unblockable, beats a turtling opponent.
const THROW_MOVE: Dictionary = {"dur": 0.42, "active": [9.0, 10.0], "dmg": 0, "kb": Vector2.ZERO, "stun": 0.0, "lunge": 0.0, "hitstop": 0.0}
const THROW_RANGE: float = 100.0
const THROW_DAMAGE: int = 14

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
@export var palette:      int    = 0
@export var is_dummy:    bool   = false   # training dummy
var dummy_mode: int = 0                   # 0 stand, 1 block, 2 fight back (CPU)

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
var _input_dash:     int   = 0       # -1 / +1 for one frame after a double-tap
var _tap_dir:        int   = 0
var _tap_ms:         int   = 0
var _dash_timer:     float = 0.0
var _dash_cd:        float = 0.0
var _dash_dir:       int   = 0
var _dash_back:      bool  = false
var _block_t:        float = 0.0     # time spent in the current block
var _wake_t:         float = 0.0     # invulnerable "wake-up" frames after a heavy knockdown
var _hit_stun_len:   float = 0.0
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
var _refl: AnimatedSprite2D
var _last_run_frame: int = -1
var _built_char: String = ""
var _built_pal: int = -1
var _built_tint: Color = Color.WHITE
var _prev_vis_state: int = -1


## Online fighters are named after their owner's peer id. Authority must be set while entering the
## tree (before _ready) or the MultiplayerSynchronizer cannot finish the spawn handshake.
func _enter_tree() -> void:
	if name.is_valid_int():
		owning_peer_id = name.to_int()
		set_multiplayer_authority(owning_peer_id)
		var sync := get_node_or_null("MultiplayerSynchronizer")
		if sync:
			sync.set_multiplayer_authority(1)


func _ready() -> void:

	# Fighters never collide with each other (the game manager nudges them apart),
	# so nobody can stand on an opponent's head. They only collide with the floor.
	collision_layer = 4
	collision_mask  = 1
	_sprite.scale           = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	_sprite.position        = Vector2(0.0, BODY_SIZE.y * 0.5 - (FighterData.FRAME_SIZE - 0.5 - 64.0) * SPRITE_SCALE)
	_sprite_base            = _sprite.position
	_sprite.texture_filter  = CanvasItem.TEXTURE_FILTER_NEAREST

	# Faint mirror image on the polished floor.
	_refl = AnimatedSprite2D.new()
	_refl.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_refl.scale = Vector2(SPRITE_SCALE, -SPRITE_SCALE)
	_refl.z_index = -1
	add_child(_refl)

	_apply_fighter()
	_sprite.play("idle")
	_refl.animation = "idle"

	_hitbox.monitoring = local_mode or multiplayer.is_server()
	_set_hitbox_enabled(false)


## (Re)builds everything that depends on char_id / palette / tint. Called again if the replicated
## values arrive after _ready on an online client.
func _apply_fighter() -> void:
	if char_id.is_empty():
		char_id = FighterData.ROSTER[player_index % FighterData.ROSTER.size()]["id"]
	_fighter = FighterData.get_fighter(char_id)
	_setup_body()
	_sprite.sprite_frames  = FighterData.build_frames(char_id)
	_sprite.self_modulate  = tint
	_sprite.material       = FighterData.palette_material(palette)
	_refl.sprite_frames    = _sprite.sprite_frames
	_refl.self_modulate    = Color(tint.r, tint.g, tint.b, 0.2)
	_refl.material         = _sprite.material
	_built_char = char_id
	_built_pal  = palette
	_built_tint = tint
	_sprite.play("idle")


## True on peers that run the combat simulation (local game or the dedicated server).
## ── Client-side prediction (the owning client only) ─────────────────────────────────────────────
## The owner moves its own fighter immediately from local input and reconciles with the server using
## input sequence numbers: the server echoes the last input it processed (_ack_seq) next to the
## position that resulted from it, so the client can measure and absorb the difference.
var _ack_seq: int = 0            # replicated: last input sequence the server has processed
var _last_seq: int = 0           # server: newest sequence received
var _seq: int = 0                # client: last sequence sent
var _pp: Vector2 = Vector2.ZERO  # predicted position
var _pv: Vector2 = Vector2.ZERO  # predicted velocity
var _pred_hist: Array = []       # [{"seq": int, "pos": Vector2}, ...]
var _pred_ack_seen: int = -1
var _pred_freeze_until: float = 0.0     # an action was pressed: let the server drive until it answers
var _pred_anim: String = ""             # animation shown instantly for an action the server has not confirmed yet
var _pred_anim_until: float = 0.0
var _vis_off: Vector2 = Vector2.ZERO    # how far the drawn sprite is from the replicated position
var _local_block_held: bool = false
var pred_stats: Dictionary = {"corr_sum": 0.0, "corr_max": 0.0, "n": 0, "off_sum": 0.0, "off_max": 0.0, "snaps": 0, "acks": 0, "miss": 0, "calls": 0, "inactive": 0}
var _sprite_base: Vector2 = Vector2.ZERO
var _smooth_off: Vector2 = Vector2.ZERO
var _last_net_pos: Vector2 = Vector2.ZERO


func _is_sim() -> bool:
	return local_mode or multiplayer.is_server()


## True while an animation we started instantly (before the server confirmed the action) is still the right one.
func _pred_covers(anim: String) -> bool:
	return _pred_anim == anim and Time.get_ticks_msec() / 1000.0 < _pred_anim_until + 0.5


func _is_owner_client() -> bool:
	return not local_mode and multiplayer.has_multiplayer_peer() and not multiplayer.is_server() \
			and multiplayer.get_unique_id() == owning_peer_id


## Prediction only runs while the server also lets this fighter walk or jump freely.
func _pred_active() -> bool:
	if Time.get_ticks_msec() / 1000.0 < _pred_freeze_until:
		return false
	return not input_locked and current_state in [State.IDLE, State.MOVE] and health > 0


func _predict(delta: float, move: float, jump: bool, attack: bool, block: bool, heavy: bool, special: bool, dash: int) -> void:
	_local_block_held = block
	var now_s := Time.get_ticks_msec() / 1000.0
	# Actions are driven by the server: show the swing at once, then stop predicting movement until it answers.
	if current_state in [State.IDLE, State.MOVE] and not input_locked:
		if attack or heavy or special or dash != 0:
			_pred_freeze_until = now_s + 0.45
			if attack and not block:
				_pred_anim = "attack_1"
				_pred_anim_until = now_s + 0.5
			elif heavy:
				_pred_anim = "heavy"
				_pred_anim_until = now_s + 0.5
	if not _pred_active():
		pred_stats["inactive"] += 1
		_pp = position
		_pv = velocity
		_pred_hist.clear()
		_pred_ack_seen = -1
		return
	# Same movement rules the server uses (see _ground_move / _state_move / jump in _try_start_actions).
	var rest_y := FLOOR_Y - BODY_SIZE.y * 0.5
	var grounded := _pp.y >= rest_y - 0.5
	var target := 0.0 if block else move * float(_fighter["speed"])
	var accel := MOVE_SPEED * (14.0 if grounded else 4.0)
	_pv.x = move_toward(_pv.x, target, accel * delta)
	if jump and grounded and not block:
		_pv.y = float(_fighter["jump"])
	if not grounded or _pv.y < 0.0:
		_pv.y += GRAVITY * delta
	_pp += _pv * delta
	if _pp.y >= rest_y:
		_pp.y = rest_y
		_pv.y = 0.0
	_pp.x = clampf(_pp.x, -ARENA_HALF_W, ARENA_HALF_W)
	_pred_hist.append({"seq": _seq, "pos": _pp})
	if _pred_hist.size() > 240:
		_pred_hist.pop_front()
	_reconcile()


## The server echoes which input produced the position it just replicated; absorb the difference.
func _reconcile() -> void:
	pred_stats["calls"] += 1
	if _ack_seq == _pred_ack_seen:
		return
	pred_stats["acks"] += 1
	_pred_ack_seen = _ack_seq
	var found := -1
	for i in range(_pred_hist.size()):
		if _pred_hist[i]["seq"] == _ack_seq:
			found = i
			break
	if found < 0:
		pred_stats["miss"] += 1
		_pp = position if absf(_pp.x - position.x) > 220.0 else _pp
		return
	var err: Vector2 = position - (_pred_hist[found]["pos"] as Vector2)
	pred_stats["n"] += 1
	pred_stats["corr_sum"] += err.length()
	pred_stats["corr_max"] = maxf(pred_stats["corr_max"], err.length())
	pred_stats["off_sum"] += (_pp - position).length()
	pred_stats["off_max"] = maxf(pred_stats["off_max"], (_pp - position).length())
	if err.length() < 0.5:
		return
	if err.length() > 240.0:               # something big happened (knockback, teleport): trust the server
		pred_stats["snaps"] += 1
		_pp = position
		_pv = velocity
		_pred_hist.clear()
		_pred_ack_seen = -1
		return
	# Small disagreements are mostly timing jitter between client and server ticks: ease them in so the
	# fighter never shakes. Big ones are real (a jump the server refused, a push): correct them quickly.
	var k := 0.3 if err.length() < 24.0 else (0.6 if err.length() < 80.0 else 1.0)
	var applied := err * k
	_pp += applied
	for i in range(found + 1, _pred_hist.size()):
		_pred_hist[i]["pos"] = (_pred_hist[i]["pos"] as Vector2) + applied
	_pred_hist[found]["pos"] = (_pred_hist[found]["pos"] as Vector2) + applied


## Visual "on the ground" test. Remote clients never run physics, so is_on_floor() is always false
## there; they use the replicated height instead.
func _grounded() -> bool:
	if _is_sim():
		return is_on_floor()
	return FLOOR_Y - global_position.y - BODY_SIZE.y * 0.5 < 4.0


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
		# Online: the owning client only sends its inputs; the server simulates everything.
		if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == owning_peer_id and not multiplayer.is_server():
			var dash := _detect_dash_dir("move_left", "move_right")
			var mv := Input.get_axis("move_left", "move_right")
			var jp := Input.is_action_just_pressed("jump")
			var at := Input.is_action_just_pressed("attack")
			var bl := Input.is_action_pressed("block")
			var hv := Input.is_action_just_pressed("heavy")
			var sp := Input.is_action_just_pressed("special")
			_seq += 1
			send_input.rpc_id(1, mv, jp, at, bl, hv, sp, dash, _seq)
			_predict(delta, mv, jp, at, bl, hv, sp, dash)
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
		pts.append(Vector2(cos(a) * 46.0 * squash + _vis_off.x, FLOOR_Y - global_position.y + sin(a) * 9.0 * squash))
	draw_colored_polygon(pts, Color(0, 0, 0, 0.35 * squash))


func _sample_local_input() -> void:
	_input_dash = 0
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
	if player_index == 0:
		_detect_dash("move_left", "move_right")
	else:
		_detect_dash("p2_left", "p2_right")


## Double-tap left/right = dash. Dashing away from the opponent is an invulnerable backdash.
func _detect_dash(left_a: String, right_a: String) -> void:
	_input_dash = _detect_dash_dir(left_a, right_a)


## Returns -1 / +1 on the frame a double-tap completes, otherwise 0.
func _detect_dash_dir(left_a: String, right_a: String) -> int:
	var dir := 0
	if Input.is_action_just_pressed(left_a):
		dir = -1
	elif Input.is_action_just_pressed(right_a):
		dir = 1
	if dir == 0:
		return 0
	var now := Time.get_ticks_msec()
	if dir == _tap_dir and now - _tap_ms < 260:
		_tap_dir = 0
		return dir
	_tap_dir = dir
	_tap_ms = now
	return 0


## Very small CPU brain: closes distance, pokes in combos, blocks when the player swings.
func _sample_cpu_input(delta: float) -> void:
	_input_move_dir = 0.0
	_input_jump     = false
	_input_attack   = false
	_input_block    = false
	_input_heavy    = false
	_input_special  = false
	_input_dash     = 0
	if is_dummy and dummy_mode == 0:
		return
	if is_dummy and dummy_mode == 1:
		_input_block = true
		return
	if input_locked or _opponent == null or _opponent.current_state == State.KO:
		return

	var dx: float = _opponent.global_position.x - global_position.x
	var dist := absf(dx)
	var dir := signf(dx)
	var range_px: float = BODY_SIZE.x + float(_fighter["reach"]) - 10.0

	var lvl: int = GameSettings.cpu_level
	_ai_timer  -= delta
	_ai_atk_cd -= delta
	var opp_swinging: bool = _opponent.current_state in [State.ATTACK, State.HEAVY, State.SUPER] and dist < range_px + 90.0
	if _ai_timer <= 0.0 or (opp_swinging and _ai_mode != "block" and randf() < 0.04):
		_ai_decide(dist, range_px, opp_swinging, lvl)

	match _ai_mode:
		"approach":
			_input_move_dir = dir
			if dist < range_px * 0.9:
				_ai_timer = 0.0
		"retreat":
			_input_move_dir = -dir
		"block":
			_input_block = true
		"dash_back":
			_input_dash = -facing_direction
			_ai_timer = 0.0
		"jump":
			_input_move_dir = dir
			_input_jump = is_on_floor()
		"attack":
			if dist > range_px:
				_input_move_dir = dir
			elif _ai_atk_cd <= 0.0:
				var roll := randf()
				if _opponent.current_state == State.BLOCK and dist < THROW_RANGE - 15.0 and roll < [0.2, 0.45, 0.7][lvl]:
					_input_block = true
					_input_attack = true
					_ai_atk_cd = 0.6
					return
				if meter >= METER_MAX and roll < [0.2, 0.6, 0.9][lvl]:
					_input_special = true
				elif roll < [0.08, 0.2, 0.3][lvl]:
					_input_heavy = true
				else:
					_input_attack = true
				_ai_atk_cd = randf_range(0.28, 0.5) * [1.7, 1.0, 0.7][lvl]


func _ai_decide(dist: float, range_px: float, opp_swinging: bool, lvl: int = 1) -> void:
	var r := randf()
	if opp_swinging and lvl >= 1 and r > 0.8 and _dash_cd <= 0.0:
		_ai_mode  = "dash_back"
		_ai_timer = 0.3
	elif opp_swinging and r < [0.25, 0.6, 0.9][lvl]:
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
func send_input(move_dir: float, jump: bool, attack: bool, block: bool = false, heavy: bool = false, special: bool = false, dash: int = 0, seq: int = 0) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != owning_peer_id and sender != 0:
		return
	_last_seq = maxi(_last_seq, seq)
	if input_locked:
		move_dir = 0.0
		jump = false
		attack = false
		block = false
		heavy = false
		special = false
		dash = 0
	# Button presses are one-frame pulses. Latch them (OR) until the server's next tick consumes them, so a
	# newer message arriving first can never wipe out an earlier press (e.g. attack + block together).
	_input_move_dir = clampf(move_dir, -1.0, 1.0)
	_input_jump     = _input_jump or jump
	_input_attack   = _input_attack or attack
	_input_block    = block
	_input_heavy    = _input_heavy or heavy
	_input_special  = _input_special or special
	if dash != 0:
		_input_dash = clampi(dash, -1, 1)


func _server_process(delta: float) -> void:
	if _hitstop > 0.0:
		_hitstop -= delta
		return
	_dash_cd -= delta
	_wake_t -= delta

	if not is_on_floor():
		velocity.y += GRAVITY * delta

	match current_state:
		State.IDLE:   _state_idle(delta)
		State.MOVE:   _state_move(delta)
		State.ATTACK, State.HEAVY: _state_attack(delta)
		State.SUPER:  _state_super(delta)
		State.DASH:   _state_dash(delta)
		State.HIT:    _state_hit(delta)
		State.BLOCK:  _state_block(delta)
		State.KO:     _state_ko(delta)
	move_and_slide()
	position.x = clampf(position.x, -ARENA_HALF_W, ARENA_HALF_W)

	if current_state in [State.IDLE, State.MOVE, State.BLOCK]:
		_face_opponent()
	if not local_mode:
		_ack_seq = _last_seq
		# Network inputs are pulses: consume them so a lagging frame never repeats an action.
		_input_attack = false
		_input_jump = false
		_input_heavy = false
		_input_special = false
		_input_dash = 0


func _face_opponent() -> void:
	if _opponent and is_on_floor() and absf(_opponent.global_position.x - global_position.x) > 6.0:
		facing_direction = 1 if _opponent.global_position.x > global_position.x else -1
	elif _opponent == null and _input_move_dir != 0.0:
		facing_direction = 1 if _input_move_dir > 0.0 else -1


func _ground_move(delta: float, target_x: float) -> void:
	var accel := MOVE_SPEED * (14.0 if is_on_floor() else 4.0)
	velocity.x = move_toward(velocity.x, target_x, accel * delta)


func _try_start_actions() -> bool:
	if _input_attack and _input_block and _try_throw():
		return true
	if _input_dash != 0 and is_on_floor() and _dash_cd <= 0.0:
		_enter_dash(_input_dash)
		return true
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
		_block_t = 0.0
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


func _enter_dash(dir: int) -> void:
	current_state = State.DASH
	_dash_dir     = dir
	_dash_back    = dir != facing_direction
	_dash_timer   = DASH_TIME
	_input_dash   = 0
	velocity.x    = dir * DASH_SPEED
	AudioManager.play("swing_light", -6.0, 0.1)
	_notify_scene("spawn_fx", ["dust", global_position + Vector2(-dir * 20.0, 52.0), -dir, Color(1, 1, 1, 0.8), 1.2])


func _state_dash(delta: float) -> void:
	_dash_timer -= delta
	velocity.x = _dash_dir * DASH_SPEED * clampf(_dash_timer / DASH_TIME * 1.3, 0.3, 1.0)
	if _dash_timer <= 0.0:
		_dash_cd = DASH_COOLDOWN
		velocity.x *= 0.2
		current_state = State.IDLE


## Returns true if a throw connected.
func _try_throw() -> bool:
	if _opponent == null or not is_on_floor():
		return false
	var dx: float = _opponent.global_position.x - global_position.x
	var dy: float = absf(_opponent.global_position.y - global_position.y)
	if absf(dx) > THROW_RANGE or dy > 40.0 or dx * facing_direction < -10.0:
		return false
	if _opponent.current_state in [State.KO, State.SUPER, State.HIT, State.DASH]:
		return false
	_input_attack = false
	_combo_step = 1                      # plays the attack_2 animation
	_cur_move = THROW_MOVE
	current_state = State.ATTACK
	_attack_dur = THROW_MOVE["dur"]
	_attack_timer = _attack_dur
	_swing_fx_done = true
	_already_hit.clear()
	_set_hitbox_enabled(false)
	_sprite.sprite_frames.set_animation_speed("attack_2", _sprite.sprite_frames.get_frame_count("attack_2") / _attack_dur)
	_sprite.play("attack_2")
	_opponent.receive_hit(self, THROW_DAMAGE, Vector2(380.0, -520.0), 0.7, 0.12, true, true)
	_notify_scene("spawn_fx", ["shockwave", _opponent.global_position + Vector2(0.0, 50.0), facing_direction, Color(1, 0.85, 0.6), 1.0])
	return true


func _state_block(delta: float) -> void:
	if _input_attack and _try_throw():
		return
	_ground_move(delta, 0.0)
	_block_t += delta
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
		if _hit_stun_len >= 0.5:
			_wake_t = 0.35
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
	_notify_scene("stat_super", [player_index])
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
	_sprite.sprite_frames.set_animation_speed("super_windup", float(_sprite.sprite_frames.get_frame_count("super_windup")) / SUPER_STARTUP)
	_sprite.play("super_windup")
	AudioManager.play("super_ready")
	_notify_scene("spawn_fx", ["aura_flame", global_position + Vector2(0.0, -6.0), 1, _fighter["color"], 2.2])
	_notify_scene("popup_text", [global_position + Vector2(0.0, -130.0), str(_super["name"]), Color(1.0, 0.85, 0.3), 34, 40.0, 0.9])


## Startup is over: the super lunges. It is a fully visible, dodgeable move - the cinematic only
## plays if the first hit actually connects (see _super_hit).
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
		velocity.x = move_toward(velocity.x, 0.0, 3000.0 * delta)
		_super_t += delta
		if _super_t >= SUPER_STARTUP:
			begin_super_strike()
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
		_super_phase = 2
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
	var kb := Vector2(760.0, -460.0) if final else Vector2(40.0, -30.0)
	var connected: bool = _opponent.receive_hit(self, int(entry[1]), kb, 0.75 if final else 0.45, 0.18 if final else 0.05, final, true)
	if connected and not _super_landed:
		_super_landed = true
		# First connect: freeze-frame cinematic (the defender had every chance to dodge before this).
		_notify_scene("super_cinematic", [self, _super["name"], _fighter["color"]])


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
func receive_hit(attacker, damage: int, knockback: Vector2, stun: float, hitstop: float, heavy: bool, unblockable: bool = false) -> bool:
	## Returns true if the hit connected (false = ignored or dodged).
	if current_state == State.KO or (current_state == State.SUPER and _super_phase >= 1) or _wake_t > 0.0:
		return false
	if current_state == State.DASH and _dash_back and _dash_timer > DASH_TIME - BACKDASH_IFRAMES:
		return false  # dodged
	var toward_attacker := signf(attacker.global_position.x - global_position.x)
	if toward_attacker == 0.0:
		toward_attacker = -float(attacker.facing_direction)
	var push_dir := -toward_attacker
	var contact := global_position + Vector2(toward_attacker * 24.0, -10.0)

	var blocked := current_state == State.BLOCK and int(toward_attacker) == facing_direction and not unblockable
	if blocked and _block_t < PARRY_WINDOW:
		# Perfectly timed block: no damage, the attacker is staggered and punishable.
		attacker._hitstop = 0.2
		attacker.velocity.x = -push_dir * 260.0 * -1.0
		attacker._set_hitbox_enabled(false)
		attacker.current_state = State.HIT
		attacker._hit_timer = 0.4
		attacker._hit_stun_len = 0.0
		attacker._sprite.play("hit")
		_hitstop = 0.12
		add_meter(12)
		AudioManager.play("block")
		AudioManager.play("ui_confirm", -4.0)
		_notify_scene("hit_effect", [contact, 0, facing_direction])
		_notify_scene("popup_text", [global_position + Vector2(0.0, -110.0), "PARRY!", Color(0.5, 0.95, 1.0), 34, 60.0, 0.9])
		return true
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
		return true

	var chained: bool = current_state == State.HIT
	# Counter hit: catching an opponent during their attack startup does +25%.
	var counter := false
	if not chained and attacker.current_state != State.SUPER and current_state in [State.ATTACK, State.HEAVY] and _attack_dur > 0.0:
		var prog := 1.0 - _attack_timer / _attack_dur
		counter = prog < float(_cur_move["active"][0])
	if counter:
		damage = int(round(damage * 1.25))
		_notify_scene("popup_text", [global_position + Vector2(0.0, -120.0), "COUNTER!", Color(1.0, 0.55, 0.2), 32, 60.0, 0.9])
	attacker._combo_hits = attacker._combo_hits + 1 if chained else 1
	if attacker._combo_hits >= 2:
		_notify_scene("show_combo", [attacker.player_index, attacker._combo_hits])
		if attacker.current_state != State.SUPER:
			# Combo damage scaling: every extra hit does 10% less (down to 50%).
			damage = maxi(1, int(round(damage * maxf(0.5, 1.0 - 0.1 * (attacker._combo_hits - 1)))))
	_hit_stun_len = stun
	health -= damage
	_notify_scene("popup_text", [contact + Vector2(randf_range(-14.0, 14.0), -30.0), str(damage), Color(1.0, 0.95, 0.6) if heavy else Color.WHITE, 40 if heavy else 28, 60.0, 0.7])
	_notify_scene("stat_hit", [attacker.player_index, damage, attacker._combo_hits])
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
	return true


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
	# Remote clients receive position in discrete network steps; absorb each step into a visual offset
	# that eases back to zero so motion looks continuous instead of stepping.
	if not _is_sim():
		if _is_owner_client():
			_vis_off = (_pp - position) if _pred_active() else Vector2.ZERO
			if _vis_off.length() > 400.0:
				_vis_off = Vector2.ZERO
			_sprite.position = _sprite_base + _vis_off
		else:
			var step := position - _last_net_pos
			_last_net_pos = position
			if step.length() > 300.0:
				_smooth_off = Vector2.ZERO
			else:
				_smooth_off -= step
			_smooth_off = _smooth_off.lerp(Vector2.ZERO, 1.0 - exp(-get_process_delta_time() * 14.0))
			_vis_off = _smooth_off
			_sprite.position = _sprite_base + _smooth_off
	if char_id != _built_char or palette != _built_pal or tint != _built_tint:
		_apply_fighter()
	var entered_state := current_state != _prev_vis_state
	_prev_vis_state = current_state
	_sprite.flip_h = (facing_direction == -1)
	# Footsteps on the run cycle's contact frames.
	if _sprite.animation == "run" and current_state == State.MOVE and _grounded():
		var f := _sprite.frame
		if f != _last_run_frame and (f == 1 or f == 5):
			AudioManager.play("step", -14.0, 0.12, true)
		_last_run_frame = f
	else:
		_last_run_frame = -1
	if _refl:
		_refl.animation = _sprite.animation
		_refl.frame = _sprite.frame
		_refl.flip_h = _sprite.flip_h
		_refl.position = Vector2(_sprite.position.x, 2.0 * (FLOOR_Y - global_position.y) - _sprite.position.y)
		_refl.visible = current_state != State.KO or true
	_sprite.speed_scale = 0.0 if _hitstop > 0.0 else 1.0
	var airborne := not _grounded()

	match current_state:
		State.KO:
			if _sprite.animation != "ko":
				_sprite.play("ko")
		State.HIT:
			if _sprite.animation != "hit":
				_sprite.play("hit")
		State.ATTACK:
			var want := "attack_%d" % (_combo_step + 1)
			if _is_sim():
				if not _sprite.animation.begins_with("attack"):
					_sprite.play(want)
			elif _sprite.animation != want or entered_state:
				_sprite.sprite_frames.set_animation_speed(want, float(_sprite.sprite_frames.get_frame_count(want)) / maxf(_attack_dur, 0.1))
				if _sprite.animation != want or not _pred_covers(want):
					_sprite.play(want)
		State.HEAVY:
			if _sprite.animation != "heavy" or (entered_state and not _is_sim()):
				if not _is_sim():
					_sprite.sprite_frames.set_animation_speed("heavy", float(_sprite.sprite_frames.get_frame_count("heavy")) / maxf(_attack_dur, 0.1))
				if _sprite.animation != "heavy" or not _pred_covers("heavy"):
					_sprite.play("heavy")
		State.DASH:
			if _sprite.animation != "run":
				_sprite.play("run")
		State.SUPER:
			if not _is_sim():
				var want_super := "super_windup" if _super_phase == 0 else ("super_strike" if _super_phase == 1 else "super_end")
				if _sprite.animation != want_super:
					_sprite.play(want_super)
			# On the simulating peer this is driven by _enter_super / begin_super_strike / _state_super
		State.BLOCK:
			if _sprite.animation != "block":
				_sprite.play("block")
		_:
			var now_s := Time.get_ticks_msec() / 1000.0
			if _is_owner_client() and _pred_anim != "" and now_s < _pred_anim_until and not airborne:
				if _sprite.animation != _pred_anim:
					_sprite.play(_pred_anim)
			elif _is_owner_client() and _local_block_held and not airborne:
				if _sprite.animation != "block":
					_sprite.play("block")
			elif airborne:
				_show_jump_frame()
			elif current_state == State.MOVE:
				if _sprite.animation != "run":
					_sprite.play("run")
			elif _sprite.animation != "idle":
				_sprite.play("idle")

	if health < _prev_health and current_state != State.KO and modulate == Color.WHITE:
		modulate = Color(2.5, 1.8, 1.8)
	modulate = modulate.lerp(Color.WHITE, 0.15)
	modulate.a = 0.45 if (_wake_t > 0.0 and int(Time.get_ticks_msec() / 60) % 2 == 0) else 1.0
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
			AudioManager.play("land", -10.0, 0.05, true)
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
	_dash_cd        = 0.0
	_wake_t         = 0.0
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
