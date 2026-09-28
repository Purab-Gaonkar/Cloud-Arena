extends SceneTree

func _init():
	var dir = DirAccess.open("res://")
	if not dir.dir_exists("assets"):
		dir.make_dir("assets")
		
	generate_background()
	generate_platform()
	generate_player()
	
	print("Assets generated successfully.")
	quit()

func generate_background():
	var img = Image.create(1920, 1080, false, Image.FORMAT_RGBA8)
	for y in range(1080):
		var t = y / 1080.0
		var c = Color(
			lerpf(135.0/255.0, 25.0/255.0, t),
			lerpf(206.0/255.0, 25.0/255.0, t),
			lerpf(235.0/255.0, 112.0/255.0, t)
		)
		for x in range(1920):
			img.set_pixel(x, y, c)
			
	# Simple sun
	for y in range(100, 300):
		for x in range(200, 400):
			if Vector2(x, y).distance_to(Vector2(300, 200)) < 100:
				img.set_pixel(x, y, Color(1, 0.86, 0.39))
	
	img.save_png("res://assets/background.png")

func generate_platform():
	var img = Image.create(128, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.55, 0.27, 0.07)) # Dirt
	
	# Grass top
	for y in range(20):
		for x in range(128):
			img.set_pixel(x, y, Color(0.18, 0.8, 0.44))
			
	img.save_png("res://assets/platform.png")

func fill_rect(img, x, y, w, h, color):
	for i in range(w):
		for j in range(h):
			if x+i < img.get_width() and y+j < img.get_height():
				img.set_pixel(x+i, y+j, color)

func draw_knight(img, x_offset, y_offset, leg_offset=0, arm_offset=0):
	var body = Color(0.78, 0.78, 0.78)
	var visor = Color(0.12, 0.12, 0.12)
	var eye = Color(0, 1, 1)
	
	# Body
	fill_rect(img, x_offset+10, 12+y_offset, 12, 12, body)
	# Head
	fill_rect(img, x_offset+8, 4+y_offset, 16, 10, body)
	# Visor
	fill_rect(img, x_offset+16, 7+y_offset, 8, 3, visor)
	# Eye
	img.set_pixel(x_offset+20, 8+y_offset, eye)
	img.set_pixel(x_offset+21, 8+y_offset, eye)
	
	# Legs
	fill_rect(img, x_offset+12-leg_offset, 24+y_offset, 3, 6, body)
	fill_rect(img, x_offset+17+leg_offset, 24+y_offset, 3, 6, body)
	
	# Arms
	fill_rect(img, x_offset+14+arm_offset, 14+y_offset, 4, 8, body)

func generate_player():
	var img = Image.create(32 * 5, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0,0,0,0))
	
	# Frame 0: Idle
	draw_knight(img, 0 * 32, 2)
	
	# Frame 1: Run (legs apart)
	draw_knight(img, 1 * 32, 0, 3, 2)
	
	# Frame 2: Run (legs together)
	draw_knight(img, 2 * 32, 2, 0, -2)
	
	# Frame 3: Run (legs apart other way)
	draw_knight(img, 3 * 32, 0, -3, 2)
	
	# Frame 4: Run (legs together)
	draw_knight(img, 4 * 32, 2, 0, -2)

	img.save_png("res://assets/player_spritesheet.png")
