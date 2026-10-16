#!/usr/bin/env python3
"""gen_sprites.py -- builds the extra animation strips and FX sheets for CloudArena.

New fighter poses are DERIVED from the Craftpix sheets (lean / squash / stretch, motion smear,
glow outline, tinted after-images). FX sheets are DRAWN from scratch. Re-run after tweaking:

    python tools/gen_sprites.py [--preview preview.png]

Output: assets/generated/<Fighter>/{Heavy,Super_Windup,Super_Strike,Super_End}.png (128x128 frames)
        assets/generated/fx/*.png (frame sizes are listed in scripts/fighter_data.gd FX table)
Hand-drawn replacements can be dropped in with the same names/frame sizes.
"""
import argparse
import math
import os
import random

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC = os.path.join(ROOT, "assets", "craftpix")
OUT = os.path.join(ROOT, "assets", "generated")
F = 128  # fighter frame size
PIVOT = (64.0, 127.0)  # feet

COLORS = {
    "Fighter": (255, 158, 51),
    "Samurai": (217, 77, 89),
    "Shinobi": (89, 204, 255),
}


# ── Sheet helpers ───────────────────────────────────────────────────────────

_sheet_cache = {}


def frame(char, anim, idx):
    key = (char, anim)
    if key not in _sheet_cache:
        _sheet_cache[key] = Image.open(os.path.join(SRC, char, anim + ".png")).convert("RGBA")
    sheet = _sheet_cache[key]
    return sheet.crop((idx * F, 0, idx * F + F, F))


def pose(img, sx=1.0, sy=1.0, rot=0.0, dx=0.0, dy=0.0):
    """Scale/rotate about the feet, then translate. Rotation in degrees (positive = lean forward/right)."""
    th = math.radians(rot)
    c, s = math.cos(th), math.sin(th)
    R = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])
    S = np.array([[sx, 0, 0], [0, sy, 0], [0, 0, 1]])
    P = np.array([[1, 0, PIVOT[0]], [0, 1, PIVOT[1]], [0, 0, 1]])
    Pi = np.array([[1, 0, -PIVOT[0]], [0, 1, -PIVOT[1]], [0, 0, 1]])
    T = np.array([[1, 0, dx], [0, 1, dy], [0, 0, 1]])
    M = T @ P @ R @ S @ Pi
    Mi = np.linalg.inv(M)
    return img.transform((F, F), Image.AFFINE, (Mi[0, 0], Mi[0, 1], Mi[0, 2], Mi[1, 0], Mi[1, 1], Mi[1, 2]), resample=Image.NEAREST)


def tint(img, color, amount):
    """Blend visible pixels toward `color` by `amount` (0-1) keeping alpha."""
    r, g, b, a = img.split()
    solid = Image.new("RGBA", img.size, color + (255,))
    mixed = Image.blend(img.convert("RGBA"), solid, amount)
    mixed.putalpha(a)
    return mixed


def fade(img, alpha):
    r, g, b, a = img.split()
    a = a.point(lambda v: int(v * alpha))
    out = img.copy()
    out.putalpha(a)
    return out


def glow(img, color, radius=4, strength=0.9):
    a = img.split()[3]
    grown = a.filter(ImageFilter.MaxFilter(radius * 2 + 1)).filter(ImageFilter.GaussianBlur(radius * 0.6))
    layer = Image.new("RGBA", img.size, color + (0,))
    layer.putalpha(grown.point(lambda v: int(min(255, v * strength))))
    out = Image.alpha_composite(layer, img)
    return out


def shift(img, ox, oy):
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (ox, oy))
    return out


def smear(img, color, offsets, alphas, tint_amt=0.7):
    """Trail of tinted ghost copies behind the sprite (offsets are (dx, dy))."""
    base = Image.new("RGBA", img.size, (0, 0, 0, 0))
    for (ox, oy), al in zip(offsets, alphas):
        ghost = fade(tint(shift(img, int(ox), int(oy)), color, tint_amt), al)
        base = Image.alpha_composite(base, ghost)
    return Image.alpha_composite(base, img)


def strip(frames, w=F, h=F):
    sheet = Image.new("RGBA", (w * len(frames), h), (0, 0, 0, 0))
    for i, fr in enumerate(frames):
        sheet.paste(fr, (i * w, 0))
    return sheet


# ── Fighter recipes ─────────────────────────────────────────────────────────
# (sheet, frame index) picks, chosen by eye from the Craftpix strips.

RECIPES = {
    "Fighter": {
        "wind":   ("Attack_3", 0),
        "strike": [("Attack_3", 2), ("Attack_3", 3), ("Attack_3", 3)],
        "super":  [("Attack_1", 3), ("Attack_2", 2), ("Attack_1", 3), ("Attack_2", 2), ("Attack_3", 2), ("Attack_3", 3)],
        "super_wind": ("Attack_3", 0),
    },
    "Samurai": {
        "wind":   ("Attack_3", 0),
        "strike": [("Attack_3", 1), ("Attack_3", 2), ("Attack_3", 2)],
        "super":  [("Attack_2", 0), ("Attack_1", 4), ("Attack_1", 5), ("Attack_2", 2), ("Attack_3", 1), ("Attack_3", 2)],
        "super_wind": ("Attack_2", 0),
    },
    "Shinobi": {
        "wind":   ("Attack_3", 0),
        "strike": [("Attack_3", 2), ("Attack_3", 3), ("Attack_3", 3)],
        "super":  [("Attack_3", 2), ("Attack_1", 3), ("Attack_2", 1), ("Attack_3", 3), ("Attack_1", 4), ("Attack_2", 2)],
        "super_wind": ("Attack_1", 0),
    },
}


def make_heavy(char):
    col = COLORS[char]
    rc = RECIPES[char]
    w = frame(char, *rc["wind"])
    out = []
    # Wind-up: lean back and crouch
    out.append(pose(w, sy=0.96, rot=-4, dx=-3))
    out.append(pose(w, sy=0.92, rot=-8, dx=-6))
    # Charge: held, glowing and growing brighter
    for i, g in enumerate([0.35, 0.6, 0.9]):
        f = pose(w, sy=0.9, rot=-9, dx=-7 + (i % 2))
        out.append(glow(tint(f, col, 0.12 * i), col, 3 + i * 2, g))
    # Strike: lunge with smear
    s = [frame(char, a, i) for a, i in rc["strike"]]
    f1 = pose(s[0], sx=1.06, rot=4, dx=8)
    out.append(smear(glow(f1, col, 3, 0.7), col, [(-14, 0), (-28, 0)], [0.45, 0.22]))
    f2 = pose(s[1], sx=1.1, rot=3, dx=14)
    out.append(smear(glow(f2, (255, 255, 255), 3, 0.6), col, [(-18, 0), (-36, 0)], [0.4, 0.2]))
    f3 = pose(s[2], sx=1.05, rot=1, dx=10)
    out.append(smear(f3, col, [(-10, 0)], [0.25]))
    # Recovery
    out.append(pose(s[2], rot=0, dx=4))
    out.append(frame(char, "Idle", 0))
    return strip(out)


def make_super_windup(char):
    col = COLORS[char]
    rc = RECIPES[char]
    base = frame(char, *rc["super_wind"])
    out = []
    for i in range(4):
        k = (i + 1) / 4.0
        f = pose(base, sy=1.0 - 0.07 * k, rot=-3 - 5 * k, dx=-2 - 4 * k)
        f = glow(tint(f, col, 0.1 * k), col, 3 + i * 2, 0.55 + 0.1 * i)
        out.append(f)
    return strip(out)


def make_super_strike(char):
    col = COLORS[char]
    rc = RECIPES[char]
    out = []
    for i, (a, idx) in enumerate(rc["super"]):
        f = frame(char, a, idx)
        dx = 6 + 4 * (i % 3)
        f = pose(f, sx=1.08, rot=2 + (i % 2) * 2, dx=dx)
        if char == "Shinobi":
            f = tint(f, (70, 30, 120), 0.35)
            f = smear(f, col, [(-22, 0), (-44, 0), (22, 0)], [0.5, 0.3, 0.3], 0.8)
        elif char == "Samurai":
            f = smear(glow(f, (255, 255, 255), 3, 0.7), col, [(-18, 0), (-36, 0), (-54, 0)], [0.55, 0.35, 0.18], 0.85)
        else:
            f = smear(glow(f, col, 4, 0.8), col, [(-14, 0), (-28, 0)], [0.5, 0.28], 0.8)
        out.append(f)
    return strip(out)


def make_super_end(char):
    col = COLORS[char]
    rc = RECIPES[char]
    last = frame(char, *rc["super"][-1])
    idle = frame(char, "Idle", 0)
    out = [glow(pose(last, rot=1, dx=6), col, 5, 0.6), glow(pose(last, rot=0, dx=3), col, 3, 0.35), idle]
    return strip(out)


# ── FX drawing (supersampled for clean edges) ───────────────────────────────

SS = 4


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def finish(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def crescent(draw, cx, cy, r, a_from, a_to, thick, color):
    steps = 36
    pts_out, pts_in = [], []
    for i in range(steps + 1):
        t = i / steps
        ang = math.radians(a_from + (a_to - a_from) * t)
        th = thick * math.sin(math.pi * t) ** 0.8
        pts_out.append((cx + math.cos(ang) * r, cy + math.sin(ang) * r))
        pts_in.append((cx + math.cos(ang) * (r - th), cy + math.sin(ang) * (r - th)))
    draw.polygon(pts_out + pts_in[::-1], fill=color)


def fx_slash(size, frames, radius, thick, core, rim, span=150, a0=-70):
    out = []
    for f in range(frames):
        im = canvas(size, size)
        d = ImageDraw.Draw(im)
        t = (f + 1) / frames
        head = a0 + span * min(1.0, t * 1.3)
        tail = a0 + span * max(0.0, t * 1.3 - 0.75)
        alpha = int(255 * (1.0 - max(0.0, t - 0.55) / 0.45))
        c = SS
        for scale, col in ((1.0, rim + (int(alpha * 0.7),)), (0.55, core + (alpha,))):
            crescent(d, size * c * 0.28, size * c * 0.5, radius * c * (1.0 + (1 - scale) * 0.04), tail, head, thick * c * scale, col)
        out.append(finish(im, size, size))
    return strip(out, size, size)


def fx_shockwave(w, h, frames):
    out = []
    for f in range(frames):
        im = canvas(w, h)
        d = ImageDraw.Draw(im)
        t = (f + 1) / frames
        rx, ry = w * 0.46 * t * SS, h * 0.42 * t * SS
        a = int(255 * (1 - t) ** 0.8)
        cx, cy = w * SS / 2, h * SS * 0.7
        for k, (wd, col) in enumerate(((10, (255, 200, 120)), (5, (255, 255, 255)))):
            d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], outline=col + (a,), width=wd * SS // 2)
        out.append(finish(im, w, h))
    return strip(out, w, h)


def fx_burst(size, frames, rays=10, colors=((255, 240, 150), (255, 140, 60))):
    out = []
    rng = random.Random(7)
    angs = [i * 2 * math.pi / rays + rng.uniform(-0.15, 0.15) for i in range(rays)]
    lens = [rng.uniform(0.7, 1.0) for _ in range(rays)]
    for f in range(frames):
        im = canvas(size, size)
        d = ImageDraw.Draw(im)
        t = (f + 1) / frames
        c = size * SS / 2
        a = int(255 * (1 - t ** 1.6))
        grow = 0.25 + 0.75 * math.sin(min(1.0, t * 1.4) * math.pi / 2)
        for ang, ln in zip(angs, lens):
            r1 = size * SS * 0.5 * grow * ln
            r0 = r1 * (0.25 + 0.6 * t)
            w0 = size * SS * 0.035 * (1 - t * 0.6)
            px, py = -math.sin(ang), math.cos(ang)
            pts = [(c + math.cos(ang) * r0 + px * w0, c + math.sin(ang) * r0 + py * w0),
                   (c + math.cos(ang) * r1, c + math.sin(ang) * r1),
                   (c + math.cos(ang) * r0 - px * w0, c + math.sin(ang) * r0 - py * w0)]
            d.polygon(pts, fill=colors[1] + (a,))
        rc_ = size * SS * 0.16 * (1 - t * 0.5)
        d.ellipse([c - rc_, c - rc_, c + rc_, c + rc_], fill=colors[0] + (a,))
        d.ellipse([c - rc_ * 0.55, c - rc_ * 0.55, c + rc_ * 0.55, c + rc_ * 0.55], fill=(255, 255, 255, a))
        out.append(finish(im, size, size))
    return strip(out, size, size)


def fx_block(size, frames):
    out = []
    for f in range(frames):
        im = canvas(size, size)
        d = ImageDraw.Draw(im)
        t = (f + 1) / frames
        c = size * SS / 2
        a = int(255 * (1 - t))
        r = size * SS * (0.18 + 0.28 * t)
        hexp = [(c + math.cos(math.radians(60 * i + 30)) * r, c + math.sin(math.radians(60 * i + 30)) * r) for i in range(6)]
        d.polygon(hexp, outline=(160, 230, 255, a), fill=(100, 190, 255, int(a * 0.25)))
        d.line(hexp + [hexp[0]], fill=(255, 255, 255, a), width=3 * SS)
        for i in range(8):
            ang = i * math.pi / 4 + 0.2
            d.line([(c + math.cos(ang) * r * 1.1, c + math.sin(ang) * r * 1.1), (c + math.cos(ang) * r * 1.55, c + math.sin(ang) * r * 1.55)], fill=(200, 240, 255, a), width=2 * SS)
        out.append(finish(im, size, size))
    return strip(out, size, size)


def fx_aura(w, h, frames):
    out = []
    rng = random.Random(3)
    wisps = [(rng.uniform(0.15, 0.85), rng.uniform(0.0, 1.0), rng.uniform(0.7, 1.4)) for _ in range(9)]
    for f in range(frames):
        im = canvas(w, h)
        d = ImageDraw.Draw(im)
        ph = f / frames
        for x0, p0, sp in wisps:
            t = (p0 + ph * sp) % 1.0
            cx = (x0 + 0.08 * math.sin(t * 6.28 + x0 * 9)) * w * SS
            cy = (1.0 - t) * h * SS * 0.95
            r = w * SS * 0.13 * (1 - t * 0.7)
            a = int(230 * math.sin(math.pi * t))
            d.polygon([(cx, cy - r * 3.2), (cx + r * 0.9, cy), (cx + r * 0.5, cy + r * 1.2), (cx - r * 0.5, cy + r * 1.2), (cx - r * 0.9, cy)], fill=(255, 200, 110, a))
            d.polygon([(cx, cy - r * 2.0), (cx + r * 0.45, cy), (cx, cy + r * 0.8), (cx - r * 0.45, cy)], fill=(255, 250, 220, a))
        out.append(finish(im, w, h))
    return strip(out, w, h)


def fx_speed(w, h, frames):
    out = []
    rng = random.Random(5)
    lines = [(rng.uniform(0, 1), rng.uniform(0.15, 0.6), rng.uniform(0.6, 1.5)) for _ in range(14)]
    for f in range(frames):
        im = canvas(w, h)
        d = ImageDraw.Draw(im)
        ph = f / frames
        for y0, ln, sp in lines:
            x = ((ph * sp + y0 * 3) % 1.0)
            x1 = x * w * SS
            d.line([(x1, y0 * h * SS), (x1 - ln * w * SS, y0 * h * SS)], fill=(255, 255, 255, 190), width=int(2.5 * SS))
        out.append(finish(im, w, h))
    return strip(out, w, h)


def fx_dust(size, frames):
    out = []
    rng = random.Random(11)
    puffs = [(rng.uniform(-1, 1), rng.uniform(0.6, 1.2)) for _ in range(6)]
    for f in range(frames):
        im = canvas(size, size)
        d = ImageDraw.Draw(im)
        t = (f + 1) / frames
        c = size * SS / 2
        for ox, sc in puffs:
            r = size * SS * (0.07 + 0.12 * t) * sc
            x = c + ox * size * SS * 0.38 * t
            y = size * SS * 0.78 - size * SS * 0.1 * t * sc
            d.ellipse([x - r, y - r, x + r, y + r], fill=(235, 225, 210, int(200 * (1 - t))))
        out.append(finish(im, size, size))
    return strip(out, size, size)


def fx_flash(size, frames, rays=14, rotate=0.0, white=True):
    out = []
    for f in range(frames):
        im = canvas(size, size)
        d = ImageDraw.Draw(im)
        t = (f + 1) / frames
        c = size * SS / 2
        a = int(255 * (1 - t ** 2))
        r = size * SS * 0.5 * (0.3 + 0.7 * t)
        for i in range(rays):
            ang = i * 2 * math.pi / rays + rotate * t
            wdt = 0.07 + 0.03 * ((i % 2))
            d.polygon([(c, c), (c + math.cos(ang - wdt) * r, c + math.sin(ang - wdt) * r), (c + math.cos(ang + wdt) * r, c + math.sin(ang + wdt) * r)],
                      fill=(255, 255, 255, int(a * 0.8)) if white else (255, 220, 120, int(a * 0.8)))
        rr = r * 0.35 * (1 - t)
        d.ellipse([c - rr, c - rr, c + rr, c + rr], fill=(255, 255, 255, a))
        out.append(finish(im, size, size))
    return strip(out, size, size)


# ── Main ────────────────────────────────────────────────────────────────────

def save(img, *path):
    full = os.path.join(OUT, *path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    img.save(full)
    return full


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="write a contact sheet PNG of everything generated")
    args = ap.parse_args()
    rows = []

    for char in COLORS:
        for name, fn in (("Heavy", make_heavy), ("Super_Windup", make_super_windup), ("Super_Strike", make_super_strike), ("Super_End", make_super_end)):
            img = fn(char)
            save(img, char, name + ".png")
            rows.append(img)
            print("wrote", char, name, img.size)

    fx = {
        "slash_light":  fx_slash(128, 4, 56, 22, (255, 255, 255), (150, 210, 255)),
        "slash_heavy":  fx_slash(192, 5, 86, 38, (255, 255, 230), (255, 150, 60), span=170, a0=-85),
        "shockwave":    fx_shockwave(192, 96, 6),
        "impact_burst": fx_burst(128, 5),
        "block_spark":  fx_block(96, 4),
        "aura_flame":   fx_aura(96, 128, 6),
        "speed_lines":  fx_speed(256, 128, 4),
        "dust":         fx_dust(64, 5),
        "ko_flash":     fx_flash(256, 5, rays=18, rotate=0.4),
        "super_flash":  fx_flash(256, 5, rays=12, rotate=-0.8, white=False),
    }
    for name, img in fx.items():
        save(img, "fx", name + ".png")
        rows.append(img)
        print("wrote fx", name, img.size)

    if args.preview:
        wmax = max(r.width for r in rows)
        sheet = Image.new("RGBA", (wmax, sum(r.height + 6 for r in rows)), (60, 70, 90, 255))
        y = 0
        for r in rows:
            sheet.alpha_composite(r, (0, y))
            y += r.height + 6
        sheet.save(args.preview)
        print("preview", args.preview, sheet.size)


if __name__ == "__main__":
    main()
