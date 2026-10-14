#!/usr/bin/env python3
"""Probe B3: the B2 scene in three manners, to choose the game's look.

  b2  the current placeholder style (reference)
  v1  "chibi, grown up": muted palette, no outline on the world, a thin
      coloured outline on people, grainy surfaces, ~2.8 heads tall, small eyes
  v2  "like Dust City, lighter": slender ~3.2 heads (14x32 like Dust City),
      dark slate outline on people only, earthy palette, dense grain

Procedural sketches, not game art: they show proportions, tone and texture.
Usage: make_probe_b3.py OUT_DIR FONT_TTF
"""
import colorsys
import math
import random
import sys

from PIL import Image, ImageDraw

import make_probes as mp
import make_probe_b2 as b2
from make_probes import P, hx, lerp, h2

T, VW, VH, OX, OY = b2.T, b2.VW, b2.VH, b2.OX, b2.OY

PROFILES = {
    "b2": dict(sat=1.0, contrast=1.0, warm=0.0, dark=0.0, grain=0.0, people_sat=1.0,
               figure=None, env_outline="colored", people_outline="ink"),
    "v1": dict(sat=0.8, contrast=1.0, warm=0.07, dark=0.02, grain=0.05, people_sat=0.85, green_to=0.27,
               figure=dict(w=18, h=32, head=0.36, head_w=0.72, legs=0.79, eyes=(1, 2), shoulders=0.42, strap=False),
               env_outline=None, people_outline="colored"),
    "v2": dict(sat=0.62, contrast=1.05, warm=0.12, dark=0.05, grain=0.08, people_sat=0.6, green_to=0.2,
               figure=dict(w=16, h=32, head=0.3, head_w=0.62, legs=0.66, eyes=(1, 1), shoulders=0.36, strap=True, leg_gap=0.07),
               dark_clothes=True, env_outline=None, people_outline="slate"),
}
WARM = (200, 160, 112)
SLATE = (36, 39, 43, 255)


def tone(img, prof, people=False):
    """Mutes, warms and flattens the colours of a picture (alpha kept)."""
    sat = prof["people_sat"] if people else prof["sat"]
    if sat == 1.0 and prof["warm"] == 0.0:
        return img
    cache = {}
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            c = px[x, y]
            if c[3] == 0:
                continue
            key = c[:3]
            if key not in cache:
                h, s, v = colorsys.rgb_to_hsv(*(k / 255 for k in key))
                if 0.15 < h < 0.5 and "green_to" in prof:  # greens toward olive
                    h = h + (prof["green_to"] - h) * 0.5
                s *= sat
                v = 0.5 + (v - 0.5) * prof["contrast"] - prof["dark"]
                r, g, b = colorsys.hsv_to_rgb(h, s, max(0.0, min(1.0, v)))
                # Warmth by channel gains, so darks stay dark (no grey haze).
                w = prof["warm"] * (0.6 if people else 1.0)
                gains = (1 + w * 0.9, 1 + w * 0.25, 1 - w * 0.9)
                cache[key] = tuple(max(0, min(255, int(255 * ch * g))) for ch, g in zip((r, g, b), gains))
            px[x, y] = cache[key] + (c[3],)
    return out


def grain(img, prof, seed):
    """Fine per-pixel noise in brightness: the material feel of Dust City."""
    amount = prof["grain"]
    if amount == 0.0:
        return img
    out = img.copy()
    px = out.load()
    rnd = random.Random(seed)
    for y in range(out.height):
        for x in range(out.width):
            c = px[x, y]
            if c[3] == 0 or rnd.random() > 0.45:
                continue
            k = 1.0 + (rnd.random() - 0.5) * 2 * amount
            px[x, y] = tuple(max(0, min(255, int(ch * k))) for ch in c[:3]) + (c[3],)
    return out


def outline(spr, kind):
    if kind == "slate":
        w, h = spr.size
        src = spr.load()
        out = spr.copy()
        dst = out.load()
        for y in range(h):
            for x in range(w):
                if src[x, y][3]:
                    continue
                if any(0 <= x + dx < w and 0 <= y + dy < h and src[x + dx, y + dy][3]
                       for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    dst[x, y] = SLATE
        return out
    return mp.outline(spr, dict(outline=kind, detail=1))


def figure(look, f, outline_kind):
    """A standing person, front view, with the head size as a parameter."""
    w, h = f["w"], f["h"]
    spr = Image.new("RGBA", (w + 2, h + 3), (0, 0, 0, 0))
    px = spr.load()
    skin, hair, cloth, pants = look["skin"], look["hair"], look["cloth"], look["pants"]
    hh = f["head"]
    cy, ry, rx = hh * 0.52, hh * 0.5, f["head_w"] / 2
    legs = f["legs"]
    for y in range(h):
        for x in range(w):
            u, v = (x + 0.5) / w, (y + 0.5) / h
            c = None
            # legs, shoes
            gap = f.get("leg_gap", 0.02)
            if legs <= v < 0.94 and (0.31 < u < 0.5 - gap or 0.5 + gap < u < 0.69):
                c = pants[1] if u < 0.5 else pants[0]
            if v >= 0.94 and (0.27 < u < 0.5 - gap or 0.5 + gap < u < 0.73):
                c = look["shoes"]
            # neck and body
            if hh * 0.96 <= v < hh + 0.04 and abs(u - 0.5) < 0.1:
                c = skin[0]
            top = hh + 0.03
            bw = f.get("shoulders", 0.3) - (v - top) * 0.12 if v < top + 0.12 else f.get("shoulders", 0.3) - 0.03
            if top <= v < legs + 0.03 and abs(u - 0.5) < bw:
                c = cloth[2] if u < 0.5 else cloth[1]
                if v > legs:
                    c = cloth[0]
                if abs(v - (top + (legs - top) * 0.62)) < 0.018:
                    c = look["accent"]
                if look.get("apron") and abs(u - 0.5) < bw * 0.62 and v > top + 0.06:
                    c = P["white"] if u < 0.56 else lerp(P["white"], cloth[0], 0.25)
            # arms along the body
            arm_end = top + (legs - top) * 0.9
            sh = f.get("shoulders", 0.3)
            if top + 0.02 <= v < arm_end and (0.5 - sh - 0.08 < u < 0.5 - sh + 0.05 or 0.5 + sh - 0.05 < u < 0.5 + sh + 0.08):
                c = (cloth[2] if u < 0.5 else cloth[0]) if v < arm_end - 0.05 else skin[1]
            # head
            dh = ((u - 0.5) / rx) ** 2 + ((v - cy) / ry) ** 2
            if dh < 1:
                c = skin[1] if u < 0.62 else skin[0]
            # hair: a cap over the skull, bangs, side locks
            dv = ((u - 0.5) / (rx + 0.06)) ** 2 + ((v - cy + 0.02) / (ry + 0.025)) ** 2
            bang = cy - ry * 0.25 + 0.025 * abs(math.sin(u * math.pi * 3))
            if dv < 1 and (v < bang or ((u < 0.5 - rx * 0.78 or u > 0.5 + rx * 0.78) and v < cy + ry * 0.55)):
                c = hair[2] if u < 0.42 and v < cy - ry * 0.5 else hair[1]
                if dv > 0.75 and (u > 0.6 or v > cy):
                    c = hair[0]
            if look.get("scarf") and dv < 1.03 and v < cy - ry * 0.45:
                c = look["scarf"] if u < 0.6 else lerp(look["scarf"], P["ink"], 0.3)
            # collar and a bag strap across the chest (Dust City's everyday detail)
            if f.get("strap") and top <= v < legs and c in (cloth[1], cloth[2]):
                if abs((u - 0.5) - (v - top - 0.12) * 1.1) < 0.045:
                    c = hx("6a4a30")
            if f.get("strap") and top <= v < top + 0.035 and abs(u - 0.5) < 0.09:
                c = lerp(skin[1], P["white"], 0.4)
            if c:
                px[x + 1, y + 2] = c
    # small eyes
    ew, eh = f["eyes"]
    ey = int(round(h * (cy + ry * 0.12))) + 2
    for ex in (int(round(w * (0.5 - rx * 0.42))), int(round(w * (0.5 + rx * 0.42))) - ew + 1):
        for yy in range(eh):
            for xx in range(ew):
                px[ex + xx, ey + yy] = lerp(look["eyes"], P["ink"], 0.55)
    return outline(spr, outline_kind)


def _look(who, prof):
    """Dust City dresses people in worn, darker everyday clothes."""
    look = dict(mp.LOOKS[who])
    if prof.get("dark_clothes"):
        if who == "player":
            look["cloth"] = [hx("2e3a44"), hx("3e4c58"), hx("52626e")]
            look["pants"] = [hx("3a2a22"), hx("4e3a2e")]
        else:
            look["cloth"] = [hx("4a3a4a"), hx("5e4a5c"), hx("745e70")]
    return look


def render(prof_name):
    prof = PROFILES[prof_name]
    style = dict(outline=prof["env_outline"], detail=1)
    img = Image.new("RGBA", (VW, VH), P["grass"][2])
    b2.ground(img)
    b2.ground_decor(img)
    rnd = random.Random(3)
    sprites = []
    seed = [0]

    def env(spr):
        seed[0] += 1
        return grain(tone(spr, prof), prof, seed[0])

    def place(tx, ty, spr, shadow=None, people=False):
        x, y = int(tx * T - OX - spr.width / 2), int(ty * T - OY - spr.height)
        if shadow:
            mp.shadow(img, x + 1, y + spr.height - shadow[1] // 2 - 1, spr.width - 2, shadow[1])
        sprites.append((ty, spr if people else env(spr), x, y))

    for i, (tx, ty, kind) in enumerate(b2.TREES):
        f = {"spruce": b2.spruce, "birch": b2.birch}.get(kind)
        spr = f(style, i + 3) if f else b2.broadleaf(kind, style, i + 3)
        b2.dappled_shadow(img, tx * T - OX + 6, ty * T - OY - 2, spr.width * 1.15, 18, i)
        place(tx, ty, spr)
    taken = [(tx, ty) for tx, ty, _ in b2.TREES]

    def want(lim):
        return lambda tx, ty: not b2.blocked(tx, ty) and b2.thicket_w(tx, ty) > lim

    for tx, ty in b2.scatter(rnd, 34, want(0.62), 0.9, taken):
        r = rnd.random()
        if r < 0.4:
            place(tx, ty, mp.bush(T, style, int(tx * 7)), (0, 5))
        elif r < 0.6:
            place(tx, ty, b2.berry_bush(style, int(ty * 13)), (0, 5))
        else:
            place(tx, ty, b2.fern(style, int(tx * 3 + ty)), (0, 4))
    for tx, ty in b2.scatter(rnd, 70, want(0.48), 0.55, taken):
        place(tx, ty, b2.tall_grass(style, int(tx * 11 + ty * 5)))
    cx, cy, rx, ry = b2.POND
    for k, a in enumerate((2.6, 2.9, 3.3, 3.7, 4.2, 4.6, 5.0, 0.3)):
        place(cx + math.cos(a) * rx * 0.98, cy + math.sin(a) * ry * 0.98 + 0.3, b2.reeds(style, k))
    for k, (dx, dy) in enumerate(((-1.2, 0.2), (0.8, -0.6), (1.6, 0.6), (-0.2, 0.9))):
        img.alpha_composite(b2.lily(style), (int((cx + dx) * T - OX), int((cy + dy) * T - OY)))
    gx0, gy0, gx1, gy1 = b2.GARDEN
    for row in range(3):
        for k in range(int((gx1 - gx0) * 2) - 1):
            place(gx0 + 0.5 + k * 0.5, gy0 + 0.6 + row * 0.7, b2.crop(style, k + row))
    fs = env(mp.fence(T, 5, style))
    sprites.append((gy1 + 0.55, fs, int(gx0 * T - OX) - 3, int((gy1 - 0.45) * T - OY)))
    place(14.5, 10.9, b2.woodpile(style), (0, 4))
    place(22.6, 11.3, b2.barrel(style), (0, 4))
    hs = env(mp.house(T, style))
    hx0, hy0 = mp.HOUSE[0] * T - OX, mp.HOUSE[1] * T - OY
    mp.shadow(img, hx0 + T // 2, hy0 + hs.height - T // 2, hs.width + T // 2, T)
    sprites.append((mp.HOUSE[1] + mp.HOUSE[3], hs, hx0, hy0))
    for name, (tx, ty) in (("player", mp.PLAYER), ("npc", mp.NPC)):
        if prof["figure"]:
            s = tone(figure(_look(name, prof), prof["figure"], prof["people_outline"]), prof, people=True)
        else:
            s = mp.chibi(20, 32, mp.LOOKS[name], dict(outline=prof["people_outline"], detail=1))
        place(tx, ty, s, (0, 5), people=True)
    ground_img = grain(tone(img, prof), prof, 999)
    img = ground_img
    for _, s, x, y in sorted(sprites, key=lambda e: e[0]):
        img.alpha_composite(s, (int(x), int(y)))
    ntx, nty = mp.NPC
    mp.bubble(img, int(ntx * T - OX), int(nty * T - OY - 34), "Хлеб ещё тёплый!", 1)
    mp.ui_overlay(img, 1)
    return img


def characters_sheet(dc_player=None):
    """People of the three manners at x8, plus Dust City's player for scale."""
    k = 8
    sheet = Image.new("RGBA", (1920, 420), hx("2a2430"))
    d = ImageDraw.Draw(sheet)
    d.fontmode = "1"
    x = 20
    for name, label in (("b2", "B2 сейчас: 20x32"), ("v1", "Вариант 1: 18x32"), ("v2", "Вариант 2: 16x32")):
        prof = PROFILES[name]
        d.text((x, 12), label, font=mp.font(32), fill=P["white"])
        xx = x
        for who in ("player", "npc"):
            if prof["figure"]:
                s = tone(figure(_look(who, prof), prof["figure"], prof["people_outline"]), prof, people=True)
            else:
                s = mp.chibi(20, 32, mp.LOOKS[who], dict(outline="ink", detail=1))
            bg = Image.new("RGBA", s.size, tone(Image.new("RGBA", (1, 1), P["grass"][2]), prof).getpixel((0, 0)))
            bg.alpha_composite(s)
            sheet.paste(bg.resize((s.width * k, s.height * k), Image.NEAREST), (xx, 60))
            xx += s.width * k + 12
        x += 470
    if dc_player:
        d.text((x, 12), "Dust City: 14x32", font=mp.font(32), fill=P["white"])
        f = dc_player.crop((8, 0, 24, 32))
        bg = Image.new("RGBA", f.size, (110, 100, 80, 255))
        bg.alpha_composite(f)
        sheet.paste(bg.resize((f.width * k, f.height * k), Image.NEAREST), (x, 60))
    return sheet


if __name__ == "__main__":
    mp.OUT.mkdir(parents=True, exist_ok=True)
    shots = {}
    for name in ("b2", "v1", "v2"):
        img = render(name)
        shots[name] = img
        img.resize((VW * 4, VH * 4), Image.NEAREST).convert("RGB").save(mp.OUT / f"scene_{name}.png")
        print("scene", name)
    dc = None
    try:
        dc = Image.open(sys.argv[3]).convert("RGBA") if len(sys.argv) > 3 else None
    except OSError:
        pass
    characters_sheet(dc).convert("RGB").save(mp.OUT / "characters.png")
    over = Image.new("RGB", (VW * 3 + 16, VH), (0, 0, 0))
    for i, name in enumerate(("b2", "v1", "v2")):
        over.paste(shots[name].convert("RGB"), (i * (VW + 8), 0))
    over.resize((over.width * 2, over.height * 2), Image.NEAREST).save(mp.OUT / "overview.png")
