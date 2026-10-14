#!/usr/bin/env python3
"""Probe B4: the next style pass after the author's brief (proposal 004).

Same scene as B2/B3, redrawn toward the author's reference: trees from leaf
clumps instead of balls (oak, ochre oak, slanted birch, tall spruce), uneven
bushes, denser grass and flowers, a stricter log house with a taller facade,
stone steps and chimney smoke, an uneven pond with rocks, reeds and a small
pier, a vegetable bed with cabbages and carrots, a stump, a barrel.
People: two proportions (A1 ~18x32, A2 stricter ~17x32), three looks each,
a dark outline on people only. Three palettes over one drawing: light,
middle, earthy. Procedural sketches to choose parameters, not game art.
Usage: make_probe_b4.py OUT_DIR FONT_TTF
"""
import math
import random

from PIL import Image, ImageDraw

import make_probes as mp
import make_probe_b2 as b2
import make_probe_b3 as b3
from make_probes import P, hx, lerp, h2, vnoise

T, VW, VH, OX, OY = b2.T, b2.VW, b2.VH, b2.OX, b2.OY

# A natural, warm base palette (ramps dark -> light), olive rather than acid.
R = {
    "oak": [hx("23331c"), hx("34482a"), hx("4a6233"), hx("62803c"), hx("86a04c"), hx("a8bc62")],
    "ochre": [hx("4a3414"), hx("7a5820"), hx("a8802c"), hx("c8a03c"), hx("e0c060"), hx("f0d88a")],
    "birch_leaf": [hx("3e5a28"), hx("5a7a34"), hx("7a9a42"), hx("9ab656"), hx("bcd070")],
    "spruce": [hx("16261e"), hx("1e3428"), hx("2a4632"), hx("38583c"), hx("4e7048")],
    "bark": [hx("2a1c12"), hx("3e2a1a"), hx("5a3e26"), hx("765434")],
    "birch_bark": [hx("2a2420"), hx("8a847a"), hx("c8c2b4"), hx("e8e2d2")],
    "log": [hx("3a2414"), hx("54361e"), hx("6e4a2a"), hx("8a6036"), hx("a67a46")],
    "roof": [hx("4a1e16"), hx("6e2c1e"), hx("8e3e28"), hx("ac5434"), hx("c06c44")],
    "stone": [hx("3a3a3e"), hx("56565a"), hx("74727a"), hx("96949a"), hx("b6b2b4")],
    "berry": [hx("7a1e1e"), hx("a83028"), hx("d0503a")],
}
PALETTES = {
    "light": dict(sat=0.95, contrast=1.0, warm=0.03, dark=0.0, grain=0.035, people_sat=0.95, green_to=0.27),
    "middle": dict(sat=0.84, contrast=1.0, warm=0.07, dark=0.025, grain=0.04, people_sat=0.88, green_to=0.24,
                   mid_sat=0.12),  # chosen: deeper half-tones, not darker
    "earthy": dict(sat=0.7, contrast=1.03, warm=0.11, dark=0.05, grain=0.05, people_sat=0.78, green_to=0.21),
}
PEOPLE = {
    "A1": dict(w=18, h=32, head=0.33, head_w=0.66, legs=0.72, eyes=(1, 1), shoulders=0.36, leg_gap=0.05),
    # A1 as chosen, a little less doll-like: smaller head, a mouth.
    "A1b": dict(w=18, h=32, head=0.315, head_w=0.6, legs=0.71, eyes=(1, 1), shoulders=0.36, leg_gap=0.05, mouth=True),
    "A2": dict(w=17, h=32, head=0.30, head_w=0.6, legs=0.68, eyes=(1, 1), shoulders=0.36, leg_gap=0.06, strap=True),
}
OUTLINE_PEOPLE = (44, 32, 30, 255)


# ------------------------------------------------------------------ helpers
def soft_edge(img, color, sides=("b", "r")):
    """A partial outline: only on the shadowed sides, so the world stays soft."""
    w, h = img.size
    src = img.load()
    out = img.copy()
    dst = out.load()
    for y in range(h):
        for x in range(w):
            if src[x, y][3]:
                continue
            for side, (dx, dy) in (("b", (0, -1)), ("r", (-1, 0)), ("l", (1, 0)), ("t", (0, 1))):
                if side in sides and 0 <= x + dx < w and 0 <= y + dy < h and src[x + dx, y + dy][3]:
                    dst[x, y] = color
                    break
    return out


def clump_canopy(img, cx, cy, rx, ry, ramp, rnd, n, rmin, rmax, irregular=0.35, sparse=0.0):
    """Leaf clumps inside an uneven blob; each clump lit from the top-left,
    lower clumps darker (in their own shade), gaps between clumps darkest."""
    px = img.load()
    w, h = img.size
    clumps = []
    tries = 0
    while len(clumps) < n and tries < n * 30:
        tries += 1
        a = rnd.uniform(0, math.tau)
        d = math.sqrt(rnd.random())
        wob = 1 + irregular * (vnoise(int(math.cos(a) * 40) + 99, int(math.sin(a) * 40) + 99, 9, rnd.randint(0, 9)) - 0.5)
        x = cx + math.cos(a) * rx * d * wob
        y = cy + math.sin(a) * ry * d * wob
        clumps.append((x, y, rnd.uniform(rmin, rmax)))
    clumps.sort(key=lambda c: c[1])  # back (top) first
    top = cy - ry
    for (kx, ky, kr) in clumps:
        shade = (ky - top) / (2 * ry)  # 0 top .. 1 bottom
        for y in range(int(ky - kr - 2), int(ky + kr + 2)):
            for x in range(int(kx - kr - 2), int(kx + kr + 2)):
                if not (0 <= x < w and 0 <= y < h):
                    continue
                dx, dy = x + 0.5 - kx, y + 0.5 - ky
                edge = kr * (0.85 + 0.3 * h2(x, y, 41))
                dist = math.hypot(dx, dy * 1.1)
                if dist > edge:
                    continue
                if sparse and h2(x // 2, y // 2, 7) < sparse and dist > edge * 0.5:
                    continue
                lit = -(dx + dy) / (kr * 1.6) + 0.35 - shade * 0.7 + (h2(x, y, 5) - 0.5) * 0.35
                i = 1 if lit < -0.2 else 2 if lit < 0.15 else 3 if lit < 0.45 else 4 if lit < 0.7 else 5
                if dist > edge - 1.2 and dx + dy > 0:
                    i = max(0, i - 2)  # the clump's shadowed rim
                px[x, y] = ramp[min(i, len(ramp) - 1)]


def trunk(img, x0, y_top, y_bot, width, ramp, rnd, lean=0.0):
    px = img.load()
    for y in range(y_top, y_bot):
        t = (y - y_top) / max(1, y_bot - y_top)
        wv = width + (2 if y > y_bot - 3 else 0)
        xc = x0 + lean * (y_bot - y)
        for x in range(int(xc - wv / 2), int(xc + wv / 2)):
            u = (x - (xc - wv / 2)) / wv
            c = ramp[2] if u < 0.35 else ramp[1]
            if u > 0.75:
                c = ramp[0]
            if h2(x, y, 3) > 0.9:
                c = ramp[min(3, len(ramp) - 1)]
            if 0 <= x < img.width:
                px[x, y] = c


# ------------------------------------------------------------------ plants
def oak(seed, ramp_name="oak", W=56, H=72):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    trunk(img, W // 2, int(H * 0.45), H - 1, 6, R["bark"], rnd)
    # two branches into the crown
    d = ImageDraw.Draw(img)
    d.line((W // 2, int(H * 0.62), W // 2 - 9, int(H * 0.45)), R["bark"][1], 2)
    d.line((W // 2, int(H * 0.58), W // 2 + 8, int(H * 0.42)), R["bark"][1], 2)
    clump_canopy(img, W / 2, H * 0.36, W * 0.42, H * 0.34, R[ramp_name], rnd, 46, 3.5, 6.5, irregular=0.5)
    return soft_edge(img, R[ramp_name][0])


def birch(seed, W=40, H=72):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = img.load()
    lean = rnd.choice((-0.12, 0.1))
    for y in range(int(H * 0.25), H - 1):
        xc = W / 2 + lean * (H - y) + math.sin(y * 0.15) * 0.8
        for x in range(int(xc - 2), int(xc + 2)):
            c = R["birch_bark"][3] if x < xc else R["birch_bark"][2]
            if h2(int(xc), y // 2, seed) > 0.8 and x <= xc:
                c = R["birch_bark"][0]
            px[x, y] = c
    for k in range(3):  # thin branches
        y = int(H * (0.3 + k * 0.12))
        xc = W / 2 + lean * (H - y)
        s = 1 if k % 2 else -1
        ImageDraw.Draw(img).line((xc, y, xc + s * 8, y - 6), R["birch_bark"][1])
    clump_canopy(img, W / 2 + lean * H * 0.6, H * 0.3, W * 0.42, H * 0.26, R["birch_leaf"], rnd, 22, 3, 6, sparse=0.25)
    return soft_edge(img, R["birch_leaf"][0])


def spruce(seed, W=34, H=76):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = img.load()
    trunk(img, W // 2, H - 10, H - 1, 4, R["bark"], rnd)
    tiers = 7
    for t in range(tiers):
        top = 2 + t * (H - 14) / tiers
        bottom = top + (H - 14) / tiers + 7
        for y in range(int(top), int(min(bottom, H - 9))):
            prog = (y - top) / (bottom - top)
            half = 2 + (t + 1) * (W / 2 - 3) / tiers * (0.4 + 0.6 * prog)
            for x in range(W):
                dx = x + 0.5 - W / 2
                droop = 1.5 * math.sin(x * 1.3 + t) * prog
                if abs(dx) < half + droop:
                    lit = -dx / (half + 1) * 0.6 + (0.3 if prog < 0.35 else -0.1) + (h2(x, y, seed) - 0.5) * 0.4
                    i = 1 if lit < -0.15 else 2 if lit < 0.2 else 3 if lit < 0.5 else 4
                    if prog > 0.85:
                        i = 0
                    px[x, y] = R["spruce"][i]
    return soft_edge(img, R["spruce"][0])


def shrub(seed, berries=False, W=24, H=16):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    clump_canopy(img, W / 2, H * 0.6, W * 0.46, H * 0.42, R["oak"], rnd, 9, 3, 5, irregular=0.6)
    if berries:
        px = img.load()
        for _ in range(8):
            x, y = rnd.randrange(3, W - 3), rnd.randrange(3, H - 3)
            if px[x, y][3]:
                px[x, y] = R["berry"][rnd.randrange(3)]
    return soft_edge(img, R["oak"][0])


def tall_tuft(seed):
    img = Image.new("RGBA", (14, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    for k in range(10):
        x0 = 2 + k + rnd.randint(-1, 1)
        hgt = rnd.randint(6, 15)
        lean = rnd.choice((-1, 0, 0, 1))
        col = [hx("4a6a2c"), hx("62803a"), hx("7c9446"), hx("a0a85a")][rnd.randrange(4)]
        d.line((x0, 15, x0 + lean, 15 - hgt), col)
        if rnd.random() < 0.25:
            d.point((x0 + lean, 15 - hgt), hx("d8c87a"))
    return img


def cattails(seed):
    img = Image.new("RGBA", (12, 22), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    for k in range(5):
        x0 = 1 + k * 2 + rnd.randint(0, 1)
        hgt = rnd.randint(12, 21)
        d.line((x0, 21, x0 + rnd.choice((-1, 0, 1)), 21 - hgt), hx("4e6e30"))
        if k % 2 == 0:
            d.rectangle((x0, 21 - hgt, x0 + 1, 21 - hgt + 4), hx("5a3a22"))
    return img


def rock(seed, W=14, H=10):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = img.load()
    for y in range(H):
        for x in range(W):
            dd = ((x + 0.5 - W / 2) / (W / 2)) ** 2 + ((y + 0.5 - H * 0.6) / (H * 0.55)) ** 2
            if dd < 1 - 0.15 * h2(x, y, seed):
                lit = (W / 2 - x) / W + (H / 2 - y) / H + (h2(x, y, seed + 1) - 0.5) * 0.3
                px[x, y] = R["stone"][1 if lit < -0.1 else 2 if lit < 0.2 else 3 if lit < 0.45 else 4]
    return soft_edge(img, R["stone"][0], ("b", "r", "l"))


def stump():
    img = Image.new("RGBA", (12, 10), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((2, 4, 9, 9), R["bark"][1])
    d.line((2, 4, 2, 9), R["bark"][2])
    d.ellipse((2, 2, 9, 6), R["log"][3])
    d.ellipse((4, 3, 7, 5), R["log"][2])
    return soft_edge(img, R["bark"][0], ("b", "r", "l"))


def barrel():
    img = Image.new("RGBA", (12, 15), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((1, 2, 10, 14), radius=2, fill=R["log"][3])
    d.rectangle((1, 2, 3, 14), R["log"][4])
    d.line((1, 5, 10, 5), R["stone"][1])
    d.line((1, 11, 10, 11), R["stone"][1])
    d.ellipse((1, 0, 10, 4), R["log"][2])
    return soft_edge(img, R["log"][0], ("b", "r", "l"))


def woodpile():
    img = Image.new("RGBA", (26, 20), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for row in range(4):
        n = 5 - row
        for k in range(n):
            x = 1 + k * 5 + row * 2.5
            y = 15 - row * 4
            d.ellipse((x, y, x + 5, y + 5), fill=R["log"][4], outline=R["log"][1])
            d.point((x + 2, y + 2), R["log"][2])
    return soft_edge(img, R["log"][0], ("b", "r"))


def cabbage(seed):
    img = Image.new("RGBA", (9, 8), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((0, 1, 8, 7), hx("5a8a3c"))
    d.ellipse((2, 2, 6, 6), hx("8ab85a"))
    d.point((4, 4), hx("b8d880"))
    return soft_edge(img, hx("2e4a20"))


def carrot(seed):
    img = Image.new("RGBA", (8, 9), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for k in range(3):
        d.line((4, 5, 2 + k * 2, 0), hx("5a8a3c"))
    d.ellipse((2, 5, 5, 8), hx("d0702a"))
    return img


def pier():
    img = Image.new("RGBA", (26, 14), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for k in range(6):
        x = 1 + k * 4
        d.rectangle((x, 2, x + 3, 9), R["log"][3] if k % 2 else R["log"][4])
        d.line((x + 3, 2, x + 3, 9), R["log"][1])
    d.rectangle((2, 9, 3, 13), R["log"][1])
    d.rectangle((21, 9, 22, 13), R["log"][1])
    return soft_edge(img, R["log"][0], ("b", "r"))


# ------------------------------------------------------------------ house
def house(W=7 * T + 8, H=6 * T + 6):
    """A stricter log house: a taller facade of wide logs with log ends at the
    corners, framed windows with flower boxes, a framed door, a tiled roof
    with an overhang, a stone chimney and a stone foundation."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = img.load()
    d = ImageDraw.Draw(img)
    roof_h = int(T * 3.1)
    wall_top = roof_h - 2
    found = H - 7
    # facade logs
    for y in range(wall_top, found):
        for x in range(4, W - 4):
            ly = (y - wall_top) % 6
            c = R["log"][3] if ly in (1, 2) else R["log"][2]
            if ly == 0:
                c = R["log"][0]
            if ly == 5:
                c = R["log"][1]
            if h2(x // 4, y, 7) > 0.85 and ly in (2, 3):
                c = R["log"][4]
            px[x, y] = c
    # log ends at both corners
    for y in range(wall_top + 1, found, 6):
        for xc in (5, W - 6):
            d.ellipse((xc - 3, y, xc + 3, y + 5), fill=R["log"][4], outline=R["log"][0])
            d.point((xc, y + 2), R["log"][1])
    # stone foundation
    for y in range(found, H):
        for x in range(2, W - 2):
            c = R["stone"][2] if ((x + (y // 3) * 5) // 7) % 2 else R["stone"][3]
            if y % 3 == 2 or (x + (y // 3) * 5) % 7 == 0:
                c = R["stone"][1]
            px[x, y] = c
    # windows with frames, lintels, flower boxes
    for wx in (16, W - 16 - 16):
        wy = wall_top + 9
        d.rectangle((wx - 2, wy - 3, wx + 17, wy - 1), R["log"][1])  # lintel
        d.rectangle((wx, wy, wx + 15, wy + 13), R["log"][0])
        d.rectangle((wx + 1, wy + 1, wx + 14, wy + 12), hx("e8c070"))
        d.rectangle((wx + 1, wy + 1, wx + 7, wy + 6), hx("f4d898"))
        d.line((wx + 8, wy, wx + 8, wy + 13), R["log"][0])
        d.line((wx, wy + 7, wx + 15, wy + 7), R["log"][0])
        if wx < W // 2:
            d.rectangle((wx - 1, wy + 14, wx + 16, wy + 17), R["log"][1])
            for k in range(8):
                d.point((wx + k * 2, wy + 13 - (k % 2)), [hx("e8e0d0"), hx("e0b040"), hx("c84a4a")][k % 3])
                d.point((wx + k * 2 + 1, wy + 13), hx("4a6a2c"))
    # door with frame
    dx = W // 2 - 8
    dy = found - 26
    d.rectangle((dx - 3, dy - 3, dx + 19, dy - 1), R["log"][1])
    d.rectangle((dx - 1, dy, dx + 17, found - 1), R["log"][0])
    d.rectangle((dx + 1, dy + 1, dx + 15, found - 1), hx("5a3a22"))
    for k in (5, 10):
        d.line((dx + 1 + k, dy + 1, dx + 1 + k, found - 1), hx("46301c"))
    d.point((dx + 13, dy + 14), hx("e0b040"))
    # roof: tile rows, staggered, with an overhang and a ridge
    for y in range(0, roof_h):
        inset = max(0, int((10 - y) * 0.9))
        for x in range(inset, W - inset):
            row = y // 4
            ly = y % 4
            tx = (x + (row % 2) * 3) % 6
            c = R["roof"][3] if ly < 2 else R["roof"][2]
            if ly == 3:
                c = R["roof"][0]
            if tx == 0 and ly != 3:
                c = R["roof"][1]
            if h2(x // 6, row, 3) > 0.8 and ly == 0:
                c = R["roof"][4]
            c = lerp(c, R["roof"][0], min(0.35, y / roof_h * 0.35))  # darker toward the eaves
            if x <= inset + 1 or x >= W - inset - 2:
                c = R["roof"][0]
            px[x, y] = c
    for x in range(W):
        if px[x, roof_h - 1][3]:
            px[x, roof_h] = (40, 26, 20, 255)  # eave shadow
    # chimney and smoke
    cx0 = int(W * 0.68)
    d.rectangle((cx0, -1, cx0 + 9, 12), R["stone"][2])
    d.rectangle((cx0, -1, cx0 + 1, 12), R["stone"][3])
    d.rectangle((cx0 - 1, -1, cx0 + 10, 1), R["stone"][1])
    return soft_edge(img, (34, 24, 20, 255))


def smoke(seed):
    img = Image.new("RGBA", (16, 22), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    for k in range(4):
        r = 2 + k
        x = 6 + int(math.sin(k * 1.3) * 3)
        y = 19 - k * 5
        a = 150 - k * 30
        d.ellipse((x - r, y - r, x + r, y + r), fill=(200, 196, 190, a))
    return img


def steps():
    img = Image.new("RGBA", (24, 14), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for k in range(3):
        y = k * 4
        d.rectangle((2 - k, y, 21 + k, y + 4), R["stone"][3 if k == 0 else 2])
        d.line((2 - k, y + 4, 21 + k, y + 4), R["stone"][1])
        for x in range(4, 21, 6):
            d.point((x + k * 2, y + 2), R["stone"][1])
    return soft_edge(img, R["stone"][0], ("b", "r", "l"))


# ------------------------------------------------------------------ people
LOOKS = {
    "villager": dict(skin=[hx("c48a6a"), hx("e0ac8c"), hx("f0c8aa")], hair=[hx("4a2414"), hx("7a3a1e"), hx("9a5028")],
                     cloth=[hx("1e3a2a"), hx("2c5038"), hx("3c6646")], pants=[hx("262838"), hx("33354a")],
                     shoes=hx("3a2618"), accent=hx("b8862e"), eyes=hx("2a2e2a")),
    "baker": dict(skin=[hx("a87656"), hx("c8987a"), hx("e0b898")], hair=[hx("1e1a20"), hx("2c2630"), hx("3e3640")],
                  cloth=[hx("3a2e46"), hx("4e3e5c"), hx("625070")], pants=[hx("2e2a38"), hx("3e3848")],
                  shoes=hx("241c1c"), accent=hx("e8e2d2"), eyes=hx("201c20"), apron=True, scarf=hx("b84a48")),
    "elder": dict(skin=[hx("b48264"), hx("d4a284"), hx("e8bea0")], hair=[hx("8a8a88"), hx("aaa8a4"), hx("c8c6c0")],
                  cloth=[hx("4a3826"), hx("624a32"), hx("7a6040")], pants=[hx("3a3630"), hx("4a463e")],
                  shoes=hx("2a201a"), accent=hx("8a6a3a"), eyes=hx("2a2620")),
}


def person(look_name, f):
    """A person with one dark brown outline (people read at a glance)."""
    return _recolor_outline(b3.figure(LOOKS[look_name], f, "colored"), OUTLINE_PEOPLE)


def _recolor_outline(spr, color):
    """mp.outline drew a darkened rim; make that rim one dark colour."""
    px = spr.load()
    w, h = spr.size
    out = spr.copy()
    o = out.load()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if not c[3]:
                continue
            nbs = [(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
            if any(not (0 <= nx < w and 0 <= ny < h) or px[nx, ny][3] == 0 for nx, ny in nbs):
                o[x, y] = color
    return out


# ------------------------------------------------------------------ scene
_orig_pond = b2.pond_d


def _uneven_pond(tx, ty):
    """A shoreline with bays instead of a perfect ellipse."""
    return _orig_pond(tx, ty) * (0.82 + 0.36 * vnoise(int(tx * 16), int(ty * 16), 22, 17))


def render(palette, people_kind, looks=("villager", "baker")):
    b2.pond_d = _uneven_pond
    prof = dict(PALETTES[palette])
    img = Image.new("RGBA", (VW, VH), P["grass"][2])
    b2.ground(img)
    b2.ground_decor(img)
    _extra_flowers(img)
    rnd = random.Random(5)
    sprites = []

    def place(tx, ty, spr, shadow=None, people=False):
        x, y = int(tx * T - OX - spr.width / 2), int(ty * T - OY - spr.height)
        if shadow:
            mp.shadow(img, x + 2, y + spr.height - shadow // 2 - 1, spr.width - 4, shadow)
        sprites.append((ty, spr, x, y, people))

    for i, (tx, ty, kind) in enumerate(b2.TREES):
        if kind == "spruce":
            spr = spruce(i)
        elif kind == "birch":
            spr = birch(i)
        else:
            spr = oak(i, "ochre" if kind == "autumn" else "oak")
        b2.dappled_shadow(img, tx * T - OX + 8, ty * T - OY - 2, spr.width * 1.2, 22, i)
        place(tx, ty, spr)
    taken = [(tx, ty) for tx, ty, _ in b2.TREES]

    def want(lim):
        return lambda tx, ty: not b2.blocked(tx, ty) and b2.thicket_w(tx, ty) > lim

    for tx, ty in b2.scatter(rnd, 30, want(0.62), 1.0, taken):
        place(tx, ty, shrub(int(tx * 7 + ty), berries=rnd.random() < 0.4), 5)
    for tx, ty in b2.scatter(rnd, 90, want(0.45), 0.5, taken):
        place(tx, ty, tall_tuft(int(tx * 11 + ty * 5)))
    cx, cy, rx, ry = b2.POND
    for k, a in enumerate((2.5, 2.8, 3.2, 3.6, 4.1, 4.5, 4.9, 0.4, 0.8)):
        place(cx + math.cos(a) * rx * 0.95, cy + math.sin(a) * ry * 0.95 + 0.4, cattails(k))
    for k, a in enumerate((1.0, 3.9, 5.6)):
        place(cx + math.cos(a) * rx * 1.05, cy + math.sin(a) * ry * 1.05 + 0.3, rock(k), 3)
    for k, (dx, dy) in enumerate(((-1.2, 0.2), (0.8, -0.6), (1.6, 0.6), (-0.2, 0.9))):
        img.alpha_composite(b2.lily(dict(outline=None, detail=1)), (int((cx + dx) * T - OX), int((cy + dy) * T - OY)))
    place(cx + rx * 0.95, cy + 0.7, pier())
    gx0, gy0, gx1, gy1 = b2.GARDEN
    for row in range(3):
        for k in range(int((gx1 - gx0) * 2) - 1):
            plant = carrot(k) if row == 2 else cabbage(k + row)
            place(gx0 + 0.5 + k * 0.5, gy0 + 0.6 + row * 0.7, plant)
    fs = mp.fence(T, 5, dict(outline=None, detail=1))
    sprites.append((gy1 + 0.55, soft_edge(fs, R["log"][0]), int(gx0 * T - OX) - 3, int((gy1 - 0.45) * T - OY), False))
    place(13.9, 10.8, woodpile(), 4)
    place(22.4, 10.9, barrel(), 4)
    place(25.2, 9.6, stump(), 3)
    place(9.4, 15.6, rock(9, 16, 11), 4)
    hs = house()
    hx0, hy0 = mp.HOUSE[0] * T - OX - 4, mp.HOUSE[1] * T - OY - 6
    mp.shadow(img, hx0 + T // 2, hy0 + hs.height - T // 2, hs.width + T // 2, T)
    sprites.append((mp.HOUSE[1] + mp.HOUSE[3], hs, hx0, hy0, False))
    sprites.append((mp.HOUSE[1] - 1, smoke(1), hx0 + int(hs.width * 0.68) - 3, hy0 - 22, False))
    sprites.append((11.6, steps(), int(18.5 * T - OX) - 12, int(11.15 * T - OY) - 4, False))
    for look, (tx, ty) in zip(looks, (mp.PLAYER, mp.NPC)):
        place(tx, ty, person(look, PEOPLE[people_kind]), 5, people=True)
    out = b3.grain(b3.tone(img, prof), prof, 999)
    for _, s, x, y, people in sorted(sprites, key=lambda e: e[0]):
        s = b3.tone(s, prof, people=people)
        if not people:
            s = b3.grain(s, prof, x * 31 + y)
        out.alpha_composite(s, (int(x), int(y)))
    ntx, nty = mp.NPC
    mp.bubble(out, int(ntx * T - OX), int(nty * T - OY - 34), "Хлеб ещё тёплый!", 1)
    mp.ui_overlay(out, 1)
    b2.pond_d = _orig_pond
    return out


def _extra_flowers(img):
    """Small white, yellow and pink flowers in loose drifts, as in the reference."""
    d = ImageDraw.Draw(img)
    rnd = random.Random(23)
    for _ in range(70):
        cx, cy = rnd.uniform(4, 37), rnd.uniform(3, 21.5)
        col = [hx("ece6d6"), hx("e8c048"), hx("d890a8"), hx("ece6d6")][rnd.randrange(4)]
        for _ in range(rnd.randint(3, 8)):
            tx, ty = cx + rnd.gauss(0, 0.6), cy + rnd.gauss(0, 0.4)
            if b2.blocked(tx, ty):
                continue
            x, y = int(tx * T - OX), int(ty * T - OY)
            for dx, dy in ((0, 0), (-1, 0), (1, 0), (0, -1)):
                d.point((x + dx, y + dy), col)
            d.point((x, y), hx("e0b040"))
            d.point((x, y + 1), hx("3e5a28"))


def people_sheet():
    k = 6
    sheet = Image.new("RGBA", (1920, 520), hx("2a2430"))
    d = ImageDraw.Draw(sheet)
    d.fontmode = "1"
    x = 20
    for kind, label in (("A1", "A1: 18x32, около 3 голов"), ("A2", "A2: 17x32, строже, около 3,3 головы")):
        d.text((x, 12), label, font=mp.font(32), fill=P["white"])
        for row, pal in enumerate(("light", "middle", "earthy")):
            xx = x
            for look in ("villager", "baker", "elder"):
                s = b3.tone(person(look, PEOPLE[kind]), PALETTES[pal], people=True)
                bg = Image.new("RGBA", s.size, b3.tone(Image.new("RGBA", (1, 1), P["grass"][2]), PALETTES[pal]).getpixel((0, 0)))
                bg.alpha_composite(s)
                if row == 1:
                    sheet.paste(bg.resize((s.width * k, s.height * k), Image.NEAREST), (xx, 60))
                xx += s.width * k + 14
        x += 960
    return sheet


if __name__ == "__main__":
    mp.OUT.mkdir(parents=True, exist_ok=True)
    main = render("middle", "A1")
    main.resize((VW * 4, VH * 4), Image.NEAREST).convert("RGB").save(mp.OUT / "scene_middle_A1.png")
    render("middle", "A2", looks=("villager", "elder")).resize((VW * 4, VH * 4), Image.NEAREST).convert("RGB").save(mp.OUT / "scene_middle_A2.png")
    pals = Image.new("RGB", (VW * 3 + 16, VH), (0, 0, 0))
    for i, pal in enumerate(("light", "middle", "earthy")):
        im = main if pal == "middle" else render(pal, "A1")
        if pal != "middle":
            im.resize((VW * 4, VH * 4), Image.NEAREST).convert("RGB").save(mp.OUT / f"scene_{pal}_A1.png")
        pals.paste(im.convert("RGB"), (i * (VW + 8), 0))
    pals.resize((pals.width * 2, pals.height * 2), Image.NEAREST).save(mp.OUT / "palettes.png")
    people_sheet().convert("RGB").save(mp.OUT / "people.png")
    print("done")
