# Лестница из пещеры (base:cave_climb)

- **Инструмент:** локальный `neyropix` (`/home/mirivlad/git/neyropix`, `scripts/sdxl.py`),
  20.10.2026; модели — SDXL Base 1.0 (CreativeML OpenRAIL++-M), LoRA Pixel Art XL
  (nerijs, CreativeML OpenRAIL-M), SDXL VAE fp16-fix (MIT); stable-diffusion.cpp (MIT).
- **Запрос:** `pixel art, a single wooden ladder leaning upright, top-down RPG game asset,
  3/4 view, two side rails and five rungs, brown wood, isolated on a plain white
  background, simple flat colors`; seed 11401, 20 шагов, `--key-background`.
- **Файлы:** `source.png` — выход `keyed-128/transparent.png` (128×128, nearest из
  1024); `report.json` — отчёт генерации (validated=true).
- **Правка** (`cave_ladder.png`, 32×74): убраны белый фон между перекладинами, серая тень,
  серые скобы и зелёная точка; 1294 цвета переложены по яркости на 8 цветов дерева
  [LPC] Wooden Stairs (Nyom, CC-BY-SA 4.0).
