## input_config.gd -- Autoload "InputConfig": keyboard + gamepad bindings for both players,
## persisted to user://controls.cfg and rebindable from the Controls menu.
## P1 gamepad = device 0, P2 gamepad = device 1. Keyboard is shared.
extends Node

signal bindings_changed

const PATH: String = "user://controls.cfg"
const AXIS_DEADZONE: float = 0.5

## [id, label, P1 action, P2 action]
const ACTIONS: Array = [
	["left",    "Move Left",    "move_left",  "p2_left"],
	["right",   "Move Right",   "move_right", "p2_right"],
	["jump",    "Jump",         "jump",       "p2_jump"],
	["attack",  "Attack",       "attack",     "p2_attack"],
	["heavy",   "Heavy Attack", "heavy",      "p2_heavy"],
	["block",   "Block",        "block",      "p2_block"],
	["special", "Super Finisher", "special",  "p2_special"],
]

## Physical keycodes (Godot Key enum values).
const DEFAULT_KEYS: Array = [
	{"left": [65], "right": [68], "jump": [87, 32], "attack": [74], "heavy": [85], "block": [83, 75], "special": [73]},
	{"left": [4194319], "right": [4194321], "jump": [4194320], "attack": [47, 4194438, 4194311],
		"heavy": [44, 4194439], "block": [4194322, 46], "special": [77, 4194440]},
]

## {"t": "b", "i": button} or {"t": "a", "axis": n, "dir": +-1}
const DEFAULT_PADS: Dictionary = {
	"left":    [{"t": "b", "i": 13}, {"t": "a", "axis": 0, "dir": -1}],
	"right":   [{"t": "b", "i": 14}, {"t": "a", "axis": 0, "dir": 1}],
	"jump":    [{"t": "b", "i": 0}, {"t": "b", "i": 11}, {"t": "a", "axis": 1, "dir": -1}],
	"attack":  [{"t": "b", "i": 2}],
	"heavy":   [{"t": "b", "i": 3}],
	"block":   [{"t": "b", "i": 9}, {"t": "a", "axis": 4, "dir": 1}, {"t": "b", "i": 12}],
	"special": [{"t": "b", "i": 1}, {"t": "b", "i": 10}, {"t": "a", "axis": 5, "dir": 1}],
}

const PAD_BUTTON_NAMES: Array = ["A", "B", "X", "Y", "BACK", "GUIDE", "START", "L3", "R3", "LB", "RB", "D-UP", "D-DOWN", "D-LEFT", "D-RIGHT"]
const PAD_AXIS_NAMES: Array = ["L-STICK X", "L-STICK Y", "R-STICK X", "R-STICK Y", "LT", "RT"]

## bindings[player][id] = {"keys": Array[int], "pads": Array[Dictionary]}
var bindings: Array = [{}, {}]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_reset_to_defaults()
	_load()
	_register_fixed_actions()
	apply_all()


# ── Public API ──────────────────────────────────────────────────────────────

func action_name(player: int, id: String) -> String:
	for row in ACTIONS:
		if row[0] == id:
			return row[2 + player]
	return ""


func key_label(player: int, id: String) -> String:
	var keys: Array = bindings[player][id]["keys"]
	if keys.is_empty():
		return "---"
	return OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(keys[0]))


func pad_label(player: int, id: String) -> String:
	var pads: Array = bindings[player][id]["pads"]
	if pads.is_empty():
		return "---"
	return _pad_to_text(pads[0])


func set_key(player: int, id: String, physical_keycode: int) -> void:
	# A key can only trigger one action: take it from anything else that used it.
	for p in range(2):
		for row in ACTIONS:
			if p == player and row[0] == id:
				continue
			bindings[p][row[0]]["keys"].erase(physical_keycode)
	bindings[player][id]["keys"] = [physical_keycode]
	_changed()


func set_pad(player: int, id: String, pad: Dictionary) -> void:
	for row in ACTIONS:
		if row[0] == id:
			continue
		var list: Array = bindings[player][row[0]]["pads"]
		for i in range(list.size() - 1, -1, -1):
			if _same_pad(list[i], pad):
				list.remove_at(i)
	bindings[player][id]["pads"] = [pad]
	_changed()


func reset_defaults() -> void:
	_reset_to_defaults()
	_changed()


func apply_all() -> void:
	for p in range(2):
		for row in ACTIONS:
			var act: String = row[2 + p]
			if not InputMap.has_action(act):
				InputMap.add_action(act, AXIS_DEADZONE)
			InputMap.action_erase_events(act)
			for code in bindings[p][row[0]]["keys"]:
				var ev := InputEventKey.new()
				ev.physical_keycode = code
				InputMap.action_add_event(act, ev)
			for pad in bindings[p][row[0]]["pads"]:
				InputMap.action_add_event(act, _pad_to_event(pad, p))


## Turns a raw event into a pad binding dictionary (empty if it isn't usable).
func pad_from_event(event: InputEvent) -> Dictionary:
	if event is InputEventJoypadButton and event.pressed:
		return {"t": "b", "i": int(event.button_index)}
	if event is InputEventJoypadMotion and absf(event.axis_value) > 0.7:
		return {"t": "a", "axis": int(event.axis), "dir": 1 if event.axis_value > 0.0 else -1}
	return {}


# ── Internals ───────────────────────────────────────────────────────────────

func _changed() -> void:
	apply_all()
	_save()
	bindings_changed.emit()


func _reset_to_defaults() -> void:
	for p in range(2):
		bindings[p] = {}
		for row in ACTIONS:
			var id: String = row[0]
			bindings[p][id] = {"keys": (DEFAULT_KEYS[p][id] as Array).duplicate(), "pads": (DEFAULT_PADS[id] as Array).duplicate(true)}


func _pad_to_event(pad: Dictionary, device: int) -> InputEvent:
	if pad["t"] == "b":
		var b := InputEventJoypadButton.new()
		b.button_index = int(pad["i"])
		b.device = device
		return b
	var m := InputEventJoypadMotion.new()
	m.axis = int(pad["axis"])
	m.axis_value = float(pad["dir"])
	m.device = device
	return m


func _pad_to_text(pad: Dictionary) -> String:
	if pad["t"] == "b":
		var i := int(pad["i"])
		return PAD_BUTTON_NAMES[i] if i < PAD_BUTTON_NAMES.size() else "BTN %d" % i
	var axis := int(pad["axis"])
	var nm: String = PAD_AXIS_NAMES[axis] if axis < PAD_AXIS_NAMES.size() else "AXIS %d" % axis
	if axis < 4:
		var dir_txt := ("-" if int(pad["dir"]) < 0 else "+")
		return "%s %s" % [nm, dir_txt]
	return nm


func _same_pad(a: Dictionary, b: Dictionary) -> bool:
	if a["t"] != b["t"]:
		return false
	if a["t"] == "b":
		return int(a["i"]) == int(b["i"])
	return int(a["axis"]) == int(b["axis"]) and int(a["dir"]) == int(b["dir"])


## Menu-level actions that aren't rebindable (pause, overlay shortcuts, stage cycling).
func _register_fixed_actions() -> void:
	_fixed("ui_pause",   [KEY_ESCAPE], [{"t": "b", "i": 6}])
	_fixed("ov_restart", [KEY_R], [{"t": "b", "i": 3}])
	_fixed("ov_select",  [KEY_C], [{"t": "b", "i": 2}])
	_fixed("ov_menu",    [KEY_M], [{"t": "b", "i": 1}, {"t": "b", "i": 4}])
	_fixed("stage_next", [KEY_TAB], [{"t": "b", "i": 10}])
	_fixed("stage_prev", [], [{"t": "b", "i": 9}])


func _fixed(act: String, keys: Array, pads: Array) -> void:
	if not InputMap.has_action(act):
		InputMap.add_action(act, 0.5)
	InputMap.action_erase_events(act)
	for k in keys:
		var ev := InputEventKey.new()
		ev.keycode = k
		InputMap.action_add_event(act, ev)
	for pad in pads:
		InputMap.action_add_event(act, _pad_to_event(pad, -1))


func _save() -> void:
	var cfg := ConfigFile.new()
	for p in range(2):
		for row in ACTIONS:
			var id: String = row[0]
			cfg.set_value("p%d" % (p + 1), id + "_keys", bindings[p][id]["keys"])
			cfg.set_value("p%d" % (p + 1), id + "_pads", bindings[p][id]["pads"])
	cfg.save(PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for p in range(2):
		for row in ACTIONS:
			var id: String = row[0]
			var sec := "p%d" % (p + 1)
			var keys = cfg.get_value(sec, id + "_keys", null)
			var pads = cfg.get_value(sec, id + "_pads", null)
			if keys is Array:
				bindings[p][id]["keys"] = keys
			if pads is Array:
				bindings[p][id]["pads"] = pads
