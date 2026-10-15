#!/usr/bin/env python3
"""Temporary art for the base pack: a tile atlas, a people sheet and the
visual definitions that tie content ids to them (content/base/visuals.json).

Placeholders in the manner chosen by the author (ART_STANDARD v2, probe B4):
the middle palette, leaf-clump trees, earthy forms, A1 people (18x32, about
three heads) with one dark outline, soft shade edges on the world. Drawn by
code so the game runs before production art exists; production art
replaces the PNGs and visuals.json without code changes.
Usage: tools/art/make_placeholders.py   (writes into content/base/)
"""
import json
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "art_probes"))
sys.argv = [sys.argv[0], "/tmp"]  # make_probes reads an output dir it will not use here
import make_probes as mp  # noqa: E402
import make_probe_b3 as b3  # noqa: E402
import make_probe_b4 as b4  # noqa: E402
from make_probes import P, hx, lerp, h2, vnoise  # noqa: E402

MIDDLE = b4.PALETTES["middle"]

T = 16
OUT = ROOT / "content" / "base"
# The world: no full outline (soft shade edges are drawn by the B4 drawers).
STYLE = dict(outline=None, detail=1)
# People and interactive things: one dark warm outline (ADR-0001 revision).
STRONG = "people"


class Atlas:
    def __init__(self, cols, rows):
        self.img = Image.new("RGBA", (cols * T, rows * T), (0, 0, 0, 0))
        self.visuals = []

    def put(self, col, row, sprite, for_id, origin, mode, variants=1):
        """origin: the sprite pixel that sits on the bottom-left corner of the cell."""
        self.img.alpha_composite(sprite, (col * T, row * T))
        w, h = sprite.size
        self.visuals.append({
            "id": "base:visual/" + for_id.split(":")[1], "kind": "visual", "for": for_id,
            "atlas": "art/tiles.png", "rect": [col * T, row * T, w // variants, h],
            "origin": list(origin), "mode": mode, "variants": variants,
        })


def strong(img):
    """The people/interactive outline: one dark warm colour around the shape."""
    w, h = img.size
    src = img.load()
    out = img.copy()
    dst = out.load()
    for y in range(h):
        for x in range(w):
            if src[x, y][3]:
                continue
            if any(0 <= x + dx < w and 0 <= y + dy < h and src[x + dx, y + dy][3]
                   for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                dst[x, y] = b4.OUTLINE_PEOPLE
    return out


def ground_tile(kind, variant):
    img = Image.new("RGBA", (T, T))
    px = img.load()
    ramps = {
        "grass": (P["grass"], 2), "grass_dry": ([hx("8a8a3a"), hx("a8a048"), hx("c0b45a"), hx("d8cc78")], 1),
        "dirt": (P["dirt"], 1), "moss": ([hx("2c5a34"), hx("3a6e3c"), hx("4e8444"), hx("68a050")], 1),
        "forest_floor": ([hx("3a3020"), hx("4e3e28"), hx("5e4a30"), hx("70603c")], 1),
        "sand": ([hx("b8a070"), hx("d0b884"), hx("e2cc98"), hx("f0deb0")], 1),
        "water": (P["water"], 2),
    }
    ramp, base = ramps[kind]
    for y in range(T):
        for x in range(T):
            r = h2(x, y, variant * 31 + len(kind))
            c = ramp[base]
            if r > 0.86:
                c = ramp[min(len(ramp) - 1, base + 1)]
            elif r < 0.10:
                c = ramp[max(0, base - 1)]
            if kind == "water" and h2(x // 3, y, variant + 5) > 0.9:
                c = ramp[3]
            if kind in ("grass", "moss") and h2(x, y - 1, variant) > 0.9:
                c = ramp[min(len(ramp) - 1, base + 1)]
            if kind == "forest_floor" and h2(x, y, variant + 9) > 0.93:
                c = P["leaf2"][2]
            px[x, y] = c
    return img


def small_plant(kind):
    img = Image.new("RGBA", (T, T), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rnd = random.Random(kind)
    if kind == "tall_grass":
        for k in range(7):
            x0 = 3 + k + rnd.randint(-1, 0)
            h = rnd.randint(5, 12)
            d.line((x0, 15, x0 + rnd.choice((-1, 0, 1)), 15 - h), P["grass"][3] if k % 2 else P["grass"][2])
    elif kind == "clover":
        for (x, y) in ((5, 9), (9, 11), (11, 7)):
            for dx, dy in ((0, -1), (-1, 0), (1, 0)):
                d.point((x + dx, y + dy), P["grass"][4])
            d.point((x, y), P["grass"][2])
    elif kind.startswith("flower"):
        col = {"flower_red": P["flower"][0], "flower_yellow": P["flower"][1], "flower_blue": hx("6a8ae8")}[kind]
        for (x, y) in ((4, 8), (9, 5), (11, 11), (6, 12)):
            d.line((x, y + 1, x, y + 3), P["grass"][1])
            d.point((x, y), col)
            d.point((x + 1, y), lerp(col, P["white"], 0.4))
    elif kind == "fern":
        spr = image_from(lambda: _fern())
        return spr
    elif kind == "reeds":
        for k in range(4):
            x0 = 3 + k * 3
            h = rnd.randint(8, 14)
            d.line((x0, 15, x0, 15 - h), P["leaf"][2])
            if k % 2 == 0:
                d.rectangle((x0, 15 - h, x0 + 1, 15 - h + 3), hx("6a4028"))
    return img


def _fern():
    img = Image.new("RGBA", (T, T), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for k in range(7):
        a = math.pi * (0.1 + 0.8 * k / 6)
        ex, ey = 8 + math.cos(a) * 7, 15 - math.sin(a) * 8
        d.line((8, 15, ex, ey), P["leaf"][3] if k % 2 else P["leaf"][2])
    return img


def image_from(f):
    return f()


def fit(sprite, w, h):
    """Places a sprite bottom-centre on a w x h transparent canvas."""
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.alpha_composite(sprite, ((w - sprite.width) // 2, h - sprite.height))
    return out


N, E, S, W = 1, 2, 4, 8


def wall(kind, mask, opened=False):
    """A wall cell a full cell thick, 16 x 32: the top of the wall (seen from
    above) over the cell to the north, the front face over the cell itself.
    mask: which neighbours are walls too (N=1, E=2, S=4, W=8); edges are drawn
    only where the wall ends, so runs join into one solid body. A wall below
    covers this one's face with its own top, so north-south runs read as one
    long wall top with a face at the end."""
    img = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    px = img.load()
    if kind == "stone_wall":
        top = [hx("6d6b72"), hx("8f8c92"), hx("a8a4a8"), hx("c4c0c0")]
        face = [hx("3a3840"), hx("55535a"), hx("6d6b72"), hx("85828a")]
    else:
        top = [b4.R["log"][1], b4.R["log"][2], b4.R["log"][3], b4.R["log"][4]]
        face = [b4.R["log"][0], b4.R["log"][1], b4.R["log"][2], b4.R["log"][3]]
    for y in range(2 * T):
        for x in range(T):
            wx = x + mask * 3  # vary the pattern a little between variants
            if y < T:  # top of the wall
                if kind == "stone_wall":
                    joint = (y % 6 == 5) or ((x + (y // 6) * 5) % 8 == 7)
                    c = top[0] if joint else (top[2] if h2(wx // 3, y // 3, 5) > 0.3 else top[1])
                else:
                    c = top[2] if (x % 5) != 4 else top[1]
                    if h2(x, y, 9) > 0.93:
                        c = top[3]
                tex = TEX.get(("stone" if kind == "stone_wall" else "wood") + "_wall_top")
                if tex is not None:
                    c = tex.getpixel(((x + (mask % 3) * T) % tex.width, y + (mask // 3 % 3) * T))
            else:  # front face, darker toward the ground
                fy = y - T
                if kind == "stone_wall":
                    joint = (fy % 5 == 4) or ((x + (fy // 5) * 4) % 8 == 7)
                    c = face[0] if joint else (face[2] if fy < 8 else face[1])
                    if not joint and h2(wx, y, 3) > 0.9:
                        c = face[3]
                else:
                    c = face[2] if fy % 4 != 3 else face[0]
                    if fy % 4 == 0:
                        c = face[3]
                    if fy >= 12 and fy % 4 != 3:
                        c = face[1]
                tex = TEX.get(("stone" if kind == "stone_wall" else "wood") + "_wall_face")
                if tex is not None:
                    c = tex.getpixel(((x + (mask % 3) * T) % tex.width, fy + T))
                    if fy >= 12:
                        c = lerp(c, face[0], 0.25)  # darker toward the ground
                if fy == T - 1:
                    c = lerp(face[0], P["ink"], 0.4)  # where the wall meets the ground
            px[x, y] = c
    edge_top = lerp(top[0], P["ink"], 0.35)
    for x in range(T):
        px[x, T] = lerp(top[0], P["ink"], 0.25)  # the top's front edge
        if not mask & N:
            px[x, 0] = edge_top
    for y in range(2 * T):
        if not mask & W:
            px[0, y] = lerp(px[0, y], top[3], 0.35) if y < T else lerp(face[0], P["ink"], 0.2)
        if not mask & E:
            px[T - 1, y] = lerp(top[0], P["ink"], 0.3) if y < T else lerp(face[0], P["ink"], 0.45)
    if kind == "wood_door":
        d = ImageDraw.Draw(img)
        if opened:
            d.rectangle((3, T + 1, 12, 2 * T - 1), hx("1e1618"))
            d.rectangle((3, T + 1, 4, 2 * T - 1), P["wood"][1])
        else:
            d.rectangle((3, T + 1, 12, 2 * T - 1), P["wood"][2])
            d.line((3, T + 1, 3, 2 * T - 1), P["wood"][0])
            d.line((12, T + 1, 12, 2 * T - 1), P["wood"][0])
            d.line((7, T + 2, 7, 2 * T - 1), P["wood"][1])
            d.point((10, T + 8), P["warm"][1])
        d.line((2, T, 13, T), lerp(top[0], P["ink"], 0.4))  # lintel
    return img


def wall_set(kind, opened=False):
    """16 variants side by side, indexed by the neighbour mask."""
    strip = Image.new("RGBA", (16 * T, 2 * T), (0, 0, 0, 0))
    base = "wood_wall" if kind == "wood_door" else kind
    for m in range(16):
        strip.alpha_composite(wall(base if kind != "wood_door" else "wood_door", m, opened), (m * T, 0))
    return strip


def window(kind, mask, facing):
    """A wall with an opening (ADR-0015), 16 x 32 like a wall and joining
    walls the same way. kind: wood_window (a framed pane) or loophole (a
    narrow slit in stone). The opening shows where it looks: on the front
    face for "s"; for "n", "e", "w" as a dark slot in the wall top on that
    side (the face it is cut in is out of sight)."""
    base = "stone_wall" if kind == "loophole" else "wood_wall"
    img = wall(base, mask)
    d = ImageDraw.Draw(img)
    dark, glass = hx("1e1618"), hx("3b4a5c")
    frame = P["wood"][3] if kind == "wood_window" else hx("4a4850")
    if facing == "s":
        if kind == "wood_window":
            d.rectangle((3, T + 3, 12, T + 10), frame)
            d.rectangle((4, T + 4, 11, T + 9), glass)
            d.line((7, T + 4, 7, T + 9), frame)
            d.line((4, T + 6, 11, T + 6), frame)
            d.point((5, T + 4), hx("8aa0b0"))  # a glint
            d.line((2, T + 11, 13, T + 11), P["wood"][1])  # the sill
        else:
            d.rectangle((7, T + 2, 8, T + 11), dark)
            d.rectangle((6, T + 5, 9, T + 7), dark)
    else:
        w = 4 if kind == "wood_window" else 2
        if facing == "n":
            box = (8 - w, 0, 7 + w, 2)
        elif facing == "e":
            box = (T - 3, 8 - w, T - 1, 7 + w)
        else:
            box = (0, 8 - w, 2, 7 + w)
        d.rectangle(box, frame)
        inner = (box[0] + (1 if facing != "w" else 0), box[1] + (1 if facing != "n" else 0),
                 box[2] - (1 if facing != "e" else 0), box[3] - (1 if facing == "n" else 1))
        d.rectangle(inner, glass if kind == "wood_window" else dark)
    return img


ORE_SPECKS = {"rock": None, "iron_ore_rock": ("c86a3a", "e89a5a"), "copper_ore_rock": ("3a9a8a", "6ac8b0"),
              "gem_rock": ("9a4ac8", "d8a0f0")}


def rock(kind, mask):
    """Natural cave rock (ADR-0017), 16 x 32 like a wall and joining its own
    kind (any rock) the same way: a rough top, a darker face; ores show as
    specks of their colour on both."""
    img = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    px = img.load()
    # The top of solid rock reads as stone, not as the earth floor beside it:
    # cool slate, darker, broken into blocks by cracks (16.10.2026: a mass of
    # rock looked like an empty floor in the dark).
    top = [hx("17161c"), hx("23222b"), hx("2f2d38"), hx("44414f")]
    face = [hx("1e1a1c"), hx("2a2628"), hx("363032"), hx("443c3c")]
    specks = ORE_SPECKS[kind]
    for y in range(2 * T):
        for x in range(T):
            r = h2(x + mask * 5, y, 17)
            if y < T:
                c = top[2] if r > 0.6 else (top[1] if r > 0.1 else top[0])
                if h2(x // 2, y // 2, mask + 3) > 0.9:
                    c = top[3]
                # Cracks between blocks, offset row by row like masonry of nature.
                bx = (x + (3 if (y // 5) % 2 else 0)) % 6
                if y % 5 == 4 or bx == 5 and h2(x // 6, y // 5, 29) > 0.25:
                    c = top[0]
            else:
                fy = y - T
                c = face[2] if fy < 5 else (face[1] if r > 0.3 else face[0])
                if h2(x, fy // 3, mask + 7) > 0.9:
                    c = face[0]
                if fy == T - 1:
                    c = lerp(face[0], P["ink"], 0.5)
            if specks and h2((x + 3) // 2, (y + mask) // 2, 41) > 0.9 and h2(x, y, 45) > 0.35:
                c = hx(specks[0]) if h2(x, y, 43) > 0.4 else hx(specks[1])
            px[x, y] = c
    for x in range(T):
        px[x, T] = lerp(top[0], P["ink"], 0.3)
        if not mask & N:
            px[x, 0] = lerp(top[0], P["ink"], 0.4)
    for y in range(2 * T):
        if not mask & W:
            px[0, y] = lerp(px[0, y], P["ink"], 0.3)
        if not mask & E:
            px[T - 1, y] = lerp(px[T - 1, y], P["ink"], 0.45)
    return img


def rock_set(kind):
    strip = Image.new("RGBA", (16 * T, 2 * T), (0, 0, 0, 0))
    for m in range(16):
        strip.alpha_composite(rock(kind, m), (m * T, 0))
    return strip


def cave_floor(variant):
    img = Image.new("RGBA", (T, T))
    px = img.load()
    ramp = [hx("4a3c30"), hx("5c4b3c"), hx("6e5a46"), hx("826a52")]  # warm earth: not the rock's slate
    for y in range(T):
        for x in range(T):
            r = h2(x, y, variant * 13 + 5)
            px[x, y] = ramp[2] if r > 0.8 else (ramp[0] if r < 0.12 else ramp[1])
            if h2(x // 2, y // 2, variant + 21) > 0.95:
                px[x, y] = ramp[3]
    return img


def way(kind):
    """The parts at the ends of ways between depths (16 x 32; a headframe 16 x 48)."""
    tall = 3 * T if kind == "headframe" else 2 * T
    img = Image.new("RGBA", (T, tall), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base = tall - T  # the cell's own square starts here
    hole, rim = hx("0e0a0c"), hx("4a423c")
    if kind in ("cave_mouth", "cave_drop", "shaft_hole", "mine_shaft", "headframe"):
        d.ellipse((1, base + 2, 14, base + 14), rim)
        d.ellipse((3, base + 4, 12, base + 12), hole)
        if kind == "cave_mouth":
            for (x, y) in ((1, base + 1), (12, base + 2), (2, base + 12), (13, base + 11)):
                d.ellipse((x - 2, y - 2, x + 2, y + 2), hx("6a6060"))
    if kind in ("mine_shaft", "headframe"):
        d.rectangle((2, base + 3, 13, base + 4), P["wood"][2])
        d.rectangle((2, base + 12, 13, base + 13), P["wood"][2])
        d.line((6, base + 4, 6, base + 12), P["wood"][3])
        d.line((9, base + 4, 9, base + 12), P["wood"][3])
    if kind in ("cave_climb", "mine_ladder"):
        rail = P["wood"][3] if kind == "mine_ladder" else hx("8a7a5a")
        d.line((4, base - 12, 4, base + 14), rail)
        d.line((11, base - 12, 11, base + 14), rail)
        for k in range(6):
            d.line((4, base - 10 + k * 4, 11, base - 10 + k * 4), P["wood"][2])
    if kind == "headframe":
        d.line((1, 2, 3, base + 8), P["wood"][1], width=2)
        d.line((14, 2, 12, base + 8), P["wood"][1], width=2)
        d.line((1, 2, 14, 2), P["wood"][2], width=2)
        d.ellipse((5, 0, 10, 5), P["wood"][3])
        d.point((7, 2), P["wood"][0])
        d.line((7, 5, 7, base + 8), hx("b8b0a0"))
    return strong(img) if kind in ("cave_climb", "mine_ladder", "headframe", "mine_shaft") else img


def window_set(kind, facing):
    """16 variants side by side, indexed by the neighbour mask."""
    strip = Image.new("RGBA", (16 * T, 2 * T), (0, 0, 0, 0))
    for m in range(16):
        strip.alpha_composite(window(kind, m, facing), (m * T, 0))
    return strip


def door_open():
    """The door swung inside: a dark doorway with the leaf at the side (16 x 32)."""
    img = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, 15, 5), P["wood"][3])
    d.rectangle((0, 6, 15, 31), hx("2a1e1c"))
    d.rectangle((1, 6, 3, 31), P["wood"][1])
    d.line((1, 6, 1, 31), P["wood"][3])
    return strong(img)


def icon(kind):
    """Small pictures of things lying on the ground (16 x 16, item ~10 px)."""
    img = Image.new("RGBA", (T, T), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if kind == "plank":
        d.rectangle((2, 6, 13, 9), P["wood"][3])
        d.line((2, 9, 13, 9), P["wood"][1])
    elif kind == "log":
        d.rectangle((3, 6, 12, 10), P["bark"][2])
        d.ellipse((10, 5, 14, 11), P["wood"][3])
        d.point((12, 8), P["wood"][1])
    elif kind == "stone":
        d.ellipse((4, 6, 12, 12), P["stone"][2])
        d.ellipse((5, 6, 9, 9), P["stone"][3])
    elif kind == "linen_shirt":
        d.polygon([(4, 5), (11, 5), (13, 8), (11, 8), (11, 12), (4, 12), (4, 8), (2, 8)], P["white"])
    elif kind == "work_trousers":
        d.polygon([(5, 4), (11, 4), (12, 12), (9, 12), (8, 7), (7, 12), (4, 12)], hx("4f4462"))
    elif kind == "boots":
        d.rectangle((4, 6, 6, 11), P["bark"][2])
        d.rectangle((9, 6, 11, 11), P["bark"][2])
        d.line((3, 11, 7, 11), P["bark"][0])
        d.line((8, 11, 12, 11), P["bark"][0])
    elif kind == "axe":
        # Held by the shaft's foot (bottom-left), the head at the top-right:
        # a socket and a fanned blade with a bright edge.
        d.line((2, 13, 10, 5), P["wood"][3])
        d.line((3, 13, 11, 5), P["wood"][1])
        d.polygon([(9, 3), (11, 1), (12, 2), (11, 4)], P["stone"][1])
        d.polygon([(11, 3), (13, 3), (14, 5), (14, 8), (12, 8), (11, 6)], P["stone"][2])
        d.line((14, 4, 14, 8), P["white"])
        d.line((13, 3, 14, 4), P["stone"][3])
        d.point((12, 5), P["stone"][3])
    elif kind == "pickaxe":
        d.line((5, 13, 10, 4), P["wood"][3])
        d.arc((3, 1, 15, 9), 190, 350, P["stone"][3], width=2)
    elif kind in ("iron_ore", "copper_ore"):
        d.ellipse((3, 5, 13, 13), hx("4a4244"))
        sp = hx("d87a48") if kind == "iron_ore" else hx("5ac8b0")
        for (x, y) in ((6, 8), (9, 7), (8, 10), (10, 10)):
            d.point((x, y), sp)
    elif kind == "raw_gem":
        d.polygon([(8, 3), (12, 7), (8, 13), (4, 7)], hx("a050d8"))
        d.polygon([(8, 3), (10, 7), (8, 9), (6, 7)], hx("e0b0ff"))
    elif kind == "spear":
        d.line((3, 13, 12, 4), P["wood"][3])
        d.polygon([(11, 2), (14, 2), (14, 5), (12, 5)], P["stone"][3])
    elif kind == "bow":
        # Limbs curving from tip to tip, bulging up-left; the string straight
        # between the nocks; a wrapped grip in the middle.
        outer = [(13, 1), (11, 1), (8, 2), (5, 4), (3, 6), (2, 8), (1, 11), (1, 13)]
        inner = [(13, 2), (11, 2), (8, 3), (5, 5), (3, 7), (2, 9), (2, 11), (2, 13)]
        for a, b in zip(outer, outer[1:]):
            d.line((a, b), P["wood"][2])
        for a, b in zip(inner, inner[1:]):
            d.line((a, b), P["wood"][3])
        d.line((13, 2, 2, 13), hx("e8e0c8"))
        d.rectangle((4, 4, 5, 5), hx("6a4a30"))
        d.point((14, 1), P["wood"][1])
        d.point((1, 14), P["wood"][1])
    elif kind == "arrow":
        # A shaft, a broad head, a feather each side of the tail, the nock.
        d.line((3, 12, 10, 5), P["wood"][3])
        d.polygon([(14, 1), (9, 3), (12, 6)], P["stone"][2])
        d.line((14, 1, 10, 3), P["stone"][3])
        for x, y in ((2, 10), (3, 9), (3, 10), (4, 9)):
            d.point((x, y), hx("c84a3c"))
        for x, y in ((4, 13), (5, 12), (5, 13), (6, 12)):
            d.point((x, y), hx("e07a60"))
        d.point((2, 13), P["white"])
    elif kind == "raw_meat":
        d.ellipse((3, 5, 13, 12), hx("b04a48"))
        d.ellipse((5, 6, 9, 9), hx("d87870"))
        d.ellipse((10, 8, 12, 10), P["white"])
    elif kind == "hide":
        d.polygon([(3, 5), (7, 3), (12, 4), (14, 9), (11, 13), (5, 12), (2, 9)], hx("8a6a4c"))
        d.polygon([(5, 6), (11, 6), (12, 9), (6, 11)], hx("a8865e"))
    return strong(img)


def building_tiles():
    """Floor (flat), ceiling and thatch roof (covers seen from above), stairs, column."""
    floor = Image.new("RGBA", (T, T))
    fp = floor.load()
    for y in range(T):
        for x in range(T):
            c = P["wood"][3] if (y // 4) % 2 == 0 else hx("c8935a")
            if y % 4 == 3:
                c = P["wood"][1]
            if (x + (y // 4) * 6) % 16 == 0:
                c = P["wood"][1]
            fp[x, y] = c
    ceiling = Image.new("RGBA", (T, T))
    cp = ceiling.load()
    for y in range(T):
        for x in range(T):
            c = b4.R["log"][2] if (x // 4) % 2 == 0 else b4.R["log"][3]
            if x % 4 == 3:
                c = b4.R["log"][0]
            if h2(x, y, 13) > 0.9:
                c = b4.R["log"][1]
            cp[x, y] = c
    thatch = Image.new("RGBA", (T, T))
    tp = thatch.load()
    for y in range(T):
        for x in range(T):
            r = h2(x, y, 77)
            c = hx("c0a458") if r > 0.35 else hx("a08240")
            if y % 5 == 4:
                c = hx("7e6230")
            if r > 0.92:
                c = hx("dcc47a")
            tp[x, y] = c
    stairs = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(stairs)
    for k in range(6):
        y = 4 + k * 5
        d.rectangle((1, y, 14, y + 3), P["wood"][3])
        d.line((1, y + 3, 14, y + 3), P["wood"][1])
    d.line((0, 4, 0, 31), P["wood"][0])
    d.line((15, 4, 15, 31), P["wood"][0])
    # Stairs rising to the east (ADR-0013; west is this one mirrored): four
    # treads seen from above, each a step higher, the south side of the run
    # below them.
    stairs_e = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(stairs_e)
    for k in range(4):
        h = 4 * (k + 1)
        x0 = 4 * k
        d.rectangle((x0, T - h, x0 + 3, 2 * T - 1 - h), P["wood"][3])          # the tread
        d.line((x0 + 3, T - h, x0 + 3, 2 * T - 1 - h), P["wood"][1])           # its edge
        d.rectangle((x0, 2 * T - h, x0 + 3, 2 * T - 1), P["wood"][2])          # the side below it
        d.line((x0, 2 * T - h, x0 + 3, 2 * T - h), P["wood"][1])
    d.line((0, 2 * T - 1, 15, 2 * T - 1), P["wood"][0])
    column = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(column)
    d.rectangle((5, 2, 10, 31), P["bark"][2])
    d.line((5, 2, 5, 31), P["bark"][1])
    d.rectangle((4, 0, 11, 2), P["wood"][3])
    d.rectangle((4, 29, 11, 31), P["wood"][2])
    return (floor, ceiling, thatch, b4.soft_edge(stairs, P["wood"][0]), b4.soft_edge(column, P["bark"][0]),
            b4.soft_edge(stairs_e, P["wood"][0]))


def people_sheet():
    """A1 people (ART_STANDARD v2). Rows: S, SE, E, NE, N (the west side is
    mirrored at run time); columns: idle, step A, step B. Frames 48x48,
    feet at (24, 45)."""
    F = 48
    sheet = Image.new("RGBA", (3 * F, 5 * F), (0, 0, 0, 0))
    for row, view in enumerate(["s", "se", "e", "ne", "n"]):
        for col in range(3):
            spr = person_view("villager", view, col)
            sheet.alpha_composite(spr, (col * F + F // 2 - spr.width // 2, row * F + 46 - spr.height + (1 if col else 0)))
    return b3.tone(sheet, MIDDLE, people=True)


def person_view(look_name, view, frame):
    """The A1 figure turned: from behind the head is hair, from the side the
    face shifts toward the way it looks; steps move the legs."""
    f = b4.PEOPLE["A1b"]
    look = b4.LOOKS[look_name]
    spr = b3.figure(look, f, None)
    px = spr.load()
    h = f["h"]
    head_bottom = int(h * f["head"]) + 2
    skin = [c[:3] for c in look["skin"]]
    if view in ("n", "ne"):
        for y in range(head_bottom):
            for x in range(spr.width):
                c = px[x, y]
                if c[3] and (c[:3] in skin or c[:3] != look["hair"][1][:3] and y > 2 and c[:3] not in [k[:3] for k in look["hair"]]):
                    px[x, y] = look["hair"][1] if x < spr.width * 0.6 else look["hair"][0]
    elif view in ("e", "se"):
        shift = 2 if view == "e" else 1
        top = int(h * f["head"] * 0.35)
        face = spr.crop((0, top, spr.width, head_bottom))
        spr.paste(Image.new("RGBA", face.size, (0, 0, 0, 0)), (0, top))
        spr.alpha_composite(face, (shift, top))
    if frame:
        legs_y = int(h * f["legs"]) + 3
        legs = spr.crop((0, legs_y, spr.width, spr.height))
        spr.paste(Image.new("RGBA", legs.size, (0, 0, 0, 0)), (0, legs_y))
        spr.alpha_composite(legs, (1 if frame == 1 else -1, legs_y))
    return strong(spr)


# --- animals (ADR-0018), placeholders: the people's frame grid -------------------
ANIMAL_ROWS = ["s", "se", "e", "ne", "n"]
ANIMALS = {
    # fur dark -> light, belly, accents
    "hare": {"fur": ["5a4632", "7a5e42", "9a7a58", "b89a74"], "belly": "e6dcc8", "eye": "1e1612"},
    "deer": {"fur": ["4a3020", "6e4a2e", "8e6440", "ae8458"], "belly": "e2d4b8", "eye": "1e1612"},
    "wolf": {"fur": ["3a3a40", "5a5a62", "7c7a80", "a09ca0"], "belly": "c8c2bc", "eye": "e8c040"},
    "cave_rat": {"fur": ["3a3236", "54484c", "6e6064", "8a7c7e"], "belly": "b8a8a4", "eye": "d84040"},
    "cave_spider": {"fur": ["1e1a22", "2e2834", "443a4c", "5e5068"], "belly": "6a3a48", "eye": "e8e060"},
    # Looters (ADR-0016), a nod to Ragnarok Online: jelly that hops.
    "poring": {"fur": ["a0405a", "d06480", "ee8ea4", "f8bccb"], "belly": "fff0f4", "eye": "2a1418"},
    "poporing": {"fur": ["3e6a2a", "5e943c", "84b85a", "b4dc8a"], "belly": "eef8de", "eye": "1a2410",
                 "leaf": ["2e5a1e", "4a8a2c"]},
}


def _animal_frame(kind, view, anim, k):
    """One 48x48 frame; feet on y 45, middle x 24."""
    img = Image.new("RGBA", (48, 48), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    a = ANIMALS[kind]
    fur = [hx(c) for c in a["fur"]]
    belly, eye = hx(a["belly"]), hx(a["eye"])
    side = view in ("e", "se", "ne")
    back = view in ("n", "ne")
    walk = anim == "walk"
    if kind in ("poring", "poporing"):
        # Squashed on the ground, stretched in the air.
        rise = [0, -3, -6, -6, -3, 0][k] if walk else 0
        squash = ([2, 0, -1, -1, 0, 2][k] if walk else [0, 1, 0, 1][k])
        base = 45 + rise
        w, h = 8 + squash, 13 - squash
        if rise:
            d.ellipse((24 - 6, 44, 24 + 6, 46), fill=(0, 0, 0, 60))                # shadow on the ground
        d.ellipse((24 - w, base - h, 24 + w, base), fill=fur[1])
        d.ellipse((24 - w + 1, base - h, 24 + w - 1, base - 2), fill=fur[2])
        d.ellipse((24 - w + 3, base - h + 2, 24 - w + 7, base - h + 5), fill=fur[3])  # shine
        d.point((24 - w + 4, base - h + 3), fill=belly)
        fx = 3 if view in ("e", "se") else (2 if view == "ne" else 0)
        if not back:
            d.point((21 + fx, base - h // 2 - 1), fill=eye)
            d.point((27 + fx, base - h // 2 - 1), fill=eye) if view != "e" else None
            d.line((23 + fx, base - h // 2 + 2, 25 + fx, base - h // 2 + 2), fill=fur[0])
        if "leaf" in a:
            lf = [hx(c) for c in a["leaf"]]
            d.line((24, base - h, 24, base - h - 3), fill=lf[0])
            d.ellipse((24, base - h - 6, 29, base - h - 3), fill=lf[1])
            d.ellipse((19, base - h - 5, 24, base - h - 2), fill=lf[0])
    elif kind == "hare":
        hop = [0, -2, -4, -3, -1, 0][k] if walk else (0 if k < 3 else -1 * 0)
        base = 45 + hop
        if side:
            d.ellipse((17, base - 7, 29, base), fill=fur[2])                 # body
            d.ellipse((18, base - 3, 28, base), fill=fur[1])
            d.ellipse((26, base - 10, 32, base - 4), fill=fur[2])           # head
            d.line((28, base - 10, 27, base - 16), fill=fur[1], width=2)    # ears
            d.line((30, base - 10, 30, base - 15), fill=fur[2], width=2)
            d.point((30, base - 8), fill=eye)
            d.ellipse((15, base - 6, 18, base - 3), fill=belly)             # tail
            if walk and k in (1, 2, 3):
                d.line((19, base, 15, base + 2), fill=fur[1])              # hind legs out
        else:
            d.ellipse((19, base - 8, 29, base), fill=fur[2])
            d.ellipse((20, base - 13, 28, base - 6), fill=fur[2])
            d.line((22, base - 13, 21, base - 19), fill=fur[1], width=2)
            d.line((26, base - 13, 27, base - 19), fill=fur[1], width=2)
            if not back:
                d.point((22, base - 10), fill=eye)
                d.point((26, base - 10), fill=eye)
                d.ellipse((22, base - 6, 26, base - 1), fill=belly)
            else:
                d.ellipse((22, base - 4, 26, base), fill=belly)
    elif kind == "cave_rat":
        hop = [0, -1, 0, 0, -1, 0][k] if walk else 0
        base = 45 + hop
        if side:
            d.line((14, base - 2, 9, base - 4), fill=fur[1])                # tail
            d.ellipse((14, base - 6, 26, base), fill=fur[2])                 # body
            d.ellipse((24, base - 6, 30, base - 1), fill=fur[2])             # head
            d.point((30, base - 3), fill=fur[0])
            d.ellipse((24, base - 8, 26, base - 6), fill=fur[3])             # ear
            d.point((28, base - 4), fill=eye)
        else:
            d.ellipse((19, base - 7, 29, base), fill=fur[2])
            d.ellipse((20, base - 9, 22, base - 7), fill=fur[3])
            d.ellipse((26, base - 9, 28, base - 7), fill=fur[3])
            if not back:
                d.point((22, base - 5), fill=eye)
                d.point((26, base - 5), fill=eye)
            else:
                d.line((24, base, 24, base + 2), fill=fur[1])
    elif kind == "cave_spider":
        step = [0, 1, 0, -1, 0, 1][k] if walk else 0
        cy0 = 40
        for i, (lx, ly) in enumerate(((-9, -3), (-10, 1), (-9, 4), (-6, 6))):
            s2 = step if i % 2 == 0 else -step
            d.line((24, cy0, 24 + lx, cy0 + ly + s2), fill=fur[1])
            d.line((24, cy0, 24 - lx, cy0 + ly - s2), fill=fur[1])
        d.ellipse((19, cy0 - 5, 29, cy0 + 4), fill=fur[2])                 # body
        d.ellipse((21, cy0 - 3, 27, cy0 + 2), fill=belly)
        if not back:
            d.point((22, cy0 - 4), fill=eye)
            d.point((26, cy0 - 4), fill=eye)
            d.point((23, cy0 - 5), fill=eye)
            d.point((25, cy0 - 5), fill=eye)
    elif kind == "wolf":
        lift = [0, -1, 0, 0, -1, 0][k] if walk else (0 if k < 2 else -1 * 0)
        top = 34 + lift
        legs = [(0, 0), (2, -2), (0, 0), (-2, 2), (0, 0), (2, -2)][k] if walk else (0, 0)
        if side:
            d.line((11, top + 2, 6, top + 6), fill=fur[1], width=3)          # tail, low
            for i, x in enumerate((14, 17, 26, 29)):
                d.line((x, top + 5, x + legs[i % 2], 45), fill=fur[1], width=2)
            d.ellipse((11, top, 31, top + 8), fill=fur[2])                  # body
            d.ellipse((13, top + 4, 29, top + 8), fill=fur[1])
            d.ellipse((28, top - 5, 36, top + 3), fill=fur[2])              # head
            d.polygon([(34, top - 1), (40, top + 1), (35, top + 3)], fill=fur[2])  # muzzle
            d.point((40, top + 1), fill=fur[0])
            d.polygon([(29, top - 4), (30, top - 9), (32, top - 4)], fill=fur[1])  # ears
            d.polygon([(32, top - 4), (34, top - 9), (35, top - 4)], fill=fur[2])
            d.point((34, top - 2), fill=eye)
        else:
            for i, x in enumerate((19, 28)):
                dy = legs[i] if walk else 0
                d.line((x, top + 6, x, 45 + min(0, dy)), fill=fur[1], width=2)
            d.ellipse((17, top - 1, 31, top + 10), fill=fur[2])
            if back:
                d.line((24, top + 6, 24, top + 12), fill=fur[1], width=3)    # tail
            d.ellipse((19, top - 9, 29, top + 1), fill=fur[2])               # head
            d.polygon([(19, top - 6), (19, top - 13), (23, top - 8)], fill=fur[1])  # ears
            d.polygon([(29, top - 6), (29, top - 13), (25, top - 8)], fill=fur[1])
            if not back:
                d.ellipse((22, top - 4, 26, top + 1), fill=belly)            # muzzle
                d.point((24, top - 3), fill=fur[0])
                d.point((21, top - 6), fill=eye)
                d.point((27, top - 6), fill=eye)
    else:  # deer
        lift = [0, -1, 0, 0, -1, 0][k] if walk else 0
        top = 31 + lift
        legs = [(0, 0), (2, -2), (0, 0), (-2, 2), (0, 0), (2, -2)][k] if walk else (0, 0)
        if side:
            for i, x in enumerate((15, 18, 27, 30)):
                dx = legs[i % 2]
                d.line((x, top + 7, x + dx, 45), fill=fur[1], width=2)
            d.ellipse((12, top, 33, top + 9), fill=fur[2])                  # body
            d.ellipse((14, top + 5, 31, top + 9), fill=fur[1])
            d.polygon([(30, top + 2), (34, top - 7), (37, top - 6), (33, top + 3)], fill=fur[2])  # neck
            d.ellipse((33, top - 11, 40, top - 5), fill=fur[2])             # head
            d.line((35, top - 11, 33, top - 16), fill=fur[0])               # antlers
            d.line((34, top - 13, 31, top - 15), fill=fur[0])
            d.point((37, top - 9), fill=eye)
            d.ellipse((10, top + 1, 13, top + 4), fill=belly)               # tail
        else:
            for i, x in enumerate((20, 27)):
                dy = legs[i] if walk else 0
                d.line((x, top + 8, x, 45 + min(0, dy)), fill=fur[1], width=2)
            d.ellipse((18, top, 30, top + 11), fill=fur[2])
            d.ellipse((20, top - 9, 28, top), fill=fur[2])
            d.line((21, top - 9, 18, top - 15), fill=fur[0])
            d.line((27, top - 9, 30, top - 15), fill=fur[0])
            if not back:
                d.point((22, top - 5), fill=eye)
                d.point((26, top - 5), fill=eye)
                d.rectangle((22, top + 2, 26, top + 8), fill=belly)
            else:
                d.ellipse((22, top + 7, 26, top + 11), fill=belly)
    return strong(img)


def animal_sheet(kind):
    """Rows S, SE, E, NE, N; columns idle 0-3, walk 4-9 (like people)."""
    sheet = Image.new("RGBA", (10 * 48, 5 * 48), (0, 0, 0, 0))
    for r, view in enumerate(ANIMAL_ROWS):
        for c in range(10):
            anim, k = ("idle", c) if c < 4 else ("walk", c - 4)
            sheet.alpha_composite(_animal_frame(kind, view, anim, k), (c * 48, r * 48))
    return b3.tone(sheet, MIDDLE, people=True)


def production_animals(visuals):
    out = OUT / "art" / "creatures"
    out.mkdir(parents=True, exist_ok=True)
    for kind in ANIMALS:
        animal_sheet(kind).save(out / f"{kind}.png")
        visuals.append({"id": "base:visual/" + kind, "kind": "visual", "for": "base:" + kind,
                        "atlas": f"art/creatures/{kind}.png", "rect": [0, 0, 48, 48], "origin": [24, 45],
                        "mode": "character", "variants": 1, "directions": ANIMAL_ROWS,
                        "animations": {"idle": {"from": 0, "frames": 4, "fps": 3},
                                       "walk": {"from": 4, "frames": 6, "fps": 10}}})


# Production material textures (brief 001, tools/art/import_texture.py), by name.
TEX = {}
MAT_DIR = OUT / "art" / "materials"
for _f in sorted(MAT_DIR.glob("*.png")) if MAT_DIR.exists() else []:
    TEX[_f.stem] = Image.open(_f).convert("RGBA")
if "wood_floor" in TEX:
    # A ceiling seen from above must not pass for the floor beside it: the
    # planks run across and are lighter, as boards in the light.
    _c = TEX["wood_floor"].transpose(Image.Transpose.ROTATE_90)
    TEX["wood_ceiling"] = Image.blend(_c, Image.new("RGBA", _c.size, (236, 206, 150, 255)), 0.28)
# Seamless textures laid over a grid of tiles: content id -> material.
GRID_MATERIALS = {"base:grass": "grass", "base:grass_dry": "grass_dry", "base:dirt": "dirt", "base:moss": "moss",
                  "base:forest_floor": "forest_floor", "base:sand": "sand", "base:water": "water",
                  "base:wood_floor": "wood_floor", "base:wood_ceiling": "wood_ceiling",
                  "base:thatch_roof": "roof_thatch"}


def production_materials(visuals):
    """Ground, floor and roof textures replace the placeholder tiles: stacked
    into art/ground.png, each one drawn as a grid of tiles (ADR-0008)."""
    used = [(i, m) for i, m in GRID_MATERIALS.items() if m in TEX]
    if not used:
        return
    atlas = Image.new("RGBA", (4 * T, sum(TEX[m].height for _, m in used)), (0, 0, 0, 0))
    y = 0
    by_id = {v["for"]: v for v in visuals}
    for for_id, m in used:
        tex = TEX[m]
        atlas.alpha_composite(tex, (0, y))
        v = by_id[for_id]
        v.update({"atlas": "art/ground.png", "rect": [0, y, T, T], "variants": 1,
                  "grid": [tex.width // T, tex.height // T]})
        y += tex.height
    atlas.save(OUT / "art" / "ground.png")
    ground_edges(by_id)


# Ground over ground (ART_STANDARD 5): a ground of higher priority laps over
# its lower neighbour with a ragged edge. Building floors take no part.
EDGE_PRIORITY = {"base:water": 0, "base:sand": 1, "base:dirt": 2, "base:forest_floor": 3,
                 "base:moss": 4, "base:grass_dry": 5, "base:grass": 6}
# Neighbour bits: sides N E S W, then corners NE SE SW NW.
_N, _E, _S, _W, _NE, _SE, _SW, _NW = 1, 2, 4, 8, 16, 32, 64, 128


def edge_masks():
    """The 47 distinct edge shapes: a corner counts only when neither side
    next to it is there (a side's band already covers its corners)."""
    out = []
    for m in range(256):
        c = m
        if m & (_N | _E):
            c &= ~_NE
        if m & (_S | _E):
            c &= ~_SE
        if m & (_S | _W):
            c &= ~_SW
        if m & (_N | _W):
            c &= ~_NW
        if c == m and m:
            out.append(m)
    return out


def _wave(t, seed):
    """Smooth noise along an edge, periodic over a cell, so bands of
    neighbouring cells meet."""
    return sum(math.sin(2 * math.pi * (k * t / T) + seed * (k + 1.7)) / k for k in (1, 2, 3)) / 1.8


def edge_shape(m):
    """Which pixels of a cell a neighbour's ground covers, for mask m."""
    cov = [[False] * T for _ in range(T)]
    for y in range(T):
        for x in range(T):
            band = lambda t, seed: 4.6 + 2.0 * _wave(t, seed)
            if m & _N and y < band(x, 1):
                cov[y][x] = True
            if m & _S and T - 1 - y < band(x, 2):
                cov[y][x] = True
            if m & _W and x < band(y, 3):
                cov[y][x] = True
            if m & _E and T - 1 - x < band(y, 4):
                cov[y][x] = True
            for bit, cx, cy, seed in ((_NE, T, 0, 5), (_SE, T, T, 6), (_SW, 0, T, 7), (_NW, 0, 0, 8)):
                if m & bit:
                    d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
                    if d < 5.6 + 1.4 * _wave(math.atan2(y - cy, x - cx) * 8, seed):
                        cov[y][x] = True
    return cov


def ground_edges(by_id):
    """art/ground_edges.png: for each ground, a block of its texture pieces
    (rows: piece py * gx + px) cut to every edge shape (columns), with a lip
    one step darker where it ends."""
    masks = edge_masks()
    shapes = [edge_shape(m) for m in masks]
    grounds = [(i, by_id[i]) for i in EDGE_PRIORITY if i in by_id and "grid" in by_id[i]]
    pieces = [v["grid"][0] * v["grid"][1] for _, v in grounds]
    img = Image.new("RGBA", (len(masks) * T, sum(pieces) * T), (0, 0, 0, 0))
    ground = Image.open(OUT / "art" / "ground.png").convert("RGBA")
    y0 = 0
    for (for_id, v), n in zip(grounds, pieces):
        gx = v["grid"][0]
        for k in range(n):
            px, py = k % gx, k // gx
            piece = ground.crop((v["rect"][0] + px * T, v["rect"][1] + py * T, v["rect"][0] + (px + 1) * T,
                                 v["rect"][1] + (py + 1) * T)).load()
            for col, cov in enumerate(shapes):
                for y in range(T):
                    for x in range(T):
                        if not cov[y][x]:
                            continue
                        c = piece[x, y]
                        inner = all(0 <= x + dx < T and 0 <= y + dy < T and cov[y + dy][x + dx]
                                    or not (0 <= x + dx < T and 0 <= y + dy < T)
                                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                        if not inner:
                            c = tuple(int(ch * 0.82) for ch in c[:3]) + (255,)
                        img.putpixel((col * T + x, y0 + k * T + y), c)
        v["edges"] = {"atlas": "art/ground_edges.png", "rect": [0, y0, T, T], "masks": masks,
                      "priority": EDGE_PRIORITY[for_id]}
        y0 += n * T
    img.save(OUT / "art" / "ground_edges.png")


def production_people(visuals):
    """Paper-doll sheets (tools/art/import_people.py, ADR-0001): the body of
    base:humanoid_adult with its animations and layer order, a layer for
    each style, a worn picture for each wearable item."""
    path = ROOT / "tools" / "art" / "imports" / "003.json"
    if not path.exists():
        return
    m = json.loads(path.read_text())
    out = Path(m["out"]).relative_to("content/base")
    if not (OUT / out / "body.png").exists():
        return
    frame = {"rect": [0, 0, 48, 48], "origin": [24, 45]}
    by_id = {v["for"]: v for v in visuals}
    dirs = ["s", "se", "e", "ne", "n"]
    by_id["base:humanoid_adult"].update(dict(frame, atlas=str(out / "body.png"), directions=dirs,
        animations={"idle": {"from": 0, "frames": 4, "fps": 6}, "walk": {"from": 4, "frames": 6, "fps": 10}},
        layer_order={d: m["layer_order"] for d in dirs}))
    by_id["base:humanoid_adult"].pop("frames", None)
    for name, spec in m["layers"].items():
        sheet = str(out / f"{name}.png")
        if spec["for"] in by_id and by_id[spec["for"]]["mode"] == "item":
            by_id[spec["for"]]["worn"] = {"atlas": sheet, "layer": spec["layer"]}
        else:
            visuals.append(dict(frame, id="base:visual/" + spec["for"].split(":")[1], kind="visual",
                                **{"for": spec["for"]}, atlas=sheet, mode="layer", layer=spec["layer"], variants=1))


def _art_origin(img):
    """Where an imported sprite stands: the middle of its base (a trunk, the
    root of a tuft) goes to the middle of the cell, its bottom row on the
    cell's bottom edge, two pixels up for depth."""
    w, h = img.size
    px = img.load()
    xs = [x for y in range(max(0, h - 4), h) for x in range(w) if px[x, y][3] > 0]
    mid = round(sum(xs) / len(xs)) if xs else w // 2
    return [mid - T // 2, h - 2]


def production_art(visuals):
    """Imported art (tools/art/imports/*.json, ADR-0008) replaces the
    placeholders of the content ids it draws."""
    by_id = {v["for"]: v for v in visuals}
    for manifest in sorted((ROOT / "tools" / "art" / "imports").glob("*.json")):
        m = json.loads(manifest.read_text())
        out = Path(m["out"]).relative_to("content/base")
        for for_id, names in m.get("visuals", {}).items():
            pics = []
            for name in names:
                path = OUT / out / f"{name}.png"
                if path.exists():
                    img = Image.open(path)
                    pics.append({"atlas": str(out / f"{name}.png"), "rect": [0, 0, img.width, img.height],
                                 "origin": _art_origin(img)})
            if not pics:
                continue
            v = by_id[for_id]
            v.update(pics[0])
            v["mode"], v["variants"] = "tall", 1
            if len(pics) > 1:
                v["alternates"] = pics[1:]


def main():
    a = Atlas(16, 51)
    for row, kind in enumerate(["grass", "grass_dry", "dirt", "moss", "forest_floor", "sand", "water"]):
        strip = Image.new("RGBA", (4 * T, T))
        for v in range(4):
            strip.alpha_composite(ground_tile(kind, v), (v * T, 0))
        a.put(0, row, strip, "base:" + kind, (0, T), "flat", variants=4)
    for col, kind in enumerate(["clover", "flower_red", "flower_yellow", "flower_blue", "fern"]):
        a.put(col, 7, small_plant(kind), "base:" + kind, (0, T), "flat")
    a.put(5, 7, fit(b4.tall_tuft(3), T, T), "base:tall_grass", (0, T), "flat")
    # Uneven bushes (B4), 32 x 16 over their one cell.
    a.put(0, 8, fit(b4.shrub(3), 2 * T, T), "base:bush", (8, T), "tall")
    a.put(2, 8, fit(b4.shrub(5, berries=True), 2 * T, T), "base:berry_bush", (8, T), "tall")
    # Trees from leaf clumps (B4): the oak over 4 x 5 cells, birch and spruce 3 x 5.
    a.put(0, 9, fit(b4.oak(7), 4 * T, 5 * T), "base:oak", (24, 5 * T), "tall")
    a.put(4, 9, fit(b4.birch(4), 3 * T, 5 * T), "base:birch", (16, 5 * T), "tall")
    a.put(7, 9, fit(b4.spruce(4), 3 * T, 5 * T), "base:spruce", (16, 5 * T), "tall")
    a.put(10, 9, fit(b4.cattails(2), T, 2 * T), "base:reeds", (0, 2 * T), "tall")
    # Walls and doors join by neighbours (mask N=1 E=2 S=4 W=8): 16 variants a row.
    for row, kind in ((15, "wood_wall"), (17, "stone_wall"), (19, "wood_door")):
        a.put(0, row, wall_set(kind), "base:" + kind, (0, 2 * T), "tall", variants=16)
        a.visuals[-1]["autotile"] = "wall"
    a.put(0, 21, wall_set("wood_door", opened=True), "base:wood_door_open_set", (0, 2 * T), "tall", variants=16)
    opened = a.visuals.pop()  # the door's "open" state, not a visual of its own
    # Windows and loopholes (ADR-0015): a set for each facing, joining walls.
    for k, kind in enumerate(("wood_window", "loophole")):
        sets = {}
        for f, facing in enumerate(("s", "e", "n", "w")):
            a.put(0, 23 + (k * 4 + f) * 2, window_set(kind, facing), "base:" + kind, (0, 2 * T), "tall", variants=16)
            sets[facing] = a.visuals.pop()["rect"]
        a.visuals.append({"id": "base:visual/" + kind, "kind": "visual", "for": "base:" + kind, "atlas": "art/tiles.png",
                          "rect": sets["s"], "origin": [0, 2 * T], "mode": "tall", "variants": 16, "autotile": "wall",
                          "rotations": {f: sets[f] for f in ("e", "n", "w")}})
    for v in a.visuals:
        if v["for"] == "base:wood_door":
            v["states"] = {"open": opened["rect"]}
    # The underground (ADR-0017): rock of any kind joins rock; the cave floor;
    # the ways between depths.
    for k, kind in enumerate(ORE_SPECKS):
        a.put(0, 39 + k * 2, rock_set(kind), "base:" + kind, (0, 2 * T), "tall", variants=16)
        a.visuals[-1]["autotile"] = "rock"
    strip = Image.new("RGBA", (4 * T, T))
    for v in range(4):
        strip.alpha_composite(cave_floor(v), (v * T, 0))
    a.put(0, 47, strip, "base:cave_floor", (0, T), "flat", variants=4)
    for col, kind in enumerate(["cave_mouth", "cave_drop", "shaft_hole", "cave_climb", "mine_ladder", "mine_shaft"]):
        a.put(col, 48, way(kind), "base:" + kind, (0, 2 * T), "tall")
    a.put(6, 47, way("headframe"), "base:headframe", (0, 3 * T), "tall")
    for col, kind in enumerate(["plank", "log", "stone", "linen_shirt", "work_trousers", "boots", "axe",
                                "spear", "bow", "arrow", "raw_meat", "hide", "pickaxe", "iron_ore", "copper_ore", "raw_gem"]):
        a.put(col, 14, icon(kind), "base:" + kind, (0, T), "item")
    floor, ceiling, thatch, stairs, column, stairs_e = building_tiles()
    a.put(7, 7, floor, "base:wood_floor", (0, T), "flat")
    a.put(8, 7, ceiling, "base:wood_ceiling", (0, T), "cover")
    a.put(9, 7, thatch, "base:thatch_roof", (0, T), "cover")
    a.put(13, 9, stairs, "base:wood_stairs", (0, 2 * T), "tall")
    down = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    dd = ImageDraw.Draw(down)
    dd.rectangle((1, T + 1, 14, 2 * T - 2), hx("1e1618"))
    for k in range(3):
        dd.rectangle((2, T + 3 + k * 4, 13, T + 4 + k * 4), P["wood"][2 - k % 2])
    dd.rectangle((0, T, 15, 2 * T - 1), outline=P["wood"][0])
    a.put(15, 9, down, "base:wood_stairs_down_frame", (0, 2 * T), "tall")
    down_v = a.visuals.pop()
    # A torch on a pole (ADR-0014: a light source).
    torch = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(torch)
    d.rectangle((7, 12, 8, 31), P["bark"][2])
    d.line((7, 12, 7, 31), P["bark"][1])
    d.rectangle((6, 9, 9, 12), P["bark"][0])
    d.polygon([(6, 9), (9, 9), (10, 6), (8, 1), (7, 3), (5, 6)], hx("e8862e"))
    d.polygon([(7, 8), (8, 8), (9, 6), (8, 3), (6, 6)], hx("f8d070"))
    a.put(12, 9, b4.soft_edge(torch, P["bark"][0]), "base:torch", (0, 2 * T), "tall")
    a.put(11, 9, stairs_e, "base:wood_stairs_east_frame", (0, 2 * T), "tall")
    east_v = a.visuals.pop()
    for v in a.visuals:
        if v["for"] == "base:wood_stairs":
            v["states"] = {"down": down_v["rect"]}
            v["rotations"] = {"e": east_v["rect"]}
            v["mirror"] = {"w": "e"}
    a.put(14, 9, column, "base:wood_column", (0, 2 * T), "tall")
    # A chest (a container, ADR-0021): a wooden box with a lid and a lock.
    chest = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(chest)
    d.rectangle((1, T + 4, 14, 2 * T - 2), P["wood"][2])
    d.rectangle((1, T + 2, 14, T + 6), P["wood"][3])
    d.line((1, T + 7, 14, T + 7), P["wood"][0])
    for x in (4, 11):
        d.line((x, T + 2, x, 2 * T - 2), P["wood"][1])
    d.rectangle((7, T + 6, 8, T + 9), hx("c8a040"))
    a.put(15, 7, strong(chest), "base:chest", (0, 2 * T), "tall")
    (OUT / "art").mkdir(parents=True, exist_ok=True)
    # The middle palette of B4 over everything, and its light grain.
    toned = b3.grain(b3.tone(a.img, MIDDLE), dict(MIDDLE, grain=0.03), 7)
    if "wood_wall_face" in TEX:
        # Walls drawn from production textures are in the palette already.
        rows = (15 * T, 39 * T)
        toned.paste(a.img.crop((0, rows[0], a.img.width, rows[1])), (0, rows[0]))
    toned.save(OUT / "art" / "tiles.png")
    people_sheet().save(OUT / "art" / "chibi_placeholder.png")
    a.visuals.append({
        "id": "base:visual/humanoid_adult", "kind": "visual", "for": "base:humanoid_adult",
        "atlas": "art/people/villager.png" if (OUT / "art" / "people" / "villager.png").exists() else "art/chibi_placeholder.png",
        "rect": [0, 0, 48, 48], "origin": [24, 45], "mode": "character",
        "variants": 1, "directions": ["s", "se", "e", "ne", "n"], "frames": 3,
    })
    production_art(a.visuals)
    production_materials(a.visuals)
    production_people(a.visuals)
    production_animals(a.visuals)
    with open(OUT / "visuals.json", "w") as f:
        json.dump({"format": 1, "defs": a.visuals}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote", len(a.visuals), "visuals")


if __name__ == "__main__":
    main()
