from pathlib import Path
import sys
import unittest

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build import ROOT


class WorkflowTests(unittest.TestCase):
    def workflow(self, name): return yaml.safe_load((ROOT/f'.github/workflows/{name}.yml').read_text())

    def test_tag_and_manual_release_share_the_same_mandatory_documentation_barrier(self):
        workflow = self.workflow('release')
        events = workflow.get('on', workflow.get(True))
        self.assertIn('push', events)
        self.assertIn('workflow_dispatch', events)
        jobs = workflow['jobs']
        self.assertEqual(set(jobs['packages']['needs']), {'tests', 'documentation'})
        self.assertEqual(jobs['documentation']['uses'], './.github/workflows/site-check.yml')
        version = jobs['documentation']['with']['release_version']
        self.assertIn('github.event.inputs.version', version)
        self.assertIn('github.ref_name', version)
        self.assertNotIn('if', jobs['documentation'])
        release = next(s for s in jobs['packages']['steps'] if s.get('uses', '').startswith('softprops/action-gh-release'))
        self.assertEqual(release['with']['body_path'], 'build/release-notes.md')
        self.assertFalse(release['with']['generate_release_notes'])

    def test_website_checks_include_actual_generator_policy_and_browser_tests(self):
        workflow = self.workflow('site-check')
        events = workflow.get('on', workflow.get(True))
        self.assertIn('pull_request', events)
        self.assertIn('workflow_call', events)
        self.assertEqual(workflow['permissions']['contents'], 'read')
        commands = '\n'.join(s.get('run', '') for s in workflow['jobs']['documentation']['steps'])
        for command in ['tools/site/sync_releases.py', 'tools/site/check.py', '--release', 'unittest discover', 'npm test']:
            self.assertIn(command, commands)

    def test_published_site_uses_a_snapshot_and_release_workflow_calls_it_explicitly(self):
        pages = self.workflow('pages')
        events = pages.get('on', pages.get(True))
        self.assertNotIn('pull_request', events)
        self.assertEqual(events['push']['branches'], ['main'])
        self.assertIn('published', events['release']['types'])
        self.assertEqual(pages['jobs']['deploy']['needs'], 'build')
        commands = '\n'.join(s.get('run', '') for s in pages['jobs']['build']['steps'])
        self.assertIn('tools/site/publish.py', commands)
        self.assertNotIn('tools/site/build.py', commands)
        upload = next(s for s in pages['jobs']['build']['steps'] if s.get('uses', '').startswith('actions/upload-pages-artifact'))
        self.assertEqual(upload['with']['path'], 'build/pages')
        call = self.workflow('release')['jobs']['published_wiki']
        self.assertEqual(call['needs'], 'packages')
        self.assertEqual(call['uses'], './.github/workflows/pages.yml')
        self.assertEqual(call['if'], "github.event_name == 'push'")


if __name__ == '__main__': unittest.main()
