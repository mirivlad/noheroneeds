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
  "lpc-farm $F/submission_daneeklu.zip 4fd2b459b0105bf750dd9766ec36c3d00c54b42b8b67f1a3696341ac8491d0a3"
  "lpc-mine $F/lpc-mine.zip 069b39efefeff64dbcebb6a95c6ff36289541e505fabdc17a807a950eae0d6d0"
)
# Single pictures.
FILES=(
  "thatched-roof.png $F/thatched-roof.png ce93207a11ffc5f22aff46f878631347884c48053474d5733901b1c6b03ee9ee"
  "wooden_stairs.png $F/wooden_stairs.png 1a43a5f75f7e73caf2b0fc86994daf0fce935e6c767c16da94b0c8e1ee39e55e"
  "house_inside_1.png $F/house_inside_1.png d703c86057bf32420bc52db28061e7d990a024d5090ed88195eed97dd97a48d2"
  "chest2.png $F/chest2.png b2e0c5bb594fcf9ff8fe427922fe22aaf4b4ac85928a84be1d032040beb31ca1"
  "ore_0.png $F/ore_0.png a0d0940be01d92f6b04fdfcb8070cebd2233de3dad4e40e5559eca4464280272"
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
# Animals (tools/art/import_lpc_animals.py), in their own folder.
ANIMALS="$ROOT/art_src/lpc_animals"
mkdir -p "$ANIMALS"
get "$ANIMALS/lpc_animals_2022_v1.1.zip" "$F/lpc_animals_2022_v1.1.zip" a4ea2c5b33061858e02a60dda34adb30bc8c4a334030bdcc7fafef32c810c002
get "$ANIMALS/LPC_Spiders.zip" "$F/LPC_Spiders.zip" fce56f13629d2aa8be48f1ef904f4cdec184f3d81793a80f202db2b2f47e95b2
get "$ANIMALS/lpc-monsters.zip" "$F/lpc-monsters.zip" 2c591d0e0c89dd579f84fb10ac9b24b97836941d6881abb5db85dc257892878f
get "$ANIMALS/wolfsheet1_0.png" "$F/wolfsheet1_0.png" 35037f84c065844cb974d7d692875115b4c6ebf34e242921991351f370e1fa4f
get "$ANIMALS/rabbit_3.png" "$F/rabbit_3.png" 89da7327cb5662ac1f8ef14ec7c00d38218827582bc0f273e1cea873ce570ae1
[[ -d "$ANIMALS/animals2022" ]] || unzip -q -o "$ANIMALS/lpc_animals_2022_v1.1.zip" -d "$ANIMALS/animals2022"
[[ -d "$ANIMALS/spiders" ]] || unzip -q -o "$ANIMALS/LPC_Spiders.zip" -d "$ANIMALS/spiders"
[[ -d "$ANIMALS/monsters" ]] || unzip -q -o "$ANIMALS/lpc-monsters.zip" -d "$ANIMALS/monsters"
# Item pictures (tools/art/import_lpc_env.py, ITEMS).
ITEMS="$ROOT/art_src/lpc_items"
mkdir -p "$ITEMS"
get "$ITEMS/idylwilds_inventory.zip" "$F/idylwilds_inventory.zip" ecf73c5d795eb94e409dc361fad51c78b5c640fe44eb44b13e55e572eecca5de
get "$ITEMS/items1_0.png" "$F/items1_0.png" e3a3a9ddf6b761548476df3546b47855efc1cf9db6a71c882678baa94579b030
get "$ITEMS/effects_5.png" "$F/effects_5.png" 9046fc06c0b1ea642f3d859deca80c9d4bfe8d0b9465417a912dd2200c4440ab
[[ -d "$ITEMS/idyl" ]] || unzip -q -o "$ITEMS/idylwilds_inventory.zip" -d "$ITEMS/idyl"
echo "LPC environment packs in $DEST, animals in $ANIMALS, items in $ITEMS"
