#!/usr/bin/env bash
# Run the game (the world in 3D). Usage: tools/run_game.sh [-- game options, e.g. --connect=HOST:PORT]
# After a pull new or changed pictures and scripts must be imported first:
# running the game alone (godot --path .) does not import them, only the
# editor does. This script imports (quickly, when nothing changed) and runs.
# Env: GODOT (binary, default "godot").
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"
"$ROOT/tools/fetch_addons.sh" || exit 1
for _ in 1 2; do
  timeout -k 5 300 "$GODOT" --headless --audio-driver Dummy --path "$ROOT" --import >/dev/null 2>&1 && break
done
[[ "${1:-}" == "--" ]] && shift
exec "$GODOT" --path "$ROOT" -- "$@"
