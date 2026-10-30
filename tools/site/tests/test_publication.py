from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build import ROOT, read, write
from publish import publication


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)/'repo'; self.root.mkdir()
        self.git('init', '-q'); self.git('config', 'user.name', 'Wiki test'); self.git('config', 'user.email', 'wiki-test@example.invalid')
        write(self.root/'content/base/pack.json', {'format': 1, 'id': 'base', 'version': '1.0.0'})
        write(self.root/'content/base/items.json', {'format': 1, 'defs': [{'id': 'base:released', 'kind': 'item', 'name': 'Выпущенная вещь'}]})
        for path in ['docs/keep', 'assets/icon/keep', 'src/keep', 'CREDITS-art.md', 'LICENSE', 'project.godot']:
            p = self.root/path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('fixture')
        (self.root/'project.godot').write_text('config/version="1.0.0"\n')
        self.commit('old game'); self.git('tag', 'v1.0.0')
        self.game = self.git('rev-parse', 'HEAD').strip()
        (self.root/'tools/site').mkdir(parents=True)
        shutil.copy2(ROOT/'tools/site/build.py', self.root/'tools/site/build.py')
        (self.root/'site/assets').mkdir(parents=True)
        (self.root/'site/assets/style.css').write_text('body {color: white; background: black}')
        guide = self.root/'site/content/guides/start.html'; guide.parent.mkdir(parents=True)
        guide.write_text('<article class="guide-article" id="start"><h2>RELEASED GUIDE</h2><p>' + 'Released instructions which must remain visible even while a future main branch develops. '*4 + '</p></article>')
        (self.root/'site/index.html').write_text('<h1>RELEASED PAGE</h1>')
        (self.root/'site/guides.html').write_text('<main><div><div id="guide-content"></div></div></main>')
        self.note('1.0.0')
        self.commit('complete documentation snapshot')
        self.docs = self.git('rev-parse', 'HEAD').strip()
        write(self.root/'site/publication.json', {'bootstrap': {'v1.0.0': self.docs}})
        (self.root/'site/index.html').write_text('<h1>FUTURE MAIN PAGE</h1>')
        guide.write_text(guide.read_text().replace('RELEASED GUIDE', 'FUTURE MAIN GUIDE'))
        write(self.root/'content/base/pack.json', {'format': 1, 'id': 'base', 'version': '2.0.0'})
        (self.root/'project.godot').write_text('config/version="2.0.0"\n')
        write(self.root/'content/base/items.json', {'format': 1, 'defs': [{'id': 'base:future', 'kind': 'item', 'name': 'Будущая вещь'}]})
        self.note('2.0.0')
        self.commit('future gameplay and docs')
        self.future = self.git('rev-parse', 'HEAD').strip()
        self.manifest = Path(self.temp.name)/'published.json'
        write(self.manifest, {'releases': [{'tag': 'v1.0.0', 'published_at': '2026-10-01T01:00:00Z', 'url': 'https://github.com/mirivlad/noheroneeds/releases/tag/v1.0.0'}]})

    def tearDown(self): self.temp.cleanup()
    def git(self, *args): return subprocess.check_output(['git', '-C', str(self.root), *args], text=True)
    def commit(self, text): self.git('add', '.'); self.git('commit', '-qm', text)
    def note(self, version):
        write(self.root/f'docs/changelog/v{version}.json', {'version': version, 'title': 'Проверенный игровой выпуск', 'tagline': 'Выпущенные изменения подтверждены игровым содержимым.', 'groups': [{'title': 'Новое', 'bullets': ['Новый подтверждённый сценарий доступен в опубликованной игре.']}], 'url': f'https://github.com/mirivlad/noheroneeds/releases/tag/v{version}'})

    def test_main_cannot_leak_future_content_or_guide_into_public_site(self):
        out = Path(self.temp.name)/'public'
        publication(self.root, self.manifest, out)
        wiki = read(out/'data/wiki.json')
        self.assertEqual({e['id'] for e in wiki['entities']}, {'base:released'})
        self.assertIn('RELEASED PAGE', (out/'index.html').read_text())
        self.assertNotIn('FUTURE', (out/'guides.html').read_text())
        self.assertEqual(read(out/'data/publication.json')['documentation_commit'], self.docs)

    def test_new_publication_switches_both_content_and_docs_to_its_exact_tag(self):
        self.git('tag', 'v2.0.0')
        value = read(self.manifest)
        value['releases'].append({'tag': 'v2.0.0', 'published_at': '2026-10-02T01:00:00Z', 'url': 'https://github.com/mirivlad/noheroneeds/releases/tag/v2.0.0'})
        write(self.manifest, value)
        out = Path(self.temp.name)/'new-public'
        publication(self.root, self.manifest, out)
        self.assertEqual({e['id'] for e in read(out/'data/wiki.json')['entities']}, {'base:future'})
        self.assertEqual(read(out/'data/publication.json')['documentation_commit'], self.future)
        self.assertIn('FUTURE MAIN PAGE', (out/'index.html').read_text())

    def test_missing_or_mutable_bootstrap_ref_fails_closed(self):
        write(self.root/'site/publication.json', {'bootstrap': {'v1.0.0': 'main'}})
        with self.assertRaisesRegex(ValueError, 'pinned bootstrap'): publication(self.root, self.manifest, Path(self.temp.name)/'bad')


if __name__ == '__main__': unittest.main()
