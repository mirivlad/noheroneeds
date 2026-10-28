#!/usr/bin/env python3
"""Foliage with something drawn on it (the author, 28.10.2026: "a spruce's branch
and a leaf are one flat colour, with no needles or veins: cut out of paper").

The Stylized Nature kit (Quaternius, CC0) leaves its pictures flat for a shader
of its own; we draw the detail into copies instead, next to them:

    Leaf_Pine_C.png          -> Leaf_Pine_C_Detail.png: a twig up the middle,
                                needles off it in a herringbone, lighter tips;
    Leaves_NormalTree_C.png,
    Leaves_TwistedTree_C.png -> *_Detail.png: every leaf a midrib and side
                                veins, lit toward its tip.

The cut-out (alpha) is kept as it is. ModelLibrary3D takes a *_Detail.png
where there is one.

    python3 tools/art/detail_foliage.py
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
NATURE = os.path.join(ROOT, "assets", "experiment_3d", "nature")


def _base(img):
    a = np.asarray(img).astype(np.float32)
    mask = a[:, :, 3] > 40
    colour = a[:, :, :3][mask].mean(axis=0)
    return a, mask, colour


def pine(name):
    img = Image.open(os.path.join(NATURE, name)).convert("RGBA")
    w, h = img.size
    a, mask, green = _base(img)
    ys, xs = np.nonzero(mask)
    top, bottom = ys.min(), ys.max()
    cx = int(np.median(xs))
    # Light toward the tip, darker deep in the branch.
    rows = np.linspace(0, 1, h)[:, None]
    shade = 0.78 + 0.34 * (1 - np.clip((rows - top / h) / max((bottom - top) / h, 1e-3), 0, 1))
    out = a.copy()
    out[:, :, :3] = np.clip(green * shade[:, :, None], 0, 255)
    layer = Image.fromarray(out.astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(layer)
    dark = tuple(int(c) for c in green * 0.55) + (255,)
    light = tuple(int(min(255, c)) for c in green * 1.35 + np.array([18, 22, 0])) + (255,)
    # Needles: rows off the twig, up and out, as far as the branch goes.
    rows_n = 34
    step = (bottom - top) / rows_n
    for i in range(rows_n + 1):
        y = bottom - i * step
        for side in (-1, 1):
            length = 0
            while True:
                px = int(cx + side * (length + 1))
                py = int(y - (length + 1) * 0.55)
                if px < 0 or px >= w or py < 0 or not mask[py, px]:
                    break
                length += 1
            if length < 6:
                continue
            end = (cx + side * length, y - length * 0.55)
            d.line([(cx, y), end], fill=dark, width=max(10, w // 120))
            d.line([(cx, y - w // 400), (end[0], end[1] - w // 400)], fill=light, width=max(5, w // 260))
    # The twig up the middle, thick at the base.
    for i in range(24):
        t0, t1 = i / 24, (i + 1) / 24
        y0 = bottom - (bottom - top) * t0 * 0.95
        y1 = bottom - (bottom - top) * t1 * 0.95
        d.line([(cx, y0), (cx, y1)], fill=(92, 62, 34, 255), width=int(max(4, (w // 70) * (1 - t0 * 0.8))))
    out = np.asarray(layer).copy()
    out[:, :, 3] = a[:, :, 3]  # the cut-out as it was
    out[~mask, :3] = a[~mask, :3]
    Image.fromarray(out.astype(np.uint8), "RGBA").save(os.path.join(NATURE, name.replace(".png", "_Detail.png")))


def leaves(name):
    img = Image.open(os.path.join(NATURE, name)).convert("RGBA")
    w, h = img.size
    a, mask, green = _base(img)
    labels, count = ndimage.label(mask)
    out = a.copy()
    layer = Image.fromarray(out.astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(layer)
    middle = np.array([w / 2, h / 2])
    for k in range(1, count + 1):
        ys, xs = np.nonzero(labels == k)
        if xs.size < 200:
            continue
        pts = np.stack([xs, ys], axis=1).astype(np.float32)
        centre = pts.mean(axis=0)
        cov = np.cov((pts - centre).T)
        vals, vecs = np.linalg.eigh(cov)
        axis = vecs[:, 1]
        half = 2.0 * math.sqrt(vals[1])
        # The leaf's base is toward the middle of the picture (they fan out from it).
        if np.dot(axis, centre - middle) < 0:
            axis = -axis
        base = centre - axis * half
        tip = centre + axis * half
        across = np.array([-axis[1], axis[0]])
        # Lit toward its tip, darker at its base.
        proj = ((pts - base) @ axis) / max(2 * half, 1.0)
        for (x, y), p in zip(pts.astype(int), proj):
            out[y, x, :3] = np.clip(green * (0.8 + 0.35 * np.clip(p, 0, 1)), 0, 255)
        layer = Image.fromarray(out.astype(np.uint8), "RGBA")
        d = ImageDraw.Draw(layer)
        vein = tuple(int(min(255, c)) for c in green * 1.45 + np.array([20, 24, 4])) + (255,)
        width = max(3, int(half / 14))
        d.line([tuple(base), tuple(tip)], fill=vein, width=width)
        span = math.sqrt(vals[0]) * 1.6
        for t in (0.25, 0.45, 0.65):
            at = base + axis * (2 * half * t)
            for side in (-1, 1):
                end = at + axis * span * 0.7 + across * side * span
                d.line([tuple(at), tuple(end)], fill=vein, width=max(2, width * 2 // 3))
        out = np.asarray(layer).astype(np.float32).copy()
    out[:, :, 3] = a[:, :, 3]
    out[~mask, :3] = a[~mask, :3]
    Image.fromarray(out.astype(np.uint8), "RGBA").save(os.path.join(NATURE, name.replace(".png", "_Detail.png")))


if __name__ == "__main__":
    pine("Leaf_Pine_C.png")
    for n in ("Leaves_NormalTree_C.png", "Leaves_TwistedTree_C.png"):
        leaves(n)
    print("detail drawn")
