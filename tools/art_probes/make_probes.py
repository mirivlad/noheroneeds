#!/usr/bin/env python3
"""Art scale probes for No Hero Needed: one scene, three pixel scales.

Not production art: procedural sketches to compare tile size, chibi size,
outline policy and how much of the world fits on a 1080p screen.
Usage: make_probes.py OUT_DIR [FONT_TTF]
"""
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
FONT = sys.argv[2] if len(sys.argv) > 2 else None


def hx(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


# Ramps go dark -> light.
P = {
    "grass": [hx("2f5d3a"), hx("3f7a3f"), hx("549546"), hx("6fae4f"), hx("93c95e")],
    "dirt": [hx("6b4a32"), hx("8a6242"), hx("a87d52"), hx("c49a68")],
    "water": [hx("1f4a6e"), hx("2a6a94"), hx("3d8cb8"), hx("6cb6d9"), hx("bfe6f2")],
    "leaf": [hx("1f4632"), hx("2c6a3c"), hx("3f8a44"), hx("5ea94b"), hx("8ccb5a")],
    "leaf2": [hx("5a3a1e"), hx("8a4f22"), hx("c06a2a"), hx("e09a3a"), hx("f2c25a")],
    "bark": [hx("3a2618"), hx("5a3c26"), hx("7a5434")],
    "wood": [hx("4a2e1c"), hx("6e4428"), hx("93613a"), hx("b8834e")],
    "roof": [hx("5a2324"), hx("82322c"), hx("a8483a"), hx("c86a4a")],
    "stone": [hx("4c4a52"), hx("6d6b72"), hx("8f8c92"), hx("b4b0b2")],
    "warm": [hx("c8862e"), hx("f2c060"), hx("fde7a0")],
    "skin": [hx("c98a6a"), hx("eab295"), hx("f8d3bd")],
    "flower": [hx("e8546a"), hx("f2d24a"), hx("ffffff"), hx("8a6ad8"), hx("f28a3a")],
    "ink": hx("2a1e26"),
    "white": hx("fbf7ee"),
    "shadow": (20, 40, 30, 70),
}


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))


def h2(x, y, s=0):
    """Deterministic hash -> [0,1)."""
    n = (x * 374761393 + y * 668265263 + s * 2147483647) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFFFF) / float(0x1000000)


def vnoise(x, y, scale, s=0):
    gx, gy = x / scale, y / scale
    x0, y0 = math.floor(gx), math.floor(gy)
    fx, fy = gx - x0, gy - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = h2(x0, y0, s), h2(x0 + 1, y0, s)
    c, d = h2(x0, y0 + 1, s), h2(x0 + 1, y0 + 1, s)
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy


# ---------------------------------------------------------------- scene, tiles
# World layout in tiles; the widest variant shows 40x22.5 tiles.
WORLD_W, WORLD_H = 40, 23
HOUSE = (15, 5, 7, 6)  # x, y, w, h of the visual block (roof+front wall)
POND = (26.6, 14.6, 3.2, 2.0)  # ellipse centre and radii
TREES = [(9, 7, "leaf"), (27, 6, "leaf"), (30, 10, "leaf2"), (6, 15, "leaf"),
         (34, 15, "leaf"), (11, 19, "leaf2"), (3, 7, "leaf"), (37, 5, "leaf2"),
         (23, 3, "leaf")]
BUSHES = [(13, 11), (25, 8.6), (21, 17), (29, 18), (2, 12), (38, 20)]
FENCE = [(8, 11), (14, 11)]  # from x to x on row y
PLAYER = (17.6, 14.2)
NPC = (22.4, 13.2)


def path_dist(tx, ty):
    """Distance (tiles) to the dirt path: door -> down -> right -> off screen."""
    pts = [(18.5, 11.2), (18.5, 15.5), (19.5, 17.0), (24, 18.5), (31, 18.8), (41, 17.5)]
    best = 99
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        dx, dy = bx - ax, by - ay
        t = max(0, min(1, ((tx - ax) * dx + (ty - ay) * dy) / (dx * dx + dy * dy)))
        best = min(best, math.hypot(tx - ax - t * dx, ty - ay - t * dy))
    return best


def draw_ground(img, T, ox, oy, style):
    px = img.load()
    W, H = img.size
    cx, cy, rx, ry = POND
    for y in range(H):
        for x in range(W):
            # world pixel coordinates in "tile units" and tile-periodic coords
            tx, ty = (x + ox) / T, (y + oy) / T
            lx, ly = (x + ox) % T, (y + oy) % T
            tile = (int(tx), int(ty))
            variant = int(h2(*tile, 7) * 4)
            d_pond = ((tx - cx) / rx) ** 2 + ((ty - cy) / ry) ** 2
            if d_pond < 1.0:
                depth = 1 - d_pond
                i = 1 if depth > 0.55 else 2
                if depth < 0.12:
                    i = 3
                c = P["water"][i]
                # horizontal ripples, tile periodic
                if h2(lx // 2, ly, variant + 11) > 0.93 and depth > 0.12:
                    c = P["water"][3 if i < 3 else 4]
                px[x, y] = c
                continue
            if d_pond < 1.18:
                px[x, y] = P["dirt"][3] if d_pond < 1.08 else P["grass"][1]
                continue
            pd = path_dist(tx, ty)
            edge = 0.62 + 0.12 * (vnoise(x + ox, y + oy, T * 0.5, 3) - 0.5)
            if pd < edge:
                c = P["dirt"][2]
                r = h2(lx, ly, variant + 21)
                if r > 0.86:
                    c = P["dirt"][3]
                elif r < 0.10:
                    c = P["dirt"][1]
                if pd > edge - 1.5 / T:
                    c = P["dirt"][1]
                px[x, y] = c
                continue
            # grass: macro tint (smooth, world space) + tile-periodic blades
            m = vnoise(x + ox, y + oy, T * 3, 1) + (h2(x + ox, y + oy, 2) - 0.5) * 0.12
            base = 2 if m > 0.30 else 1
            if m > 0.74:
                base = 3
            c = P["grass"][base]
            r = h2(lx, ly, variant)
            blade = max(1, T // 16)
            if r > 0.90:
                c = P["grass"][min(4, base + 1)]
            elif r < 0.07:
                c = P["grass"][max(0, base - 1)]
            # short vertical blades
            if h2(lx, ly - blade, variant) > 0.90 and style["detail"] >= 1:
                c = P["grass"][min(4, base + 1)]
            px[x, y] = c
    # flowers: world-space clusters
    rnd = random.Random(5)
    sz = max(1, T // 16)
    for _ in range(int(WORLD_W * WORLD_H * 0.9)):
        tx, ty = rnd.uniform(0, WORLD_W), rnd.uniform(0, WORLD_H)
        if vnoise(int(tx * 16), int(ty * 16), 50, 9) < 0.55:
            continue
        if path_dist(tx, ty) < 1.0 or ((tx - cx) / rx) ** 2 + ((ty - cy) / ry) ** 2 < 1.5:
            continue
        hx_, hy_ = HOUSE[0], HOUSE[1]
        if hx_ - 0.5 < tx < hx_ + HOUSE[2] + 0.5 and hy_ < ty < hy_ + HOUSE[3] + 0.5:
            continue
        col = P["flower"][rnd.randrange(len(P["flower"]))]
        x, y = int(tx * T - ox), int(ty * T - oy)
        d = ImageDraw.Draw(img)
        if sz == 1:
            d.point((x, y), col)
            d.point((x, y + 1), P["grass"][0])
        else:
            d.rectangle((x, y, x + sz - 1, y + sz - 1), col)
            d.point((x + sz // 2, y - 1), col)
            d.point((x - 1, y + sz // 2), col)
            d.point((x + sz, y + sz // 2), col)
            d.point((x + sz // 2, y + sz), lerp(col, P["white"], 0.5))
            d.rectangle((x + sz // 2, y + sz + 1, x + sz // 2, y + sz + sz), P["grass"][0])


def shadow(img, x, y, w, h):
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(lay).ellipse((x, y, x + w, y + h), P["shadow"])
    img.alpha_composite(lay)


# ------------------------------------------------------------ sprite helpers
def outline(spr, style):
    """Add a 1px outline around opaque pixels, per the variant's policy."""
    if style["outline"] is None:
        return spr
    w, h = spr.size
    src = spr.load()
    out = spr.copy()
    dst = out.load()
    for y in range(h):
        for x in range(w):
            if src[x, y][3]:
                continue
            nb = [src[x + dx, y + dy] for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
                  if 0 <= x + dx < w and 0 <= y + dy < h and src[x + dx, y + dy][3]]
            if nb:
                if style["outline"] == "ink":
                    dst[x, y] = P["ink"]
                else:  # coloured: darkened neighbour
                    c = nb[0]
                    dst[x, y] = (int(c[0] * 0.35), int(c[1] * 0.3), int(c[2] * 0.38), 255)
    return out


def tree(T, kind, style, seed):
    rnd = random.Random(seed)
    W, H = int(T * 2.6), int(T * 3.2)
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    px = spr.load()
    ramp = P[kind]
    # trunk
    tw = max(3, T // 4)
    tx0 = W // 2 - tw // 2 + 1
    for y in range(int(H * 0.62), H - 1):
        for x in range(tx0, tx0 + tw):
            c = P["bark"][1]
            if x == tx0:
                c = P["bark"][2]
            if x == tx0 + tw - 1:
                c = P["bark"][0]
            px[x, y] = c
    # roots flare
    px[tx0 - 1, H - 2] = P["bark"][1]
    px[tx0 + tw, H - 2] = P["bark"][0]
    # canopy: blobs
    blobs = [(W * 0.5, H * 0.36, W * 0.36)]
    for _ in range(6):
        a = rnd.uniform(0, math.tau)
        r = W * rnd.uniform(0.12, 0.2)
        blobs.append((W * 0.5 + math.cos(a) * W * 0.2, H * 0.38 + math.sin(a) * H * 0.13, r))
    for y in range(H):
        for x in range(W):
            inside = None
            for bx, by, br in blobs:
                d = math.hypot(x + 0.5 - bx, (y + 0.5 - by) * 1.1)
                if d < br:
                    # light from top-left, per blob
                    lt = ((bx - x) + (by - y)) / (br * 1.6) + 0.15
                    inside = lt if inside is None else max(inside, lt)
            if inside is None:
                continue
            g = (y / H - 0.15) * -0.8
            v = inside + g
            n = h2(x // max(1, T // 16), y // max(1, T // 16), seed)
            v += (n - 0.5) * (0.35 if style["detail"] >= 1 else 0.15)
            i = 1 if v < -0.05 else 2 if v < 0.3 else 3 if v < 0.62 else 4
            if style["detail"] == 0:
                i = min(3, i)
            px[x + 1, y + 1] = ramp[i]
    # dark underside
    for y in range(1, H):
        for x in range(W):
            if px[x, y][3] and px[x, y] in ramp and y > H * 0.48 and not px[x, min(H, y + 2)][3]:
                px[x, y] = ramp[0]
    if style["detail"] >= 2:  # a few fruit/blossom dots
        for _ in range(5):
            x, y = int(W * rnd.uniform(0.25, 0.75)), int(H * rnd.uniform(0.18, 0.5))
            if px[x, y][3]:
                c = P["flower"][0] if kind == "leaf" else P["warm"][1]
                px[x, y] = c
                px[x + 1, y] = c
    return outline(spr, style)


def bush(T, style, seed):
    W, H = int(T * 1.2), int(T * 0.9)
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    px = spr.load()
    for y in range(H):
        for x in range(W):
            d = ((x + 0.5 - W / 2) / (W / 2)) ** 2 + ((y + 0.5 - H * 0.55) / (H * 0.5)) ** 2
            if d < 1:
                v = (W / 2 - x) / W + (H / 2 - y) / H + (h2(x, y, seed) - 0.5) * 0.4
                i = 1 if v < -0.2 else 2 if v < 0.25 else 3
                px[x + 1, y + 1] = P["leaf"][i]
    if style["detail"] >= 1:
        for k in range(3):
            x, y = int(W * (0.25 + k * 0.25)), int(H * 0.4) + k % 2
            px[x, y] = P["flower"][2]
    return outline(spr, style)


def house(T, style):
    _, _, tw, th = HOUSE
    W, H = tw * T, th * T
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    px = spr.load()
    s = max(1, T // 16)
    roof_h = int(T * 3.6)
    wall_top = roof_h - s * 2
    # front wall: horizontal logs
    for y in range(wall_top, H - 2 * s):
        for x in range(s, W - s):
            row = (y - wall_top) // (4 * s)
            ly = (y - wall_top) % (4 * s)
            c = P["wood"][2]
            if ly == 0:
                c = P["wood"][0]
            elif ly == 1 * s and style["detail"] >= 1:
                c = P["wood"][3]
            elif h2(x // (3 * s), row, 4) > 0.8 and ly == 2 * s:
                c = P["wood"][1]
            px[x + 1, y + 1] = c
    # stone foundation
    for y in range(H - 2 * s, H):
        for x in range(0, W):
            c = P["stone"][1] if (x // (3 * s) + y // (2 * s)) % 2 else P["stone"][2]
            if y == H - 1:
                c = P["stone"][0]
            px[x + 1, y + 1] = c
    # door
    dw, dh = int(T * 0.9), int(T * 1.45)
    dx0 = W // 2 - dw // 2
    dy0 = H - 2 * s - dh
    d.rectangle((dx0 + 1, dy0 + 1, dx0 + dw, H - 2 * s), P["wood"][0])
    d.rectangle((dx0 + 1 + s, dy0 + 1 + s, dx0 + dw - s, H - 2 * s), P["wood"][1])
    for k in range(1, 3):
        x = dx0 + 1 + k * dw // 3
        d.line((x, dy0 + 1 + s, x, H - 2 * s), P["wood"][0])
    d.rectangle((dx0 + dw - 3 * s, dy0 + dh // 2, dx0 + dw - 2 * s, dy0 + dh // 2 + s - 1), P["warm"][1])
    # windows with warm light
    ww, wh = int(T * 0.9), int(T * 0.8)
    for wx in (int(T * 0.9), W - int(T * 0.9) - ww):
        wy = wall_top + int(T * 0.55)
        d.rectangle((wx + 1, wy + 1, wx + ww, wy + wh), P["wood"][0])
        d.rectangle((wx + 1 + s, wy + 1 + s, wx + ww - s, wy + wh - s), P["warm"][1])
        if style["detail"] >= 1:
            d.rectangle((wx + 1 + s, wy + 1 + s, wx + ww // 2, wy + wh // 2), P["warm"][2])
        d.line((wx + 1 + ww // 2, wy + 1, wx + 1 + ww // 2, wy + wh), P["wood"][0])
        d.line((wx + 1, wy + 1 + wh // 2, wx + ww, wy + 1 + wh // 2), P["wood"][0])
        # flower box
        d.rectangle((wx, wy + wh + 1, wx + ww + 1, wy + wh + 2 * s), P["wood"][1])
        for k in range(ww // (2 * s)):
            d.point((wx + 1 + k * 2 * s, wy + wh), P["flower"][k % 2])
    # roof: shingle rows with eaves overhang, ridge on top
    for y in range(0, roof_h):
        inset = max(0, int((roof_h * 0.18 - y) * 0.9))
        for x in range(inset, W - inset + 2):
            row = y // (3 * s)
            off = (row % 2) * 2 * s
            ridge = int(roof_h * 0.3)
            c = P["roof"][2] if y >= ridge else P["roof"][1]
            ly = y % (3 * s)
            if ly == 3 * s - 1:
                c = P["roof"][0]
            elif ly == 0 and style["detail"] >= 1:
                c = P["roof"][3]
            if (x + off) % (4 * s) == 0 and ly != 3 * s - 1:
                c = P["roof"][1]
            if ridge - s <= y < ridge + s:
                c = P["roof"][3]
            if y < s * 2:
                c = P["roof"][0]
            if x < inset + s or x > W - inset:
                c = P["roof"][0]
            px[x, y] = c
    # eave shadow on wall
    for x in range(1, W + 1):
        for k in range(s):
            px[x, roof_h + k] = P["wood"][0]
    # chimney
    cx0, cw = int(W * 0.7), int(T * 0.7)
    d.rectangle((cx0, -1, cx0 + cw, int(T * 0.9)), P["stone"][2])
    d.rectangle((cx0, -1, cx0 + s - 1, int(T * 0.9)), P["stone"][3])
    d.rectangle((cx0 + cw - s + 1, -1, cx0 + cw, int(T * 0.9)), P["stone"][1])
    d.rectangle((cx0 - s, 0, cx0 + cw + s, s), P["stone"][0])
    return outline(spr, style)


def fence(T, length, style):
    W, H = length * T, T
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    s = max(1, T // 16)
    for k in range(length + 1):
        x = min(W - 2 * s, k * T)
        d.rectangle((x + 1, int(T * 0.15) + 1, x + 2 * s, H), P["wood"][2])
        d.point((x + 1, int(T * 0.15) + 1), P["wood"][3])
    for y in (int(T * 0.35), int(T * 0.65)):
        d.rectangle((1, y, W, y + s), P["wood"][3] if style["detail"] >= 1 else P["wood"][2])
        d.line((1, y + s + 1, W, y + s + 1), P["wood"][1])
    return outline(spr, style)


# ----------------------------------------------------------------- chibi
def chibi(w, h, look, style):
    """Front-facing chibi built from implicit shapes in normalised coords."""
    spr = Image.new("RGBA", (w + 2, h + 4), (0, 0, 0, 0))
    px = spr.load()
    skin, hair, cloth, pants, accent = look["skin"], look["hair"], look["cloth"], look["pants"], look["accent"]
    head_cy, head_ry, head_rx = 0.285, 0.215, 0.44
    for y in range(h):
        for x in range(w):
            u, v = (x + 0.5) / w, (y + 0.5) / h
            c = None
            # legs, then shoes a little wider
            if 0.80 <= v < 0.93 and (0.33 < u < 0.47 or 0.53 < u < 0.67):
                c = pants[1] if u < 0.5 else pants[0]
            if 0.93 <= v and (0.30 < u < 0.47 or 0.53 < u < 0.70):
                c = look["shoes"]
            # neck
            if 0.44 <= v < 0.49 and abs(u - 0.5) < 0.09:
                c = skin[0]
            # body (tunic, flares to the hem)
            bw = 0.2 + (v - 0.47) * 0.42
            if 0.47 <= v < 0.83 and abs(u - 0.5) < bw:
                c = cloth[2] if u < 0.5 else cloth[1]
                if v > 0.80:
                    c = cloth[0]
                if abs(v - 0.67) < 0.022:
                    c = accent
                if look.get("apron") and abs(u - 0.5) < bw * 0.6 and v > 0.55:
                    c = P["white"] if u < 0.56 else lerp(P["white"], cloth[0], 0.25)
            # arms hang slightly out from the body
            if 0.49 <= v < 0.74 and (0.14 < u < 0.27 or 0.73 < u < 0.86):
                c = (cloth[2] if u < 0.5 else cloth[0]) if v < 0.67 else skin[1]
            # head
            dh = ((u - 0.5) / head_rx) ** 2 + ((v - head_cy) / head_ry) ** 2
            if dh < 1:
                c = skin[1] if u < 0.64 else skin[0]
                if dh < 0.3 and u < 0.45 and v > head_cy and style["detail"] >= 1:
                    c = skin[2]
            # hair: a volume larger than the skull, bangs, side locks
            dv = ((u - 0.5) / (head_rx + 0.07)) ** 2 + ((v - head_cy + 0.03) / (head_ry + 0.04)) ** 2
            bang = 0.20 + 0.05 * abs(math.sin(u * math.pi * 3.2)) + look.get("bang", 0)
            side = (u < 0.2 or u > 0.8) and v < look["lock"] and abs(u - 0.5) < head_rx + 0.06 and (dv < 1.0 or v > 0.2)
            if (dv < 1 and v < bang) or side:
                c = hair[2] if u < 0.42 and v < 0.16 else hair[1]
                if dv > 0.72 and (u > 0.6 or v > 0.2):
                    c = hair[0]
            if look.get("scarf") and dv < 1.04 and v < 0.13 + 0.02 * math.cos(u * 6):
                c = look["scarf"] if u < 0.6 else lerp(look["scarf"], P["ink"], 0.3)
            if c:
                px[x + 1, y + 2] = c
    # face: big eyes with a highlight, sized per sprite height
    ew = max(1, round(w * 0.12))
    eh = max(2, round(h * 0.105))
    ey = round(h * 0.285) + 1
    for ex in (round(w * 0.30), round(w * 0.70) - ew):
        for yy in range(eh):
            for xx in range(ew):
                col = look["eyes"] if yy >= eh // 2 else lerp(look["eyes"], P["ink"], 0.6)
                if yy == 0 and eh >= 3:
                    col = P["ink"]
                px[ex + xx + 1, ey + yy + 1] = col
        if eh >= 3:
            px[ex + 1, ey + 2] = P["white"]
            if ew >= 3 and eh >= 5:
                px[ex + ew, ey + eh - 1] = lerp(P["white"], look["eyes"], 0.4)
    if h >= 40:
        for ex in (round(w * 0.30), round(w * 0.70) - ew):
            for xx in range(ew):
                px[ex + xx + 1, ey - 1] = hair[0]
        px[w // 2 + 1, ey + eh + 3] = lerp(skin[0], P["ink"], 0.55)
        px[w // 2, ey + eh + 3] = lerp(skin[0], P["ink"], 0.35)
        for bx in (round(w * 0.22), round(w * 0.78) - 2):
            px[bx + 1, ey + eh + 1] = hx("f0a090")
            px[bx + 2, ey + eh + 1] = hx("f0a090")
    elif h >= 30:
        px[w // 2 + 1, ey + eh + 2] = lerp(skin[0], P["ink"], 0.5)
    return outline(spr, style)


LOOKS = {
    "player": dict(skin=P["skin"], hair=[hx("4a2418"), hx("8a3a20"), hx("b85a2a")],
                   cloth=[hx("1f4d3a"), hx("2f7a52"), hx("48a06a")],
                   pants=[hx("3a3048"), hx("4f4462")], shoes=hx("3a2618"), accent=hx("c8862e"),
                   eyes=hx("2f7a52"), lock=0.40),
    "npc": dict(skin=[hx("b07858"), hx("d6a07e"), hx("ecc4a6")],
                hair=[hx("2a2028"), hx("3c3040"), hx("564658")],
                cloth=[hx("4a3270"), hx("6a4a9a"), hx("8a6ac0")],
                pants=[hx("4a3270"), hx("6a4a9a")], shoes=hx("2a1e26"), accent=hx("c8862e"),
                eyes=hx("4a3270"), lock=0.50, apron=True, scarf=hx("e8546a"), bang=0.02),
}


# ------------------------------------------------------------------- UI bits
def font(size):
    if FONT:
        return ImageFont.truetype(FONT, size)
    return ImageFont.load_default()


def bubble(img, ax, ay, text, ui):
    f = font(16 * ui)
    d = ImageDraw.Draw(img)
    d.fontmode = "1"
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    pad = 4 * ui
    w, h = r - l + pad * 2, b - t + pad * 2
    x0, y0 = int(ax - w // 2), int(ay - h - 5 * ui)
    d.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=3 * ui, fill=P["white"], outline=P["ink"], width=ui)
    for k in range(4 * ui):  # tail
        d.line((ax - 3 * ui + k * 3 // 4, y0 + h + k // 1 - ui + 1, ax + 3 * ui - k, y0 + h + k - ui + 1),
               P["white"])
        d.point((ax - 3 * ui + k * 3 // 4 - 1, y0 + h + k - ui + 1), P["ink"])
        d.point((ax + 3 * ui - k + 1, y0 + h + k - ui + 1), P["ink"])
    d.text((x0 + pad - l, y0 + pad - t), text, font=f, fill=P["ink"])


def ui_overlay(img, ui):
    d = ImageDraw.Draw(img)
    d.fontmode = "1"
    f = font(16 * ui)
    label = "Поверхность  0"
    l, t, r, b = d.textbbox((0, 0), label, font=f)
    d.rounded_rectangle((4 * ui, 4 * ui, 4 * ui + r - l + 10 * ui, 4 * ui + b - t + 8 * ui),
                        radius=2 * ui, fill=(30, 24, 36, 200), outline=hx("c8a070"), width=ui)
    d.text((9 * ui - l, 8 * ui - t), label, font=f, fill=hx("f2e6c8"))
    # hotbar
    n, cell = 6, 18 * ui
    W, H = img.size
    x0 = W // 2 - n * (cell + 2 * ui) // 2
    y0 = H - cell - 4 * ui
    icons = [P["bark"][2], P["stone"][2], P["warm"][1], P["flower"][0], P["water"][3], None]
    for k in range(n):
        x = x0 + k * (cell + 2 * ui)
        d.rounded_rectangle((x, y0, x + cell, y0 + cell), radius=2 * ui, fill=(30, 24, 36, 190),
                            outline=hx("f2e6c8") if k == 0 else hx("8a7660"), width=ui)
        if icons[k]:
            m = 5 * ui
            d.rounded_rectangle((x + m, y0 + m, x + cell - m, y0 + cell - m), radius=ui, fill=icons[k])


# ------------------------------------------------------------------ compose
def render(v):
    T, (cw, ch), (VW, VH), scale = v["T"], v["char"], v["view"], v["scale"]
    style = v["style"]
    # centre the view on the house/path area
    ox = int(20.0 * T - VW / 2)
    oy = int(11.6 * T - VH / 2)
    img = Image.new("RGBA", (VW, VH), P["grass"][2])
    draw_ground(img, T, ox, oy, style)

    sprites = []  # (base_y, image, x, y)
    for i, (tx, ty, kind) in enumerate(TREES):
        s = tree(T, kind, style, i + 3)
        x, y = int(tx * T - ox - s.width / 2), int(ty * T - oy - s.height)
        shadow(img, x + int(T * 0.4), y + s.height - int(T * 0.45), int(T * 2.0), int(T * 0.7))
        sprites.append((ty * T, s, x, y))
    for i, (tx, ty) in enumerate(BUSHES):
        s = bush(T, style, i)
        x, y = int(tx * T - ox - s.width / 2), int(ty * T - oy - s.height)
        shadow(img, x + 2, y + s.height - int(T * 0.3), s.width, int(T * 0.4))
        sprites.append((ty * T, s, x, y))
    hs = house(T, style)
    hx0, hy0 = HOUSE[0] * T - ox, HOUSE[1] * T - oy
    shadow(img, hx0 + T // 2, hy0 + hs.height - T // 2, hs.width + T // 2, T)
    sprites.append(((HOUSE[1] + HOUSE[3]) * T, hs, hx0, hy0))
    (fx0, fy), (fx1, _) = FENCE
    fs = fence(T, fx1 - fx0, style)
    sprites.append((fy * T + T, fs, fx0 * T - ox, fy * T - oy))
    for name, (tx, ty) in (("player", PLAYER), ("npc", NPC)):
        s = chibi(cw, ch, LOOKS[name], style)
        x, y = int(tx * T - ox - s.width / 2), int(ty * T - oy - s.height)
        shadow(img, x + 1, y + s.height - max(2, ch // 10), s.width - 2, max(3, ch // 6))
        sprites.append((ty * T, s, x, y))
    for _, s, x, y in sorted(sprites, key=lambda e: e[0]):
        img.alpha_composite(s, (int(x), int(y)))

    # NPC bubble
    ntx, nty = NPC
    bubble(img, int(ntx * T - ox), int(nty * T - oy - ch - 2), "Хлеб ещё тёплый!", v["ui"])
    ui_overlay(img, v["ui"])
    return img


VARIANTS = [
    dict(key="A", T=16, char=(16, 24), view=(640, 360), scale=3, ui=1,
         style=dict(outline=None, detail=1)),
    dict(key="B", T=16, char=(20, 32), view=(480, 270), scale=4, ui=1,
         style=dict(outline="ink", detail=1)),
    dict(key="C", T=32, char=(32, 48), view=(960, 540), scale=2, ui=2,
         style=dict(outline="colored", detail=2)),
]

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for v in VARIANTS:
        img = render(v)
        img.save(OUT / f"probe_{v['key']}_native.png")
        big = img.resize((img.width * v["scale"], img.height * v["scale"]), Image.NEAREST)
        big.convert("RGB").save(OUT / f"probe_{v['key']}_1080p.png")
        print(v["key"], img.size, "->", big.size)
    sheet = Image.new("RGBA", (1920, 600), hx("2a2430"))
    d = ImageDraw.Draw(sheet)
    d.fontmode = "1"
    x = 24
    for v in VARIANTS:
        cw, ch = v["char"]
        k = 8 if ch < 40 else 6
        d.text((x, 16), f"{v['key']}: {cw}x{ch}, тайл {v['T']}", font=font(32), fill=P["white"])
        xx = x
        for name in ("player", "npc"):
            s = chibi(cw, ch, LOOKS[name], v["style"])
            bg = Image.new("RGBA", s.size, P["grass"][2])
            bg.alpha_composite(s)
            sheet.paste(bg.resize((s.width * k, s.height * k), Image.NEAREST), (xx, 70))
            xx += s.width * k + 16
        x += 640
    sheet.convert("RGB").save(OUT / "probe_characters.png")
