## online_match.gd -- RPC endpoint for an online match. Lives at <Game>/Net on every peer.
##
## Server (dedicated, headless): accepts at most two clients, waits for both to register their
## fighter, then builds the match through the game manager and drives the whole round flow.
## Clients: register, then render whatever the server replicates and announces.
extends Node

const FighterData := preload("res://scripts/fighter_data.gd")

## Cosmetic game-manager calls the server may trigger on clients, and HUD calls it may forward.
const CLIENT_GM_CALLS: Array = ["hit_effect", "shake", "spawn_fx", "popup_text", "show_combo", "_cine_remote", "_ko_cam"]
const CLIENT_HUD_CALLS: Array = ["configure_rules", "reset_round", "set_round", "set_round_text", "set_wins", "show_announcement",
	"clear_announcement", "start_clock", "stop_round", "set_fighters", "set_portraits"]
const REGISTER_TIMEOUT_SEC: float = 12.0
const GRACE_SEC: float = 30.0      # a dropped player keeps their slot this long

var gm: Node2D
var is_server_role: bool = false

var regs: Dictionary = {}          # peer_id -> {"name", "char", "pal"}
var order: Array[int] = []         # registration order = player slots
var started: bool = false
var _rematch_votes: Dictionary = {}
var _pending: Dictionary = {}      # peer_id -> seconds since connect (unregistered peers)
var held: Dictionary = {}          # slot -> seconds left for a dropped player to come back
var _last_shown: int = -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS     # keeps counting while the match is frozen
	gm = get_parent()
	is_server_role = multiplayer.is_server() and NetworkManager.is_server
	if is_server_role:
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_left)
		for id in multiplayer.get_peers():
			_on_peer_connected(id)


func _process(delta: float) -> void:
	if not is_server_role:
		return
	for id in _pending.keys():
		_pending[id] += delta
		if _pending[id] > REGISTER_TIMEOUT_SEC:
			_pending.erase(id)
			_kick(id)
	if held.is_empty():
		return
	var soonest: float = GRACE_SEC
	for slot in held.keys():
		held[slot] -= delta
		if held[slot] <= 0.0:
			_expire_slot(slot)
		else:
			soonest = minf(soonest, held[slot])
	if not held.is_empty() and ceili(soonest) != _last_shown:
		_last_shown = ceili(soonest)
		net_status.rpc("OPPONENT DISCONNECTED  %d" % _last_shown)


## The grace period ran out: the player who stayed wins.
func _expire_slot(slot: int) -> void:
	held.erase(slot)
	NetworkManager.hold_active = not held.is_empty()
	NetworkManager.room_event("grace_expired", {"slot": slot})
	if held.is_empty():
		gm.online_freeze(false)
		net_status_clear.rpc()
	gm.online_player_left(slot)


func _kick(id: int) -> void:
	if multiplayer.multiplayer_peer and id in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(id)


# ── Server: connections ─────────────────────────────────────────────────────

func _on_peer_connected(id: int) -> void:
	if multiplayer.get_peers().size() > 2:
		_kick(id)
		return
	_pending[id] = 0.0
	NetworkManager.room_event("peer_connected", {"peers": multiplayer.get_peers().size()})


func _on_peer_left(id: int) -> void:
	_pending.erase(id)
	var was_player := regs.has(id)
	var slot := order.find(id)
	_redeeming.erase(id)
	if started and was_player and slot >= 0 and not gm._match_over:
		# Keep the slot (regs/order untouched) and freeze the match; the player can return with a fresh ticket.
		held[slot] = GRACE_SEC
		_last_shown = -1
		NetworkManager.hold_active = true
		NetworkManager.room_event("player_dropped", {"slot": slot, "grace": GRACE_SEC})
		gm.online_freeze(true)
		return
	regs.erase(id)
	order.erase(id)
	_rematch_votes.erase(id)
	NetworkManager.room_event("player_left", {"peers": multiplayer.get_peers().size()})
	if was_player and started:
		gm.online_player_left(slot)


var _redeeming: Dictionary = {}    # peer_id -> true while its ticket is being verified


@rpc("any_peer", "call_remote", "reliable")
func register(ticket: String, char_id: String, palette: int) -> void:
	if not is_server_role:
		return
	var id := multiplayer.get_remote_sender_id()
	var full := (not started and regs.size() + _redeeming.size() >= 2) or (started and held.is_empty())
	if regs.has(id) or _redeeming.has(id) or full:
		_kick(id)
		return
	_pending.erase(id)
	_redeeming[id] = true
	# The ticket was issued by the matchmaking API for exactly this room; redeeming it proves the account.
	NetworkManager.redeem_ticket(ticket, func(ok: bool, username: String) -> void:
		_redeeming.erase(id)
		if not ok or not (id in multiplayer.get_peers()):
			NetworkManager.room_event("auth_rejected", {})
			_kick(id)
			return
		_finish_register(id, username, char_id, palette))


func _finish_register(id: int, username: String, char_id: String, palette: int) -> void:
	if started:
		_rebind(id, username)
		return
	for other in regs.values():
		if other["name"] == username:       # the same account cannot occupy both slots
			_kick(id)
			return
	if regs.size() >= 2 or started:
		_kick(id)
		return
	var valid := false
	for f in FighterData.ROSTER:
		if f["id"] == char_id:
			valid = true
	regs[id] = {
		"name": username,
		"char": char_id if valid else "Fighter",
		"pal":  clampi(palette, 0, FighterData.PALETTE_HUES.size() - 1),
	}
	order.append(id)
	NetworkManager.room_event("player_joined", {"count": regs.size(), "name": username})
	if regs.size() == 2:
		_begin_match()
	else:
		net_waiting.rpc_id(id)


## A dropped player is back (new peer id): hand their fighter to the new connection.
func _rebind(id: int, username: String) -> void:
	var slot := -1
	for s in held.keys():
		if regs.has(order[s]) and regs[order[s]]["name"] == username:
			slot = s
	if slot < 0:
		_kick(id)
		return
	var old: int = order[slot]
	regs[id] = regs[old]
	regs.erase(old)
	order[slot] = id
	held.erase(slot)
	gm.online_rebind(slot, id)
	NetworkManager.room_event("player_rejoined", {"name": username, "slot": slot})
	net_resume.rpc_id(id, gm.online_info())
	if held.is_empty():
		NetworkManager.hold_active = false
		gm.online_freeze(false)
		net_status_clear.rpc()


func _begin_match() -> void:
	started = true
	var info: Dictionary = gm.online_build_match(regs, order)
	net_start.rpc(info)
	NetworkManager.room_event("match_started", {"players": info["names"]})
	gm.online_start_flow()


@rpc("any_peer", "call_remote", "reliable")
func request_rematch() -> void:
	if not is_server_role or not gm._match_over:
		return
	_rematch_votes[multiplayer.get_remote_sender_id()] = true
	if _rematch_votes.size() >= 2 and regs.size() == 2:
		_rematch_votes.clear()
		net_rematch.rpc()
		gm.online_rematch()


@rpc("any_peer", "call_remote", "unreliable")
func ping() -> void:
	pass


# ── Server -> clients ───────────────────────────────────────────────────────

@rpc("authority", "call_remote", "reliable")
func net_waiting() -> void:
	gm.online_set_status("WAITING FOR OPPONENT")


@rpc("authority", "call_remote", "reliable")
func net_start(info: Dictionary) -> void:
	gm.online_client_start(info)


@rpc("authority", "call_remote", "reliable")
func net_resume(info: Dictionary) -> void:
	gm.online_client_resume(info)


@rpc("authority", "call_remote", "reliable")
func net_status(text: String) -> void:
	gm.online_set_status(text)


@rpc("authority", "call_remote", "reliable")
func net_status_clear() -> void:
	gm.online_clear_status()


@rpc("authority", "call_remote", "reliable")
func net_rematch() -> void:
	gm.online_client_rematch()


@rpc("authority", "call_remote", "reliable")
func net_match_end(text: String, stats: Dictionary) -> void:
	gm.online_client_match_end(text, stats)


@rpc("authority", "call_remote", "reliable")
func net_call(method: String, args: Array) -> void:
	if method in CLIENT_GM_CALLS and gm.has_method(method):
		gm.callv(method, args)


@rpc("authority", "call_remote", "reliable")
func net_hud(method: String, args: Array) -> void:
	var hud := gm.get_node_or_null("TekkenHUD")
	if hud and method in CLIENT_HUD_CALLS and hud.has_method(method):
		hud.callv(method, args)


@rpc("authority", "call_remote", "reliable")
func net_sfx(sound: String, volume_db: float) -> void:
	AudioManager.play(sound, volume_db, 0.05, true)
