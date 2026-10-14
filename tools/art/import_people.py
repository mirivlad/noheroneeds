#!/usr/bin/env python3
"""Import tool, people (ADR-0008, brief 003): reference sheets (4 views in a
row: front, three-quarter front-right, right, back) -> an A1 character sheet
for the game (ART_STANDARD v2, 8: 48x48 frames, feet at (24, 45); rows S,
SE, E, NE, N, the west side mirrored; columns idle, step A, step B).

Every reference is drawn on the same body, so the tool:
  1. cuts the four views and reads each on its own block grid, scaled so
     the body is 32 pixels tall (hair sheets: the body under the hair);
  2. puts them on the frame by the feet line and the middle of the feet;
  3. takes a hair layer from a hair sheet: the pixels that differ from the
     bare body in the head, in the hair's own colours;
  4. maps colours to the master palette (skin, clothes, nature), draws the
     one dark warm outline of people over the silhouette's edge;
  5. makes the steps by moving the legs a pixel.

Usage: tools/art/import_people.py tools/art/imports/003.json [--preview P.png]
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from import_sheet import ROOT, Palette, clean, crop, find_grid, find_objects, load, sample

F = 48
FEET = (24, 45)
BODY_H = 32
VIEWS = ["s", "se", "e", "n"]           # the order on a reference sheet
ROWS = ["s", "se", "e", "ne", "n"]      # the order of the game's sheet
OUTLINE = (0x2c, 0x20, 0x1e)


def views(path, height, extra_top=0):
    """The four views of a sheet as RGBA arrays (one colour per block).
    height: the body's height in sprite pixels; extra_top: what the hair
    adds above it, so the body under it still comes out `height` tall."""
    rgb, alpha = load(path)
    objs, lab = find_objects(alpha, min_area=4000)
    objs = sorted(objs, key=lambda o: o.box[0])[:4]
    out = []
    for o in objs:
        c, a = crop(rgb, alpha, o, lab)
        p = (o.box[3] - o.box[1]) / (height + extra_top)
        p, fx, fy = find_grid(c, a > 200, p=p)
        cols, mask = sample(c, a, p, fx, fy)
        mask, _ = clean(mask)
        ys, xs = np.nonzero(mask)
        cols, mask = cols[ys.min():ys.max() + 1, xs.min():xs.max() + 1], mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
        img = np.zeros(mask.shape + (4,), float)
        img[..., :3] = cols
        img[..., 3] = mask
        out.append(img)
    return out


def place(img):
    """A view on a 48x48 frame: feet line on FEET[1], the feet's middle on FEET[0]."""
    h, w = img.shape[:2]
    feet = np.nonzero(img[h - 3:, :, 3].any(0))[0]
    mid = int(round((feet.min() + feet.max()) / 2)) if len(feet) else w // 2
    frame = np.zeros((F, F, 4), float)
    ox, oy = FEET[0] - mid, FEET[1] + 1 - h
    for y in range(h):
        for x in range(w):
            fx, fy = x + ox, y + oy
            if 0 <= fx < F and 0 <= fy < F and img[y, x, 3]:
                frame[fy, fx] = img[y, x]
    return frame


def hair_layer(hair, body):
    """Hair: pixels of the hair view closer in colour to the hair than to the
    bare body's skin and clothes, joined to the mass of hair at the crown
    (so the eyes and the mouth stay out)."""
    from scipy import ndimage
    from import_sheet import _lab
    solid = hair[..., 3] > 0
    ys = np.nonzero(solid.any(1))[0]
    top = ys.min()
    hl = _lab(hair[..., :3])
    # The crown's colours are hair; the bare body's colours are not.
    crown = hl[top:top + 3][solid[top:top + 3]]
    bare = _lab(body[..., :3])[body[..., 3] > 0]
    d_hair = np.sqrt(((hl[..., None, :] - crown[None, None]) ** 2).sum(-1)).min(-1)
    d_bare = np.sqrt(((hl[..., None, :] - bare[None, None]) ** 2).sum(-1)).min(-1)
    sel = solid & (d_hair < d_bare)
    lab, n = ndimage.label(sel)
    keep = set(lab[top:top + 3][sel[top:top + 3]].ravel()) - {0}
    sel = np.isin(lab, list(keep))
    layer = np.zeros_like(hair)
    layer[sel] = hair[sel]
    return layer


def over(base, top):
    out = base.copy()
    m = top[..., 3] > 0
    out[m] = top[m]
    return out


def finish(frame, pal):
    """Palette colours and the people outline on the silhouette's edge."""
    mask = frame[..., 3] > 0
    idx = pal.nearest(frame[..., :3])
    out = np.zeros((F, F, 4), np.uint8)
    out[..., :3] = pal.rgb[idx]
    out[..., 3] = mask * 255
    edge = mask & ~(np.roll(mask, 1, 0) & np.roll(mask, -1, 0) & np.roll(mask, 1, 1) & np.roll(mask, -1, 1))
    out[edge, :3] = OUTLINE
    return out


def step(frame, side, hip):
    """A step: the legs below the hip move a pixel to one side."""
    out = frame.copy()
    legs = frame[hip:].copy()
    out[hip:] = 0
    out[hip:] = np.roll(legs, side, axis=1)
    return out


def build(m, pal):
    inc = ROOT / m["dir"]
    body = [place(v) for v in views(inc / "body.png", BODY_H)]
    look = m["look"]
    outfit = [place(v) for v in views(inc / f"{look['outfit']}.png", BODY_H)]
    frames = {}
    hair = None
    if look.get("hair"):
        hv = [place(v) for v in views(inc / f"{look['hair']}.png", BODY_H, look.get("hair_extra", 1))]
        hair = [hair_layer(h, b) for h, b in zip(hv, body)]
    for k, view in enumerate(VIEWS):
        f = outfit[k]
        if hair:
            f = over(f, hair[k])
        frames[view] = f
    # The back three-quarter view is not in the references yet: the back.
    frames["ne"] = frames["n"]
    hip = FEET[1] - int(BODY_H * 0.29)
    sheet = np.zeros((len(ROWS) * F, 3 * F, 4), np.uint8)
    for r, view in enumerate(ROWS):
        f = finish(frames[view], pal)
        for c, side in enumerate((0, 1, -1)):
            sheet[r * F:(r + 1) * F, c * F:(c + 1) * F] = step(f, side, hip) if side else f
    return Image.fromarray(sheet, "RGBA")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--preview")
    args = ap.parse_args()
    m = json.loads(Path(args.manifest).read_text())
    pal = Palette(("skin", "clothes", "nature", "build"))
    sheet = build(m, pal)
    out = ROOT / m["out"]
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    print("wrote", out.relative_to(ROOT), sheet.size)
    if args.preview:
        k = 4
        big = Image.new("RGBA", (sheet.width * k, sheet.height * k), (122, 140, 90, 255))
        big.alpha_composite(sheet.resize((sheet.width * k, sheet.height * k), Image.NEAREST))
        d = ImageDraw.Draw(big)
        for r, v in enumerate(ROWS):
            d.text((2, r * F * k + 2), v, fill=(255, 255, 255))
        big.save(args.preview)


if __name__ == "__main__":
    main()
