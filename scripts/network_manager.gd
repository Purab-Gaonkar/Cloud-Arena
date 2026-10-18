## network_manager.gd -- Autoload singleton for all multiplayer networking.
##
## ROLES
##   * Dedicated server: a headless Godot process (or `--server`) that hosts exactly ONE match.
##       godot --headless --path . -- --server --port=7001 --room=abc123 --api=http://api:8000
##     It prints machine-readable "@@ROOM {json}" lines on stdout so the Python room manager can
##     track it, reports the result to the matchmaking API and exits when the match is over.
##   * Client: matchmakes through the REST API (matchmake()), connects over WebSocket (join_game())
##     and plays through the same game scene; all combat is simulated on the server.
##
## Uses WebSocketMultiplayerPeer so builds also work behind WebSocket-only proxies
## (NGINX, Cloud Run). A keepalive ping is sent while connected so idle timeouts never fire.
extends Node

const DEFAULT_PORT: int = 7000
const MAX_PLAYERS: int = 2
const PING_INTERVAL_SEC: float = 20.0
const MATCHMAKE_TIMEOUT_SEC: float = 25.0
const GAME_SCENE: String = "res://scenes/game.tscn"

signal network_ready
signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal server_lost
signal connect_failed
signal matchmaking_status(text: String)
signal matchmaking_failed(reason: String)
signal matchmaking_done

## True when this process is the authoritative dedicated server.
var is_server: bool = false
## Dedicated-server settings (from command-line user args).
var room_id: String = ""
var api_url: String = ""
var server_rounds: int = 2
var server_round_seconds: int = 99
var idle_timeout_sec: float = 90.0
## Client identity used when registering with a server.
var player_name: String = ""
## One-time ticket from /match/join; presented to the game server to prove who we are.
var join_ticket: String = ""
## Headless bot client (load / soak testing): plays by itself.
var bot_mode: bool = false

var _ping_accum: float = 0.0
var _ping_active: bool = false
var _http: HTTPRequest
var _matchmaking: bool = false
var _mm_elapsed: float = 0.0
var _mm_attempts: int = 0
var _args: Dictionary = {}
var _server_idle_t: float = 0.0
var _server_had_players: bool = false
var _server_empty_t: float = 0.0
var _server_age: float = 0.0
## True while the match is frozen waiting for a dropped player to come back (keeps the server alive).
var hold_active: bool = false
var _lifecycle: bool = false   # only managed servers (--room / --server) shut themselves down


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS     # keep pinging / managing the server while a match is frozen
	_args = _parse_args()
	player_name = String(_args.get("name", "Player_%d" % (randi() % 9000 + 1000)))
	bot_mode = _args.has("bot")

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_http = HTTPRequest.new()
	_http.timeout = 10.0
	add_child(_http)
	_http.request_completed.connect(_on_matchmake_response)

	if _wants_server():
		room_id = String(_args.get("room", "local"))
		api_url = String(_args.get("api", ""))
		server_rounds = int(_args.get("rounds", 2))
		server_round_seconds = int(_args.get("time", 99))
		idle_timeout_sec = float(_args.get("idle", 90.0))
		_lifecycle = _args.has("room") or _args.has("server")
		var port := int(_args.get("port", DEFAULT_PORT))
		print("[NetworkManager] Dedicated server mode (room %s) on port %d" % [room_id, port])
		host_game(port)
	elif _args.has("matchmake"):
		# Headless bot that goes through the matchmaking API like a real player.
		get_tree().root.set_meta("local_mode", false)
		get_tree().root.set_meta("p1_char", String(_args.get("char", "Fighter")))
		get_tree().root.set_meta("p1_pal", int(_args.get("pal", 0)))
		matchmaking_failed.connect(func(reason: String) -> void:
			print("@@BOT matchmaking_failed: ", reason)
			get_tree().quit(2))
		_bot_sign_in_then_matchmake.call_deferred(String(_args["matchmake"]))
		_go_to_game_when_connected.call_deferred()
	elif _args.has("join"):
		# Command-line auto join (used by bots and for quick manual testing).
		get_tree().root.set_meta("local_mode", false)
		get_tree().root.set_meta("p1_char", String(_args.get("char", "Fighter")))
		get_tree().root.set_meta("p1_pal", int(_args.get("pal", 0)))
		join_game(String(_args["join"]))
		_go_to_game_when_connected.call_deferred()


## Bots have real accounts too: sign in, creating the account on first use.
func _bot_sign_in_then_matchmake(url: String) -> void:
	var user := String(_args.get("user", String(_args.get("name", "bot_%d" % (randi() % 90000 + 10000)))))
	var pw := String(_args.get("pass", "botpassword1"))
	Account.sign_in(url, user, pw)
	var res: Array = await Account.request_done
	if not res[0]:
		Account.create_account(url, user, pw)
		res = await Account.request_done
	if not res[0]:
		print("@@BOT auth_failed: ", res[1])
		get_tree().quit(3)
		return
	matchmake(url)


func _wants_server() -> bool:
	if _args.has("server") or OS.has_feature("dedicated_server"):
		return true
	return DisplayServer.get_name() == "headless" and not _args.has("join") and not _args.has("matchmake") and not _args.has("client")


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var s := String(a).trim_prefix("--")
		var eq := s.find("=")
		if eq == -1:
			out[s] = true
		else:
			out[s.substr(0, eq)] = s.substr(eq + 1)
	return out


# ── Keepalive, matchmaking timeout and dedicated-server lifecycle ──────────────

func _process(delta: float) -> void:
	if _ping_active and not is_server:
		_ping_accum += delta
		if _ping_accum >= PING_INTERVAL_SEC:
			_ping_accum = 0.0
			_send_ping()
	if _matchmaking:
		_mm_elapsed += delta
		if _mm_elapsed > MATCHMAKE_TIMEOUT_SEC:
			_fail_matchmaking("Matchmaking timed out.")
	if is_server and _lifecycle:
		_server_lifecycle(delta)


## The server shuts itself down when nobody shows up, everyone has left, or a match runs forever.
func _server_lifecycle(delta: float) -> void:
	_server_age += delta
	var peers := multiplayer.get_peers().size()
	if peers > 0:
		_server_had_players = true
		_server_empty_t = 0.0
		_server_idle_t = 0.0
	elif hold_active:
		_server_empty_t = 0.0                   # a dropped player may still come back
	else:
		if _server_had_players:
			_server_empty_t += delta
			if _server_empty_t > 6.0:
				_quit_server("all_players_left")
		else:
			_server_idle_t += delta
			if _server_idle_t > idle_timeout_sec:
				_quit_server("idle_timeout")
	if _server_age > 3600.0:
		_quit_server("max_age")


func _quit_server(reason: String) -> void:
	room_event("closed", {"reason": reason})
	get_tree().quit()


func _send_ping() -> void:
	var peer = multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_ping_active = false
		return
	# A tiny RPC keeps both ends (and Cloud Run / NGINX) aware the connection is live.
	var node := get_tree().current_scene
	if node and node.has_node("Net"):
		node.get_node("Net").ping.rpc_id(1)


## Machine-readable status line for the Python room manager (parsed from stdout).
func room_event(event: String, data: Dictionary = {}) -> void:
	if not is_server:
		return
	var payload := {"event": event, "room": room_id}
	payload.merge(data)
	print("@@ROOM " + JSON.stringify(payload))


# ── Public API ──────────────────────────────────────────────────────────────

func host_game(port: int = DEFAULT_PORT) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("[NetworkManager] Failed to create server on port %d - error %s" % [port, error_string(err)])
		print("@@ROOM " + JSON.stringify({"event": "error", "room": room_id, "msg": error_string(err)}))
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	print("[NetworkManager] Hosting on port %d  |  Peer ID: %d" % [port, multiplayer.get_unique_id()])
	room_event("ready", {"port": port})
	network_ready.emit()
	return OK


func join_game(url: String) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_error("[NetworkManager] Failed to connect to %s - error %s" % [url, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_server = false
	print("[NetworkManager] Connecting to %s ..." % url)
	return OK


func _server_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json", "X-Server-Key: " + OS.get_environment("SERVER_KEY")])


## Dedicated server: exchange a client's join ticket for its verified account name.
## Without an --api (local development only) the ticket text itself is used as the name.
func redeem_ticket(ticket: String, done: Callable) -> void:
	if api_url.is_empty():
		done.call(true, ticket.left(14))
		return
	var h := HTTPRequest.new()
	h.timeout = 6.0
	add_child(h)
	h.request_completed.connect(func(_r: int, code: int, _hd: PackedStringArray, body: PackedByteArray) -> void:
		h.queue_free()
		var data = JSON.parse_string(body.get_string_from_utf8())
		if code == 200 and typeof(data) == TYPE_DICTIONARY and data.has("username"):
			done.call(true, str(data["username"]))
		else:
			done.call(false, "")
	)
	var body := JSON.stringify({"ticket": ticket, "room_id": room_id})
	if h.request(api_url.trim_suffix("/") + "/auth/ticket/redeem", _server_headers(), HTTPClient.METHOD_POST, body) != OK:
		h.queue_free()
		done.call(false, "")


## Dedicated server: tell the matchmaking API who won (feeds the global leaderboard).
func report_result(winner_name: String, loser_name: String, duration_s: float) -> void:
	if not is_server or api_url.is_empty():
		return
	var h := HTTPRequest.new()
	h.timeout = 8.0
	add_child(h)
	h.request_completed.connect(func(_r: int, code: int, _hd: PackedStringArray, _b: PackedByteArray) -> void:
		print("[NetworkManager] Result reported (HTTP %d)" % code)
		h.queue_free())
	var body := JSON.stringify({"room_id": room_id, "winner_name": winner_name, "loser_name": loser_name, "duration_s": duration_s})
	if h.request(api_url.trim_suffix("/") + "/stats/result", _server_headers(), HTTPClient.METHOD_POST, body) != OK:
		h.queue_free()


func disconnect_game() -> void:
	_ping_active = false
	_ping_accum = 0.0
	_matchmaking = false
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false


## Test helper: behave as if the network cable was pulled (no goodbye to the server).
func simulate_drop() -> void:
	print("@@BOT dropping connection")
	_ping_active = false
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	server_lost.emit()


## Client: get back into the match this account is still playing. Returns 0 = connected (register next),
## 1 = try again shortly, 2 = no match to return to.
func try_rejoin() -> int:
	var h := HTTPRequest.new()
	h.timeout = 6.0
	add_child(h)
	if h.request(api_url.trim_suffix("/") + "/match/rejoin", Account.auth_headers(), HTTPClient.METHOD_POST, "{}") != OK:
		h.queue_free()
		return 1
	var res: Array = await h.request_completed
	h.queue_free()
	var code: int = res[1]
	if code == 404 or code == 401:
		return 2
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if code != 200 or typeof(data) != TYPE_DICTIONARY or not data.has("ws_url"):
		return 1
	join_ticket = str(data.get("ticket", ""))
	if join_game(str(data["ws_url"])) != OK:
		return 1
	var waited := 0.0
	while waited < 8.0:
		if is_connected_to_server():
			return 0
		if multiplayer.multiplayer_peer == null:
			return 1                            # connection_failed already cleaned up
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	disconnect_game()
	return 1


func is_connected_to_server() -> bool:
	var peer = multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## Ask the REST API for a room, then connect to the returned WebSocket address.
func matchmake(url: String) -> void:
	if _matchmaking:
		return
	api_url = url.strip_edges().trim_suffix("/")
	if api_url.is_empty():
		api_url = "http://127.0.0.1:8000"
	_matchmaking = true
	_mm_elapsed = 0.0
	_mm_attempts += 1
	matchmaking_status.emit("Looking for a match...")
	player_name = Account.username
	var body := JSON.stringify({"player_name": player_name})
	var err := _http.request(api_url + "/match/join", Account.auth_headers(), HTTPClient.METHOD_POST, body)
	if err != OK:
		_fail_matchmaking("Could not reach the matchmaking service.")


func cancel_matchmaking() -> void:
	_matchmaking = false
	_mm_attempts = 0
	_http.cancel_request()
	disconnect_game()


func _on_matchmake_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not _matchmaking:
		return
	if code == 401:
		Account.clear_session()
		_fail_matchmaking("Please sign in again.")
		return
	if code != 200:
		_fail_matchmaking("Matchmaking failed (HTTP %d)." % code)
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY or not json.has("ws_url") or json.get("room_id") == null:
		_fail_matchmaking("Matchmaking returned no room.")
		return
	var url: String = json["ws_url"]
	join_ticket = str(json.get("ticket", ""))
	matchmaking_status.emit("Joining room %s..." % str(json["room_id"]))
	get_tree().root.set_meta("local_mode", false)
	if join_game(url) != OK:
		_fail_matchmaking("Could not open a connection to the game server.")


func _fail_matchmaking(reason: String) -> void:
	_matchmaking = false
	disconnect_game()
	matchmaking_failed.emit(reason)


func _go_to_game_when_connected() -> void:
	await network_ready
	Transition.go(GAME_SCENE)


# ── Signal callbacks ────────────────────────────────────────────────────────

func _on_peer_connected(id: int) -> void:
	print("[NetworkManager] Peer connected: %d" % id)
	player_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	print("[NetworkManager] Peer disconnected: %d" % id)
	player_disconnected.emit(id)


func _on_connected_to_server() -> void:
	print("[NetworkManager] Connected  |  My Peer ID: %d" % multiplayer.get_unique_id())
	_ping_accum = 0.0
	_ping_active = true
	if _matchmaking:
		_matchmaking = false
		_mm_attempts = 0
		matchmaking_done.emit()
	network_ready.emit()


func _on_connection_failed() -> void:
	push_warning("[NetworkManager] Connection to server failed.")
	multiplayer.multiplayer_peer = null
	if _matchmaking:
		# A stale/full room: try matchmaking again a few times before giving up.
		if _mm_attempts < 3:
			_matchmaking = false
			matchmake(api_url)
		else:
			_fail_matchmaking("Could not connect to the game server.")
	else:
		connect_failed.emit()


func _on_server_disconnected() -> void:
	print("[NetworkManager] Server closed the connection.")
	_ping_active = false
	multiplayer.multiplayer_peer = null
	server_lost.emit()


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")
