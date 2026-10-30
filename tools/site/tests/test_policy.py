import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build import ROOT, catalog, digest, guides, read, write
from check import coverage, receipts


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.run_git('init', '-q')
        self.run_git('config', 'user.name', 'Wiki test')
        self.run_git('config', 'user.email', 'wiki-test@example.invalid')
        self.source = self.root/'src/mechanic.gd'
        self.source.parent.mkdir()
        self.source.write_text('func action():\n\treturn 1\n')
        self.guide = self.root/'site/content/guides/example.html'
        self.guide.parent.mkdir(parents=True)
        self.guide.write_text('<article class="guide-article" id="example"><h2>Проверяемая механика</h2><p>' + 'Действие доступно в игровом мире и использует обычные ресурсы персонажа. '*4 + '</p></article>')
        write(self.root/'content/base/pack.json', {'format': 1, 'id': 'base', 'version': '1.0.0'})
        write(self.root/'content/base/items.json', {'format': 1, 'defs': [{'id': 'base:thing', 'kind': 'item', 'name': 'Вещь'}]})
        write(self.root/'site/mechanics-manifest.json', {'mechanics': [{'id': 'example', 'guide': 'example', 'sources': ['src/mechanic.gd', 'content/base/*.json'], 'kinds': ['item']}]})
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'baseline')
        self.base = self.run_git('rev-parse', 'HEAD').strip()
        self.source.write_text('func action():\n\treturn 2\n')

    def tearDown(self): self.temp.cleanup()
    def run_git(self, *args): return subprocess.check_output(['git', '-C', str(self.root), *args], text=True)
    def data(self):
        data = catalog(self.root)
        data['guides'] = guides(self.root, data)
        return data
    def entry(self, impact='player-facing-change'):
        return {'impact': impact, 'summary': 'Изменено действие персонажа с конкретным новым результатом.',
                'sources': {'src/mechanic.gd': digest(self.source)}, 'mechanics': ['example'],
                'guides': {'site/content/guides/example.html': digest(self.guide)},
                'changelog': 'docs/changelog/unreleased.json'}
    def save(self, entry):
        write(self.root/'docs/changes/example.json', {'changes': [entry]})
        write(self.root/'docs/changelog/unreleased.json', {'mechanics': ['example'], 'tagline': 'Конкретное улучшение доступного игроку действия в мире.', 'groups': [{'title': 'Изменено', 'bullets': ['Действие теперь даёт новый понятный результат вместо прежнего.']}]})

    def test_missing_receipt_blocks_gameplay_change(self):
        with self.assertRaisesRegex(ValueError, 'lack current'): receipts(self.root, self.base, self.data())

    def test_unchanged_or_cosmetically_changed_guide_does_not_cover_behavior(self):
        self.save(self.entry())
        with self.assertRaisesRegex(ValueError, 'meaningful guide'): receipts(self.root, self.base, self.data())
        self.guide.write_text(self.guide.read_text().replace('<p>', '<p class="changed">'))
        self.save(self.entry())
        with self.assertRaisesRegex(ValueError, 'meaningful guide'): receipts(self.root, self.base, self.data())

    def test_actual_guide_update_and_current_hashes_pass_but_later_code_change_fails(self):
        self.guide.write_text(self.guide.read_text().replace('обычные ресурсы персонажа', 'другие доступные материалы из инвентаря гостя'))
        self.save(self.entry())
        receipts(self.root, self.base, self.data())
        self.source.write_text('func action():\n\treturn 3\n')
        with self.assertRaisesRegex(ValueError, 'lack current'): receipts(self.root, self.base, self.data())

    def test_internal_exemption_needs_a_specific_reason_and_exact_files(self):
        self.source.write_text('func action():\n\tvar result = 1\n\treturn result\n')
        entry = self.entry('no-player-facing-change')
        entry['summary'] = 'Выделить внутреннюю переменную без изменения результата действия.'
        self.save(entry)
        with self.assertRaisesRegex(ValueError, 'rationale'): receipts(self.root, self.base, self.data())
        entry['rationale'] = 'Переименована внутренняя переменная без изменения доступного игроку поведения; возвращаемое значение и ветвления сохранены. Это небольшая техническая правка, а не новый сценарий.'
        self.save(entry)
        receipts(self.root, self.base, self.data())
        entry['sources'] = {'src/*.gd': digest(self.source)}
        self.save(entry)
        with self.assertRaisesRegex(ValueError, 'exact gameplay'): receipts(self.root, self.base, self.data())

    def test_semantic_content_cannot_use_internal_exemption(self):
        self.source.write_text('func action():\n\treturn 1\n')
        path = self.root/'content/base/items.json'
        value = read(path); value['defs'][0]['stack'] = 99; write(path, value)
        entry = self.entry('no-player-facing-change')
        entry['sources'] = {'content/base/items.json': digest(path)}
        entry['rationale'] = 'Это намеренно длинное обоснование внутреннего изменения, которое всё равно не должно разрешить незаметно изменить игровые данные и обойти обновление справочника и патчноутов.'
        self.save(entry)
        with self.assertRaisesRegex(ValueError, 'Semantic content'): receipts(self.root, self.base, self.data())

    def test_large_internal_exemption_is_rejected(self):
        self.source.write_text('\n'.join(f'var test_{n} = {n}' for n in range(120)))
        entry = self.entry('no-player-facing-change')
        entry['rationale'] = 'Большая внутренняя правка требует обычной проверки документации, даже если в её описании обещано отсутствие влияния на игрока; нельзя подменять проверку длинным объяснением.'
        self.save(entry)
        with self.assertRaisesRegex(ValueError, 'Large internal'): receipts(self.root, self.base, self.data())

    def test_large_internal_review_does_not_force_a_fictional_player_guide_change(self):
        self.source.write_text('\n'.join(f'# Internal documentation {n}' for n in range(120)) + '\nfunc action():\n\treturn 1\n')
        test = self.root/'tests/unit/test_contract.gd'
        test.parent.mkdir(parents=True)
        test.write_text('extends TestCase\nfunc test_contract():\n\tcheck(true, "fixture contract")\n')
        entry = self.entry('no-player-facing-change')
        entry['summary'] = 'Расширить внутренние комментарии, сохранив поведение функции.'
        entry['rationale'] = 'Внутренние определения разделены без изменения внешнего поведения; ни один игрок не получает новую возможность и не теряет прежнюю, проверка пользовательского руководства не требует менять его текст.'
        entry['internal_review'] = {'behavior_contract': 'Сохранены входные параметры, результаты и порядок выполнения всех доступных игроку действий; сериализуемые поля, цены, потребности и изменения мира остались прежними.', 'tests': ['tests/unit/test_contract.gd']}
        self.save(entry)
        receipts(self.root, self.base, self.data())

    def test_unknown_mechanic_or_missing_guide_is_rejected(self):
        manifest = read(self.root/'site/mechanics-manifest.json')
        manifest['mechanics'][0]['guide'] = 'missing'
        write(self.root/'site/mechanics-manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'coverage'): coverage(self.root, self.data())


if __name__ == '__main__': unittest.main()
