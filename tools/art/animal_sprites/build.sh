#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
animal_blender="${BLENDER:-$(command -v blender || true)}"
if [[ -z "$animal_blender" ]]; then
    animal_blender="$HOME/bin/blender-5.2.2-linux-x64/blender"
fi
animal_out="${1:-build/animal_sprites/horse-v6}"
"$animal_blender" -b -t "${THREADS:-4}" --python-exit-code 1 \
    -P tools/art/animal_sprites/render.py -- "$animal_out"
python3 tools/art/animal_sprites/export.py "$animal_out"
