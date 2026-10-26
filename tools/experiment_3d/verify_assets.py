#!/usr/bin/env python3
"""Check the vendored source roster, CC0 records and all glTF dependencies."""
import hashlib
import json
from pathlib import Path
from urllib.parse import unquote
ROOT = Path(__file__).resolve().parents[2]
manifest = json.loads((ROOT/'assets/experiment_3d/manifest.json').read_text())
assert manifest['license'] == 'CC0-1.0'
for name, record in manifest['files'].items():
 path = ROOT/name
 assert not path.is_symlink() and path.is_file(), name
 assert hashlib.sha256(path.read_bytes()).hexdigest() == record['sha256'], name
 if path.suffix == '.gltf':
  doc = json.loads(path.read_text())
  for entry in doc.get('buffers', []) + doc.get('images', []):
   uri = entry.get('uri', '')
   if uri and not uri.startswith('data:'):
    dep = (path.parent/unquote(uri)).resolve()
    dep.relative_to(ROOT/'assets/experiment_3d')
    assert str(dep.relative_to(ROOT)) in manifest['files'], str(dep)
for pack in manifest['packs']:
 assert b'CC0' in (ROOT/'assets/experiment_3d'/pack/'LICENSE.txt').read_bytes()
catalog = json.loads((ROOT/'assets/experiment_3d/catalog.json').read_text())
used = {entry['path'] for entry in catalog.values()}
models = {str(Path(name).relative_to('assets/experiment_3d')) for name in manifest['files'] if name.endswith('.gltf')}
assert used == models, (used-models, models-used)
print(f'ASSETS_VERIFIED: {len(manifest["packs"])} CC0 packs, {len(models)} used models, {len(manifest["files"])} source files')
