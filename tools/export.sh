#!/usr/bin/env bash
# Build the game for players: a Linux binary and a Windows .exe (Godot export,
# presets in export_presets.cfg), each with the SQLite library beside it, and
# an archive of each in build/.
# Usage: tools/export.sh [linux|windows|all] [--debug]
# Env: GODOT (binary, default "godot"). Needs Godot's export templates of the
# same version (Editor > Manage Export Templates, or the templates .tpz).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"
WHAT="${1:-all}"
MODE="--export-release"
[[ "${2:-}" == "--debug" || "${1:-}" == "--debug" ]] && MODE="--export-debug"
[[ "$WHAT" == "--debug" ]] && WHAT="all"

VERSION="$("$GODOT" --version | cut -d. -f1-4)"  # e.g. 4.7.2.stable
TEMPLATES="$HOME/.local/share/godot/export_templates/${VERSION}"
if [[ ! -d "$TEMPLATES" ]]; then
  echo "no export templates for Godot $VERSION in $TEMPLATES" >&2
  exit 1
fi
GAME_VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/content/base/pack.json'))['version'])")"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
NAME="noheroneeds-${GAME_VERSION}-${COMMIT}"

"$ROOT/tools/fetch_addons.sh"
# Imports first (a fresh checkout has none); a retry covers Godot's first-run crash.
for _ in 1 2; do
  timeout -k 5 300 "$GODOT" --headless --audio-driver Dummy --path "$ROOT" --import >/dev/null 2>&1 && break
done

build() {  # preset, directory, file, archive command
  local preset="$1" dir="$ROOT/build/$2" file="$3"
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "exporting $preset -> build/$2/$file"
  local log
  log="$("$GODOT" --headless --audio-driver Dummy --path "$ROOT" "$MODE" "$preset" "$dir/$file" 2>&1)" || true
  if [[ ! -s "$dir/$file" ]]; then
    echo "$log" >&2
    echo "export of $preset failed" >&2
    exit 1
  fi
  if echo "$log" | grep -q "ERROR"; then
    echo "$log" | grep -A2 "ERROR" >&2
  fi
}

if [[ "$WHAT" == "linux" || "$WHAT" == "all" ]]; then
  build "Linux" linux noheroneeds.x86_64
  chmod +x "$ROOT/build/linux/noheroneeds.x86_64"
  tar -C "$ROOT/build" -czf "$ROOT/build/${NAME}-linux-x86_64.tar.gz" --transform "s|^linux|${NAME}|" linux
  echo "  build/${NAME}-linux-x86_64.tar.gz"
fi
if [[ "$WHAT" == "windows" || "$WHAT" == "all" ]]; then
  build "Windows" windows noheroneeds.exe
  (cd "$ROOT/build" && rm -f "${NAME}-windows-x86_64.zip" && cp -r windows "$NAME" && zip -qr "${NAME}-windows-x86_64.zip" "$NAME" && rm -rf "$NAME")
  echo "  build/${NAME}-windows-x86_64.zip"
fi
