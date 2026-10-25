#!/usr/bin/env python3
"""Check native GPU captures; never rescale images for the measurements."""
import json
from pathlib import Path
import sys
from PIL import Image

root = Path(sys.argv[1])
composition = json.loads((root / 'sprites.json').read_text())
assert len(composition) == 8 and all(x['composition_bytes_equal'] for x in composition)
results = []
for path in sorted(root.glob('*-2d.png')):
    reference = Image.open(path).convert('RGBA')
    actual = Image.open(path.with_name(path.name.replace('-2d', '-3d'))).convert('RGBA')
    assert reference.size == actual.size
    pairs = list(zip(reference.getdata(), actual.getdata()))
    mask_diff = sum((a[3] > 0) != (b[3] > 0) for a, b in pairs)
    max_alpha = max(abs(a[3] - b[3]) for a, b in pairs)
    max_rgb = max(abs(a[i] - b[i]) for a, b in pairs if a[3] for i in range(3))
    result = {'name': path.stem.removesuffix('-2d'), 'mask_difference': mask_diff,
              'max_alpha_error': max_alpha, 'max_rgb_error_255': max_rgb,
              'reference_bounds': reference.getbbox(), 'actual_bounds': actual.getbbox()}
    results.append(result)
    assert mask_diff == 0 and max_alpha == 0 and max_rgb <= 2, result
assert len(results) == 8
(root / 'pixel-comparison.json').write_text(json.dumps(results, indent=2) + '\n')
rows = ''.join(f'<tr><td>{x["name"]}</td><td><img src="{x["name"]}-2d.png"></td>'
               f'<td><img src="{x["name"]}-3d.png"></td></tr>' for x in results)
(root / 'comparison.html').write_text('<!doctype html><meta charset="utf-8"><title>LPC: 2D / 3D</title>'
    '<style>body{background:#35424a;color:#eee;font:18px sans-serif}img{width:384px;height:384px;image-rendering:pixelated}'
    'td{border:1px solid #61717b;text-align:center}</style><h1>Один и тот же персонаж: 2D / Sprite3D</h1>'
    '<p>Нативные GPU-кадры увеличены CSS ×2 с nearest. Измерения сделаны до увеличения.</p>'
    '<table><tr><th>Вид</th><th>Штатная 2D-сборка, камера ×2</th><th>3D, 32 пикселя/метр</th></tr>' + rows + '</table>')
print('SPRITES_VERIFIED: 8 directions, identical alpha/silhouettes, RGB error <= 2/255')
