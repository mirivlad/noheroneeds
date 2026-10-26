#!/usr/bin/env bash
# Fetch the pinned VRoid sample model the RO-style base body is built from into
# art_src/ro_sprites (not kept in git). HairSample_Male is CC0 (VRoid Studio
# beta sample; the licence is also written in the file's VRM meta).
# Usage: tools/art/ro_sprites/fetch_base.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/art_src/ro_sprites"
URL="https://github.com/madjin/vrm-samples/raw/master/vroid/beta/HairSample_Male.vrm"
SHA="7aeca142dabbc26ba0f5b9c998c8f3cb6df341287d67788427ac837223785a3f"
FILE="$DEST/HairSample_Male.vrm"
mkdir -p "$DEST"
if [[ ! -f "$FILE" ]] || ! echo "$SHA  $FILE" | sha256sum -c --quiet 2>/dev/null; then
  curl -fL --retry 3 -o "$FILE.part" "$URL"
  echo "$SHA  $FILE.part" | sha256sum -c --quiet
  mv "$FILE.part" "$FILE"
fi
echo "base model: $FILE"
