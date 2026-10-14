# Бриф 001 — материалы (фактуры)

**Зачем:** из фактур инструмент делает плоские тайлы 16×16 (по 4 варианта), переходы между грунтами (16 тайлов на пару), наборы стен и кровли по соседям. Заменяют заглушки в `content/base/art/tiles.png`.

**Что сдавать:** по одной картинке на материал, квадрат 1024×1024, бесшовная по всем краям. Имя файла — из таблицы. Каталог: `art_src/incoming/001/`.

| Файл | Материал | Цвета (мастер-палитра) |
|---|---|---|
| `grass.png` | луговая трава сверху, вертикальные стебельки разных оттенков с жёлтым подтоном | grass |
| `grass_dry.png` | выгоревшая сухая трава | grass_dry |
| `dirt.png` | утоптанная земля с камешками | dirt |
| `moss.png` | лесной мох | moss |
| `forest_floor.png` | лесная подстилка: хвоя, листья, веточки | forest_floor, leaf_autumn |
| `sand.png` | речной песок | sand |
| `water.png` | спокойная вода пруда сверху, лёгкая рябь | water |
| `wood_wall_face.png` | передняя грань бревенчатой стены: широкие горизонтальные брёвна с тёмными стыками | log |
| `wood_wall_top.png` | верх бревенчатой стены (вид сверху на торцы и брёвна) | log |
| `stone_wall_face.png` | передняя грань каменной кладки | stone |
| `stone_wall_top.png` | верх каменной стены (вид сверху) | stone |
| `wood_floor.png` | дощатый пол сверху | plank |
| `roof_red.png` | черепичная кровля сверху (ряды черепицы) | roof_tile |
| `roof_thatch.png` | соломенная кровля сверху | thatch |

## Запрос (подставить материал)

```
Seamless tileable pixel art texture of {MATERIAL}, seen from above (top-down) for a cozy
16x16-tile life-sim sandbox game in the style of the attached image: natural, warm,
muted palette (olive greens, earthy browns, ochre accents), calm and grounded, not toy-like.
The whole image must look like a 64x64 pixel texture enlarged 16 times: every texture pixel
is a crisp square block of one flat color, no anti-aliasing, no blur, no gradients inside
blocks. 6-8 colors with rich half-tones, light natural texture (fine grain, fibres, joints),
soft daylight from the top-left. Tileable on all four edges. No objects, no text, no border,
no outline.
```

Для граней стен вместо «seen from above» пишем «front face of a wall, seen straight on».

## Что проверить при выборе

- Рисунок ровный, без крупного пятна, бросающегося в глаза при повторе.
- «Пиксели» читаются как квадраты, примерно одного размера.
- Цвет близок к рампе из таблицы. Точную подгонку сделает инструмент.
