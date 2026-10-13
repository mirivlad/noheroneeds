#!/usr/bin/env python3
"""Probe B2: the chosen B scale with a lived-in meadow, in two outline styles.

Same scale as probe B (tile 16, chibi 20x32, 480x270 x4). Shows that the art
direction can carry dense vegetation: species of trees, thickets, ferns, tall
grass, clover, dappled shade, stone/dirt/rut paths, a trodden trail, reeds,
a vegetable bed and small props. Still procedural sketches, not game art.
Usage: make_probe_b2.py OUT_DIR FONT_TTF
"""
import math
import random

from PIL import Image, ImageDraw

import make_probes as mp
from make_probes import P, hx, lerp, h2, vnoise

T = 16
VW, VH, SCALE = 480, 270, 4
OX, OY = int(20.0 * T - VW / 2), int(11.6 * T - VH / 2)

SLAB = [(18.5, 11.2), (18.5, 13.4)]
TRACK = [(18.5, 13.4), (18.8, 15.5), (20.0, 17.0), (24.0, 18.3), (31.0, 18.6), (37.0, 17.6)]
TRAIL = [(19.0, 15.0), (21.5, 14.3), (23.6, 14.6)]
GARDEN = (9.2, 12.0, 14.0, 14.1)
TREES = [(9, 7.4, "round"), (6, 9.8, "spruce"), (27.4, 6.2, "birch"), (30.6, 10.6, "autumn"),
         (33.4, 7.2, "spruce"), (12.2, 4.8, "birch"), (34.2, 15.4, "round"), (6.4, 16.4, "spruce"),
         (11.6, 19.6, "autumn"), (23.8, 4.4, "round"), (31.6, 4.6, "spruce"), (7.0, 13.2, "birch"),
         (3.0, 6.0, "round"), (36.5, 11.0, "birch")]
POND = (26.6, 14.6, 3.2, 2.0)


def seg_dist(pts, tx, ty):
    best = 99
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        dx, dy = bx - ax, by - ay
        t = max(0, min(1, ((tx - ax) * dx + (ty - ay) * dy) / (dx * dx + dy * dy)))
        best = min(best, math.hypot(tx - ax - t * dx, ty - ay - t * dy))
    return best


def pond_d(tx, ty):
    cx, cy, rx, ry = POND
    return ((tx - cx) / rx) ** 2 + ((ty - cy) / ry) ** 2


def blocked(tx, ty, margin=0.0):
    """Places where vegetation must not grow."""
    if seg_dist(SLAB, tx, ty) < 0.9 + margin or seg_dist(TRACK, tx, ty) < 0.9 + margin:
        return True
    if pond_d(tx, ty) < 1.25 + margin:
        return True
    hx0, hy0, hw, hh = mp.HOUSE
    if hx0 - 0.6 - margin < tx < hx0 + hw + 0.6 + margin and hy0 - margin < ty < hy0 + hh + 1.2 + margin:
        return True
    gx0, gy0, gx1, gy1 = GARDEN
    if gx0 - 0.7 < tx < gx1 + 0.7 and gy0 - 0.9 < ty < gy1 + 1.0:
        return True
    return False


def ground(img):
    px = img.load()
    for y in range(VH):
        for x in range(VW):
            wx, wy = x + OX, y + OY
            tx, ty = wx / T, wy / T
            lx, ly = wx % T, wy % T
            variant = int(h2(int(tx), int(ty), 7) * 4)
            dp = pond_d(tx, ty)
            if dp < 1.0:
                depth = 1 - dp
                i = 1 if depth > 0.55 else 2
                if depth < 0.12:
                    i = 3
                c = P["water"][i]
                if h2(lx // 2, ly, variant + 11) > 0.93 and depth > 0.12:
                    c = P["water"][3 if i < 3 else 4]
                px[x, y] = c
                continue
            if dp < 1.16:
                c = P["dirt"][3] if dp < 1.07 else P["dirt"][1]
                if h2(wx, wy, 31) > 0.8:
                    c = P["stone"][2]
                px[x, y] = c
                continue
            # stone slabs from the door: 8px slabs in staggered rows, grass in the joints
            if seg_dist(SLAB, tx, ty) < 0.62:
                row = wy // 8
                sx = (wx + (row % 2) * 4) // 8
                inx, iny = (wx + (row % 2) * 4) % 8, wy % 8
                if inx == 0 or iny == 0:
                    c = P["grass"][1] if h2(sx, row, 3) > 0.5 else P["stone"][0]
                else:
                    k = h2(sx, row, 9)
                    c = P["stone"][2] if k > 0.35 else P["stone"][1]
                    if inx == 1 or iny == 1:
                        c = P["stone"][3]
                px[x, y] = c
                continue
            # dirt track, a grass strip between the ruts once it leaves the yard
            td = seg_dist(TRACK, tx, ty)
            edge = 0.6 + 0.14 * (vnoise(wx, wy, 8, 3) - 0.5)
            if td < edge:
                c = P["dirt"][2]
                r = h2(lx, ly, variant + 21)
                if r > 0.86:
                    c = P["dirt"][3]
                elif r < 0.10:
                    c = P["dirt"][1]
                if td > edge - 1.5 / T:
                    c = P["dirt"][1]
                if tx > 21.5 and td < 0.05 + 0.07 * vnoise(wx, wy, 5, 4):
                    c = P["grass"][2] if h2(wx, wy, 5) > 0.3 else P["grass"][1]
                px[x, y] = c
                continue
            # trodden trail: grass worn thin, not a path
            trd = seg_dist(TRAIL, tx, ty)
            gx0, gy0, gx1, gy1 = GARDEN
            if gx0 < tx < gx1 and gy0 < ty < gy1:
                c = P["dirt"][1] if (wy // 3) % 2 else P["dirt"][0]
                if h2(wx, wy, 41) > 0.85:
                    c = P["dirt"][2]
                px[x, y] = c
                continue
            m = vnoise(wx, wy, T * 3, 1) + (h2(wx, wy, 2) - 0.5) * 0.12
            base = 2 if m > 0.30 else 1
            if m > 0.74:
                base = 3
            # damp, darker grass around tree feet and thickets
            for ttx, tty, _ in TREES:
                if math.hypot(tx - ttx, (ty - tty) * 1.6) < 1.7:
                    base = max(1, base - 1)
                    break
            c = P["grass"][base]
            r = h2(lx, ly, variant)
            if r > 0.90:
                c = P["grass"][min(4, base + 1)]
            elif r < 0.07:
                c = P["grass"][max(0, base - 1)]
            if h2(lx, ly - 1, variant) > 0.90:
                c = P["grass"][min(4, base + 1)]
            if trd < 0.42 + 0.1 * (vnoise(wx, wy, 6, 8) - 0.5):
                c = P["grass"][3] if h2(wx, wy, 12) > 0.45 else P["dirt"][3]
            px[x, y] = c


def scatter(rnd, n, ok, spacing, taken):
    out = []
    tries = 0
    while len(out) < n and tries < n * 40:
        tries += 1
        tx, ty = rnd.uniform(4, 37), rnd.uniform(3, 21.5)
        if not ok(tx, ty):
            continue
        if any(math.hypot(tx - a, ty - b) < spacing for a, b in taken):
            continue
        taken.append((tx, ty))
        out.append((tx, ty))
    return out


def thicket_w(tx, ty):
    """How much a place wants to be overgrown: edges of the clearing + noise."""
    edge = max(0.0, 1 - min(tx - 3, 37 - tx, ty - 2.5, 21.5 - ty, 6) / 6)
    centre = math.hypot((tx - 20) / 14, (ty - 12.5) / 8)
    return 0.55 * vnoise(int(tx * 8), int(ty * 8), 30, 21) + 0.45 * min(1, centre) + 0.3 * edge


def ground_decor(img):
    d = ImageDraw.Draw(img)
    rnd = random.Random(11)

    def put(tx, ty):
        return int(tx * T - OX), int(ty * T - OY)

    # clover patches: lighter rosettes of 3 leaves
    for _ in range(260):
        tx, ty = rnd.uniform(4, 37), rnd.uniform(3, 21.5)
        if blocked(tx, ty) or vnoise(int(tx * 8), int(ty * 8), 22, 5) < 0.55:
            continue
        x, y = put(tx, ty)
        c = P["grass"][4]
        for dx, dy in ((0, -1), (-1, 0), (1, 0)):
            d.point((x + dx, y + dy), c)
        d.point((x, y), P["grass"][2])
        if rnd.random() < 0.15:
            d.point((x, y - 2), P["white"])
    # pebbles and mushrooms
    for _ in range(70):
        tx, ty = rnd.uniform(4, 37), rnd.uniform(3, 21.5)
        if blocked(tx, ty, -0.4):
            continue
        x, y = put(tx, ty)
        d.point((x, y), P["stone"][2])
        d.point((x + 1, y), P["stone"][1])
        d.point((x, y - 1), P["stone"][3])
    for ttx, tty, kind in TREES:
        for k in range(rnd.randint(0, 3)):
            x, y = put(ttx + rnd.uniform(-1.2, 1.2), tty + rnd.uniform(0.1, 0.7))
            cap = hx("c83a3a") if kind != "spruce" else hx("b8783a")
            d.point((x, y), P["white"])
            d.line((x - 1, y - 1, x + 1, y - 1), cap)
            d.point((x, y - 2), cap)
            d.point((x, y - 1), P["white"] if cap == hx("c83a3a") else cap)
        if kind == "autumn":  # fallen leaves
            for k in range(24):
                x, y = put(ttx + rnd.uniform(-1.8, 1.8), tty + rnd.uniform(-0.6, 0.9))
                d.point((x, y), P["leaf2"][rnd.randint(2, 4)])
    # meadow flowers: clusters of a single species
    for _ in range(46):
        cx, cy = rnd.uniform(4, 37), rnd.uniform(3, 21.5)
        if thicket_w(cx, cy) > 0.85:
            continue
        col = P["flower"][rnd.randrange(len(P["flower"]))]
        for _ in range(rnd.randint(4, 11)):
            tx, ty = cx + rnd.gauss(0, 0.55), cy + rnd.gauss(0, 0.35)
            if blocked(tx, ty):
                continue
            x, y = put(tx, ty)
            d.point((x, y), col)
            d.point((x, y + 1), P["grass"][0])
            if rnd.random() < 0.3:
                d.point((x + 1, y), lerp(col, P["white"], 0.4))
    # bed of flowers along the house front, left of the door
    for k in range(18):
        x, y = put(15.4 + k * 0.12, 11.25 + (k % 3) * 0.12)
        d.point((x, y), P["flower"][(k // 2) % 4])
        d.point((x, y + 1), P["leaf"][2])


def dappled_shadow(img, cx, cy, w, h, seed):
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    px = lay.load()
    for y in range(int(cy - h / 2), int(cy + h / 2)):
        for x in range(int(cx - w / 2), int(cx + w / 2)):
            if not (0 <= x < VW and 0 <= y < VH):
                continue
            dd = ((x - cx) / (w / 2)) ** 2 + ((y - cy) / (h / 2)) ** 2
            if dd >= 1:
                continue
            if vnoise(x + OX, y + OY, 3, seed) > 0.72 and dd > 0.15:
                continue  # light coming through the leaves
            a = 78 if dd < 0.6 else 55
            px[x, y] = (18, 40, 30, a)
    img.alpha_composite(lay)


# ------------------------------------------------------------------ sprites
def spruce(style, seed):
    W, H = 30, 48
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    px = spr.load()
    for y in range(H - 6, H):
        for x in range(W // 2 - 1, W // 2 + 2):
            px[x + 1, y + 1] = P["bark"][1] if x < W // 2 + 1 else P["bark"][0]
    tiers = 4
    for t in range(tiers):
        top = 1 + t * 9
        bottom = top + 16
        for y in range(top, min(bottom, H - 5)):
            half = (y - top + 2) * (0.42 + t * 0.07)
            for x in range(W):
                dx = x + 0.5 - W / 2
                jag = 1.2 * math.sin(y * 1.7 + t) if y > bottom - 4 else 0
                if abs(dx) < half + jag:
                    v = -dx / (half + 1) * 0.6 + (h2(x, y, seed) - 0.5) * 0.5
                    i = 2 if v > 0.15 else 1
                    if y > bottom - 3:
                        i = 0
                    if v > 0.5:
                        i = 3
                    px[x + 1, y + 1] = P["leaf"][i]
    return mp.outline(spr, style)


def birch(style, seed):
    rnd = random.Random(seed)
    W, H = 34, 50
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    px = spr.load()
    for y in range(int(H * 0.45), H):
        for x in range(W // 2 - 2, W // 2 + 1):
            c = hx("eae4d6") if x < W // 2 else hx("c8c0b0")
            if h2(x // 2, y, seed) > 0.78:
                c = P["ink"]
            px[x + 1, y + 1] = c
    # a side branch
    for k in range(5):
        px[W // 2 + 2 + k, int(H * 0.55) - k // 2] = hx("c8c0b0")
    blobs = [(W * 0.5 + rnd.uniform(-9, 9), H * 0.3 + rnd.uniform(-10, 8), rnd.uniform(5, 8)) for _ in range(9)]
    for y in range(H):
        for x in range(W):
            best = None
            for bx, by, br in blobs:
                dd = math.hypot(x + 0.5 - bx, (y + 0.5 - by) * 1.15)
                if dd < br:
                    lt = ((bx - x) + (by - y)) / (br * 1.5) + 0.2
                    best = lt if best is None else max(best, lt)
            if best is None or h2(x, y, seed + 1) > 0.9:
                continue
            v = best + (h2(x // 2, y // 2, seed) - 0.5) * 0.4
            i = 2 if v < 0.15 else 3 if v < 0.55 else 4
            px[x + 1, y + 1] = P["leaf"][i]
    return mp.outline(spr, style)


def broadleaf(kind, style, seed):
    return mp.tree(T, "leaf2" if kind == "autumn" else "leaf", style, seed)


def berry_bush(style, seed):
    spr = mp.bush(T, dict(style, outline=None), seed)
    px = spr.load()
    rnd = random.Random(seed)
    for _ in range(7):
        x, y = rnd.randrange(3, spr.width - 3), rnd.randrange(3, spr.height - 4)
        if px[x, y][3]:
            px[x, y] = hx("c8324a")
            px[x + 1, y] = hx("e8546a") if px[x + 1, y][3] else px[x + 1, y]
    return mp.outline(spr, style)


def fern(style, seed):
    W, H = 20, 14
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    rnd = random.Random(seed)
    for k in range(7):
        a = math.pi * (0.1 + 0.8 * k / 6)
        ln = rnd.uniform(6, 9.5)
        ex, ey = W / 2 + math.cos(a) * ln, H - 1 - math.sin(a) * ln * 1.15
        col = P["leaf"][3] if k % 2 else P["leaf"][2]
        d.line((W / 2 + 1, H, ex + 1, ey + 1), col)
        for s in range(2, int(ln), 2):  # leaflets
            fx, fy = W / 2 + math.cos(a) * s, H - 1 - math.sin(a) * s * 1.15
            d.point((fx + 1, fy), P["leaf"][4] if k % 2 else P["leaf"][3])
    return mp.outline(spr, style)


def tall_grass(style, seed):
    W, H = 12, 12
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    rnd = random.Random(seed)
    for k in range(9):
        x0 = 2 + k + rnd.randint(-1, 0)
        h = rnd.randint(5, H - 1)
        lean = rnd.choice((-1, 0, 1))
        d.line((x0 + 1, H, x0 + 1 + lean, H - h), P["grass"][2] if k % 2 else P["grass"][3])
        d.point((x0 + 1 + lean, H - h), P["grass"][4])
        if rnd.random() < 0.25:
            d.point((x0 + 1 + lean, H - h - 1), hx("e8d890"))  # seed head
    return mp.outline(spr, dict(style, outline=None))


def reeds(style, seed):
    W, H = 10, 18
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    rnd = random.Random(seed)
    for k in range(4):
        x0 = 2 + k * 2
        h = rnd.randint(10, H - 1)
        d.line((x0, H, x0, H - h), P["leaf"][2])
        if k % 2 == 0:
            d.rectangle((x0, H - h, x0 + 1, H - h + 3), hx("6a4028"))
        d.line((x0 + 1, H, x0 + 3, H - h // 2), P["leaf"][3])
    return mp.outline(spr, style)


def lily(style):
    spr = Image.new("RGBA", (9, 6), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    d.ellipse((0, 1, 7, 5), P["leaf"][2])
    d.line((4, 3, 7, 2), P["water"][2])
    d.point((2, 2), P["leaf"][4])
    return spr


def crop(style, seed):
    spr = Image.new("RGBA", (8, 7), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    d.ellipse((1, 1, 6, 6), P["leaf"][3])
    d.ellipse((2, 2, 5, 5), P["leaf"][4])
    d.point((3, 3), P["leaf"][2])
    return mp.outline(spr, style)


def woodpile(style):
    W, H = 22, 14
    spr = Image.new("RGBA", (W + 2, H + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    for row in range(3):
        n = 4 - row
        for k in range(n):
            x = 2 + k * 5 + row * 2.5
            y = H - 4 - row * 4
            d.ellipse((x, y, x + 4, y + 4), fill=P["wood"][3], outline=P["wood"][0])
            d.point((x + 2, y + 2), P["wood"][1])
            d.point((x + 1, y + 1), hx("d8b080"))
    return mp.outline(spr, style)


def barrel(style):
    spr = Image.new("RGBA", (12, 14), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    d.rounded_rectangle((1, 2, 10, 13), radius=2, fill=P["wood"][2])
    d.rectangle((1, 2, 3, 13), P["wood"][3])
    d.line((1, 5, 10, 5), P["stone"][0])
    d.line((1, 10, 10, 10), P["stone"][0])
    d.ellipse((1, 0, 10, 4), P["wood"][1])
    d.ellipse((3, 1, 8, 3), P["wood"][0])
    return mp.outline(spr, style)


# ------------------------------------------------------------------ compose
def render(style):
    img = Image.new("RGBA", (VW, VH), P["grass"][2])
    ground(img)
    ground_decor(img)
    rnd = random.Random(3)
    sprites = []

    def place(tx, ty, spr, shadow=None):
        x, y = int(tx * T - OX - spr.width / 2), int(ty * T - OY - spr.height)
        if shadow:
            mp.shadow(img, x + 1, y + spr.height - shadow[1] // 2 - 1, spr.width - 2, shadow[1])
        sprites.append((ty, spr, x, y))

    for i, (tx, ty, kind) in enumerate(TREES):
        spr = {"spruce": spruce, "birch": birch}.get(kind)
        spr = spr(style, i + 3) if spr else broadleaf(kind, style, i + 3)
        dappled_shadow(img, tx * T - OX + 6, ty * T - OY - 2, spr.width * 1.15, 18, i)
        place(tx, ty, spr)
    taken = [(tx, ty) for tx, ty, _ in TREES]
    want = lambda lim: lambda tx, ty: not blocked(tx, ty) and thicket_w(tx, ty) > lim
    for tx, ty in scatter(rnd, 34, want(0.62), 0.9, taken):
        r = rnd.random()
        if r < 0.4:
            place(tx, ty, mp.bush(T, style, int(tx * 7)), (0, 5))
        elif r < 0.6:
            place(tx, ty, berry_bush(style, int(ty * 13)), (0, 5))
        else:
            place(tx, ty, fern(style, int(tx * 3 + ty)), (0, 4))
    for tx, ty in scatter(rnd, 70, want(0.48), 0.55, taken):
        place(tx, ty, tall_grass(style, int(tx * 11 + ty * 5)))
    # pond edge: reeds on the far and left banks, lily pads on the water
    cx, cy, rx, ry = POND
    for k, a in enumerate((2.6, 2.9, 3.3, 3.7, 4.2, 4.6, 5.0, 0.3)):
        place(cx + math.cos(a) * rx * 0.98, cy + math.sin(a) * ry * 0.98 + 0.3, reeds(style, k))
    for k, (dx, dy) in enumerate(((-1.2, 0.2), (0.8, -0.6), (1.6, 0.6), (-0.2, 0.9))):
        lp = lily(style)
        img.alpha_composite(lp, (int((cx + dx) * T - OX), int((cy + dy) * T - OY)))
        if k == 1:
            ImageDraw.Draw(img).point((int((cx + dx) * T - OX) + 3, int((cy + dy) * T - OY) + 2),
                                      hx("f2a0c0"))
    # vegetable bed and its fence
    gx0, gy0, gx1, gy1 = GARDEN
    for row in range(3):
        for k in range(int((gx1 - gx0) * 2) - 1):
            place(gx0 + 0.5 + k * 0.5, gy0 + 0.6 + row * 0.7, crop(style, k + row))
    fs = mp.fence(T, 5, style)
    sprites.append((gy1 + 0.55, fs, int(gx0 * T - OX) - 3, int((gy1 - 0.45) * T - OY)))
    place(14.5, 10.9, woodpile(style), (0, 4))
    place(22.6, 11.3, barrel(style), (0, 4))
    # house, characters
    hs = mp.house(T, style)
    hx0, hy0 = mp.HOUSE[0] * T - OX, mp.HOUSE[1] * T - OY
    mp.shadow(img, hx0 + T // 2, hy0 + hs.height - T // 2, hs.width + T // 2, T)
    sprites.append((mp.HOUSE[1] + mp.HOUSE[3], hs, hx0, hy0))
    for name, (tx, ty) in (("player", mp.PLAYER), ("npc", mp.NPC)):
        s = mp.chibi(20, 32, mp.LOOKS[name], style)
        place(tx, ty, s, (0, 5))
    for _, s, x, y in sorted(sprites, key=lambda e: e[0]):
        img.alpha_composite(s, (int(x), int(y)))
    ntx, nty = mp.NPC
    mp.bubble(img, int(ntx * T - OX), int(nty * T - OY - 34), "Хлеб ещё тёплый!", 1)
    mp.ui_overlay(img, 1)
    return img


if __name__ == "__main__":
    mp.OUT.mkdir(parents=True, exist_ok=True)
    for key, outline in (("ink", "ink"), ("colored", "colored")):
        img = render(dict(outline=outline, detail=1))
        img.resize((VW * SCALE, VH * SCALE), Image.NEAREST).convert("RGB").save(
            mp.OUT / f"probe_B2_{key}_1080p.png")
        print("B2", key)
