"""Hair and skin as the game draws them (python3 + numpy): greys painted a colour, hair cut under headwear.

A hairstyle is rendered in the grey ramp of palette.HAIR. Its atlas in the game
(export_game.py) keeps the grey in red and the pixel's depth, as a byte, in
green; a headwear's keep-out atlas keeps the depth of the keep-out's near side
in red and of its far side in green. A hair pixel between the two is inside the
keep-out and is not drawn (ro_hair.gdshader does the same in the game). A depth
byte is 255 at WINDOW's near end, 1 at its far end, 0 where there is nothing.

paint() turns the grey into tones of the chosen colour (palette.HAIR_MIDDLE,
HAIR_LIFT); paint_skin() the greys of the body (palette.SKIN_MIDDLE, SKIN_LIFT),
leaving its other colours (the underwear, the drawn face) as they are.
"""
import os

import numpy as np
from PIL import Image

import gear
import palette

# Metres from the camera a depth byte spans: every head of every clip lies within.
WINDOW = (18.9, 21.1)
# A hair pixel this many depth bytes outside the keep-out still counts as inside it.
SLACK = 1


def depth_bytes(d16):
	"""16-bit depth map (gear.DEPTH_RANGE) to depth bytes."""
	near, far = gear.DEPTH_RANGE
	metres = far - d16.astype(np.float64) / 65535 * (far - near)
	b = np.clip(np.round((WINDOW[1] - metres) / (WINDOW[1] - WINDOW[0]) * 254) + 1, 1, 255)
	return np.where(d16 > 0, b, 0).astype(np.uint8)


def keep_out(build, hat, frame):
	"""(near, far) depth bytes of a headwear's keep-out in a frame, at its cell's size."""
	cell, _ = gear.cell_of(hat)
	out = []
	for side in ("_keep_out", "_keep_out_back"):
		d = np.asarray(Image.open(os.path.join(build, "raw", hat + side, frame + ".depth.png"))).astype(np.int64)
		k = d.shape[0] // cell
		out.append(depth_bytes(d[:cell * k, :cell * k].reshape(cell, k, cell, k).max(axis=(1, 3))))
	return out


def inside(depth, near, far):
	"""Where hair of these depth bytes is inside the keep-out."""
	d, n, f = (a.astype(np.int64) for a in (depth, near, far))
	return (d > 0) & (n > 0) & (f > 0) & (d <= n + SLACK) & (d >= f - SLACK)


def paint(px, colour, middle=palette.HAIR_MIDDLE, lift=palette.HAIR_LIFT):
	"""RGBA in greys (red is the grey) -> the same in tones of colour ("#rrggbb")."""
	c = np.array([int(colour[i:i + 2], 16) for i in (1, 3, 5)]) / 255
	t = px[..., :1].astype(np.float64) / 255
	m = middle / 255
	dark = c * t / m
	light = c + (1 - c) * (t - m) / (1 - m) * lift
	out = px.copy()
	out[..., :3] = np.round(np.clip(np.where(t <= m, dark, light), 0, 1) * 255)
	return out


def paint_skin(px, colour):
	"""The body's greys (under white) painted colour; its other pixels kept."""
	r, g, b = (px[..., i].astype(np.int64) for i in range(3))
	skin = (r == g) & (g == b) & (r < 0xf0) & (px[..., 3] > 0)
	out = px.copy()
	out[skin] = paint(px, colour, palette.SKIN_MIDDLE, palette.SKIN_LIFT)[skin]
	return out
