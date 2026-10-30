import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class SiteTests(unittest.TestCase):
    def test_required_files(self):
        for rel in ("index.html", "wiki.html", "guides.html", "updates.html", "assets/style.css", "assets/site.js", "data/wiki.json", "data/releases.json", "CODEX_PROMPT.md"):
            with self.subTest(path=rel):
                self.assertTrue((ROOT / rel).is_file(), rel)

    def test_internal_page_links(self):
        for html in ROOT.glob("*.html"):
            data = html.read_text(encoding="utf-8")
            for href in re.findall(r'href="([^"]+)"', data):
                if href.startswith(("https:", "http:", "mailto:", "#", "data:")):
                    continue
                path = href.split("?")[0].split("#")[0]
                if path:
                    with self.subTest(source=html.name, target=path):
                        self.assertTrue((ROOT / path).is_file(), path)

    def test_wiki_relations(self):
        wiki = json.loads((ROOT / "data/wiki.json").read_text(encoding="utf-8"))
        item_ids = {x["id"] for x in wiki["items"]}
        recipe_ids = {x["id"] for x in wiki["recipes"]}
        npc_ids = {x["id"] for x in wiki["professions"]}
        self.assertEqual(len(item_ids), len(wiki["items"]))
        self.assertEqual(len(recipe_ids), len(wiki["recipes"]))
        self.assertEqual(len(npc_ids), len(wiki["professions"]))
        for recipe in wiki["recipes"]:
            for item in [*recipe["inputs"], *recipe["outputs"]]:
                with self.subTest(recipe=recipe["id"], item=item):
                    self.assertIn(item, item_ids)
        for npc in wiki["professions"]:
            for recipe in npc["teaches"]:
                self.assertIn(recipe, recipe_ids)

    def test_releases(self):
        data = json.loads((ROOT / "data/releases.json").read_text(encoding="utf-8"))
        self.assertEqual(len({x["version"] for x in data}), len(data))
        self.assertEqual(data[-1]["version"], "0.16.0")
        self.assertTrue(all(x["url"].startswith("https://github.com/mirivlad/noheroneeds/releases/tag/") for x in data))
        versions = [tuple(int(n) for n in x["version"].split(".")) for x in data]
        self.assertEqual(versions, sorted(versions))

    def test_navigation_selection(self):
        js = (ROOT / "assets/site.js").read_text(encoding="utf-8")
        self.assertIn("release-index-link", js)
        self.assertIn("scrollIntoView", js)
        self.assertIn("aria-current", js)

if __name__ == "__main__":
    unittest.main()
