#!/usr/bin/env bash
# Fetch the pinned LPC environment packs (OpenGameArt) the world is drawn
# from into art_src/lpc_env (not kept in git); tools/art/import_lpc_env.py
# builds the game's atlases from them. Checksums keep them exactly these.
# Usage: tools/art/fetch_lpc_env.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/art_src/lpc_env"
mkdir -p "$DEST"
# name  url  sha256
F=https://opengameart.org/sites/default/files
# Archives, unpacked into a folder of their name.
PACKS=(
  "lpc-terrains $F/lpc-terrains.zip d2d48771a1af9c02c7f12e3a8412ba4b746a2858d42a5f639da064f934eef80f"
  "lpc-walls $F/lpc-walls.zip 604871bda6e4ece50270f0db9d8674351dab861e2d2624430346d1c4eda2aa8e"
  "lpc-floors $F/lpc-floors.zip 68403971cdc51c58e5f6e9a00bfa6008715b3e0694aac59969d03b8328879e23"
  "lpc-windows-doors $F/lpc-windows-doors-v2.zip 5a1c01aacc54fae857451fcd01871e2a8919ff9d84ca0eaccba9210148eef2be"
  "lpc-trees $F/lpc-trees.zip 47803bf90669759f3c6ca8a74ac1d1a05895dfba1b990851a56bcf164aec42a5"
  "lpc-plants $F/lpc-flowers-plants-fungi-wood.zip ec3e039bd872757b8424a0d11c1818eca0286fd1dc0322d276462a46b0f0948f"
)
# Single pictures.
FILES=(
  "thatched-roof.png $F/thatched-roof.png ce93207a11ffc5f22aff46f878631347884c48053474d5733901b1c6b03ee9ee"
  "wooden_stairs.png $F/wooden_stairs.png 1a43a5f75f7e73caf2b0fc86994daf0fce935e6c767c16da94b0c8e1ee39e55e"
  "house_inside_1.png $F/house_inside_1.png d703c86057bf32420bc52db28061e7d990a024d5090ed88195eed97dd97a48d2"
  "chest2.png $F/chest2.png b2e0c5bb594fcf9ff8fe427922fe22aaf4b4ac85928a84be1d032040beb31ca1"
)
get() {  # file url sha256
  if [[ ! -f "$1" ]] || ! echo "$3  $1" | sha256sum -c --quiet - 2>/dev/null; then
    echo "fetching $(basename "$1")"
    curl -fsSL -A "Mozilla/5.0" "$2" -o "$1"
    echo "$3  $1" | sha256sum -c --quiet -
  fi
}
for line in "${PACKS[@]}"; do
  read -r name url sum <<<"$line"
  get "$DEST/$name.zip" "$url" "$sum"
  [[ -d "$DEST/$name" ]] || unzip -q -o "$DEST/$name.zip" -d "$DEST/$name"
done
for line in "${FILES[@]}"; do
  read -r name url sum <<<"$line"
  get "$DEST/$name" "$url" "$sum"
done
echo "LPC environment packs in $DEST"
