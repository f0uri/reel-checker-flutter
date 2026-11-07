#!/usr/bin/env python3
"""Generate Reel Checker launcher icons (gold ring + white play + gold check
badge on deep plum-black) for Android + iOS, from scratch.

The GitHub connector cannot push binary files, so the launcher PNGs are NOT
committed — this script regenerates them on the CI runner before the build.
Run from the project root:  python3 tools/make_icons.py
Requires Pillow:  pip install pillow
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BG = (26, 14, 30)        # deep plum-black
GOLD = (212, 175, 55)    # gold ring / badge
WHITE = (255, 255, 255)  # play triangle

ANDROID = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# (filename, pixel size) from ios/Runner/.../AppIcon.appiconset/Contents.json
IOS = [
    ("Icon-App-20x20@1x.png", 20),
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40),
    ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-76x76@1x.png", 76),
    ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167),
    ("Icon-App-1024x1024@1x.png", 1024),
]


def draw_icon(size):
    """Draw the icon at `size` px (RGB, no alpha — iOS forbids alpha)."""
    s = 1024  # draw big, downscale with LANCZOS for crisp edges
    im = Image.new("RGB", (s, s), BG)
    d = ImageDraw.Draw(im)
    r = int(s * 0.225)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=BG)
    # gold ring
    inset = int(s * 0.13)
    d.ellipse([inset, inset, s - inset, s - inset],
              outline=GOLD, width=int(s * 0.055))
    # white play triangle (slightly right of centre, inside the ring)
    d.polygon([(s * 0.40, s * 0.335), (s * 0.40, s * 0.665),
               (s * 0.665, s * 0.50)], fill=WHITE)
    # gold badge, bottom-right, overlapping the ring
    bcx, bcy, br = int(s * 0.76), int(s * 0.76), int(s * 0.135)
    d.ellipse([bcx - br, bcy - br, bcx + br, bcy + br], fill=GOLD)
    # dark check inside the badge
    w = max(6, int(s * 0.022))
    d.line([(bcx - br * 0.45, bcy), (bcx - br * 0.10, bcy + br * 0.38),
            (bcx + br * 0.50, bcy - br * 0.38)], fill=BG, width=w, joint="curve")
    if size != s:
        im = im.resize((size, size), Image.LANCZOS)
    return im


def main():
    for density, size in ANDROID.items():
        out = os.path.join(
            ROOT, "android", "app", "src", "main", "res",
            "mipmap-" + density, "ic_launcher.png")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        draw_icon(size).save(out, "PNG")
        print("wrote", out)

    appicon = os.path.join(
        ROOT, "ios", "Runner", "Assets.xcassets",
        "AppIcon.appiconset")
    for name, size in IOS:
        out = os.path.join(appicon, name)
        draw_icon(size).save(out, "PNG")
        print("wrote", out)

    launch = os.path.join(
        ROOT, "ios", "Runner", "Assets.xcassets",
        "LaunchImage.imageset")
    blank = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
    for name in ("LaunchImage.png", "LaunchImage@2x.png",
                 "LaunchImage@3x.png"):
        out = os.path.join(launch, name)
        blank.save(out, "PNG")
        print("wrote", out)


if __name__ == "__main__":
    main()
