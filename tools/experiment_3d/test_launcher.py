#!/usr/bin/env python3
"""Real Git/worktree integration checks. No network, Godot or user saves."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

LAUNCHER = Path(__file__).resolve().parents[1] / 'run_3d_experiment.sh'

def git(root, *args):
 return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.STDOUT, text=True).strip()

class LauncherTest(unittest.TestCase):
 def setUp(self):
  self.tmp = tempfile.TemporaryDirectory(prefix='nhn-launcher-')
  self.base = Path(self.tmp.name)
  self.remote = self.base/'remote.git'; self.author = self.base/'author'; self.main = self.base/'noheroneeds'; self.work = self.base/'noheroneeds-3d'
  self.env = {**os.environ, 'GIT_CONFIG_NOSYSTEM':'1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_AUTHOR_NAME':'Test', 'GIT_AUTHOR_EMAIL':'test@example.invalid', 'GIT_COMMITTER_NAME':'Test', 'GIT_COMMITTER_EMAIL':'test@example.invalid'}
  self.run_cmd(['git','init','--bare',str(self.remote)])
  self.run_cmd(['git','init','-b','main',str(self.author)])
  (self.author/'tools').mkdir(); shutil.copy2(LAUNCHER,self.author/'tools/run_3d_experiment.sh')
  (self.author/'tracked').write_text('base\n'); (self.author/'.gitignore').write_text('.godot/\n')
  self.g(self.author,'add','.'); self.g(self.author,'commit','-m','base'); self.g(self.author,'remote','add','origin',str(self.remote)); self.g(self.author,'push','origin','main')
  self.run_cmd(['git','clone','-b','main',str(self.remote),str(self.main)])
  self.g(self.author,'switch','-c','experiment/3d-world')
  (self.author/'tools/start_3d_experiment.sh').write_text('#!/usr/bin/env bash\nset -eu\nprintf "%s\\n" "$PWD" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" > "$XDG_STATE_HOME/launched"\n')
  self.publish()
 def tearDown(self): self.tmp.cleanup()
 def run_cmd(self,args,ok=True,cwd=None):
  r=subprocess.run(args,cwd=cwd,env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  if ok and r.returncode: self.fail(r.stdout)
  return r
 def g(self,root,*args): return self.run_cmd(['git','-C',str(root),*args]).stdout.strip()
 def publish(self):
  self.g(self.author,'add','.'); self.g(self.author,'commit','-m','experiment'); self.g(self.author,'push','origin','experiment/3d-world')
 def launch(self,ok=True): return self.run_cmd([str(self.main/'tools/run_3d_experiment.sh')],ok=ok,cwd='/tmp')
 def snapshot(self):
  return (self.g(self.main,'symbolic-ref','HEAD'),self.g(self.main,'rev-parse','HEAD'),self.g(self.main,'diff','--binary'),self.g(self.main,'diff','--cached','--binary'),self.g(self.main,'status','--porcelain'),(self.main/'untracked').read_bytes() if (self.main/'untracked').exists() else b'')
 def test_create_repeat_update_preserves_primary_dirty_branch(self):
  self.g(self.main,'switch','-c','user-work'); (self.main/'tracked').write_text('staged\n');self.g(self.main,'add','tracked');(self.main/'tracked').write_text('unstaged\n');(self.main/'untracked').write_bytes(b'private')
  before=self.snapshot(); self.launch(); self.assertEqual(before,self.snapshot())
  self.assertEqual(self.g(self.work,'branch','--show-current'),'experiment/3d-world')
  receipt=(self.base/'.noheroneeds-3d-data/state/launched').read_text().splitlines(); self.assertEqual(receipt[0],str(self.work)); self.assertTrue(all(str(self.base/'.noheroneeds-3d-data') in p for p in receipt[1:]))
  (self.work/'.godot').mkdir();(self.work/'.godot/cache').write_text('cached');(self.author/'new_asset').write_text('asset');self.publish()
  self.launch();self.assertEqual(before,self.snapshot());self.assertEqual((self.work/'.godot/cache').read_text(),'cached');self.assertEqual((self.work/'new_asset').read_text(),'asset')
  head=self.g(self.work,'rev-parse','HEAD');self.launch();self.assertEqual(self.g(self.work,'rev-parse','HEAD'),head)
 def test_dirty_experiment_stops_without_overwrite(self):
  self.launch(); (self.work/'tracked').write_text('my changes');(self.work/'untracked').write_text('keep');(self.author/'tracked').write_text('remote');self.publish()
  old=self.g(self.work,'rev-parse','HEAD');r=self.launch(False);self.assertNotEqual(r.returncode,0);self.assertIn('незакоммиченные',r.stdout);self.assertEqual(old,self.g(self.work,'rev-parse','HEAD'));self.assertEqual((self.work/'tracked').read_text(),'my changes');self.assertEqual((self.work/'untracked').read_text(),'keep')
 def test_occupied_directory_preserved(self):
  self.work.mkdir();(self.work/'mine').write_text('keep');r=self.launch(False);self.assertNotEqual(r.returncode,0);self.assertEqual((self.work/'mine').read_text(),'keep')
 def test_missing_branch_does_not_create_worktree(self):
  self.g(self.author,'push','origin',':experiment/3d-world');r=self.launch(False);self.assertNotEqual(r.returncode,0);self.assertIn('ещё не опубликована',r.stdout);self.assertFalse(self.work.exists())
 def test_wrong_branch_refused(self):
  self.launch();self.g(self.work,'switch','-c','personal');r=self.launch(False);self.assertNotEqual(r.returncode,0);self.assertIn('другая ветка',r.stdout);self.assertEqual(self.g(self.work,'branch','--show-current'),'personal')
 def test_local_commits_preserved(self):
  self.launch();(self.work/'mine').write_text('keep');self.g(self.work,'add','.');self.g(self.work,'commit','-m','local');head=self.g(self.work,'rev-parse','HEAD');r=self.launch(False);self.assertNotEqual(r.returncode,0);self.assertEqual(head,self.g(self.work,'rev-parse','HEAD'))
 def test_ignored_user_file_is_not_replaced_by_update(self):
  (self.author/'.gitignore').write_text('private\n');self.publish();self.launch();(self.work/'private').write_text('keep');(self.author/'private').write_text('upstream');self.g(self.author,'add','-f','private');self.g(self.author,'commit','-m','incoming');self.g(self.author,'push','origin','experiment/3d-world');r=self.launch(False);self.assertNotEqual(r.returncode,0);self.assertEqual((self.work/'private').read_text(),'keep')
 def test_data_symlink_refused(self):
  (self.base/'.noheroneeds-3d-data').symlink_to(self.base/'other');r=self.launch(False);self.assertNotEqual(r.returncode,0);self.assertIn('символической',r.stdout)

if __name__=='__main__': unittest.main(verbosity=2)
