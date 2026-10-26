#!/usr/bin/env bash
# RO-style 8-way sprite pipeline: base body, clip renders, pixel sprites, drawn face, previews.
# Everything is written under build/ro_sprites (not kept in git).
# Usage: tools/art/ro_sprites/build.sh [clip...]   (default: all clips of clips.py)
# BLENDER=/path/to/blender overrides the Blender binary; PROPS=1 adds stand-in tools (for review
# only: they are drawn into the body layer); OUT=dir writes elsewhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/tools/art/ro_sprites"
OUT="${OUT:-$ROOT/build/ro_sprites}"
BLENDER="${BLENDER:-$(command -v blender || echo "$HOME/bin/blender-5.2.2-linux-x64/blender")}"
CLIPS=("${@:-all}")
PROPS_ARG=()
[[ "${PROPS:-0}" == 1 ]] && PROPS_ARG=(--props)

mkdir -p "$OUT"
LOG="$OUT/blender.log"
blender() {
  local status=0
  timeout 1800 "$BLENDER" -b "$@" >"$LOG" 2>&1 || status=$?
  grep -E -i 'error|traceback|^  File|base height' "$LOG" | grep -v 'gpu.texture' || true
  if ((status)) || grep -q -E 'Traceback|Cannot read file' "$LOG"; then
    echo "blender failed, see $LOG" >&2
    exit 1
  fi
}

"$T/fetch_base.sh"
blender --factory-startup -P "$T/build_base.py" -- \
  "$ROOT/art_src/ro_sprites/HairSample_Male.vrm" "$OUT/base_male.blend" "$OUT/base_male_layout.json"
for variant in body hair; do
  raw="$OUT/raw/$variant"
  # a full build starts clean; named clips replace only their own frames
  [[ "${CLIPS[*]}" == all ]] && rm -rf "$raw" "$OUT/pixels/$variant" "$OUT/face/$variant" "$OUT/sprites/$variant"
  hair=()
  [[ $variant == hair ]] && hair=(--hair)
  blender "$OUT/base_male.blend" -P "$T/render.py" -- "$raw" --clips "${CLIPS[@]}" "${hair[@]}" "${PROPS_ARG[@]}"
  python3 "$T/pixelate.py" 8 "$raw"/*.png --out "$OUT/pixels/$variant"
  python3 "$T/face2d.py" "$OUT/pixels/$variant" "$raw/anchors.json" \
    --out "$OUT/face/$variant" --onto "$OUT/sprites/$variant"
  clips=()
  [[ "${CLIPS[*]}" != all ]] && clips=(--clips "${CLIPS[@]}")
  python3 "$T/preview.py" "$OUT/sprites/$variant" "$OUT/preview/$variant" "${clips[@]}"
done
echo "previews: $OUT/preview/{body,hair}/<clip>.gif|png"
