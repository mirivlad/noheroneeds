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
    "base:forest_floor": ("Dirt_Roots", 2),
    "base:grass_dry": ("Grass_Light", 3),
    "base:moss": ("Grass_Dark", 4),
    "base:grass": ("Grass", 5),
    "base:water": ("Water", 6),
}
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
    fills_max = max(len(tiles[t][15]) for _, (t, _) in rows)
    atlas = Image.new("RGBA", ((15 + fills_max) * T, len(rows) * T))
    defs = []
    for r, (ground, (name, priority)) in enumerate(rows):
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
}
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


def build_buildings():
    walls = Image.open(WALLS_DIR / "walls.png").convert("RGBA")
    doors = Image.open(DOORS_DIR / "windows-doors.png").convert("RGBA")
    rows = []  # (visual id parts, [16 images])
    defs = []
    for part, spec in WALLS.items():
        tiles = ceilings(spec["cap"])
        for state in ["", "open"] if "open" in spec else [""]:
            variants = []
            for nesw in range(16):
                img = Image.new("RGBA", (T, T + STOREY))
                img.alpha_composite(wall_top(tiles, nesw), (0, 0))
                if not nesw & 4:  # the face shows where nothing stands south
                    img.alpha_composite(wall_face(walls, spec["face"][0], spec["face"][1], nesw), (0, T))
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
        d = {"id": "base:visual/" + part.split(":")[1], "kind": "visual", "for": part, "mode": "tall",
             "atlas": "art/lpc_env/walls.png", "rect": at[(part, "")], "origin": [0, T + STOREY],
             "pixel_scale": 0.5, "variants": 16, "autotile": "wall"}
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


ENV_CREDITS_START = "<!-- environment -->"


def credits():
    """The environment part of CREDITS-art.md (the characters' part stays)."""
    text = CREDITS.read_text(encoding="utf-8") if CREDITS.exists() else ""
    text = text.split(ENV_CREDITS_START)[0].rstrip() + "\n\n"
    lines = [ENV_CREDITS_START, "# Авторы графики окружения", "",
             "Земля и вода — из набора [[LPC] Terrains](https://opengameart.org/content/lpc-terrains)",
             "(bluecarrot16 и авторы ниже), собраны в атлас `tools/art/import_lpc_env.py`; рисунок не менялся.",
             "Ниже — список авторов из самого набора (CREDITS-terrain.txt).", ""]
    raw = (TERRAIN_DIR / "CREDITS-terrain.txt").read_text(encoding="utf-8", errors="replace")
    for block in [b.strip() for b in raw.split("\n\n") if b.strip()]:
        head, *rest = block.split("\n")
        lines.append("## " + head.strip())
        lines.append("")
        lines += ["- " + r.strip() for r in rest if r.strip()]
        lines.append("")
    CREDITS.write_text(text + "\n".join(lines), encoding="utf-8")


def main():
    if not all(d.exists() for d in [TERRAIN_DIR, WALLS_DIR, DOORS_DIR, FLOORS_DIR, ROOF]):
        sys.exit("no LPC environment sources: run tools/art/fetch_lpc_env.sh")
    defs = build_terrain() + build_buildings()
    VISUALS.write_text(json.dumps({"format": 1, "defs": defs}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    credits()
    print("%d ground visuals" % len(defs))


if __name__ == "__main__":
    main()
