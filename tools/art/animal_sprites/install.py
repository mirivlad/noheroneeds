"""Install only verified RO animal sheets; retain the existing creature IDs/rules."""
import hashlib
import json
from pathlib import Path
import shutil

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
MODELS = {
    "horse":("quaternius","Horse","Horse_White"),"deer":("quaternius","Deer","Stag"),
    "cow":("quaternius","Cow"),"wolf":("quaternius","Wolf"),"fox":("quaternius","Fox"),
    "arctic_fox":("quaternius","ArcticFox"),"hare":("support","Hare"),"bear":("support","Bear"),
    "polar_bear":("support","PolarBear"),"sheep":("support","Sheep"),"chicken":("support","Chicken"),
    "cave_rat":("cave","CaveRat"),"cave_spider":("cave","CaveSpider"),
}


def main():
    destination = ROOT/"content/base/art/ro_animals"
    ready = {}
    receipt = {"models":{},"files":{},"tools":{}}
    # Validate every model before changing game content.
    for group,*models in MODELS.values():
        for model in models:
            path = ROOT/"build/animal_sprites"/("production-"+group)/model
            report = json.loads((path/"render.json").read_text())
            for source,expected in report["sources"].items():
                if hashlib.sha256((ROOT/source).read_bytes()).hexdigest()!=expected:
                    raise ValueError(f"Render source changed: {source}")
            visual = json.loads((path/"visual.json").read_text())
            if not all(float(visual.get("stride_px",{}).get(gait,0))>0 for gait in ["walk","run"]):
                raise ValueError(f"Gait calibration missing: {model}")
            proof = json.loads((path/"verification.json").read_text())
            atlas = path/visual["atlas"]
            if proof["clipped_frames"] or hashlib.sha256(atlas.read_bytes()).hexdigest()!=proof["sha256"]:
                raise ValueError(f"Invalid colour atlas: {model}")
            for filename in [visual["atlas"],visual["volume"]["atlas"]]:
                with Image.open(path/filename) as image:
                    if max(image.size)>16384: raise ValueError(f"Oversize atlas: {model}")
            with Image.open(atlas) as colour, Image.open(path/visual["volume"]["atlas"]) as depth:
                if colour.size!=depth.size or ImageChops.difference(colour.getchannel("A"),depth.getchannel("A")).getbbox():
                    raise ValueError(f"Colour/volume coverage differs: {model}")
            visual.pop("atlas_path",None)
            visual["atlas"] = "art/ro_animals/"+visual["atlas"]
            ready[model] = path,visual
            receipt["models"][model] = {"render_sources":report["sources"],"verification":proof}
    destination.mkdir(parents=True,exist_ok=True)
    definitions = []
    for animal,(group,*models) in MODELS.items():
        visual = dict(ready[models[0]][1])
        visual.update(id="base:visual/"+animal,kind="visual",**{"for":"base:"+animal})
        visual["alternates"] = [ready[model][1] for model in models[1:]]
        definitions.append(visual)
    for path,visual in ready.values():
        for filename in [Path(visual["atlas"]).name,visual["volume"]["atlas"]]:
            target = destination/filename
            shutil.copyfile(path/filename,target)
            receipt["files"][str(target.relative_to(ROOT))] = hashlib.sha256(target.read_bytes()).hexdigest()
    target = ROOT/"content/base/animal_visuals.json"
    target.write_text(json.dumps({"format":1,"defs":definitions},ensure_ascii=False,indent=1)+"\n")
    receipt["files"][str(target.relative_to(ROOT))] = hashlib.sha256(target.read_bytes()).hexdigest()
    old = ROOT/"content/base/lpc_animal_visuals.json"
    data = json.loads(old.read_text())
    data["defs"] = [d for d in data["defs"] if d["for"].removeprefix("base:") not in MODELS]
    old.write_text(json.dumps(data,ensure_ascii=False,indent=1)+"\n")
    for name in ["export.py","install.py","quaternius.py","support.py","cave.py","convert_0ad.py","calibrate.py"]:
        path = HERE/name
        receipt["tools"][str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (ROOT/"build/animal_sprites/installed.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print("Installed",len(definitions),"species,",len(ready),"models,",len(receipt["files"]),"files")


if __name__=="__main__": main()
