from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build import ROOT, read


class ReleaseModeTests(unittest.TestCase):
    def test_published_release_cannot_be_repackaged_by_release_workflow_mode(self):
        published = read(ROOT/'site/content/published-releases.json')['releases'][-1]['tag']
        with tempfile.TemporaryDirectory() as temp:
            result = subprocess.run([sys.executable, str(ROOT/'tools/site/check.py'), '--root', str(ROOT), '--out', temp,
                                     '--release', published, '--unpublished'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already published', result.stderr)


if __name__ == '__main__': unittest.main()
