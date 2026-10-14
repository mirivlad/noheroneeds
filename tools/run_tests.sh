#!/usr/bin/env bash
# Run headless tests. Usage: tools/run_tests.sh [--only=path_part] [--test=name_part] [--bench]
# Env: GODOT (binary, default "godot"), TEST_TIMEOUT (seconds, default 600)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"
"$ROOT/tools/fetch_addons.sh" || exit 1
# Refresh imports and the global class cache (new class_name scripts).
# fetch_addons.sh registers the extension first, which avoids a crash of the
# very first import; a retry stays as a safety net.
for _ in 1 2; do
  timeout -k 5 300 "$GODOT" --headless --audio-driver Dummy --path "$ROOT" --import >/dev/null 2>&1 && break
done
OUT="$(timeout -k 5 "${TEST_TIMEOUT:-600}" "$GODOT" --headless --audio-driver Dummy --path "$ROOT" \
  -s res://tests/framework/run.gd -- "$@" 2>&1)"
CODE=$?
echo "$OUT" | grep -v '^\s*$' | grep -v '^Godot Engine'
[[ $CODE -eq 124 ]] && echo "TIMEOUT: tests did not finish"
# Script errors do not always fail a check; any engine error fails the run.
if echo "$OUT" | grep -q "SCRIPT ERROR\|^ERROR:"; then
  echo "engine errors detected"; CODE=1
fi
exit $CODE
