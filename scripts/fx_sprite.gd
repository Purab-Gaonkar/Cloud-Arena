## fx_sprite.gd -- One-shot (or looping) sprite-sheet effect that cleans itself up.
## Use FxSprite.spawn(parent, "slash_heavy", position, facing) from anywhere.
extends AnimatedSprite2D

const FighterData := preload("res://scripts/fighter_data.gd")

static var _shared_frames: SpriteFrames


static func spawn(parent: Node, fx_name: String, pos: Vector2, facing: int = 1, tint: Color = Color.WHITE, fx_scale: float = 1.0, lifetime: float = 0.0) -> AnimatedSprite2D:
	if _shared_frames == null:
		_shared_frames = FighterData.build_fx_frames()
	if not _shared_frames.has_animation(fx_name):
		return null
	var fx := (load("res://scripts/fx_sprite.gd") as GDScript).new() as AnimatedSprite2D
	fx.sprite_frames = _shared_frames
	fx.position = pos
	fx.flip_h = facing < 0
	fx.modulate = tint
	fx.scale = Vector2(fx_scale, fx_scale)
	fx.z_index = 30
	fx.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	parent.add_child(fx)
	fx.play(fx_name)
	if not _shared_frames.get_animation_loop(fx_name):
		fx.animation_finished.connect(fx.queue_free)
	elif lifetime > 0.0:
		# Looping effects (flames, speed lines) must be given a lifetime or they would never go away.
		var tw := fx.create_tween()
		tw.tween_property(fx, "modulate:a", 0.0, minf(0.2, lifetime * 0.4)).set_delay(lifetime * 0.6)
		tw.tween_callback(fx.queue_free)
	return fx
