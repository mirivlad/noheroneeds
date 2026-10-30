#!/usr/bin/env python3
"""Read published GitHub Releases, never infer publications from Git tags."""
import argparse
import json
import os
from pathlib import Path
from urllib.request import Request, urlopen

from build import ROOT, version_key, write


def published():
    url = "https://api.github.com/repos/mirivlad/noheroneeds/releases?per_page=100"
    records = []
    while url:
        headers = {"Accept": "application/vnd.github+json", "User-Agent": "NHN-wiki-builder"}
        if os.environ.get("GITHUB_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
        with urlopen(Request(url, headers=headers), timeout=30) as response:
            for release in json.load(response):
                if release["draft"] or release["prerelease"]: continue
                version_key(release["tag_name"])
                if not release.get("published_at"): raise ValueError("Release publication date is missing")
                records.append({"tag": release["tag_name"], "published_at": release["published_at"], "url": release["html_url"]})
            import re
            next_page = re.search(r'<([^>]+)>; rel="next"', response.headers.get("Link", ""))
            url = next_page[1] if next_page else None
    if not records: raise ValueError("No published releases returned")
    if len({r["tag"] for r in records}) != len(records): raise ValueError("Duplicate releases returned")
    return {"releases": sorted(records, key=lambda r: version_key(r["tag"]))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT/"build/published-releases.json")
    parser.add_argument("--require-tag")
    args = parser.parse_args()
    try: data = published()
    except Exception as error: parser.exit(1, f"Cannot verify published release history: {error}\n")
    if args.require_tag and args.require_tag not in {r["tag"] for r in data["releases"]}:
        parser.exit(1, f"Release is not yet confirmed published: {args.require_tag}\n")
    write(args.out, data)
    print(f"Verified {len(data['releases'])} publications; latest: {data['releases'][-1]['tag']}")


if __name__ == "__main__": main()
