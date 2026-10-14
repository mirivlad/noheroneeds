#!/usr/bin/env python3
"""Master palette: tools/art/palette.json is the source; this script writes
docs/art/palette.md and docs/art/palette.png from it. Ramps go dark -> light,
shadows cooler, highlights warmer (docs/art/ART_STANDARD.md, section 2)."""
import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "art" / "palette.json"

PALETTE = {
    "nature": {
        "grass": ["2f5d3a", "3f7a3f", "549546", "6fae4f", "93c95e"],
        "grass_dry": ["6e6a2e", "8a8a3a", "a8a048", "c0b45a", "d8cc78"],
        "moss": ["24442c", "2c5a34", "3a6e3c", "4e8444", "68a050"],
        "forest_floor": ["2e2418", "3a3020", "4e3e28", "5e4a30", "70603c"],
        "leaf": ["1f4632", "2c6a3c", "3f8a44", "5ea94b", "8ccb5a"],
        "leaf_light": ["3a6a30", "5a8a3a", "7aaa48", "9ec85a", "c4e07a"],
        "leaf_autumn": ["5a3a1e", "8a4f22", "c06a2a", "e09a3a", "f2c25a"],
        "needles": ["14322a", "1f4632", "2c5a3c", "3f7448", "5a9058"],
        "bark": ["2a1c14", "3a2618", "5a3c26", "7a5434", "9a7048"],
        "birch_bark": ["2a1e26", "8a8478", "c8c0b0", "eae4d6", "fbf7ee"],
        "dirt": ["4e3424", "6b4a32", "8a6242", "a87d52", "c49a68"],
        "sand": ["8a7450", "b8a070", "d0b884", "e2cc98", "f0deb0"],
        "stone": ["3a3840", "4c4a52", "6d6b72", "8f8c92", "b4b0b2"],
        "water": ["1f4a6e", "2a6a94", "3d8cb8", "6cb6d9", "bfe6f2"],
        "snow": ["6a7a9a", "9aaac4", "c4d0e2", "e2eaf4", "fbfdff"],
        "swamp_mud": ["2a2a1c", "3a3a24", "4e4a2e", "62603a", "7a7848"],
        "swamp_water": ["1e3a32", "2a4e40", "3a6450", "568060", "7aa078"],
        "crystal": ["2a1e5a", "4a3a9a", "7a6ad8", "a8a0f0", "e0dcff"],
    },
    "flowers": {
        "red": ["8a2438", "c83a4a", "e8546a", "f28a96"],
        "yellow": ["a8781e", "d8b030", "f2d24a", "fbe88a"],
        "blue": ["2a3a8a", "4a5ac0", "6a8ae8", "a0b8f8"],
        "white": ["a8a4a0", "d8d4cc", "fbf7ee"],
        "purple": ["4a2a6a", "6a4a9a", "8a6ad8", "b8a0f0"],
    },
    "build": {
        "wood": ["3a2416", "4a2e1c", "6e4428", "93613a", "b8834e"],
        "wood_light": ["6e4a2a", "93683e", "b88a52", "d4aa6c", "ecca8e"],
        "roof_red": ["3e1618", "5a2324", "82322c", "a8483a", "c86a4a"],
        "roof_slate": ["22262e", "30364a", "444c62", "5c667a", "7c8696"],
        "thatch": ["5a4420", "7e6230", "a08240", "c0a458", "dcc47a"],
        "metal": ["2a2c34", "4a4e5a", "70768a", "a0a6b4", "d4d8e0"],
        "gold": ["6a4a14", "9a7020", "c89a30", "eac460", "fbe8a0"],
        "glass_warm": ["c8862e", "f2c060", "fde7a0"],
    },
    "skin": {
        "skin_1": ["c98a6a", "eab295", "f8d3bd"],
        "skin_2": ["b07858", "d6a07e", "ecc4a6"],
        "skin_3": ["8a5a3e", "b07858", "d09a78"],
        "skin_4": ["6a4030", "8a5a42", "a87858"],
        "skin_5": ["4a2c22", "6a4030", "8a5a42"],
        "skin_6": ["3a2420", "52342a", "6e4a3a"],
    },
    # Recolour keys (ART_STANDARD 7): parts that the editor recolours are drawn
    # in these exact shades; a shader swaps them for the chosen ramp.
    "keys": {
        "key_skin": ["400010", "800020", "c00030", "ff0040", "ff6080"],
        "key_hair": ["400040", "800080", "b000b0", "e000e0", "ff60ff"],
        "key_eyes": ["004040", "008080", "00c0c0"],
        "key_cloth_main": ["000040", "000080", "0000c0", "0000ff", "6060ff"],
        "key_cloth_accent": ["404000", "808000", "c0c000", "ffff00", "ffff80"],
        "key_leather": ["402000", "804000", "c06000", "ff8000", "ffb060"],
        "key_metal": ["004000", "008000", "00c000", "00ff00", "80ff80"],
    },
    "ink": {"ink": ["1e1824", "2a1e26"], "light": ["fbf7ee"]},
}


def main():
    SRC.write_text(json.dumps(PALETTE, indent=1) + "\n")
    rows = [(g, name, ramp) for g, ramps in PALETTE.items() for name, ramp in ramps.items()]
    sw = 24
    img = Image.new("RGB", (8 * sw + 170, len(rows) * sw), (40, 36, 44))
    d = ImageDraw.Draw(img)
    md = ["# Мастер-палитра\n", "Источник — `tools/art/palette.json` (пересобрать: `tools/art/palette.py`). "
          "Рампы от тёмного к светлому. Группа `keys` — ключевые цвета перекраски, в обычном арте не встречаются.\n",
          "![палитра](palette.png)\n"]
    group = None
    for i, (g, name, ramp) in enumerate(rows):
        if g != group:
            md.append(f"\n## {g}\n\n| Рампа | Цвета |\n|---|---|")
            group = g
        md.append(f"| {name} | " + " ".join(f"`#{c}`" for c in ramp) + " |")
        d.text((4, i * sw + 6), name, fill=(240, 230, 210))
        for k, c in enumerate(ramp):
            d.rectangle((160 + k * sw, i * sw + 2, 160 + k * sw + sw - 3, i * sw + sw - 3), fill="#" + c)
    img.save(ROOT / "docs" / "art" / "palette.png")
    (ROOT / "docs" / "art" / "palette.md").write_text("\n".join(md) + "\n")
    print(len(rows), "ramps")


if __name__ == "__main__":
    main()
