## character_select.gd -- Fighter + stage select for local play (2 players, or 1 player vs CPU).
extends Control

const UiStyle      := preload("res://scripts/ui_style.gd")
const FighterData  := preload("res://scripts/fighter_data.gd")
const WorldBuilder := preload("res://scripts/world_builder.gd")

const GAME_SCENE: String = "res://scenes/game.tscn"
const MENU_SCENE: String = "res://scenes/main.tscn"

var _vs_cpu: bool = false
var _cursor: Array[int]  = [0, 1]
var _locked: Array[bool] = [false, false]
var _starting: bool = false
var _stage: int = 0

var _world: Node2D
var _cards:   Array[Panel] = []
var _sprites: Array[AnimatedSprite2D] = []
var _tags:    Array[Label] = []
var _prompt:  Label
var _stage_label: Label
var _t: float = 0.0


func _ready() -> void:
	var root := get_tree().root
	_vs_cpu = root.has_meta("vs_cpu") and root.get_meta("vs_cpu")
	_stage = root.get_meta("stage") if root.has_meta("stage") else randi() % WorldBuilder.stage_count()
	AudioManager.play_music("menu")
	_build_ui()
	_set_stage(_stage)
	_refresh()


func _process(delta: float) -> void:
	_t += delta
	if _world:
		_world.update_parallax(sin(_t * 0.15) * 250.0)


func _set_stage(index: int) -> void:
	_stage = posmod(index, WorldBuilder.stage_count())
	if _world:
		AudioManager.play("ui_toggle")
		_world.queue_free()
	_world = WorldBuilder.new()
	_world.position = Vector2(640, 690.0 - WorldBuilder.GROUND_Y)
	add_child(_world)
	move_child(_world, 0)
	_world.build(_stage)
	_stage_label.text = "STAGE   <   %s   >      TAB to change" % WorldBuilder.stage_name(_stage)


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.01, 0.06, 0.5)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var title := UiStyle.label("SELECT YOUR FIGHTER", 64, Color.WHITE, true, 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("shadow_offset_x", 5)
	title.add_theme_constant_override("shadow_offset_y", 5)
	root.add_child(title)

	_prompt = UiStyle.label("", 24, UiStyle.GOLD, true, 6)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_prompt)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	root.add_child(row)
	for i in range(FighterData.ROSTER.size()):
		row.add_child(_build_card(i))

	_stage_label = UiStyle.label("", 22, UiStyle.TEXT, true, 6)
	_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_stage_label)

	var hint := UiStyle.label("", 14, UiStyle.TEXT, false, 5)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if _vs_cpu:
		hint.text = "A / D choose      J confirm      S undo      TAB stage      ESC back"
	else:
		hint.text = "P1:  A / D choose,  J confirm,  S undo        P2:  Left / Right,  /  or Numpad 0 confirm,  Down undo        TAB stage      ESC back"
	root.add_child(hint)


func _build_card(index: int) -> Panel:
	var f: Dictionary = FighterData.ROSTER[index]
	var card := Panel.new()
	card.custom_minimum_size = Vector2(300, 390)
	_cards.append(card)

	var tag := UiStyle.label("", 24, Color.WHITE, true, 6)
	tag.position = Vector2(0, 8)
	tag.size = Vector2(300, 30)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(tag)
	_tags.append(tag)

	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = FighterData.build_frames(f["id"])
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.scale = Vector2(2.3, 2.3)
	sprite.position = Vector2(150, 90)
	sprite.play("idle")
	sprite.animation_finished.connect(_on_preview_finished.bind(sprite))
	card.add_child(sprite)
	_sprites.append(sprite)

	var name_lbl := UiStyle.label(f["name"], 40, f["color"], true, 8)
	name_lbl.position = Vector2(0, 236)
	name_lbl.size = Vector2(300, 46)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(name_lbl)

	var blurb := UiStyle.label(f["blurb"], 14, UiStyle.MUTED, false)
	blurb.position = Vector2(0, 282)
	blurb.size = Vector2(300, 20)
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(blurb)

	var stat_names := ["POWER", "SPEED", "REACH"]
	for s in range(3):
		_add_stat_row(card, stat_names[s], f["stats"][s], f["color"], Vector2(40, 314 + s * 22))
	return card


func _add_stat_row(card: Panel, label: String, value: int, color: Color, pos: Vector2) -> void:
	var lbl := UiStyle.label(label, 16, UiStyle.TEXT, true)
	lbl.position = pos + Vector2(0, -4)
	card.add_child(lbl)
	for i in range(5):
		var pip := ColorRect.new()
		pip.position = pos + Vector2(80 + i * 32, 2)
		pip.size = Vector2(27, 11)
		pip.color = color if i < value else Color(0.2, 0.2, 0.28)
		card.add_child(pip)


func _on_preview_finished(sprite: AnimatedSprite2D) -> void:
	if sprite.animation != "idle":
		sprite.play("idle")


func _refresh() -> void:
	for i in range(_cards.size()):
		var on1: bool = _cursor[0] == i
		var on2: bool = _cursor[1] == i
		var border := Color(0.35, 0.33, 0.48)
		if on1 and on2:
			border = UiStyle.GOLD
		elif on1:
			border = UiStyle.P1
		elif on2:
			border = UiStyle.P2
		var bg := Color(0.07, 0.05, 0.13, 0.88)
		var st := UiStyle.box(bg, border, 5 if (on1 or on2) else 2, 10)
		if on1 or on2:
			st.shadow_size = 16
			st.shadow_color = Color(border.r, border.g, border.b, 0.45)
		_cards[i].add_theme_stylebox_override("panel", st)

		var txt := ""
		if on1:
			txt += "P1" + (" READY" if _locked[0] else "")
		if on2:
			txt += ("  " if txt != "" else "") + ("CPU" if _vs_cpu else "P2") + (" READY" if _locked[1] else "")
		_tags[i].text = txt
		_tags[i].add_theme_color_override("font_color", border)

	if _vs_cpu:
		_prompt.text = "CHOOSE YOUR OPPONENT" if _locked[0] else "PLAYER 1 - CHOOSE YOUR FIGHTER"
	else:
		_prompt.text = "BOTH PLAYERS CHOOSE, THEN CONFIRM"


func _unhandled_input(event: InputEvent) -> void:
	if _starting or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		Transition.go(MENU_SCENE)
		return
	if event.keycode == KEY_TAB:
		_set_stage(_stage + 1)
		return

	if _vs_cpu:
		# P1's keys drive both picks: first their own fighter, then the CPU opponent.
		var who := 1 if _locked[0] else 0
		_handle(who, "move_left", "move_right", "attack", "block", event)
	else:
		_handle(0, "move_left", "move_right", "attack", "block", event)
		_handle(1, "p2_left", "p2_right", "p2_attack", "p2_block", event)


func _handle(who: int, left: String, right: String, confirm: String, cancel: String, event: InputEvent) -> void:
	if event.is_action_pressed(left) and not _locked[who]:
		_cursor[who] = wrapi(_cursor[who] - 1, 0, FighterData.ROSTER.size())
		AudioManager.play("ui_move")
	elif event.is_action_pressed(right) and not _locked[who]:
		_cursor[who] = wrapi(_cursor[who] + 1, 0, FighterData.ROSTER.size())
		AudioManager.play("ui_move")
	elif event.is_action_pressed(confirm) and not _locked[who]:
		_locked[who] = true
		AudioManager.play("ui_select")
		AudioManager.play("hit_heavy", -8.0)
		_sprites[_cursor[who]].play("attack_3")
	elif event.is_action_pressed(cancel):
		AudioManager.play("ui_back")
		if _locked[who]:
			_locked[who] = false
		elif _vs_cpu and who == 1:
			_locked[0] = false
	else:
		return
	_refresh()
	_check_start()


func _check_start() -> void:
	if not (_locked[0] and _locked[1]):
		return
	_starting = true
	var root := get_tree().root
	root.set_meta("local_mode", true)
	root.set_meta("p1_char", FighterData.ROSTER[_cursor[0]]["id"])
	root.set_meta("p2_char", FighterData.ROSTER[_cursor[1]]["id"])
	root.set_meta("stage", _stage)
	_prompt.text = "GET READY!"
	await get_tree().create_timer(0.8).timeout
	Transition.go(GAME_SCENE)
