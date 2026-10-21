#!/usr/bin/env python3
"""The game's icon: the campfire (Camp Fire Animation for RPGs, Zabin and
Jetrel, CC-BY-SA 3.0; art_src/lpc_env/CampFireFinished.png from
tools/art/fetch_lpc_env.sh) on a night square with a warm frame — pixel art
at 64 px, scaled without smoothing. Writes assets/icon/icon.png (256 px, the
project's), icon-<size>.png for the desktop menus and icon.ico for Windows.
Usage: tools/art/make_icon.py"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "art_src" / "lpc_env" / "CampFireFinished.png"
OUT = ROOT / "assets" / "icon"
N = 64
INK = (30, 24, 36, 255)
FRAME = (200, 160, 96, 255)
FRAME_DARK = (107, 84, 64, 255)


def base() -> Image.Image:
    img = Image.new("RGBA", (N, N))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, N - 1, N - 1), radius=10, fill=FRAME_DARK)
    d.rounded_rectangle((2, 2, N - 3, N - 3), radius=8, fill=FRAME)
    d.rounded_rectangle((4, 4, N - 5, N - 5), radius=6, fill=INK)
    # The night: darker at the top, a little warmer near the fire.
    for y in range(5, N - 5):
        t = (y - 5) / (N - 10)
        c = (int(22 + 30 * t), int(18 + 14 * t), int(40 + 6 * t), 255)
        for x in range(5, N - 5):
            if img.getpixel((x, y))[3] and img.getpixel((x, y)) == INK:
                img.putpixel((x, y), c)
    for x, y in [(12, 11), (20, 8), (47, 10), (53, 17), (9, 21), (40, 14), (29, 6)]:
        img.putpixel((x, y), (250, 240, 200, 255))
    # The ground the fire stands on.
    d.ellipse((12, 50, 52, 60), fill=(58, 40, 28, 255))
    fire = Image.open(SRC).convert("RGBA").crop((128, 0, 192, 64))  # its third frame: the fullest flame
    layer = Image.new("RGBA", (N, N))
    layer.alpha_composite(fire, (0, -4))
    inside = Image.new("L", (N, N))
    ImageDraw.Draw(inside).rounded_rectangle((5, 5, N - 6, N - 6), radius=5, fill=255)  # within the frame
    layer.putalpha(Image.composite(layer.getchannel("A"), Image.new("L", (N, N)), inside))
    img.alpha_composite(layer)
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    pix = base()
    for size in [16, 24, 32, 48, 64, 128, 256, 512]:
        pic = pix.resize((size, size), Image.NEAREST if size >= N else Image.LANCZOS)
        pic.save(OUT / ("icon-%d.png" % size))
    pix.resize((256, 256), Image.NEAREST).save(OUT / "icon.png")
    big = pix.resize((256, 256), Image.NEAREST)
    big.save(OUT / "icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print(OUT)


if __name__ == "__main__":
    main()
