#!/usr/bin/env bash
# RO-style 8-way sprite pipeline: base body, renders, pixel sprites, drawn face.
# Everything is written under build/ro_sprites (not kept in git).
# Usage: tools/art/ro_sprites/build.sh [pose...]   (default pose: stand)
# BLENDER=/path/to/blender overrides the Blender binary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/tools/art/ro_sprites"
OUT="$ROOT/build/ro_sprites"
BLENDER="${BLENDER:-$(command -v blender || echo "$HOME/bin/blender-5.2.2-linux-x64/blender")}"
POSES=("${@:-stand}")

LOG="$OUT/blender.log"
blender() {
  local status=0
  timeout 600 "$BLENDER" -b "$@" >"$LOG" 2>&1 || status=$?
  grep -E -i 'error|traceback|^  File|base height' "$LOG" || true
  if ((status)) || grep -q Traceback "$LOG"; then echo "blender failed, see $LOG" >&2; exit 1; fi
}

mkdir -p "$OUT"
"$T/fetch_base.sh"
blender --factory-startup -P "$T/build_base.py" -- \
  "$ROOT/art_src/ro_sprites/HairSample_Male.vrm" "$OUT/base_male.blend" "$OUT/base_male_layout.json"
for pose in "${POSES[@]}"; do
  for hair in "" --hair; do
    raw="$OUT/raw/$pose$hair"
    rm -rf "$raw"
    blender "$OUT/base_male.blend" -P "$T/render_dirs.py" -- "$raw" --pose "$pose" $hair
    python3 "$T/pixelate.py" 8 "$raw"/*.png --out "$OUT/body/$pose$hair"
    python3 "$T/face2d.py" "$OUT/body/$pose$hair" "$raw/anchors.json" \
      --out "$OUT/face/$pose$hair" --onto "$OUT/sprites/$pose$hair"
  done
  python3 "$T/sheet.py" "$OUT/sheet_$pose.png" --cols 8 --zoom 3 \
    "$OUT/sprites/$pose"/"$pose"_{s,se,e,ne,n,nw,w,sw}.png "$OUT/sprites/$pose--hair"/"$pose"_{s,se,e,ne,n,nw,w,sw}.png
done
echo "sheets: $OUT/sheet_*.png"
