#!/usr/bin/env python3
"""Build the latest published game snapshot; never deploy a main-branch preview."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

from build import ROOT, read, version_key, write


def command(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def export(repo, ref, destination, paths):
    process = subprocess.Popen(["git", "-C", str(repo), "archive", ref, *paths], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            archive.extractall(destination, filter="data")
    finally:
        process.stdout.close()
    if process.wait() != 0: raise ValueError(f"Cannot export {ref}")


def publication(repo, published, output):
    releases = read(published)["releases"]
    if not releases: raise ValueError("No published release to build")
    latest = max(releases, key=lambda r: version_key(r["tag"]))
    if not latest.get("published_at"): raise ValueError("Latest release has not been confirmed published")
    tag = latest["tag"]
    game_ref = command(repo, "rev-parse", "--verify", f"{tag}^{{commit}}")
    has_builder = subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{game_ref}:tools/site/build.py"], capture_output=True).returncode == 0
    if has_builder:
        docs_ref = game_ref
    else:
        docs_ref = read(repo/"site/publication.json")["bootstrap"].get(tag, "")
        if not re.fullmatch(r"[0-9a-f]{40}", docs_ref):
            raise ValueError(f"Published tag {tag} has no wiki; a pinned bootstrap commit is required")
        docs_ref = command(repo, "rev-parse", "--verify", f"{docs_ref}^{{commit}}")
    with tempfile.TemporaryDirectory(prefix="nhn-publication-") as temp:
        temp = Path(temp)
        game, docs = temp/"game", temp/"docs"
        game.mkdir(); docs.mkdir()
        export(repo, game_ref, game, ["content", "docs", "assets/icon", "src", "project.godot", "CREDITS-art.md", "LICENSE"])
        export(repo, docs_ref, docs, ["tools/site", "site", "docs/changelog"])
        manifest = temp/"published.json"
        write(manifest, {"releases": releases})
        game_version = "v" + read(game/"content/base/pack.json")["version"]
        if game_version != tag: raise ValueError("Published tag and game version differ")
        if f'config/version="{tag.removeprefix("v")}"' not in (game/"project.godot").read_text():
            raise ValueError("Published tag and project version differ")
        subprocess.run(["python3", str(docs/"tools/site/build.py"), "--root", str(docs), "--game-root", str(game),
                        "--published", str(manifest), "--out", str(output.resolve())], check=True)
    metadata = {"tag": tag, "game_commit": game_ref, "documentation_commit": docs_ref, "published_at": latest["published_at"]}
    write(output/"data/publication.json", metadata)
    print(json.dumps(metadata, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--published", type=Path, default=ROOT/"build/published-releases.json")
    parser.add_argument("--out", type=Path, default=ROOT/"build/pages")
    args = parser.parse_args()
    try: publication(args.repo, args.published, args.out)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Public wiki build refused: {error}\n")


if __name__ == "__main__": main()
