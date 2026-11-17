from pathlib import Path
import hashlib
import json
import os
import queue
import re
import signal
import sqlite3
import subprocess
import tarfile
import threading
import time
import zipfile

root = Path.cwd()
release = root / 'build/release-v0.21.0/assets'
version = '0.21.0'
names = [f'noheroneeds-{version}-linux-x86_64.tar.gz', f'noheroneeds-{version}-windows-portable.zip',
         f'noheroneeds-{version}-windows-setup.exe', f'noheroneeds_{version}_amd64.deb']
expected = {}
for line in (release / 'SHA256SUMS').read_text().splitlines():
    sha, name = line.split(maxsplit=1)
    name = name.lstrip('*')
    assert Path(name).name == name
    expected[name] = sha
assert set(expected) == set(names), expected
for name, sha in expected.items():
    assert hashlib.sha256((release / name).read_bytes()).hexdigest() == sha, name

with zipfile.ZipFile(release / names[1]) as archive:
    assert archive.testzip() is None
    executable = next(n for n in archive.namelist() if n.endswith('/noheroneeds.exe'))
    assert archive.read(executable)[:2] == b'MZ'
    assert any(n.lower().endswith('.dll') for n in archive.namelist())
assert (release / names[2]).read_bytes()[:2] == b'MZ'
deb_version = subprocess.check_output(['dpkg-deb', '-f', str(release / names[3]), 'Version'], text=True).strip()
assert deb_version == version

out = root / 'build/release-v0.21.0/smoke'
out.mkdir(exist_ok=True)
assert not (out / 'world.db').exists(), 'Use a fresh disposable smoke directory'
with tarfile.open(release / names[0]) as archive:
    archive.extractall(out, filter='data')
binary = out / f'noheroneeds-{version}/noheroneeds.x86_64'
assert binary.is_file()
stop = out / 'STOP'
args = [str(binary), '--headless', '--audio-driver', 'Dummy', '--', '--server', '--world=' + str(out / 'world.db'),
        '--identity=' + str(out / 'server-key'), '--seed=7', '--preset=small', '--climate=temperate',
        '--port=42621', '--stop-file=' + str(stop)]
began = time.monotonic()
server_log = out / 'server.log'
with server_log.open('w') as stream:
    process = subprocess.Popen(args, stdout=stream, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        ready_seconds = None
        while time.monotonic() - began < 300:
            assert process.poll() is None, 'Exported server exited before its first view'
            try:
                connection = sqlite3.connect(f'file:{out / "world.db"}?mode=ro', uri=True)
                count = connection.execute('SELECT COUNT(*) FROM chunks').fetchone()[0]
                connection.close()
                if count >= 25:
                    ready_seconds = time.monotonic() - began
                    break
            except sqlite3.Error:
                pass
            time.sleep(.1)
        assert ready_seconds is not None, 'Exported server never persisted its spawn view'
        bot_env = dict(os.environ, XDG_DATA_HOME=str(out / 'client-profile'))
        bot = subprocess.run(['/home/mirivlad/.local/bin/godot', '--headless', '--audio-driver', 'Dummy', '--path', str(root),
                              '-s', 'res://tests/support/load_bots.gd', '--', '--connect=127.0.0.1:42621',
                              '--bots=1', '--seconds=10'], env=bot_env, capture_output=True, text=True, timeout=60)
        (out / 'client.log').write_text(bot.stdout + bot.stderr)
        match = re.search(r'^BOTS (\{.*\})$', bot.stdout, re.M)
        assert bot.returncode == 0 and match, bot.stdout + bot.stderr
        client_result = json.loads(match[1])
        assert int(client_result['playing']) == 1 and int(client_result['acks']) > 0, client_result
        assert int(client_result['unanswered']) <= 1, client_result
        stop.touch()
        code = process.wait(timeout=15)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
lines = server_log.read_text()
assert code == 0, (code, lines[-2000:])
assert not re.search(r'^(?:ERROR:|SCRIPT ERROR)', lines, re.M), lines[-2000:]
con = sqlite3.connect(f'file:{out / "world.db"}?mode=ro', uri=True)
created_with = con.execute('SELECT value FROM meta WHERE key="created_with"').fetchone()[0]
assert created_with == version, created_with
assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
chunks = con.execute('SELECT COUNT(*) FROM chunks').fetchone()[0]
assert chunks > 0
con.close()
report = {'version': version, 'sha256_verified': expected, 'windows_zip_crc_ok': True, 'windows_pe_headers_ok': True,
          'debian_version': deb_version, 'linux_server_exit_code': code, 'linux_ready_seconds': round(ready_seconds, 3),
          'readiness': 'saved spawn view followed by a live ENet client; no dependency on exported stdout', 'enet_client': client_result, 'stdout_bytes': len(lines.encode()), 'created_with': created_with, 'sqlite_integrity': 'ok', 'saved_chunks': chunks}
(root / 'build/release-v0.21.0/artifact-check.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
