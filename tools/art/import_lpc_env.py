#!/usr/bin/env python3
"""The world's environment from LPC packs (tools/art/fetch_lpc_env.sh).

Ground: every ground of the game is an LPC terrain drawn over transparency
with its transitions. The atlas content/base/art/lpc_env/terrain.png has a row
of 32 px tiles per ground: column m (1..15) is the tile whose corners in the
mask m are this ground (bits: top-left 1, top-right 2, bottom-left 4,
bottom-right 8); columns 16.. are more fills. WorldView draws them on a grid
of cell corners (ADR-0024): each tile sits between four cells.

Writes the atlases, content/base/lpc_env_visuals.json and the environment
part of CREDITS-art.md.
Usage: tools/art/import_lpc_env.py
"""
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "art_src" / "lpc_env"
OUT = ROOT / "content" / "base" / "art" / "lpc_env"
VISUALS = ROOT / "content" / "base" / "lpc_env_visuals.json"
CREDITS = ROOT / "CREDITS-art.md"
T = 32

TERRAIN_DIR = SRC / "lpc-terrains" / "lpc-terrains"
# Game ground -> LPC terrain and its priority: a higher ground's edge is
# drawn over a lower one (grass over dirt, water with its bank over all).
GROUNDS = {
    "base:dirt": ("Dirt_Brown", 0),
    "base:sand": ("Sand", 1),
    "base:farmland": ("farm:plowed_soil", 2),
    "base:forest_floor": ("Dirt_Roots", 3),
    "base:grass_dry": ("Grass_Light", 4),
    "base:moss": ("Grass_Dark", 5),
    "base:grass": ("Grass", 6),
    "base:water": ("Water", 7),
    "base:cave_floor": ("Dirt_Dark", -1),
}
FARM = SRC / "lpc-farm" / "submission_daneeklu" / "tilesets"
# An LPC terrain block (96 x 192: a lone piece, inner corners, edges, fills)
# as corner masks (TL 1, TR 2, BL 4, BR 8) -> (column, row) of the block.
BLOCK_MASKS = {7: (1, 0), 11: (2, 0), 13: (1, 1), 14: (2, 1), 8: (0, 2), 12: (1, 2), 4: (2, 2),
               10: (0, 3), 15: (1, 3), 5: (2, 3), 2: (0, 4), 3: (1, 4), 1: (2, 4)}
# Fills that are other things (animated water, a cracked variant) are left out.
SKIP_FILLS = {"Water": {566, 569, 572}}


def terrain_tiles():
    """LPC terrain name -> {mask: [tile ids]} for tiles of that terrain alone."""
    root = ET.parse(TERRAIN_DIR / "terrain-v7.tsx").getroot()
    names = [t.get("name") for t in root.find("terraintypes")]
    out = {n: {} for n in names}
    for tile in root.findall("tile"):
        corners = (tile.get("terrain") or "").split(",")
        kinds = {c for c in corners if c != ""}
        if len(corners) != 4 or len(kinds) != 1:
            continue
        name = names[int(kinds.pop())]
        mask = sum(1 << i for i, c in enumerate(corners) if c != "")
        out[name].setdefault(mask, []).append(int(tile.get("id")))
    return out


def _close(a, b):
    """Whether two tiles are the same ground: their mean colours are near."""
    def mean(img):
        px = list(img.convert("RGB").getdata())
        return [sum(p[c] for p in px) / len(px) for c in range(3)]
    return sum(abs(x - y) for x, y in zip(mean(a), mean(b))) < 40


def build_terrain():
    sheet = Image.open(TERRAIN_DIR / "terrain-v7.png").convert("RGBA")
    columns = sheet.width // T
    tiles = terrain_tiles()

    def tile(i):
        x, y = (i % columns) * T, (i // columns) * T
        return sheet.crop((x, y, x + T, y + T))

    rows = sorted(GROUNDS.items(), key=lambda kv: kv[1][1])
    # Blocks of other packs (name "farm:<file>"): their tiles by mask, the
    # diagonals made of two corner pieces laid together.
    blocks = {}
    for _, (name, _) in rows:
        if name.startswith("farm:"):
            img = Image.open(FARM / (name[5:] + ".png")).convert("RGBA")
            cut = lambda c, r: img.crop((c * T, r * T, c * T + T, r * T + T))
            m = {k: cut(*v) for k, v in BLOCK_MASKS.items()}
            for diag, (a, b) in {6: (2, 4), 9: (1, 8)}.items():
                d = m[a].copy()
                d.alpha_composite(m[b])
                m[diag] = d
            blocks[name] = {"tiles": m, "fills": [cut(0, 5), cut(1, 5), cut(2, 5), cut(1, 3)]}
    fills_max = max(len(tiles[t][15]) if t in tiles else len(blocks[t]["fills"]) for _, (t, _) in rows)
    atlas = Image.new("RGBA", ((15 + fills_max) * T, len(rows) * T))
    defs = []
    for r, (ground, (name, priority)) in enumerate(rows):
        if name in blocks:
            for m in range(1, 15):
                atlas.paste(blocks[name]["tiles"][m], (m * T, r * T))
            for k, img in enumerate(blocks[name]["fills"]):
                atlas.paste(img, ((15 + k) * T, r * T))
            defs.append({
                "id": "base:visual/" + ground.split(":")[1], "kind": "visual", "for": ground, "mode": "flat",
                "atlas": "art/lpc_env/terrain.png", "rect": [15 * T, r * T, T, T], "origin": [0, T], "pixel_scale": 0.5,
                "terrain": {"priority": priority, "fills": len(blocks[name]["fills"])},
            })
            continue
        masks = tiles[name]
        missing = [m for m in range(1, 16) if m not in masks]
        if missing:
            sys.exit("%s lacks masks %s" % (name, missing))
        for m in range(1, 15):
            atlas.paste(tile(masks[m][0]), (m * T, r * T))
        # A fill must be the ground itself: whole, and like the first one
        # (some tiles marked full are other things, holes or overlays).
        first = tile(masks[15][0])
        fills = [i for i in masks[15] if i not in SKIP_FILLS.get(name, set())
                 and tile(i).getextrema()[3][0] == 255 and _close(tile(i), first)]
        for k, i in enumerate(fills):
            atlas.paste(tile(i), ((15 + k) * T, r * T))
        defs.append({
            "id": "base:visual/" + ground.split(":")[1], "kind": "visual", "for": ground, "mode": "flat",
            "atlas": "art/lpc_env/terrain.png", "rect": [15 * T, r * T, T, T], "origin": [0, T], "pixel_scale": 0.5,
            "terrain": {"priority": priority, "fills": len(fills)},
        })
    OUT.mkdir(parents=True, exist_ok=True)
    atlas.save(OUT / "terrain.png", optimize=True)
    return defs


WALLS_DIR = SRC / "lpc-walls" / "lpc-walls"
DOORS_DIR = SRC / "lpc-windows-doors" / "lpc-windows-doors-v2"
FLOORS_DIR = SRC / "lpc-floors" / "lpc-floors"
ROOF = SRC / "thatched-roof.png"
STOREY = 64  # a wall's face (ADR-0024)
DOOR = 56
# Walls: the top (an LPC "Ceilings" colour, drawn on cell corners) and the
# face (x, y of a 96 px face block: three seamless tiles; rows top and bottom).
WALLS = {
    "base:wood_wall": {"cap": 1, "face": (512, 2176)},
    "base:stone_wall": {"cap": 8, "face": (256, 928)},
    "base:wood_door": {"cap": 1, "face": (512, 2176), "door": (192, 833, 48), "open": (512, 640, 52)},
    "base:wood_window": {"cap": 1, "face": (512, 2176), "window": (384, 64, 32, 32, 12)},
    "base:loophole": {"cap": 8, "face": (256, 928), "window": (608, 320, 32, 32, 18)},
    # Rock of the underground, read from a passage outwards: a face of dark
    # stone (in the tone of the cap's trim) at the passage's edge, then the
    # grey stone of the rock's top (a terrain fill) inside the trim, then the
    # dark of the mass deep in (the author, 20.10.2026: "по краю прохода —
    # кирпич, дальше серо и темно").
    "base:rock": {"cap": 16, "fill": "Rock_Gray", "face": (128, 928)},
    "base:iron_ore_rock": {"cap": 16, "fill": "Rock_Gray", "face": (128, 928), "ore": (64, 64)},
    "base:copper_ore_rock": {"cap": 16, "fill": "Rock_Gray", "face": (128, 928), "ore": (96, 32)},
    "base:gem_rock": {"cap": 16, "fill": "Rock_Gray", "face": (128, 928), "ore": (128, 256)},
}
ORE = SRC / "ore_0.png"
# Cave rock (the author, 20.10.2026: walls in caves look like rock, not
# buildings, and do not stand over the passage): LPC Mountains' grey cliff,
# drawn inside the rock's own cell. Its top from the corner tiles (by corner
# mask TL 1, TR 2, BL 4, BR 8), a face where a passage is south: the lip of
# the cliff and its foot; deep in the mass, the black cliff's top.
MOUNTAINS = SRC / "lpc-mountains" / "submission" / "mountains-v6.png"
CLIFF_TOP = {1: 914, 2: 912, 3: 913, 4: 786, 5: 850, 7: 851, 8: 784, 10: 848, 11: 847, 12: 785, 13: 1109, 14: 1108, 15: 849}
CLIFF_LIP = (912, 913, 914)    # left end, middle, right end: the top's edge and the face below it
CLIFF_FOOT = (1040, 1041, 1042)  # the foot of the face
CLIFF_DEEP = 861
LIP_ROWS = 24  # of the lip tile kept; the foot's first rows below them
FACE_FROM = 6  # rows of the top kept above the lip (its edge when nothing is north)
MINE = SRC / "lpc-mine" / "lpc-mine" / "mine.png"
# Flat things: x, y and grid of a seamless block (floors, ceilings, roofs).
FLAT = {
    "base:wood_floor": ("floors", 192, 1152, 2, 2, "flat"),
    "base:wood_ceiling": ("floors", 192, 1216, 2, 2, "cover"),
    "base:thatch_roof": ("roof", 192, 352, 3, 3, "cover"),
}


def ceilings(color):
    """mask -> 32 px tile of a wall top colour (corners: TL 1, TR 2, BL 4, BR 8)."""
    sheet = Image.open(WALLS_DIR / "walls.png").convert("RGBA")
    root = ET.parse(WALLS_DIR / "walls.tsx").getroot()
    out = {}
    for ws in root.find("wangsets"):
        if ws.get("name") != "Ceilings":
            continue
        for wt in ws.findall("wangtile"):
            w = [int(x) for x in wt.get("wangid").split(",")]
            corners = [w[7], w[1], w[5], w[3]]  # TL TR BL BR
            if any(c not in (0, color) for c in corners):
                continue
            mask = sum(1 << i for i, c in enumerate(corners) if c == color)
            if mask and mask not in out:
                i = int(wt.get("tileid"))
                x, y = (i % 64) * T, (i // 64) * T
                out[mask] = sheet.crop((x, y, x + T, y + T))
    # All four corners in the mass: LPC leaves a hole there (a room's middle
    # in its own maps); a wall's top is the mass's colour all over.
    colours = [c for c in out[3].getdata() if c[3] == 255]
    out[15] = Image.new("RGBA", (T, T), max(set(colours), key=colours.count))
    return out


def wall_top(tiles, nesw):
    """The top of a wall cell whose neighbours N E S W (bits 1 2 4 8) are
    walls: the four quarters of the corner tiles round it (a diagonal counts
    when both its sides are walls)."""
    n, e, s_, w = (nesw >> 0) & 1, (nesw >> 1) & 1, (nesw >> 2) & 1, (nesw >> 3) & 1
    ne, se, sw, nw = n & e, s_ & e, s_ & w, n & w
    h = T // 2
    img = Image.new("RGBA", (T, T))
    # corner tile masks (TL 1, TR 2, BL 4, BR 8) and the quarter of it this cell sees
    for (m, q, at) in [
        (nw * 1 | n * 2 | w * 4 | 8, (h, h), (0, 0)),     # the corner at the cell's top-left
        (n * 1 | ne * 2 | 4 | e * 8, (0, h), (h, 0)),     # top-right
        (w * 1 | 2 | sw * 4 | s_ * 8, (h, 0), (0, h)),    # bottom-left
        (1 | e * 2 | s_ * 4 | se * 8, (0, 0), (h, h)),    # bottom-right
    ]:
        img.alpha_composite(tiles[m].crop((q[0], q[1], q[0] + h, q[1] + h)), at)
    return img


def without(img, colour):
    """The picture with one colour taken out (the dark of a cap's middle)."""
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            if px[x, y][:3] == colour[:3]:
                px[x, y] = (0, 0, 0, 0)
    return out


def mountain_tile(sheet, i):
    x, y = (i % (sheet.width // T)) * T, (i // (sheet.width // T)) * T
    return sheet.crop((x, y, x + T, y + T))


def rock_cell(sheet, nesw):
    """A cell of cave rock with rock N E S W (bits 1 2 4 8): its top from
    the cliff's corner tiles (the edge on the cell's border), a face in the
    cell itself where nothing is south, the black top deep in the mass."""
    if nesw == 15:
        return mountain_tile(sheet, CLIFF_DEEP)
    img = wall_top({m: mountain_tile(sheet, i) for m, i in CLIFF_TOP.items()}, nesw)
    if not nesw & 4:
        e, w = (nesw >> 1) & 1, (nesw >> 3) & 1
        h = T // 2
        # The cliff's lip and foot are corner tiles too: the cell's left half
        # is the right half of the tile at its bottom-left corner (a left end
        # where nothing is west), its right half the other's left half.
        face = Image.new("RGBA", (T, T))
        for k_left, k_right in [((1 if w else 0), (1 if e else 2))]:
            for k, (src_x, at_x) in ((k_left, (h, 0)), (k_right, (0, h))):
                lip = mountain_tile(sheet, CLIFF_LIP[k]).crop((src_x, FACE_FROM, src_x + h, LIP_ROWS))
                foot = mountain_tile(sheet, CLIFF_FOOT[k]).crop((src_x, 0, src_x + h, T - LIP_ROWS))
                face.alpha_composite(lip, (at_x, FACE_FROM))
                face.alpha_composite(foot, (at_x, LIP_ROWS))
        img.paste(Image.new("RGBA", (T, T - FACE_FROM)), (0, FACE_FROM))  # the top's lower part gives way to the face
        img.alpha_composite(face)
    return img


def wall_face(walls, fx, fy, nesw):
    """A face 64 px tall: the block's top and bottom rows; its end tiles at
    the wall's ends."""
    e, w = (nesw >> 1) & 1, (nesw >> 3) & 1
    def column(c):
        top = walls.crop((fx + c * T, fy, fx + c * T + T, fy + T))
        bottom = walls.crop((fx + c * T, fy + 2 * T, fx + c * T + T, fy + 3 * T))
        col = Image.new("RGBA", (T, STOREY))
        col.paste(top, (0, 0))
        col.paste(bottom, (0, T))
        return col
    if not w and not e:
        face = column(0)
        face.paste(column(2).crop((T // 2, 0, T, STOREY)), (T // 2, 0))
        return face
    return column(0 if not w else (2 if not e else 1))


def taller(img, rows):
    """A door made taller by repeating rows of its middle (planks go on), not scaled."""
    mid = img.height // 2
    out = Image.new("RGBA", (img.width, img.height + rows))
    out.paste(img.crop((0, 0, img.width, mid)), (0, 0))
    out.paste(img.crop((0, mid - rows, img.width, mid)), (0, mid))
    out.paste(img.crop((0, mid, img.width, img.height)), (0, mid + rows))
    return out


def terrain_fill(name):
    """The first fill tile of an LPC terrain."""
    sheet = Image.open(TERRAIN_DIR / "terrain-v7.png").convert("RGBA")
    i = terrain_tiles()[name][15][0]
    x, y = (i % (sheet.width // T)) * T, (i // (sheet.width // T)) * T
    return sheet.crop((x, y, x + T, y + T))


def spec_of(part):
    return WALLS[part]


def build_buildings():
    walls = Image.open(WALLS_DIR / "walls.png").convert("RGBA")
    ore = Image.open(ORE).convert("RGBA")
    fills = {n: terrain_fill(n) for n in {spec["fill"] for spec in WALLS.values() if "fill" in spec}}
    doors = Image.open(DOORS_DIR / "windows-doors.png").convert("RGBA")
    mountains = Image.open(MOUNTAINS).convert("RGBA")
    rows = []  # (visual id parts, [16 images])
    defs = []
    for part, spec in WALLS.items():
        tiles = ceilings(spec["cap"])
        for state in ["", "open"] if "open" in spec else [""]:
            variants = []
            for nesw in range(16):
                img = Image.new("RGBA", (T, T + STOREY))
                if "fill" in spec:  # cave rock: a flat cell (the row's top tile)
                    img.alpha_composite(rock_cell(mountains, nesw), (0, 0))
                    if "ore" in spec:
                        x, y = spec["ore"]
                        img.alpha_composite(ore.crop((x, y, x + T, y + T)), (0, 0))
                    variants.append(img)
                    continue
                if "fill" in spec and nesw != 15:
                    # Rock at the mass's edge: its grey top inside the trim
                    # (the mass's colour of the trim tiles left out).
                    img.alpha_composite(fills[spec["fill"]], (0, 0))
                    img.alpha_composite(without(wall_top(tiles, nesw), tiles[15].getpixel((0, 0))), (0, 0))
                else:
                    img.alpha_composite(wall_top(tiles, nesw), (0, 0))
                if not nesw & 4:  # the face shows where nothing stands south
                    img.alpha_composite(wall_face(walls, spec["face"][0], spec["face"][1], nesw), (0, T))
                    if "ore" in spec:
                        x, y = spec["ore"]
                        img.alpha_composite(ore.crop((x, y, x + T, y + T)), (0, T + STOREY - T - 4))
                    if "door" in spec or "open" in spec:
                        x, y, h = spec["open" if state else "door"]
                        door = taller(doors.crop((x, y, x + T, y + h)), DOOR - h)
                        img.alpha_composite(door, (0, T + STOREY - DOOR))
                    if "window" in spec:
                        x, y, ww, wh, dy = spec["window"]
                        img.alpha_composite(doors.crop((x, y, x + ww, y + wh)), (0, T + dy))
                variants.append(img)
            rows.append(((part, state), variants))
    atlas = Image.new("RGBA", (16 * T, len(rows) * (T + STOREY)))
    at = {}
    for r, ((part, state), variants) in enumerate(rows):
        for i, img in enumerate(variants):
            atlas.paste(img, (i * T, r * (T + STOREY)))
        at[(part, state)] = [0, r * (T + STOREY), T, T + STOREY]
    atlas.save(OUT / "walls.png", optimize=True)
    for part in WALLS:
        rect = at[(part, "")] if "fill" not in spec_of(part) else at[(part, "")][:3] + [T]  # rock: a cell
        d = {"id": "base:visual/" + part.split(":")[1], "kind": "visual", "for": part, "mode": "tall",
             "atlas": "art/lpc_env/walls.png", "rect": rect, "origin": [0, rect[3]],
             "pixel_scale": 0.5, "variants": 16, "autotile": "rock" if "fill" in spec_of(part) else "wall"}
        if (part, "open") in at:
            d["states"] = {"open": at[(part, "open")]}
        defs.append(d)
    # Floors, ceilings and roofs: seamless blocks, a tile a cell by its place.
    sources = {"floors": Image.open(FLOORS_DIR / "floors.png").convert("RGBA"),
               "roof": Image.open(ROOF).convert("RGBA")}
    flat = Image.new("RGBA", (3 * T, len(FLAT) * 3 * T))
    for r, (part, (src, x, y, gw, gh, mode)) in enumerate(FLAT.items()):
        flat.paste(sources[src].crop((x, y, x + gw * T, y + gh * T)), (0, r * 3 * T))
        defs.append({"id": "base:visual/" + part.split(":")[1], "kind": "visual", "for": part, "mode": mode,
                     "atlas": "art/lpc_env/flat.png", "rect": [0, r * 3 * T, T, T], "origin": [0, T],
                     "pixel_scale": 0.5, "variants": 1, "grid": [gw, gh]})
    flat.save(OUT / "flat.png", optimize=True)
    return defs


PLANTS_PNG = SRC / "lpc-plants" / "lpc-flowers-plants-fungi-wood" / "plants.png"
TREES_DIR = SRC / "lpc-trees" / "lpc-trees"
# Plants: id -> (sheet, [rects: the picture and its alternates]); a picture
# is cut to what is drawn and stands with its base (trunk, stem) on the
# middle of its cell.
PLANTS = {
    "base:tall_grass": ("plants", [(0, 320, 32, 32), (32, 320, 32, 32), (64, 320, 32, 32)]),
    "base:clover": ("plants", [(320, 256, 32, 32), (352, 256, 32, 32)]),
    "base:flower_red": ("plants", [(256, 96, 32, 32), (256, 160, 32, 32)]),
    "base:flower_yellow": ("plants", [(288, 96, 32, 32), (288, 160, 32, 32)]),
    "base:flower_blue": ("plants", [(224, 96, 32, 32), (224, 160, 32, 32)]),
    "base:fern": ("plants", [(352, 288, 32, 32), (384, 288, 32, 32)]),
    "base:reeds": ("plants", [(32, 416, 32, 32), (64, 416, 32, 32)]),
    "base:bush": ("plants", [(192, 704, 64, 64), (256, 704, 64, 64), (320, 704, 64, 64)]),
    "base:berry_bush": ("plants", [(160, 160, 32, 32), (160, 128, 32, 32)]),
    "base:oak": ("trees", [(301, 512, 165, 200), (491, 512, 170, 200), (672, 512, 160, 200), (835, 512, 155, 200)]),
    "base:birch": ("trees", [(164, 224, 89, 128), (264, 224, 107, 128)]),
    "base:spruce": ("trees", [(64, 352, 63, 160), (0, 352, 62, 160)]),
}


def _base(img):
    """Where a cut picture stands: the middle of its lowest solid row (a
    trunk or stem; a shadow is half transparent and does not count)."""
    px = img.load()
    for y in range(img.height - 1, -1, -1):
        xs = [x for x in range(img.width) if px[x, y][3] == 255]
        if len(xs) >= 2:
            return (min(xs) + max(xs)) // 2, y
    return img.width // 2, img.height - 1


def build_plants():
    sheets = {"plants": Image.open(PLANTS_PNG).convert("RGBA"),
              "trees": Image.open(TREES_DIR / "trees-green.png").convert("RGBA")}
    pieces = []  # (id, [(img, origin)])
    for part, (sheet, rects) in PLANTS.items():
        pics = []
        for (x, y, w, h) in rects:
            img = sheets[sheet].crop((x, y, x + w, y + h))
            img = img.crop(img.getbbox())
            bx, by = _base(img)
            # The base on the cell's middle, a little above its bottom edge.
            pics.append((img, [bx - T // 2, by + 6]))
        pieces.append((part, pics))
    # Shelf packing: a row per plant.
    width = max(sum(i.width for i, _ in pics) for _, pics in pieces)
    height = sum(max(i.height for i, _ in pics) for _, pics in pieces)
    atlas = Image.new("RGBA", (width, height))
    defs = []
    y = 0
    for part, pics in pieces:
        x = 0
        rects = []
        for img, origin in pics:
            atlas.paste(img, (x, y))
            rects.append(([x, y, img.width, img.height], origin))
            x += img.width
        y += max(i.height for i, _ in pics)
        (r0, o0), alts = rects[0], rects[1:]
        defs.append({"id": "base:visual/" + part.split(":")[1], "kind": "visual", "for": part, "mode": "tall",
                     "atlas": "art/lpc_env/plants.png", "rect": r0, "origin": o0, "pixel_scale": 0.5, "variants": 1,
                     "alternates": [{"rect": r, "origin": o} for r, o in alts]})
    atlas.save(OUT / "plants.png", optimize=True)
    return defs


# Things standing on a cell: id -> (file under art_src/lpc_env, rect, states).
PROPS = {
    "base:wood_stairs": ("wooden_stairs.png", (0, 320, 32, 64), {"down": (0, 320, 32, 64)}),
    "base:torch": ("house_inside_1.png", (416, 192, 32, 96), {}),
    "base:wood_column": ("lpc-windows-doors/lpc-windows-doors-v2/windows-doors.png", (960, 0, 32, 64), {}),
    "base:chest": ("chest2.png", (0, 0, 32, 32), {"open": (32, 0, 32, 32)}),
    "base:mine_ladder": ("lpc-mine/lpc-mine/mine.png", (0, 288, 32, 96), {}),
    # A ladder out of a cave: generated (docs/art/AI_ASSETS.md), LPC wood colours.
    "base:cave_climb": (str(ROOT / "tools" / "art" / "generated" / "cave_ladder" / "cave_ladder.png"), (0, 0, 32, 74), {}),
    "base:headframe": ("lpc-mine/lpc-mine/mine.png", (0, 0, 128, 224), {}),
    "base:workbench": ("house_inside_1.png", (96, 32, 32, 64), {}),
    "base:bed": ("house_inside_1.png", (72, 172, 48, 88), {}),
    "base:forge": ("ore_0.png", (64, 384, 64, 128), {}),
    "base:campfire": ("../lpc_items/effects_5.png", (544, 32, 32, 32), {}),
}
# Openings in the ground, a cell each: an LPC terrain's lone piece (a pit).
HOLES = {
    "base:cave_mouth": "Hole_Black",
    "base:cave_drop": "Hole_Black",
    "base:shaft_hole": "Hole_Brown",
    "base:mine_shaft": "Hole_Brown",
}


def build_props():
    """Props a cell wide, standing on its bottom edge (their own pixels, cut
    to what is drawn but keeping the cell's width so they sit on it)."""
    pics = []
    sheet = Image.open(TERRAIN_DIR / "terrain-v7.png").convert("RGBA")
    columns = sheet.width // T
    tiles = terrain_tiles()
    for part, name in HOLES.items():
        corners = {m: sheet.crop(((ids[0] % columns) * T, (ids[0] // columns) * T,
                                  (ids[0] % columns) * T + T, (ids[0] // columns) * T + T))
                   for m, ids in tiles[name].items()}
        pics.append((part, {"": wall_top(corners, 0)}))
    for part, (path, rect, states) in PROPS.items():
        src = Image.open(SRC / path).convert("RGBA")
        cuts = {}
        for name, (x, y, w, h) in [("", rect)] + list(states.items()):
            img = src.crop((x, y, x + w, y + h))
            box = img.getbbox()
            cuts[name] = img.crop((0, box[1], w, box[3]))
        pics.append((part, cuts))
    width = max(sum(c.width for c in cuts.values()) for _, cuts in pics)
    atlas = Image.new("RGBA", (width, sum(max(c.height for c in cuts.values()) for _, cuts in pics)))
    defs = []
    y = 0
    for part, cuts in pics:
        x = 0
        rects = {}
        for name, img in cuts.items():
            atlas.paste(img, (x, y + max(c.height for c in cuts.values()) - img.height))
            rects[name] = [x, y + max(c.height for c in cuts.values()) - img.height, img.width, img.height]
            x += img.width
        y += max(c.height for c in cuts.values())
        # A prop wider than its cell stands with its middle on the cell's.
        d = {"id": "base:visual/" + part.split(":")[1], "kind": "visual", "for": part, "mode": "tall",
             "atlas": "art/lpc_env/props.png", "rect": rects[""],
             "origin": [(rects[""][2] - T) // 2, rects[""][3] - 4], "pixel_scale": 0.5, "variants": 1}
        if len(rects) > 1:
            d["states"] = {k: v for k, v in rects.items() if k}
        defs.append(d)
    atlas.save(OUT / "props.png", optimize=True)
    return defs


ITEMS_DIR = ROOT / "art_src" / "lpc_items"
CHARS = ROOT / "content" / "base" / "art" / "lpc"
# Item pictures (inventory, hands, the ground), 32 px: id -> (file, x, y) of
# a 32 px cell; clothes are a frame of the LPC layer they are worn as.
ITEMS = {
    "base:plank": ("idyl/board.png", 0, 0),
    "base:log": ("idyl/log.png", 0, 0),
    "base:raw_meat": ("idyl/steak.png", 0, 0),
    "base:hide": ("idyl/rawhide.png", 0, 0),
    "base:arrow": ("idyl/arrow.png", 0, 0),
    "base:pickaxe": ("idyl/iron_pickaxe.png", 0, 0),
    "base:iron_ore": ("idyl/iron_ore.png", 0, 0),
    "base:copper_ore": ("idyl/copper_ore.png", 0, 0),
    "base:axe": ("items1_0.png", 224, 224),
    "base:spear": ("items1_0.png", 160, 64),
    "base:bow": ("items1_0.png", 128, 32),
    "base:raw_gem": ("items1_0.png", 384, 96),
    "base:stone": (str(ORE), 192, 32),
    "base:iron_ingot": (str(ORE), 32, 352),
    "base:copper_ingot": (str(ORE), 96, 352),
    "base:cooked_meat": ("items1_0.png", 256, 192),
    "base:iron_axe": ("items1_0.png", 192, 224),
    "base:iron_pickaxe": ("items1_0.png", 96, 0),
    "base:wheat_seeds": (str(FARM / "farming_fishing.png"), 32, 160),
    "base:carrot_seeds": (str(FARM / "farming_fishing.png"), 32, 192),
    "base:wheat": (str(FARM / "wheat.png"), 0, 0),
    "base:carrot": (str(FARM / "plants.png"), 64, 352),
    "base:bread": ("idyl/bread.png", 0, 0),
    "base:fishing_rod": ("items1_0.png", 384, 224),
    "base:garnet_amulet": ("items1_0.png", 416, 160),
    "base:amethyst_amulet": ("items1_0.png", 416, 192),
    "base:raw_fish": ("items1_0.png", 416, 224),
    "base:perch": (str(FARM / "farming_fishing.png"), 528, 194),
    "base:pike": (str(FARM / "farming_fishing.png"), 528, 321),
    "base:cooked_fish": ("items1_0.png", 352, 128),
    "base:leather": ("idyl/leather.png", 0, 0),
    "base:wool": ("idyl/thread.png", 0, 0),
    "base:cloth": ("idyl/cloth.png", 0, 0),
    "base:egg": ("idyl/egg.png", 0, 0),
    "base:bucket": ("idyl/bucket.png", 0, 0),
    "base:coin": (str(ROOT / "tools" / "art" / "generated" / "coin" / "coin.png"), 0, 0),  # generated (docs/art/AI_ASSETS.md)
}
# A picture with some of its colours changed inside a box (a recolouring, not
# a new drawing: the bucket's dark inside as water or milk): id -> (file,
# box x0, y0, x1, y1, {from: to}).
RECOLOURED = {
    "base:water_bucket": ("idyl/bucket.png", 8, 5, 25, 15, {(22, 22, 20): (52, 104, 170), (35, 28, 26): (82, 140, 196)}),
    "base:milk_bucket": ("idyl/bucket.png", 8, 5, 25, 15, {(22, 22, 20): (232, 228, 214), (35, 28, 26): (204, 198, 184)}),
}
# Tools drawn in the hands by LPC: the south standing frame of their layers.
HELD_ICONS = {"base:hoe": ["tools/hoe/bg/walk.png", "tools/hoe/fg/walk.png"]}
WORN_ICONS = {
    "base:linen_shirt": "torso_clothes_longsleeve_longsleeve_male.png",
    "base:work_trousers": "legs_pants_male.png",
    "base:boots": "feet_boots_basic_male.png",
    "base:felt_hat": "hat_formal_bowler_adult_brown.png",
    "base:leather_armor": "torso_armour_leather_male.png",
    "base:iron_helmet": "hat_helmet_nasal_adult.png",
    "base:wool_cloak": "cape_solid_fg.png",
}
WORN_ICON_ROW = {"base:wool_cloak": 0}
# Worn things are dyed in the game (lpc_visuals.json); the icon shows that.
WORN_DYE = {"base:work_trousers": "walnut", "base:boots": "leather", "base:wool_cloak": "gray"}


def build_items():
    pal = json.loads((CHARS / "palettes.json").read_text())["cloth"]
    icons = []
    for item, (path, x, y) in ITEMS.items():
        src = Image.open(path if path.startswith("/") else ITEMS_DIR / path).convert("RGBA")
        icons.append((item, src.crop((x, y, x + T, y + T))))
    for item, (path, x0, y0, x1, y1, colours) in RECOLOURED.items():
        img = Image.open(ITEMS_DIR / path).convert("RGBA").crop((0, 0, T, T))
        px = img.load()
        for yy in range(y0, y1):
            for xx in range(x0, x1):
                c = px[xx, yy]
                if c[3] and c[:3] in colours:
                    px[xx, yy] = colours[c[:3]] + (c[3],)
        icons.append((item, img))
    for item, sheet in WORN_ICONS.items():
        # The south-facing standing frame (idle, row s), cut to what is drawn.
        row = WORN_ICON_ROW.get(item, 2)  # the south frame, or the north for what is on the back
        frame = Image.open(CHARS / sheet).convert("RGBA").crop((0, row * 64, 64, (row + 1) * 64))
        frame = frame.crop(frame.getbbox())
        if item in WORN_DYE:
            ramp = dict(zip([c.lower() for c in pal["ramps"][pal["base"]]], pal["ramps"][WORN_DYE[item]]))
            px = frame.load()
            for yy in range(frame.height):
                for xx in range(frame.width):
                    c = px[xx, yy]
                    hx = "#%02x%02x%02x" % c[:3]
                    if c[3] and hx in ramp:
                        v = ramp[hx]
                        px[xx, yy] = (int(v[1:3], 16), int(v[3:5], 16), int(v[5:7], 16), c[3])
        cell = Image.new("RGBA", (T, T))
        cell.alpha_composite(frame.crop((0, 0, min(T, frame.width), min(T, frame.height))),
                             ((T - min(T, frame.width)) // 2, (T - min(T, frame.height)) // 2))
        icons.append((item, cell))
    for item, layers in HELD_ICONS.items():
        frame = Image.new("RGBA", (64, 64))
        for path in layers:
            frame.alpha_composite(Image.open(ROOT / "art_src" / "lpc" / "spritesheets" / path).convert("RGBA").crop((0, 128, 64, 192)))
        frame = frame.crop(frame.getbbox())
        cell = Image.new("RGBA", (T, T))
        cell.alpha_composite(frame.crop((0, 0, min(T, frame.width), min(T, frame.height))),
                             ((T - min(T, frame.width)) // 2, (T - min(T, frame.height)) // 2))
        icons.append((item, cell))
    atlas = Image.new("RGBA", (len(icons) * T, T))
    defs = []
    for i, (item, img) in enumerate(icons):
        atlas.paste(img, (i * T, 0))
        defs.append({"id": "base:visual/" + item.split(":")[1], "kind": "visual", "for": item, "mode": "item",
                     "atlas": "art/lpc_env/items.png", "rect": [i * T, 0, T, T], "origin": [0, T],
                     "pixel_scale": 0.5, "variants": 1})
    atlas.save(OUT / "items.png", optimize=True)
    return defs


# Crops (ADR-0027): a picture a stage, all on a 32 x 64 cell standing on its
# bottom, so the stages share one origin. (file under lpc-farm tilesets, rect)
CROPS = {
    "base:wheat_crop": [("plants", (32, 32, 32, 32)), ("plants", (32, 96, 32, 32)),
                        ("youngwheat", (0, 0, 32, 64)), ("wheat", (0, 0, 32, 64))],
    "base:carrot_crop": [("plants", (64, 32, 32, 32)), ("plants", (64, 96, 32, 32)),
                         ("plants", (64, 160, 32, 32)), ("plants", (64, 224, 32, 32))],
}


def build_crops():
    rows = list(CROPS.items())
    atlas = Image.new("RGBA", (4 * T, len(rows) * 2 * T))
    defs = []
    for r, (part, stages) in enumerate(rows):
        states = {}
        for i, (sheet, (x, y, w, h)) in enumerate(stages):
            img = Image.open(FARM / (sheet + ".png")).convert("RGBA").crop((x, y, x + w, y + h))
            atlas.paste(img, (i * T, r * 2 * T + 2 * T - h))
            states["stage_%d" % i] = [i * T, r * 2 * T, T, 2 * T]
        defs.append({"id": "base:visual/" + part.split(":")[1], "kind": "visual", "for": part, "mode": "tall",
                     "atlas": "art/lpc_env/crops.png", "rect": states["stage_0"], "origin": [0, 2 * T - 2],
                     "pixel_scale": 0.5, "variants": 1, "states": states})
    atlas.save(OUT / "crops.png", optimize=True)
    return defs


# Fences (ADR-0024: half a storey): a post on the cell's middle, rails to the
# fence cells beside it, from the [LPC] Farming fence block.
FENCES = {"base:wood_fence": "fence"}
GATES = {"base:wood_gate": "fence"}


def build_fences():
    def cut(img, c, r):
        return img.crop((c * T, r * T, c * T + T, r * T + T))
    rows = []
    for part, sheet in list(FENCES.items()) + list(GATES.items()):
        img = Image.open(FARM / (sheet + ".png")).convert("RGBA")
        post, rail, down = cut(img, 0, 1), cut(img, 1, 0), cut(img, 1, 1)
        if part in GATES:
            gate = cut(img, 1, 5)
            rows.append((part, "", [gate] * 16))
            rows.append((part, "open", [post] * 16))
            continue
        variants = []
        for nesw in range(16):
            v = post.copy()
            if nesw & 2:
                v.alpha_composite(rail.crop((T // 2, 0, T, T)), (T // 2, 0))
            if nesw & 8:
                v.alpha_composite(rail.crop((0, 0, T // 2, T)), (0, 0))
            if nesw & 4:
                v.alpha_composite(down)
            variants.append(v)
        rows.append((part, "", variants))
    atlas = Image.new("RGBA", (16 * T, len(rows) * T))
    at = {}
    for r, (part, state, variants) in enumerate(rows):
        for i, img in enumerate(variants):
            atlas.paste(img, (i * T, r * T))
        at[(part, state)] = [0, r * T, T, T]
    atlas.save(OUT / "fences.png", optimize=True)
    defs = []
    for part in list(FENCES) + list(GATES):
        d = {"id": "base:visual/" + part.split(":")[1], "kind": "visual", "for": part, "mode": "tall",
             "atlas": "art/lpc_env/fences.png", "rect": at[(part, "")], "origin": [0, T - 2],
             "pixel_scale": 0.5, "variants": 16, "autotile": "fence"}
        if (part, "open") in at:
            d["states"] = {"open": at[(part, "open")]}
        defs.append(d)
    return defs


ENV_CREDITS_START = "<!-- environment -->"


# Credits of the packs, as they give them, and of single pictures.
PACK_CREDITS = [
    ("[LPC] Terrains", "lpc-terrains/lpc-terrains/CREDITS-terrain.txt"),
    ("[LPC] Walls", "lpc-walls/lpc-walls/CREDITS-walls.txt"),
    ("[LPC] Mountains", "lpc-mountains/submission/CREDITS-mountains.txt"),
    ("[LPC] Windows & Doors", "lpc-windows-doors/lpc-windows-doors-v2/CREDITS-windows-doors.txt"),
    ("[LPC] Floors", "lpc-floors/lpc-floors/CREDITS-floors.txt"),
    ("[LPC] Trees", "lpc-trees/lpc-trees/CREDITS-trees.txt"),
    ("[LPC] Flowers / Plants / Fungi / Wood", "lpc-plants/lpc-flowers-plants-fungi-wood/CREDITS-plants.txt"),
    ("[LPC] Mine (копёр, верёвка)", "lpc-mine/lpc-mine/CREDITS-mine.txt"),
    ("[LPC] Farming tilesets (пашня, посевы, урожай, семена)", "lpc-farm/submission_daneeklu/readme.txt"),
]
FILE_CREDITS = [
    ("Монета — сгенерирована (tools/art/generated/coin)",
     "модели: Stability AI SDXL Base 1.0, nerijs Pixel Art XL, madebyollin SDXL VAE fp16-fix; палитра золота Idylwild's Inventory",
     "CreativeML OpenRAIL++-M / CreativeML OpenRAIL-M (модели)", "https://huggingface.co/nerijs/pixel-art-xl"),
    ("Лестница из пещеры — сгенерирована (tools/art/generated/cave_ladder)",
     "модели: Stability AI SDXL Base 1.0, nerijs Pixel Art XL, madebyollin SDXL VAE fp16-fix; очистка и палитра [LPC] Wooden Stairs",
     "CreativeML OpenRAIL++-M / CreativeML OpenRAIL-M (модели)", "https://huggingface.co/nerijs/pixel-art-xl"),
    ("[LPC] Thatched-roof Cottage (крыша)", "bluecarrot16", "CC-BY-SA 3.0 / GPL 3.0",
     "https://opengameart.org/content/lpc-thatched-roof-cottage"),
    ("[LPC] Wooden Stairs (лестница)", "Nyom", "CC-BY-SA 4.0", "https://opengameart.org/content/lpc-wooden-stairs"),
    ("[LPC] House Insides (факел, верстак)", "Lanea Zimmerman (Sharm), репак", "CC-BY-SA 3.0 / GPL 3.0",
     "https://opengameart.org/content/lpc-house-insides"),
    ("Modified 32x32 Treasure chest (сундук)", "Blarumyrran, правка Gaurav", "CC0",
     "https://opengameart.org/content/modified-32x32-treasure-chest"),
    ("[LPC] Ore and Forge (руда в камне, камень, слитки, печь)", "bluecarrot16", "CC-BY 4.0 / CC-BY 3.0 / GPL 3.0 / OGA-BY 3.0",
     "https://opengameart.org/content/lpc-ore-and-forge"),
    ("Idylwild's Inventory (доски, бревно, мясо, шкура, стрела, кирка, руда)", "Idylwild", "CC0",
     "https://opengameart.org/content/idylwilds-inventory"),
    ("[LPC] Items and game effects (топор, копьё, лук, самоцвет, жареное мясо, пламя костра)", "Lanea Zimmerman (Sharm) и др. (LPC)",
     "CC-BY-SA 3.0 / GPL 2.0 / GPL 3.0", "https://opengameart.org/content/lpc-items-and-game-effects"),
]


def credits():
    """The environment part of CREDITS-art.md (the characters' part stays)."""
    text = CREDITS.read_text(encoding="utf-8") if CREDITS.exists() else ""
    text = text.split(ENV_CREDITS_START)[0].rstrip() + "\n\n"
    lines = [ENV_CREDITS_START, "# Авторы графики окружения", "",
             "Земля, вода, стены, двери, окна, полы, крыши, деревья, растения и вещи — из наборов LPC",
             "на OpenGameArt; собраны в атласы `tools/art/import_lpc_env.py`, рисунок не менялся",
             "(двери удлинены повтором досок посередине). Ниже — авторы каждого набора так, как он их",
             "указывает, и отдельных рисунков. Где лицензий несколько, можно использовать любую.", ""]
    for name, path in PACK_CREDITS:
        lines += ["## " + name, "", "```"]
        lines += (SRC / path).read_text(encoding="utf-8", errors="replace").strip().splitlines()
        lines += ["```", ""]
    for name, who, lic, url in FILE_CREDITS:
        lines += ["## " + name, "", "- Авторы: " + who, "- Лицензии: " + lic, "- " + url, ""]
    # The animals' part (tools/art/import_lpc_animals.py) stays after ours.
    old = CREDITS.read_text(encoding="utf-8") if CREDITS.exists() else ""
    animals = "\n<!-- animals -->" + old.split("<!-- animals -->", 1)[1] if "<!-- animals -->" in old else ""
    CREDITS.write_text(text + "\n".join(lines) + animals, encoding="utf-8")


def main():
    if not all(d.exists() for d in [TERRAIN_DIR, WALLS_DIR, DOORS_DIR, FLOORS_DIR, ROOF, PLANTS_PNG, TREES_DIR, ORE, MINE]):
        sys.exit("no LPC environment sources: run tools/art/fetch_lpc_env.sh")
    defs = build_terrain() + build_buildings() + build_plants() + build_props() + build_items() + build_crops() + build_fences()
    VISUALS.write_text(json.dumps({"format": 1, "defs": defs}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    credits()
    print("%d environment visuals" % len(defs))


if __name__ == "__main__":
    main()
