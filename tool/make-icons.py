#!/usr/bin/env python3
"""Generates the Pi TV launcher icon (Android adaptive + legacy, web).

Charcoal background, flat teal outlined TV with a stand, filled teal play
mark (spec v0.11, /workspace/pi-tv-design/icon-charcoal-teal-tv.jpg).
Geometry is in the 108x108 adaptive-icon canvas; the screen and play mark
sit inside the 66-unit safe circle, so a mask that clips the stand still
leaves a readable TV. Re-run after changing the geometry:

    python3 tool/make-icons.py
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'apps', 'remote')
BG = (0x12, 0x14, 0x16, 255)
TEAL = (0x14, 0xB8, 0xA6, 255)

# --- geometry (108x108 canvas, centre 54,54) ---
SCREEN = (28, 33, 80, 65)  # outer box of the outlined screen
SCREEN_R = 7  # corner radius
STROKE = 4.5
NECK = (51.5, 65, 56.5, 71.5)
BASE = (40, 73.5, 68, 73.5)  # line from x0 to x1 at y, round caps
BASE_W = 4
PLAY = [(46.5, 38.5), (46.5, 59.5), (64, 49)]  # triangle (centred in the screen)
PLAY_R = 2.4  # rounded corners


def _inset_triangle(pts, r):
    (ax, ay), (bx, by), (cx, cy) = pts
    a = math.dist((bx, by), (cx, cy))
    b = math.dist((ax, ay), (cx, cy))
    c = math.dist((ax, ay), (bx, by))
    p = a + b + c
    ix, iy = (a * ax + b * bx + c * cx) / p, (a * ay + b * by + c * cy) / p
    s = p / 2
    area = math.sqrt(s * (s - a) * (s - b) * (s - c))
    inr = area / s
    k = (inr - r) / inr
    return [(ix + (x - ix) * k, iy + (y - iy) * k) for x, y in pts]


def _hull(points):
    pts = sorted(set(points))
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def rounded_triangle(pts, r, steps=48):
    """Triangle [pts] with corners rounded by [r] (hull of corner circles)."""
    inner = _inset_triangle(pts, r)
    ring = [(x + r * math.cos(2 * math.pi * k / steps), y + r * math.sin(2 * math.pi * k / steps))
            for x, y in inner for k in range(steps)]
    return _hull(ring)


def draw_foreground(size, color=TEAL, crop=(0, 0, 108, 108), ss=8):
    """Foreground layer at [size] px showing the [crop] region of the canvas."""
    big = size * ss
    x0, y0, x1, y1 = crop
    scale = big / (x1 - x0)
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def P(x, y):
        return ((x - x0) * scale, (y - y0) * scale)

    sx0, sy0, sx1, sy1 = SCREEN
    d.rounded_rectangle([P(sx0, sy0), P(sx1, sy1)], radius=SCREEN_R * scale, outline=color, width=round(STROKE * scale))
    d.rectangle([P(NECK[0], NECK[1]), P(NECK[2], NECK[3])], fill=color)
    bx0, by, bx1, _ = BASE
    hw = BASE_W / 2
    d.rounded_rectangle([P(bx0 - hw, by - hw), P(bx1 + hw, by + hw)], radius=hw * scale, fill=color)
    d.polygon([P(*q) for q in rounded_triangle(PLAY, PLAY_R)], fill=color)
    return img.resize((size, size), Image.LANCZOS)


def rounded_square(size, radius_frac=0.22, ss=8):
    big = size * ss
    m = Image.new('L', (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, big - 1, big - 1], radius=big * radius_frac, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def legacy_icon(size, full_bleed=False):
    """Square icon for pre-26 Android, the web manifest and the favicon."""
    bg = Image.new('RGBA', (size, size), BG)
    # Legacy icons show the central 72 of the 108 canvas (like a launcher mask).
    fg = draw_foreground(size, crop=(0, 0, 108, 108) if full_bleed else (18, 18, 90, 90))
    out = Image.alpha_composite(bg, fg)
    if not full_bleed:
        out.putalpha(rounded_square(size))
    return out


def main():
    res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    for name, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        d = os.path.join(res, f'mipmap-{name}')
        os.makedirs(d, exist_ok=True)
        legacy_icon(px).save(os.path.join(d, 'ic_launcher.png'))
        # Adaptive foreground as a bitmap too (some launchers rasterise it).
        draw_foreground(round(px * 108 / 48)).save(os.path.join(d, 'ic_launcher_foreground.png'))
    web = os.path.join(ROOT, 'web')
    legacy_icon(192).save(os.path.join(web, 'icons', 'Icon-192.png'))
    legacy_icon(512).save(os.path.join(web, 'icons', 'Icon-512.png'))
    legacy_icon(192, full_bleed=True).save(os.path.join(web, 'icons', 'Icon-maskable-192.png'))
    legacy_icon(512, full_bleed=True).save(os.path.join(web, 'icons', 'Icon-maskable-512.png'))
    legacy_icon(64).save(os.path.join(web, 'favicon.png'))
    # Preview sheet for review (not shipped).
    preview = Image.new('RGBA', (1180, 420), (40, 44, 48, 255))
    mask_circle = Image.new('L', (256, 256), 0)
    ImageDraw.Draw(mask_circle).ellipse([0, 0, 255, 255], fill=255)
    adaptive = Image.alpha_composite(Image.new('RGBA', (256, 256), BG), draw_foreground(256, crop=(18, 18, 90, 90)))
    circ = adaptive.copy()
    circ.putalpha(mask_circle)
    preview.alpha_composite(legacy_icon(256), (30, 30))
    preview.alpha_composite(circ, (316, 30))
    sq = adaptive.copy()
    sq.putalpha(rounded_square(256, 0.12))
    preview.alpha_composite(sq, (602, 30))
    for i, px in enumerate([96, 48, 32, 24]):
        preview.alpha_composite(legacy_icon(px), (888 + sum([96, 48, 32, 24][:i]) + i * 14, 300 - px))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'docs', 'icon-preview.png')
    preview.save(out)
    print('icons written; preview', os.path.normpath(out))


if __name__ == '__main__':
    main()
