extends Node

# Server connection
@export var server_url = "ws://localhost:8765"
var websocket = WebSocketPeer.new()
var connected = false
var player_id = 0
var player_name = "Player"

# Game state
var players = {}  # player_id -> player_node
var bullets = []

# References
var game_manager: Node

func _ready():
	game_manager = get_tree().root.get_child(0)
	connect_to_server()

func connect_to_server():
	print("Connecting to server: ", server_url)
	var error = websocket.connect_to_url(server_url)
	if error != OK:
		print("Failed to connect: ", error)
		# Retry in 2 seconds
		await get_tree().create_timer(2.0).timeout
		connect_to_server()

func _process(_delta):
	websocket.poll()
	
	var state = websocket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			print("Connected to server!")
			send_join_game()
		
		# Handle incoming messages
		while websocket.get_available_packet_count() > 0:
			var message = websocket.get_message()
			if message is String:
				handle_message(message)
	elif state == WebSocketPeer.STATE_CLOSED:
		connected = false
		print("Disconnected from server")

func send_message(data: Dictionary):
	"""Send JSON message to server"""
	if connected:
		var json = JSON.stringify(data)
		websocket.send_text(json)

func send_join_game():
	"""Tell server we're joining"""
	send_message({
		"type": "join",
		"player_name": player_name
	})

func send_player_update(pid: int, pos: Vector2, rot: float):
	"""Send player position and rotation to server"""
	send_message({
		"type": "player_update",
		"player_id": pid,
		"x": pos.x,
		"y": pos.y,
		"rotation": rot
	})

func send_shoot(pid: int, pos: Vector2, direction: Vector2):
	"""Send shoot event to server"""
	send_message({
		"type": "shoot",
		"player_id": pid,
		"x": pos.x,
		"y": pos.y,
		"dir_x": direction.x,
		"dir_y": direction.y
	})

func handle_message(message: String):
	"""Parse and handle incoming server messages"""
	var json = JSON.new()
	var error = json.parse(message)
	
	if error != OK:
		print("JSON parse error: ", error)
		return
	
	var data = json.data
	if not data is Dictionary:
		return
	
	var msg_type = data.get("type", "")
	
	match msg_type:
		"join_success":
			handle_join_success(data)
		"player_joined":
			handle_player_joined(data)
		"player_left":
			handle_player_left(data)
		"player_update":
			handle_player_update(data)
		"shoot":
			handle_shoot(data)
		"hit":
			handle_hit(data)
		"game_update":
			handle_game_update(data)
		"safe_zone":
			handle_safe_zone(data)
		"game_over":
			handle_game_over(data)
		_:
			print("Unknown message type: ", msg_type)

func handle_join_success(data: Dictionary):
	"""We successfully joined the game"""
	player_id = data.get("player_id", 0)
	var spawn_x = data.get("spawn_x", 500.0)
	var spawn_y = data.get("spawn_y", 500.0)
	
	print("Joined game! Player ID: ", player_id)
	
	# Create our player
	game_manager.spawn_player(player_id, player_name, Vector2(spawn_x, spawn_y), true)

func handle_player_joined(data: Dictionary):
	"""Another player joined the game"""
	var pid = data.get("player_id", 0)
	var name = data.get("player_name", "Player")
	var spawn_x = data.get("spawn_x", 0.0)
	var spawn_y = data.get("spawn_y", 0.0)
	
	print("Player joined: ", name, " (ID: ", pid, ")")
	game_manager.spawn_player(pid, name, Vector2(spawn_x, spawn_y), false)

func handle_player_left(data: Dictionary):
	"""Player disconnected"""
	var pid = data.get("player_id", 0)
	game_manager.remove_player(pid)

func handle_player_update(data: Dictionary):
	"""Update another player's position"""
	var pid = data.get("player_id", 0)
	var x = data.get("x", 0.0)
	var y = data.get("y", 0.0)
	var rot = data.get("rotation", 0.0)
	
	if pid in players:
		players[pid].update_position(Vector2(x, y))
		players[pid].update_rotation(rot)

func handle_shoot(data: Dictionary):
	"""Another player shot"""
	var pid = data.get("player_id", 0)
	var x = data.get("x", 0.0)
	var y = data.get("y", 0.0)
	var dir_x = data.get("dir_x", 0.0)
	var dir_y = data.get("dir_y", 0.0)
	
	# Visual feedback for other players shooting
	if pid in players:
		pass  # Could add sound/flash effect here

func handle_hit(data: Dictionary):
	"""Player got hit by a bullet"""
	var pid = data.get("player_id", 0)
	var damage = data.get("damage", 10)
	
	if pid in players:
		players[pid].take_damage(damage)

func handle_game_update(data: Dictionary):
	"""General game state update"""
	var players_alive = data.get("players_alive", 0)
	if game_manager.has_method("update_hud"):
		game_manager.update_hud(players_alive)

func handle_safe_zone(data: Dictionary):
	"""Safe zone update (for circle shrinking)"""
	var center_x = data.get("center_x", 500.0)
	var center_y = data.get("center_y", 500.0)
	var radius = data.get("radius", 200.0)
	
	if game_manager.has_method("update_safe_zone"):
		game_manager.update_safe_zone(Vector2(center_x, center_y), radius)

func handle_game_over(data: Dictionary):
	"""Game ended"""
	var winner = data.get("winner", "")
	print("Game Over! Winner: ", winner)
	if game_manager.has_method("end_game"):
		game_manager.end_game(winner)
