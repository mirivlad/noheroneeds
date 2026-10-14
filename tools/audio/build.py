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
dismantle | open | close | pickup | drop | climb | click | ambience,
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


def write(name, x, peak=0.9):
    x = np.clip(norm(x, peak), -1, 1)
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

def step(surface, seed):
    """A soft footstep on a surface."""
    r = rng(seed)
    sec = 0.18
    if surface == "grass":       # blades brushing, a soft heel
        x = band(noise(sec, seed), 1200, 5000) * decay(sec, 0.035, 0.012) * 0.5
        x += band(noise(sec, seed + 1), 80, 300) * decay(sec, 0.03, 0.006)
    elif surface == "leaves":    # dry litter crackling under the foot
        x = band(noise(sec, seed + 1), 80, 300) * decay(sec, 0.03, 0.006)
        for k in range(r.integers(5, 10)):
            place(x, band(noise(0.008, seed + 10 + k), 2000, 6000) * decay(0.008, 0.0015),
                  r.uniform(0.0, 0.07), r.uniform(0.2, 0.5))
    elif surface == "moss":      # almost nothing: a muffled press
        x = band(noise(sec, seed), 60, 260) * decay(sec, 0.045, 0.012)
        x += band(noise(sec, seed + 1), 600, 1500) * decay(sec, 0.02, 0.01) * 0.15
    elif surface == "sand":      # a long soft crunch
        sec = 0.22
        x = band(noise(sec, seed), 1500, 6000) * decay(sec, 0.06, 0.02) * 0.45
        x += band(noise(sec, seed + 1), 90, 300) * decay(sec, 0.03, 0.008) * 0.6
    elif surface == "wood":      # a board, hollow underneath
        x = band(noise(sec, seed), 90, 520) * decay(sec, 0.04, 0.005)
        x += 0.35 * knock(r.uniform(150, 190), sec, seed + 2, 0.03)
        x += 0.1 * band(noise(sec, seed + 3), 1100, 2400) * decay(sec, 0.008, 0.003)
    else:                        # earth: a dull thud with a little grit
        x = band(noise(sec, seed), 70, 380) * decay(sec, 0.035, 0.006)
        x += band(noise(sec, seed + 1), 1500, 3500) * decay(sec, 0.02, 0.006) * 0.12
    return low(x, 3000, 2)


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


def amb_meadow():
    """A meadow in the day: a soft wind, grasshoppers, now and then birds."""
    sec = 24.0
    wind = band(noise(sec, 100), 120, 900) * 0.35 * slow_env(sec, 0.15, 101, 0.25, 1.0)
    grass = band(noise(sec, 102), 2000, 6000) * 0.04 * slow_env(sec, 0.3, 103, 0.2, 1.0)
    x = wind + grass + 0.08 * cricket(sec, 104, 4300) + 0.05 * cricket(sec, 105, 5200)
    r = rng(106)
    for k, at in enumerate(np.sort(r.uniform(1.0, sec - 2.0, 6))):
        place(x, chirp(110 + k), at, r.uniform(0.12, 0.25))
    place(x, song(120), 8.0, 0.2)
    place(x, song(121), 17.5, 0.16)
    return loopify(reverb(x, 0.3, 0.15, 107), 1.5)


def amb_forest():
    """In a forest: wind in the crowns in long gusts, many birds, a woodpecker far off."""
    sec = 28.0
    crowns = band(noise(sec, 200), 300, 2500) * 0.3 * slow_env(sec, 0.1, 201, 0.15, 1.0)
    low_air = low(noise(sec, 202), 200, 3) * 0.6 * slow_env(sec, 0.08, 203, 0.4, 1.0)
    x = crowns + low_air
    r = rng(204)
    for k, at in enumerate(np.sort(r.uniform(0.5, sec - 2.0, 7))):
        place(x, song(210 + k), at, r.uniform(0.12, 0.3))
    for k, at in enumerate(np.sort(r.uniform(0.5, sec - 1.0, 10))):
        place(x, chirp(230 + k), at, r.uniform(0.08, 0.18))
    for at in (6.0, 19.0):        # a woodpecker: a quick roll of knocks
        for k in range(14):
            place(x, knock(900, 0.03, 250 + k, 0.006), at + k * 0.045, 0.12 * (1 - k / 20))
    return loopify(reverb(x, 0.6, 0.3, 205), 2.0)


def amb_water():
    """By the water: small waves lapping at the bank, a plip now and then."""
    sec = 16.0
    lap = low(noise(sec, 300), 700, 3) * slow_env(sec, 1.2, 301, 0.0, 1.0) ** 2 * 0.8
    hiss = band(noise(sec, 302), 1500, 5000) * 0.05 * slow_env(sec, 0.9, 303, 0.1, 1.0)
    x = lap + hiss
    r = rng(304)
    for k, at in enumerate(np.sort(r.uniform(0.5, sec - 1.0, 8))):
        t = t_axis(0.06)
        f = r.uniform(600, 1100) * (1 + 2.5 * t / 0.06)
        place(x, np.sin(2 * np.pi * np.cumsum(f) / SR) * decay(0.06, 0.02), at, r.uniform(0.08, 0.18))
    return loopify(x, 1.5)


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
        sound("step_" + ground.split(":")[1], ground, "step", steps[surface], -10.0, (0.9, 1.1))
    sound("step", "*", "step", steps["earth"], -10.0, (0.9, 1.1))
    sound("build", "*", "build", [write("build_wood", build_wood())], -4.0)
    sound("build_stone", "base:stone_wall", "build", [write("build_stone", build_stone())], -4.0)
    sound("dismantle", "*", "dismantle", [write("dismantle_wood", dismantle_wood())], -4.0)
    sound("dismantle_stone", "base:stone_wall", "dismantle", [write("dismantle_stone", dismantle_stone())], -4.0)
    sound("door_open", "base:wood_door", "open", [write("door_open", door(True))], -5.0)
    sound("door_close", "base:wood_door", "close", [write("door_close", door(False))], -5.0)
    sound("pickup", "*", "pickup", [write("pickup", pickup())], -6.0)
    sound("drop", "*", "drop", [write("drop", drop())], -6.0)
    sound("climb", "*", "climb", [write("climb", climb())], -6.0)
    sound("click", "*", "click", [write("click", click(), 0.6)], -8.0, (0.97, 1.03))
    meadow = write("amb_meadow", amb_meadow(), 0.7)
    forest = write("amb_forest", amb_forest(), 0.7)
    water = write("amb_water", amb_water(), 0.7)
    for ground in ("base:grass", "base:grass_dry", "base:dirt", "base:sand"):
        sound("amb_" + ground.split(":")[1], ground, "ambience", [meadow], -14.0, (1.0, 1.0), True)
    for ground in ("base:forest_floor", "base:moss"):
        sound("amb_" + ground.split(":")[1], ground, "ambience", [forest], -12.0, (1.0, 1.0), True)
    sound("amb_water", "base:water", "ambience", [water], -12.0, (1.0, 1.0), True)
    with open(os.path.join(PACK, "sounds.json"), "w") as f:
        json.dump({"format": 1, "defs": defs}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote %d sounds, %d files" % (len(defs), len(os.listdir(OUT))))


if __name__ == "__main__":
    main()
