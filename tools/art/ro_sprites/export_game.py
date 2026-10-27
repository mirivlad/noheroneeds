"""Put the rendered RO layers into the game: atlases and visuals (python3 + Pillow + numpy).

For every body build.sh has made in full (BUILD_DIR/<body>/pixels), every layer
(the body with its drawn face, the sample hair, each item) becomes one atlas in
content/base/art/ro/<body>/: frames cropped to the box all of that
layer's frames fit in, eight rows of directions (s, se, e, ne, n, nw, w, sw) and
the clips one after another along the columns; a layer too wide for one strip
of columns goes on in another band of eight rows below.

The order the layers are drawn in comes from the depth maps, frame by frame:
for two layers that overlap in a frame, the one nearer at most of the shared
pixels is drawn later. The body is always first: every other layer was filmed
on it as a holdout and holds only what shows in front of it.

CREDITS-art.md gets the source model in its own section ("<!-- ro -->", at
the end). content/base/ro_visuals.json gets each body plan's visual (format "ro", read by
RoSprite): the body sheet itself, its sample hair as a style, the clothes and
held things of gear.py as fitted layers, the clips with their frames and fps,
the game's swings, and the draw order of every frame.

Usage: python3 export_game.py BUILD_DIR CONTENT_DIR [--max-width 4096]   (BUILD_DIR holds <body>/)
"""
import argparse
import json
import os
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gear  # noqa: E402
from clips import CLIPS  # noqa: E402

DIRECTIONS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]
# body: (body plan, the style its sample hair is)
BODIES = {"male": ("base:human_ro_m", "base:human_ro_hair_tousled"),
	"female": ("base:human_ro_f", "base:human_ro_hair_twintails")}
# Game swings (world_view.gd swing_kind) -> clips.
SWINGS = {"chop": "chop", "mine": "mine", "thrust": "thrust", "draw": "shoot", "lunge": "slash", "cast": "cast"}
# Game equipment slots of the layers (content/base character_editor.json).
SLOTS = {"hair_sample": "hair", **gear.WORN, **{item: "main_hand" for item in gear.HELD}}
# What wins a tie or a cycle of the depth order: from the body outwards.
CANONICAL = ["body", "work_trousers", "boots", "linen_shirt", "leather_armor", "wool_cloak", "fur_cloak",
	"hair_sample", "iron_helmet", "felt_hat", "fur_hood", *gear.HELD]


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("build")
	ap.add_argument("content")
	ap.add_argument("--max-width", type=int, default=4096)
	a = ap.parse_args()
	layers = gear.all_layers()
	visuals = []
	with Pool(min(8, os.cpu_count() or 1)) as pool:
		for body, (plan, hair) in BODIES.items():
			build = os.path.join(a.build, body)
			if not all(os.path.isdir(os.path.join(build, "pixels", l)) for l in layers):
				print("ro body %s: not built in full, left out" % body)
				continue
			out_dir = os.path.join(a.content, "art", "ro", body)
			os.makedirs(out_dir, exist_ok=True)
			sheets = dict(zip(layers, pool.map(atlas, [(build, out_dir, body, layer, a.max_width) for layer in layers])))
			jobs = [(build, clip, d, i) for clip in CLIPS for d in DIRECTIONS for i in range(CLIPS[clip][0])]
			orders = dict(zip([j[1:] for j in jobs], pool.map(order, jobs)))
			visuals.append(visual(body, plan, hair, sheets, orders))
			total = sum(os.path.getsize(os.path.join(out_dir, n)) for n in os.listdir(out_dir) if n.endswith(".png"))
			print("ro body %s: %d layers, %.1f MB" % (body, len(layers), total / 1e6))
	with open(os.path.join(a.content, "ro_visuals.json"), "w", encoding="utf-8") as f:
		json.dump({"format": 1, "defs": visuals}, f, ensure_ascii=False, separators=(",", ":"))
	credit(os.path.join(a.content, "..", "..", "CREDITS-art.md"))


def visual(body, plan, hair, sheets, orders):
	index = {layer: k for k, layer in enumerate(CANONICAL)}
	return {
		"id": "base:visual/" + plan.split(":")[1], "kind": "visual", "for": plan, "mode": "character", "format": "ro",
		"pixel_scale": 0.25, **sheets["body"], "rect": [0, 0, *sheets["body"]["frame"]],
		"clips": {c: {"frames": f, "fps": fps, "loop": loop} for c, (f, fps, loop, _) in CLIPS.items()},
		"swings": SWINGS,
		"layers": CANONICAL,
		"order": {c: [[[index[l] for l in orders[(c, d, i)]] for i in range(CLIPS[c][0])] for d in DIRECTIONS]
			for c in CLIPS},
		"style_overrides": {hair: {"layer": "hair", "sheets": [sheets["hair_sample"]]}},
		"worn_overrides": {"base:" + item: {"layer": SLOTS[item], "sheets": [sheets[item]]} for item in gear.WORN},
		"held_overrides": {"base:" + item: {"layer": "main_hand", "sheets": [sheets[item]]} for item in gear.HELD},
	}


RO_CREDITS_START = "<!-- ro -->"
RO_CREDITS = [
	RO_CREDITS_START, "# Авторы графики персонажей в стиле Ragnarok Online", "",
	"Тела — модели VRoid **HairSample_Male** и **HairSample_Female** (pixiv Inc., лицензия CC0, указана в",
	"метаданных VRM) из",
	"[madjin/vrm-samples](https://github.com/madjin/vrm-samples). Пропорции, лицо, одежда, предметы и",
	"анимации сделаны в `tools/art/ro_sprites` и отрендерены в пиксели там же.", "",
]


def credit(path):
	"""Put the RO section at the end of the credits, replacing an older one."""
	text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
	text = text.split(RO_CREDITS_START)[0].rstrip() + "\n\n"
	with open(path, "w", encoding="utf-8") as f:
		f.write(text + "\n".join(RO_CREDITS))


def frames_of(layer):
	for clip in gear.clips_of(layer):
		for i in range(CLIPS[clip][0]):
			yield clip, i


def load(build, layer, clip, d, i):
	base = os.path.join(build, "pixels", layer, f"{clip}_{d}_{i:02d}")
	px = np.asarray(Image.open(base + ".png").convert("RGBA")).copy()
	if layer == "body":  # the drawn face on top
		face = np.asarray(Image.open(os.path.join(build, "face", "body", f"{clip}_{d}_{i:02d}.png")).convert("RGBA"))
		drawn = face[..., 3] > 0
		px[drawn] = face[drawn]
	return px, base


def atlas(job):
	"""One layer's atlas; returns its sheet: atlas, frame size, the feet in the frame, columns, clips."""
	build, out_dir, body, layer, max_width = job
	cell, foot = gear.cell_of(layer)
	frames = list(frames_of(layer))
	pics = {(clip, d, i): load(build, layer, clip, d, i)[0] for clip, i in frames for d in DIRECTIONS}
	solid = np.zeros((cell, cell), bool)
	for px in pics.values():
		solid |= px[..., 3] > 0
	ys, xs = np.nonzero(solid)
	x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
	w, h = int(x1 - x0), int(y1 - y0)
	columns = max(1, min(len(frames), max_width // w))
	bands = -(-len(frames) // columns)
	sheet = Image.new("RGBA", (columns * w, bands * len(DIRECTIONS) * h))
	clips, n = {}, 0
	for clip in gear.clips_of(layer):
		clips[clip] = [n, CLIPS[clip][0]]
		n += CLIPS[clip][0]
	for c, (clip, i) in enumerate(frames):
		for r, d in enumerate(DIRECTIONS):
			crop = pics[(clip, d, i)][y0:y1, x0:x1]
			x, y = (c % columns) * w, ((c // columns) * len(DIRECTIONS) + r) * h
			sheet.paste(Image.fromarray(crop, "RGBA"), (x, y))
	name = layer + ".png"
	sheet.save(os.path.join(out_dir, name), optimize=True)
	return {"atlas": "art/ro/%s/%s" % (body, name), "key": layer, "frame": [w, h], "origin": [int(cell // 2 - x0), int(foot - y0)],
		"columns": columns, "anims": clips}


def order(job):
	"""The layers with frames for this frame, in the order they are drawn."""
	build, clip, d, i = job
	cell, foot = gear.HELD_CELL, gear.HELD_FOOT
	present, depth = [], {}
	for layer in CANONICAL:
		if clip not in gear.clips_of(layer):
			continue
		c, f = gear.cell_of(layer)
		base = os.path.join(build, "pixels", layer, f"{clip}_{d}_{i:02d}")
		z = np.zeros((cell, cell), np.int64)
		x, y = (cell - c) // 2, foot - f
		z[y:y + c, x:x + c] = np.asarray(Image.open(base + ".depth.png")).astype(np.int64)
		present.append(layer)
		depth[layer] = z
	# behind[b] = layers drawn before b (b is nearer where they overlap)
	behind = {l: set() for l in present}
	for k, p in enumerate(present):
		for q in present[k + 1:]:
			both = (depth[p] > 0) & (depth[q] > 0)
			if not both.any():
				continue
			p_near = int((depth[p][both] > depth[q][both]).sum())
			q_near = int((depth[q][both] > depth[p][both]).sum())
			if p_near > q_near:
				behind[p].add(q)
			elif q_near > p_near:
				behind[q].add(p)
	for l in present:  # the body first: everything else was filmed in front of it
		if l == "body":
			behind[l].clear()
		else:
			behind[l].add("body")
	out, left = [], list(present)
	while left:
		ready = [l for l in left if not (behind[l] & set(left))]
		pick = (ready or left)[0]  # canonical order breaks ties and cycles
		out.append(pick)
		left.remove(pick)
	return out


if __name__ == "__main__":
	main()
