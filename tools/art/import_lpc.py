#!/usr/bin/env python3
"""Humans from the Universal LPC sources (tools/art/fetch_lpc.sh) for the game.

Every LPC layer (a body, a head, a nose, hair, a shirt, a tool's front or
back) becomes one atlas: its animations side by side, each a block of four
rows (n, w, s, e) of square frames, 64 px, or 128 px for the oversize tool
swings. Writes the atlases to content/base/art/lpc/, the palettes the game
recolours by, the visual definitions (content/base/lpc_visuals.json) and the
authors and licences of every used file (CREDITS-art.md).

Usage: tools/art/import_lpc.py
"""
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
LPC = ROOT / "art_src" / "lpc"
SHEETS = LPC / "spritesheets"
OUT = ROOT / "content" / "base" / "art" / "lpc"
VISUALS = ROOT / "content" / "base" / "lpc_visuals.json"
CREDITS = ROOT / "CREDITS-art.md"

FRAME = 64
# Our name -> LPC's. Frames counted from the sources.
ANIMS = {"idle": "idle", "walk": "walk", "run": "run", "slash": "slash", "thrust": "thrust", "shoot": "shoot"}
# Oversize LPC animations (custom_animation in a sheet definition): our name, frame size.
CUSTOM = {"tool_axe": ("chop", 128), "walk_128": ("walk", 128), "tool_rod": ("fish", 128)}
# Animations a layer plays with the columns of another (LPC's custom timelines):
# ours -> (theirs, its column for each frame). The rod's cast is the thrust.
BORROWED = {"fish": ("thrust", [0, 1, 2, 3, 4, 5, 4, 4, 4, 5, 4, 2, 3])}
# How each body plan is built: the LPC body type its layers are fitted to.
PLANS = {
    "base:human_m": "male", "base:human_f": "female",
}
# Where colours come from: "@key" takes the character's colour (nearest LPC
# palette); a plain name is a fixed palette of that material.
SKIN = {"body": "@skin"}
HEAD = {"body": "@skin", "eye": "@eyes"}
HAIR = {"hair": "@hair"}
D = "sheet_definitions/"
BODY = D + "body/body.json"
HEADS = {"male": D + "head/heads/human/heads_human_male.json", "female": D + "head/heads/human/heads_human_female.json",
         "gaunt": D + "head/heads/human/heads_human_male_gaunt.json", "plump": D + "head/heads/human/heads_human_male_plump.json"}
NOSE_BIG = D + "head/nose/head_nose_big.json"
NOSE_STRAIGHT = D + "head/nose/head_nose_straight.json"
BROWS_THICK = D + "head/eyebrows/eyebrows_thick.json"
BROWS_THIN = D + "head/eyebrows/eyebrows_thin.json"


def face(male_head, *extra):
    """A face: a head per sex (heads are fitted to the face, not the body) and features."""
    return lambda body: [(HEADS["female" if body == "female" else male_head], None, HEAD)] + list(extra)


# Styles: id -> body type -> [(sheet definition, variant, recolour)].
STYLES = {
    "face": {
        "base:human_face_soft": face("male"),
        "base:human_face_square": face("plump", (NOSE_BIG, None, SKIN), (BROWS_THICK, None, HAIR)),
        "base:human_face_angular": face("gaunt", (NOSE_STRAIGHT, None, SKIN), (BROWS_THIN, None, HAIR)),
    },
    "hair": {
        "base:human_hair_short": D + "hair/short/hair_messy1.json",
        "base:human_hair_plain": D + "hair/short/hair_plain.json",
        "base:human_hair_long": D + "hair/long/hair_long.json",
        "base:human_hair_braid": D + "hair/braids/hair_braid.json",
        "base:human_hair_ponytail": D + "hair/braids/hair_ponytail.json",
        "base:human_hair_bald": None,
    },
}
# Worn things: item -> (slot, sheet definition, variant, recolour).
WORN = {
    "base:linen_shirt": ("torso", D + "torso/shirts/longsleeve/torso_clothes_longsleeve.json", None, {"cloth": "white"}),
    "base:work_trousers": ("legs", D + "legs/pants/legs_pants.json", None, {"cloth": "walnut"}),
    "base:boots": ("feet", D + "feet/boots/feet_boots_basic.json", None, {"cloth": "leather"}),
    "base:felt_hat": ("headwear", D + "headwear/hats/formal/hat_formal_bowler.json", "brown", {}),
    "base:leather_armor": ("armor", D + "torso/armour/torso_armour_leather.json", None, {}),
    "base:iron_helmet": ("headwear", D + "headwear/helmets/helmets/hat_helmet_nasal.json", None, {}),
    "base:wool_cloak": ("back_item", D + "torso/cape/cape_solid.json", None, {"cloth": "gray"}),
    "base:fur_cloak": ("back_item", D + "torso/cape/cape_solid.json", None, {"cloth": "brown"}),
    "base:fur_hood": ("headwear", D + "headwear/coverings/hoods/hat_hood_cloth.json", None, {"cloth": "brown"}),
}
# Things in the hands, drawn with their own frames: item -> (sheet definition, variant).
HELD = {
    "base:flint_axe": (D + "tools/tool_axe.json", None),
    "base:axe": (D + "tools/tool_axe.json", None),
    "base:iron_axe": (D + "tools/tool_axe.json", None),
    "base:flint_pick": (D + "tools/tool_pickaxe.json", None),
    "base:pickaxe": (D + "tools/tool_pickaxe.json", None),
    "base:iron_pickaxe": (D + "tools/tool_pickaxe.json", None),
    "base:hoe": (D + "tools/tool_hoe.json", None),
    "base:fishing_rod": (D + "tools/tool_rod.json", None),
    "base:spear": (D + "weapons/polearm/weapon_polearm_spear.json", "medium"),
    "base:bow": (D + "weapons/ranged/bow/weapon_ranged_bow_normal.json", "medium"),
}
# How each swing of ADR-0021 is played, and its frames (columns of the LPC
# animation in order). The axe's is LPC's own tool_axe timeline.
BODY_ANIMATIONS = {
    "idle": {"frames": [0, 0, 1, 1], "fps": 3},
    "walk": {"frames": [1, 2, 3, 4, 5, 6, 7, 8], "fps": 11},
    "run": {"frames": [0, 1, 2, 3, 4, 5, 6, 7], "fps": 13},
    "slash": {"frames": [0, 1, 2, 3, 4, 5], "fps": 16},
    "thrust": {"frames": [0, 1, 2, 3, 4, 5, 6, 7], "fps": 18},
    "shoot": {"frames": list(range(13)), "fps": 22},
    "chop": {"frames": [5, 5, 4, 4, 3, 1, 0, 0, 0, 0], "fps": 22},
    "fish": {"frames": list(range(13)), "fps": 18},
}
SWINGS = {"chop": "chop", "thrust": "thrust", "draw": "shoot", "lunge": "slash", "cast": "fish"}
# A thing in the hands without frames for an animation: what the body does instead.
FALLBACK = {"idle": ["walk", 0], "run": ["walk", -1], "slash": ["chop", -1]}

_used = {}  # LPC file -> sheet definition it came from (for the credits)


def load(path):
    with open(LPC / path, encoding="utf-8") as f:
        return json.load(f)


def frames_of(img, size):
    return img.width // size


def anim_file(base, anim, variant):
    """The PNG of one animation of a layer path, or None."""
    for p in ([base + anim + "/" + variant + ".png"] if variant else []) + [base + anim + ".png", base + anim + "/" + anim + ".png"]:
        if (SHEETS / p).is_file():
            return p
    return None


def build_sheet(defn_path, layer_key, body, variant):
    """One LPC layer for a body type as an atlas: (atlas name, anims, z) or None."""
    defn = load(defn_path)
    layer = defn[layer_key]
    base = layer.get(body) or layer.get("male")
    if base is None:
        return None
    blocks = []  # (our anim, image, frame size)
    custom = layer.get("custom_animation")
    if custom:
        name, size = CUSTOM[custom]
        p = base.rstrip("/") + ".png"
        if not (SHEETS / p).is_file():
            p = anim_file(base.rstrip("/") + "/", "", variant) if variant else None
        if p is None or not (SHEETS / p).is_file():
            raise SystemExit("missing %s (%s)" % (base, defn_path))
        blocks.append((name, p, size))
    else:
        for ours, theirs in ANIMS.items():
            if theirs not in defn.get("animations", ANIMS.values()):
                continue
            p = anim_file(base, theirs, variant)
            if p:
                blocks.append((ours, p, FRAME))
    if not blocks:
        return None
    name = base.strip("/").replace("/", "_") + ("_" + variant if variant else "")
    if custom:
        name += "_" + CUSTOM[custom][0]
    images = []
    for ours, p, size in blocks:
        img = Image.open(SHEETS / p).convert("RGBA")
        rows = img.height // size
        if rows != 4:
            continue  # one-row animations (hurt) are not used
        images.append((ours, img, size))
        _used[p] = defn_path
    width = sum(img.width for _, img, _ in images)
    height = max(img.height for _, img, _ in images)
    atlas = Image.new("RGBA", (width, height))
    anims = {}
    x = 0
    for ours, img, size in images:
        atlas.paste(img, (x, 0))
        anims[ours] = [x, 0, size, frames_of(img, size)]
        x += img.width
    # A swing of the whole body (an axe) is the slash on layers without their own.
    if "slash" in anims and "chop" not in anims:
        anims["chop"] = anims["slash"]
    # A layer drawn walking but not running (a cape) runs in its walk.
    if "walk" in anims and "run" not in anims and not custom:
        anims["run"] = anims["walk"]
    for ours, (theirs, columns) in BORROWED.items():
        if theirs in anims and ours not in anims:
            anims[ours] = anims[theirs] + [columns]
    OUT.mkdir(parents=True, exist_ok=True)
    atlas.save(OUT / (name + ".png"), optimize=True)
    return {"atlas": "art/lpc/%s.png" % name, "anims": anims, "z": int(layer.get("zPos", 0))}


def sheets_of(defn_path, body, variant=None, recolor=None):
    """Every layer of a sheet definition (front and back of a braid or a spear)."""
    defn = load(defn_path)
    out = []
    for key in sorted(k for k in defn if k.startswith("layer_")):
        s = build_sheet(defn_path, key, body, variant)
        if s:
            if recolor:
                s["recolor"] = recolor
            out.append(s)
    return out


# Ramps a character's colour may map to (natural skin and hair; fur, green
# skin and dyed hair are other creatures' and later choices).
CHOICES = {
    "body": ["light", "amber", "olive", "taupe", "bronze", "brown", "black"],
    "hair": ["black", "raven", "dark_brown", "chestnut", "light_brown", "dark_gray", "gray", "white", "platinum",
             "ash", "sandy", "blonde", "gold", "strawberry", "ginger", "carrot", "redhead"],
}


def palettes():
    out = {}
    for material in ["body", "hair", "eye", "cloth"]:
        meta = load("palette_definitions/%s/meta_%s.json" % (material, material))
        ramps = load("palette_definitions/%s/%s_ulpc.json" % (material, material))
        out[material] = {"base": meta["base"], "ramps": {k: [c.lower() for c in v] for k, v in ramps.items()},
                         "choices": CHOICES.get(material, sorted(ramps))}
    return out


def credits():
    """Authors and licences of every used file, from the sheet definitions."""
    rows = []
    seen = set()
    for p, defn_path in sorted(_used.items()):
        for c in load(defn_path).get("credits", []):
            f = c["file"].rstrip("/")
            if not p.startswith(f) or (f, defn_path) in seen:
                continue
            seen.add((f, defn_path))
            rows.append(c)
    rows.sort(key=lambda c: c["file"])
    lines = [
        "# Авторы графики персонажей",
        "",
        "Люди, одежда, причёски, инструменты и оружие в руках — из проекта",
        "[Universal LPC Spritesheet Character Generator](https://github.com/LiberatedPixelCup/Universal-LPC-Spritesheet-Character-Generator)",
        "(Liberated Pixel Cup), коммит `%s`. Файлы собраны в атласы игры" % commit(),
        "`tools/art/import_lpc.py`; рисунок не менялся. Ниже — авторы и лицензии",
        "каждого использованного файла (список создаётся тем же скриптом).",
        "Где лицензий несколько, можно использовать любую из них.",
        "",
    ]
    for c in rows:
        lines.append("## %s" % c["file"])
        lines.append("")
        lines.append("- Авторы: %s" % ", ".join(c.get("authors", [])))
        lines.append("- Лицензии: %s" % ", ".join(c.get("licenses", [])))
        if c.get("notes"):
            lines.append("- Примечание: %s" % c["notes"].strip().replace("\n", " "))
        for u in c.get("urls", []):
            lines.append("- %s" % u)
        lines.append("")
    # The environment's part (tools/art/import_lpc_env.py) stays after ours.
    env = ""
    if CREDITS.exists() and "<!-- environment -->" in CREDITS.read_text(encoding="utf-8"):
        env = "\n" + "<!-- environment -->" + CREDITS.read_text(encoding="utf-8").split("<!-- environment -->", 1)[1]
    CREDITS.write_text("\n".join(lines) + env, encoding="utf-8")
    return len(rows)


def commit():
    out = subprocess.run(["git", "-C", str(LPC), "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True)
    return out.stdout.strip() or "?"


def main():
    if not (LPC / "sheet_definitions").is_dir():
        sys.exit("no LPC sources: run tools/art/fetch_lpc.sh")
    for old in OUT.glob("*.png"):
        old.unlink()
    defs = []
    built = {}  # LPC body type -> its visual parts (shared by plans of that body)
    for body in sorted(set(PLANS.values())):
        body_sheet = sheets_of(BODY, body, recolor=SKIN)[0]
        styles = {}
        for slot, choices in STYLES.items():
            for style, spec in choices.items():
                if spec is None:
                    styles[style] = {"layer": slot, "sheets": []}
                    continue
                parts = spec(body) if callable(spec) else [(spec, None, HAIR)]
                sheets = []
                for defn_path, variant, recolor in parts:
                    sheets += sheets_of(defn_path, body, variant, recolor)
                styles[style] = {"layer": slot, "sheets": sheets}
        worn = {item: {"layer": slot, "sheets": sheets_of(p, body, v, rc)} for item, (slot, p, v, rc) in WORN.items()}
        held = {item: {"layer": "main_hand", "sheets": sheets_of(p, body, v)} for item, (p, v) in HELD.items()}
        built[body] = (body_sheet, styles, worn, held)
    for plan, body in PLANS.items():
        body_sheet, styles, worn, held = built[body]
        defs.append({
            "id": "base:visual/" + plan.split(":")[1], "kind": "visual", "for": plan, "mode": "character",
            "format": "lpc", "atlas": body_sheet["atlas"], "anims": body_sheet["anims"], "z": body_sheet["z"],
            "recolor": body_sheet["recolor"], "rect": [0, 0, FRAME, FRAME], "origin": [32, 62], "pixel_scale": 0.5,
            "palettes": "art/lpc/palettes.json", "rows": ["n", "w", "s", "e"],
            "animations": BODY_ANIMATIONS, "swings": SWINGS, "fallback": FALLBACK,
            "style_overrides": styles, "worn_overrides": worn, "held_overrides": held,
        })
    (OUT / "palettes.json").write_text(json.dumps(palettes(), indent=1) + "\n", encoding="utf-8")
    VISUALS.write_text(json.dumps({"format": 1, "defs": defs}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    n = credits()
    print("%d atlases, %d visuals, %d credited sources" % (len(list(OUT.glob("*.png"))), len(defs), n))


if __name__ == "__main__":
    main()
