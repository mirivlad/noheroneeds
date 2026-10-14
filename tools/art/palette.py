#!/usr/bin/env python3
"""Master palette (ART_STANDARD v2): writes tools/art/palette.json, which the
import tool reads, and docs/art/palette.md + palette.png. The ramps are the
natural base colours of probe B4 after the chosen "middle" toning, with an
extra half-tone between the middle steps. Ramps go dark -> light."""
import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "art" / "palette.json"

# Base ramps (dark -> light), natural colours as drawn for probe B4. The
# master palette is these after the "middle" toning (ADR-0001 revision):
# muted, warm, olive rather than acid, with deeper half-tones.
BASE = {
    "nature": {
        "grass": ["2f5d3a", "3f7a3f", "549546", "6fae4f", "93c95e"],
        "grass_dry": ["6e6a2e", "8a8a3a", "a8a048", "c0b45a", "d8cc78"],
        "moss": ["24442c", "2c5a34", "3a6e3c", "4e8444", "68a050"],
        "forest_floor": ["2e2418", "3a3020", "4e3e28", "5e4a30", "70603c"],
        "leaf_oak": ["23331c", "34482a", "4a6233", "62803c", "86a04c", "a8bc62"],
        "leaf_birch": ["3e5a28", "5a7a34", "7a9a42", "9ab656", "bcd070"],
        "leaf_ochre": ["4a3414", "7a5820", "a8802c", "c8a03c", "e0c060", "f0d88a"],
        "needles": ["16261e", "1e3428", "2a4632", "38583c", "4e7048"],
        "bark": ["2a1c12", "3e2a1a", "5a3e26", "765434"],
        "birch_bark": ["2a2420", "8a847a", "c8c2b4", "e8e2d2"],
        "dirt": ["4e3424", "6b4a32", "8a6242", "a87d52", "c49a68"],
        "sand": ["8a7450", "b8a070", "d0b884", "e2cc98", "f0deb0"],
        "stone": ["3a3a3e", "56565a", "74727a", "96949a", "b6b2b4"],
        "water": ["1f4a6e", "2a6a94", "3d8cb8", "6cb6d9", "bfe6f2"],
        "reeds": ["3a4e24", "4e6e30", "6a8a3c", "5a3a22"],
        "snow": ["6a7a9a", "9aaac4", "c4d0e2", "e2eaf4", "fbfdff"],
        "swamp_mud": ["2a2a1c", "3a3a24", "4e4a2e", "62603a", "7a7848"],
        "swamp_water": ["1e3a32", "2a4e40", "3a6450", "568060", "7aa078"],
        "crystal": ["2a1e5a", "4a3a9a", "7a6ad8", "a8a0f0", "e0dcff"],
    },
    "flowers": {
        "white": ["a8a4a0", "d8d4cc", "ece6d6"],
        "yellow": ["a8781e", "d8b030", "e8c048"],
        "pink": ["8a4a5a", "b86a80", "d890a8"],
        "red": ["7a1e1e", "a83028", "d0503a"],
        "blue": ["2a3a8a", "4a5ac0", "6a8ae8"],
    },
    "build": {
        "log": ["3a2414", "54361e", "6e4a2a", "8a6036", "a67a46"],
        "plank": ["6e4a2a", "93683e", "b88a52", "d4aa6c", "ecca8e"],
        "roof_tile": ["4a1e16", "6e2c1e", "8e3e28", "ac5434", "c06c44"],
        "roof_slate": ["22262e", "30364a", "444c62", "5c667a", "7c8696"],
        "thatch": ["5a4420", "7e6230", "a08240", "c0a458", "dcc47a"],
        "metal": ["2a2c34", "4a4e5a", "70768a", "a0a6b4", "d4d8e0"],
        "gold": ["6a4a14", "9a7020", "c89a30", "eac460", "fbe8a0"],
        "window_light": ["c8862e", "e8c070", "f4d898"],
    },
    "skin": {
        "skin_1": ["c98a6a", "eab295", "f8d3bd"],
        "skin_2": ["b07858", "d6a07e", "ecc4a6"],
        "skin_3": ["8a5a3e", "b07858", "d09a78"],
        "skin_4": ["6a4030", "8a5a42", "a87858"],
        "skin_5": ["4a2c22", "6a4030", "8a5a42"],
        "skin_6": ["3a2420", "52342a", "6e4a3a"],
    },
    "clothes": {
        "linen": ["8a8274", "b4ac9a", "d8d0bc", "ece6d6"],
        "forest_cloth": ["1e3a2a", "2c5038", "3c6646", "52805a"],
        "plum_cloth": ["3a2e46", "4e3e5c", "625070", "7a6688"],
        "earth_cloth": ["4a3826", "624a32", "7a6040", "967a52"],
        "slate_cloth": ["262838", "33354a", "454a60", "5a6078"],
        "leather": ["3a2618", "54361e", "6e4a2a", "8a6036"],
    },
}
# Not toned: exact recolour keys (ART_STANDARD 7) and the people outline.
FIXED = {
    "keys": {
        "key_skin": ["400010", "800020", "c00030", "ff0040", "ff6080"],
        "key_hair": ["400040", "800080", "b000b0", "e000e0", "ff60ff"],
        "key_eyes": ["004040", "008080", "00c0c0"],
        "key_cloth_main": ["000040", "000080", "0000c0", "0000ff", "6060ff"],
        "key_cloth_accent": ["404000", "808000", "c0c000", "ffff00", "ffff80"],
        "key_leather": ["402000", "804000", "c06000", "ff8000", "ffb060"],
        "key_metal": ["004000", "008000", "00c000", "00ff00", "80ff80"],
    },
    "ink": {"people_outline": ["2c201e"], "ui_dark": ["1e1824"], "ui_light": ["fbf7ee"]},
}
# The "middle" palette of probe B4, with deeper half-tones (author, 14.10.2026).
MIDDLE = dict(sat=0.84, warm=0.07, dark=0.025, green_to=0.24, mid_sat=0.12)


def tone(hexc):
    import colorsys
    r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (0, 2, 4))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    if 0.15 < h < 0.5:
        h += (MIDDLE["green_to"] - h) * 0.5
    # Deeper half-tones: more colour in the middle values, not darker.
    s = min(1.0, s * MIDDLE["sat"] * (1 + MIDDLE["mid_sat"] * (1 - abs(v - 0.5) * 2)))
    v = max(0.0, min(1.0, v - MIDDLE["dark"]))
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    w = MIDDLE["warm"]
    gains = (1 + w * 0.9, 1 + w * 0.25, 1 - w * 0.9)
    return "".join("%02x" % max(0, min(255, int(255 * c * k))) for c, k in zip((r, g, b), gains))


def with_halftones(ramp):
    """Adds a step between the middle steps, so shading has more half-tones."""
    if len(ramp) < 4:
        return ramp
    out = []
    for i, c in enumerate(ramp):
        out.append(c)
        if 0 < i < len(ramp) - 2:
            a = [int(c[k:k + 2], 16) for k in (0, 2, 4)]
            b = [int(ramp[i + 1][k:k + 2], 16) for k in (0, 2, 4)]
            out.append("".join("%02x" % ((x + y) // 2) for x, y in zip(a, b)))
    return out


PALETTE = {g: {n: with_halftones([tone(c) for c in r]) for n, r in ramps.items()} for g, ramps in BASE.items()}
PALETTE.update(FIXED)


def main():
    SRC.write_text(json.dumps(PALETTE, indent=1) + "\n")
    rows = [(g, name, ramp) for g, ramps in PALETTE.items() for name, ramp in ramps.items()]
    sw = 24
    img = Image.new("RGB", (11 * sw + 170, len(rows) * sw), (40, 36, 44))
    d = ImageDraw.Draw(img)
    md = ["# Мастер-палитра (версия 2: средняя палитра B4)\n", "Источник — `tools/art/palette.py` → `tools/art/palette.json`. "
          "Рампы от тёмного к светлому: природные базовые цвета B4 после «средней» тонировки, с добавленным полутоном между средними ступенями. "
          "Группа `keys` — ключевые цвета перекраски (в обычном арте не встречаются), `ink` — контур людей и цвета интерфейса.\n",
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
