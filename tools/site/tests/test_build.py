import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build import ROOT, build, catalog, guides, load_content, read, releases, version_key, write
from check import coverage, validate_links


class CatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.temp.name)/'site'
        cls.data = build(ROOT, ROOT, cls.out)
        cls.defs, _, _ = load_content(ROOT)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_every_recipe_and_its_exact_data_come_from_content(self):
        actual = {r['id']: r for r in self.data['recipes']}
        expected = {k: v for k, v in self.defs.items() if v['kind'] == 'recipe'}
        self.assertEqual(set(actual), set(expected))
        for key, value in expected.items():
            for field in ['inputs', 'outputs', 'station', 'skill', 'difficulty', 'innate']:
                self.assertEqual(actual[key].get(field), value.get(field), (key, field))
        sword = actual['base:forge_iron_sword']
        self.assertEqual(sword['inputs'], {'base:iron_ingot': 3, 'base:plank': 1, 'base:cord': 1})
        self.assertEqual(sword['station'], 'forge')

    def test_all_ingredients_results_and_both_directions_resolve(self):
        ids = {r['id'] for r in self.data['entities']}
        self.assertEqual(len(ids), len(self.data['entities']))
        for edge in self.data['edges']:
            self.assertIn(edge['from'], ids)
            self.assertIn(edge['to'], ids)
            self.assertIn(edge, self.data['forward'][edge['from']])
            self.assertIn(edge, self.data['reverse'][edge['to']])
            self.assertTrue((ROOT/edge['source']['file']).is_file())
            self.assertTrue(edge['source']['pointer'])

    def test_teachers_prices_skills_and_stock_are_not_independent_copies(self):
        for profession in self.data['professions']:
            original = self.defs[profession['id']]
            self.assertEqual(profession['teaches'], original.get('teaches', {}))
            self.assertEqual(profession['sells'], sorted(original.get('trade', {}).get('sells', {})))
            for recipe, terms in profession['teaches'].items():
                self.assertEqual(self.defs[recipe]['kind'], 'recipe')
                for skill in terms.get('skill', {}): self.assertEqual(self.defs[skill]['kind'], 'skill')
        smith = next(p for p in self.data['professions'] if p['id'] == 'base:smith')
        self.assertEqual(smith['teaches']['base:forge_iron_sword'], {'price': 55, 'standing': 1, 'skill': {'base:weaponsmithing': 10}})

    def test_ore_chains_work_for_all_four_metals(self):
        for metal in ['iron', 'copper', 'silver', 'gold']:
            self.assertTrue(any(e['from'] == f'base:{metal}_ore_rock' and e['to'] == f'base:{metal}_ore' for e in self.data['edges']))
            self.assertTrue(any(e['from'] == f'base:smelt_{metal}' and e['to'] == f'base:{metal}_ore' for e in self.data['edges']))
            self.assertTrue(any(e['from'] == f'base:smelt_{metal}' and e['to'] == f'base:{metal}_ingot' for e in self.data['edges']))
            self.assertTrue(any(e['from'] == 'base:smith' and e['to'] == f'base:smelt_{metal}' for e in self.data['edges']))
        self.assertTrue(any(e['from'] == 'base:iron_ore_rock' and e['to'] == 'base:flint_pick' and e['label'] == 'Подходящий инструмент' for e in self.data['edges']))

    def test_guide_coverage_links_and_live_hospitality_facts(self):
        coverage(ROOT, self.data)
        validate_links(self.out)
        html = (self.out/'guides.html').read_text()
        service = self.defs['base:inn_services']
        for lodging in service['lodging']:
            self.assertIn(f'{lodging["price"]} монет на {lodging["hours"]}', html)
        self.assertNotIn('{{inn-', html)
        self.assertTrue(any(e['from'] == 'base:innkeeper' and e['to'] == service['id'] for e in self.data['edges']))
        search = read(self.out/'data/search.json')
        self.assertTrue(any(e['url'] == 'guides.html#hospitality' for e in search))
        self.assertEqual({r['id'] for r in self.data['entities']}, {r['id'] for r in search if r['url'].startswith('wiki.html')})

    def test_build_bytes_are_deterministic_and_media_are_local(self):
        other = Path(self.temp.name)/'again'
        build(ROOT, ROOT, other)
        files = {p.relative_to(self.out): p.read_bytes() for p in self.out.rglob('*') if p.is_file()}
        self.assertEqual(files, {p.relative_to(other): p.read_bytes() for p in other.rglob('*') if p.is_file()})
        for page in self.out.glob('*.html'):
            self.assertNotIn('raw.githubusercontent.com', page.read_text())
            self.assertNotIn('{{', page.read_text())
        for release in read(self.out/'data/releases.json'):
            for image in release.get('images', []): self.assertTrue((self.out/image).is_file())

    def test_rebuild_removes_stale_future_pages_but_does_not_overwrite_unrelated_files(self):
        obsolete = self.out/'future-preview.html'
        obsolete.write_text('not released')
        build(ROOT, ROOT, self.out)
        self.assertFalse(obsolete.exists())
        unrelated = Path(self.temp.name)/'unrelated'
        unrelated.mkdir()
        note = unrelated/'notes.txt'; note.write_text('keep this')
        with self.assertRaisesRegex(ValueError, 'not owned'):
            build(ROOT, ROOT, unrelated)
        self.assertEqual(note.read_text(), 'keep this')

    def test_history_is_exactly_the_publications_not_the_tags(self):
        manifest = read(ROOT/'site/content/published-releases.json')['releases']
        actual = read(self.out/'data/releases.json')
        self.assertEqual([r['version'] for r in actual], [r['tag'][1:] for r in manifest])
        self.assertEqual([version_key(r['version']) for r in actual], sorted(version_key(r['version']) for r in actual))
        self.assertEqual(actual[-1]['version'], max(manifest, key=lambda r: version_key(r['tag']))['tag'][1:])
        for r in actual: self.assertEqual(r['url'], f'https://github.com/mirivlad/noheroneeds/releases/tag/v{r["version"]}')

    def test_no_missing_or_empty_candidate_changelog_is_accepted(self):
        with self.assertRaises(FileNotFoundError): releases(ROOT, ROOT/'site/content/published-releases.json', 'v99.98.97')
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            path = root/'docs/changelog/v1.2.3.json'
            write(path, {'version': '1.2.3', 'url': 'https://github.com/mirivlad/noheroneeds/releases/tag/v1.2.3', 'title': 'обновлено', 'tagline': '', 'groups': []})
            manifest = root/'public.json'
            write(manifest, {'releases': []})
            with self.assertRaises(ValueError): releases(root, manifest, 'v1.2.3')


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.file = self.root/'content/base/defs.json'
        write(self.root/'content/base/pack.json', {'format': 1, 'id': 'base', 'version': '1.0.0', 'depends': []})
        self.defs = [{'id': 'base:new_material', 'kind': 'item', 'name': 'Новый материал'},
                     {'id': 'base:new_recipe', 'kind': 'recipe', 'name': 'Новое изделие', 'inputs': {'base:new_material': 2}, 'outputs': {'base:new_material': 1}}]

    def tearDown(self): self.temp.cleanup()

    def save(self): write(self.file, {'format': 1, 'defs': self.defs})

    def test_new_ids_and_additional_packs_are_discovered(self):
        self.save()
        write(self.root/'content/addon/pack.json', {'format': 1, 'id': 'addon', 'version': '1.0.0', 'depends': ['base']})
        write(self.root/'content/addon/other.json', {'format': 1, 'defs': [{'id': 'addon:previously_unknown', 'kind': 'item', 'name': 'Находка'}]})
        data = catalog(self.root)
        self.assertIn('base:new_recipe', {d['id'] for d in data['recipes']})
        self.assertIn('addon:previously_unknown', {d['id'] for d in data['entities']})

    def test_duplicate_ids_are_rejected(self):
        self.defs.append(copy.deepcopy(self.defs[0])); self.save()
        with self.assertRaisesRegex(ValueError, 'duplicate'): catalog(self.root)

    def test_unknown_ingredient_and_result_are_rejected(self):
        for field in ['inputs', 'outputs']:
            original = copy.deepcopy(self.defs)
            self.defs[1][field] = {'base:missing': 1}; self.save()
            with self.assertRaisesRegex(ValueError, 'Broken reference'): catalog(self.root)
            self.defs = original

    def test_cross_pack_missing_reference_and_dependency_cycle_are_rejected(self):
        self.defs[1]['inputs'] = {'missing:thing': 1}; self.save()
        with self.assertRaisesRegex(ValueError, 'Broken reference'): catalog(self.root)
        write(self.root/'content/base/pack.json', {'format': 1, 'id': 'base', 'version': '1.0.0', 'depends': ['addon']})
        write(self.root/'content/addon/pack.json', {'format': 1, 'id': 'addon', 'version': '1.0.0', 'depends': ['base']})
        with self.assertRaisesRegex(ValueError, 'cycle'): catalog(self.root)

    def test_pack_format_matches_the_game_registry(self):
        self.save()
        write(self.root/'content/base/pack.json', {'format': 99, 'id': 'base', 'version': '1.0.0'})
        with self.assertRaisesRegex(ValueError, 'format'): catalog(self.root)

    def test_teaching_wrong_type_or_invalid_terms_is_rejected(self):
        self.defs.append({'id': 'base:teacher', 'kind': 'profession', 'teaches': {'base:new_material': {'price': -1}}})
        self.save()
        with self.assertRaisesRegex(ValueError, 'teaching'): catalog(self.root)

    def test_unknown_content_kind_requires_support_instead_of_silent_omission(self):
        self.defs.append({'id': 'base:new_system', 'kind': 'new_system'}); self.save()
        with self.assertRaisesRegex(ValueError, 'Unknown content kind'): catalog(self.root)


if __name__ == '__main__': unittest.main()
