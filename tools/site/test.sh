#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
python3 tools/site/check.py "${@}"
python3 -m unittest discover -s tools/site/tests -v
npm --prefix site run check
npm --prefix site test
