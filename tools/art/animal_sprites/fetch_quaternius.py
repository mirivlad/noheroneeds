"""Fetch the pinned CC0 pack; refuse different bytes and external glTF dependencies."""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
SPEC = Path(__file__).with_name("quaternius-source.json")


def main():
    spec = json.loads(SPEC.read_text())
    destination = ROOT / "art_src/quaternius_animals"
    for name, info in spec["files"].items():
        path = destination / name
        if path.is_symlink():
            raise ValueError(f"Source is a symlink: {path}")
        if path.exists():
            data = path.read_bytes()
        else:
            request = urllib.request.Request(info["url"], headers={"User-Agent":"NoHeroNeeded-art"})
            with urllib.request.urlopen(request, timeout=60) as response:
                data = response.read()
        if hashlib.sha256(data).hexdigest() != info["sha256"]:
            raise ValueError(f"Source hash mismatch: {name}")
        if name.endswith(".gltf"):
            document = json.loads(data)
            for dependency in document.get("buffers", []) + document.get("images", []):
                if not dependency.get("uri", "").startswith("data:"):
                    raise ValueError(f"Unrecorded dependency in {name}")
        elif b"CC0 1.0 Universal" not in data:
            raise ValueError("Expected original CC0 license")
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print(f"QUATERNIUS_SOURCE_OK {len(spec['files'])} pinned files; CC0-1.0")


if __name__ == "__main__":
    main()
