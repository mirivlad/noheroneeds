"""Bake licensed hare and 0 A.D. animals through the same RO farm.

blender --disable-autoexec -b -P tools/art/animal_sprites/support.py -- OUT --models Hare Bear Sheep Chicken
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0,str(HERE))
import quaternius as farm

HEIGHTS = {"Hare":.50,"Bear":1.40,"PolarBear":1.50,"Sheep":.90,"Chicken":.42}


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def clean_name(name):
    return re.sub(r"\.\d{3}$","",name)


def import_0ad(name,spec):
    objects = {}
    actions = {}
    arm = None
    rest = None
    for clip in spec["models"][name]["clips"]:
        previous = set(bpy.data.objects)
        old_actions = set(bpy.data.actions)
        bpy.ops.import_scene.gltf(filepath=str(ROOT/f"build/animal_sprites/0ad/{name}-{clip}.glb"))
        made = set(bpy.data.objects)-previous
        action = next(iter(set(bpy.data.actions)-old_actions))
        action.use_fake_user = True
        action.name = clip
        current_arm = next(o for o in made if o.type=="ARMATURE")
        current_rest = {b.name:list(v for row in b.matrix_local for v in row) for b in current_arm.data.bones}
        if arm is None:
            arm,rest = current_arm,current_rest
            objects = {clean_name(o.name):o for o in made}
        elif current_rest!=rest:
            raise ValueError(f"Different bind skeleton: {name}/{clip}")
        bindings = {}
        for obj in made:
            data = obj.animation_data
            if data is None:
                continue
            slot = data.action_slot if data.action==action else None
            if slot is None:
                slot = next((strip.action_slot for track in data.nla_tracks for strip in track.strips if strip.action==action),None)
            if slot:
                bindings[objects[clean_name(obj.name)].name] = slot.handle
        action["sprite_bindings"] = bindings
        actions[clip] = action
        if current_arm!=arm:
            for obj in made:
                bpy.data.objects.remove(obj,do_unlink=True)
    for obj in objects.values():
        obj.animation_data_clear()
    return arm,actions


def palette(image,out):
    if image.packed_file:
        source = out.with_suffix(".source")
        source.write_bytes(image.packed_file.data)
    else:
        source = Path(bpy.path.abspath(image.filepath))
    # Pillow belongs to the host Python; Blender stays free of pip dependencies.
    subprocess.run(["python3","-c",
        "from PIL import Image; import sys; im=Image.open(sys.argv[1]).convert('RGBA'); a=im.getchannel('A'); "
        "im=im.convert('RGB').quantize(24,dither=Image.Dither.NONE).convert('RGBA'); im.putalpha(a); im.save(sys.argv[2])",str(source),str(out)],check=True)
    return bpy.data.images.load(str(out),check_existing=False)


def textured_material(title,image,cutout):
    material = farm.toon.ramp_material(title,[(0,"#858585"),(.33,"#c7c7c7"),(.67,"#ffffff")])
    nodes,links = material.node_tree.nodes,material.node_tree.links
    emission = next(n for n in nodes if n.type=="EMISSION")
    shade = emission.inputs["Color"].links[0].from_socket
    texture = nodes.new("ShaderNodeTexImage")
    texture.image,texture.interpolation = image,"Closest"
    multiply = nodes.new("ShaderNodeMixRGB")
    multiply.blend_type = "MULTIPLY"
    multiply.inputs[0].default_value = 1
    links.new(shade,multiply.inputs[1])
    links.new(texture.outputs["Color"],multiply.inputs[2])
    links.new(multiply.outputs[0],emission.inputs["Color"])
    if cutout:
        output = next(n for n in nodes if n.type=="OUTPUT_MATERIAL")
        transparent = nodes.new("ShaderNodeBsdfTransparent")
        solid = nodes.new("ShaderNodeMath")
        solid.operation = "GREATER_THAN"
        solid.inputs[1].default_value = .5
        links.new(texture.outputs["Alpha"],solid.inputs[0])
        mix = nodes.new("ShaderNodeMixShader")
        links.new(solid.outputs[0],mix.inputs[0])
        links.new(transparent.outputs[0],mix.inputs[1])
        links.new(emission.outputs[0],mix.inputs[2])
        links.new(mix.outputs[0],output.inputs["Surface"])
    return material


def load(name,out):
    clear()
    sources = []
    if name=="Hare":
        manifest = HERE/"support-source.json"
        spec = json.loads(manifest.read_text())[name]
        source = ROOT/spec["file"]
        if hashlib.sha256(source.read_bytes()).hexdigest()!=spec["sha256"]:
            raise ValueError("Changed hare source")
        bpy.ops.wm.open_mainfile(filepath=str(source),load_ui=False,use_scripts=False)
        arm = next(o for o in bpy.context.scene.objects if o.type=="ARMATURE")
        aliases = {"idle":"Sitting.000","walk":"Jump","run":"Running","dead":"Dying.000"}
        actions = {key:bpy.data.actions[value] for key,value in aliases.items()}
        arm.animation_data_clear()
        images = {"Fur":palette(bpy.data.images["Fur-skin"],out/"fur.png"),
            "Fur.001":palette(bpy.data.images["rabbot-skinn"],out/"body.png")}
        body_name,head_name = "Hips","Head"
        sources = [manifest,source]
    else:
        manifest = HERE/"0ad-source.json"
        spec = json.loads(manifest.read_text())
        arm,actions = import_0ad(name,spec)
        source = ROOT/"art_src/0ad_animals"/spec["models"][name]["texture"]
        image = palette(bpy.data.images.load(str(source)),out/"body.png")
        images = {m.name:image for o in bpy.context.scene.objects if o.type=="MESH" for m in o.data.materials}
        candidates = [b.name for b in arm.data.bones]
        head_name = next(n for n in candidates if n.lower()=="head" or n.lower().endswith("_head"))
        body_name = next(n for n in candidates if n.lower().endswith(("_pelvis","_body","body_rear","hips")))
        sources = [manifest,source,*[ROOT/f"build/animal_sprites/0ad/{name}-{c}.glb" for c in actions]]
    farm.use_action(arm,actions["idle"])
    bpy.context.scene.frame_set(0)
    bpy.context.view_layer.update()
    meshes = [o for o in bpy.context.scene.objects if o.type=="MESH" and
        any(m.type=="ARMATURE" and m.object==arm for m in o.modifiers)]
    for obj in list(bpy.context.scene.objects):
        if obj.type in ["CAMERA","LIGHT"] or (obj.type=="MESH" and obj not in meshes):
            bpy.data.objects.remove(obj,do_unlink=True)
    vertices = farm.points(meshes)
    low,high = min(p.z for p in vertices),max(p.z for p in vertices)
    direction = (arm.matrix_world @ arm.pose.bones[head_name].head)-(arm.matrix_world @ arm.pose.bones[body_name].head)
    yaw = math.pi/2-math.atan2(direction.y,direction.x)
    root = bpy.data.objects.new("SpriteRoot",None)
    bpy.context.scene.collection.objects.link(root)
    for obj in list(bpy.context.scene.objects):
        if obj!=root and obj.parent is None:
            obj.parent = root
    scale = HEIGHTS[name]/(high-low)
    root.scale = (scale,)*3
    root.location.z,root.rotation_euler.z = -low*scale,yaw
    for obj in meshes:
        for slot in obj.material_slots:
            if slot.material.name in images:
                slot.material = textured_material("RO "+slot.material.name,images[slot.material.name],name=="Hare")
        obj.hide_render = False
    bpy.context.view_layer.update()
    inventory = {"model":name,"bones":len(arm.data.bones),"vertices":sum(len(o.data.vertices) for o in meshes),
        "mesh_objects":len(meshes),"materials":sorted({m.name for o in meshes for m in o.data.materials}),
        "target_height":HEIGHTS[name],"normalization_scale":scale,"base_yaw":yaw,
        "clips":{key:{"source":a.name,"range":list(a.frame_range)} for key,a in actions.items()}}
    return root,arm,meshes,actions,inventory,sources


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out",type=Path)
    parser.add_argument("--models",nargs="+",default=list(HEIGHTS))
    parser.add_argument("--clips",nargs="+",default=["idle","walk","run","attack","dead"])
    parser.add_argument("--frames",type=int)
    args = parser.parse_args(sys.argv[sys.argv.index("--")+1:])
    args.out = args.out.resolve()
    args.out.mkdir(parents=True,exist_ok=True)
    (args.out/".gdignore").touch()
    for name in args.models:
        out = args.out/name
        (out/"raw").mkdir(parents=True,exist_ok=True)
        root,arm,meshes,actions,inventory,sources = load(name,out)
        wanted = [c for c in args.clips if c in actions]
        plan = farm.frame_plan(actions,wanted,args.frames)
        strides = farm.measure_strides(arm,actions,HEIGHTS[name])
        cell,foot = farm.fit_frames(arm,meshes,plan)
        scene = farm.scene_setup(4,cell,foot)
        volume = farm.volume_material(6)
        report = {"species":name.lower(),"source_kind":"licensed-authored","cell":cell,"foot":foot,
            "px_per_m":farm.PX_PER_M,"scale":4,"directions":farm.ROWS,"clips":{},"anatomy":inventory,"strides":strides,
            "volume":{"span":6,"elevation":22,"px_per_m":farm.PX_PER_M},
            "sources":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                [Path(__file__),HERE/"quaternius.py",HERE/"convert_0ad.py",*sources]}}
        bpy.ops.wm.save_as_mainfile(filepath=str(out/"model.blend"))
        for clip,action,frames,info in plan:
            farm.use_action(arm,action)
            report["clips"][clip] = info
            for i,frame in enumerate(frames):
                scene.frame_set(math.floor(frame),subframe=frame-math.floor(frame))
                for row,direction in enumerate(farm.ROWS):
                    root.rotation_euler.z = inventory["base_yaw"]+math.radians(row*45)
                    bpy.context.view_layer.update()
                    farm.render_frame(scene,out/"raw"/f"{clip}_{direction}_{i:02d}.png",4,volume)
        (out/"render.json").write_text(json.dumps(report,indent=2)+"\n")


if __name__ == "__main__":
    main()
