# Монета (base:coin)

- **Инструмент:** локальный `neyropix` (`scripts/sdxl.py`), 20.10.2026; модели — SDXL Base 1.0
  (CreativeML OpenRAIL++-M), LoRA Pixel Art XL (nerijs, CreativeML OpenRAIL-M), SDXL VAE
  fp16-fix (MIT); stable-diffusion.cpp (MIT).
- **Запрос:** `pixel art, a single small stack of three gold coins, inventory icon, centered,
  front view, isolated on a plain white background, simple flat colors`; seed 11401, 20 шагов,
  `--key-background`.
- **Файлы:** `source.png` — выход `keyed-128/transparent.png`; `report.json` — отчёт (validated=true).
- **Правка** (`coin.png`, 32×32): модель нарисовала высокий столбик (22×66) — взята его верхняя
  часть (19×26, без масштабирования), убрана серая тень, 431 цвет переложен по яркости на 8 цветов
  золотого слитка Idylwild's Inventory (CC0).
