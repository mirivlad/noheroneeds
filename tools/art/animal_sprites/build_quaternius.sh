#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
animal_blender="${BLENDER:-$(command -v blender || true)}"
if [[ -z "$animal_blender" ]]; then
    animal_blender="$HOME/bin/blender-5.2.2-linux-x64/blender"
fi
animal_out="${1:-build/animal_sprites/quaternius}"
if (($#)); then shift; fi
if (($# == 0)); then set -- --models all --clips idle walk run; fi
python3 tools/art/animal_sprites/fetch_quaternius.py
"$animal_blender" -b -t "${THREADS:-4}" --python-exit-code 1 \
    -P tools/art/animal_sprites/quaternius.py -- "$animal_out" "$@"
for animal_report in "$animal_out"/*/render.json; do
    python3 tools/art/animal_sprites/export.py "$(dirname "$animal_report")"
done
