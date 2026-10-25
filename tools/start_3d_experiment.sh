#!/usr/bin/env bash
# Experiment implementation. The main-branch launcher prepares its worktree.
set -euo pipefail
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DATA="$(dirname -- "$ROOT")/.noheroneeds-3d-data"
for DIR in "$DATA" "$DATA/data" "$DATA/config" "$DATA/cache" "$DATA/state"; do
  [[ ! -L "$DIR" ]] || die "Каталог $DIR является символической ссылкой; запуск остановлен."
  mkdir -p -- "$DIR"
done
export XDG_DATA_HOME="$DATA/data" XDG_CONFIG_HOME="$DATA/config"
export XDG_CACHE_HOME="$DATA/cache" XDG_STATE_HOME="$DATA/state"
for CMD in timeout flock; do command -v "$CMD" >/dev/null || die "Не установлена зависимость: $CMD."; done
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null || die 'Нужен Godot 4.7.2. Установите его или укажите GODOT=/путь/к/godot.'
VERSION=$("$GODOT" --version) || die 'Не удалось проверить версию Godot.'
[[ "$VERSION" == 4.7.2.* ]] || die "Нужен Godot 4.7.2, найден $VERSION."
exec 9>"$DATA/run.lock"
flock -n 9 || die 'Эксперимент уже запущен. Закройте его окно перед повторным запуском.'
MODE='3d'
PROFILE='experiment-3d'
ARGS=()
for ARG in "$@"; do
  case "$ARG" in
    --2d) MODE='2d' ;;
    --quality) PROFILE='experiment-3d-quality'; ARGS+=("--quality") ;;
    --profile*|--world*|--connect*|--server*|--renderer*|--demo*) die "Параметр $ARG запрещён: launcher использует отдельный профиль и мир." ;;
    *) ARGS+=("$ARG") ;;
  esac
done
bash "$ROOT/tools/experiment_3d/prepare_addons.sh" || die 'Не удалось подготовить godot-sqlite; существующие файлы сохранены.'
LOG="$DATA/cache/import.log"
printf 'Подготавливаю импорт Godot (установленные ресурсы используются повторно)…\n'
IMPORTED=false
for _ in 1 2; do
  if timeout -k 5 300 "$GODOT" --headless --audio-driver Dummy --path "$ROOT" --import >"$LOG" 2>&1; then IMPORTED=true; break; fi
done
if [[ "$IMPORTED" != true ]] || grep -q 'SCRIPT ERROR\|^ERROR:' "$LOG"; then
  tail -n 35 "$LOG" >&2
  die "Godot не смог импортировать эксперимент. Журнал: $LOG"
fi
printf 'Запускаю %s-эксперимент. Отдельный профиль: %s.\n' "$MODE" "$PROFILE"
cd -- "$ROOT"
"$GODOT" --path "$ROOT" -- "${ARGS[@]}" --profile="$PROFILE" --world="$PROFILE" --renderer="$MODE" || die 'Godot завершился с ошибкой; сохранения основной игры не затронуты.'
