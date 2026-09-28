extends CharacterBody2D

# Movement
@export var speed = 200.0
@export var health = 100
@export var player_id = 0
@export var player_name = "Player"

# Shooting
@export var fire_rate = 0.1
@export var bullet_speed = 500.0
var can_shoot = true
var last_shot_time = 0.0

# References
@onready var sprite = $Sprite2D
@onready var network = get_tree().root.get_child(0).network_manager

var input_vector = Vector2.ZERO
var mouse_pos = Vector2.ZERO
var dead = false

func _ready():
	# Make sure sprite exists
	if not sprite:
		var new_sprite = Sprite2D.new()
		new_sprite.name = "Sprite2D"
		add_child(new_sprite)
		sprite = new_sprite
	
	# Create a simple colored square for the player
	var image = Image.create(32, 32, false, Image.FORMAT_RGB8)
	for x in range(32):
		for y in range(32):
			image.set_pixel(x, y, Color.BLUE)
	var texture = ImageTexture.create_from_image(image)
	sprite.texture = texture
	
	# Set up collision shape
	if not has_node("CollisionShape2D"):
		var collision = CollisionShape2D.new()
		collision.shape = CircleShape2D.new()
		collision.shape.radius = 16
		add_child(collision)

func _physics_process(delta):
	if dead:
		return
	
	# Get input
	input_vector = Vector2.ZERO
	if Input.is_action_pressed("ui_up") or Input.is_action_pressed("w"):
		input_vector.y -= 1
	if Input.is_action_pressed("ui_down") or Input.is_action_pressed("s"):
		input_vector.y += 1
	if Input.is_action_pressed("ui_left") or Input.is_action_pressed("a"):
		input_vector.x -= 1
	if Input.is_action_pressed("ui_right") or Input.is_action_pressed("d"):
		input_vector.x += 1
	
	input_vector = input_vector.normalized()
	
	# Move player
	velocity = input_vector * speed
	move_and_slide()
	
	# Rotate to face mouse
	mouse_pos = get_global_mouse_position()
	var direction = (mouse_pos - global_position).normalized()
	rotation = direction.angle()
	
	# Shooting
	if Input.is_action_pressed("ui_accept") or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		shoot()
	
	# Send position to server
	if network:
		network.send_player_update(player_id, global_position, rotation)

func shoot():
	if not can_shoot or dead:
		return
	
	can_shoot = false
	
	# Visual feedback
	var flash = Sprite2D.new()
	flash.texture = sprite.texture
	flash.modulate = Color.YELLOW
	flash.global_position = global_position
	flash.scale = Vector2(0.5, 0.5)
	get_parent().add_child(flash)
	await get_tree().create_timer(0.1).timeout
	flash.queue_free()
	
	# Create bullet
	var direction = (mouse_pos - global_position).normalized()
	if network:
		network.send_shoot(player_id, global_position, direction)
	
	# Local bullet visual
	var bullet = Area2D.new()
	bullet.global_position = global_position + direction * 20
	
	var bullet_sprite = Sprite2D.new()
	var bullet_image = Image.create(8, 8, false, Image.FORMAT_RGB8)
	for x in range(8):
		for y in range(8):
			bullet_image.set_pixel(x, y, Color.YELLOW)
	bullet_sprite.texture = ImageTexture.create_from_image(bullet_image)
	bullet.add_child(bullet_sprite)
	
	var bullet_collision = CollisionShape2D.new()
	bullet_collision.shape = CircleShape2D.new()
	bullet_collision.shape.radius = 4
	bullet.add_child(bullet_collision)
	
	get_parent().add_child(bullet)
	
	# Move bullet
	for i in range(200):
		bullet.global_position += direction * bullet_speed * 0.016
		await get_tree().create_timer(0.016).timeout
	
	bullet.queue_free()
	
	# Cooldown
	await get_tree().create_timer(fire_rate).timeout
	can_shoot = true

func take_damage(amount):
	if dead:
		return
	
	health -= amount
	if health <= 0:
		die()

func die():
	dead = true
	modulate = Color.GRAY
	# Respawn after 5 seconds or wait for next game
	await get_tree().create_timer(5.0).timeout
	queue_free()

func update_position(new_pos: Vector2):
	"""Called when receiving position update from server"""
	global_position = new_pos

func update_rotation(new_rotation: float):
	"""Called when receiving rotation update from server"""
	rotation = new_rotation
