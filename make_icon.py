#!/usr/bin/env python3
"""Turn artwork into logo.png on Apple's macOS icon grid.

Usage: make_icon.py <art> [--crop L,T,R,B]
(The current icon: make_icon.py icons/icon-art.webp --crop 101,85,1155,1139)
The art is cropped (optionally), cut to the macOS squircle and placed at
824 px on a transparent 1024 px canvas with a soft shadow, like system icons.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

N, BODY = 1024, 824


def squircle(size, n=5.0, scale=4):
    """Superellipse mask, close to Apple's continuous-corner icon shape."""
    s = size * scale
    m = Image.new("L", (s, s), 0)
    px = m.load()
    r = s / 2
    for y in range(s):
        dy = abs((y + 0.5 - r) / r) ** n
        if dy > 1:
            continue
        half = int(r * (1 - dy) ** (1 / n))
        for x in range(int(r - half), int(r + half)):
            px[x, y] = 255
    return m.resize((size, size), Image.LANCZOS)


def main():
    art = Image.open(sys.argv[1]).convert("RGBA")
    if "--crop" in sys.argv:
        box = tuple(int(v) for v in sys.argv[sys.argv.index("--crop") + 1].split(","))
        art = art.crop(box)
    art = art.resize((BODY, BODY), Image.LANCZOS)
    mask = squircle(BODY)
    if art.getchannel("A").getextrema() != (255, 255):
        # Art that already has transparency keeps its own shape.
        from PIL import ImageChops
        mask = ImageChops.multiply(mask, art.getchannel("A"))
    art.putalpha(mask)

    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    off = (N - BODY) // 2
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (off, off + 12), mask)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(art, (off, off))
    canvas.save("logo.png")


main()
