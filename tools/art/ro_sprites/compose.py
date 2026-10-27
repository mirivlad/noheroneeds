"""Put layers together into character frames by their depth maps (python3 + Pillow + numpy).

Every layer was rendered alone over the invisible body (render.py), so a pixel
of a layer is a pixel that shows on the body; where layers overlap, the nearer
one wins (the brighter depth). The body layer takes its drawn face
(face2d.py) on top. Skin and hair are painted their colours and hair, under
headwear, cut where it is inside the headwear's keep-out, as the game does (hair.py). Cells of different sizes are lined up by their ground
point; the frame is as large as the largest cell. A layer without frames for a
clip (a held thing in a swing that is not its own) is left out of that clip.

Usage: python3 compose.py BUILD_DIR OUT_DIR (--outfit NAME | --layers body linen_shirt ...)
       [--clips idle walk ...] [--hair-colour "#rrggbb"] [--skin-colour "#rrggbb"]
BUILD_DIR holds pixels/<layer>/, face/body/ and the keep-outs' raw depth maps (build.sh).
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gear  # noqa: E402
import hair  # noqa: E402
from clips import CLIPS  # noqa: E402

DIRECTIONS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]
# Hair and skin in the previews.
HAIR_COLOUR, SKIN_COLOUR = "#7d4513", "#dc9b7e"


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("build")
	ap.add_argument("out")
	ap.add_argument("--outfit")
	ap.add_argument("--layers", nargs="+")
	ap.add_argument("--clips", nargs="+", default=list(CLIPS))
	ap.add_argument("--hair-colour", default=HAIR_COLOUR)
	ap.add_argument("--skin-colour", default=SKIN_COLOUR)
	a = ap.parse_args()
	layers = gear.OUTFITS[a.outfit] if a.outfit else a.layers
	# "hair" is the hairstyle the body is shown in (BUILD_DIR is build/ro_sprites/<body>)
	layers = [gear.DEFAULT_HAIR[os.path.basename(os.path.normpath(a.build))] if l == "hair" else l for l in layers]
	os.makedirs(a.out, exist_ok=True)
	cell, foot = max(gear.cell_of(layer) for layer in layers)  # the largest cell holds them all
	for clip in a.clips:
		have = [layer for layer in layers if clip in gear.clips_of(layer)]
		for d in DIRECTIONS:
			for i in range(CLIPS[clip][0]):
				frame = f"{clip}_{d}_{i:02d}"
				compose(a.build, have, frame, cell, foot, a.hair_colour, a.skin_colour).save(os.path.join(a.out, frame + ".png"))


def compose(build, layers, frame, cell, foot, hair_colour=None, skin_colour=None):
	colour = np.zeros((cell, cell, 4), np.uint8)
	nearest = np.zeros((cell, cell), np.int64)
	hats = [layer for layer in layers if layer in gear.HEADWEAR]
	for layer in layers:
		px, depth = load(build, layer, frame)
		if layer == "body":
			px = hair.paint_skin(px, skin_colour or SKIN_COLOUR)
		if layer in gear.HAIR_LAYERS:
			px = hair.paint(px, hair_colour or HAIR_COLOUR)
			for hat in hats:
				cut = hair.inside(hair.depth_bytes(depth), *hair.keep_out(build, hat, frame))
				px[cut] = 0
				depth[cut] = 0
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
