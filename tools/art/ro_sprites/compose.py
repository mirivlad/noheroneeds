"""Put layers together into character frames by their depth maps (python3 + Pillow + numpy).

Every layer was rendered alone over the invisible body (render.py), so a pixel
of a layer is a pixel that shows on the body; where layers overlap, the nearer
one wins (the brighter depth). The body layer takes its drawn face
(face2d.py) on top. Cells of different sizes are lined up by their ground
point; the frame is as large as the largest cell. A layer without frames for a
clip (a held thing in a swing that is not its own) is left out of that clip.

Usage: python3 compose.py BUILD_DIR OUT_DIR (--outfit NAME | --layers body linen_shirt ...)
       [--clips idle walk ...]
BUILD_DIR holds pixels/<layer>/ and face/body/ (build.sh).
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gear  # noqa: E402
from clips import CLIPS  # noqa: E402

DIRECTIONS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("build")
	ap.add_argument("out")
	ap.add_argument("--outfit")
	ap.add_argument("--layers", nargs="+")
	ap.add_argument("--clips", nargs="+", default=list(CLIPS))
	a = ap.parse_args()
	layers = gear.OUTFITS[a.outfit] if a.outfit else a.layers
	os.makedirs(a.out, exist_ok=True)
	cell = max(gear.cell_of(layer)[0] for layer in layers)
	foot = gear.FOOT + (cell - gear.CELL) // 2
	for clip in a.clips:
		have = [layer for layer in layers if clip in gear.clips_of(layer)]
		for d in DIRECTIONS:
			for i in range(CLIPS[clip][0]):
				frame = f"{clip}_{d}_{i:02d}"
				compose(a.build, have, frame, cell, foot).save(os.path.join(a.out, frame + ".png"))


def compose(build, layers, frame, cell, foot):
	colour = np.zeros((cell, cell, 4), np.uint8)
	nearest = np.zeros((cell, cell), np.int64)
	for layer in layers:
		px, depth = load(build, layer, frame)
		c, f = gear.cell_of(layer)
		x0, y0 = (cell - c) // 2, foot - f
		view = (slice(y0, y0 + c), slice(x0, x0 + c))
		wins = (px[..., 3] > 0) & (depth >= nearest[view])
		colour[view][wins] = px[wins]
		nearest[view][wins] = depth[wins]
	return Image.fromarray(colour, "RGBA")


def load(build, layer, frame):
	base = os.path.join(build, "pixels", layer, frame)
	px = np.asarray(Image.open(base + ".png").convert("RGBA")).copy()
	depth = np.asarray(Image.open(base + ".depth.png")).astype(np.int64)
	if layer == "body":
		face = np.asarray(Image.open(os.path.join(build, "face", "body", frame + ".png")).convert("RGBA"))
		drawn = face[..., 3] > 0
		px[drawn] = face[drawn]
	return px, depth


if __name__ == "__main__":
	main()
