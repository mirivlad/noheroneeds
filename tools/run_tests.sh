#!/usr/bin/env bash
# Run headless tests. Usage: tools/run_tests.sh [--only=path_part] [--test=name_part] [--bench] [--test_limit=S]
# Env: GODOT (binary, default "godot"), TEST_TIMEOUT (seconds, default 1200),
#      TEST_OUTPUT_MAX (bytes of output kept, default 20 MB: past it the run is stopped).
# Broken code fails fast: scripts that do not compile stop the run before any
# test; a test that floods errors or runs too long stops it (tests/framework/run.gd).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"
LOG="$(mktemp -t noheroneeds-tests.XXXXXX)"
trap 'rm -f "$LOG"' EXIT
"$ROOT/tools/fetch_addons.sh" || exit 1
# Refresh imports and the global class cache (new class_name scripts).
# fetch_addons.sh registers the extension first, which avoids a crash of the
# very first import; a retry stays as a safety net.
for _ in 1 2; do
  timeout -k 5 300 "$GODOT" --headless --audio-driver Dummy --path "$ROOT" --import >"$LOG" 2>&1 && break
done
# Scripts that do not compile: no test could tell more than this.
if grep -q "Parse Error\|Compile Error" "$LOG"; then
  echo "SCRIPTS DO NOT COMPILE:"
  grep -A1 "Parse Error\|Compile Error" "$LOG" | grep -v '^--$' | head -40
  exit 1
fi
# Output goes to a file, not a shell variable, and only so much of it is kept.
MAX="${TEST_OUTPUT_MAX:-20000000}"
timeout -k 5 "${TEST_TIMEOUT:-1200}" "$GODOT" --headless --audio-driver Dummy --path "$ROOT" \
  -s res://tests/framework/run.gd -- "$@" 2>&1 | head -c "$MAX" >"$LOG"
CODE=${PIPESTATUS[0]}
grep -v '^\s*$' "$LOG" | grep -v '^Godot Engine'
[[ $CODE -eq 124 ]] && echo "TIMEOUT: tests did not finish"
(( $(stat -c %s "$LOG") >= MAX )) && { echo "OUTPUT FLOOD: over $MAX bytes, the run was stopped"; CODE=1; }
# Script errors do not always fail a check; any engine error fails the run,
# except those tests caused on purpose (expect_errors; the runner counts them).
ERRS=$(grep -c "SCRIPT ERROR\|^ERROR:" "$LOG")
EXPECTED=$(sed -n 's/^expected engine errors: \([0-9]*\)$/\1/p' "$LOG")
if (( ERRS > ${EXPECTED:-0} )); then
  echo "engine errors detected"; CODE=1
fi
(( CODE == 0 )) && grep -q "STOPPED: the run was ended early" "$LOG" && CODE=1
exit $CODE
