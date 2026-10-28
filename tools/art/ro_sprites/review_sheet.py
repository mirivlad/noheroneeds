"""Labelled sheets and animations of an RO character as the game draws it (python3 + Pillow).

Reads what the game reads — content/base/ro_visuals.json and the atlases of
content/base/art/ro — and puts the layers of a look together in the order the
visual gives for each frame, as RoSprite does: skin and hair painted their colours, hair
cut inside the headwear's keep-out (hair.py). For every clip: <clip>.png with
one row per direction and one column per frame, each labelled, and <clip>.gif
playing the directions side by side at the clip's pace.

Usage: python3 review_sheet.py CONTENT_DIR OUT_DIR [--plan base:human_ro_m] [--hair STYLE]
       [--hair-colour "#rrggbb"] [--skin-colour "#rrggbb"] [--worn linen_shirt ...] [--held axe] [--clips idle walk ...] [--dirs n s e ne se] [--zoom 3]
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import hair as hair_paint

ROWS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]
CLIP_NAMES = {"idle": "стойка", "walk": "ходьба", "run": "бег", "sit": "сидит", "pickup": "поднять с земли",
	"hurt": "получил удар", "dead": "падение", "slash": "рубящий удар (меч)", "thrust": "укол (копьё, мотыга)",
	"chop": "рубка (топоры)", "mine": "кирка: сверху вниз", "shoot": "выстрел из лука", "cast": "заброс удочки"}
FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "assets", "fonts", "monogram.ttf")
GRASS = "#4f7a3a"
CELL = (128, 150)  # frame cell, sprite pixels: wide enough for a swung tool
FOOT = (64, 123)


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("content")
	ap.add_argument("out")
	ap.add_argument("--plan", default="base:human_ro_m")
	ap.add_argument("--hair")
	ap.add_argument("--hair-colour", default="#7d4513")
	ap.add_argument("--skin-colour", default="#dc9b7e")
	ap.add_argument("--worn", nargs="*", default=["linen_shirt", "work_trousers", "boots"])
	ap.add_argument("--held")
	ap.add_argument("--clips", nargs="+")
	ap.add_argument("--dirs", nargs="+", default=["n", "s", "e", "ne", "se"])
	ap.add_argument("--zoom", type=int, default=3)
	a = ap.parse_args()
	visuals = json.load(open(os.path.join(a.content, "ro_visuals.json"), encoding="utf-8"))["defs"]
	v = next(d for d in visuals if d["for"] == a.plan)
	sheets = [("body", v)]
	hair = a.hair or next(iter(v["style_overrides"]))
	if hair in v["style_overrides"]:
		sheets.append(("hair", v["style_overrides"][hair]["sheets"][0]))
	keep_out = None
	for item in a.worn:
		worn = v["worn_overrides"]["base:" + item]
		sheets.append((item, worn["sheets"][0]))
		keep_out = worn.get("keep_out", keep_out)
	if a.held:
		sheets.append((a.held, v["held_overrides"]["base:" + a.held]["sheets"][0]))
	atlases = {s["atlas"]: Image.open(os.path.join(a.content, s["atlas"])).convert("RGBA")
		for s in [s for _, s in sheets] + ([keep_out] if keep_out else [])}
	os.makedirs(a.out, exist_ok=True)
	font = ImageFont.truetype(FONT, 48)
	small = ImageFont.truetype(FONT, 32)
	for clip in a.clips or list(v["clips"]):
		c = v["clips"][clip]
		frames = [[frame(v, sheets, atlases, clip, ROWS.index(d), i, (a.hair_colour, a.skin_colour), keep_out)
			for i in range(c["frames"])]
			for d in a.dirs]
		title = "%s - %s (%s), кадров %d, %g к/с%s" % (plan_name(a.plan), clip, CLIP_NAMES.get(clip, clip),
			c["frames"], c["fps"], ", в руках: " + a.held if a.held else "")
		sheet_png(frames, a.dirs, title, font, a.zoom).save(os.path.join(a.out, clip + ".png"))
		gif(frames, a.dirs, c, small, a.zoom, os.path.join(a.out, clip + ".gif"))


def plan_name(plan):
	return {"base:human_ro_m": "Мужской RO", "base:human_ro_f": "Женский RO"}.get(plan, plan)


def crop(sheet, atlases, clip, row, i):
	"""A frame of a sheet as an array, or None when the sheet has none."""
	first, count = sheet["anims"].get(clip, (0, 0))
	if i >= count:
		return None
	col = first + i
	w, h = sheet["frame"]
	x, y = (col % sheet["columns"]) * w, ((col // sheet["columns"]) * 8 + row) * h
	return np.asarray(atlases[sheet["atlas"]].crop((x, y, x + w, y + h))).copy()


def frame(v, sheets, atlases, clip, row, i, colours, keep_out):
	"""One frame of the look, its layers in the visual's order for it, on grass."""
	out = Image.new("RGBA", CELL, GRASS)
	order = [v["layers"][k] for k in v["order"][clip][row][i]]
	present = [(key, s) for key, s in sheets if clip in s["anims"]]
	present.sort(key=lambda ks: order.index(ks[1]["key"]) if ks[1]["key"] in order else len(order))
	for key, s in present:
		px = crop(s, atlases, clip, row, i)
		if px is None:
			continue
		if key == "hair":
			k = crop(keep_out, atlases, clip, row, i) if keep_out else None
			if k is not None:  # the keep-out lined up with the hair by the feet
				near, far = np.zeros(px.shape[:2], np.uint8), np.zeros(px.shape[:2], np.uint8)
				dx, dy = keep_out["origin"][0] - s["origin"][0], keep_out["origin"][1] - s["origin"][1]
				for y in range(px.shape[0]):
					for x in range(px.shape[1]):
						kx, ky = x + dx, y + dy
						if 0 <= kx < k.shape[1] and 0 <= ky < k.shape[0] and k[ky, kx, 3] > 0:
							near[y, x], far[y, x] = k[ky, kx, 0], k[ky, kx, 1]
				px[hair_paint.inside(px[..., 1], near, far) & (px[..., 3] > 0)] = 0
			px = hair_paint.paint(px, colours[0])
		if key == "body":
			px = hair_paint.paint_skin(px, colours[1])
		pic = Image.fromarray(px, "RGBA")
		# the pixels are either opaque or clear: pasting through their own alpha is compositing
		out.paste(pic, (FOOT[0] - s["origin"][0], FOOT[1] - s["origin"][1]), pic)
	return out


def sheet_png(frames, dirs, title, font, zoom):
	w, h = CELL[0] * zoom, CELL[1] * zoom
	left, top, gap = 70, 100, 4
	cols = len(frames[0])
	img = Image.new("RGB", (left + cols * (w + gap), top + len(dirs) * (h + gap)), "#202124")
	d = ImageDraw.Draw(img)
	d.text((8, 4), title, font=font, fill="#ffffff")
	for i in range(cols):
		d.text((left + i * (w + gap) + w // 2 - 8, top - 46), str(i), font=font, fill="#c8c8c8")
	for r, (direction, row) in enumerate(zip(dirs, frames)):
		y = top + r * (h + gap)
		d.text((8, y + h // 2 - 24), direction.upper(), font=font, fill="#ffffff")
		for i, pic in enumerate(row):
			img.paste(pic.resize((w, h), Image.NEAREST), (left + i * (w + gap), y))
	return img


def gif(frames, dirs, c, font, zoom, path):
	w, h = CELL[0] * zoom, CELL[1] * zoom
	shots = []
	for i in range(len(frames[0])):
		strip = Image.new("RGB", (len(dirs) * w, h + 30), "#202124")
		d = ImageDraw.Draw(strip)
		for k, direction in enumerate(dirs):
			strip.paste(frames[k][i].resize((w, h), Image.NEAREST), (k * w, 30))
			d.text((k * w + 4, 0), direction.upper(), font=font, fill="#ffffff")
		shots.append(strip)
	durations = [round(1000 / c["fps"])] * len(shots)
	if not c["loop"]:
		durations[-1] = 700
	shots[0].save(path, save_all=True, append_images=shots[1:], duration=durations, loop=0)


if __name__ == "__main__":
	main()
