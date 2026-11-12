"""Bake br-n518's CC0 rat and spider with their authored rigs and motions."""
import argparse
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
import quaternius as farm
from support import palette, textured_material

MODELS = {
    "CaveRat":{"source":"rat","height":.32,"head":"head","body":"base",
        "clips":{"idle":"idle-loop","walk":"walk-loop","run":"run-loop","attack":"attack","dead":"death"}},
    "CaveSpider":{"source":"spider","height":.28,"head":"thorax","body":"abdomen",
        "clips":{"idle":"IDLE","walk":"WALK","run":"WALK","attack":"ATTACK"}},
}


def strides(arm,actions,height):
    # These legacy rigs name their feet FL/BR or leg_AL, not foot/hoof/paw.
    # Sample low joints, excluding stationary controls by their zero travel.
    result = {}
    for gait in ["walk","run"]:
        action = actions[gait]
        farm.use_action(arm,action)
        start,end = action.frame_range
        samples = []
        for i in range(101):
            frame = start+(end-start)*i/100
            bpy.context.scene.frame_set(math.floor(frame),subframe=frame-math.floor(frame))
            bpy.context.view_layer.update()
            samples.append([arm.matrix_world@bone.tail for bone in arm.pose.bones])
        seconds = (end-start)/bpy.context.scene.render.fps
        velocities = []
        for joint in range(len(arm.pose.bones)):
            low = min(sample[joint].z for sample in samples)
            if low>height*.2: continue
            for previous,current in zip(samples,samples[1:]):
                a,b = previous[joint],current[joint]
                velocity = (a.y-b.y)*100/seconds
                if max(a.z,b.z)<low+.02 and velocity>.02: velocities.append(velocity)
        if velocities: result[gait] = statistics.median(velocities)*seconds
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out",type=Path)
    parser.add_argument("--models",nargs="+",default=list(MODELS))
    parser.add_argument("--frames",type=int)
    args = parser.parse_args(sys.argv[sys.argv.index("--")+1:])
    args.out = args.out.resolve()
    args.out.mkdir(parents=True,exist_ok=True)
    (args.out/".gdignore").touch()
    sources = json.loads((HERE/"cave-source.json").read_text())
    for info in sources["files"]+sources["extracted"]:
        source = ROOT/info["file"]
        if hashlib.sha256(source.read_bytes()).hexdigest()!=info["sha256"]:
            raise ValueError(f"Changed source: {source}")
    for name in args.models:
        spec = MODELS[name]
        source = ROOT/"art_src/cave_animals"/(spec["source"]+".blend")
        texture = source.with_suffix(".png")
        out = args.out/name
        (out/"raw").mkdir(parents=True,exist_ok=True)
        bpy.ops.wm.open_mainfile(filepath=str(source),use_scripts=False)
        arm = next(o for o in bpy.data.objects if o.type=="ARMATURE")
        meshes = [o for o in bpy.data.objects if o.type=="MESH" and any(m.type=="ARMATURE" and m.object==arm for m in o.modifiers)]
        actions = {clip:bpy.data.actions[action] for clip,action in spec["clips"].items()}
        arm.animation_data_clear()
        farm.use_action(arm,actions["idle"])
        bpy.context.scene.frame_set(0)
        for obj in list(bpy.context.scene.objects):
            if obj not in meshes and obj!=arm:
                bpy.data.objects.remove(obj,do_unlink=True)
        bpy.context.view_layer.update()
        vertices = farm.points(meshes)
        low,high = min(p.z for p in vertices),max(p.z for p in vertices)
        direction = arm.data.bones[spec["head"]].head_local-arm.data.bones[spec["body"]].head_local
        yaw = math.pi/2-math.atan2(direction.y,direction.x)
        root = bpy.data.objects.new("SpriteRoot",None)
        bpy.context.scene.collection.objects.link(root)
        arm.parent = root
        root.scale = (spec["height"]/(high-low),)*3
        root.location.z = -low*root.scale.z
        root.rotation_euler.z = yaw
        image = palette(bpy.data.images.load(str(texture),check_existing=False),out/"body.png")
        material = textured_material("RO "+name,image,False)
        for obj in meshes:
            for slot in obj.material_slots: slot.material = material
        bpy.context.view_layer.update()
        plan = farm.frame_plan(actions,list(actions),args.frames)
        measured = strides(arm,actions,spec["height"])
        cell,foot = farm.fit_frames(arm,meshes,plan)
        scene = farm.scene_setup(4,cell,foot)
        volume = farm.volume_material(6)
        report = {"species":name.lower(),"source_kind":"licensed-authored","cell":cell,"foot":foot,
            "px_per_m":farm.PX_PER_M,"scale":4,"directions":farm.ROWS,"clips":{},"strides":measured,
            "anatomy":{"model":name,"bones":len(arm.data.bones),"vertices":sum(len(o.data.vertices)for o in meshes),"target_height":spec["height"]},
            "volume":{"span":6,"elevation":22,"px_per_m":farm.PX_PER_M},
            "sources":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                [Path(__file__),HERE/"quaternius.py",HERE/"support.py",HERE/"cave-source.json",source,texture]}}
        bpy.ops.wm.save_as_mainfile(filepath=str(out/"model.blend"))
        for clip,action,frames,info in plan:
            farm.use_action(arm,action)
            report["clips"][clip] = info
            for i,frame in enumerate(frames):
                scene.frame_set(math.floor(frame),subframe=frame-math.floor(frame))
                for row,direction in enumerate(farm.ROWS):
                    root.rotation_euler.z = yaw+math.radians(row*45)
                    bpy.context.view_layer.update()
                    farm.render_frame(scene,out/"raw"/f"{clip}_{direction}_{i:02d}.png",4,volume)
        (out/"render.json").write_text(json.dumps(report,indent=2)+"\n")


if __name__=="__main__": main()
