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
    if not TERRAIN_DIR.is_dir():
        sys.exit("no LPC environment sources: run tools/art/fetch_lpc_env.sh")
    defs = build_terrain()
    VISUALS.write_text(json.dumps({"format": 1, "defs": defs}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    credits()
    print("%d ground visuals" % len(defs))


if __name__ == "__main__":
    main()
