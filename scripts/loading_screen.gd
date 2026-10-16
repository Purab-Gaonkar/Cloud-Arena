## loading_screen.gd -- Boot splash: preloads fighter sheets and scenes while a ninja runs along a progress bar.
extends Control

const UiStyle     := preload("res://scripts/ui_style.gd")
const FighterData := preload("res://scripts/fighter_data.gd")
const WorldBuilder := preload("res://scripts/world_builder.gd")

const NEXT_SCENE: String = "res://scenes/main.tscn"
const BAR_W: float = 640.0
const MIN_LOAD_SECONDS: float = 2.4

const TIPS: Array[String] = [
	"TAP ATTACK THREE TIMES FOR A FULL COMBO",
	"HOLD BLOCK TO TAKE ONLY CHIP DAMAGE - BUT BLOCK FACING YOUR ENEMY",
	"SAMURAI REACHES FARTHEST, SHINOBI HITS FASTEST",
	"THE THIRD HIT OF A COMBO LAUNCHES YOUR OPPONENT",
	"WIN TWO ROUNDS TO TAKE THE MATCH",
]

var _paths: PackedStringArray = []
var _shown: float = 0.0
var _hold: float = 0.0
var _leaving: bool = false

var _fill: ColorRect
var _runner: AnimatedSprite2D
var _percent: Label
var _bar_y: float = 600.0


func _ready() -> void:
	# Dedicated servers skip straight to the menu script, which auto-hosts.
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		get_tree().change_scene_to_file(NEXT_SCENE)
		return
	_build_ui()
	_queue_loads()


func _queue_loads() -> void:
	for f in FighterData.ROSTER:
		for spec in FighterData.ANIMS:
			_paths.append("%s%s/%s.png" % [FighterData.BASE_DIR, f["id"], spec[1]])
	for p in _paths:
		ResourceLoader.load_threaded_request(p)


func _build_ui() -> void:
	var world := WorldBuilder.new()
	world.position = Vector2(640, 650.0 - WorldBuilder.GROUND_Y)
	add_child(world)
	world.build(randi() % WorldBuilder.stage_count())

	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.01, 0.06, 0.45)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)

	var sub := UiStyle.label("THE  CLOUD-POWERED  ARENA  FIGHTER", 22, UiStyle.GOLD, true, 6)
	sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub.position = Vector2(-300, 120)
	sub.size = Vector2(600, 30)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(sub)

	var title := UiStyle.label("CLOUD ARENA", 132, Color.WHITE, true, 20)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.position = Vector2(-420, 150)
	title.size = Vector2(840, 150)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.55))
	title.add_theme_constant_override("shadow_offset_x", 8)
	title.add_theme_constant_override("shadow_offset_y", 8)
	title.pivot_offset = Vector2(420, 75)
	add_child(title)
	for n in [sub, title]:
		n.modulate.a = 0.0
	title.scale = Vector2(1.25, 1.25)
	var intro := create_tween().set_parallel(true)
	intro.tween_property(title, "modulate:a", 1.0, 0.7)
	intro.tween_property(title, "scale", Vector2.ONE, 0.9).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	intro.tween_property(sub, "modulate:a", 1.0, 0.9).set_delay(0.5)

	# Progress bar
	var bar := Panel.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bar.position = Vector2(-BAR_W * 0.5, _bar_y)
	bar.size = Vector2(BAR_W, 26)
	bar.clip_contents = true
	bar.add_theme_stylebox_override("panel", UiStyle.box(Color(0.05, 0.04, 0.1, 0.92), UiStyle.GOLD, 3, 13))
	add_child(bar)
	_fill = ColorRect.new()
	_fill.color = UiStyle.GOLD
	_fill.position = Vector2(3, 3)
	_fill.size = Vector2(0, 20)
	bar.add_child(_fill)

	_runner = AnimatedSprite2D.new()
	_runner.sprite_frames = FighterData.build_frames("Shinobi")
	_runner.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_runner.scale = Vector2(1.5, 1.5)
	_runner.z_index = 5
	_runner.play("run")
	add_child(_runner)

	_percent = UiStyle.label("LOADING  0%", 24, UiStyle.TEXT, true, 6)
	_percent.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_percent.position = Vector2(-300, _bar_y + 36)
	_percent.size = Vector2(600, 30)
	_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_percent)

	var tip := UiStyle.label(TIPS[randi() % TIPS.size()], 16, UiStyle.MUTED, false, 5)
	tip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	tip.position = Vector2(-400, _bar_y + 74)
	tip.size = Vector2(800, 24)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(tip)


func _process(delta: float) -> void:
	if _paths.is_empty() or _leaving:
		return
	var total := 0.0
	for p in _paths:
		var prog: Array = []
		var st := ResourceLoader.load_threaded_get_status(p, prog)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			total += float(prog[0])
		else:
			total += 1.0
	var target := total / _paths.size()
	_shown = move_toward(_shown, target, delta / MIN_LOAD_SECONDS)

	var center_x := size.x * 0.5
	var fill_w := (BAR_W - 6.0) * _shown
	_fill.size.x = fill_w
	_runner.position = Vector2(center_x - BAR_W * 0.5 + 3.0 + fill_w, _bar_y - 8.0 - 63.5 * 1.5)
	_percent.text = "LOADING  %d%%" % int(_shown * 100.0)

	if _shown >= 1.0:
		_hold += delta
		if _hold > 0.45:
			_leaving = true
			_percent.text = "READY!"
			Transition.go(NEXT_SCENE)
