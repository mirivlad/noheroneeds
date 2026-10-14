#!/usr/bin/env python3
"""Temporary art for the base pack: a tile atlas, a chibi sheet and the
visual definitions that tie content ids to them (content/base/visuals.json).

These are placeholders in the spirit of probe B2 (tile 16, chibi 20x32,
coloured outline), drawn by code so the game can run before production art
exists. Production art replaces the PNGs and visuals.json; no code changes.
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
from make_probes import P, hx, lerp, h2, vnoise  # noqa: E402

T = 16
OUT = ROOT / "content" / "base"
STYLE = dict(outline="colored", detail=1)
# Characters and interactive things get a darker outline than the scenery (ADR-0001).
STRONG = dict(outline="ink", detail=1)


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


def wall(kind):
    """Top-front view: a cap on top, the front face below (16 x 32)."""
    img = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    px = img.load()
    for y in range(2 * T):
        for x in range(T):
            if kind == "wood_wall":
                cap, face = P["wood"][3], P["wood"][2]
                c = cap if y < 6 else face
                if y >= 6 and (y - 6) % 4 == 0:
                    c = P["wood"][0]
            elif kind == "stone_wall":
                cap, face = P["stone"][3], P["stone"][2]
                c = cap if y < 6 else face
                if y >= 6 and ((y - 6) % 5 == 0 or (x + ((y - 6) // 5) * 4) % 8 == 0):
                    c = P["stone"][0]
            else:  # wood_door
                c = P["wood"][1] if y >= 6 else P["wood"][3]
                if y >= 6 and x in (5, 10):
                    c = P["wood"][0]
                if (x, y) in ((12, 19), (12, 20)):
                    c = P["warm"][1]
            px[x, y] = c
    for x in range(T):
        px[x, 6] = lerp(px[x, 6], P["ink"], 0.4)
    return mp.outline(img, STRONG if kind == "wood_door" else STYLE)


def door_open():
    """The door swung inside: a dark doorway with the leaf at the side (16 x 32)."""
    img = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, 15, 5), P["wood"][3])
    d.rectangle((0, 6, 15, 31), hx("2a1e1c"))
    d.rectangle((1, 6, 3, 31), P["wood"][1])
    d.line((1, 6, 1, 31), P["wood"][3])
    return mp.outline(img, STRONG)


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
        d.line((5, 12, 11, 4), P["wood"][3])
        d.polygon([(9, 3), (13, 4), (12, 8)], P["stone"][3])
    return mp.outline(img, STRONG)


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
            c = P["wood"][2] if (x // 4) % 2 == 0 else P["wood"][3]
            if x % 4 == 3:
                c = P["wood"][0]
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
    column = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(column)
    d.rectangle((5, 2, 10, 31), P["bark"][2])
    d.line((5, 2, 5, 31), P["bark"][1])
    d.rectangle((4, 0, 11, 2), P["wood"][3])
    d.rectangle((4, 29, 11, 31), P["wood"][2])
    return floor, ceiling, thatch, mp.outline(stairs, STYLE), mp.outline(column, STYLE)


def chibi_sheet():
    """Rows: S, SE, E, NE, N (W-side rows are mirrored at run time).
    Columns: idle, step A, step B. Frames 48x48, feet at (24, 44)."""
    F = 48
    sheet = Image.new("RGBA", (3 * F, 5 * F), (0, 0, 0, 0))
    look = dict(mp.LOOKS["player"])
    for row, view in enumerate(["s", "se", "e", "ne", "n"]):
        for col in range(3):
            spr = chibi_view(20, 32, look, view, col)
            sheet.alpha_composite(spr, (col * F + F // 2 - spr.width // 2, row * F + 45 - spr.height + (1 if col else 0)))
    return sheet


def chibi_view(w, h, look, view, frame):
    """The probe chibi, turned: back views show hair, side views one eye."""
    spr = mp.chibi(w, h, look, dict(outline=None, detail=1))
    px = spr.load()
    if view in ("n", "ne"):
        # Cover the face with hair.
        for y in range(spr.height):
            for x in range(spr.width):
                c = px[x, y]
                if c[3] and c[:3] in [s[:3] for s in look["skin"]] + [look["eyes"][:3], P["ink"][:3], P["white"][:3]] \
                        and y < h * 0.5:
                    px[x, y] = look["hair"][1]
    elif view in ("e", "se"):
        shift = 2 if view == "e" else 1
        face = spr.crop((0, int(h * 0.25), spr.width, int(h * 0.45)))
        spr.paste(Image.new("RGBA", face.size, (0, 0, 0, 0)), (0, int(h * 0.25)))
        spr.alpha_composite(face, (shift, int(h * 0.25)))
    if frame:
        legs_y = int(h * 0.82) + 2
        legs = spr.crop((0, legs_y, spr.width, spr.height))
        spr.paste(Image.new("RGBA", legs.size, (0, 0, 0, 0)), (0, legs_y))
        spr.alpha_composite(legs, (1 if frame == 1 else -1, legs_y))
    return mp.outline(spr, STRONG)


def main():
    a = Atlas(16, 14)
    for row, kind in enumerate(["grass", "grass_dry", "dirt", "moss", "forest_floor", "sand", "water"]):
        strip = Image.new("RGBA", (4 * T, T))
        for v in range(4):
            strip.alpha_composite(ground_tile(kind, v), (v * T, 0))
        a.put(0, row, strip, "base:" + kind, (0, T), "flat", variants=4)
    for col, kind in enumerate(["tall_grass", "clover", "flower_red", "flower_yellow", "flower_blue", "fern", "reeds"]):
        a.put(col, 7, small_plant(kind), "base:" + kind, (0, T), "flat")
    a.put(0, 8, fit(mp.bush(T, STYLE, 3), T, T), "base:bush", (0, T), "tall")
    berry = mp.bush(T, dict(outline=None, detail=1), 5)
    bpx = berry.load()
    for (x, y) in ((4, 5), (8, 7), (11, 4), (6, 9)):
        if bpx[x, y][3]:
            bpx[x, y] = hx("c8324a")
    a.put(1, 8, fit(mp.outline(berry, STYLE), T, T), "base:berry_bush", (0, T), "tall")
    for col, (kind, src) in enumerate([("oak", "leaf"), ("birch", "birch"), ("spruce", "spruce")]):
        if src == "leaf":
            spr = mp.tree(T, "leaf", STYLE, 7)
        else:
            import make_probe_b2 as b2  # noqa: E402
            spr = b2.birch(STYLE, 4) if src == "birch" else b2.spruce(STYLE, 4)
        a.put(col * 3, 9, fit(spr, 3 * T, 4 * T), "base:" + kind, (T, 4 * T), "tall")
    for col, kind in enumerate(["wood_wall", "stone_wall", "wood_door"]):
        a.put(9 + col, 9, wall(kind), "base:" + kind, (0, 2 * T), "tall")
    a.put(12, 9, door_open(), "base:wood_door_open_frame", (0, 2 * T), "tall")
    opened = a.visuals.pop()  # not a visual of its own: the door's "open" state
    for v in a.visuals:
        if v["for"] == "base:wood_door":
            v["states"] = {"open": opened["rect"]}
    for col, kind in enumerate(["plank", "log", "stone", "linen_shirt", "work_trousers", "boots", "axe"]):
        a.put(col, 13, icon(kind), "base:" + kind, (0, T), "item")
    floor, ceiling, thatch, stairs, column = building_tiles()
    a.put(7, 7, floor, "base:wood_floor", (0, T), "flat")
    a.put(8, 7, ceiling, "base:wood_ceiling", (0, T), "cover")
    a.put(9, 7, thatch, "base:thatch_roof", (0, T), "cover")
    a.put(13, 9, stairs, "base:wood_stairs", (0, 2 * T), "tall")
    a.put(14, 9, column, "base:wood_column", (0, 2 * T), "tall")
    (OUT / "art").mkdir(parents=True, exist_ok=True)
    a.img.save(OUT / "art" / "tiles.png")
    chibi_sheet().save(OUT / "art" / "chibi_placeholder.png")
    a.visuals.append({
        "id": "base:visual/humanoid_adult", "kind": "visual", "for": "base:humanoid_adult",
        "atlas": "art/chibi_placeholder.png", "rect": [0, 0, 48, 48], "origin": [24, 45], "mode": "character",
        "variants": 1, "directions": ["s", "se", "e", "ne", "n"], "frames": 3,
    })
    with open(OUT / "visuals.json", "w") as f:
        json.dump({"format": 1, "defs": a.visuals}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote", len(a.visuals), "visuals")


if __name__ == "__main__":
    main()
