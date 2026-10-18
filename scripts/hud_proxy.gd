## hud_proxy.gd -- Stands in for the HUD on the dedicated server.
## Every HUD call the match flow makes is applied to the server's own (headless) HUD, which keeps the
## round clock, and also forwarded to every client so they show the same banners, pips and timer.
extends Node

signal time_up

var real: Node = null
var net: Node = null   # the online_match node (provides net_hud)


func setup(real_hud: Node, net_node: Node) -> void:
	real = real_hud
	net = net_node
	if real.has_signal("time_up"):
		real.time_up.connect(func() -> void: time_up.emit())


func _fwd(method: String, args: Array = []) -> void:
	if real and real.has_method(method):
		real.callv(method, args)
	if net:
		net.net_hud.rpc(method, args)


func configure_rules(rounds_to_win: int, round_seconds: int) -> void:
	_fwd("configure_rules", [rounds_to_win, round_seconds])


func reset_round() -> void:
	_fwd("reset_round")


func set_round(n: int) -> void:
	_fwd("set_round", [n])


func set_round_text(txt: String) -> void:
	_fwd("set_round_text", [txt])


func set_wins(p1_wins: int, p2_wins: int) -> void:
	_fwd("set_wins", [p1_wins, p2_wins])


func show_announcement(txt: String, color: Color, font_size: int = 118) -> void:
	_fwd("show_announcement", [txt, color, font_size])


func clear_announcement() -> void:
	_fwd("clear_announcement")


func start_clock() -> void:
	_fwd("start_clock")


func stop_round() -> void:
	_fwd("stop_round")


func set_fighters(p1_name: String, p1_color: Color, p2_name: String, p2_color: Color) -> void:
	_fwd("set_fighters", [p1_name, p1_color, p2_name, p2_color])


func set_portraits(id1: String, id2: String) -> void:
	_fwd("set_portraits", [id1, id2])
