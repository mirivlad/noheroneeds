#!/usr/bin/env python3
"""Deterministic, offline encyclopedia built from content packs and editorial guides."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
ID = re.compile(r"^[a-z0-9_]+:[a-z0-9_/]+$")
SYMBOL_NAMESPACES = {"work", "season", "station", "tool", "weapon"}
KINDS = {"item", "recipe", "profession", "plant", "structure", "ground", "creature", "deposit",
         "skill", "hospitality", "settlement", "biome", "modifier", "attribute", "achievement", "generator", "story"}


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def version_key(value):
    if not re.fullmatch(r"v?\d+\.\d+\.\d+", value):
        raise ValueError(f"Invalid version: {value}")
    return tuple(map(int, value.removeprefix("v").split(".")))


def load_content(game):
    definitions, origins, packs = {}, {}, {}
    manifests = sorted((game / "content").rglob("pack.json"))
    for manifest in manifests:
        pack = read(manifest)
        if not isinstance(pack, dict) or pack.get("format") != 1:
            raise ValueError(f"Unsupported pack format: {manifest}")
        if not re.fullmatch(r"[a-z_][a-z0-9_]*", str(pack.get("id", ""))):
            raise ValueError(f"Invalid pack namespace: {manifest}")
        if pack["id"] in packs:
            raise ValueError(f"Duplicate pack: {pack['id']}")
        packs[pack["id"]] = pack
        # Match ContentRegistry._load_pack: definitions are immediate JSON
        # children of each pack, not unrelated asset metadata below it.
        for file in sorted(manifest.parent.glob("*.json")):
            if file.name == "pack.json": continue
            data = read(file)
            if not isinstance(data, dict) or data.get("format") != 1:
                raise ValueError(f"Unsupported definitions format: {file}")
            for n, definition in enumerate(data.get("defs", [])):
                key = definition["id"]
                if definition["kind"] not in KINDS | {"visual", "sound", "style", "body_plan", "names"}:
                    raise ValueError(f"Unknown content kind needs catalog/guide support: {definition['kind']}")
                if not ID.fullmatch(key) or not key.startswith(pack["id"] + ":") or key in definitions:
                    raise ValueError(f"Invalid or duplicate ID: {key} in {file}")
                definitions[key] = definition
                origins[key] = {"file": file.relative_to(game).as_posix(), "pointer": f"/defs/{n}"}
    for pack in packs.values():
        if any(dep not in packs for dep in pack.get("depends", [])):
            raise ValueError(f"Missing pack dependency: {pack['id']}")
    resolved = set()
    while len(resolved) < len(packs):
        ready = {key for key, p in packs.items() if key not in resolved and set(p.get("depends", [])) <= resolved}
        if not ready: raise ValueError("Pack dependency cycle")
        resolved |= ready
    return definitions, origins, packs


def references(value, namespace, path=""):
    if isinstance(value, dict):
        for key, child in sorted(value.items()):
            pointer = path + "/" + key.replace("~", "~0").replace("/", "~1")
            if ID.fullmatch(key) and key.split(":")[0] not in SYMBOL_NAMESPACES:
                yield key, pointer, child
            yield from references(child, namespace, pointer)
    elif isinstance(value, list):
        for n, child in enumerate(value):
            yield from references(child, namespace, path + f"/{n}")
    elif isinstance(value, str) and ID.fullmatch(value) and value.split(":")[0] not in SYMBOL_NAMESPACES:
        yield value, path, None


def category(d):
    kind = d["kind"]
    if kind == "item":
        if d.get("tools"): return "Инструменты"
        if d.get("weapon"): return "Оружие"
        if d.get("food"): return "Еда и хозяйство"
        if d.get("wear") or d.get("armor"): return "Одежда и броня"
        if d["id"].endswith("_ore") or d["id"] in {"base:flint", "base:raw_gem"}: return "Руда"
        if d["id"].endswith("_ingot"): return "Металлы"
        return "Материалы"
    return {"recipe": "Рецепты", "profession": "Жители", "plant": "Растения", "creature": "Существа",
            "structure": "Постройки и транспорт", "hospitality": "Таверны", "deposit": "Месторождения",
            "skill": "Умения", "ground": "Мир", "biome": "Мир", "settlement": "Поселения",
            "generator": "Мир", "story": "Поручения"}.get(kind, "Другие знания")


def relation(pointer):
    for part, names in [("/inputs/", ("Требуется", "Нужно для")), ("/outputs/", ("Создаёт", "Получается по рецепту")),
                        ("/gather/drops/", ("Добыча", "Где добыть")), ("/drops/", ("Добыча", "Где добыть")),
                        ("/teaches/", ("Обучает", "Учитель")), ("/trade/sells/", ("Продаёт", "Продавец")),
                        ("/trade/buys/", ("Покупает", "Покупатель")), ("/trade/blueprints/", ("Продаёт чертёж", "Чертёж продаёт")),
                        ("/cost/", ("Материалы конструкции", "Конструкция")), ("/menu/", ("Подаёт", "Питание у хозяина")),
                        ("/gather/pick/", ("Возможная добыча (вес выбора)", "Промысел (вес выбора)"))]:
        if part in pointer: return names
    return ("Связано", "Связано")


def catalog(game):
    definitions, origins, packs = load_content(game)
    visible = {key for key, d in definitions.items() if d["kind"] in KINDS and (d["kind"] != "story" or d.get("request"))}
    edges, entities = [], []
    for key, d in sorted(definitions.items()):
        for target, pointer, value in references(d, packs):
            if pointer == "/id": continue
            if target not in definitions:
                raise ValueError(f"Broken reference: {key}{pointer} -> {target}")
            if key in visible and target in visible:
                label, reverse = relation(pointer)
                edges.append({"from": key, "to": target, "label": label, "reverse": reverse,
                              "value": value, "source": {**origins[key], "pointer": origins[key]["pointer"] + pointer}})
        if key not in visible: continue
        entity = {**d, "name": d.get("name", key), "category": category(d), "source": origins[key]}
        if "name" not in d and d["kind"] == "deposit":
            entity["name"] = "Месторождение: " + definitions[d["rock"]].get("name", d["rock"])
        if "name" not in d and d["kind"] == "story":
            item = d["request"].get("item", "")
            entity["name"] = "Поручение: " + definitions.get(item, {}).get("name", item or key)
        if d["kind"] == "profession":
            entity["sells"] = sorted(d.get("trade", {}).get("sells", {}))
            entity["buys"] = sorted(d.get("trade", {}).get("buys", {}))
            entity["teaches"] = d.get("teaches", {})
        entities.append(entity)
    for recipe in (d for d in entities if d["kind"] == "recipe"):
        for station in (d for d in entities if d.get("station") == recipe.get("station") and d["kind"] == "structure" and recipe.get("station")):
            edges.append({"from": recipe["id"], "to": station["id"], "label": "Рабочая станция", "reverse": "Рецепт для станции", "value": None,
                          "source": {**origins[recipe["id"]], "pointer": origins[recipe["id"]]["pointer"] + "/station"}})
    for source in (d for d in entities if d.get("gather", {}).get("tool")):
        token = source["gather"]["tool"]
        tools = [d for d in entities if d["kind"] == "item" and token in d.get("tools", [])]
        if not tools: raise ValueError(f"Gathering tool has no available item: {source['id']} ({token})")
        for tool in tools:
            edges.append({"from": source["id"], "to": tool["id"], "label": "Подходящий инструмент", "reverse": "Можно добывать", "value": None,
                          "source": {**origins[source["id"]], "pointer": origins[source["id"]]["pointer"] + "/gather/tool"}})
    # The current Hospitality system shares a single service profile across
    # its buildings. Roles come from those services' real work definitions.
    profiles = [d for d in entities if d["kind"] == "hospitality" and d.get("mode") == "services"]
    if len(profiles) == 1:
        profile = profiles[0]
        roles = {definitions[k]["request"]["asker"] for k in profile.get("work", [])}
        for building in (d for d in entities if d["kind"] == "hospitality" and d.get("mode") == "building"):
            edges.append({"from": building["id"], "to": profile["id"], "label": "Услуги заведения", "reverse": "Доступно в здании", "value": None,
                          "source": {"file": "src/server/hospitality.gd", "pointer": "Hospitality.terms"}})
            for role in sorted(roles):
                edges.append({"from": building["id"], "to": role, "label": "Хозяин", "reverse": "Работает в заведении", "value": None,
                              "source": {"file": "src/server/hospitality.gd", "pointer": "Hospitality.arrived"}})
        for role in sorted(roles):
            edges.append({"from": role, "to": profile["id"], "label": "Услуги хозяина", "reverse": "Обслуживает", "value": None,
                          "source": {"file": "src/server/hospitality.gd", "pointer": "Hospitality.decorate"}})
    for d in entities:
        if d["kind"] == "recipe":
            for field in ["inputs", "outputs"]:
                if not d.get(field) or any(not isinstance(n, (int, float)) or n <= 0 or definitions[k]["kind"] != "item" for k, n in d[field].items()):
                    raise ValueError(f"Invalid recipe {field}: {d['id']}")
        for recipe, terms in d.get("teaches", {}).items():
            if definitions[recipe]["kind"] != "recipe" or terms.get("price", -1) < 0 or not isinstance(terms.get("standing", 0), int):
                raise ValueError(f"Invalid teaching: {d['id']} -> {recipe}")
            if any(definitions[k]["kind"] != "skill" or n < 0 for k, n in terms.get("skill", {}).items()):
                raise ValueError(f"Invalid teaching skill: {d['id']}")
    edges.sort(key=lambda e: (e["from"], e["to"], e["source"]["pointer"]))
    forward, reverse = {}, {}
    for edge in edges:
        forward.setdefault(edge["from"], []).append(edge)
        reverse.setdefault(edge["to"], []).append(edge)
    return {"content_version": "v" + packs["base"]["version"], "packs": packs, "entities": entities,
            "items": [d for d in entities if d["kind"] not in {"recipe", "profession"}],
            "recipes": [d for d in entities if d["kind"] == "recipe"], "professions": [d for d in entities if d["kind"] == "profession"],
            "skills": {d["id"]: d["name"] for d in entities if d["kind"] == "skill"},
            "edges": edges, "forward": forward, "reverse": reverse}


def guides(root, data):
    out = []
    known = {d["id"] for d in data["entities"]}
    for file in sorted((root / "site/content/guides").glob("*.html")):
        body = file.read_text(encoding="utf-8")
        if "{{inn-" in body:
            body = hospitality_facts(body, data)
        match = re.search(r'<article class="guide-article" id="([a-z0-9-]+)">', body)
        title = re.search(r"<h2>(.*?)</h2>", body)
        if not match or not title or len(re.sub("<[^>]+>", "", body).strip()) < 180:
            raise ValueError(f"Invalid guide: {file}")
        refs = re.findall(r'wiki\.html\?item=([^"&#]+)', body)
        from urllib.parse import unquote
        refs = sorted({unquote(ref) for ref in refs})
        if any(ref not in known for ref in refs): raise ValueError(f"Unknown guide entity: {file}: {refs}")
        out.append({"id": match[1], "name": html.unescape(title[1]), "html": body, "entities": refs,
                    "file": file.relative_to(root).as_posix()})
    if len({g["id"] for g in out}) != len(out): raise ValueError("Duplicate guide ID")
    manifest = root/"site/mechanics-manifest.json"
    if manifest.exists():
        order = list(dict.fromkeys(m["guide"] for m in read(manifest)["mechanics"]))
        out.sort(key=lambda g: order.index(g["id"]) if g["id"] in order else len(order))
    return out


def hospitality_facts(body, data):
    entities = {d["id"]: d for d in data["entities"]}
    service = entities["base:inn_services"]
    def link(key):
        from urllib.parse import quote
        return f'<a class="tiny-link" href="wiki.html?item={quote(key, safe="")}">{html.escape(entities[key]["name"])}</a>'
    def listing(rows): return "<ul>" + "".join("<li>" + row + "</li>" for row in rows) + "</ul>"
    fields = {
        "menu": listing([f'{html.escape(m["name"])} — {m["price"]} монет; {link(m["item"])}: сытость +{entities[m["item"]]["food"].get("satiety", 0)}, здоровье +{entities[m["item"]]["food"].get("heal", 0)}.' for m in service["menu"]]),
        "lodging": listing([f'{html.escape(b["name"])} — {b["price"]} монет на {b["hours"]} игровых часов.' for b in service["lodging"]]),
        "work": listing([f'{link(k)}: {link(entities[k]["request"]["item"])} ×{entities[k]["request"]["count"]}, награда {entities[k]["request"]["reward"]} монет.' for k in service["work"]]),
        "lessons": listing([f'{link(k)} — {t["price"]} монет, доверие от {t.get("standing", 0)}.' for k, t in entities["base:innkeeper"]["teaches"].items()]),
    }
    for key, value in fields.items(): body = body.replace("{{inn-" + key + "}}", value)
    if "{{inn-" in body: raise ValueError("Unknown hospitality fact template")
    return body


def releases(root, manifest, candidate=None):
    source = read(manifest)
    result = []
    records = source["releases"]
    if candidate and candidate not in {r["tag"] for r in records}:
        records = records + [{"tag": candidate, "published_at": None, "url": f"https://github.com/mirivlad/noheroneeds/releases/tag/{candidate}"}]
    for published in sorted(records, key=lambda r: version_key(r["tag"])):
        tag = published["tag"]
        entry = read(root / f"docs/changelog/{tag}.json")
        if entry["version"] != tag.removeprefix("v") or entry["url"] != f"https://github.com/mirivlad/noheroneeds/releases/tag/{tag}":
            raise ValueError(f"Wrong changelog version/link: {tag}")
        if len(entry.get("title", "")) < 8 or len(entry.get("tagline", "")) < 30 or not entry.get("groups"):
            raise ValueError(f"Incomplete player changelog: {tag}")
        for group in entry["groups"]:
            if not group.get("title") or not group.get("bullets") or any(len(b.strip()) < 20 or re.match(r"^(chore|refactor|ci|build):", b, re.I) for b in group["bullets"]):
                raise ValueError(f"Empty/technical changelog: {tag}")
        date = "Готовится к выпуску"
        if published["published_at"]:
            from datetime import datetime
            from zoneinfo import ZoneInfo
            when = datetime.fromisoformat(published["published_at"].replace("Z", "+00:00")).astimezone(ZoneInfo("Asia/Irkutsk"))
            months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
            date = f"{when.day} {months[when.month-1]} {when.year} г."
        result.append({**entry, "date": date, "published_at": published["published_at"], "prepared": published["published_at"] is None})
    if len({r["version"] for r in result}) != len(result): raise ValueError("Duplicate published release")
    return result


def build(root, game, output, manifest=None, candidate=None):
    data = catalog(game)
    chapters = guides(root, data)
    history = releases(root, manifest or root / "site/content/published-releases.json", candidate)
    if not history: raise ValueError("No published releases")
    if candidate and data["content_version"] != candidate: raise ValueError("Candidate version differs from game content")
    if output.resolve() in {root.resolve(), game.resolve()}:
        raise ValueError("Output must be a separate generated directory")
    if output.exists() and any(output.iterdir()):
        marker = output/"data/build.json"
        if not marker.is_file() or read(marker).get("generator") != "nhn-wiki-v2":
            raise ValueError("Output directory is not owned by the wiki builder; choose an empty directory")
        shutil.rmtree(output)  # no obsolete or unreleased pages survive a snapshot rebuild
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(root / "site/assets", output / "assets", dirs_exist_ok=True)
    media = output / "assets/media"
    media.mkdir(exist_ok=True)
    def image(path):
        source = game / path
        if not source.is_file(): raise ValueError(f"Missing screenshot: {path}")
        target = "assets/media/" + hashlib.sha256(path.encode()).hexdigest()[:10] + "-" + source.name
        shutil.copy2(source, output / target)
        return target
    history = [{**entry, "images": [image(path) for path in entry.get("images", [])]} for entry in history]
    for page in (root / "site").glob("*.html"):
        text = page.read_text(encoding="utf-8")
        if page.name == "guides.html":
            text = re.sub(r'(<div id="guide-content">).*?(</div></div></main>)', lambda m: m[1] + "\n".join(g["html"] for g in chapters) + m[2], text, flags=re.S)
        text = re.sub(r"https://raw\.githubusercontent\.com/mirivlad/noheroneeds/(?:main|v[\d.]+)/([^\"'<>\s)]+)", lambda m: image(m[1]), text)
        text = text.replace("{{version}}", data["content_version"]).replace("{{latest_release}}", history[-1]["url"])
        for key, value in {"release_count": len(history), "recipe_count": len(data["recipes"]), "item_count": sum(d["kind"] == "item" for d in data["entities"]),
                           "profession_count": len(data["professions"]), "latest_version": history[-1]["version"],
                           "latest_anchor": "v" + history[-1]["version"].replace(".", "-"), "latest_title": history[-1]["title"], "latest_tagline": history[-1]["tagline"], "latest_date": history[-1]["date"]}.items():
            text = text.replace("{{" + key + "}}", html.escape(str(value)))
        text = re.sub(r'(?<=src=")repo:([^\"]+)', lambda m: image(m[1]), text)
        (output / page.name).write_text(text, encoding="utf-8")
    (output / ".nojekyll").touch()
    shutil.copy2(game / "CREDITS-art.md", output / "assets/CREDITS-art.md")
    shutil.copy2(game / "LICENSE", output / "assets/LICENSE")
    data["guides"] = [{k: v for k, v in g.items() if k != "html"} for g in chapters]
    write(output / "data/wiki.json", data)
    write(output / "data/releases.json", history)
    search = [{"id": d["id"], "name": d["name"], "tag": d["category"], "url": "wiki.html?item=" + __import__('urllib.parse', fromlist=['quote']).quote(d["id"], safe=""), "text": d.get("description", "")} for d in data["entities"]]
    search += [{"id": g["id"], "name": g["name"], "tag": "Руководство", "url": "guides.html#" + g["id"]} for g in chapters]
    search += [{"id": "v" + r["version"], "name": "v" + r["version"] + " — " + r["title"], "tag": "Обновление", "url": "updates.html#v" + r["version"].replace(".", "-")} for r in history]
    write(output / "data/search.json", search)
    write(output / "data/build.json", {"generator": "nhn-wiki-v2", "version": data["content_version"], "published": [r["version"] for r in history if not r["prepared"]],
          "sources": {p.relative_to(game).as_posix(): digest(p) for p in sorted((game / "content").rglob("*.json"))},
          "guides": {g["file"]: digest(root / g["file"]) for g in chapters}})
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--game-root", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "build/site")
    parser.add_argument("--published", type=Path)
    parser.add_argument("--candidate")
    args = parser.parse_args()
    try:
        data = build(args.root, args.game_root or args.root, args.out, args.published, args.candidate)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"Site build failed: {error}\n")
    print(f"Built {len(data['entities'])} records, {len(data['edges'])} relations for {data['content_version']} -> {args.out}")


if __name__ == "__main__":
    main()
