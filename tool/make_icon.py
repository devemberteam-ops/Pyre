"""Generates the Pyre launcher icon.

Output:
  assets/icon/icon_foreground.png  (1024x1024 transparent — adaptive foreground)
  assets/icon/icon.png             (1024x1024 with background — legacy icon)

The art is a stylised teardrop flame: a circular base with a tapered top.
Generated parametrically with PIL polygons so no emoji font is needed.
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
EMBER_BG_DEEP = (11, 11, 15, 255)        # #0B0B0F
EMBER_PRIMARY = (255, 106, 61, 255)      # #FF6A3D
CREAM = (242, 237, 230, 255)             # #F2EDE6


def teardrop_points(cx, cy, w, h, segments=128):
    """Sample a teardrop pointing UP, centered at (cx, cy).

    Lower half is a circle of radius w/2; upper half tapers to a point
    h*0.5 above center via a quadratic curve from the circle's left/right
    apex up to the tip.
    """
    pts = []
    r = w / 2

    # Lower half — circle from rightmost (90°) clockwise through bottom (270°)
    # to leftmost (180°). Standard math angle 0=right going counter-clockwise,
    # but we want the lower semicircle.
    for i in range(segments // 2 + 1):
        t = i / (segments // 2)
        angle = math.pi * t       # 0 → π
        # Right apex (t=0) is (cx + r, cy). Bottom (t=0.5) is (cx, cy + r).
        # Left apex (t=1) is (cx - r, cy).
        x = cx + r * math.cos(angle)
        y = cy + r * math.sin(angle)
        pts.append((x, y))

    # Upper tapered side — from left apex (cx - r, cy) curving up to the
    # tip (cx, cy - h/2), then back down to the right apex (cx + r, cy).
    tip_y = cy - h / 2 + r * 0.1   # tip pulled slightly into the silhouette
    tip = (cx, tip_y)

    # Left side: quadratic Bezier from (cx - r, cy) via control point to tip
    ctrl_left = (cx - r * 0.55, cy - h * 0.25)
    for i in range(1, segments // 4 + 1):
        t = i / (segments // 4)
        x = (1 - t) ** 2 * (cx - r) + 2 * (1 - t) * t * ctrl_left[0] + t ** 2 * tip[0]
        y = (1 - t) ** 2 * cy + 2 * (1 - t) * t * ctrl_left[1] + t ** 2 * tip[1]
        pts.append((x, y))

    # Right side: tip back down to right apex
    ctrl_right = (cx + r * 0.55, cy - h * 0.25)
    for i in range(1, segments // 4 + 1):
        t = i / (segments // 4)
        x = (1 - t) ** 2 * tip[0] + 2 * (1 - t) * t * ctrl_right[0] + t ** 2 * (cx + r)
        y = (1 - t) ** 2 * tip[1] + 2 * (1 - t) * t * ctrl_right[1] + t ** 2 * cy
        pts.append((x, y))

    return pts


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, '..', 'assets', 'icon')
    os.makedirs(out_dir, exist_ok=True)

    cx = SIZE / 2
    cy = SIZE / 2 + SIZE * 0.08
    outer_w = SIZE * 0.55
    outer_h = SIZE * 0.78

    # --- adaptive foreground (transparent background) ---
    fg = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    d.polygon(teardrop_points(cx, cy, outer_w, outer_h), fill=EMBER_PRIMARY)
    # inner tongue — smaller flame, offset slightly toward base
    inner_w = outer_w * 0.42
    inner_h = outer_h * 0.50
    inner_cy = cy + SIZE * 0.06
    d.polygon(teardrop_points(cx, inner_cy, inner_w, inner_h), fill=CREAM)
    fg.save(os.path.join(out_dir, 'icon_foreground.png'))

    # --- full legacy icon: dark bg + radial glow + flame ---
    bg = Image.new('RGBA', (SIZE, SIZE), EMBER_BG_DEEP)
    glow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    halo_r = SIZE * 0.42
    gd.ellipse(
        [cx - halo_r, cy - halo_r, cx + halo_r, cy + halo_r],
        fill=(*EMBER_PRIMARY[:3], 80),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    bg = Image.alpha_composite(bg, glow)
    bg = Image.alpha_composite(bg, fg)
    bg.save(os.path.join(out_dir, 'icon.png'))

    print('Wrote', os.path.join(out_dir, 'icon.png'))
    print('Wrote', os.path.join(out_dir, 'icon_foreground.png'))


if __name__ == '__main__':
    main()
