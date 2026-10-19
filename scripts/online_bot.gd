## online_bot.gd -- Headless test client: presses random buttons so server + matchmaking can be
## soak-tested without a human. Enabled with the `--bot` command-line flag (see NetworkManager).
extends Node

var _held: Dictionary = {}
var _done: bool = false
var _acts: Array = ["move_left", "move_right", "jump", "attack", "heavy", "block", "special"]
var _t: float = 0.0
var _want_rematch: bool = false
var _matches_done: int = 0
var _drop_at: float = -1.0       # --drop-at=SECONDS: pull the plug this long after the match starts (reconnect test)
var _match_t: float = -1.0
var _walk: bool = false          # --walk: only move and jump (no attacks), used to measure movement prediction
var _stat_t: float = 0.0
var _shots: Array = []   # [[seconds, path], ...] from --shot=path1,path2 --shot-at=8,14 (windowed runs only)


func _ready() -> void:
	_want_rematch = OS.get_cmdline_user_args().has("--rematch")
	_walk = OS.get_cmdline_user_args().has("--walk")
	if _walk:
		_acts = ["move_left", "move_right", "move_right", "move_left", "jump"]
	var paths := ""
	var times := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--drop-at="):
			_drop_at = float(String(a).substr(10))
		if String(a).begins_with("--shot="):
			paths = String(a).substr(7)
		elif String(a).begins_with("--shot-at="):
			times = String(a).substr(10)
	if paths != "":
		var pl := paths.split(",")
		var tl := times.split(",")
		for i in range(pl.size()):
			_shots.append([float(tl[i]) if i < tl.size() else 10.0, pl[i]])


func match_started() -> void:
	if _match_t < 0.0:
		_match_t = 0.0


func _physics_process(delta: float) -> void:
	_t += delta
	if _match_t >= 0.0 and _drop_at > 0.0:
		_match_t += delta
		if _match_t >= _drop_at:
			_drop_at = -1.0
			NetworkManager.simulate_drop()
	while not _shots.is_empty() and _t >= _shots[0][0]:
		var shot: Array = _shots.pop_front()
		get_viewport().get_texture().get_image().save_png(shot[1])
		print("@@BOT screenshot ", shot[1])
	_stat_t += delta
	if _walk and _stat_t >= 5.0:
		_stat_t = 0.0
		_print_prediction()
	if _walk and not _done:
		_walk_step(delta)
		return
	if _done:
		return
	if randf() < 0.3:
		var a: String = _acts[randi() % _acts.size()]
		if _held.get(a, false):
			Input.action_release(a)
			_held[a] = false
		else:
			Input.action_press(a)
			_held[a] = true
		if randf() < 0.5:
			Input.action_release(a)
			_held[a] = false


var _walk_t: float = 0.0


## Deterministic walker: right 1.2 s, pause 0.5 s, left 1.2 s, pause 0.5 s, with a jump in each pause.
func _walk_step(delta: float) -> void:
	_walk_t = fmod(_walk_t + delta, 3.4)
	var right := _walk_t < 1.2
	var left := _walk_t >= 1.7 and _walk_t < 2.9
	var jump := (_walk_t >= 1.25 and _walk_t < 1.3) or (_walk_t >= 2.95 and _walk_t < 3.0)
	for pair in [["move_right", right], ["move_left", left], ["jump", jump]]:
		if pair[1]:
			Input.action_press(pair[0])
		else:
			Input.action_release(pair[0])


func _print_prediction() -> void:
	var players := get_parent().get_node_or_null("Players")
	if players == null:
		return
	for p in players.get_children():
		if p.has_method("_is_owner_client") and p._is_owner_client():
			var s: Dictionary = p.pred_stats
			var n: int = maxi(1, int(s["n"]))
			print("@@BOT pred n=%d corr_avg=%.2f corr_max=%.1f off_avg=%.1f off_max=%.1f snaps=%d ping=%d calls=%d acks=%d miss=%d inactive=%d ack_seq=%d" % [
				s["n"], s["corr_sum"] / n, s["corr_max"], s["off_sum"] / n, s["off_max"], s["snaps"], NetworkManager.ping_ms,
				s["calls"], s["acks"], s["miss"], s["inactive"], p._ack_seq])


func rematch_started() -> void:
	_done = false


func match_finished() -> void:
	_done = true
	_matches_done += 1
	if _want_rematch and _matches_done == 1:
		await get_tree().create_timer(1.5).timeout
		print("@@BOT requesting rematch")
		get_parent().online_request_rematch()
		return
	for a in _held.keys():
		Input.action_release(a)
	print("@@BOT match_end")
	await get_tree().create_timer(1.5).timeout
	NetworkManager.disconnect_game()
	get_tree().quit()
