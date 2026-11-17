from pathlib import Path
import os, sqlite3, subprocess, json, re
root = Path.cwd()
out = root / 'build/release-v0.21.0'
profile = out / 'graphical-data/noheroneeds/profiles/default'
world = profile / 'worlds/release/world.db'
assert not world.exists(), 'Use a fresh disposable graphical profile'
world.parent.mkdir(parents=True)
source = sqlite3.connect(f'file:{out / "smoke/world.db"}?mode=ro', uri=True)
target = sqlite3.connect(world)
source.backup(target)
target.close()
source.close()
binary = out / 'smoke/noheroneeds-0.21.0/noheroneeds.x86_64'
image = out / 'exported-game.png'
env = dict(os.environ, DISPLAY=':0.0', XDG_DATA_HOME=str(out / 'graphical-data'))
args = [str(binary), '--audio-driver', 'Dummy', '--resolution', '960x540', '--',
        '--world=release', '--body=base:human_ro_m',
        '--time=12', '--weather=clear', '--frames=6000', '--screenshot=' + str(image)]
result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
(out / 'exported-graphical.log').write_text(result.stdout)
assert result.returncode == 0, result.stdout[-3000:]
assert not re.search(r'^(?:ERROR:|SCRIPT ERROR)', result.stdout, re.M), result.stdout[-3000:]
assert image.is_file()
frames = [json.loads(v) for v in re.findall(r'^EXPERIMENT_3D (\{.*\})$', result.stdout, re.M)]
from PIL import Image
with Image.open(image) as picture:
    assert picture.size == (960, 540), picture.size
    assert any(lo != hi for lo, hi in picture.convert('RGB').getextrema()), 'Empty screenshot'
report = {'artifact': binary.parent.name, 'exit_code': result.returncode, 'scenario': 'Disposable SQLite backup of exported server seed 7; ordinary App with RO character, noon and clear weather; screenshot after 6000 frames.', 'last_renderer_diagnostic': frames[-1] if frames else None, 'requires_visual_review': True, 'note': 'Functional exported graphical smoke test, not an FPS benchmark.'}
(out / 'graphical.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
