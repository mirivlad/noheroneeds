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
        d.line((5, 12, 11, 4), P["wood"][3])
        d.polygon([(9, 3), (13, 4), (12, 8)], P["stone"][3])
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
    column = Image.new("RGBA", (T, 2 * T), (0, 0, 0, 0))
    d = ImageDraw.Draw(column)
    d.rectangle((5, 2, 10, 31), P["bark"][2])
    d.line((5, 2, 5, 31), P["bark"][1])
    d.rectangle((4, 0, 11, 2), P["wood"][3])
    d.rectangle((4, 29, 11, 31), P["wood"][2])
    return floor, ceiling, thatch, b4.soft_edge(stairs, P["wood"][0]), b4.soft_edge(column, P["bark"][0])


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


# Production material textures (brief 001, tools/art/import_texture.py), by name.
TEX = {}
MAT_DIR = OUT / "art" / "materials"
for _f in sorted(MAT_DIR.glob("*.png")) if MAT_DIR.exists() else []:
    TEX[_f.stem] = Image.open(_f).convert("RGBA")
# Seamless textures laid over a grid of tiles: content id -> material.
GRID_MATERIALS = {"base:grass": "grass", "base:grass_dry": "grass_dry", "base:dirt": "dirt", "base:moss": "moss",
                  "base:forest_floor": "forest_floor", "base:sand": "sand", "base:water": "water",
                  "base:wood_floor": "wood_floor", "base:wood_ceiling": "wood_floor",
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
    a = Atlas(16, 23)
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
    for v in a.visuals:
        if v["for"] == "base:wood_door":
            v["states"] = {"open": opened["rect"]}
    for col, kind in enumerate(["plank", "log", "stone", "linen_shirt", "work_trousers", "boots", "axe"]):
        a.put(col, 14, icon(kind), "base:" + kind, (0, T), "item")
    floor, ceiling, thatch, stairs, column = building_tiles()
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
    for v in a.visuals:
        if v["for"] == "base:wood_stairs":
            v["states"] = {"down": down_v["rect"]}
    a.put(14, 9, column, "base:wood_column", (0, 2 * T), "tall")
    (OUT / "art").mkdir(parents=True, exist_ok=True)
    # The middle palette of B4 over everything, and its light grain.
    toned = b3.grain(b3.tone(a.img, MIDDLE), dict(MIDDLE, grain=0.03), 7)
    if "wood_wall_face" in TEX:
        # Walls drawn from production textures are in the palette already.
        rows = (15 * T, 23 * T)
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
    with open(OUT / "visuals.json", "w") as f:
        json.dump({"format": 1, "defs": a.visuals}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote", len(a.visuals), "visuals")


if __name__ == "__main__":
    main()
