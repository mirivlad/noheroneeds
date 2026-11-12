"""Fetch the pinned supporting animal sources; never replace mismatching bytes."""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def fetch(path,info):
    if path.is_symlink(): raise ValueError(f"Source is a symlink: {path}")
    if path.exists():
        data = path.read_bytes()
    else:
        request = urllib.request.Request(info["url"],headers={"User-Agent":"NoHeroNeeded-art"})
        with urllib.request.urlopen(request,timeout=60) as response: data = response.read()
    if len(data)!=info["bytes"] or hashlib.sha256(data).hexdigest()!=info["sha256"]:
        raise ValueError(f"Source mismatch: {path}")
    path.parent.mkdir(parents=True,exist_ok=True)
    if not path.exists(): path.write_bytes(data)


def main():
    for info in json.loads((HERE/"support-source.json").read_text()).values():
        fetch(ROOT/info["file"],info)
    spec = json.loads((HERE/"0ad-source.json").read_text())
    for info in spec["files"]: fetch(ROOT/"art_src/0ad_animals"/info["file"],info)
    spec = json.loads((HERE/"cave-source.json").read_text())
    for info in spec["files"]: fetch(ROOT/info["file"],info)
    missing = [Path(i["file"]).name for i in spec["extracted"] if not (ROOT/i["file"]).exists()]
    if missing:
        subprocess.run(["7z","x","-y","-o"+str(ROOT/"art_src/cave_animals"),str(ROOT/"art_src/cave_animals/rat_source.7z"),*missing],check=True)
    for info in spec["extracted"]:
        path = ROOT/info["file"]
        if path.is_symlink() or path.stat().st_size!=info["bytes"] or hashlib.sha256(path.read_bytes()).hexdigest()!=info["sha256"]:
            raise ValueError(f"Extracted source mismatch: {path}")
    print("Supporting sources verified: hare, four 0 A.D. animals, rat and spider")


if __name__=="__main__": main()
