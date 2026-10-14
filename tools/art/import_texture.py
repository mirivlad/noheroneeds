#!/usr/bin/env python3
"""Import tool, materials (ADR-0008, brief 001): a generated seamless texture
-> a small seamless pixel texture in the material's own master-palette ramps.

  1. one colour per block (median of the block's core), at the size the
     manifest asks for (64 = 4 x 4 tiles of 16);
  2. each pixel goes to the closest of the material's ramps (grass, or dirt
     and stone for pebbles);
  3. within a ramp, steps are given by brightness rank, so the texture uses
     the whole ramp evenly whatever the generation's own colours were (a too
     yellow or too orange picture comes out in the standard's colours);
  4. the edges are checked: a texture whose opposite edges do not match is
     reported, since its tiles would show seams.

Usage: tools/art/import_texture.py tools/art/imports/001.json [--preview P.png]
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from import_sheet import ROOT, _lab

PAL = json.loads((ROOT / "tools" / "art" / "palette.json").read_text())


def ramp(name):
    for group in PAL.values():
        if name in group:
            return np.array([[int(c[k:k + 2], 16) for k in (0, 2, 4)] for c in group[name]])
    raise KeyError(name)


def blocks(img, n):
    a = np.asarray(img.convert("RGB"), float)
    h, w, _ = a.shape
    out = np.zeros((n, n, 3))
    for j in range(n):
        for i in range(n):
            y0, y1 = j * h / n, (j + 1) * h / n
            x0, x1 = i * w / n, (i + 1) * w / n
            m = (y1 - y0) * 0.22
            core = a[int(y0 + m):max(int(y1 - m), int(y0 + m) + 1), int(x0 + m):max(int(x1 - m), int(x0 + m) + 1)]
            out[j, i] = np.median(core.reshape(-1, 3), axis=0)
    return out


def to_ramps(cols, names, centre=0.5, spread=0.3):
    """Each pixel to the closest ramp, then to a step of it by brightness
    rank; centre and spread shape how the steps are shared."""
    ramps = [ramp(n) for n in names]
    lab = _lab(cols)
    # Which ramp: the closest colour of any of its steps, by hue and chroma
    # more than by lightness.
    best = np.full(cols.shape[:2], np.inf)
    which = np.zeros(cols.shape[:2], int)
    for k, r in enumerate(ramps):
        rl = _lab(r)
        d = ((lab[..., None, 1:] - rl[:, 1:]) ** 2).sum(-1) + 0.3 * (lab[..., None, 0] - rl[:, 0]) ** 2
        d = d.min(-1)
        which = np.where(d < best, k, which)
        best = np.minimum(d, best)
    out = np.zeros(cols.shape, np.uint8)
    for k, r in enumerate(ramps):
        sel = which == k
        if not sel.any():
            continue
        light = lab[..., 0][sel]
        rank = light.argsort().argsort() / max(1, len(light) - 1)
        # Ground is calmer than the things on it: most pixels in the middle
        # half-tones, the darkest and lightest steps only as accents.
        n = len(r)
        w = np.exp(-(((np.arange(n) - centre * (n - 1)) / (n * spread)) ** 2))
        edges = np.cumsum(w) / w.sum()
        out[sel] = r[np.minimum(np.searchsorted(edges, rank), n - 1)]
    return out


def seam(px):
    """How different the opposite edges are, against neighbouring columns."""
    a = px.astype(float)
    across = np.abs(a[:, 0] - a[:, -1]).mean() + np.abs(a[0] - a[-1]).mean()
    inside = np.abs(a[:, 1:] - a[:, :-1]).mean() + np.abs(a[1:] - a[:-1]).mean()
    return across / max(inside, 1e-9)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--preview")
    args = ap.parse_args()
    m = json.loads(Path(args.manifest).read_text())
    out = ROOT / m["out"]
    out.mkdir(parents=True, exist_ok=True)
    shown = []
    for name, spec in m["materials"].items():
        src = Image.open(ROOT / spec["file"])
        px = to_ramps(blocks(src, spec.get("size", 64)), spec["ramps"], spec.get("centre", 0.5), spec.get("spread", 0.3))
        Image.fromarray(px, "RGB").save(out / f"{name}.png")
        s = seam(px)
        print(f"{name:16s} {px.shape[1]}x{px.shape[0]} seam {s:4.2f}{'  <- visible seams' if s > 1.6 else ''}")
        shown.append((name, px))
    if args.preview:
        k, cols = 3, 4
        cell = 64 * 2 * k
        sheet = Image.new("RGB", (cols * (cell + 8), ((len(shown) + cols - 1) // cols) * (cell + 24)), (40, 36, 44))
        d = ImageDraw.Draw(sheet)
        for i, (name, px) in enumerate(shown):
            tile = Image.fromarray(px, "RGB")
            two = Image.new("RGB", (tile.width * 2, tile.height * 2))
            for oy in (0, 1):
                for ox in (0, 1):
                    two.paste(tile, (ox * tile.width, oy * tile.height))
            two = two.resize((two.width * k, two.height * k), Image.NEAREST).crop((0, 0, cell, cell))
            x, y = (i % cols) * (cell + 8), (i // cols) * (cell + 24)
            sheet.paste(two, (x, y))
            d.text((x, y + cell + 6), name, fill=(240, 232, 214))
        sheet.save(args.preview)


if __name__ == "__main__":
    main()
