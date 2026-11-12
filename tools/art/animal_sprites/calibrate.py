"""Measure Quaternius strides from lower-leg endpoints in saved normalized rigs.

blender --disable-autoexec -b -P tools/art/animal_sprites/calibrate.py -- BUILD_DIR [BUILD_DIR ...]
Colour/depth renders are untouched; only measured gait metadata is added.
"""
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys

import bpy

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0,str(HERE))
from quaternius import use_action, load_model


def main():
    for directory in sys.argv[sys.argv.index("--")+1:]:
        directory = Path(directory).resolve()
        report = json.loads((directory/"render.json").read_text())
        for source,expected in report["sources"].items():
            if hashlib.sha256((ROOT/source).read_bytes()).hexdigest()!=expected:
                raise ValueError(f"Changed source: {source}")
        bpy.ops.wm.read_factory_settings(use_empty=True)
        name = directory.name
        source = ROOT/"art_src/quaternius_animals/glTF"/(('Fox' if name=='ArcticFox' else name)+'.gltf')
        root,arm,meshes,actions,inventory = load_model(name,source)
        feet = [p for p in arm.pose.bones if "lowerleg" in p.name.lower() and not any(s in p.name.lower()for s in ["ik","target"])]
        if not feet: raise ValueError(f"No lower-leg endpoints: {directory.name}")
        strides = {}
        for gait in ["walk","run"]:
            action = actions[gait]
            use_action(arm,action)
            first,last = action.frame_range
            seconds = (last-first)/bpy.context.scene.render.fps
            samples = []
            for i in range(101):
                frame = first+(last-first)*i/100
                bpy.context.scene.frame_set(math.floor(frame),subframe=frame-math.floor(frame))
                bpy.context.view_layer.update()
                samples.append([arm.matrix_world@p.tail for p in feet])
            speeds = []
            for foot in range(len(feet)):
                ground = min(row[foot].z for row in samples)
                for a,b in zip(samples,samples[1:]):
                    if max(a[foot].z,b[foot].z)<=ground+max(.015,report["anatomy"]["target_height"]*.03):
                        speed = (a[foot].y-b[foot].y)*100/seconds
                        if speed>.05: speeds.append(speed)
            if not speeds: raise ValueError(f"No planted backward travel: {directory.name}/{gait}")
            strides[gait] = statistics.median(speeds)*seconds
        report["strides"] = strides
        report["calibration"] = {"feet":[p.name+".tail"for p in feet],"samples":101,"method":"median backward speed during each foot's ground phase","source_sha256":inventory["source_sha256"]}
        report["sources"][str(Path(__file__).relative_to(ROOT))] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        (directory/"render.json").write_text(json.dumps(report,indent=2)+"\n")
        print("CALIBRATED",directory.name,strides,flush=True)


if __name__=="__main__": main()
