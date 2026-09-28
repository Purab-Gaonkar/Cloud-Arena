import os
from PIL import Image, ImageDraw
import math

def generate_background(path):
    width, height = 1920, 1080
    img = Image.new('RGB', (width, height))
    draw = ImageDraw.Draw(img)

    # Gradient Sky
    for y in range(height):
        r = int(135 + (25 - 135) * (y / height))
        g = int(206 + (25 - 206) * (y / height))
        b = int(235 + (112 - 235) * (y / height))
        draw.line([(0, y), (width, y)], fill=(r, g, b))

    # Sun
    draw.ellipse([200, 100, 400, 300], fill=(255, 220, 100))

    # Distant Mountains (Dark Blue)
    mountain_points = [(0, 1080), (0, 700), (300, 500), (700, 800), (1200, 400), (1600, 750), (1920, 500), (1920, 1080)]
    draw.polygon(mountain_points, fill=(44, 62, 80))

    # Front Mountains (Green)
    mountain_points_2 = [(0, 1080), (0, 900), (400, 700), (800, 950), (1400, 600), (1920, 800), (1920, 1080)]
    draw.polygon(mountain_points_2, fill=(39, 174, 96))

    img.save(path)

def generate_platform(path):
    width, height = 128, 128
    img = Image.new('RGB', (width, height), color=(139, 69, 19))
    draw = ImageDraw.Draw(img)
    
    # Dirt pattern
    import random
    random.seed(42)
    for _ in range(200):
        x, y = random.randint(0, width), random.randint(30, height)
        draw.point((x, y), fill=(101, 67, 33))

    # Grass top
    draw.rectangle([0, 0, width, 20], fill=(46, 204, 113))
    
    # Grass blades extending down
    for i in range(0, width, 8):
        h = random.randint(20, 35)
        draw.polygon([(i, 20), (i+4, h), (i+8, 20)], fill=(46, 204, 113))

    img.save(path)

def generate_player(path):
    frame_w, frame_h = 32, 32
    frames = 5 # 1 idle, 4 run
    img = Image.new('RGBA', (frame_w * frames, frame_h), color=(0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    color_body = (200, 200, 200, 255) # Knight armor
    color_visor = (30, 30, 30, 255)
    color_eye = (0, 255, 255, 255)
    
    def draw_knight(draw, x_offset, y_offset, leg_offset=0, arm_offset=0):
        # Body
        draw.rectangle([x_offset+10, 12+y_offset, x_offset+22, 24+y_offset], fill=color_body)
        # Head
        draw.rectangle([x_offset+8, 4+y_offset, x_offset+24, 14+y_offset], fill=color_body)
        # Visor slit
        draw.rectangle([x_offset+16, 7+y_offset, x_offset+24, 10+y_offset], fill=color_visor)
        # Eye
        draw.point((x_offset+20, 8+y_offset), fill=color_eye)
        draw.point((x_offset+21, 8+y_offset), fill=color_eye)
        
        # Legs
        draw.rectangle([x_offset+12-leg_offset, 24+y_offset, x_offset+15-leg_offset, 30+y_offset], fill=color_body)
        draw.rectangle([x_offset+17+leg_offset, 24+y_offset, x_offset+20+leg_offset, 30+y_offset], fill=color_body)
        
        # Arms
        draw.rectangle([x_offset+14+arm_offset, 14+y_offset, x_offset+18+arm_offset, 22+y_offset], fill=color_body)
    
    # Frame 0: Idle
    draw_knight(draw, 0 * 32, 2)
    
    # Frame 1: Run (legs apart)
    draw_knight(draw, 1 * 32, 0, leg_offset=3, arm_offset=2)
    
    # Frame 2: Run (legs together)
    draw_knight(draw, 2 * 32, 2, leg_offset=0, arm_offset=-2)
    
    # Frame 3: Run (legs apart other way)
    draw_knight(draw, 3 * 32, 0, leg_offset=-3, arm_offset=2)
    
    # Frame 4: Run (legs together)
    draw_knight(draw, 4 * 32, 2, leg_offset=0, arm_offset=-2)

    img.save(path)

os.makedirs("e:/CloudArena/cloud-arena/assets", exist_ok=True)
generate_background("e:/CloudArena/cloud-arena/assets/background.png")
generate_platform("e:/CloudArena/cloud-arena/assets/platform.png")
generate_player("e:/CloudArena/cloud-arena/assets/player.png")
print("Assets generated successfully.")
