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
PACKS=(
  "lpc-terrains https://opengameart.org/sites/default/files/lpc-terrains.zip d2d48771a1af9c02c7f12e3a8412ba4b746a2858d42a5f639da064f934eef80f"
)
for line in "${PACKS[@]}"; do
  read -r name url sum <<<"$line"
  zip="$DEST/$name.zip"
  if [[ ! -f "$zip" ]] || ! echo "$sum  $zip" | sha256sum -c --quiet - 2>/dev/null; then
    echo "fetching $name"
    curl -fsSL -A "Mozilla/5.0" "$url" -o "$zip"
    echo "$sum  $zip" | sha256sum -c --quiet -
  fi
  if [[ ! -d "$DEST/$name" ]]; then
    unzip -q -o "$zip" -d "$DEST/$name"
  fi
done
echo "LPC environment packs in $DEST"
