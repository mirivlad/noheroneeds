#!/usr/bin/env python3
"""Reproduce the small vendored CC0 selection from the four FREE archives.
Usage: python3 tools/experiment_3d/import_assets.py /directory/with/{nature,village,resource,dungeon}.zip
Archives are never extracted wholesale; only selected glTF files and their dependencies.
"""
import hashlib
import json
import pathlib
import sys
import urllib.parse
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEST = ROOT / 'assets/experiment_3d'
PACKS = {
 'nature': ('Quaternius', 'https://quaternius.itch.io/stylized-nature-megakit', ['CommonTree_1', 'CommonTree_3', 'Pine_2', 'DeadTree_1', 'Bush_Common', 'Bush_Common_Flowers', 'Flower_3_Group', 'Fern_1', 'Grass_Common_Short', 'Mushroom_Common', 'Rock_Medium_1', 'Pebble_Round_1']),
 'village': ('Quaternius', 'https://quaternius.com/packs/medievalvillagemegakit.html', ['Wall_Plaster_Straight', 'Wall_Plaster_Window_Wide_Flat', 'Door_1_Flat', 'Floor_WoodDark', 'Roof_RoundTiles_4x4', 'Stair_Interior_Simple']),
 'resource': ('Kay Lousberg', 'https://kaylousberg.itch.io/resource-bits', ['Wood_Log_A', 'Stone_Chunks_Large', 'Iron_Nugget_Large', 'Copper_Nugget_Large', 'Silver_Nugget_Large', 'Gold_Nugget_Large']),
 'dungeon': ('Kay Lousberg', 'https://kaylousberg.itch.io/kaykit-dungeon-pack', ['wall', 'floor_tile_large', 'stairs', 'chest', 'table_medium', 'torch_lit', 'barrel_small']),
}

def digest(data):
 return hashlib.sha256(data).hexdigest()

def run(source):
 manifest = {'license': 'CC0-1.0', 'packs': {}, 'files': {}}
 for key, (author, url, models) in PACKS.items():
  archive = source / (key + '.zip')
  with zipfile.ZipFile(archive) as z:
   names = z.namelist()
   license_path = next(n for n in names if 'license' in n.lower())
   license_bytes = z.read(license_path)
   if b'CC0' not in license_bytes:
    raise ValueError(f'{key}: archive does not contain a CC0 license')
   chosen = []
   for model in models:
    name = next(n for n in names if pathlib.PurePosixPath(n).name == model + '.gltf')
    chosen.append(name)
    doc = json.loads(z.read(name))
    for item in doc.get('buffers', []) + doc.get('images', []):
     uri = item.get('uri', '')
     if uri and not uri.startswith('data:'):
      chosen.append(str(pathlib.PurePosixPath(name).parent / urllib.parse.unquote(uri)))
   base = pathlib.PurePosixPath(chosen[0]).parent
   # All selected upstream models share one glTF directory.
   for name in sorted(set(chosen)):
    rel = pathlib.PurePosixPath(name).relative_to(base)
    if '..' in rel.parts or rel.is_absolute():
     raise ValueError('Unsafe archive path: ' + name)
    dest = DEST / key / rel
    data = z.read(name)
    if dest.is_symlink() or (dest.exists() and dest.read_bytes() != data):
     raise ValueError('Refusing to overwrite different existing file: ' + str(dest))
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    manifest['files'][str(dest.relative_to(ROOT))] = {'sha256': digest(data), 'source': name, 'pack': key}
   (DEST / key / 'LICENSE.txt').write_bytes(license_bytes)
   manifest['files'][f'assets/experiment_3d/{key}/LICENSE.txt'] = {'sha256': digest(license_bytes), 'source': license_path, 'pack': key}
   manifest['packs'][key] = {'author': author, 'url': url, 'edition': 'Standard FREE' if key in ['nature', 'village'] else 'FREE', 'archive_sha256': digest(archive.read_bytes()), 'models': models}
 (DEST / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
 print(f'Vendored {sum(len(v[2]) for v in PACKS.values())} CC0 models with {len(manifest["files"])} hashed files')

if __name__ == '__main__':
 run(pathlib.Path(sys.argv[1]))
