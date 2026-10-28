#!/usr/bin/env python3
"""Animals and monsters from LPC packs (tools/art/fetch_lpc_env.sh) for the game.

Each source sheet has its own layout (rows in another order, frames of
other sizes, a wolf seen from the side wider than from the front). Every
animation is brought to one: four rows n, w, s, e of square frames, each
frame standing on the cell's bottom middle, the feet on one row for the
whole sheet. LpcSprite plays them like the people.

Writes content/base/art/lpc_animals/*.png, content/base/lpc_animal_visuals.json
and the animals' part of CREDITS-art.md.
Usage: tools/art/import_lpc_animals.py
"""
import colorsys
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "art_src" / "lpc_animals"
OUT = ROOT / "content" / "base" / "art" / "lpc_animals"
VISUALS = ROOT / "content" / "base" / "lpc_animal_visuals.json"
CREDITS = ROOT / "CREDITS-art.md"
A22 = "animals2022/lpc animals 2022 v1.1/individual creature spritesheets/"
DIRS = ["n", "w", "s", "e"]


def grid(path, fw, fh, rows, cols):
    """An animation on a regular grid: rows maps a direction to its row, cols
    lists the columns -> {dir: [(path, rect)]}."""
    return {d: [(path, (c * fw, rows[d] * fh, fw, fh)) for c in cols] for d in DIRS}


def strip(path, places):
    """An animation by hand: dir -> (x, y, w, h, frames) in a row."""
    return {d: [(path, (x + i * w, y, w, h)) for i in range(n)] for d, (x, y, w, h, n) in places.items()}


DEER_ROWS = {"n": 0, "w": 1, "e": 2, "s": 3}
WOLF = "wolfsheet1_0.png"
SPIDER_ROWS = {"n": 0, "w": 1, "s": 2, "e": 3}
SLIME = "monsters/lpc-monsters/slime.png"
FARM = "farm/"
FARM_ROWS = {"n": 0, "w": 1, "s": 2, "e": 3}
# kind -> {anims}, swing animation, fps, frame recolour (hue turn), alternates (other sheets, same layout)
ANIMALS = {
    "base:deer": {
        "anims": lambda p: {"walk": grid(p, 64, 96, DEER_ROWS, range(4)), "idle": grid(p, 64, 96, DEER_ROWS, [0])},
        "sheet": A22 + "deer, light buck.png",
        "alternates": [A22 + "deer, light doe.png", A22 + "deer, dark buck.png", A22 + "deer, dark doe.png"],
        "attack": "walk", "fps": 8,
    },
    "base:hare": {
        "anims": lambda p: {"walk": grid(p, 72, 72, {"n": 0, "w": 1, "s": 2, "e": 3}, range(4)),
                            "idle": grid(p, 72, 72, {"n": 4, "w": 5, "s": 6, "e": 7}, range(4))},
        "sheet": "rabbit_3.png", "attack": "walk", "fps": 10,
    },
    "base:wolf": {
        "anims": lambda p: {
            "walk": strip(p, {"s": (0, 128, 32, 64, 4), "n": (160, 128, 32, 64, 4),
                              "e": (320, 96, 64, 32, 5), "w": (320, 288, 64, 32, 5)}),
            "run": strip(p, {"s": (0, 192, 32, 64, 5), "n": (160, 192, 32, 64, 5),
                             "e": (320, 128, 64, 32, 5), "w": (320, 320, 64, 32, 5)}),
            "attack": strip(p, {"s": (0, 256, 32, 64, 5), "n": (160, 256, 32, 64, 5),
                                "e": (320, 160, 64, 32, 5), "w": (320, 352, 64, 32, 5)}),
            "idle": strip(p, {"s": (0, 128, 32, 64, 1), "n": (160, 128, 32, 64, 1),
                              "e": (320, 96, 64, 32, 1), "w": (320, 288, 64, 32, 1)}),
        },
        "sheet": WOLF, "attack": "attack", "fps": 9,
    },
    "base:cave_rat": {
        "anims": lambda p: {"walk": grid(p, 80, 64, {"s": 0, "w": 1, "e": 2, "n": 3}, range(8)),
                            "idle": grid(p, 80, 64, {"s": 0, "w": 1, "e": 2, "n": 3}, [0]),
                            "attack": grid(p, 80, 64, {"s": 0, "w": 1, "e": 2, "n": 3}, range(8, 11))},
        "sheet": A22 + "giant rat (Sevarihk).png", "attack": "attack", "fps": 10,
    },
    "base:cave_spider": {
        "anims": lambda p: {"walk": grid(p, 64, 64, SPIDER_ROWS, range(4, 10)),
                            "idle": grid(p, 64, 64, SPIDER_ROWS, [0]),
                            "attack": grid(p, 64, 64, SPIDER_ROWS, range(0, 4))},
        "sheet": "spiders/LPC_Spiders/spider01.png",
        "alternates": ["spiders/LPC_Spiders/spider05.png", "spiders/LPC_Spiders/spider09.png"],
        "attack": "attack", "fps": 10,
    },
    # Farm animals (rows n, w, s, e): walking and grazing, the head down.
    "base:sheep": {
        "anims": lambda p: {"walk": grid(p, 128, 128, FARM_ROWS, range(4)), "idle": grid(p, 128, 128, FARM_ROWS, [0]),
                            "attack": grid(FARM + "sheep_eat.png", 128, 128, FARM_ROWS, range(4))},
        "sheet": FARM + "sheep_walk.png", "attack": "attack", "fps": 6,
    },
    "base:cow": {
        "anims": lambda p: {"walk": grid(p, 128, 128, FARM_ROWS, range(4)), "idle": grid(p, 128, 128, FARM_ROWS, [0]),
                            "attack": grid(FARM + "cow_eat.png", 128, 128, FARM_ROWS, range(4))},
        "sheet": FARM + "cow_walk.png", "attack": "attack", "fps": 5,
    },
    "base:chicken": {
        "anims": lambda p: {"walk": grid(p, 32, 32, FARM_ROWS, range(4)), "idle": grid(p, 32, 32, FARM_ROWS, [0]),
                            "attack": grid(FARM + "chicken_eat.png", 32, 32, FARM_ROWS, range(4))},
        "sheet": FARM + "chicken_walk.png", "attack": "attack", "fps": 8,
    },
    # Bears (rows n, e, w, s: the sides the other way round from the deer's),
    # walking and striking with a paw.
    "base:bear": {
        "anims": lambda p: {
            "walk": strip(p, {"n": (0, 0, 64, 64, 4), "e": (0, 64, 64, 64, 5), "w": (0, 128, 64, 64, 5), "s": (0, 192, 64, 64, 4)}),
            "idle": strip(p, {"n": (0, 0, 64, 64, 1), "e": (0, 64, 64, 64, 1), "w": (0, 128, 64, 64, 1), "s": (0, 192, 64, 64, 1)}),
            "attack": strip(p, {"n": (0, 256, 64, 64, 4), "e": (0, 320, 64, 64, 3), "w": (0, 384, 64, 64, 3), "s": (0, 448, 64, 64, 4)}),
        },
        "sheet": A22 + "bear, grizzly.png", "alternates": [A22 + "bear, black.png"], "attack": "attack", "fps": 7,
    },
    "base:polar_bear": {
        "anims": lambda p: {
            "walk": strip(p, {"n": (0, 0, 64, 64, 4), "e": (0, 64, 64, 64, 5), "w": (0, 128, 64, 64, 5), "s": (0, 192, 64, 64, 4)}),
            "idle": strip(p, {"n": (0, 0, 64, 64, 1), "e": (0, 64, 64, 64, 1), "w": (0, 128, 64, 64, 1), "s": (0, 192, 64, 64, 1)}),
            "attack": strip(p, {"n": (0, 256, 64, 64, 4), "e": (0, 320, 64, 64, 3), "w": (0, 384, 64, 64, 3), "s": (0, 448, 64, 64, 4)}),
        },
        "sheet": A22 + "bear, polar.png", "attack": "attack", "fps": 7,
    },
    # Foxes (rows s, e, w, n: read as s, w, e, n they walked backwards): no strike
    # of their own, a lunge of the walk.
    "base:fox": {
        "anims": lambda p: {"walk": grid(p, 64, 64, {"s": 0, "e": 1, "w": 2, "n": 3}, range(4)),
                            "idle": grid(p, 64, 64, {"s": 0, "e": 1, "w": 2, "n": 3}, [0])},
        "sheet": A22 + "fox, woods.png", "attack": "walk", "fps": 10,
    },
    "base:arctic_fox": {
        "anims": lambda p: {"walk": grid(p, 64, 64, {"s": 0, "e": 1, "w": 2, "n": 3}, range(4)),
                            "idle": grid(p, 64, 64, {"s": 0, "e": 1, "w": 2, "n": 3}, [0])},
        "sheet": A22 + "fox, arctic.png", "attack": "walk", "fps": 10,
    },
    # A mushroom that walks (rows s, e, w, n).
    "base:mushroom_walker": {
        "anims": lambda p: {"walk": grid(p, 32, 32, {"s": 0, "e": 1, "w": 2, "n": 3}, range(4)),
                            "idle": grid(p, 32, 32, {"s": 0, "e": 1, "w": 2, "n": 3}, [0])},
        "sheet": A22 + "mushroom walker (Sevarihk).png", "alternates": [A22 + "mushroom walker, fly amanita (Sevarihk).png"],
        "attack": "walk", "fps": 8,
    },
    # Slimes look the same every way: their hop and their spit in every row.
    "base:poporing": {
        "anims": lambda p: {"walk": {d: [(p, (i * 64, 0, 64, 64)) for i in range(6)] for d in DIRS},
                            "idle": {d: [(p, (0, 0, 64, 64))] for d in DIRS},
                            "attack": {d: [(p, (i * 64, 64, 64, 64)) for i in range(8)] for d in DIRS}},
        "sheet": SLIME, "attack": "attack", "fps": 8,
    },
    "base:poring": {
        "anims": lambda p: {"walk": {d: [(p, (i * 64, 0, 64, 64)) for i in range(6)] for d in DIRS},
                            "idle": {d: [(p, (0, 0, 64, 64))] for d in DIRS},
                            "attack": {d: [(p, (i * 64, 64, 64, 64)) for i in range(8)] for d in DIRS}},
        "sheet": SLIME, "attack": "attack", "fps": 8, "hue": (0.52, 0.8, 1.35),  # green to pink
    },
}
CREDITS_ANIMALS = [
    ("[LPC] bears, deer, lions and more (олень, медведи, лиса, песец)", "tapatilorenzo", "CC-BY 4.0",
     "https://opengameart.org/content/lpc-bears-deer-lions-and-more"),
    ("Giant rat, mushroom walker (пещерная крыса, грибовик), из того же набора", "Sevarihk", "CC-BY 4.0",
     "https://opengameart.org/content/lpc-bears-deer-lions-and-more"),
    ("[LPC] Wolf Animation (волк)", "Redshrike, заказ William.Thompsonj", "CC-BY 3.0 / CC-BY 4.0 / GPL 2.0 / GPL 3.0 / OGA-BY 3.0",
     "https://opengameart.org/content/lpc-wolf-animation"),
    ("Reorganised LPC rabbit (заяц)", "Redshrike; перекладка Evert", "CC-BY 3.0 / CC-BY-SA 3.0 / OGA-BY 3.0",
     "https://opengameart.org/content/reorganised-lpc-rabbit"),
    ("[LPC] Spider (пещерный паук)", "Redshrike, заказ William.Thompsonj", "CC-BY 3.0 / CC-BY 4.0 / GPL 2.0 / GPL 3.0 / OGA-BY 3.0",
     "https://opengameart.org/content/lpc-spider"),
    ("LPC Style Farm Animals (овца, корова, курица)", "Daniel Eddeland (daneeklu)", "CC-BY 3.0 / GPL 2.0",
     "https://opengameart.org/content/lpc-style-farm-animals"),
    ("[LPC] Monsters (слизни: поринг перекрашен, попоринг)", "Charles Sanchez (CharlesGabriel), bluecarrot16; заказ Pierre Vigier",
     "CC-BY-SA 3.0 / GPL 3.0", "https://opengameart.org/content/lpc-monsters"),
]
ANIMAL_CREDITS_START = "<!-- animals -->"


def turn_hue(img, how):
    """Each pixel's hue turned, its saturation and value scaled (a
    recolouring, not a new drawing): how = (turn, saturation, value)."""
    by, sat, val = how
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            if a:
                h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
                r2, g2, b2 = colorsys.hsv_to_rgb((h + by) % 1.0, min(1.0, s * sat), min(1.0, v * val))
                px[x, y] = (round(r2 * 255), round(g2 * 255), round(b2 * 255), a)
    return out


def build(kind, spec, sheet):
    anims = spec["anims"](sheet)
    sources = {}

    def frame(path, rect):
        if path not in sources:
            img = Image.open(SRC / path).convert("RGBA")
            sources[path] = turn_hue(img, spec["hue"]) if "hue" in spec else img
        x, y, w, h = rect
        return sources[path].crop((x, y, x + w, y + h))
    size = max(max(r[2], r[3]) for a in anims.values() for d in a.values() for _, r in d)
    # Each animation: as many frames as its longest row; shorter rows go round.
    names = [n for n in ["idle", "walk", "run", "attack"] if n in anims]
    count = {n: max(len(anims[n][d]) for d in DIRS) for n in names}
    atlas = Image.new("RGBA", (sum(count.values()) * size, 4 * size))
    out = {}
    x0 = 0
    feet = 0
    for n in names:
        for r, d in enumerate(DIRS):
            frames = anims[n][d]
            for i in range(count[n]):
                path, rect = frames[i % len(frames)]
                img = frame(path, rect)
                at = (x0 + i * size + (size - img.width) // 2, r * size + size - img.height)
                atlas.alpha_composite(img, at)
                box = img.getbbox()
                if box and n in ("walk", "idle"):
                    feet = max(feet, size - img.height + box[3] - 1)
        out[n] = [x0, 0, size, count[n]]
        x0 += count[n] * size
    # Every row of an animation stands on the cell's bottom (the author,
    # 28.10.2026: a fox walking sideways and the hare hung in the air — their
    # sources draw some rows higher than others): a row is moved down as a
    # whole, so its frames keep their steps.
    for n in names:
        x, _, _, c = out[n]
        for r in range(4):
            strip = atlas.crop((x, r * size, x + c * size, (r + 1) * size))
            box = strip.getchannel("A").point(lambda a: 255 if a > 40 else 0).getbbox()
            if box and box[3] < size:
                moved = Image.new("RGBA", strip.size)
                moved.alpha_composite(strip, (0, size - box[3]))
                atlas.paste(moved, (x, r * size))
    feet = size - 1
    return atlas, out, size, feet


def main():
    if not (SRC / "wolfsheet1_0.png").exists():
        sys.exit("no LPC animal sources: run tools/art/fetch_lpc_env.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    defs = []
    for kind, spec in ANIMALS.items():
        name = kind.split(":")[1]
        atlas, anims, size, feet = build(kind, spec, spec["sheet"])
        atlas.save(OUT / (name + ".png"), optimize=True)
        alts = []
        for i, alt in enumerate(spec.get("alternates", [])):
            a, _, _, _ = build(kind, spec, alt)
            a.save(OUT / ("%s_%d.png" % (name, i + 1)), optimize=True)
            alts.append({"atlas": "art/lpc_animals/%s_%d.png" % (name, i + 1), "rect": [0, 0, size, size], "origin": [size // 2, feet]})
        fps = spec["fps"]
        animations = {n: {"frames": list(range(anims[n][3])), "fps": fps if n != "run" else fps + 3} for n in anims}
        animations["idle"]["fps"] = 3
        if "attack" in anims:
            animations["attack"]["fps"] = fps + 4
        defs.append({
            "id": "base:visual/" + name, "kind": "visual", "for": kind, "mode": "character", "format": "lpc",
            "atlas": "art/lpc_animals/%s.png" % name, "anims": anims, "z": 10,
            "rect": [0, 0, size, size], "origin": [size // 2, feet], "pixel_scale": 0.5,
            "rows": DIRS, "animations": animations, "swings": {"lunge": spec["attack"]},
            "variants": 1, "alternates": alts,
        })
    VISUALS.write_text(json.dumps({"format": 1, "defs": defs}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    text = CREDITS.read_text(encoding="utf-8") if CREDITS.exists() else ""
    text = text.split(ANIMAL_CREDITS_START)[0].rstrip() + "\n\n"
    lines = [ANIMAL_CREDITS_START, "# Авторы графики зверей", "",
             "Звери и чудища — из наборов LPC на OpenGameArt, собраны в листы игры",
             "`tools/art/import_lpc_animals.py` (кадры переложены, рисунок не менялся; поринг — перекрашенный слизень).", ""]
    for name, who, lic, url in CREDITS_ANIMALS:
        lines += ["## " + name, "", "- Авторы: " + who, "- Лицензии: " + lic, "- " + url, ""]
    CREDITS.write_text(text + "\n".join(lines), encoding="utf-8")
    print("%d animal visuals" % len(defs))


if __name__ == "__main__":
    main()
