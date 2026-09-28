extends Node

# References
@onready var network_manager = $NetworkManager
var players_container: Node2D
var hud_label: Label
var safe_zone_circle: Circle2D

var local_player = null
var map_size = Vector2(2000, 2000)

func _ready():
	# Create container for players
	players_container = Node2D.new()
	players_container.name = "PlayersContainer"
	add_child(players_container)
	
	# Create HUD
	var hud_canvas = CanvasLayer.new()
	add_child(hud_canvas)
	
	hud_label = Label.new()
	hud_label.text = "Waiting for players..."
	hud_label.anchor_left = 0.0
	hud_label.anchor_top = 0.0
	hud_label.offset_left = 10
	hud_label.offset_top = 10
	hud_canvas.add_child(hud_label)
	
	# Create safe zone visualization
	safe_zone_circle = Circle2D.new()
	safe_zone_circle.radius = 300
	safe_zone_circle.position = Vector2(1000, 1000)
	safe_zone_circle.color = Color(0, 1, 0, 0.3)
	players_container.add_child(safe_zone_circle)
	
	# Create game background
	var background = ColorRect.new()
	background.color = Color.DARK_GREEN
	background.size = map_size
	background.anchor_left = 0.0
	background.anchor_top = 0.0
	players_container.add_child(background)
	players_container.move_child(background, 0)

func spawn_player(player_id: int, player_name: String, position: Vector2, is_local: bool):
	"""Spawn a player in the game"""
	if player_id in network_manager.players:
		return  # Player already exists
	
	# Create player instance
	var player = Node2D.new()
	player.name = "Player_%d" % player_id
	
	# Add sprite and collision
	var sprite = Sprite2D.new()
	player.add_child(sprite)
	
	var collision = CollisionShape2D.new()
	collision.shape = CircleShape2D.new()
	collision.shape.radius = 16
	player.add_child(collision)
	
	# Set up the player script
	var player_script = preload("res://Player.gd").new()
	player.add_script(player_script)
	player.player_id = player_id
	player.player_name = player_name
	player.network = network_manager
	player.global_position = position
	
	# Create a simple colored square
	var image = Image.create(32, 32, false, Image.FORMAT_RGB8)
	var color = Color(randf(), randf(), randf())  # Random color for each player
	for x in range(32):
		for y in range(32):
			image.set_pixel(x, y, color)
	sprite.texture = ImageTexture.create_from_image(image)
	
	players_container.add_child(player)
	network_manager.players[player_id] = player
	
	if is_local:
		local_player = player
		# Make camera follow local player
		var camera = Camera2D.new()
		camera.global_position = position
		player.add_child(camera)
		camera.make_current()
		print("Local player spawned at ", position)
	else:
		print("Remote player spawned: ", player_name)
	
	update_hud(len(network_manager.players))

func remove_player(player_id: int):
	"""Remove a player from the game"""
	if player_id in network_manager.players:
		var player = network_manager.players[player_id]
		player.queue_free()
		network_manager.players.erase(player_id)
		print("Player removed: ", player_id)
		update_hud(len(network_manager.players))

func update_hud(players_alive: int):
	"""Update HUD with game info"""
	if hud_label:
		hud_label.text = "Players Alive: %d" % players_alive
		if local_player and not local_player.dead:
			hud_label.text += "\nHealth: %d" % local_player.health

func update_safe_zone(center: Vector2, radius: float):
	"""Update the safe zone visualization"""
	if safe_zone_circle:
		safe_zone_circle.position = center
		safe_zone_circle.radius = radius

func end_game(winner: String):
	"""Game has ended"""
	hud_label.text = "GAME OVER\nWinner: %s" % winner
	print("Game ended! Winner: ", winner)

# Helper class for drawing the safe zone
class Circle2D extends Node2D:
	var radius: float = 100
	var color: Color = Color.WHITE
	
	func _draw():
		draw_circle(Vector2.ZERO, radius, color)
