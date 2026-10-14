#!/usr/bin/env python3
"""Import tool, first part (ADR-0008): generated sheets of world objects ->
clean pixel sprites in the master palette.

A generated picture only looks like pixel art: its "pixels" are soft blocks
of about 5-7 image pixels whose size drifts from object to object. For each
object the tool:
  1. finds it on the sheet (transparent or flat #FF00FF background);
  2. finds the block size and the grid phase from the image itself;
  3. reads one colour per block (median of the block's core, so the soft
     edges and coloured fringes of background removal do not leak in);
  4. drops stray edge pixels and holes, maps colours to the master palette
     (tools/art/palette.json, groups "nature", "flowers", "build");
  5. draws the environment edge of ART_STANDARD v2: no outline, a soft shade
     on the bottom and right of the silhouette (the next darker step).

Usage:
  tools/art/import_sheet.py --manifest tools/art/imports/002.json [--preview P.png]
  tools/art/import_sheet.py SHEET.png OUT_DIR [--names a,b,c] [--preview P.png]
Objects are numbered in reading order (rows top to bottom, then left to
right); --names gives them file names, "-" skips one.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
PALETTE_GROUPS = ("nature", "flowers", "build")


# --- palette --------------------------------------------------------------

def _lab(rgb):
    """sRGB (0..255, shape (..., 3)) -> CIE Lab."""
    c = np.asarray(rgb, float) / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.9505, 1.0, 1.089])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


class Palette:
    def __init__(self, groups=PALETTE_GROUPS):
        data = json.loads((ROOT / "tools" / "art" / "palette.json").read_text())
        self.rgb, self.darker = [], []
        for g in groups:
            for ramp in data[g].values():
                base = len(self.rgb)
                for i, c in enumerate(ramp):
                    self.rgb.append([int(c[k:k + 2], 16) for k in (0, 2, 4)])
                    # The shade edge goes one step down the same ramp.
                    self.darker.append(base + max(0, i - 2) if i > 0 else base)
        self.rgb = np.array(self.rgb)
        self.lab = _lab(self.rgb)

    def nearest(self, rgb):
        lab = _lab(rgb)
        d = ((lab[..., None, :] - self.lab) ** 2).sum(-1)
        # Lightness counts a bit less than hue: keeps a colour's family.
        d += ((lab[..., None, 0] - self.lab[:, 0]) ** 2) * -0.4
        return d.argmin(-1)


# --- finding objects ------------------------------------------------------

def load(path):
    img = np.array(Image.open(path).convert("RGBA")).astype(float)
    rgb, alpha = img[..., :3], img[..., 3]
    magenta = (rgb[..., 0] > 200) & (rgb[..., 1] < 80) & (rgb[..., 2] > 200)
    alpha = np.where(magenta, 0, alpha)
    return rgb, alpha


class Obj:
    """One object on the sheet: the labels of its parts and their box."""

    def __init__(self, labels, box):
        self.labels, self.box = set(labels), box

    def join(self, other):
        b, o = self.box, other.box
        self.labels |= other.labels
        self.box = (min(b[0], o[0]), min(b[1], o[1]), max(b[2], o[2]), max(b[3], o[3]))


def find_objects(alpha, gap=3, min_area=1500, attach=30):
    """Objects in reading order (rows by bottoms, then left to right). Parts
    smaller than min_area (a loose leaf, a pebble) join the nearest object
    within `attach` pixels, or are dropped."""
    solid = alpha > 160
    lab, n = ndimage.label(ndimage.binary_dilation(solid, iterations=gap))
    lab = lab * solid
    big, small = [], []
    for i, sl in enumerate(ndimage.find_objects(lab)):
        if sl is None:
            continue
        part = lab[sl] == i + 1
        ys, xs = np.nonzero(part)
        o = Obj([i + 1], (sl[1].start + xs.min(), sl[0].start + ys.min(), sl[1].start + xs.max() + 1, sl[0].start + ys.max() + 1))
        (big if part.sum() >= min_area else small).append(o)

    def dist(a, b):
        dx = max(b.box[0] - a.box[2], a.box[0] - b.box[2], 0)
        dy = max(b.box[1] - a.box[3], a.box[1] - b.box[3], 0)
        return max(dx, dy)

    for s in small:
        near = min(big, key=lambda b: dist(s, b), default=None)
        if near is not None and dist(s, near) <= attach:
            near.join(s)
    big.sort(key=lambda o: o.box[3])
    rows, row = [], []
    for o in big:
        if row and o.box[1] > max(r.box[3] for r in row) - 10:
            rows.append(row)
            row = []
        row.append(o)
    if row:
        rows.append(row)
    return [o for r in rows for o in sorted(r, key=lambda o: o.box[0])], lab


# --- the grid -------------------------------------------------------------

def _edges(rgb, solid, axis):
    g = np.abs(np.diff(rgb, axis=axis)).sum(-1)
    both = (solid[:, 1:] & solid[:, :-1]) if axis == 1 else (solid[1:] & solid[:-1])
    return (g * both).sum(axis=1 - axis)


def _comb(profile, p, phase):
    n = len(profile)
    k = np.arange(int(n / p) + 1)
    at = np.round(phase + k * p).astype(int)
    mid = np.round(phase + (k + 0.5) * p).astype(int)
    return profile[at[at < n]].mean() - profile[mid[mid < n]].mean()


def find_grid(rgb, solid, lo=4.0, hi=9.0, p=None):
    """Block size (shared by x and y; found unless given) and the phase on
    each axis."""
    px, py = _edges(rgb, solid, 1), _edges(rgb, solid, 0)
    if p is not None:
        fx = max(np.arange(0, p, 0.1), key=lambda f: _comb(px, p, f))
        fy = max(np.arange(0, p, 0.1), key=lambda f: _comb(py, p, f))
        return p, fx, fy
    best = None
    for p in np.arange(lo, hi, 0.02):
        sx = max(_comb(px, p, f) for f in np.arange(0, p, 0.5))
        sy = max(_comb(py, p, f) for f in np.arange(0, p, 0.5))
        # A multiple of the true size also lands on edges; the comb's
        # mid-points then land on edges too, which the score subtracts.
        s = sx / (px.mean() + 1e-9) + sy / (py.mean() + 1e-9)
        if best is None or s > best[0]:
            best = (s, p)
    p = best[1]
    fx = max(np.arange(0, p, 0.1), key=lambda f: _comb(px, p, f))
    fy = max(np.arange(0, p, 0.1), key=lambda f: _comb(py, p, f))
    return p, fx, fy


# --- sampling -------------------------------------------------------------

def sample(rgb, alpha, p, fx, fy):
    h, w = alpha.shape
    nx = int(np.ceil((w - fx) / p)) + 1
    ny = int(np.ceil((h - fy) / p)) + 1
    out = np.zeros((ny, nx, 3))
    cover = np.zeros((ny, nx))
    core = 0.22
    for j in range(ny):
        y0, y1 = fy + (j - 1) * p, fy + j * p
        ya, yb = int(round(y0 + p * core)), int(round(y1 - p * core))
        ya, yb = max(ya, 0), min(max(yb, ya + 1), h)
        if ya >= h or yb <= 0:
            continue
        for i in range(nx):
            x0, x1 = fx + (i - 1) * p, fx + i * p
            xa, xb = int(round(x0 + p * core)), int(round(x1 - p * core))
            xa, xb = max(xa, 0), min(max(xb, xa + 1), w)
            if xa >= w or xb <= 0:
                continue
            a = alpha[ya:yb, xa:xb]
            cover[j, i] = (a > 160).mean()
            sel = rgb[ya:yb, xa:xb][a > 200]
            if len(sel):
                out[j, i] = np.median(sel, axis=0)
    return out, cover > 0.5


def clean(mask):
    """Drops single stray pixels on the edge and fills single holes."""
    n = ndimage.convolve(mask.astype(int), np.ones((3, 3), int), mode="constant") - mask
    mask = mask & (n >= 2)
    holes = ~mask & (ndimage.convolve(mask.astype(int), np.array([[0, 1, 0], [1, 0, 1], [0, 1, 0]]), mode="constant") == 4)
    return mask | holes, holes


def fill_holes(rgb, mask, holes):
    for y, x in zip(*np.nonzero(holes)):
        near = [rgb[y + dy, x + dx] for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)) if not holes[y + dy, x + dx]]
        rgb[y, x] = np.median(near, axis=0)
    return rgb


def shade_edge(idx, mask, pal):
    """ART_STANDARD v2, 3: the environment has no outline, only a soft shade
    on the bottom and right of the silhouette, in its own darker colour."""
    out = idx.copy()
    h, w = mask.shape
    for y in range(h):
        for x in range(w):
            if not mask[y, x]:
                continue
            right = x + 1 >= w or not mask[y, x + 1]
            below = y + 1 >= h or not mask[y + 1, x]
            if right or below:
                out[y, x] = pal.darker[idx[y, x]]
    return out


def crop(rgb, alpha, obj, lab, pad=4):
    x0, y0, x1, y1 = obj.box
    x0, y0 = max(0, x0 - pad), max(0, y0 - pad)
    x1, y1 = min(alpha.shape[1], x1 + pad), min(alpha.shape[0], y1 + pad)
    a = alpha[y0:y1, x0:x1] * np.isin(lab[y0:y1, x0:x1], list(obj.labels))
    return rgb[y0:y1, x0:x1], a


def to_sprite(c, a, pal, p):
    p, fx, fy = find_grid(c, a > 200, p=p)
    cols, mask = sample(c, a, p, fx, fy)
    mask, holes = clean(mask)
    cols = fill_holes(cols, mask, holes)
    idx = pal.nearest(cols)
    idx = shade_edge(idx, mask, pal)
    ys, xs = np.nonzero(mask)
    idx, mask = idx[ys.min():ys.max() + 1, xs.min():xs.max() + 1], mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    out = np.zeros(mask.shape + (4,), np.uint8)
    out[..., :3] = pal.rgb[idx]
    out[..., 3] = mask * 255
    return Image.fromarray(out, "RGBA")


def sheet_block(rgb, alpha, objs, lab, lo=4.5, hi=8.0):
    """The sheet's block size: the one whose grid fits the edges of all its
    large objects together (a single small object has too few edges)."""
    big = sorted(objs, key=lambda o: -(o.box[2] - o.box[0]) * (o.box[3] - o.box[1]))[:8]
    profiles = []
    for o in big:
        c, a = crop(rgb, alpha, o, lab)
        for axis in (1, 0):
            pr = _edges(c, a > 200, axis)
            profiles.append(pr / (pr.mean() + 1e-9))
    best = None
    for p in np.arange(lo, hi, 0.01):
        s = sum(max(_comb(pr, p, f) for f in np.arange(0, p, 0.25)) for pr in profiles)
        if best is None or s > best[0]:
            best = (s, p)
    return float(best[1])


def import_sheet(path, names, out, block=None, scale=1.0, heights=None):
    """Cuts one sheet into sprites in `out`; returns [(name, image)].
    heights: {name: sprite height} for objects the generation drew out of
    scale (grass as tall as a man): their blocks are read coarser."""
    rgb, alpha = load(path)
    objs, lab = find_objects(alpha)
    named = {}
    for n, o in enumerate(objs):
        name = names[n] if n < len(names) else f"object_{n:02d}"
        if name == "-":
            continue
        if name in named:
            named[name].join(o)
        else:
            named[name] = o
    p = block or sheet_block(rgb, alpha, list(named.values()), lab)
    print("%s: block %.2f px, %d objects" % (path, p, len(named)))
    p /= scale
    pal = Palette()
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    sprites = []
    for name, o in named.items():
        c, a = crop(rgb, alpha, o, lab)
        own = p
        if heights and name in heights:
            own = (o.box[3] - o.box[1]) / heights[name]
        spr = to_sprite(c, a, pal, own)
        spr.save(out / f"{name}.png")
        sprites.append((name, spr))
        print(f"  {name:18s} {spr.size[0]}x{spr.size[1]}")
    return sprites


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sheet", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--manifest", help="tools/art/imports/NNN.json: sheets, names and the output directory")
    ap.add_argument("--names", default="", help="names in reading order; a repeated name joins parts, - skips")
    ap.add_argument("--block", type=float, help="block size in sheet pixels (found if omitted)")
    ap.add_argument("--scale", type=float, default=1.0, help="sprite pixels per block, below 1 makes it smaller")
    ap.add_argument("--preview")
    args = ap.parse_args()
    sprites = []
    if args.manifest:
        m = json.loads(Path(args.manifest).read_text())
        for sh in m["sheets"]:
            sprites += import_sheet(ROOT / sh["file"], sh["names"], ROOT / m["out"], sh.get("block"), sh.get("scale", 1.0), m.get("heights"))
    else:
        sprites = import_sheet(args.sheet, args.names.split(",") if args.names else [], args.out, args.block, args.scale)
    if args.preview:
        preview(sprites, args.preview)


def preview(sprites, path, k=3):
    w = sum(s.size[0] + 6 for _, s in sprites) * k
    h = max(s.size[1] for _, s in sprites) * k + 30
    sheet = Image.new("RGBA", (w, h), (120, 140, 80, 255))
    d = ImageDraw.Draw(sheet)
    x = 0
    for name, s in sprites:
        sheet.alpha_composite(s.resize((s.size[0] * k, s.size[1] * k), Image.NEAREST), (x, h - 20 - s.size[1] * k))
        d.text((x, h - 16), name, fill=(255, 255, 255))
        x += (s.size[0] + 6) * k
    sheet.save(path)


if __name__ == "__main__":
    main()
