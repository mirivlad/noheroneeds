#!/usr/bin/env python3
"""Dependency setup safety using real pinned libraries and a network-denying curl."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class AddonSetupTest(unittest.TestCase):
 def setUp(self):
  self.tmp = tempfile.TemporaryDirectory(prefix='nhn-addon-')
  self.base = Path(self.tmp.name); self.exp = self.base/'noheroneeds-3d'; self.main = self.base/'noheroneeds'
  self.bin = self.exp/'addons/godot-sqlite/bin'; self.source = self.main/'addons/godot-sqlite/bin'
  self.source.mkdir(parents=True); (self.exp/'tools/experiment_3d').mkdir(parents=True)
  self.script = self.exp/'tools/experiment_3d/prepare_addons.sh'; shutil.copy2(ROOT/'tools/experiment_3d/prepare_addons.sh',self.script)
  for build in ['debug','release']:
   name=f'libgdsqlite.linux.template_{build}.x86_64.so';shutil.copy2(ROOT/'addons/godot-sqlite/bin'/name,self.source/name)
  fake=self.base/'fake';fake.mkdir();(fake/'curl').write_text('#!/bin/sh\nexit 75\n');(fake/'curl').chmod(0o755)
  self.env={**os.environ,'PATH':str(fake)+':'+os.environ['PATH'],'XDG_CACHE_HOME':str(self.base/'cache')}
 def tearDown(self):self.tmp.cleanup()
 def run_setup(self):return subprocess.run(['bash',str(self.script)],env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 def test_installed_libraries_are_reused_and_unrelated_files_preserved(self):
  self.bin.mkdir(parents=True);(self.bin/'user-note').write_text('keep')
  r=self.run_setup();self.assertEqual(r.returncode,0,r.stdout)
  installed={p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.bin.iterdir()}
  r=self.run_setup();self.assertEqual(r.returncode,0,r.stdout)
  self.assertEqual(installed,{p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.bin.iterdir()})
  cfg=(self.exp/'.godot/extension_list.cfg').read_text();self.assertEqual(cfg.count('gdsqlite.gdextension'),1)
 def test_modified_binary_is_never_replaced(self):
  self.bin.mkdir(parents=True);p=self.bin/'libgdsqlite.linux.template_debug.x86_64.so';p.write_bytes(b'my library')
  r=self.run_setup();self.assertNotEqual(r.returncode,0);self.assertIn('замена запрещена',r.stdout);self.assertEqual(p.read_bytes(),b'my library')
 def test_dependency_directory_symlink_is_refused(self):
  self.bin.parent.mkdir(parents=True);self.bin.symlink_to(self.source,target_is_directory=True)
  r=self.run_setup();self.assertNotEqual(r.returncode,0);self.assertIn('Символическая',r.stdout);self.assertFalse((self.source/'.version').exists())
 def test_invalid_source_is_preserved_on_download_failure(self):
  p=self.source/'libgdsqlite.linux.template_debug.x86_64.so';p.write_bytes(b'personal')
  r=self.run_setup();self.assertNotEqual(r.returncode,0);self.assertIn('Не удалось скачать',r.stdout);self.assertEqual(p.read_bytes(),b'personal')

if __name__=='__main__':unittest.main(verbosity=2)
