"""Reduce supersampled renders to sprite pixels (python3 + Pillow + numpy).

Each SCALE x SCALE block becomes one pixel: opaque when at least half of it is
covered, coloured with the most frequent opaque colour of the block, so only
the palette colours of the toon materials survive (no blended in-between tones).
A one-pixel outline in a darkened colour of the neighbouring pixel is drawn
around the silhouette, as in Ragnarok Online sprites.

A depth map next to a frame (IN.depth.png, 16-bit grey at any multiple of the
sprite size, nearer brighter) is reduced along: each pixel takes the nearest
depth of its block, and pixels the colour has but the depth missed (edges, the
outline) take the nearest depth around them. A frame whose pixels touch the
edge of the cell is reported: something is cut off.

Usage: python3 pixelate.py SCALE IN.png... --out DIR [--no-outline]   (non-PNG inputs are skipped)
"""
import argparse
import os
from multiprocessing import Pool

import numpy as np
from PIL import Image

OUTLINE_DARKEN = 0.42
# Drawn lines (eyes, brows) are thin: a dark colour counts this many times over.
LINE_LUMA = 80
LINE_WEIGHT = 4.0


def reduce(img, scale):
	a = np.asarray(img.convert("RGBA"), dtype=np.uint8)
	h, w = a.shape[0] // scale, a.shape[1] // scale
	blocks = a[:h * scale, :w * scale].reshape(h, scale, w, scale, 4).transpose(0, 2, 1, 3, 4).reshape(h, w, -1, 4)
	opaque = blocks[..., 3] >= 128
	out = np.zeros((h, w, 4), np.uint8)
	keys = (blocks[..., 0].astype(np.int64) << 16) | (blocks[..., 1].astype(np.int64) << 8) | blocks[..., 2]
	cover = opaque.mean(axis=2) >= 0.5
	lum = blocks[..., 0] * 0.3 + blocks[..., 1] * 0.59 + blocks[..., 2] * 0.11
	weight = np.where(lum < LINE_LUMA, LINE_WEIGHT, 1.0)
	for y, x in zip(*np.nonzero(cover)):
		sel = opaque[y, x]
		vals, inv = np.unique(keys[y, x][sel], return_inverse=True)
		c = int(vals[np.argmax(np.bincount(inv, weights=weight[y, x][sel]))])
		out[y, x] = (c >> 16, (c >> 8) & 255, c & 255, 255)
	return out


def outline(px):
	solid = px[..., 3] > 0
	h, w = solid.shape
	out = px.copy()
	acc = np.zeros((h, w, 3))
	n = np.zeros((h, w))
	for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
		shifted = np.zeros_like(solid)
		col = np.zeros((h, w, 3))
		ys, yd = slice(max(dy, 0), h + min(dy, 0)), slice(max(-dy, 0), h + min(-dy, 0))
		xs, xd = slice(max(dx, 0), w + min(dx, 0)), slice(max(-dx, 0), w + min(-dx, 0))
		shifted[yd, xd] = solid[ys, xs]
		col[yd, xd] = px[ys, xs, :3]
		acc += col * shifted[..., None]
		n += shifted
	edge = (~solid) & (n > 0)
	out[edge, :3] = (acc[edge] / n[edge, None] * OUTLINE_DARKEN).astype(np.uint8)
	out[edge, 3] = 255
	return out


def reduce_depth(img, size):
	d = np.asarray(img).astype(np.int64)
	k = d.shape[0] // size
	d = d[:size * k, :size * k].reshape(size, k, size, k).max(axis=(1, 3))
	return d


def fill_depth(depth, solid, rounds=3):
	"""Give pixels of the colour that have no depth the nearest depth around them."""
	for _ in range(rounds):
		missing = solid & (depth == 0)
		if not missing.any():
			break
		near = depth.copy()
		for dy in (-1, 0, 1):
			for dx in (-1, 0, 1):
				near = np.maximum(near, np.roll(np.roll(depth, dy, 0), dx, 1))
		depth = np.where(missing, near, depth)
	return np.where(solid, depth, 0)


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("scale", type=int)
	ap.add_argument("inputs", nargs="+")
	ap.add_argument("--out", required=True)
	ap.add_argument("--no-outline", action="store_true")
	a = ap.parse_args()
	os.makedirs(a.out, exist_ok=True)
	with Pool(min(8, os.cpu_count() or 1)) as pool:
		jobs = [(p, a.scale, a.out, not a.no_outline) for p in a.inputs
			if p.endswith(".png") and not p.endswith(".depth.png")]
		for clipped in pool.map(one, jobs):
			if clipped:
				print("cut off at the cell edge:", clipped)


def one(job):
	path, scale, out, line = job
	px = reduce(Image.open(path), scale)
	if line:
		px = outline(px)
	name = os.path.basename(path)
	Image.fromarray(px, "RGBA").save(os.path.join(out, name))
	depth_path = path[:-4] + ".depth.png"
	if os.path.exists(depth_path):
		d = fill_depth(reduce_depth(Image.open(depth_path), px.shape[0]), px[..., 3] > 0)
		Image.fromarray(d.astype(np.uint16)).save(os.path.join(out, name[:-4] + ".depth.png"))
	solid = px[..., 3] > 0
	return name if solid[0].any() or solid[-1].any() or solid[:, 0].any() or solid[:, -1].any() else None


if __name__ == "__main__":
	main()
