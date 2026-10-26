"""Animated previews and frame sheets of rendered clips (python3 + Pillow).

For every clip: <out>/<clip>.gif plays the clip in all 8 directions side by
side at the clip's fps, and <out>/<clip>.png lays its frames out with one row
per direction.

Usage: python3 preview.py SPRITE_DIR OUT_DIR [--zoom 3] [--bg 789a5a] [--clips walk ...]
"""
import argparse
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clips import CLIPS  # noqa: E402

DIRECTIONS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("sprites")
	ap.add_argument("out")
	ap.add_argument("--zoom", type=int, default=3)
	ap.add_argument("--bg", default="789a5a")
	ap.add_argument("--clips", nargs="+", default=list(CLIPS))
	a = ap.parse_args()
	os.makedirs(a.out, exist_ok=True)
	bg = "#" + a.bg
	for clip in a.clips:
		frames, fps, loop, _ = CLIPS[clip]
		grid = [[Image.open(os.path.join(a.sprites, f"{clip}_{d}_{i:02d}.png")).convert("RGBA")
			for i in range(frames)] for d in DIRECTIONS]
		w, h = grid[0][0].size
		sheet = Image.new("RGBA", (frames * w, len(DIRECTIONS) * h), bg)
		for r, row in enumerate(grid):
			for c, im in enumerate(row):
				sheet.alpha_composite(im, (c * w, r * h))
		sheet.resize((sheet.width * a.zoom, sheet.height * a.zoom), Image.NEAREST).save(os.path.join(a.out, clip + ".png"))
		shots = []
		for i in range(frames):
			strip = Image.new("RGBA", (len(DIRECTIONS) * w, h), bg)
			for r, row in enumerate(grid):
				strip.alpha_composite(row[i], (r * w, 0))
			shots.append(strip.resize((strip.width * a.zoom, strip.height * a.zoom), Image.NEAREST).convert("RGB"))
		durations = [round(1000 / fps)] * frames
		if not loop:
			durations[-1] = 700  # hold the end pose before playing again
		shots[0].save(os.path.join(a.out, clip + ".gif"), save_all=True, append_images=shots[1:],
			duration=durations, loop=0, disposal=1)


main()
