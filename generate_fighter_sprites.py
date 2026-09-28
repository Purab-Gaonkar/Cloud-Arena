"""
generate_fighter_sprites.py
Generates high-quality martial artist spritesheets for Player 1 (Blue/Silver) and Player 2 (Red/Black)
with smooth 8-frame Idle, 8-frame Run, 8-frame Attack (roundhouse kick & punch combo), and Hurt frame.
"""
import os
import math
from PIL import Image, ImageDraw

FRAME_SIZE = 64  # High definition 64x64 sprites

def create_fighter_sheet(p1_colors=True):
    # Palette definition
    if p1_colors:
        # Player 1: Jin / Mishima style (Navy pants, white gi, silver hair/accents, cyan energy)
        c_pants = (30, 45, 80, 255)
        c_belt = (20, 20, 25, 255)
        c_skin = (235, 185, 150, 255)
        c_skin_shadow = (195, 140, 110, 255)
        c_hair = (40, 40, 50, 255)
        c_vest = (240, 240, 245, 255)
        c_gloves = (200, 30, 30, 255)      # Red MMA gloves
        c_flame = (50, 200, 255, 220)       # Cyan electric hit trail
    else:
        # Player 2: Kazuya style (Crimson/black pants, dark skin/shadow, spiked hair, violet energy)
        c_pants = (120, 20, 25, 255)
        c_belt = (15, 15, 15, 255)
        c_skin = (220, 170, 140, 255)
        c_skin_shadow = (180, 125, 95, 255)
        c_hair = (25, 20, 25, 255)
        c_vest = (35, 35, 40, 255)
        c_gloves = (240, 180, 20, 255)     # Gold/Yellow MMA gloves
        c_flame = (230, 50, 80, 220)       # Crimson energy hit trail

    # Animations:
    # Row 0: Idle (8 frames)
    # Row 1: Run (8 frames)
    # Row 2: Attack (8 frames - roundhouse kick & electric punch)
    # Row 3: Hurt / Flinch (4 frames)
    cols = 8
    rows = 4
    sheet = Image.new("RGBA", (cols * FRAME_SIZE, rows * FRAME_SIZE), (0, 0, 0, 0))

    def draw_fighter_frame(img, ox, oy, pose):
        draw = ImageDraw.Draw(img)
        
        # Base anchor coordinates in 64x64 frame
        cx = ox + 32
        cy = oy + 48 # Feet floor line
        
        bob = pose.get("bob", 0.0)
        lean = pose.get("lean", 0.0)
        leg_l_angle = pose.get("leg_l", 0.0)
        leg_r_angle = pose.get("leg_r", 0.0)
        arm_l_angle = pose.get("arm_l", 0.0)
        arm_r_angle = pose.get("arm_r", 0.0)
        kick_extend = pose.get("kick", 0.0)
        punch_extend = pose.get("punch", 0.0)
        energy_fx = pose.get("fx", False)

        # 1. Shadow under feet
        draw.ellipse([cx - 16, cy - 3, cx + 16, cy + 3], fill=(0, 0, 0, 80))

        # Pelvis position
        px = cx + lean * 0.5
        py = cy - 22 + bob

        # Chest / Torso position
        tx = px + lean
        ty = py - 14

        # Head position
        hx = tx + lean * 0.4
        hy = ty - 12

        # LEGS
        # Left Leg (Back)
        ll_knee_x = px - 4 + math.sin(leg_l_angle) * 10
        ll_knee_y = py + math.cos(leg_l_angle) * 11
        ll_foot_x = ll_knee_x + math.sin(leg_l_angle * 0.7) * 11
        ll_foot_y = ll_knee_y + math.cos(leg_l_angle * 0.7) * 11
        draw.line([px - 4, py, ll_knee_x, ll_knee_y], fill=c_pants, width=5)
        draw.line([ll_knee_x, ll_knee_y, ll_foot_x, ll_foot_y], fill=c_pants, width=4)
        draw.rectangle([ll_foot_x - 3, ll_foot_y - 2, ll_foot_x + 3, ll_foot_y + 2], fill=(20, 20, 25, 255))

        # TORSO (Muscular V-taper)
        torso_pts = [
            (tx - 9, ty - 6), (tx + 9, ty - 6), # Shoulders
            (tx + 7, ty + 6), (px + 6, py),     # Right ribs & hip
            (px - 6, py), (tx - 7, ty + 6)      # Left hip & ribs
        ]
        draw.polygon(torso_pts, fill=c_vest)
        # Chest line / muscle definition
        draw.line([tx, ty - 5, tx, ty + 4], fill=c_skin_shadow, width=2)
        draw.line([tx - 6, ty - 1, tx + 6, ty - 1], fill=c_skin_shadow, width=1)
        # Belt
        draw.rectangle([px - 6, py - 3, px + 6, py + 1], fill=c_belt)

        # HEAD & HAIR (Tekken spiked hair / headband)
        draw.ellipse([hx - 5, hy - 5, hx + 5, hy + 5], fill=c_skin)
        # Visor / Eye glow
        draw.rectangle([hx + 1, hy - 1, hx + 4, hy + 1], fill=(20, 20, 20, 255))
        draw.point([hx + 2, hy], fill=(255, 255, 255, 255))
        # Spiked hair
        hair_pts = [
            (hx - 5, hy - 2), (hx - 8, hy - 9), (hx - 3, hy - 7),
            (hx, hy - 11), (hx + 4, hy - 7), (hx + 7, hy - 9),
            (hx + 5, hy - 2)
        ]
        draw.polygon(hair_pts, fill=c_hair)

        # ARMS & ATTACKS
        # Left Arm (Back arm)
        la_hand_x = tx - 8 + math.sin(arm_l_angle) * 12
        la_hand_y = ty + math.cos(arm_l_angle) * 12
        draw.line([tx - 7, ty - 3, la_hand_x, la_hand_y], fill=c_skin, width=4)
        draw.ellipse([la_hand_x - 3, la_hand_y - 3, la_hand_x + 3, la_hand_y + 3], fill=c_gloves)

        # Right Leg (Front / Kicking leg)
        if kick_extend > 0.05:
            # Roundhouse high kick!
            rl_hip_x = px + 4
            rl_hip_y = py
            rl_knee_x = rl_hip_x + kick_extend * 18
            rl_knee_y = py - kick_extend * 14
            rl_foot_x = rl_knee_x + kick_extend * 18
            rl_foot_y = rl_knee_y - kick_extend * 6
            draw.line([rl_hip_x, rl_hip_y, rl_knee_x, rl_knee_y], fill=c_pants, width=6)
            draw.line([rl_knee_x, rl_knee_y, rl_foot_x, rl_foot_y], fill=c_pants, width=5)
            draw.rectangle([rl_foot_x - 2, rl_foot_y - 4, rl_foot_x + 4, rl_foot_y + 3], fill=(240, 240, 250, 255))
            
            # Kick swoosh trail
            draw.arc([rl_foot_x - 25, rl_foot_y - 15, rl_foot_x + 5, rl_foot_y + 25], 260, 40, fill=c_flame, width=4)
        else:
            rl_knee_x = px + 4 + math.sin(leg_r_angle) * 10
            rl_knee_y = py + math.cos(leg_r_angle) * 11
            rl_foot_x = rl_knee_x + math.sin(leg_r_angle * 0.7) * 11
            rl_foot_y = rl_knee_y + math.cos(leg_r_angle * 0.7) * 11
            draw.line([px + 4, py, rl_knee_x, rl_knee_y], fill=c_pants, width=5)
            draw.line([rl_knee_x, rl_knee_y, rl_foot_x, rl_foot_y], fill=c_pants, width=4)
            draw.rectangle([rl_foot_x - 3, rl_foot_y - 2, rl_foot_x + 3, rl_foot_y + 2], fill=(240, 240, 250, 255))

        # Right Arm (Front arm / Punching)
        if punch_extend > 0.05:
            # Straight devastating martial arts punch
            ra_hand_x = tx + 6 + punch_extend * 24
            ra_hand_y = ty - 2
            draw.line([tx + 7, ty - 3, tx + 14, ty - 1], fill=c_skin, width=4)
            draw.line([tx + 14, ty - 1, ra_hand_x, ra_hand_y], fill=c_skin, width=4)
            draw.ellipse([ra_hand_x - 4, ra_hand_y - 4, ra_hand_x + 4, ra_hand_y + 4], fill=c_gloves)
        else:
            ra_elbow_x = tx + 7 + math.sin(arm_r_angle) * 8
            ra_elbow_y = ty + math.cos(arm_r_angle) * 8
            ra_hand_x = ra_elbow_x + 4
            ra_hand_y = ra_elbow_y - 6
            draw.line([tx + 7, ty - 3, ra_elbow_x, ra_elbow_y], fill=c_skin, width=4)
            draw.line([ra_elbow_x, ra_elbow_y, ra_hand_x, ra_hand_y], fill=c_skin, width=4)
            draw.ellipse([ra_hand_x - 3, ra_hand_y - 3, ra_hand_x + 3, ra_hand_y + 3], fill=c_gloves)

        # Electric/Fiery impact aura on attack hits
        if energy_fx:
            for spark in range(6):
                ang = spark * (math.pi / 3) + bob
                sx = (ra_hand_x if punch_extend > 0.1 else rl_foot_x) + math.cos(ang) * 9
                sy = (ra_hand_y if punch_extend > 0.1 else rl_foot_y) + math.sin(ang) * 9
                draw.line([sx, sy, sx + math.cos(ang)*5, sy + math.sin(ang)*5], fill=c_flame, width=2)
                draw.point([sx, sy], fill=(255, 255, 255, 255))

    # --- ROW 0: IDLE (8 frames, rhythmic boxer bounce & breathing) ---
    for f in range(8):
        t = f / 8.0 * (math.pi * 2)
        pose = {
            "bob": math.sin(t) * 2.2,
            "lean": 1.0 + math.cos(t) * 0.5,
            "leg_l": -0.2 + math.sin(t) * 0.05,
            "leg_r": 0.35 + math.sin(t) * 0.05,
            "arm_l": 1.9 + math.sin(t) * 0.15,
            "arm_r": 1.7 + math.cos(t) * 0.15,
            "kick": 0.0,
            "punch": 0.0
        }
        draw_fighter_frame(sheet, f * FRAME_SIZE, 0 * FRAME_SIZE, pose)

    # --- ROW 1: RUN (8 frames, athletic forward sprint) ---
    for f in range(8):
        t = f / 8.0 * (math.pi * 2)
        leg_cycle = math.sin(t) * 0.85
        pose = {
            "bob": abs(math.sin(t * 2)) * -2.5,
            "lean": 5.0, # forward dash lean
            "leg_l": -leg_cycle,
            "leg_r": leg_cycle,
            "arm_l": 1.5 + leg_cycle * 0.8,
            "arm_r": 1.5 - leg_cycle * 0.8,
            "kick": 0.0,
            "punch": 0.0
        }
        draw_fighter_frame(sheet, f * FRAME_SIZE, 1 * FRAME_SIZE, pose)

    # --- ROW 2: ATTACK (8 frames, combo: windup, straight punch, roundhouse kick, recovery) ---
    attack_poses = [
        # Frame 0: Windup
        {"bob": 1.0, "lean": -2.0, "leg_l": -0.3, "leg_r": 0.4, "arm_l": 2.2, "arm_r": 2.4, "kick": 0.0, "punch": 0.0},
        # Frame 1: Step in punch start
        {"bob": 0.0, "lean": 3.0, "leg_l": -0.4, "leg_r": 0.2, "arm_l": 1.5, "arm_r": 1.8, "kick": 0.0, "punch": 0.5},
        # Frame 2: Heavy punch impact with electric spark!
        {"bob": -1.0, "lean": 6.0, "leg_l": -0.5, "leg_r": 0.3, "arm_l": 1.2, "arm_r": 1.5, "kick": 0.0, "punch": 1.0, "fx": True},
        # Frame 3: Transition & chamber kick
        {"bob": -2.0, "lean": 2.0, "leg_l": 0.0, "leg_r": 0.8, "arm_l": 2.0, "arm_r": 1.8, "kick": 0.3, "punch": 0.1},
        # Frame 4: FULL ROUNDHOUSE KICK EXTENSION (Hit Frame 2!)
        {"bob": -3.0, "lean": -3.0, "leg_l": -0.2, "leg_r": 1.5, "arm_l": 2.4, "arm_r": 1.2, "kick": 1.0, "punch": 0.0, "fx": True},
        # Frame 5: Kick follow-through
        {"bob": -1.0, "lean": -2.0, "leg_l": -0.2, "leg_r": 1.1, "arm_l": 2.2, "arm_r": 1.5, "kick": 0.7, "punch": 0.0},
        # Frame 6: Retract & spin
        {"bob": 1.0, "lean": 0.0, "leg_l": -0.3, "leg_r": 0.5, "arm_l": 1.9, "arm_r": 1.7, "kick": 0.2, "punch": 0.0},
        # Frame 7: Return to guard
        {"bob": 2.0, "lean": 1.0, "leg_l": -0.2, "leg_r": 0.4, "arm_l": 1.9, "arm_r": 1.7, "kick": 0.0, "punch": 0.0}
    ]
    for f in range(8):
        draw_fighter_frame(sheet, f * FRAME_SIZE, 2 * FRAME_SIZE, attack_poses[f])

    # --- ROW 3: HURT / HIT FLINCH (4 frames) ---
    hurt_poses = [
        {"bob": -2.0, "lean": -6.0, "leg_l": -0.4, "leg_r": 0.6, "arm_l": 0.5, "arm_r": 0.8, "kick": 0.0, "punch": 0.0},
        {"bob": -1.0, "lean": -8.0, "leg_l": -0.5, "leg_r": 0.5, "arm_l": 0.3, "arm_r": 0.5, "kick": 0.0, "punch": 0.0},
        {"bob": 1.0, "lean": -4.0, "leg_l": -0.3, "leg_r": 0.4, "arm_l": 1.2, "arm_r": 1.2, "kick": 0.0, "punch": 0.0},
        {"bob": 0.0, "lean": -1.0, "leg_l": -0.2, "leg_r": 0.3, "arm_l": 1.7, "arm_r": 1.6, "kick": 0.0, "punch": 0.0}
    ]
    for f in range(4):
        draw_fighter_frame(sheet, f * FRAME_SIZE, 3 * FRAME_SIZE, hurt_poses[f])

    return sheet

if __name__ == "__main__":
    out_dir = "e:/CloudArena/cloud-arena/assets"
    os.makedirs(out_dir, exist_ok=True)
    
    # Generate Player 1 (Blue/Silver)
    sheet_p1 = create_fighter_sheet(p1_colors=True)
    sheet_p1.save(os.path.join(out_dir, "fighter_p1.png"))
    print("Generated fighter_p1.png")

    # Generate Player 2 (Red/Crimson)
    sheet_p2 = create_fighter_sheet(p1_colors=False)
    sheet_p2.save(os.path.join(out_dir, "fighter_p2.png"))
    print("Generated fighter_p2.png")
