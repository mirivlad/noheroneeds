#!/usr/bin/env python3
"""Animal voices from freely licensed recordings (the author, 27.10.2026: rare,
by events): fetched into art_src/animal_sounds (not kept in git), cut to their
loudest calls and evened out with sox, written to content/base/audio/voice_*.ogg
with content/base/voices.json tying them to the creatures and CREDITS-audio.md
naming their authors.

    python3 tools/audio/import_animal_voices.py

Events (AudioDirector): "voice" now and then (every [lo, hi] seconds, each
animal on its own), "attack" when it strikes, "chase" once when it starts
hunting someone, "death" when it dies. Mono Ogg Vorbis, 22050 Hz.
"""
import json
import os
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "art_src", "animal_sounds")
OUT = os.path.join(ROOT, "content", "base", "audio")
OGA = "https://opengameart.org/sites/default/files/"
COMMONS = "https://commons.wikimedia.org/wiki/Special:FilePath/"

# file in SRC: (url, title, author, licence, page)
SOURCES = {
    "sheep_baa.ogg": (OGA + "sheep_baa.ogg", "Sheep Baa", "AntumDeluge", "CC0",
        "https://opengameart.org/content/sheep-baa"),
    "chicken_sound_effect.mp3": (OGA + "chicken_sound_effect.mp3", "Chicken Sound Effect", "IMadeIt", "CC-BY 3.0",
        "https://opengameart.org/content/chicken-sound-effect"),
    "archive_1.zip": (OGA + "archive_1.zip", "Dog growls", "congusbongus", "CC-BY 3.0",
        "https://opengameart.org/content/dog-growls"),
    "bear_01.ogg": (OGA + "bear_01.ogg", "Bear Growls", "AntumDeluge (U.S. Fish & Wildlife Service)", "CC0",
        "https://opengameart.org/content/bear-growls"),
    "bear_02.ogg": (OGA + "bear_02.ogg", "Bear Growls", "AntumDeluge (U.S. Fish & Wildlife Service)", "CC0",
        "https://opengameart.org/content/bear-growls"),
    "80-CC0-creature-SFX_0.zip": (OGA + "80-CC0-creature-SFX_0.zip", "80 CC0 creature SFX", "rubberduck", "CC0",
        "https://opengameart.org/content/80-cc0-creature-sfx"),
    "Single_Cow_Moo.ogg": (COMMONS + "Single_Cow_Moo.ogg", "Single Cow Moo", "MichaeltheFox8621", "CC BY-SA 4.0",
        "https://commons.wikimedia.org/wiki/File:Single_Cow_Moo.ogg"),
    "Mudchute_cow_1.ogg": (COMMONS + "Mudchute_cow_1.ogg", "Mudchute cow 1", "Secretlondon", "CC BY-SA 3.0",
        "https://commons.wikimedia.org/wiki/File:Mudchute_cow_1.ogg"),
    "Chickens_demanding_food.ogg": (COMMONS + "Chickens_demanding_food.ogg", "Chickens demanding food", "alys",
        "Public domain", "https://commons.wikimedia.org/wiki/File:Chickens_demanding_food.ogg"),
    "Hirsch_roehrt.ogg": (COMMONS + "Hirsch_roehrt.ogg", "Hirsch röhrt", "Jugrü", "CC BY-SA 3.0",
        "https://commons.wikimedia.org/wiki/File:Hirsch_roehrt.ogg"),
    "Wolf_howls.ogg": (COMMONS + "Wolf_howls.ogg", "Wolf howls", "автор не указан на Commons", "Public domain",
        "https://commons.wikimedia.org/wiki/File:Wolf_howls.ogg"),
    "red_fox.ogg": (COMMONS + "Red_Fox_(Vulpes_vulpes)_(W1CDR0001529_BD12).ogg", "Red Fox (Vulpes vulpes)",
        "автор не указан на Commons (запись W1CDR0001529 BD12)", "CC BY-SA 4.0",
        "https://commons.wikimedia.org/wiki/File:Red_Fox_(Vulpes_vulpes)_(W1CDR0001529_BD12).ogg"),
}

# name: (source file (in SRC, or inside its zip as "zip:member"), how many calls to keep,
# longest call in seconds)
CUTS = {
    "cow": [("Single_Cow_Moo.ogg", 1, 3.5), ("Mudchute_cow_1.ogg", 1, 2.2)],
    "sheep": [("sheep_baa.ogg", 1, 1.5)],
    "chicken": [("chicken_sound_effect.mp3", 2, 1.2), ("Chickens_demanding_food.ogg", 2, 1.5)],
    "wolf_growl": [("archive_1.zip:2.ogg", 1, 1.2), ("archive_1.zip:3.ogg", 1, 1.2), ("archive_1.zip:4.ogg", 1, 1.2)],
    "wolf_howl": [("Wolf_howls.ogg", 1, 4.0)],
    "bear": [("bear_01.ogg", 1, 1.5), ("bear_02.ogg", 1, 1.5)],
    "deer": [("Hirsch_roehrt.ogg", 1, 2.5)],
    "fox": [("red_fox.ogg", 2, 1.2)],
    "death": [("80-CC0-creature-SFX_0.zip:hurt_01.ogg", 1, 1.5), ("80-CC0-creature-SFX_0.zip:hurt_03.ogg", 1, 1.5),
        ("80-CC0-creature-SFX_0.zip:scream_01.ogg", 1, 1.5)],
    "squeak": [("80-CC0-creature-SFX_0.zip:cute_03.ogg", 1, 1.0), ("80-CC0-creature-SFX_0.zip:cute_05.ogg", 1, 1.0)],
}

# creature: [(event, cut, volume_db, every)]
VOICES = {
    "base:cow": [("voice", "cow", -6.0, [25, 70]), ("death", "cow", -6.0, None)],
    "base:sheep": [("voice", "sheep", -6.0, [20, 60]), ("death", "sheep", -6.0, None)],
    "base:chicken": [("voice", "chicken", -9.0, [15, 45]), ("death", "chicken", -8.0, None)],
    "base:wolf": [("attack", "wolf_growl", -6.0, None), ("chase", "wolf_howl", -4.0, None), ("death", "death", -6.0, None)],
    "base:bear": [("attack", "bear", -4.0, None), ("death", "bear", -4.0, None)],
    "base:polar_bear": [("attack", "bear", -4.0, None), ("death", "bear", -4.0, None)],
    "base:deer": [("voice", "deer", -8.0, [50, 130]), ("death", "death", -8.0, None)],
    "base:fox": [("voice", "fox", -9.0, [50, 130]), ("death", "fox", -8.0, None)],
    "base:arctic_fox": [("voice", "fox", -9.0, [50, 130]), ("death", "fox", -8.0, None)],
    "base:hare": [("death", "squeak", -10.0, None)],
    "base:cave_rat": [("death", "squeak", -10.0, None)],
}


def fetch() -> None:
    os.makedirs(SRC, exist_ok=True)
    for name, (url, *_) in SOURCES.items():
        path = os.path.join(SRC, name)
        if not os.path.exists(path):
            req = urllib.request.Request(url, headers={"User-Agent": "NoHeroNeeded asset import"})
            with urllib.request.urlopen(req) as r, open(path, "wb") as f:
                f.write(r.read())


def source(spec: str, tmp: str) -> str:
    if ":" not in spec:
        return os.path.join(SRC, spec)
    archive, member = spec.split(":", 1)
    with zipfile.ZipFile(os.path.join(SRC, archive)) as z:
        for n in z.namelist():
            if n.endswith("/" + member) or n == member:
                if "__MACOSX" in n:
                    continue
                out = os.path.join(tmp, archive + "_" + member)
                with open(out, "wb") as f:
                    f.write(z.read(n))
                return out
    raise SystemExit("no %s in %s" % (member, archive))


def calls(path: str, tmp: str, keep: int, longest: float) -> list:
    """The loudest stretches between pauses, at most `longest` seconds each."""
    wav = os.path.join(tmp, "whole.wav")
    subprocess.run(["sox", path, "-c", "1", "-r", "22050", wav, "highpass", "60"], check=True)
    parts = os.path.join(tmp, "part.wav")
    for f in os.listdir(tmp):
        if f.startswith("part"):
            os.remove(os.path.join(tmp, f))
    subprocess.run(["sox", wav, parts, "silence", "1", "0.05", "4%", "1", "0.25", "4%", ":", "newfile", ":",
        "restart"], check=True)
    found = []
    for f in sorted(os.listdir(tmp)):
        if not f.startswith("part"):
            continue
        p = os.path.join(tmp, f)
        length = float(subprocess.run(["soxi", "-D", p], capture_output=True, text=True).stdout or 0)
        if length < 0.25:
            continue
        stat = subprocess.run(["sox", p, "-n", "stat"], capture_output=True, text=True).stderr
        rms = float(next((l.split()[-1] for l in stat.splitlines() if l.startswith("RMS     amplitude")), "0"))
        found.append((rms, p, length))
    if not found:  # no pauses in it: the whole of it
        found = [(1.0, wav, longest)]
    found.sort(reverse=True)
    return found[:keep]


def main() -> None:
    fetch()
    os.makedirs(OUT, exist_ok=True)
    files = {}
    for cut, specs in CUTS.items():
        files[cut] = []
        for spec, keep, longest in specs:
            with tempfile.TemporaryDirectory() as tmp:
                for i, (_, p, length) in enumerate(calls(source(spec, tmp), tmp, keep, longest)):
                    name = "voice_%s_%d.ogg" % (cut, len(files[cut]) + 1)
                    subprocess.run(["sox", p, "-C", "4", os.path.join(OUT, name), "trim", "0", str(min(length, longest)),
                        "norm", "-3", "fade", "t", "0.02", "-0", "0.08"], check=True)
                    files[cut].append("audio/" + name)
    defs = []
    for creature, voices in VOICES.items():
        for event, cut, db, every in voices:
            d = {"id": "base:sound/voice_%s_%s" % (creature.split(":")[1], event), "kind": "sound", "for": creature,
                "event": event, "files": files[cut], "volume_db": db, "pitch": [0.92, 1.08]}
            if every:
                d["every"] = every
            defs.append(d)
    with open(os.path.join(ROOT, "content", "base", "voices.json"), "w", encoding="utf-8") as f:
        json.dump({"format": 1, "defs": defs}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    lines = ["# Авторы звуков", "", "Голоса зверей (`content/base/audio/voice_*.ogg`) вырезаны из записей ниже",
        "(`tools/audio/import_animal_voices.py`); остальные звуки синтезированы (`tools/audio/build.py`).", ""]
    seen = set()
    for name, (_, title, author, licence, page) in SOURCES.items():
        if (title, page) in seen:
            continue
        seen.add((title, page))
        lines.append("- [%s](%s) — %s, %s" % (title, page, author, licence))
    with open(os.path.join(ROOT, "CREDITS-audio.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %d voices, %d files" % (len(defs), sum(len(v) for v in files.values())))


if __name__ == "__main__":
    main()
