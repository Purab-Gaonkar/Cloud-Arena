## network_manager.gd — Autoload singleton for all multiplayer networking.
##
## Uses WebSocketMultiplayerPeer so the same build works on desktop AND
## future HTML5 exports (WebSocket is the only transport that browsers allow).
##
## Cloud-ready: when the engine runs in headless mode (dedicated server export
## or --headless flag), it automatically starts hosting on port 7000.
## Clients call host_game() / join_game() from the main menu.
##
## Keepalive: once joined as a client, a ping is sent every PING_INTERVAL_SEC
## seconds so GCP Cloud Run (and any upstream proxy) does not idle-close the
## WebSocket connection before the match ends.
extends Node

## Default port for hosting. Override via host_game(port).
const DEFAULT_PORT: int = 7000
## Maximum players in a match (including the host peer).
const MAX_PLAYERS: int = 4
## Seconds between client-side keepalive pings (Cloud Run idles at 5 min).
const PING_INTERVAL_SEC: float = 20.0

## Emitted when the local peer has fully connected or when hosting starts.
signal network_ready
## Emitted when a remote peer joins (passes the peer_id).
signal player_connected(peer_id: int)
## Emitted when a remote peer leaves (passes the peer_id).
signal player_disconnected(peer_id: int)

## True when this instance is acting as the authoritative server (peer ID 1).
var is_server: bool = false

## Accumulated time since the last ping was sent (clients only).
var _ping_accum: float = 0.0
## Whether the keepalive loop is currently active.
var _ping_active: bool = false


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Wire up Godot's built-in multiplayer signals so we get notified of
	# connections, disconnections and failures through a single choke-point.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

	# --- Headless auto-host -------------------------------------------------
	# If the engine is running without a display (dedicated server export or
	# the --headless CLI flag), skip the menu and start hosting immediately.
	if _is_headless():
		print("[NetworkManager] Headless runtime detected — auto-hosting on port %d" % DEFAULT_PORT)
		host_game(DEFAULT_PORT)


# ---------------------------------------------------------------------------
# Keepalive (_process)
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	# Send a lightweight ping to keep the Cloud Run WebSocket connection alive.
	# Only runs on clients (not the authoritative server peer).
	if not _ping_active or is_server:
		return
	_ping_accum += delta
	if _ping_accum >= PING_INTERVAL_SEC:
		_ping_accum = 0.0
		_send_ping()


## Fire-and-forget ping over the RPC channel.
func _send_ping() -> void:
	var peer = multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_ping_active = false
		return
	# We repurpose Godot's raw packet send so the game server echoes it back
	# as a pong — keeping both sides (and Cloud Run) aware the connection is live.
	var payload := JSON.stringify({"type": "ping", "ts": Time.get_ticks_msec()})
	peer.put_packet(payload.to_utf8_buffer())
	print("[NetworkManager] Keepalive ping sent")



# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Start hosting a game on the given port.
## After this call, multiplayer.get_unique_id() == 1 (server).
func host_game(port: int = DEFAULT_PORT) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("[NetworkManager] Failed to create server on port %d — error %s" % [port, error_string(err)])
		return err

	multiplayer.multiplayer_peer = peer
	is_server = true
	print("[NetworkManager] Hosting on port %d  |  Peer ID: %d" % [port, multiplayer.get_unique_id()])
	network_ready.emit()
	return OK


## Join an existing game at the given WebSocket URL.
func join_game(url: String) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_error("[NetworkManager] Failed to connect to %s — error %s" % [url, error_string(err)])
		return err

	multiplayer.multiplayer_peer = peer
	is_server = false
	print("[NetworkManager] Connecting to %s …" % url)
	return OK


## Cleanly tear down the current session.
func disconnect_game() -> void:
	_ping_active = false
	_ping_accum  = 0.0
	multiplayer.multiplayer_peer = null
	is_server = false
	print("[NetworkManager] Disconnected.")


# ---------------------------------------------------------------------------
# Signal callbacks
# ---------------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	print("[NetworkManager] Peer connected: %d" % id)
	player_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	print("[NetworkManager] Peer disconnected: %d" % id)
	player_disconnected.emit(id)


func _on_connected_to_server() -> void:
	print("[NetworkManager] Successfully connected to server  |  My Peer ID: %d" % multiplayer.get_unique_id())
	# Start keepalive pings so Cloud Run does not idle-close this connection.
	_ping_accum  = 0.0
	_ping_active = true
	network_ready.emit()


func _on_connection_failed() -> void:
	push_warning("[NetworkManager] Connection to server failed.")
	multiplayer.multiplayer_peer = null


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Returns true when the engine is running without a windowing system.
func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")
