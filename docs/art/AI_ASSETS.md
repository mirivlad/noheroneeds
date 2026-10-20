# Сгенерированные ассеты: локальный SDXL (neyropix)

Проверено 20.10.2026 на лестнице из пещеры (`tools/art/generated/cave_ladder`).

## Когда

Только для того, чего нет в наборах LPC (сначала поиск на OpenGameArt, см.
[ART_STANDARD](ART_STANDARD.md), правило 6): одиночные вещи, предметы обстановки,
иконки. Не для людей и зверей: согласованные направления и анимации модель не
даёт, а LPC их даёт.

## Как

Инструмент — соседний проект `/home/mirivlad/git/neyropix` (SDXL Base 1.0 + LoRA
Pixel Art XL + SDXL VAE fp16-fix через stable-diffusion.cpp на Vulkan; инструкция —
его `CLAUDE.md`). Один запуск — около 4 минут, по одному (блокировка GPU), каждый
в новую папку:

```bash
cd /home/mirivlad/git/neyropix
.venv/bin/python scripts/sdxl.py --prompt "pixel art, a single <вещь>, top-down RPG game asset, 3/4 view, <материал и цвета>, isolated on a plain white background, simple flat colors" --seed 11401 --steps 20 --key-background --output "data/results/sdxl/nhn-<имя>-$(date +%Y%m%d-%H%M%S)"
```

Выход `keyed-128/transparent.png` — 128×128 (nearest из 1024): плотность близка к
LPC (тексель — пиксель экрана 960×540), вещь в клетку — около 30 px шириной.

## Что сделать с результатом

1. Посмотреть 1:1 и увеличенным: лишние пиксели, тени, «заплатки».
2. Убрать фон внутри замкнутых мест (между перекладинами и т.п.) — выделение по
   краю его не берёт; убрать тени и случайные точки.
3. **Переложить палитру** на рампу подходящего материала LPC (по яркости): у выхода
   модели сотни цветов, это не пиксель-арт без перекладки.
4. Обрезать по нарисованному; ширина — не больше клетки (32), если вещь в клетку.
5. Положить в `tools/art/generated/<имя>/`: `source.png` (выход), `report.json`,
   итоговый PNG и `PROVENANCE.md` (запрос, seed, модели и их лицензии, что правлено).
   Строка в импортёре; запись в титры (`FILE_CREDITS`).

## Лицензии

Модели: SDXL Base 1.0 — CreativeML OpenRAIL++-M, Pixel Art XL — CreativeML
OpenRAIL-M (ограничения на использование, выход не запрещён), VAE — MIT. В титрах
указываются модели и источник палитры.
