#!/usr/bin/env bash
# Fetch the pinned Universal LPC sources the characters are built from into
# art_src/lpc (not kept in git): only the parts tools/art/import_lpc.py uses.
# Usage: tools/art/fetch_lpc.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="https://github.com/LiberatedPixelCup/Universal-LPC-Spritesheet-Character-Generator.git"
COMMIT="9bf06be193b053db256b2536824af426de046aa2"
DEST="$ROOT/art_src/lpc"
PATHS=(
  /CREDITS.csv /sheet_definitions/ /palette_definitions/ /sources/custom-animations.ts
  /spritesheets/body/bodies/male/ /spritesheets/body/bodies/female/
  /spritesheets/head/heads/human/male/ /spritesheets/head/heads/human/female/
  /spritesheets/head/heads/human/male_gaunt/ /spritesheets/head/heads/human/male_plump/
  /spritesheets/head/nose/big/ /spritesheets/head/nose/straight/
  /spritesheets/eyes/eyebrows/thick/ /spritesheets/eyes/eyebrows/thin/
  /spritesheets/hair/messy1/ /spritesheets/hair/plain/ /spritesheets/hair/long/
  /spritesheets/hair/braid/ /spritesheets/hair/ponytail/
  /spritesheets/torso/clothes/longsleeve/longsleeve/ /spritesheets/legs/pants/
  /spritesheets/feet/boots/basic/ /spritesheets/hat/formal/bowler/
  /spritesheets/tools/axe/ /spritesheets/tools/pickaxe/ /spritesheets/tools/hoe/ /spritesheets/tools/fishing_rod/
  /spritesheets/weapon/polearm/spear/ /spritesheets/weapon/ranged/bow/normal/
)
if [[ ! -d "$DEST/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$REPO" "$DEST"
fi
cd "$DEST"
git sparse-checkout set --no-cone "${PATHS[@]}"
git fetch --depth 1 origin "$COMMIT"
git checkout -q "$COMMIT"
echo "LPC sources at $(git rev-parse --short HEAD) in $DEST"
