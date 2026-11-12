"""Join pinned 0 A.D. meshes and authored motions, then convert with Assimp.

python3 tools/art/animal_sprites/convert_0ad.py
Assimp must be installed, or unpacked under build/animal_sprites/assimp/root.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
NS = "{http://www.collada.org/2005/11/COLLADASchema}"


def convert(mesh, motion, output):
    scene = ET.parse(mesh).getroot()
    animation = ET.parse(motion).getroot().find(NS+"library_animations")
    ids = {node.get("id") for node in scene.iter() if node.get("id")}
    parents = {child:parent for parent in scene.iter() for child in parent}
    required = set()
    for joint in scene.iter(NS+"joints"):
        binding = next(item for item in joint if item.get("semantic")=="JOINT")
        array = scene.find(".//%ssource[@id='%s']/%sName_array" % (NS,binding.get("source")[1:],NS))
        names = set(array.text.split())
        for node in scene.iter(NS+"node"):
            if node.get("sid") not in names and node.get("id") not in names:
                continue
            while node.tag==NS+"node":
                required.add(node.get("id"))
                node = parents[node]
    # Attachment markers carry no skin weights. Newer death files include
    # unused markers absent from the original mesh and duplicate decal IDs.
    kept = []
    for node in animation.iter(NS+"animation"):
        channel = node.find(NS+"channel")
        if channel is None:
            continue
        target = channel.get("target").split("/")[0]
        if target in ids and target in required:
            kept.append(node)
    for tag in ("library_animations", "library_animation_clips"):
        for node in scene.findall(NS+tag):
            scene.remove(node)
    # One named motion, preserving all numeric keyframes. Flattening avoids
    # Assimp splitting legacy Blender containers into same-named animations.
    library = ET.SubElement(scene,NS+"library_animations")
    track = ET.SubElement(library,NS+"animation",id="Motion",name="Motion")
    for tag in ("source","sampler","channel"):
        for node in kept:
            for data in node.findall(NS+tag):
                track.append(copy.deepcopy(data))
    ET.register_namespace("",NS[1:-1])
    ET.ElementTree(scene).write(output,encoding="utf-8",xml_declaration=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models",nargs="+")
    args = parser.parse_args()
    source = ROOT/"art_src/0ad_animals"
    spec = json.loads(Path(__file__).with_name("0ad-source.json").read_text())
    for file in spec["files"]:
        if hashlib.sha256((source/file["file"]).read_bytes()).hexdigest()!=file["sha256"]:
            raise ValueError(f"Changed source: {file['file']}")
    assimp = shutil.which("assimp") or str(ROOT/"build/animal_sprites/assimp/root/usr/bin/assimp")
    environment = dict(os.environ)
    if assimp.startswith(str(ROOT/"build")):
        environment["LD_LIBRARY_PATH"] = str(ROOT/"build/animal_sprites/assimp/root/usr/lib/x86_64-linux-gnu")
    out = ROOT/"build/animal_sprites/0ad"
    out.mkdir(parents=True,exist_ok=True)
    (out/".gdignore").touch()
    for name in args.models or spec["models"]:
        model = spec["models"][name]
        for clip,path in model["clips"].items():
            target = out/f"{name}-{clip}.dae"
            convert(source/model["mesh"],source/path,target)
            with target.with_suffix(".log").open("w") as log:
                subprocess.run([assimp,"export",str(target),str(target.with_suffix(".glb")),"-fglb2"],
                    env=environment,stdout=log,stderr=subprocess.STDOUT,check=True)
            print("CONVERTED",name,clip,flush=True)


if __name__ == "__main__":
    main()
