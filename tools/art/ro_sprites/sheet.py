"""Contact sheet of sprite frames for review (python3 + Pillow).

Usage: python3 sheet.py OUT.png --cols 8 --zoom 3 [--size PX] [--bg 789a5a] FRAME.png...
--size first scales every frame to PX square (smoothly; for big renders).
"""
import argparse

from PIL import Image


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("out")
	ap.add_argument("frames", nargs="+")
	ap.add_argument("--cols", type=int, default=8)
	ap.add_argument("--zoom", type=int, default=3)
	ap.add_argument("--size", type=int)
	ap.add_argument("--bg", default="789a5a")
	a = ap.parse_args()
	ims = [Image.open(f).convert("RGBA") for f in a.frames]
	if a.size:
		ims = [im.resize((a.size, a.size), Image.LANCZOS) for im in ims]
	w, h = ims[0].size
	cols = min(a.cols, len(ims))
	rows = (len(ims) + cols - 1) // cols
	sheet = Image.new("RGBA", (cols * w, rows * h), "#" + a.bg)
	for i, im in enumerate(ims):
		sheet.alpha_composite(im, ((i % cols) * w, (i // cols) * h))
	sheet.resize((sheet.width * a.zoom, sheet.height * a.zoom), Image.NEAREST).save(a.out)


main()
