#!/usr/bin/env bash
# Overview maps of worlds (ADR-0049): tools/world_map.sh --seed=1,2,3 [--regions=1] [--out=DIR] [--detail=512] [--villages=R]
# Writes world-<seed>.png (the regions round spawn a pixel a chunk, x2), -climate.png and, with --detail, a
# piece round spawn cell by cell. Env: GODOT (binary, default "godot").
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"
"$ROOT/tools/fetch_addons.sh" >/dev/null || exit 1
for _ in 1 2; do
  timeout -k 5 300 "$GODOT" --headless --audio-driver Dummy --path "$ROOT" --import >/dev/null 2>&1 && break
done
# A script error does not end Godot by itself: the first one stops the run.
LOG="$(mktemp -t world-map.XXXXXX)"; trap 'rm -f "$LOG"' EXIT
timeout -k 5 "${MAP_TIMEOUT:-300}" "$GODOT" --headless --audio-driver Dummy --path "$ROOT" -s res://tools/world_map.gd -- "$@" >"$LOG" 2>&1 &
PID=$!
while kill -0 "$PID" 2>/dev/null; do
  if grep -q "SCRIPT ERROR\|Parse Error" "$LOG"; then sleep 1; kill "$PID" 2>/dev/null; pkill -P "$PID" 2>/dev/null; break; fi
  sleep 1
done
wait "$PID" 2>/dev/null
grep -v '^\s*$' "$LOG" | grep -v '^Godot Engine'
! grep -q "SCRIPT ERROR\|Parse Error" "$LOG"
