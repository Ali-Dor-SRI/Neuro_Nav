"""Generate a 1024x1024 app icon for the Brainsight Monitor GUI.

Lightweight text-monogram icon: deep blue rounded square + white "Bs"
centered. Saves to icon.png next to this script. The build script then
converts that PNG to a Mac .icns via iconutil.

Usage:
    python3 generate_icon.py [output_path]

Requires Pillow. The build script `pip install pillow` first if missing.
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow not installed. Run:  python3 -m pip install pillow")
    sys.exit(1)


SIZE       = 1024
BG_TOP     = (28, 53, 110)     # deep blue
BG_BOTTOM  = (74, 116, 200)    # lighter blue
FG_COLOR   = (255, 255, 255)
TEXT       = "Bs"
CORNER_FRAC = 0.22   # rounded corner radius relative to SIZE


def _vertical_gradient(size, top, bottom):
    """Create a vertical gradient image."""
    img = Image.new("RGB", (size, size), top)
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return img


def _rounded_mask(size, corner_radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([(0, 0), (size, size)], radius=corner_radius, fill=255)
    return mask


def _load_font(target_height):
    """Try a couple of common bold fonts; fall back to default."""
    candidates = [
        # macOS
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/SFNS.ttf",
        "/Library/Fonts/Arial Bold.ttf",
        # Linux
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        # Windows (for dev)
        "C:/Windows/Fonts/arialbd.ttf",
        "C:/Windows/Fonts/segoeuib.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size=target_height)
            except OSError:
                continue
    return ImageFont.load_default()


def make_icon(path):
    # 1. Gradient background
    bg = _vertical_gradient(SIZE, BG_TOP, BG_BOTTOM)

    # 2. Round the corners
    rounded = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded.paste(bg, (0, 0), _rounded_mask(SIZE, int(SIZE * CORNER_FRAC)))

    # 3. Draw the monogram text
    draw = ImageDraw.Draw(rounded)
    # Target text height ~58% of icon size
    font = _load_font(int(SIZE * 0.58))
    # Center the text
    bbox = draw.textbbox((0, 0), TEXT, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (SIZE - tw) // 2 - bbox[0]
    y = (SIZE - th) // 2 - bbox[1] - int(SIZE * 0.03)
    draw.text((x, y), TEXT, fill=FG_COLOR, font=font)

    rounded.save(path, "PNG")
    print(f"Wrote {path} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "icon.png")
    make_icon(out)
