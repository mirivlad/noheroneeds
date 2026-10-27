#!/usr/bin/env bash
# RO-style 8-way sprite pipeline, for each body (male, female): base body, hairstyles, gear, layer renders,
# pixel sprites, drawn face, sample outfits put together and previewed; then the game's
# atlases. Everything but those (content/base/art/ro, content/base/ro_visuals.json) is written
# under build/ro_sprites/<body> (not kept in git).
# Usage: tools/art/ro_sprites/build.sh [clip...]   (default: all clips of clips.py)
# BODIES="male female" (default) builds those; LAYERS="body boots ..." renders only those
# layers (default: all of gear.render_layers); JOBS=n Blender processes per body at once (default 3; more overfill an 8 GB GPU);
# BLENDER=/path/to/blender overrides the Blender binary; OUT=dir writes elsewhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/tools/art/ro_sprites"
OUT="${OUT:-$ROOT/build/ro_sprites}"
BLENDER="${BLENDER:-$(command -v blender || echo "$HOME/bin/blender-5.2.2-linux-x64/blender")}"
JOBS="${JOBS:-3}"
CLIPS=("${@:-all}")
read -r -a BODIES <<<"${BODIES:-male female}"
read -r -a LAYERS <<<"${LAYERS:-$(cd "$T" && python3 -c 'import gear; print(*gear.render_layers())')}"
read -r -a KEEP_OUTS <<<"$(cd "$T" && python3 -c 'import gear; print(*gear.KEEP_OUT_LAYERS)')"
declare -A SOURCE=([male]=HairSample_Male [female]=HairSample_Female)

mkdir -p "$OUT/logs"
touch "$OUT/.gdignore"  # inside the Godot project: thousands of frames it must not import
blender() {  # blender LOG ARGS...: fails on a non-zero exit or a Python error in the log
  local log="$1" status=0
  shift
  timeout 7200 "$BLENDER" -b "$@" >"$log" 2>&1 || status=$?
  grep -E -i 'error|traceback|^  File|base height|^hair |^gear:' "$log" | grep -v 'gpu.texture' || true
  if ((status)) || grep -q -E 'Traceback|Cannot read file' "$log"; then
    echo "blender failed, see $log" >&2
    return 1
  fi
}
all_there() {  # all_there DIR LAYER...: every layer has pixels in DIR
  (cd "$T" && python3 -c "import os, sys; sys.exit(not all(os.path.isdir(os.path.join('$1', 'pixels', l)) for l in sys.argv[1:]))" "${@:2}")
}

"$T/fetch_base.sh"
pids=()
for body in "${BODIES[@]}"; do
  B="$OUT/$body"
  mkdir -p "$B"
  blender "$OUT/logs/base_$body.log" --factory-startup -P "$T/build_base.py" -- \
    "$ROOT/art_src/ro_sprites/${SOURCE[$body]}.vrm" "$B/base.blend" "$B/layout.json" --body "$body"
  blender "$OUT/logs/hair_$body.log" "$B/base.blend" -P "$T/build_hair.py" -- "$B/hair.blend" "$ROOT/art_src/ro_sprites"
  blender "$OUT/logs/gear_$body.log" "$B/hair.blend" -P "$T/build_gear.py" -- "$B/gear.blend"
  # a full build starts clean; named clips replace only their own frames
  if [[ "${CLIPS[*]}" == all ]]; then
    for layer in "${LAYERS[@]}"; do
      rm -rf "${B:?}/raw/$layer" "$B/pixels/$layer"
    done
    [[ " ${LAYERS[*]} " == *" body "* ]] && rm -rf "$B/face/body"
  fi
  # the layers are dealt out to JOBS Blender processes rendering side by side
  for ((j = 0; j < JOBS; j++)); do
    part=()
    for ((i = j; i < ${#LAYERS[@]}; i += JOBS)); do part+=("${LAYERS[i]}"); done
    ((${#part[@]})) || continue
    blender "$OUT/logs/render_${body}_$j.log" "$B/gear.blend" -P "$T/render.py" -- "$B/raw" \
      --layers "${part[@]}" --clips "${CLIPS[@]}" &
    pids+=($!)
  done
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
((failed == 0)) || exit 1

clips=()
[[ "${CLIPS[*]}" != all ]] && clips=(--clips "${CLIPS[@]}")
for body in "${BODIES[@]}"; do
  B="$OUT/$body"
  for layer in "${LAYERS[@]}"; do
    # the keep-outs are depth maps alone, read raw (hair.py)
    [[ " ${KEEP_OUTS[*]} " == *" $layer "* ]] && continue
    python3 "$T/pixelate.py" 8 "$B/raw/$layer"/*.png --out "$B/pixels/$layer"
  done
  if [[ " ${LAYERS[*]} " == *" body "* ]]; then
    python3 "$T/face2d.py" "$B/pixels/body" "$B/raw/body/anchors.json" --out "$B/face/body"
  fi
  for outfit in $(cd "$T" && python3 -c 'import gear; print(*gear.OUTFITS)'); do
    # an outfit is put together only when all its layers are rendered
    # shellcheck disable=SC2046
    if all_there "$B" $(cd "$T" && python3 -c "import gear; print(*[gear.DEFAULT_HAIR['$body'] if l == 'hair' else l for l in gear.OUTFITS['$outfit']])"); then
      python3 "$T/compose.py" "$B" "$B/outfits/$outfit" --outfit "$outfit" "${clips[@]}"
      python3 "$T/preview.py" "$B/outfits/$outfit" "$B/preview/$outfit" --zoom 2 "${clips[@]}"
    fi
  done
done
# into the game: the bodies that have every layer (content/base/art/ro, ro_visuals.json)
python3 "$T/export_game.py" "$OUT" "$ROOT/content/base"
echo "previews: $OUT/<body>/preview/<outfit>/<clip>.gif|png"
