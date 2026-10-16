## fighter_data.gd -- Roster definitions and sprite loading for the Craftpix fighters.
## Every sheet is a horizontal strip of 128x128 frames with the feet on the bottom edge.
extends RefCounted

const FRAME_SIZE: int    = 128
const BASE_DIR:   String = "res://assets/craftpix/"

## stats are 1-5 and only used by the character select screen.
const ROSTER: Array[Dictionary] = [
	{
		"id": "Fighter", "name": "BRAWLER", "color": Color(1.0, 0.62, 0.2),
		"speed": 330.0, "jump": -700.0, "damage": 1.0, "reach": 70.0, "atk_speed": 1.0,
		"stats": [3, 3, 3],
		"blurb": "Balanced all-rounder",
	},
	{
		"id": "Samurai", "name": "SAMURAI", "color": Color(0.85, 0.3, 0.35),
		"speed": 290.0, "jump": -660.0, "damage": 1.3, "reach": 100.0, "atk_speed": 1.12,
		"stats": [5, 2, 5],
		"blurb": "Slow but long, heavy blade",
	},
	{
		"id": "Shinobi", "name": "SHINOBI", "color": Color(0.35, 0.8, 1.0),
		"speed": 390.0, "jump": -760.0, "damage": 0.85, "reach": 85.0, "atk_speed": 0.85,
		"stats": [2, 5, 3],
		"blurb": "Lightning fast, light hits",
	},
]

## [animation, sheet file, fps, loops]
const ANIMS: Array = [
	["idle",     "Idle",     8.0,  true],
	["run",      "Run",      14.0, true],
	["jump",     "Jump",     14.0, false],
	["attack_1", "Attack_1", 14.0, false],
	["attack_2", "Attack_2", 14.0, false],
	["attack_3", "Attack_3", 14.0, false],
	["block",    "Shield",   12.0, false],
	["hit",      "Hurt",     12.0, false],
	["ko",       "Dead",     8.0,  false],
]


static func get_fighter(char_id: String) -> Dictionary:
	for f in ROSTER:
		if f["id"] == char_id:
			return f
	return ROSTER[0]


static func build_frames(char_id: String) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	for spec in ANIMS:
		var anim: String = spec[0]
		var sheet: Texture2D = load("%s%s/%s.png" % [BASE_DIR, char_id, spec[1]])
		if sheet == null:
			push_warning("[FighterData] Missing sheet %s/%s" % [char_id, spec[1]])
			continue
		frames.add_animation(anim)
		frames.set_animation_speed(anim, spec[2])
		frames.set_animation_loop(anim, spec[3])
		var count: int = sheet.get_width() / FRAME_SIZE
		for i in range(count):
			var atlas := AtlasTexture.new()
			atlas.atlas  = sheet
			atlas.region = Rect2(i * FRAME_SIZE, 0, FRAME_SIZE, FRAME_SIZE)
			frames.add_frame(anim, atlas)
	return frames
