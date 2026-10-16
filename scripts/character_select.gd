## character_select.gd -- Fighter select screen for local play (2 players, or 1 player vs CPU).
extends Control

const FighterData := preload("res://scripts/fighter_data.gd")

const GAME_SCENE: String = "res://scenes/game.tscn"
const MENU_SCENE: String = "res://scenes/main.tscn"
const P1_COLOR: Color = Color(0.3, 0.85, 1.0)
const P2_COLOR: Color = Color(1.0, 0.35, 0.35)
const GOLD:     Color = Color(1.0, 0.82, 0.1)

var _vs_cpu: bool = false
var _cursor: Array[int]  = [0, 1]
var _locked: Array[bool] = [false, false]
var _starting: bool = false

var _cards:   Array[Panel] = []
var _sprites: Array[AnimatedSprite2D] = []
var _tags:    Array[Label] = []
var _prompt:  Label


func _ready() -> void:
	_vs_cpu = get_tree().root.has_meta("vs_cpu") and get_tree().root.get_meta("vs_cpu")
	_build_ui()
	_refresh()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.04, 0.07)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var glow := ColorRect.new()
	glow.color = Color(0.06, 0.0, 0.14, 0.45)
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(glow)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 18)
	add_child(root)

	var title := Label.new()
	title.text = "SELECT YOUR FIGHTER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	root.add_child(title)

	_prompt = Label.new()
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 18)
	_prompt.add_theme_color_override("font_color", GOLD)
	root.add_child(_prompt)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	root.add_child(row)

	for i in range(FighterData.ROSTER.size()):
		row.add_child(_build_card(i))

	var hint := Label.new()
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.75))
	if _vs_cpu:
		hint.text = "A / D choose     J confirm     S undo     ESC back"
	else:
		hint.text = "P1:  A / D choose,  J confirm,  S undo          P2:  Left / Right choose,  / or Numpad 0 confirm,  Down undo          ESC back"
	root.add_child(hint)


func _build_card(index: int) -> Panel:
	var f: Dictionary = FighterData.ROSTER[index]
	var card := Panel.new()
	card.custom_minimum_size = Vector2(300, 400)
	_cards.append(card)

	var tag := Label.new()
	tag.position = Vector2(0, 10)
	tag.size = Vector2(300, 26)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.add_theme_font_size_override("font_size", 16)
	card.add_child(tag)
	_tags.append(tag)

	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = FighterData.build_frames(f["id"])
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.scale = Vector2(2.4, 2.4)
	sprite.position = Vector2(150, 90)  # frame centre; feet land near y=240
	sprite.play("idle")
	sprite.animation_finished.connect(_on_preview_finished.bind(sprite))
	card.add_child(sprite)
	_sprites.append(sprite)

	var name_lbl := Label.new()
	name_lbl.text = f["name"]
	name_lbl.position = Vector2(0, 258)
	name_lbl.size = Vector2(300, 32)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 26)
	name_lbl.add_theme_color_override("font_color", f["color"])
	card.add_child(name_lbl)

	var blurb := Label.new()
	blurb.text = f["blurb"]
	blurb.position = Vector2(0, 292)
	blurb.size = Vector2(300, 20)
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blurb.add_theme_font_size_override("font_size", 12)
	blurb.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	card.add_child(blurb)

	var stat_names := ["POWER", "SPEED", "REACH"]
	for s in range(3):
		_add_stat_row(card, stat_names[s], f["stats"][s], f["color"], Vector2(50, 322 + s * 22))
	return card


func _add_stat_row(card: Panel, label: String, value: int, color: Color, pos: Vector2) -> void:
	var lbl := Label.new()
	lbl.text = label
	lbl.position = pos
	lbl.add_theme_font_size_override("font_size", 12)
	card.add_child(lbl)
	for i in range(5):
		var pip := ColorRect.new()
		pip.position = pos + Vector2(70 + i * 34, 4)
		pip.size = Vector2(28, 10)
		pip.color = color if i < value else Color(0.2, 0.2, 0.26)
		card.add_child(pip)


func _on_preview_finished(sprite: AnimatedSprite2D) -> void:
	if sprite.animation != "idle":
		sprite.play("idle")


func _refresh() -> void:
	for i in range(_cards.size()):
		var on1: bool = _cursor[0] == i
		var on2: bool = _cursor[1] == i
		var border := Color(0.35, 0.35, 0.45)
		if on1 and on2:
			border = GOLD
		elif on1:
			border = P1_COLOR
		elif on2:
			border = P2_COLOR
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.1, 0.1, 0.16, 0.95)
		st.border_color = border
		st.set_border_width_all(4 if (on1 or on2) else 2)
		st.set_corner_radius_all(10)
		_cards[i].add_theme_stylebox_override("panel", st)

		var txt := ""
		if on1:
			txt += "P1" + (" READY" if _locked[0] else "")
		if on2:
			txt += ("   " if txt != "" else "") + ("CPU" if _vs_cpu else "P2") + (" READY" if _locked[1] else "")
		_tags[i].text = txt
		_tags[i].add_theme_color_override("font_color", border)

	if _vs_cpu:
		_prompt.text = "Choose your opponent" if _locked[0] else "Player 1 - choose your fighter"
	else:
		_prompt.text = "Both players choose, then confirm"


func _unhandled_input(event: InputEvent) -> void:
	if _starting or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file(MENU_SCENE)
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
	elif event.is_action_pressed(right) and not _locked[who]:
		_cursor[who] = wrapi(_cursor[who] + 1, 0, FighterData.ROSTER.size())
	elif event.is_action_pressed(confirm) and not _locked[who]:
		_locked[who] = true
		_sprites[_cursor[who]].play("attack_3")
	elif event.is_action_pressed(cancel):
		if _locked[who]:
			_locked[who] = false
		elif _vs_cpu and who == 1:
			_locked[0] = false
	else:
		return
	_refresh()
	_check_start()


func _check_start() -> void:
	var ready_to_go: bool = _locked[0] and _locked[1]
	if not ready_to_go:
		return
	_starting = true
	var root := get_tree().root
	root.set_meta("local_mode", true)
	root.set_meta("p1_char", FighterData.ROSTER[_cursor[0]]["id"])
	root.set_meta("p2_char", FighterData.ROSTER[_cursor[1]]["id"])
	_prompt.text = "GET READY!"
	await get_tree().create_timer(0.9).timeout
	get_tree().change_scene_to_file(GAME_SCENE)
