#!/usr/bin/env python3
"""Documentation coverage, reviewed change receipts and release preflight."""
import argparse
import difflib
import fnmatch
import json
from pathlib import Path
import re
import subprocess
import sys

from build import ROOT, build, digest, read, releases, version_key


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True)


def changed(root, base):
    return set(git(root, "diff", "--name-only", base, "--").splitlines()) | set(git(root, "ls-files", "--others", "--exclude-standard").splitlines())


def game_file(path):
    return path.startswith(("src/", "content/")) or path in {"project.godot", "export_presets.cfg"}


def meaningful_change(before, after):
    text = lambda value: re.sub(r"<[^>]+>", " ", value).split()
    return sum(max(a2-a1, b2-b1) for tag, a1, a2, b1, b2 in difflib.SequenceMatcher(None, text(before), text(after)).get_opcodes() if tag != "equal") >= 4


def coverage(root, data):
    manifest = read(root / "site/mechanics-manifest.json")
    guides = {g["id"]: g for g in data["guides"]}
    ids = set()
    for mechanic in manifest["mechanics"]:
        if mechanic["id"] in ids or mechanic["guide"] not in guides or not mechanic.get("sources"):
            raise ValueError(f"Invalid mechanic coverage: {mechanic}")
        ids.add(mechanic["id"])
        for pattern in mechanic["sources"]:
            if not list(root.glob(pattern)):
                raise ValueError(f"Mechanic source matches nothing: {pattern}")
    covered_kinds = {kind for m in manifest["mechanics"] for kind in m.get("kinds", [])}
    missing = {d["kind"] for d in data["entities"]} - covered_kinds
    if missing: raise ValueError(f"New content kinds need guides: {sorted(missing)}")
    patterns = [p for m in manifest["mechanics"] for p in m["sources"]]
    unmapped = [p.relative_to(root).as_posix() for p in (root/"src").rglob("*.gd")
                if not any(fnmatch.fnmatch(p.relative_to(root).as_posix(), pattern) for pattern in patterns)]
    if unmapped: raise ValueError(f"New subsystems need mechanic/guide mappings: {unmapped}")
    return {m["id"]: m for m in manifest["mechanics"]}


def receipts(root, base, data):
    paths = changed(root, base)
    gameplay = {p for p in paths if game_file(p)}
    if not gameplay: return
    manifest = coverage(root, data)
    entries = []
    for path in sorted(paths):
        if path.startswith("docs/changes/") and path.endswith(".json") and (root/path).is_file():
            entries.extend(read(root/path).get("changes", []))
    accounted = set()
    for entry in entries:
        sources = entry.get("sources", {})
        if not sources or any(not game_file(p) or any(c in p for c in "*?[") for p in sources):
            raise ValueError("Receipts must name exact gameplay files")
        active = {p for p, sha in sources.items() if p in gameplay and (digest(root/p) if (root/p).is_file() else "deleted") == sha}
        if not active: continue  # superseded receipts from earlier PRs in a release
        if len(entry.get("summary", "").strip()) < 30:
            raise ValueError("Change receipt needs a substantive summary")
        impact = entry.get("impact")
        if impact == "no-player-facing-change":
            if len(entry.get("rationale", "").strip()) < 100 or len(active) > 5:
                raise ValueError("Internal exemption needs a specific rationale and at most five files")
            patch = git(root, "diff", "--numstat", base, "--", *sorted(active))
            lines = sum(int(n) for row in patch.splitlines() for n in row.split("\t")[:2] if n.isdigit())
            if lines > 100:
                review = entry.get("internal_review", {})
                tests = review.get("tests", [])
                if len(review.get("behavior_contract", "").strip()) < 100 or not tests or any(
                    not p.startswith("tests/unit/") or not p.endswith(".gd") or not (root/p).is_file() for p in tests
                ):
                    raise ValueError("Large internal changes require an explicit behavior contract and existing regression tests")
            for p in active:
                if p.startswith("content/"):
                    try: before = json.loads(git(root, "show", f"{base}:{p}"))
                    except (subprocess.CalledProcessError, json.JSONDecodeError): before = None
                    if before != read(root/p): raise ValueError("Semantic content changes cannot use an internal exemption")
        elif impact == "player-facing-change":
            mechanics = entry.get("mechanics", [])
            if not mechanics or any(m not in manifest for m in mechanics):
                raise ValueError("Player-facing changes must identify documented mechanics")
            for p in active:
                if not any(fnmatch.fnmatch(p, pattern) for m in mechanics for pattern in manifest[m]["sources"]):
                    raise ValueError(f"New subsystem needs an explicit mechanic/guide mapping: {p}")
            for m in mechanics:
                guide = next(g for g in data["guides"] if g["id"] == manifest[m]["guide"])["file"]
                if entry.get("guides", {}).get(guide) != digest(root/guide):
                    raise ValueError(f"Guide review receipt is missing/stale: {guide}")
                if any(p.endswith(".gd") for p in active):
                    try: before = git(root, "show", f"{base}:{guide}")
                    except subprocess.CalledProcessError: before = ""
                    if not meaningful_change(before, (root/guide).read_text()):
                        raise ValueError(f"Behavior changes require a meaningful guide update: {guide}")
            changelog = entry.get("changelog", "")
            if not changelog.startswith("docs/changelog/") or changelog not in paths:
                raise ValueError("Player-facing changes require a prepared changelog in the same change")
            note = read(root/changelog)
            if not set(mechanics) <= set(note.get("mechanics", [])):
                raise ValueError("Changelog must describe the same reviewed mechanics")
            if len(note.get("tagline", "")) < 30 or not note.get("groups") or not all(g.get("bullets") and all(len(b.strip()) >= 20 for b in g["bullets"]) for g in note["groups"]):
                raise ValueError("Prepared player changelog is empty or incomplete")
        else: raise ValueError("Receipt impact must be explicit")
        accounted |= active
    if gameplay - accounted:
        raise ValueError(f"Gameplay changes lack current documentation receipts: {sorted(gameplay-accounted)}")


def validate_links(output):
    from html.parser import HTMLParser
    from urllib.parse import unquote, urlsplit
    wiki = read(output/"data/wiki.json")
    entities = {d["id"] for d in wiki["entities"]}
    guide_ids = {g["id"] for g in wiki["guides"]}
    errors = []
    class Links(HTMLParser):
        def handle_starttag(self, tag, attrs):
            for attr, value in attrs:
                if attr not in {"href", "src"} or not value: continue
                url = urlsplit(value)
                if url.scheme or value.startswith("#"): continue
                target = output/url.path
                if url.path and not target.is_file(): errors.append(value)
                if url.path == "wiki.html" and url.query.startswith("item=") and unquote(url.query[5:]) not in entities: errors.append(value)
                if url.path == "guides.html" and url.fragment and url.fragment not in guide_ids: errors.append(value)
    for page in output.glob("*.html"): Links().feed(page.read_text())
    if errors: raise ValueError(f"Broken website links: {errors}")


def check(root, output, base=None, version=None, published=None, unpublished=False):
    if unpublished:
        history = read(published or root/"site/content/published-releases.json")["releases"]
        if not version or version in {r["tag"] for r in history}:
            raise ValueError("Refusing to rebuild or overwrite an already published game release")
    data = build(root, root, output, published, version)
    coverage(root, data)
    validate_links(output)
    if base: receipts(root, base, data)
    if version:
        version_key(version)
        project = (root/"project.godot").read_text()
        if f'config/version="{version.removeprefix("v")}"' not in project:
            raise ValueError("Project version differs from release version")
        history = read(published or root/"site/content/published-releases.json")["releases"]
        known = [r["tag"] for r in history if version_key(r["tag"]) <= version_key(version)]
        if version in known:
            baseline = version
        else:
            baseline = max(known, key=version_key) if known else None
        if baseline: receipts(root, baseline, data)
    print(f"Documentation ready: {len(data['entities'])} records, {len(data['guides'])} guides")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--out", type=Path, default=ROOT/"build/site")
    parser.add_argument("--base")
    parser.add_argument("--release")
    parser.add_argument("--published", type=Path)
    parser.add_argument("--unpublished", action="store_true", help="Release workflow: reject already published versions")
    args = parser.parse_args()
    try: check(args.root, args.out, args.base, args.release, args.published, args.unpublished)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Documentation gate failed: {error}\n")


if __name__ == "__main__": main()
