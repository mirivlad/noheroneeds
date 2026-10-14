#!/usr/bin/env python3
"""Import tool, people as paper dolls (ADR-0001, ADR-0008, brief 003).

References are drawn on one body: four views in a row (front, three-quarter
front-right, right, back) plus a three-quarter back view on its own sheet
(<name>_ne.png). The tool makes the body plan's sheets for the game:

  1. each view is read on its own block grid, scaled so the body is 32
     pixels tall (under hair: hair adds a little on top), and put on a
     48x48 frame by the feet line and the middle of the feet (24, 45);
  2. the bare body gives the TEMPLATE: for every view a map of parts —
     head, torso, the two arms, the two legs;
  3. layers are cut from the references: hair by colour (hair, not skin,
     joined to the crown); clothes are the outfit's pixels that are not
     skin, split by the template into torso, legs and feet;
  4. every layer is animated by the SAME movements of the template's parts
     (idle 4 frames: breathing; walk 6 frames: legs, arms, a bob), so all
     layers stay on the body pixel for pixel in every frame;
  5. colours go to the master palette; the outer edge of the figure gets the
     dark warm outline of people, seams inside a softer shade.

Sheets: rows S, SE, E, NE, N (the west side is mirrored in the game),
columns idle 0-3, walk 4-9. Output and what each sheet draws: the manifest
(tools/art/imports/003.json), read again by make_placeholders.py.

Usage: tools/art/import_people.py tools/art/imports/003.json [--preview P.png]
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

from import_sheet import ROOT, Palette, _lab, clean, crop, find_grid, find_objects, load, sample

F = 48
FEET = (24, 45)
BODY_H = 32
SHEET_VIEWS = ["s", "se", "e", "n"]      # the order on a reference sheet
ROWS = ["s", "se", "e", "ne", "n"]       # the order of the game's sheet
IDLE, WALK = 4, 6
OUTLINE = np.array([0x2c, 0x20, 0x1e])
HEAD, TORSO, ARM_L, ARM_R, LEG_L, LEG_R = 1, 2, 3, 4, 5, 6
# People's colours: skin, cloth, leather, wood, metal, hair browns; no
# leaves or grass, so a grey shirt never turns green.
PEOPLE_RAMPS = ["skin_1", "skin_2", "skin_3", "skin_4", "skin_5", "skin_6", "linen", "forest_cloth", "plum_cloth",
                "earth_cloth", "slate_cloth", "leather", "bark", "dirt", "sand", "stone", "birch_bark", "log",
                "plank", "metal", "gold", "roof_tile"]


# --- reading the references ------------------------------------------------

def read_figure(c, a, height):
    rows = np.nonzero((a > 160).any(1))[0]
    p = (rows.max() - rows.min() + 1) / height
    p, fx, fy = find_grid(c, a > 200, p=p)
    cols, mask = sample(c, a, p, fx, fy)
    mask, _ = clean(mask)
    ys, xs = np.nonzero(mask)
    img = np.zeros(mask.shape + (4,), float)
    img[..., :3] = cols
    img[..., 3] = mask
    return img[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def figures(path, count, height):
    rgb, alpha = load(path)
    objs, lab = find_objects(alpha, min_area=4000)
    objs = sorted(sorted(objs, key=lambda o: -(o.box[3] - o.box[1]))[:count], key=lambda o: o.box[0])
    return [read_figure(*crop(rgb, alpha, o, lab), height) for o in objs]


def place(img):
    """On a 48x48 frame: feet line on FEET[1], the feet's middle on FEET[0]."""
    h, w = img.shape[:2]
    feet = np.nonzero(img[h - 3:, :, 3].any(0))[0]
    mid = int(round((feet.min() + feet.max()) / 2)) if len(feet) else w // 2
    frame = np.zeros((F, F, 4), float)
    ox, oy = FEET[0] - mid, FEET[1] + 1 - h
    ys, xs = np.nonzero(img[..., 3])
    ok = (ys + oy >= 0) & (ys + oy < F) & (xs + ox >= 0) & (xs + ox < F)
    frame[ys[ok] + oy, xs[ok] + ox] = img[ys[ok], xs[ok]]
    return frame


def views(inc, name, extra_top=0):
    """{view: frame} of one reference: its sheet and its back three-quarter."""
    h = BODY_H + extra_top
    out = dict(zip(SHEET_VIEWS, (place(f) for f in figures(inc / f"{name}.png", 4, h))))
    ne = inc / f"{name}_ne.png"
    out["ne"] = place(figures(ne, 1, h)[0]) if ne.exists() else out["n"]
    return out


# --- the template ----------------------------------------------------------

def skin_of(body):
    """The skin colours of the bare body: the inside of its head (not the
    drawn edge, not the eyes)."""
    m = body[..., 3] > 0
    inner = ndimage.binary_erosion(m, iterations=2)
    top = np.nonzero(m.any(1))[0].min()
    band = np.zeros_like(m)
    band[top + 2:top + 9] = True
    lab = _lab(body[..., :3])
    sel = inner & band & (lab[..., 0] > 50)
    return lab[sel]


def is_skin(img, skin, tol=14.0):
    lab = _lab(img[..., :3])
    d = np.sqrt(((lab[..., None, :] - skin[None, None]) ** 2).sum(-1)).min(-1)
    return (img[..., 3] > 0) & (d < tol)


def template(body, view):
    """Part map of the bare body in one view; and its key rows."""
    m = body[..., 3] > 0
    rows = np.nonzero(m.any(1))[0]
    top, feet = rows.min(), rows.max()
    h = feet - top + 1
    # The neck: the narrowest row between the chin and the shoulders.
    widths = m.sum(1)
    band = range(top + int(h * 0.24), top + int(h * 0.40))
    neck = min(band, key=lambda y: widths[y])
    hip = feet - int(round(h * 0.30))
    parts = np.zeros((F, F), int)
    parts[m & (np.arange(F)[:, None] <= neck)] = HEAD
    skin = is_skin(body, skin_of(body))
    xs = np.nonzero(m[neck + 1:hip + 1].any(0))[0]
    mid = int(round(np.median(np.nonzero(m[feet - 2:feet + 1])[1])))
    # Torso rows: the clothed middle is the torso, skin beside it the arms.
    # The torso's sides are the same for all rows (the median of the rows),
    # so an arm is whole and moves as one.
    los, his = [], []
    for y in range(neck + 2, hip + 1):
        cloth = np.nonzero(m[y] & ~skin[y])[0]
        if len(cloth):
            los.append(cloth.min())
            his.append(cloth.max())
    lo, hi = int(np.median(los)), int(np.median(his))
    for y in range(neck + 1, hip + 1):
        cols = np.nonzero(m[y])[0]
        if view == "e":
            parts[y, cols] = TORSO
        else:
            parts[y, cols] = np.where(cols < lo, ARM_L, np.where(cols > hi, ARM_R, TORSO))
    # Hands hanging below the hip are arms, joined to the arm above them.
    legs_zone = m & (np.arange(F)[:, None] > hip)
    lab, n = ndimage.label(legs_zone)
    for k in range(1, n + 1):
        comp = lab == k
        ys, xs_ = np.nonzero(comp)
        if ys.max() < feet - 3:  # does not reach the ground: a hand
            parts[comp] = ARM_L if xs_.mean() < mid else ARM_R
        else:
            for y, x in zip(ys, xs_):
                parts[y, x] = LEG_L if x < mid else LEG_R
    if view == "e":
        # From the side the near arm hangs over the torso: the largest patch
        # of skin there, with its rows filled across.
        lab2, n2 = ndimage.label(skin & (parts == TORSO))
        if n2:
            big = 1 + int(np.argmax(ndimage.sum(np.ones_like(lab2), lab2, range(1, n2 + 1))))
            arm = lab2 == big
            for y in np.nonzero(arm.any(1))[0]:
                xs2 = np.nonzero(arm[y])[0]
                arm[y, xs2.min():xs2.max() + 1] = True
            parts[arm & m] = ARM_R
    return parts, dict(top=top, neck=neck, hip=hip, feet=feet, mid=mid)


def part_of(parts, layer_mask, prefer=None):
    """Parts for a layer's pixels: the template's part under each; outside
    the body (long hair, wide clothes) the nearest part, or `prefer`."""
    out = parts.copy()
    if prefer is not None:
        out[layer_mask] = prefer
        return out
    outside = layer_mask & (parts == 0)
    if outside.any():
        _, idx = ndimage.distance_transform_edt(parts == 0, return_indices=True)
        out[outside] = parts[idx[0][outside], idx[1][outside]]
    return out


# --- animation ---------------------------------------------------------------

def moves(view, anim, k):
    """{part: (dx, dy)} for frame k of an animation in a view, and the side
    view's stride (legs swing from the hip, drawn twice)."""
    mv = {p: [0, 0] for p in (HEAD, TORSO, ARM_L, ARM_R, LEG_L, LEG_R)}
    upper = (HEAD, TORSO, ARM_L, ARM_R)
    if anim == "idle":
        for p in upper:
            mv[p][1] = [0, 0, 1, 1][k]  # breathing: the upper body sinks a pixel
        return mv, 0
    phase = 2 * np.pi * k / WALK
    swing = np.cos(phase)
    bob = -1 if k in (1, 4) else 0  # passing frames: the body rises
    for p in upper:
        mv[p][1] = bob
    if view == "e":
        # The arm hangs over the torso from the side; there is no torso drawn
        # under it to show if it swung, so it moves with the body.
        return mv, int(round(2.5 * swing))
    # Front, back, three-quarters: the legs lift in turn and step aside a
    # little on the diagonals.
    side = 1 if view in ("se", "ne") else 0
    mv[LEG_L][0] = int(round(swing)) * side
    mv[LEG_R][0] = -int(round(swing)) * side
    mv[LEG_L][1] = -1 if np.sin(phase) > 0.3 else 0
    mv[LEG_R][1] = -1 if np.sin(phase) < -0.3 else 0
    return mv, 0


DRAW = [LEG_R, LEG_L, TORSO, ARM_L, ARM_R, HEAD]  # back to front within a layer


def _put(out, layer, sel, dx, dy, shade=1.0):
    ys, xs = np.nonzero(sel)
    ty, tx = ys + dy, xs + dx
    ok = (ty >= 0) & (ty < F) & (tx >= 0) & (tx < F)
    px = layer[ys[ok], xs[ok]].copy()
    px[:, :3] *= shade
    out[ty[ok], tx[ok]] = px


def animate(layer, parts, view, anim, k, rows):
    mv, stride = moves(view, anim, k)
    out = np.zeros_like(layer)
    has = layer[..., 3] > 0
    if mv[TORSO][1] < 0:
        # The body rises: its lowest rows stay too, so the waist stretches
        # instead of parting from the legs.
        low = has & (parts == TORSO) & (np.arange(F)[:, None] > rows["hip"] + mv[TORSO][1])
        _put(out, layer, low, 0, 0)
    if view == "e":
        # The side view's legs are one drawing: the far leg is that drawing
        # leaning back (a little darker), the near one leaning forward.
        legs = has & ((parts == LEG_L) | (parts == LEG_R))
        hip, feet = rows["hip"], rows["feet"]
        for sign, shade in ((-1, 0.78), (1, 1.0)):
            for y in range(hip, F):
                lean = int(round(sign * stride * (y - hip) / max(1, feet - hip)))
                lift = -1 if sign * stride < 0 and y > feet - 4 and abs(stride) > 1 else 0
                _put(out, layer, legs & (np.arange(F)[:, None] == y), lean, lift, shade)
        for p in (TORSO, ARM_L, ARM_R, HEAD):
            _put(out, layer, has & (parts == p), *mv[p])
        return out
    for p in DRAW:
        _put(out, layer, has & (parts == p), *mv[p])
    return out


# --- layers ------------------------------------------------------------------

def hair_layer(hair, body):
    solid = hair[..., 3] > 0
    top = np.nonzero(solid.any(1))[0].min()
    hl = _lab(hair[..., :3])
    crown = hl[top:top + 3][solid[top:top + 3]]
    bare = _lab(body[..., :3])[body[..., 3] > 0]
    d_hair = np.sqrt(((hl[..., None, :] - crown[None, None]) ** 2).sum(-1)).min(-1)
    d_bare = np.sqrt(((hl[..., None, :] - bare[None, None]) ** 2).sum(-1)).min(-1)
    sel = solid & (d_hair < d_bare)
    lab, _ = ndimage.label(sel)
    keep = set(lab[top:top + 3][sel[top:top + 3]].ravel()) - {0}
    out = np.zeros_like(hair)
    sel = np.isin(lab, list(keep))
    out[sel] = hair[sel]
    return out


def cloth_layers(outfit, body, rows):
    """An outfit's clothes split into torso, legs and feet. Clothes are its
    pixels that are not skin, below the neck, without the outline the
    generation drew (around the figure, and dark lines along bare skin):
    the tool draws its own. Torso and legs part at the waist, the row where
    the clothes' colour changes most; the feet are the lowest sixth."""
    skin = is_skin(outfit, skin_of(body), tol=12.0)
    solid = outfit[..., 3] > 0
    ring = solid & ~ndimage.binary_erosion(solid)
    lab = _lab(outfit[..., :3])
    dark_line = (lab[..., 0] < 32) & ndimage.binary_dilation(skin)
    cloth = solid & ~skin & ~ring & ~dark_line
    y = np.arange(F)[:, None]
    cloth &= y > rows["neck"]
    means = [lab[r][cloth[r]].mean(0) if cloth[r].sum() >= 3 else None for r in range(F)]
    band = range(rows["neck"] + 4, rows["hip"] + 3)
    steps = [(np.abs(means[r + 1] - means[r]).sum(), r) for r in band
             if means[r] is not None and means[r + 1] is not None]
    waist = max(steps)[1] if steps else rows["hip"]
    ankle = rows["feet"] - int(round((rows["feet"] - rows["top"]) * 0.17))
    out = {}
    for name, sel in (("torso", cloth & (y <= waist)),
                      ("legs", cloth & (y > waist) & (y < ankle)),
                      ("feet", cloth & (y >= ankle))):
        lay = np.zeros_like(outfit)
        lay[sel] = outfit[sel]
        out[name] = lay
    return out


# --- finishing ---------------------------------------------------------------

def finish(frame, under, pal):
    """Palette colours; where the layer's edge is the figure's outer edge
    (nothing of it nor of the body under it beside), the people outline;
    elsewhere on its edge a darker step of its own colour."""
    mask = frame[..., 3] > 0
    idx = pal.nearest(frame[..., :3])
    out = np.zeros((F, F, 4), np.uint8)
    out[..., :3] = pal.rgb[idx]
    out[..., 3] = mask * 255
    union = mask | under
    pad = np.pad(union, 1)
    inner = pad[:-2, 1:-1] & pad[2:, 1:-1] & pad[1:-1, :-2] & pad[1:-1, 2:]
    out[mask & ~inner, :3] = OUTLINE
    padm = np.pad(mask, 1)
    seam = mask & inner & ~(padm[:-2, 1:-1] & padm[2:, 1:-1] & padm[1:-1, :-2] & padm[1:-1, 2:])
    out[seam, :3] = pal.rgb[np.array(pal.darker)[idx[seam]]]
    return out


def sheet(layer_by_view, tmpl, body_frames, pal, is_body):
    s = np.zeros((len(ROWS) * F, (IDLE + WALK) * F, 4), np.uint8)
    for r, view in enumerate(ROWS):
        parts, _ = tmpl[view]
        lay = layer_by_view[view]
        lp = part_of(parts, lay[..., 3] > 0, HEAD if lay is not None and getattr(lay, "head", False) else None)
        for c in range(IDLE + WALK):
            anim, k = ("idle", c) if c < IDLE else ("walk", c - IDLE)
            rows = tmpl[view][1]
            fr = animate(lay, lp, view, anim, k, rows)
            under = np.zeros((F, F), bool) if is_body else animate(body_frames[view], parts, view, anim, k, rows)[..., 3] > 0
            s[r * F:(r + 1) * F, c * F:(c + 1) * F] = finish(fr, under, pal)
    return Image.fromarray(s, "RGBA")


class HeadLayer(np.ndarray):
    """A layer that moves with the head wherever its pixels are (hair)."""
    head = True


def build(m, pal):
    inc = ROOT / m["dir"]
    out = ROOT / m["out"]
    out.mkdir(parents=True, exist_ok=True)
    body = views(inc, m["body"])
    tmpl = {v: template(body[v], v) for v in ROWS}
    made = {"body": sheet(body, tmpl, body, pal, True)}
    for name, spec in m["layers"].items():
        if spec["from"].startswith("hair"):
            src = views(inc, spec["from"], spec.get("extra_top", 1))
            lay = {v: hair_layer(src[v], body[v]).view(HeadLayer) for v in ROWS}
        else:
            src = views(inc, spec["from"])
            lay = {v: cloth_layers(src[v], body[v], tmpl[v][1])[spec["part"]] for v in ROWS}
        made[name] = sheet(lay, tmpl, body, pal, False)
    for name, img in made.items():
        img.save(out / f"{name}.png")
    return made


def preview(made, path, look, k=4):
    """The body with a look's layers, every frame, on grass."""
    base = made["body"].copy()
    for name in look:
        base.alpha_composite(made[name])
    big = Image.new("RGBA", (base.width * k, base.height * k), (122, 140, 90, 255))
    big.alpha_composite(base.resize((base.width * k, base.height * k), Image.NEAREST))
    d = ImageDraw.Draw(big)
    for r, v in enumerate(ROWS):
        d.text((2, r * F * k + 2), v, fill=(255, 255, 255))
    big.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--preview")
    args = ap.parse_args()
    m = json.loads(Path(args.manifest).read_text())
    pal = Palette(("skin", "clothes", "nature", "build"), ramps=PEOPLE_RAMPS)
    made = build(m, pal)
    for name, img in made.items():
        print(f"{name:14s} {img.size[0]}x{img.size[1]}")
    if args.preview:
        preview(made, args.preview, m.get("preview", []))


if __name__ == "__main__":
    main()
