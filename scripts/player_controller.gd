## player_controller.gd -- Fighting character controller.
## LOCAL MODE: both players on same machine, no networking.
## NETWORK MODE: server-authoritative RPC input.
extends CharacterBody2D

enum State { IDLE, MOVE, ATTACK, HIT, KO }

const MOVE_SPEED:      float = 320.0
const JUMP_VELOCITY:   float = -520.0
const GRAVITY:         float = 1000.0
const ATTACK_DURATION: float = 0.38
const HIT_DURATION:    float = 0.25
const ATTACK_DAMAGE:   int   = 10
const SPRITE_SCALE:    float = 2.2
const MAX_HP:          int   = 100

@export var player_index: int  = 0
@export var local_mode:   bool = true
@export var health:       int  = MAX_HP

var current_state:    int = State.IDLE
var facing_direction: int = 1

var owning_peer_id:  int   = 1
var _attack_timer:   float = 0.0
var _hit_timer:      float = 0.0
var _prev_health:    int   = MAX_HP
var _input_move_dir: float = 0.0
var _input_jump:     bool  = false
var _input_attack:   bool  = false
var _opponent: CharacterBody2D = null

@onready var _hitbox: Area2D = $Hitbox


func _ready() -> void:
	if not local_mode:
		owning_peer_id = name.to_int()
		set_multiplayer_authority(owning_peer_id)
		if has_node("MultiplayerSynchronizer"):
			$MultiplayerSynchronizer.set_multiplayer_authority(1)

	var sprite: AnimatedSprite2D = $AnimatedSprite2D
	if sprite and (sprite.sprite_frames == null or not sprite.sprite_frames.has_animation("idle")):
		_load_player_png_animations(sprite)

	if _hitbox:
		var should_monitor := local_mode or multiplayer.is_server()
		_hitbox.monitoring = should_monitor
		_set_hitbox_enabled(false)
		if should_monitor and not _hitbox.area_entered.is_connected(_on_hitbox_area_entered):
			_hitbox.area_entered.connect(_on_hitbox_area_entered)


func _physics_process(delta: float) -> void:
	if local_mode:
		_sample_local_input()
		_server_process(delta)
	else:
		if multiplayer.get_unique_id() == owning_peer_id:
			var is_p2   := (owning_peer_id != 1)
			var left_a  := "p2_left"   if is_p2 else "move_left"
			var right_a := "p2_right"  if is_p2 else "move_right"
			var jump_a  := "p2_jump"   if is_p2 else "jump"
			var atk_a   := "p2_attack" if is_p2 else "attack"
			var md := Input.get_axis(left_a, right_a)
			var jp := Input.is_action_just_pressed(jump_a)
			var at := Input.is_action_just_pressed(atk_a)
			if multiplayer.is_server():
				_input_move_dir = md
				_input_jump     = jp
				_input_attack   = at
			else:
				send_input.rpc_id(1, md, jp, at)
		if multiplayer.is_server():
			_server_process(delta)

	_update_visuals()


func _sample_local_input() -> void:
	if player_index == 0:
		_input_move_dir = Input.get_axis("move_left", "move_right")
		_input_jump     = Input.is_action_just_pressed("jump")
		_input_attack   = Input.is_action_just_pressed("attack")
	else:
		_input_move_dir = Input.get_axis("p2_left", "p2_right")
		_input_jump     = Input.is_action_just_pressed("p2_jump")
		_input_attack   = Input.is_action_just_pressed("p2_attack")


@rpc("any_peer", "call_local", "reliable")
func send_input(move_dir: float, jump: bool, attack: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != owning_peer_id and sender != 0:
		return
	_input_move_dir = move_dir
	_input_jump     = jump
	_input_attack   = attack


func _server_process(delta: float) -> void:
	if current_state == State.KO:
		move_and_slide()
		return
	if not is_on_floor():
		velocity.y += GRAVITY * delta
	match current_state:
		State.IDLE:   _state_idle()
		State.MOVE:   _state_move()
		State.ATTACK: _state_attack(delta)
		State.HIT:    _state_hit(delta)
	move_and_slide()
	if _input_move_dir != 0.0 and current_state != State.ATTACK:
		facing_direction = 1 if _input_move_dir > 0.0 else -1


func _state_idle() -> void:
	velocity.x = move_toward(velocity.x, 0.0, MOVE_SPEED * 2)
	if _input_attack:
		_enter_attack()
	elif _input_move_dir != 0.0:
		current_state = State.MOVE
	elif _input_jump and is_on_floor():
		velocity.y = JUMP_VELOCITY


func _state_move() -> void:
	velocity.x = _input_move_dir * MOVE_SPEED
	if _input_attack:
		_enter_attack()
	elif _input_move_dir == 0.0:
		current_state = State.IDLE
	elif _input_jump and is_on_floor():
		velocity.y = JUMP_VELOCITY


func _state_attack(delta: float) -> void:
	velocity.x = _input_move_dir * MOVE_SPEED * 0.25
	_attack_timer -= delta
	if _attack_timer <= 0.0:
		_set_hitbox_enabled(false)
		current_state = State.IDLE


func _state_hit(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, MOVE_SPEED)
	_hit_timer -= delta
	if _hit_timer <= 0.0:
		current_state = State.IDLE


func _enter_attack() -> void:
	current_state = State.ATTACK
	_attack_timer = ATTACK_DURATION
	_input_attack = false
	_set_hitbox_enabled(true)


func _set_hitbox_enabled(enabled: bool) -> void:
	if _hitbox:
		for child in _hitbox.get_children():
			if child is CollisionShape2D:
				child.disabled = not enabled


func _on_hitbox_area_entered(area: Area2D) -> void:
	if area.name != "Hurtbox":
		return
	var target := area.get_parent()
	if target == self:
		return
	if target.has_method("apply_damage"):
		target.apply_damage(ATTACK_DAMAGE)


func apply_damage(amount: int) -> void:
	if current_state == State.KO:
		return
	health -= amount
	if health <= 0:
		health = 0
		_on_ko()
	else:
		current_state = State.HIT
		_hit_timer    = HIT_DURATION
		var kb_dir := 1
		if _opponent:
			kb_dir = sign(global_position.x - _opponent.global_position.x)
		velocity = Vector2(kb_dir * 200.0, -150.0)


func _on_ko() -> void:
	current_state = State.KO
	set_physics_process(false)
	print("[Player %d] KO!" % player_index)
	await get_tree().create_timer(3.5).timeout
	var gm = get_tree().root.get_node_or_null("Game")
	if gm and gm.has_method("end_round"):
		gm.end_round(player_index)


func _update_visuals() -> void:
	var sprite: AnimatedSprite2D = $AnimatedSprite2D
	if not sprite:
		return
	sprite.flip_h = (facing_direction == -1)
	match current_state:
		State.KO:
			if sprite.animation != "ko":
				sprite.play("ko")
		State.HIT:
			if sprite.animation != "hit" or not sprite.is_playing():
				sprite.play("hit")
		State.ATTACK:
			if sprite.animation != "attack" or not sprite.is_playing():
				sprite.play("attack")
		State.MOVE:
			if sprite.animation != "run":
				sprite.play("run")
		_:
			if sprite.animation != "idle":
				sprite.play("idle")
	if health < _prev_health:
		modulate = Color(2.5, 1.8, 1.8)
	else:
		modulate = modulate.lerp(Color.WHITE, 0.12)
	_prev_health = health
	var hud = get_tree().root.get_node_or_null("Game/TekkenHUD")
	if hud and hud.has_method("update_health"):
		hud.update_health(player_index, health)


func reset_for_new_round(spawn_pos: Vector2) -> void:
	health        = MAX_HP
	current_state = State.IDLE
	_prev_health  = MAX_HP
	_attack_timer = 0.0
	_hit_timer    = 0.0
	velocity      = Vector2.ZERO
	position      = spawn_pos
	set_physics_process(true)
	var sprite: AnimatedSprite2D = $AnimatedSprite2D
	if sprite:
		sprite.play("idle")
	modulate = Color.WHITE


func _load_player_png_animations(sprite: AnimatedSprite2D) -> void:
	var path := "res://assets/player.png"
	var sheet := Image.load_from_file(path)
	if not sheet:
		push_warning("[PlayerController] Could not load %s" % path)
		return

	var frames := SpriteFrames.new()
	for anim in ["idle", "run", "attack", "hit", "ko"]:
		frames.add_animation(anim)

	frames.set_animation_speed("idle",    8.0)
	frames.set_animation_speed("run",    14.0)
	frames.set_animation_speed("attack", 18.0)
	frames.set_animation_speed("hit",    12.0)
	frames.set_animation_speed("ko",      8.0)

	frames.set_animation_loop("idle",   true)
	frames.set_animation_loop("run",    true)
	frames.set_animation_loop("attack", false)
	frames.set_animation_loop("hit",    false)
	frames.set_animation_loop("ko",     false)

	var is_p1 := (player_index == 0)

	var extract = func(rect: Rect2i, ox: int = 16) -> Texture2D:
		var sub := sheet.get_region(rect)
		if not is_p1:
			for y in range(sub.get_height()):
				for x in range(sub.get_width()):
					var c := sub.get_pixel(x, y)
					if c.a > 0.5 and c.r > 0.58 and c.g > 0.58 and c.b > 0.58 and abs(c.r - c.g) < 0.12 and abs(c.g - c.b) < 0.12:
						var lum := (c.r + c.g + c.b) / 3.0
						sub.set_pixel(x, y, Color(lum * 0.98, lum * 0.15, lum * 0.2, c.a))
		var canvas := Image.create(84, 100, false, Image.FORMAT_RGBA8)
		canvas.fill(Color(0, 0, 0, 0))
		var dy := 100 - sub.get_height()
		canvas.blit_rect(sub, Rect2i(0, 0, sub.get_width(), sub.get_height()), Vector2i(ox, dy))
		return ImageTexture.create_from_image(canvas)

	frames.add_frame("idle", extract.call(Rect2i(12,  6,  54, 88), 15))
	frames.add_frame("idle", extract.call(Rect2i(96,  6,  54, 88), 15))
	frames.add_frame("idle", extract.call(Rect2i(182, 6,  54, 88), 15))
	frames.add_frame("idle", extract.call(Rect2i(11,  97, 54, 90), 15))

	frames.add_frame("run", extract.call(Rect2i(261, 191, 57, 89), 14))
	frames.add_frame("run", extract.call(Rect2i(345, 191, 57, 89), 14))
	frames.add_frame("run", extract.call(Rect2i(431, 191, 53, 89), 14))
	frames.add_frame("run", extract.call(Rect2i(12,  191, 55, 89), 14))
	frames.add_frame("run", extract.call(Rect2i(105, 191, 42, 89), 14))
	frames.add_frame("run", extract.call(Rect2i(96,  6,   54, 88), 14))

	frames.add_frame("attack", extract.call(Rect2i(345, 6,   54, 88), 14))
	frames.add_frame("attack", extract.call(Rect2i(422, 6,   78, 88), 8))
	frames.add_frame("attack", extract.call(Rect2i(88,  97,  78, 90), 8))
	frames.add_frame("attack", extract.call(Rect2i(344, 97,  56, 90), 14))
	frames.add_frame("attack", extract.call(Rect2i(420, 97,  80, 90), 6))
	frames.add_frame("attack", extract.call(Rect2i(501, 97,  82, 90), 2))
	frames.add_frame("attack", extract.call(Rect2i(585, 97,  81, 90), 2))
	frames.add_frame("attack", extract.call(Rect2i(170, 191, 68, 89), 10))

	frames.add_frame("hit", extract.call(Rect2i(263, 97,  56, 90), 14))
	frames.add_frame("hit", extract.call(Rect2i(18,  282, 50, 90), 14))
	frames.add_frame("hit", extract.call(Rect2i(97,  282, 55, 90), 14))

	frames.add_frame("ko", extract.call(Rect2i(253, 282, 80,  90), 4))
	frames.add_frame("ko", extract.call(Rect2i(339, 282, 100, 90), 0))
	frames.add_frame("ko", extract.call(Rect2i(450, 282, 103, 90), 0))
	frames.add_frame("ko", extract.call(Rect2i(559, 282, 105, 90), 0))

	sprite.sprite_frames = frames
	sprite.play("idle")
	sprite.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.offset = Vector2(-42, -50)