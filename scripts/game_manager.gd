## game_manager.gd -- Match and spawn manager.
## LOCAL MODE: Both players spawned immediately, no networking.
## NETWORK MODE: Listens for peer connections.
extends Node2D

var local_mode: bool = true

const SPAWN_POINTS: Array[Vector2] = [
	Vector2(-600.0, 0.0),
	Vector2( 600.0, 0.0),
]

var _players: Array = []
var _next_spawn_index: int = 0
var _network_players: Dictionary = {}

@onready var _players_node: Node2D        = $Players
@onready var _spawner: MultiplayerSpawner = $MultiplayerSpawner


func _ready() -> void:
	if get_tree().root.has_meta("local_mode"):
		local_mode = get_tree().root.get_meta("local_mode")

	_setup_background()
	_setup_platform()
	_setup_hud()

	if local_mode:
		_spawn_local_players()
	else:
		_setup_network()


func _setup_background() -> void:
	var parallax := ParallaxBackground.new()
	var layer    := ParallaxLayer.new()
	layer.motion_scale = Vector2(0.15, 0.15)
	var tex := TextureRect.new()
	tex.texture  = load("res://assets/background.svg")
	tex.position = Vector2(-960, -540)
	layer.add_child(tex)
	parallax.add_child(layer)
	add_child(parallax)


func _setup_platform() -> void:
	var floor_node := get_node_or_null("Floor")
	if not floor_node:
		return
	var old := floor_node.get_node_or_null("ColorRect")
	if old:
		old.queue_free()
	if not floor_node.has_node("PlatformTex"):
		var pt := TextureRect.new()
		pt.name           = "PlatformTex"
		pt.texture        = load("res://assets/platform.svg")
		pt.stretch_mode   = TextureRect.STRETCH_TILE
		pt.size           = Vector2(3000, 40)
		pt.position       = Vector2(-1500, -20)
		pt.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		floor_node.add_child(pt)


func _setup_hud() -> void:
	if not get_node_or_null("TekkenHUD"):
		var hud = preload("res://scripts/tekken_hud.gd").new()
		hud.name = "TekkenHUD"
		add_child(hud)


func _spawn_local_players() -> void:
	var scene: PackedScene = preload("res://scenes/player.tscn")
	for i in range(2):
		var p = scene.instantiate()
		p.name          = "Player%d" % i
		p.player_index  = i
		p.local_mode    = true
		p.position      = SPAWN_POINTS[i]
		if i == 1:
			p.facing_direction = -1
		_players_node.add_child(p)
		_players.append(p)

	if _players.size() == 2:
		_players[0]._opponent = _players[1]
		_players[1]._opponent = _players[0]

	print("[GameManager] Local players spawned.")


func _setup_network() -> void:
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
	_reset_round()


func _reset_round() -> void:
	var hud := get_node_or_null("TekkenHUD")
	if hud and hud.has_method("reset_round"):
		hud.reset_round()
	for i in range(_players.size()):
		var p = _players[i]
		if is_instance_valid(p):
			p.reset_for_new_round(SPAWN_POINTS[i % SPAWN_POINTS.size()])
			if i == 1:
				p.facing_direction = -1


func _get_network_manager() -> Node:
	return get_node_or_null("/root/NetworkManager")