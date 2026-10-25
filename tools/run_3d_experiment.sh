#!/usr/bin/env bash
# The only 3D-experiment file in main. Never checks out or edits this worktree.
# Usage: tools/run_3d_experiment.sh [--2d] [experiment options]
set -euo pipefail

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
command -v git >/dev/null || die 'Для запуска нужен Git.'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'Скрипт должен находиться в рабочей копии No Hero Needed.'
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
DEST="$(dirname -- "$ROOT")/noheroneeds-3d"
BRANCH='experiment/3d-world'
REMOTE="refs/remotes/origin/$BRANCH"
[[ "$DEST" != "$ROOT" ]] || die 'Запустите вспомогательный скрипт из основной рабочей копии.'
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || die 'Не найден remote origin с репозиторием на GitHub.'

printf 'Проверяю ветку %s на origin…\n' "$BRANCH"
if REMOTE_HEAD=$(git -C "$ROOT" ls-remote --exit-code --heads origin "refs/heads/$BRANCH"); then
  REMOTE_HEAD=${REMOTE_HEAD%%[[:space:]]*}
else
  CODE=$?
  if [[ $CODE == 2 ]]; then
    die "Ветка $BRANCH ещё не опубликована на GitHub. Основная рабочая копия не изменена."
  fi
  die 'Не удалось проверить GitHub. Проверьте сеть и доступ Git к origin.'
fi
LOCAL_REMOTE=$(git -C "$ROOT" rev-parse --verify "$REMOTE" 2>/dev/null || true)
if [[ "$LOCAL_REMOTE" != "$REMOTE_HEAD" ]]; then
  git -C "$ROOT" fetch --no-tags origin "refs/heads/$BRANCH:$REMOTE" || die 'Не удалось получить экспериментальную ветку; локальные файлы сохранены.'
fi

if [[ -e "$DEST" || -L "$DEST" ]]; then
  [[ -d "$DEST" && ! -L "$DEST" && -f "$DEST/.git" ]] || die "Каталог $DEST уже занят. Файлы не изменены; освободите это имя вручную."
  OTHER_COMMON=$(git -C "$DEST" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "$DEST не является доступным worktree."
  [[ "$OTHER_COMMON" == "$COMMON" ]] || die "$DEST относится к другому репозиторию. Файлы не изменены."
  [[ "$(git -C "$DEST" symbolic-ref --quiet --short HEAD || true)" == "$BRANCH" ]] || die "В $DEST выбрана другая ветка. Автоматическое переключение запрещено."
else
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$ROOT" worktree add "$DEST" "$BRANCH" || die 'Не удалось создать worktree. Возможно, экспериментальная ветка уже открыта в другом каталоге.'
  else
    git -C "$ROOT" worktree add -b "$BRANCH" "$DEST" "$REMOTE" || die 'Не удалось создать экспериментальную рабочую копию.'
  fi
fi

# Untracked files also count: an update must not replace somebody's work.
if [[ -n "$(git -C "$DEST" status --porcelain --untracked-files=all)" ]]; then
  die "В $DEST есть незакоммиченные изменения. Обновление и запуск остановлены: сохраните изменения в эксперименте и повторите команду."
fi
if [[ "$(git -C "$DEST" rev-parse HEAD)" != "$(git -C "$DEST" rev-parse "$REMOTE")" ]]; then
  if git -C "$DEST" merge-base --is-ancestor HEAD "$REMOTE"; then
    # --no-overwrite-ignore protects even ignored user files from incoming paths.
    git -C "$DEST" merge --ff-only --no-overwrite-ignore "$REMOTE" || die 'Безопасное обновление не удалось. Экспериментальные файлы сохранены.'
  else
    die "Локальная ветка $BRANCH содержит собственные коммиты или разошлась с GitHub. Автообновление остановлено; разрешите расхождение вручную."
  fi
fi

ENTRY="$DEST/tools/start_3d_experiment.sh"
[[ -f "$ENTRY" && ! -L "$ENTRY" ]] || die 'В экспериментальной ветке нет tools/start_3d_experiment.sh. Реализация эксперимента ещё не готова.'
# Stable across updates; independent of the main game's XDG dirs and profiles.
DATA="$(dirname -- "$DEST")/.noheroneeds-3d-data"
for DIR in "$DATA" "$DATA/data" "$DATA/config" "$DATA/cache" "$DATA/state"; do
  [[ ! -L "$DIR" ]] || die "Каталог данных $DIR является символической ссылкой. Запуск остановлен для защиты сохранений."
  mkdir -p -- "$DIR" || die "Не удалось подготовить отдельный каталог $DIR."
done
export XDG_DATA_HOME="$DATA/data" XDG_CONFIG_HOME="$DATA/config"
export XDG_CACHE_HOME="$DATA/cache" XDG_STATE_HOME="$DATA/state"
printf 'Рабочая копия: %s\nДанные эксперимента: %s\n' "$DEST" "$DATA"
cd -- "$DEST"
exec bash "$ENTRY" "$@"
