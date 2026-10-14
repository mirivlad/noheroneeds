# Бриф 002 — деревья и растения (лето)

**Зачем:** заменить заглушки деревьев, кустов и мелких растений. Размеры — в ART_STANDARD, раздел 5.

**Что сдавать:** по одному объекту на картинку, ровный фон **#FF00FF**, объект целиком, по центру, у основания немного свободного места. Каталог: `art_src/incoming/002/`.

| Файл | Объект | Итоговый спрайт |
|---|---|---|
| `oak.png` | раскидистый дуб, круглая крона | 48×64 |
| `birch.png` | берёза, белый ствол с чёрными штрихами, лёгкая крона | 48×64 |
| `spruce.png` | ель ярусами | 48×64 |
| `bush.png` | круглый лиственный куст | 16×16 |
| `berry_bush.png` | куст с красными ягодами | 16×16 |
| `fern.png` | папоротник, веер листьев | 16×16 |
| `tall_grass.png` | пучок высокой травы | 16×16 |
| `reeds.png` | камыш с бурыми початками | 16×16 |
| `flowers_red.png`, `flowers_yellow.png`, `flowers_blue.png` | куртина из 3–4 цветков | 16×16 |

## Запрос (подставить объект и размер)

```
Pixel art game sprite of a single {OBJECT}, top-down three-quarter view (like Stardew Valley),
in the style of the attached image. The image must look like a {W}x{H} pixel sprite enlarged
16 times: every sprite pixel is a crisp square block of one flat color, no anti-aliasing,
no blur. Limited palette (max 14 colors), hue-shifted shading, daylight from the top-left.
No outline, no shadow on the ground, nothing else in the picture.
Centered on a flat solid #FF00FF magenta background.
```

## Что проверить

- Силуэт читается и с маленького размера: прищуриться, глядя на уменьшенную картинку.
- Ствол дерева — в нижней средней части. Именно этой клеткой дерево стоит на земле.
- Нет теней на земле и обводки.
