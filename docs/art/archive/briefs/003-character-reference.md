# Бриф 003 — эталоны персонажа

**Зачем:** это **не готовые спрайты, а эталоны образа.** По ним инструмент перенесёт цвета и рисунок на шаблон тела **A1 — 18×32, около 3 голов** (кадр 48×48, 8 направлений), чтобы все слои бумажной куклы совпадали попиксельно (ADR-0008, стандарт v2, раздел 8). Образец — люди на референсе и в пробе B4: жители мира, а не игрушки, без кукольности.

**Что сдавать:** каждая картинка — **4 ракурса в один ряд, слева направо:** спереди, три четверти спереди-справа, справа, сзади. Ровный фон **#FF00FF**, одинаковый рост и одинаковая линия ступней во всех ракурсах. Каталог: `art_src/incoming/003/`.

| Файл | Что | Примечание |
|---|---|---|
| `body.png` | базовое тело гуманоида в простом нижнем белье (майка и шорты нейтрального цвета), босиком, руки опущены | без причёски — голова гладкая, коротко остриженная |
| `hair_short.png`, `hair_long.png`, `hair_braid.png` | причёска на том же теле | только волосы контрастного цвета, одежда как в body |
| `outfit_villager.png` | льняная рубаха, рабочие штаны, сапоги, пояс | на том же теле, без причёски |
| `outfit_baker.png` | куртка, светлая рубаха, фартук | на том же теле |
| `outfit_elder.png` | жилет, рубаха, ремень с сумкой | на том же теле, старческая осанка допустима |
| `faces.png` | только голова спереди, 6 эмоций в ряд: нейтрально, рад, грустит, сердит, удивлён, задумался | для глаз и рта в игре и для портретов |

## Запрос

```
Pixel art character reference sheet in the style of the attached image: a slightly
stylised villager {WHAT}, about 3 heads tall (not a big-headed chibi, not a doll): visible
neck, shoulders wider than the head, small dot eyes, simple calm everyday clothes, natural
muted warm colors.
Four views in one row, left to right: front, three-quarter front-right, right side, back.
Same height and same feet line in all views, arms relaxed. The image must look like
18x32 pixel sprites enlarged 16 times: crisp square blocks of flat color, no anti-aliasing,
no blur. Limited palette, hue-shifted shading, light from the top-left. No outline,
no shadow on the ground. Flat solid #FF00FF magenta background, nothing else.
```

Для `faces.png`: «six expressions of the same chibi face in one row: neutral, happy, sad, angry, surprised, thinking; head only, front view».

## Что проверить

- Около 3 голов роста, без кукольности, одинаково в 4 ракурсах. Пропорции важнее деталей.
- Вид сзади действительно сзади: лица не видно.
- Причёски и одежда надеты на одно и то же тело (сравнить с `body.png`).
