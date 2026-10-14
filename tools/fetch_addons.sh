#!/usr/bin/env bash
# Download the pinned native addons (not kept in git) and verify their checksum.
# Usage: tools/fetch_addons.sh [--force]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQLITE_VERSION="v4.9"
SQLITE_URL="https://github.com/2shady4u/godot-sqlite/releases/download/${SQLITE_VERSION}/addons.zip"
SQLITE_SHA256="95e91b72fe32984a84edaf6357a78753661f37a170cb362f5b948e0ede7c2cb0"
BIN="$ROOT/addons/godot-sqlite/bin"
MARK="$BIN/.version"

# Tell Godot about the extension before its first scan of a fresh checkout:
# otherwise Godot 4.7.2 discovers it mid-import and crashes on exit.
mkdir -p "$ROOT/.godot"
EXT_LIST="$ROOT/.godot/extension_list.cfg"
grep -qs "gdsqlite.gdextension" "$EXT_LIST" || echo "res://addons/godot-sqlite/gdsqlite.gdextension" >> "$EXT_LIST"

if [[ "${1:-}" != "--force" && -f "$MARK" && "$(cat "$MARK")" == "$SQLITE_VERSION" ]]; then
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "fetching godot-sqlite $SQLITE_VERSION"
curl -fsSL "$SQLITE_URL" -o "$TMP/addons.zip"
echo "$SQLITE_SHA256  $TMP/addons.zip" | sha256sum -c --quiet -
# Desktop binaries only; mobile and web are not targets yet.
unzip -q "$TMP/addons.zip" 'addons/godot-sqlite/bin/libgdsqlite.linux.*' \
  'addons/godot-sqlite/bin/libgdsqlite.windows.*' 'addons/godot-sqlite/bin/libgdsqlite.macos.*' -d "$TMP"
rm -rf "$BIN"
mkdir -p "$BIN"
cp -r "$TMP"/addons/godot-sqlite/bin/. "$BIN"/
echo "$SQLITE_VERSION" > "$MARK"
