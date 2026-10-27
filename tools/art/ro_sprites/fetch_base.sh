#!/usr/bin/env bash
# Fetch the pinned VRoid sample models the RO-style base bodies and hairstyles are built from
# into art_src/ro_sprites (not kept in git). All are CC0, by pixiv Inc. (VRoid Studio beta
# samples; the licence is written in each file's VRM meta and on vroid.pixiv.help:
# HairSample_Male/Female, AvatarSample_D = Sendagaya Shibu, E = Vivi, F = Vita, G = Victoria
# Rubin, and her sister Sendagaya Shino and cousin Sakurada Fumiriya).
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
}
fetch HairSample_Male 7aeca142dabbc26ba0f5b9c998c8f3cb6df341287d67788427ac837223785a3f
fetch HairSample_Female adfd242317aaabc773f31f7fff7b013979fbb5baa47e97427a78913d9cb4e979
fetch Sakurada_Fumiriya d8fb05f33e377df028cb6b9d58c441ce68326c41fa23f6c735d40c65ae3dc710
fetch Sendagaya_Shibu b7bcad5e5890abc4d7c65f9afc31da2445db03197d44f1ec10447f9db5abeaff
fetch Sendagaya_Shino 1e177c1a7b14f783a9c48395831db8616260d3bddd4154cb2784b779adca49b5
fetch Victoria_Rubin b1372131bdbf233f46320146d565f342a7e4f6f4b8f2aefb301f1a283ec07e1e
fetch Vita f2bf78f28a24e2f75f5ca0b6c3b646654c394e4b03592dfaa0d0633ef0972b4d
fetch Vivi eaf902e041a7a810f1423599ae75682f61184ab6ef0206da9a8ed9caa8ec3a9d
