#!/usr/bin/env python3
"""Synthesised sounds of the base pack (deterministic: the same code gives the
same samples), in the manner of Dust City's tools/audio/build.py.

    python3 tools/audio/build.py  -> content/base/audio/*.wav, content/base/sounds.json

Mono 16-bit WAV, 22050 Hz. Recipes are physical-ish rather than musical:
filtered noise, decaying partials, envelopes, a cheap room. Footsteps are
soft (Dust City's author found sharp ones tiring): the heel's thud more than
its click, the top cut off. Ambience loops are crossfaded at the seam.

sounds.json ties them to content (ADR-0009: presentation, not rules):
{"kind": "sound", "for": <content id or "*">, "event": step | build |
dismantle | open | close | pickup | drop | climb | click | ambience | wind,
"files": [...], "volume_db", "pitch": [lo, hi], "loop"}.
"""
import json
import os
import wave

import numpy as np
from scipy import signal

SR = 22050
ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
PACK = os.path.join(ROOT, "content", "base")
OUT = os.path.join(PACK, "audio")


# ------------------------------------------------------------------ kit

def rng(seed):
    return np.random.default_rng(seed)


def t_axis(sec):
    return np.arange(int(sec * SR)) / SR


def noise(sec, seed):
    return rng(seed).uniform(-1, 1, int(sec * SR))


def band(x, lo, hi, order=2):
    b, a = signal.butter(order, [lo / (SR / 2), min(hi / (SR / 2), 0.99)], "band")
    return signal.lfilter(b, a, x)


def low(x, f, order=2):
    b, a = signal.butter(order, f / (SR / 2), "low")
    return signal.lfilter(b, a, x)


def high(x, f, order=2):
    b, a = signal.butter(order, f / (SR / 2), "high")
    return signal.lfilter(b, a, x)


def decay(sec, tau, attack=0.002):
    t = t_axis(sec)
    return np.minimum(t / attack, 1.0) * np.exp(-t / tau)


def norm(x, peak=0.9):
    m = np.max(np.abs(x)) or 1.0
    return x / m * peak


def place(buf, clip, at_sec, gain=1.0):
    i = int(at_sec * SR)
    n = min(len(clip), len(buf) - i)
    if n > 0:
        buf[i:i + n] += clip[:n] * gain


def reverb(x, size=0.25, mix=0.25, seed=1):
    """Cheap room: convolution with exponentially decaying noise."""
    ir = noise(size, seed) * np.exp(-t_axis(size) / (size / 4))
    ir[0] = 1.0
    wet = signal.fftconvolve(x, ir)[: len(x)]
    return (1 - mix) * x + mix * norm(wet, np.max(np.abs(x)) + 1e-9)


def slow_env(sec, rate_hz, seed, lo=0.3, hi=1.0):
    """Smooth random envelope (gusts, swells)."""
    n = int(sec * rate_hz) + 3
    pts = rng(seed).uniform(lo, hi, n)
    x = np.linspace(0, n - 1, int(sec * SR))
    return np.interp(x, np.arange(n), pts)


def loopify(x, fade=1.0):
    """Crossfade the tail into the head: the clip loops seamlessly."""
    n = int(fade * SR)
    head, tail = x[:n], x[-n:]
    w = np.linspace(0, 1, n)
    out = x[:-n].copy()
    out[:n] = head * w + tail * (1 - w)
    return out


def write(name, x, peak=0.9, gain=None):
    """peak: normalise to it; gain: a fixed gain instead (ambience keeps the
    level the author heard, so one part can be made quieter alone)."""
    x = np.clip(x * gain if gain is not None else norm(x, peak), -1, 1)
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32000).astype("<i2").tobytes())
    return "audio/%s.wav" % name


# ------------------------------------------------------------ elements

def knock(f0, sec, seed, tau=0.05):
    """Wood struck: a few inharmonic partials of a board, quickly damped."""
    t = t_axis(sec)
    r = rng(seed)
    x = np.zeros_like(t)
    for k, mult in enumerate((1.0, 2.31, 3.9, 5.4)):
        f = f0 * mult * r.uniform(0.97, 1.03)
        x += np.sin(2 * np.pi * f * t) * np.exp(-t / (tau / (1 + k * 0.8))) / (1 + k)
    x += 0.5 * band(noise(sec, seed), 300, 2500) * decay(sec, 0.006)
    return x


def chirp(seed):
    """A small bird's call: a quick whistle bending up or down."""
    r = rng(seed)
    dur = r.uniform(0.06, 0.14)
    t = t_axis(dur)
    f0 = r.uniform(3200, 5000)
    f = f0 + 1100 * np.sin(np.pi * t / dur) * r.choice([-1, 1]) + 250 * np.sin(2 * np.pi * 60 * t)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.sin(np.pi * t / dur) ** 2


def song(seed):
    """A short song: three to six notes of one bird."""
    r = rng(seed)
    x = np.zeros(int(1.2 * SR))
    at = 0.0
    base = r.uniform(2600, 4200)
    for k in range(r.integers(3, 7)):
        dur = r.uniform(0.05, 0.12)
        t = t_axis(dur)
        f = base * r.uniform(0.85, 1.25) + 600 * t / dur * r.choice([-1, 1])
        note = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.sin(np.pi * t / dur) ** 1.5
        place(x, note, at, r.uniform(0.6, 1.0))
        at += dur + r.uniform(0.03, 0.09)
    return x


def cricket(sec, seed, f=4300):
    """A grasshopper's chirping: trains of short buzzes."""
    r = rng(seed)
    x = np.zeros(int(sec * SR))
    t = t_axis(0.025)
    pulse = np.sin(2 * np.pi * f * t) * np.sin(np.pi * t / 0.025) ** 2
    at = r.uniform(0, 1.5)
    while at < sec - 1:
        for k in range(r.integers(3, 8)):
            place(x, pulse, at + k * 0.045, 1.0)
        at += r.uniform(0.6, 2.4)
    return x


# ------------------------------------------------------------ sounds

def thud(sec, seed, top=420, tau=0.012):
    """The heel: noise under a gentle (first-order) low-pass, a few
    milliseconds long. No narrow band: a narrow band rings at its pitch and
    the step sounds hollow, like a drum or an empty tank."""
    x = low(high(noise(sec, seed), 50, 1), top, 2)
    return x * decay(sec, tau, 0.003)


def tail_out(x, keep=0.45):
    """Fades the clip to silence after `keep` of it: nothing rings on."""
    n = len(x)
    k = int(n * keep)
    w = np.ones(n)
    w[k:] = np.cos(np.linspace(0, np.pi / 2, n - k)) ** 2
    return x * w


def step(surface, seed):
    """A soft, dull footstep on a surface: a short heel and the surface's own
    texture, most of it in the first 40 ms, then silence."""
    r = rng(seed)
    sec = 0.14
    if surface == "grass":       # blades brushing, a soft heel
        x = thud(sec, seed + 1, 380, 0.010)
        x += high(low(noise(sec, seed), 4000, 1), 1200, 1) * decay(sec, 0.028, 0.010) * 0.35
    elif surface == "leaves":    # dry litter crackling under the foot
        x = thud(sec, seed + 1, 380, 0.010)
        for k in range(r.integers(5, 10)):
            place(x, band(noise(0.006, seed + 10 + k), 1800, 4500, 1) * decay(0.006, 0.0012),
                  r.uniform(0.0, 0.06), r.uniform(0.15, 0.35))
    elif surface == "moss":      # almost nothing: a muffled press
        x = thud(sec, seed, 260, 0.016)
    elif surface == "sand":      # a soft crunch
        sec = 0.18
        x = thud(sec, seed + 1, 360, 0.010) * 0.8
        x += high(low(noise(sec, seed), 4500, 1), 1300, 1) * decay(sec, 0.045, 0.015) * 0.3
    elif surface == "wood":      # a board: firmer, damped at once
        x = thud(sec, seed, 550, 0.009)
        x += 0.08 * knock(r.uniform(220, 260), sec, seed + 2, 0.010)
    else:                        # earth: a dull thud with a little grit
        x = thud(sec, seed, 400, 0.012)
        x += high(low(noise(sec, seed + 1), 3000, 1), 1200, 1) * decay(sec, 0.012, 0.004) * 0.1
    bright = surface in ("grass", "leaves", "sand")  # their rustle is the point
    return tail_out(low(x, 3200 if bright else 1600, 2))


def swing(seed=2100):
    """A blow through the air: a short whoosh, rising then falling."""
    sec = 0.22
    t = t_axis(sec)
    x = noise(sec, seed)
    env = np.sin(np.pi * np.clip(t / sec, 0, 1)) ** 2
    lo = low(x, 900, 2) * env
    hi = high(low(x, 2600, 1), 500, 1) * env * 0.5
    return tail_out(lo + hi, 0.6)


def hit(seed=2200):
    """A blow landing on a body: a dull thump and a short slap, no ring."""
    sec = 0.16
    x = thud(sec, seed, 300, 0.018)
    x += high(low(noise(sec, seed + 1), 2500, 1), 600, 1) * decay(sec, 0.008, 0.001) * 0.6
    return tail_out(low(x, 2000, 2), 0.5)


def shoot(seed=2300):
    """A bowstring let go: a low plucked thrum, damped fast, and a swish."""
    sec = 0.3
    t = t_axis(sec)
    r = rng(seed)
    f = r.uniform(105, 120)
    x = (np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * 2.02 * f * t)) * decay(sec, 0.05, 0.002)
    x += high(low(noise(sec, seed), 3000, 1), 800, 1) * decay(sec, 0.04, 0.01) * 0.35
    return tail_out(low(x, 2500, 2), 0.5)


def build_wood():
    """Something set up in wood: two hammer knocks and a settling rattle."""
    x = np.zeros(int(0.7 * SR))
    place(x, knock(210, 0.25, 1, 0.06), 0.0, 1.0)
    place(x, knock(230, 0.25, 2, 0.06), 0.17, 0.8)
    place(x, band(noise(0.3, 3), 300, 1800) * decay(0.3, 0.05, 0.01), 0.3, 0.25)
    return reverb(x, 0.2, 0.2, 4)


def build_stone():
    """A stone set down: a heavy thud and grit scraping."""
    x = np.zeros(int(0.8 * SR))
    place(x, low(noise(0.4, 10), 160, 4) * decay(0.4, 0.08, 0.004) * 3, 0.0, 1.0)
    place(x, band(noise(0.35, 11), 1200, 4500) * decay(0.35, 0.09, 0.03), 0.05, 0.25)
    for k in range(6):
        place(x, band(noise(0.01, 12 + k), 2500, 7000) * decay(0.01, 0.002), 0.08 + k * 0.05, 0.2)
    return reverb(x, 0.25, 0.2, 13)


def creak(sec, seed, f0=180, f1=320):
    t = t_axis(sec)
    f = f0 + (f1 - f0) * t / sec + 15 * np.sin(2 * np.pi * 7 * t)
    saw = signal.sawtooth(2 * np.pi * np.cumsum(f) / SR)
    return band(saw, 300, 2200) * np.sin(np.pi * t / sec) ** 0.7 * slow_env(sec, 30, seed, 0.4, 1.0)


def dismantle_wood():
    """Taken apart: a creak, a crack, boards knocking."""
    x = np.zeros(int(0.8 * SR))
    place(x, creak(0.3, 20), 0.0, 0.25)
    place(x, band(noise(0.04, 21), 800, 5000) * decay(0.04, 0.008), 0.28, 0.9)
    place(x, knock(170, 0.2, 22, 0.04), 0.4, 0.7)
    place(x, knock(200, 0.2, 23, 0.04), 0.52, 0.45)
    return reverb(x, 0.2, 0.2, 24)


def dismantle_stone():
    x = np.zeros(int(0.9 * SR))
    place(x, low(noise(0.5, 30), 200, 3) * decay(0.5, 0.12, 0.02) * 2, 0.0, 0.8)
    r = rng(31)
    for k in range(9):
        place(x, band(noise(0.02, 32 + k), 1500, 5000) * decay(0.02, 0.004), 0.1 + r.uniform(0, 0.6), r.uniform(0.2, 0.5))
    return reverb(x, 0.25, 0.2, 33)


def door(opening):
    """A wooden door: a creak and the latch (opening), a thud and the latch (closing)."""
    x = np.zeros(int(0.7 * SR))
    latch = band(noise(0.04, 40), 1800, 6000) * decay(0.04, 0.005)
    if opening:
        place(x, latch, 0.0, 0.5)
        place(x, creak(0.45, 41, 160, 280), 0.05, 0.2)
    else:
        place(x, creak(0.25, 42, 260, 180), 0.0, 0.12)
        place(x, band(noise(0.3, 43), 70, 400) * decay(0.3, 0.06, 0.004), 0.22, 1.0)
        place(x, latch, 0.24, 0.5)
    return reverb(x, 0.25, 0.25, 44)


def pickup():
    """A thing lifted: a brush of fabric and a small knock."""
    x = band(noise(0.18, 50), 800, 4000) * decay(0.18, 0.04, 0.02) * 0.6
    place(x, knock(320, 0.1, 51, 0.02), 0.03, 0.4)
    return x


def drop():
    """A thing put down on the ground: a soft thump."""
    x = band(noise(0.25, 60), 70, 400) * decay(0.25, 0.04, 0.004)
    place(x, knock(260, 0.12, 61, 0.025), 0.0, 0.35)
    return x


def climb():
    """Up or down wooden stairs: a few quick steps on boards and a creak."""
    x = np.zeros(int(0.9 * SR))
    for k in range(4):
        place(x, step("wood", 70 + k), k * 0.17, 1.0 - k * 0.1)
    place(x, creak(0.3, 75, 200, 260), 0.3, 0.12)
    return reverb(x, 0.2, 0.25, 76)


def click():
    """The interface: a small wooden tick."""
    return knock(900, 0.06, 80, 0.012) * 0.7


def at_rms(x, level):
    return x * (level / (np.sqrt(np.mean(x ** 2)) or 1.0))


def soft_wind(sec, seed, lo=80, hi=600, top=450):
    """Wind, soft: dark (the top cut off) and steady, swelling only a little,
    slowly - the first, deep and wide-band swells sounded like surf."""
    x = low(band(noise(sec, seed), lo, hi), top, 2)
    return x * slow_env(sec, 0.06, seed + 1, 0.65, 1.0)


# Ambience levels: the gain each loop had when the author first heard it.
AMB_GAIN = {"amb_meadow": 2.67, "amb_forest": 1.92}
# The author: the wind 15% quieter than it first was, then again a little
# quieter, and not always there (rms of the first wind, times 0.85 twice).
WIND_LEVEL = {"meadow": 0.0399 * 0.72, "forest_crowns": 0.0545 * 0.72, "forest_low": 0.028 * 0.72}


def gust(kind, seed):
    """A gust of wind, 5-10 s: it rises softly, holds, dies away. The game
    plays gusts now and then, with at least 15 s of calm between them."""
    r = rng(seed)
    sec = r.uniform(5.0, 10.0)
    t = t_axis(sec)
    rise, fall = r.uniform(1.5, 3.0), r.uniform(2.0, 4.0)
    env = np.minimum(1.0, np.minimum(t / rise, (sec - t) / fall))
    env = np.sin(np.clip(env, 0, 1) * np.pi / 2) ** 2
    if kind == "meadow":
        x = at_rms(soft_wind(sec, seed), WIND_LEVEL["meadow"])
    else:
        x = at_rms(soft_wind(sec, seed, 300, 1500, 1100), WIND_LEVEL["forest_crowns"])
        x += at_rms(soft_wind(sec, seed + 7, 40, 220, 200), WIND_LEVEL["forest_low"])
    return x * env


def amb_meadow():
    """A meadow in the day: grasshoppers, a whisper of grass, now and then
    birds. The wind comes in gusts of its own (gust())."""
    sec = 24.0
    grass = band(noise(sec, 102), 2000, 6000) * 0.02 * slow_env(sec, 0.3, 103, 0.2, 1.0)
    x = grass + 0.08 * cricket(sec, 104, 4300) + 0.05 * cricket(sec, 105, 5200)
    r = rng(106)
    for k, at in enumerate(np.sort(r.uniform(1.0, sec - 2.0, 6))):
        place(x, chirp(110 + k), at, r.uniform(0.12, 0.25))
    place(x, song(120), 8.0, 0.2)
    place(x, song(121), 17.5, 0.16)
    return loopify(reverb(x, 0.3, 0.15, 107), 1.5)


def amb_forest():
    """In a forest: still air with a faint stir of leaves, many birds, a
    woodpecker far off. Wind in the crowns comes in gusts (gust())."""
    sec = 28.0
    x = at_rms(soft_wind(sec, 202, 40, 220, 200), WIND_LEVEL["forest_low"] * 0.3)
    r = rng(204)
    for k, at in enumerate(np.sort(r.uniform(0.5, sec - 2.0, 7))):
        place(x, song(210 + k), at, r.uniform(0.12, 0.3))
    for k, at in enumerate(np.sort(r.uniform(0.5, sec - 1.0, 10))):
        place(x, chirp(230 + k), at, r.uniform(0.08, 0.18))
    for at in (6.0, 19.0):        # a woodpecker: a quick roll of knocks
        for k in range(14):
            place(x, knock(900, 0.03, 250 + k, 0.006), at + k * 0.045, 0.12 * (1 - k / 20))
    return loopify(reverb(x, 0.6, 0.3, 205), 2.0)


def bubbles(sec, seed, count, f_lo=250, f_hi=700):
    """Water's own voice: small air pockets bursting as water folds over -
    short low tones that rise as they close (a gurgle, not a drip)."""
    r = rng(seed)
    x = np.zeros(int(sec * SR))
    for k in range(count):
        dur = r.uniform(0.02, 0.06)
        t = t_axis(dur)
        f = r.uniform(f_lo, f_hi) * (1 + 0.8 * t / dur)
        b = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (dur / 3)) * np.minimum(t / 0.003, 1)
        place(x, b, r.uniform(0, sec * 0.6), r.uniform(0.3, 1.0))
    return x


def amb_water():
    """By the water: only its gurgle - small air pockets bursting where the
    water folds at the bank, in bunches of different size with pauses of
    1-7 s between them, at random (the author: no wash of waves, no noise).
    A long loop, so the pauses do not repeat in a noticeable round."""
    sec = 45.0
    x = np.zeros(int(sec * SR))
    r = rng(302)
    at = r.uniform(0.3, 1.5)
    k = 0
    while at < sec - 2.0:
        size = r.uniform(0.4, 1.6)                      # how long the bunch lasts
        count = int(r.integers(4, 18))
        place(x, bubbles(size, 310 + k, count), at, r.uniform(0.5, 1.0))
        at += size + r.uniform(1.0, 7.0)
        k += 1
    x = loopify(low(x, 2500, 2), 1.0)
    return norm(x, 0.44)  # peaks as loud as the water before


# ------------------------------------------------------------ the pack

def main():
    defs = []

    def sound(name, for_id, event, files, volume_db=0.0, pitch=(0.94, 1.06), loop=False):
        d = {"id": "base:sound/" + name, "kind": "sound", "for": for_id, "event": event,
             "files": files, "volume_db": volume_db, "pitch": list(pitch)}
        if loop:
            d["loop"] = True
        defs.append(d)

    steps = {}
    for surface, seed in (("grass", 1000), ("leaves", 1100), ("moss", 1200), ("sand", 1300),
                          ("wood", 1400), ("earth", 1500)):
        steps[surface] = [write("step_%s_%d" % (surface, k + 1), step(surface, seed + k * 7), 0.8) for k in range(3)]
    for ground, surface in (("base:grass", "grass"), ("base:grass_dry", "grass"), ("base:forest_floor", "leaves"),
                            ("base:moss", "moss"), ("base:sand", "sand"), ("base:dirt", "earth"),
                            ("base:wood_floor", "wood")):
        sound("step_" + ground.split(":")[1], ground, "step", steps[surface], -13.0, (0.92, 1.08))
    sound("step", "*", "step", steps["earth"], -13.0, (0.92, 1.08))
    sound("build", "*", "build", [write("build_wood", build_wood())], -4.0)
    sound("swing", "*", "swing", [write("swing_%d" % (k + 1), swing(2100 + k)) for k in range(2)], -12.0)
    sound("hit", "*", "hit", [write("hit_%d" % (k + 1), hit(2200 + k * 3)) for k in range(3)], -6.0)
    sound("shoot", "*", "shoot", [write("shoot_bow", shoot())], -8.0)
    sound("build_stone", "base:stone_wall", "build", [write("build_stone", build_stone())], -4.0)
    sound("dismantle", "*", "dismantle", [write("dismantle_wood", dismantle_wood())], -4.0)
    sound("dismantle_stone", "base:stone_wall", "dismantle", [write("dismantle_stone", dismantle_stone())], -4.0)
    sound("door_open", "base:wood_door", "open", [write("door_open", door(True))], -5.0)
    sound("door_close", "base:wood_door", "close", [write("door_close", door(False))], -5.0)
    sound("pickup", "*", "pickup", [write("pickup", pickup())], -6.0)
    sound("drop", "*", "drop", [write("drop", drop())], -6.0)
    sound("climb", "*", "climb", [write("climb", climb())], -6.0)
    sound("click", "*", "click", [write("click", click(), 0.6)], -8.0, (0.97, 1.03))
    meadow = write("amb_meadow", amb_meadow(), gain=AMB_GAIN["amb_meadow"])
    forest = write("amb_forest", amb_forest(), gain=AMB_GAIN["amb_forest"])
    water = write("amb_water", amb_water(), gain=1.0)
    for ground in ("base:grass", "base:grass_dry", "base:dirt", "base:sand"):
        sound("amb_" + ground.split(":")[1], ground, "ambience", [meadow], -14.0, (1.0, 1.0), True)
    for ground in ("base:forest_floor", "base:moss"):
        sound("amb_" + ground.split(":")[1], ground, "ambience", [forest], -12.0, (1.0, 1.0), True)
    sound("amb_water", "base:water", "ambience", [water], -12.0, (1.0, 1.0), True)
    meadow_gusts = [write("wind_meadow_%d" % (k + 1), gust("meadow", 500 + k * 11), gain=AMB_GAIN["amb_meadow"]) for k in range(4)]
    forest_gusts = [write("wind_forest_%d" % (k + 1), gust("forest", 600 + k * 11), gain=AMB_GAIN["amb_forest"]) for k in range(4)]
    for ground in ("base:grass", "base:grass_dry", "base:dirt", "base:sand", "base:water"):
        sound("wind_" + ground.split(":")[1], ground, "wind", meadow_gusts, -14.0, (0.95, 1.05))
    for ground in ("base:forest_floor", "base:moss"):
        sound("wind_" + ground.split(":")[1], ground, "wind", forest_gusts, -12.0, (0.95, 1.05))
    with open(os.path.join(PACK, "sounds.json"), "w") as f:
        json.dump({"format": 1, "defs": defs}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote %d sounds, %d files" % (len(defs), len([f for f in os.listdir(OUT) if f.endswith(".wav")])))


if __name__ == "__main__":
    main()
