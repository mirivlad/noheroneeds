#!/usr/bin/env python3
"""Render the reviewed player changelog used by the game release workflow."""
import argparse
from pathlib import Path

from build import ROOT, releases

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("version")
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
entry = next(r for r in releases(ROOT, ROOT/"site/content/published-releases.json", args.version) if r["version"] == args.version.removeprefix("v"))
text = [f'# {entry["title"]}', "", entry["tagline"], ""]
for group in entry["groups"]:
    text += [f'## {group["title"]}', ""]
    text += ["- " + bullet for bullet in group["bullets"]]
    text += [""]
text += [f'[Руководство и справочник](https://mirivlad.github.io/noheroneeds/)', ""]
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text("\n".join(text), encoding="utf-8")
