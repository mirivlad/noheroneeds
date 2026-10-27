#!/usr/bin/env bash
# Fetch the pinned VRoid sample models the RO-style base bodies are built from into
# art_src/ro_sprites (not kept in git). HairSample_Male and HairSample_Female are
# CC0 (VRoid Studio beta samples; the licence is also written in each file's VRM meta).
# Usage: tools/art/ro_sprites/fetch_base.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/art_src/ro_sprites"
BASE="https://github.com/madjin/vrm-samples/raw/master/vroid/beta"
mkdir -p "$DEST"
fetch() {  # fetch NAME SHA256
  local file="$DEST/$1.vrm"
  if [[ ! -f "$file" ]] || ! echo "$2  $file" | sha256sum -c --quiet 2>/dev/null; then
    curl -fL --retry 3 -o "$file.part" "$BASE/$1.vrm"
    echo "$2  $file.part" | sha256sum -c --quiet
    mv "$file.part" "$file"
  fi
  echo "base model: $file"
}
fetch HairSample_Male 7aeca142dabbc26ba0f5b9c998c8f3cb6df341287d67788427ac837223785a3f
fetch HairSample_Female adfd242317aaabc773f31f7fff7b013979fbb5baa47e97427a78913d9cb4e979
