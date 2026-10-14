#!/usr/bin/env bash
# Dedicated server. Usage: tools/run_server.sh [--world=PATH] [--port=N] [--max-players=N] ...
# (options: see src/server/server_main.gd). Env: GODOT (binary, default "godot").
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tools/fetch_addons.sh"
# New scripts (class names) are known only after an import.
"${GODOT:-godot}" --headless --audio-driver Dummy --path "$ROOT" --import >/dev/null 2>&1
CONSOLE=()
[[ -t 0 ]] && CONSOLE=(--console)  # type "stop" to stop cleanly
exec "${GODOT:-godot}" --headless --audio-driver Dummy --path "$ROOT" -s res://src/server/server_main.gd -- "${CONSOLE[@]}" "$@"
