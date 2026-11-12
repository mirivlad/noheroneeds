"""Bake the game animals, serially on one Blender renderer, then export the sheets.

python3 tools/art/animal_sprites/build_production.py [--group quaternius|support|cave]
BLENDER can select the local Blender executable. Requires Assimp and 7z for supporting sources.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--group",choices=["quaternius","support","cave"])
    args = parser.parse_args()
    blender = os.environ.get("BLENDER",str(Path.home()/"bin/blender-5.2.2-linux-x64/blender"))
    out = ROOT/"build/animal_sprites"
    groups = [args.group] if args.group else ["quaternius","support","cave"]
    for group in groups:
        subprocess.run([sys.executable,str(HERE/("fetch_quaternius.py" if group=="quaternius" else "fetch_support.py"))],cwd=ROOT,check=True)
        if group=="support": subprocess.run([sys.executable,str(HERE/"convert_0ad.py")],cwd=ROOT,check=True)
        if group=="quaternius":
            tree = ast.parse((HERE/"quaternius.py").read_text())
            names = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=="NAMES" for t in n.targets))
            models = ["Horse","Horse_White","Cow","Deer","Stag","Wolf","Fox","ArcticFox"]
        else:
            models = ["Hare","Bear","PolarBear","Sheep","Chicken"] if group=="support" else ["CaveRat","CaveSpider"]
        for name in models:
            command = [blender,"--disable-autoexec","-b","-t","4","--python-exit-code","1","-P",str(HERE/("quaternius.py" if group=="quaternius" else "support.py" if group=="support" else "cave.py")),"--",str(out/("production-"+group)),"--models",name]
            if group=="quaternius":
                source = ROOT/"art_src/quaternius_animals/glTF"/(('Fox' if name=='ArcticFox' else name)+'.gltf')
                available = {names[a['name']] for a in json.loads(source.read_text())["animations"] if a['name'] in names}
                command += ["--clips",*[c for c in ["idle","walk","run","attack","dead","hurt"] if c in available],"--volume"]
            subprocess.run(command,cwd=ROOT,check=True)
            if group=="quaternius":
                subprocess.run([blender,"--disable-autoexec","-b","-t","2","--python-exit-code","1","-P",str(HERE/"calibrate.py"),"--",str(out/("production-"+group)/name)],cwd=ROOT,check=True)
            subprocess.run([sys.executable,str(HERE/"export.py"),str(out/("production-"+group)/name)],cwd=ROOT,check=True)


if __name__=="__main__": main()
