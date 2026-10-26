#!/usr/bin/env bash
# RO-style 8-way sprite pipeline: base body, gear, layer renders, pixel sprites, drawn face,
# sample outfits put together and previewed. Everything is written under build/ro_sprites
# (not kept in git).
# Usage: tools/art/ro_sprites/build.sh [clip...]   (default: all clips of clips.py)
# BLENDER=/path/to/blender overrides the Blender binary; LAYERS="body boots ..." renders only
# those layers (default: all of gear.py); JOBS=n Blender processes at once (default 3);
# OUT=dir writes elsewhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/tools/art/ro_sprites"
OUT="${OUT:-$ROOT/build/ro_sprites}"
BLENDER="${BLENDER:-$(command -v blender || echo "$HOME/bin/blender-5.2.2-linux-x64/blender")}"
JOBS="${JOBS:-3}"
CLIPS=("${@:-all}")
read -r -a LAYERS <<<"${LAYERS:-$(cd "$T" && python3 -c 'import gear; print(*gear.all_layers())')}"

mkdir -p "$OUT/logs"
blender() {  # blender LOG ARGS...: fails on a non-zero exit or a Python error in the log
  local log="$1" status=0
  shift
  timeout 7200 "$BLENDER" -b "$@" >"$log" 2>&1 || status=$?
  grep -E -i 'error|traceback|^  File|base height|^gear:' "$log" | grep -v 'gpu.texture' || true
  if ((status)) || grep -q -E 'Traceback|Cannot read file' "$log"; then
    echo "blender failed, see $log" >&2
    return 1
  fi
}

"$T/fetch_base.sh"
blender "$OUT/logs/base.log" --factory-startup -P "$T/build_base.py" -- \
  "$ROOT/art_src/ro_sprites/HairSample_Male.vrm" "$OUT/base_male.blend" "$OUT/base_male_layout.json"
blender "$OUT/logs/gear.log" "$OUT/base_male.blend" -P "$T/build_gear.py" -- "$OUT/gear_male.blend"

# a full build starts clean; named clips replace only their own frames
if [[ "${CLIPS[*]}" == all ]]; then
  for layer in "${LAYERS[@]}"; do
    rm -rf "${OUT:?}/raw/$layer" "$OUT/pixels/$layer"
  done
  [[ " ${LAYERS[*]} " == *" body "* ]] && rm -rf "$OUT/face/body"
fi

# the layers are dealt out to JOBS Blender processes rendering side by side
pids=()
for ((j = 0; j < JOBS; j++)); do
  part=()
  for ((i = j; i < ${#LAYERS[@]}; i += JOBS)); do part+=("${LAYERS[i]}"); done
  ((${#part[@]})) || continue
  blender "$OUT/logs/render_$j.log" "$OUT/gear_male.blend" -P "$T/render.py" -- "$OUT/raw" \
    --layers "${part[@]}" --clips "${CLIPS[@]}" &
  pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
((failed == 0)) || exit 1

for layer in "${LAYERS[@]}"; do
  python3 "$T/pixelate.py" 8 "$OUT/raw/$layer"/*.png --out "$OUT/pixels/$layer"
done
if [[ " ${LAYERS[*]} " == *" body "* ]]; then
  python3 "$T/face2d.py" "$OUT/pixels/body" "$OUT/raw/body/anchors.json" --out "$OUT/face/body"
fi

clips=()
[[ "${CLIPS[*]}" != all ]] && clips=(--clips "${CLIPS[@]}")
for outfit in $(cd "$T" && python3 -c 'import gear; print(*gear.OUTFITS)'); do
  # an outfit is put together only when all its layers are rendered
  if (cd "$T" && python3 -c "import gear, os, sys; sys.exit(not all(os.path.isdir('$OUT/pixels/' + l) for l in gear.OUTFITS['$outfit']))"); then
    python3 "$T/compose.py" "$OUT" "$OUT/outfits/$outfit" --outfit "$outfit" "${clips[@]}"
    python3 "$T/preview.py" "$OUT/outfits/$outfit" "$OUT/preview/$outfit" --zoom 2 "${clips[@]}"
  fi
done
echo "previews: $OUT/preview/<outfit>/<clip>.gif|png"
