#!/usr/bin/env bash
# Pinned Linux dependency installation without removing/replacing user files.
set -euo pipefail
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "$(uname -s):$(uname -m)" == Linux:x86_64 ]] || die 'Этот эксперимент проверен для Linux x86_64.'
BIN="$ROOT/addons/godot-sqlite/bin"
CACHE="${XDG_CACHE_HOME:?}/noheroneeds-3d"
for DIR in "$ROOT/.godot" "$ROOT/addons" "$ROOT/addons/godot-sqlite" "$BIN" "$CACHE"; do
  [[ ! -L "$DIR" ]] || die "Символическая ссылка в каталоге $DIR: автоматическая подготовка остановлена."
  mkdir -p -- "$DIR"
done
command -v sha256sum >/dev/null || die 'Нужна утилита sha256sum.'
DEBUG_SHA='a2fa1dddab744135a3ce0f16da6a84d41ec981ffc85560ecb3abf54d9ad4c393'
RELEASE_SHA='6bc7d4f045ba1903c08931a4f8f39be6a5424d37971d3f3a068f618846fc21ec'
ARCHIVE_SHA='95e91b72fe32984a84edaf6357a78753661f37a170cb362f5b948e0ede7c2cb0'
valid() { [[ -f "$1" && ! -L "$1" ]] && [[ "$(sha256sum -- "$1" | cut -d ' ' -f 1)" == "$2" ]]; }
TMP=''
trap '[[ -z "$TMP" ]] || rm -rf -- "$TMP"' EXIT
for BUILD in debug release; do
  NAME="libgdsqlite.linux.template_$BUILD.x86_64.so"
  SHA=$DEBUG_SHA
  [[ "$BUILD" != release ]] || SHA=$RELEASE_SHA
  if valid "$BIN/$NAME" "$SHA"; then continue; fi
  [[ ! -e "$BIN/$NAME" && ! -L "$BIN/$NAME" ]] || die "Файл $BIN/$NAME отличается от проверенной версии. Он сохранён; автоматическая замена запрещена."
  # Reuse an installed pinned library from the primary checkout, read-only.
  SOURCE="$(dirname -- "$ROOT")/noheroneeds/addons/godot-sqlite/bin/$NAME"
  if valid "$SOURCE" "$SHA"; then
    cp -n -- "$SOURCE" "$BIN/$NAME"
    continue
  fi
  ZIP="$CACHE/godot-sqlite-v4.9.zip"
  if ! valid "$ZIP" "$ARCHIVE_SHA"; then
    [[ ! -e "$ZIP" && ! -L "$ZIP" ]] || die "Кэш $ZIP повреждён или изменён; файл сохранён."
    for CMD in curl unzip; do command -v "$CMD" >/dev/null || die "Для первой установки нужен $CMD."; done
    TMP="$(mktemp -d "$CACHE/install.XXXXXX")"
    printf 'Скачиваю проверенную зависимость godot-sqlite v4.9…\n'
    curl -fsSL --connect-timeout 15 --max-time 300 'https://github.com/2shady4u/godot-sqlite/releases/download/v4.9/addons.zip' -o "$TMP/addons.zip" || die 'Не удалось скачать godot-sqlite; проверьте соединение с GitHub.'
    valid "$TMP/addons.zip" "$ARCHIVE_SHA" || die 'Контрольная сумма godot-sqlite не совпала.'
    cp -n -- "$TMP/addons.zip" "$ZIP"
  fi
  [[ -n "$TMP" ]] || TMP="$(mktemp -d "$CACHE/install.XXXXXX")"
  unzip -p "$ZIP" "addons/godot-sqlite/bin/$NAME" > "$TMP/$NAME" || die 'Не удалось прочитать библиотеку из архива.'
  valid "$TMP/$NAME" "$SHA" || die 'Контрольная сумма библиотеки не совпала.'
  cp -n -- "$TMP/$NAME" "$BIN/$NAME"
done
[[ ! -L "$BIN/.version" && ! -L "$ROOT/.godot/extension_list.cfg" ]] || die 'Файл состояния зависимости является символической ссылкой.'
if [[ ! -e "$BIN/.version" ]]; then printf 'v4.9\n' > "$BIN/.version"; fi
EXT_LIST="$ROOT/.godot/extension_list.cfg"
grep -qs 'gdsqlite.gdextension' "$EXT_LIST" || printf 'res://addons/godot-sqlite/gdsqlite.gdextension\n' >> "$EXT_LIST"
