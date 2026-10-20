# Бриф 002 — деревья и растения (лето)

**Зачем:** заменить заглушки деревьев, кустов и мелких растений. Размеры и формы — ART_STANDARD v2, раздел 6: **кроны из листовых гроздей, не шары; породы различаются силуэтом; кусты неровные, не подушки.** Образец — деревья на референсе и в пробе B4.

**Что сдавать:** по одному объекту на картинку, ровный фон **#FF00FF**, объект целиком, по центру, у основания немного свободного места. Каталог: `art_src/incoming/002/`.

| Файл | Объект | Итоговый спрайт |
|---|---|---|
| `oak.png` | дуб: широкая неровная крона из листовых гроздей, видны ветви | 56×72 |
| `oak_autumn.png` | тот же дуб осенью, охра | 56×72 |
| `birch.png` | берёза: тонкий наклонный белый ствол с чёрными штрихами, рыхлая светлая крона | 40×72 |
| `spruce.png` | ель: высокая, узкая, ярусы с провисающими краями | 34×76 |
| `bush.png` | неровный лиственный куст из гроздей | 24×16 |
| `berry_bush.png` | неровный куст с красными ягодами | 24×16 |
| `fern.png` | папоротник, веер листьев | 16×16 |
| `tall_grass.png` | пучок высокой травы | 16×16 |
| `reeds.png` | камыш с бурыми початками | 16×16 |
| `flowers_red.png`, `flowers_yellow.png`, `flowers_blue.png` | куртина из 3–4 цветков | 16×16 |

## Запрос (подставить объект и размер)

```
Pixel art game sprite of a single {OBJECT}, top-down three-quarter view, in the style of the
attached image: natural warm muted palette, grounded and not toy-like. Foliage built from
many small leaf clumps with dark gaps between them (not round balls), an uneven silhouette.
The image must look like a {W}x{H} pixel sprite enlarged 16 times: every sprite pixel is a
crisp square block of one flat color, no anti-aliasing, no blur. Up to 18 colors with rich
half-tones, daylight from the top-left. No outline, no shadow on the ground, nothing else
in the picture. Centered on a flat solid #FF00FF magenta background.
```

## Что проверить

- Силуэт читается и с маленького размера: прищуриться, глядя на уменьшенную картинку.
- Ствол дерева — в нижней средней части. Именно этой клеткой дерево стоит на земле.
- Нет теней на земле и обводки.
