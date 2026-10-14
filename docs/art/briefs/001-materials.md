# Бриф 001 — материалы (фактуры)

**Зачем:** из фактур инструмент делает плоские тайлы 16×16 (по 4 варианта), переходы между грунтами (16 тайлов на пару), наборы стен и кровли по соседям. Заменяют заглушки в `content/base/art/tiles.png`.

**Что сдавать:** по одной картинке на материал, квадрат 1024×1024, бесшовная по всем краям. Имя файла — из таблицы. Каталог: `art_src/incoming/001/`.

| Файл | Материал | Цвета (мастер-палитра) |
|---|---|---|
| `grass.png` | сочная луговая трава сверху | grass |
| `grass_dry.png` | выгоревшая сухая трава | grass_dry |
| `dirt.png` | утоптанная земля с камешками | dirt |
| `moss.png` | лесной мох | moss |
| `forest_floor.png` | лесная подстилка: хвоя, листья, веточки | forest_floor, leaf_autumn |
| `sand.png` | речной песок | sand |
| `water.png` | спокойная вода пруда сверху, лёгкая рябь | water |
| `wood_wall_face.png` | передняя грань бревенчатой стены (горизонтальные брёвна) | wood |
| `stone_wall_face.png` | передняя грань каменной кладки | stone |
| `wood_floor.png` | дощатый пол сверху | wood_light |
| `roof_red.png` | черепичная кровля сверху (ряды черепицы) | roof_red |
| `roof_thatch.png` | соломенная кровля сверху | thatch |

## Запрос (подставить материал)

```
Seamless tileable pixel art texture of {MATERIAL}, seen from above (top-down) for a cozy
16x16-tile farming and adventure game in the style of the attached image.
The whole image must look like a 64x64 pixel texture enlarged 16 times: every texture pixel
is a crisp square block of one flat color, no anti-aliasing, no blur, no gradients inside
blocks. 5-6 colors only, hue-shifted shading (cool shadows, warm highlights), soft daylight
from the top-left. Tileable on all four edges. No objects, no text, no border, no outline.
```

Для граней стен вместо «seen from above» пишем «front face of a wall, seen straight on».

## Что проверить при выборе

- Рисунок ровный, без крупного пятна, бросающегося в глаза при повторе.
- «Пиксели» читаются как квадраты, примерно одного размера.
- Цвет близок к рампе из таблицы. Точную подгонку сделает инструмент.
