"""Draw the face in pixels at the projected face anchors (python3 + Pillow).

Ragnarok Online faces are drawn, not modelled: a few pixels of lid line, iris,
highlight and sclera. render.py writes where the eyes and the mouth land
in every frame and how far each turns from the viewer; an eye looking at the
viewer gets the full template, one turned away gets the narrow one, and one
turned further (or covered by the body) is not drawn. Face pixels go only on
skin; bangs and headwear, layers of their own, cover them where they are nearer
(compose.py).

The face is written as its own layer (FACE_DIR/<frame>.png); --onto writes
the sprites with the face drawn on them as well.

Usage: python3 face2d.py SPRITE_DIR ANCHORS.json --out FACE_DIR [--onto OUT_DIR]
"""
import argparse
import json
import os

import numpy as np
from PIL import Image

import palette as pal

COLOURS = {
	"L": pal.EYE_LINE, "I": pal.IRIS_DARK, "i": pal.IRIS_LIGHT, "h": pal.HIGHLIGHT,
	"W": pal.SCLERA, "B": pal.BROW, "M": pal.MOUTH,
}
# Templates: rows of colour letters ("." is empty) and the (col, row) on the anchor.
# Eyes are the character's right eye (on the left of the screen when facing the
# viewer) with the outer corner on the left; the left eye is the mirror image.
EYE_FULL = (["BBBB.", ".....", ".LLLL", "LIIhW", "LIIiW", ".iii."], (2, 4))
EYE_NARROW = (["BBB", "...", "LLL", "IIh", "Iii", "ii."], (1, 4))
MOUTH_FULL = (["MM"], (1, 0))
MOUTH_NARROW = (["M"], (0, 0))
FULL, NARROW = 0.6, 0.25  # facing thresholds


def stamp(layer, template, x, y, mirror):
	rows, (ax, ay) = template
	w = len(rows[0])
	for r, row in enumerate(rows):
		for c, ch in enumerate(row):
			if ch == ".":
				continue
			cc = (w - 1 - c) if mirror else c
			px, py = round(x) - ((w - 1 - ax) if mirror else ax) + cc, round(y) - ay + r
			if 0 <= py < layer.shape[0] and 0 <= px < layer.shape[1]:
				layer[py, px] = (*pal.rgb(COLOURS[ch]), 255)


def draw_face(size, anchors):
	layer = np.zeros((size[1], size[0], 4), np.uint8)
	for name, mirror in (("eye_r", False), ("eye_l", True)):
		x, y, facing, visible = anchors[name]
		if visible and facing >= NARROW:
			stamp(layer, EYE_FULL if facing >= FULL else EYE_NARROW, x, y, mirror)
	x, y, facing, visible = anchors["mouth"]
	if visible and facing >= NARROW:
		stamp(layer, MOUTH_FULL if facing >= FULL else MOUTH_NARROW, x, y, False)
	return layer


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("sprites")
	ap.add_argument("anchors")
	ap.add_argument("--out", required=True)
	ap.add_argument("--onto")
	a = ap.parse_args()
	skin = {(r << 16) | (g << 8) | b for r, g, b in (pal.rgb(c) for _, c in pal.SKIN)}
	os.makedirs(a.out, exist_ok=True)
	if a.onto:
		os.makedirs(a.onto, exist_ok=True)
	for frame, anchors in json.load(open(a.anchors)).items():
		base = np.asarray(Image.open(os.path.join(a.sprites, frame + ".png")).convert("RGBA")).copy()
		layer = draw_face((base.shape[1], base.shape[0]), anchors)
		key = (base[..., 0].astype(np.int32) << 16) | (base[..., 1].astype(np.int32) << 8) | base[..., 2]
		on_skin = np.isin(key, list(skin)) & (base[..., 3] > 0)
		layer[~on_skin] = 0
		Image.fromarray(layer, "RGBA").save(os.path.join(a.out, frame + ".png"))
		if a.onto:
			drawn = layer[..., 3] > 0
			base[drawn] = layer[drawn]
			Image.fromarray(base, "RGBA").save(os.path.join(a.onto, frame + ".png"))


if __name__ == "__main__":
	main()
