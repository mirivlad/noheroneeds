"""Bake the selected Quaternius pack with the RO camera/toon/pixel pipeline.

Import authored rigs and clips intact. This does not use the procedural horse.
blender -b -t 4 --python-exit-code 1 -P tools/art/animal_sprites/quaternius.py -- OUT --models Horse --clips idle walk run
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
import sys

import bpy
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0,str(HERE.parent/"ro_sprites"))
import toon
from palette import tones

ROWS = ["s","se","e","ne","n","nw","w","sw"]
CELL,FOOT,PX_PER_M = 256,204,77
HEIGHTS = {"Horse":1.62,"Horse_White":1.62,"Cow":1.30,"Bull":1.42,"Deer":1.52,"Stag":2.05,
    "Donkey":1.40,"Alpaca":1.60,"Wolf":.78,"Fox":.52,"ArcticFox":.52,"Husky":.65,"ShibaInu":.55}
NAMES = {"Idle":"idle","Idle_2":"idle_2","Idle_Headlow":"idle_low","Idle_2_HeadLow":"idle_low",
    "Walk":"walk","Gallop":"run","Eating":"graze","Death":"dead","Attack":"attack",
    "Attack_Headbutt":"attack","Attack_Kick":"kick","Idle_HitReact1":"hurt","Idle_HitReact2":"hurt_2",
    "Gallop_Jump":"run_jump","Jump_toIdle":"jump","Jump_ToIdle":"jump"}
LOOPS = {"idle","idle_2","idle_low","walk","run","graze"}


def use_action(arm,action):
    if "sprite_bindings" in action:
        for name,handle in action["sprite_bindings"].items():
            obj = bpy.data.objects[name]
            obj.animation_data_create()
            obj.animation_data.action = action
            obj.animation_data.action_slot = next(s for s in action.slots if s.handle==handle)
        return
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = action
    for slot in action.slots:
        if any(bag and any(c.data_path.startswith("pose.bones[") for c in bag.fcurves)
                for layer in action.layers for strip in layer.strips for bag in [strip.channelbag(slot)]):
            arm.animation_data.action_slot = slot
            break


def measure_strides(arm,actions,height):
    """Distance per authored cycle from backward-moving grounded foot joints."""
    feet = [p for p in arm.pose.bones if any(s in p.name.lower() for s in ("foot","hoof","paw","toe"))
        and not any(s in p.name.lower() for s in ("ik","target"))]
    result = {}
    for clip in ("walk","run"):
        if clip not in actions or not feet:
            continue
        action = actions[clip]
        use_action(arm,action)
        first,last = action.frame_range
        seconds = (last-first)/bpy.context.scene.render.fps
        if seconds<=0:
            continue
        samples = []
        for i in range(101):
            frame = first+(last-first)*i/100
            bpy.context.scene.frame_set(math.floor(frame),subframe=frame-math.floor(frame))
            bpy.context.view_layer.update()
            samples.append([arm.matrix_world @ p.head for p in feet])
        speeds = []
        for foot in range(len(feet)):
            ground = min(row[foot].z for row in samples)
            for a,b in zip(samples,samples[1:]):
                if max(a[foot].z,b[foot].z)<=ground+max(.015,height*.03):
                    speed = (a[foot].y-b[foot].y)*100/seconds
                    if speed>.05:
                        speeds.append(speed)
        if speeds:
            result[clip] = statistics.median(speeds)*seconds
    return result


def points(meshes):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    return [obj.matrix_world @ v.co for obj in meshes for v in obj.evaluated_get(depsgraph).data.vertices]


def load_model(name,source):
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj,do_unlink=True)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    bpy.data.orphans_purge(do_recursive=True)
    bpy.ops.import_scene.gltf(filepath=str(source))
    arm = next(o for o in bpy.context.scene.objects if o.type=="ARMATURE")
    meshes = [o for o in bpy.context.scene.objects if o.type=="MESH" and (o.parent==arm
        or any(m.type=="ARMATURE" and m.object==arm for m in o.modifiers))]
    if not meshes:
        raise ValueError(f"No skinned animal mesh: {name}")
    # With COLOR_0 the importer leaves Material.diffuse_color white, while
    # the real base factor lives in its node graph. Use the pinned glTF factor.
    source_colours = {m["name"]:m.get("pbrMetallicRoughness",{}).get("baseColorFactor",[1,1,1,1])
        for m in json.loads(source.read_text())["materials"]}
    if name=="ArcticFox":
        source_colours.update({"Main":[.65,.65,.62,1],"Main_Light":[.83,.83,.80,1],"Grey":[.35,.35,.34,1]})
    for obj in meshes:
        for material in obj.data.materials:
            material.diffuse_color = source_colours[material.name]
    # The importer creates hidden icosphere bone widgets; these are not animal art.
    for obj in list(bpy.context.scene.objects):
        if obj.type=="MESH" and obj not in meshes:
            bpy.data.objects.remove(obj,do_unlink=True)
    actions = {NAMES[a.name]:a for a in bpy.data.actions if a.name in NAMES}
    arm.animation_data_clear()  # no NLA mixing while sampling one authored clip
    use_action(arm,actions["idle"])
    bpy.context.scene.frame_set(0)
    bpy.context.view_layer.update()
    verts = points(meshes)
    bottom,top = min(p.z for p in verts),max(p.z for p in verts)
    head = arm.data.bones["Head"].head_local
    body = arm.data.bones["Body"].head_local
    yaw = math.pi/2-math.atan2(head.y-body.y,head.x-body.x)
    root = bpy.data.objects.new("SpriteRoot",None)
    bpy.context.scene.collection.objects.link(root)
    arm.parent = root
    scale = HEIGHTS[name]/(top-bottom)
    root.scale = (scale,)*3
    root.location.z = -bottom*scale
    root.rotation_euler.z = yaw
    bpy.context.view_layer.update()
    inventory = {"model":name,"source_sha256":hashlib.sha256(source.read_bytes()).hexdigest(),
        "bones":len(arm.data.bones),"vertices":sum(len(o.data.vertices) for o in meshes),
        "mesh_objects":len(meshes),"materials":sorted({m.name for o in meshes for m in o.data.materials}),
        "clips":{key:{"source":action.name,"range":list(action.frame_range)} for key,action in actions.items()},
        "target_height":HEIGHTS[name],"source_height":top-bottom,"normalization_scale":scale,"base_yaw":yaw}
    return root,arm,meshes,actions,inventory


def srgb(linear):
    return linear*12.92 if linear<=.0031308 else 1.055*linear**(1/2.4)-.055


def colour(values):
    rgb = [max(0,min(255,round(v*255))) for v in values]
    # RoSprite's human skin shader recognises exact greys; animal greys stay neutral.
    if rgb[0]==rgb[1]==rgb[2] and rgb[0]<240:
        rgb[2] = max(0,rgb[2]-1)
    return "#"+"".join(f"{v:02x}" for v in rgb)


def paint(meshes):
    replacements = {}
    for obj in meshes:
        attribute = obj.data.color_attributes[0].name if obj.data.color_attributes else ""
        for slot in obj.material_slots:
            material = slot.material
            cache_key = (material.name,attribute)
            if cache_key not in replacements:
                key = material.name.lower()
                if "eye" in key and "white" in key:
                    ramp = [(0,"#f5f2e9"),(1,"#f5f2e9")]
                elif "eye" in key and "black" in key:
                    ramp = [(0,"#17140f"),(1,"#17140f")]
                else:
                    base = [srgb(v) for v in material.diffuse_color[:3]]
                    ramp = tones(colour([v*.58 for v in base]),colour(base),colour([v+(1-v)*.20 for v in base]))
                painted = toon.ramp_material("RO "+material.name,ramp)
                if attribute and not ("eye" in key and ("black" in key or "white" in key)):
                    nodes,links = painted.node_tree.nodes,painted.node_tree.links
                    emit = next(n for n in nodes if n.type=="EMISSION")
                    shade = emit.inputs["Color"].links[0].from_socket
                    vertex = nodes.new("ShaderNodeVertexColor")
                    vertex.layer_name = attribute
                    multiply = nodes.new("ShaderNodeMixRGB")
                    multiply.blend_type = "MULTIPLY"
                    multiply.inputs[0].default_value = 1
                    links.new(shade,multiply.inputs[1])
                    links.new(vertex.outputs["Color"],multiply.inputs[2])
                    links.new(multiply.outputs[0],emit.inputs["Color"])
                replacements[cache_key] = painted
            slot.material = replacements[cache_key]


def scene_setup(scale,cell,foot):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.film_transparent = True
    scene.render.resolution_x = scene.render.resolution_y = cell*scale
    scene.render.resolution_percentage = 100
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.file_format = "PNG"
    scene.render.filter_size = .5
    scene.eevee.taa_render_samples = 1
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.world = bpy.data.worlds.new("Transparent")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0
    data = bpy.data.cameras.new("RO camera")
    data.type,data.ortho_scale = "ORTHO",cell/PX_PER_M
    camera = bpy.data.objects.new("RO camera",data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    elevation = math.radians(22)
    forward = Vector((0,-math.cos(elevation),-math.sin(elevation)))
    up = Vector((0,-math.sin(elevation),math.cos(elevation)))
    camera.location = up*((foot-cell/2)/PX_PER_M)-forward*20
    camera.rotation_euler = forward.to_track_quat("-Z","Y").to_euler()
    light = bpy.data.lights.new("RO sun","SUN")
    light.energy,light.angle,light.use_shadow = math.pi,0,False
    sun = bpy.data.objects.new("RO sun",light)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (-Vector((.8,.35,.7))).to_track_quat("-Z","Y").to_euler()
    bpy.ops.mesh.primitive_plane_add(size=20,location=(0,0,-.002))
    bpy.context.object.name = "Ground holdout"
    bpy.context.object.is_holdout = True
    return scene


def volume_material(span):
    """World Y toward the camera; keep real body depth alongside sprite colour."""
    material = bpy.data.materials.new("Animal volume")
    material.use_nodes = True
    nodes,links = material.node_tree.nodes,material.node_tree.links
    nodes.clear()
    geometry = nodes.new("ShaderNodeNewGeometry")
    xyz = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geometry.outputs["Position"],xyz.inputs[0])
    mapped = nodes.new("ShaderNodeMapRange")
    mapped.inputs["From Min"].default_value = -span/2
    mapped.inputs["From Max"].default_value = span/2
    links.new(xyz.outputs["Y"],mapped.inputs["Value"])
    emission = nodes.new("ShaderNodeEmission")
    links.new(mapped.outputs["Result"],emission.inputs["Color"])
    output = nodes.new("ShaderNodeOutputMaterial")
    links.new(emission.outputs[0],output.inputs["Surface"])
    return material


def render_frame(scene,path,scale,volume):
    scene.view_layers[0].material_override = None
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = "Standard"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    if volume:
        scene.view_layers[0].material_override = volume
        scene.render.resolution_percentage = 200//scale
        scene.view_settings.view_transform = "Raw"
        scene.render.image_settings.color_mode = "BW"
        scene.render.image_settings.color_depth = "16"
        scene.render.filepath = str(path.with_suffix(".volume.png"))
        bpy.ops.render.render(write_still=True)


def harness_points(scene,arm,meshes,row,rest_body):
    """Shaft and bridle endpoints on this exact filmed horse pose."""
    angle = math.radians(row*45)
    side = Vector((math.cos(angle),math.sin(angle),0))
    forward = Vector((-math.sin(angle),math.cos(angle),0))
    body = arm.matrix_world @ arm.pose.bones["Body"].matrix.to_translation()
    body.z += 1.0-rest_body.z
    body += forward*.25
    muzzle = []
    graph = bpy.context.evaluated_depsgraph_get()
    for obj in meshes:
        indices = {i for p in obj.data.polygons if "muzzle" in obj.data.materials[p.material_index].name.lower() for i in p.vertices}
        evaluated = obj.evaluated_get(graph)
        muzzle.extend(obj.matrix_world @ evaluated.data.vertices[i].co for i in indices)
    if not muzzle:
        raise ValueError("Horse has no muzzle surface for the bridle")
    head = sum(muzzle,Vector())/len(muzzle)
    result = []
    for point in [body-side*.40,body+side*.40,head-side*.09,head+side*.09]:
        uv = world_to_camera_view(scene,scene.camera,point)
        cell = scene.camera.data.ortho_scale*PX_PER_M
        # Relative to the common ground origin, independent of atlas cropping.
        origin = world_to_camera_view(scene,scene.camera,Vector())
        result.append([(uv.x-origin.x)*cell,(uv.y-origin.y)*cell,point.y])
    return result


def frame_plan(actions,wanted,limit):
    plan = []
    fps = bpy.context.scene.render.fps
    for clip in wanted:
        action = actions[clip]
        start,end = action.frame_range
        seconds = (end-start)/fps
        rate = 1.2 if clip.startswith("idle") else (20 if clip=="run" else 12)
        count = max(2,math.ceil(seconds*rate-1e-5))
        if limit:
            count = min(count,limit)
        loop = clip in LOOPS
        frames = [start+(end-start)*(i/count if loop else i/max(1,count-1)) for i in range(count)]
        plan.append((clip,action,frames,{"frames":count,"fps":count/seconds,"loop":loop,"source":action.name,"duration":seconds}))
    return plan


def fit_frames(arm,meshes,plan):
    radius,above,below = 0,0,0
    sine,cosine = math.sin(math.radians(22)),math.cos(math.radians(22))
    for _,action,frames,_ in plan:
        use_action(arm,action)
        for frame in frames:
            bpy.context.scene.frame_set(math.floor(frame),subframe=frame-math.floor(frame))
            bpy.context.view_layer.update()
            for p in points(meshes):
                r = math.hypot(p.x,p.y)
                radius = max(radius,r)
                above = max(above,p.z*cosine+r*sine)
                below = max(below,-p.z*cosine+r*sine)
    cell = math.ceil(max(CELL,2*radius*PX_PER_M+32,(above+below)*PX_PER_M+32)/16)*16
    foot = max(math.ceil(above*PX_PER_M+16),cell-max(52,math.ceil(below*PX_PER_M+16)))
    return cell,foot


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out",type=Path)
    parser.add_argument("--models",nargs="+",default=["Horse"])
    parser.add_argument("--clips",nargs="+",default=["idle","walk","run"])
    parser.add_argument("--frames",type=int)
    parser.add_argument("--scale",type=int,default=4)
    parser.add_argument("--inspect-only",action="store_true")
    parser.add_argument("--volume",action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--")+1:])
    args.out = args.out.resolve()
    args.out.mkdir(parents=True,exist_ok=True)
    (args.out/".gdignore").touch()
    spec = json.loads((HERE/"quaternius-source.json").read_text())
    models = list(HEIGHTS) if args.models==["all"] else args.models
    inventory = []
    for name in models:
        relative = f"glTF/{'Fox' if name=='ArcticFox' else name}.gltf"
        source = ROOT/"art_src/quaternius_animals"/relative
        if hashlib.sha256(source.read_bytes()).hexdigest()!=spec["files"][relative]["sha256"]:
            raise ValueError(f"Unverified source: {name}")
        root,arm,meshes,actions,item = load_model(name,source)
        inventory.append(item)
        if args.inspect_only:
            continue
        wanted = list(actions) if args.clips==["all"] else args.clips
        plan = frame_plan(actions,wanted,args.frames)
        strides = measure_strides(arm,actions,HEIGHTS[name])
        cell,foot = fit_frames(arm,meshes,plan)
        paint(meshes)
        scene = scene_setup(args.scale,cell,foot)
        volume = volume_material(6) if args.volume else None
        use_action(arm,actions["idle"])
        scene.frame_set(0)
        bpy.context.view_layer.update()
        rest_body = arm.matrix_world @ arm.pose.bones["Body"].matrix.to_translation() if name.startswith("Horse") else None
        out = args.out/name
        raw = out/"raw"
        raw.mkdir(parents=True,exist_ok=True)
        report = {"species":name.lower(),"source_kind":"quaternius-authored","cell":cell,"foot":foot,
            "px_per_m":PX_PER_M,"scale":args.scale,"directions":ROWS,"clips":{},"anatomy":item,
            "strides":strides,
            "sources":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                [HERE/"quaternius.py",HERE/"quaternius-source.json",HERE.parent/"ro_sprites/toon.py",HERE.parent/"ro_sprites/pixelate.py",source]}}
        if volume:
            report["volume"] = {"span":6,"elevation":22,"px_per_m":PX_PER_M}
        if rest_body is not None:
            report["harness"] = {}
        bpy.ops.wm.save_as_mainfile(filepath=str(out/"model.blend"))
        for clip,action,frames,info in plan:
            use_action(arm,action)
            report["clips"][clip] = info
            if rest_body is not None:
                report["harness"][clip] = []
            for i,frame in enumerate(frames):
                scene.frame_set(math.floor(frame),subframe=frame-math.floor(frame))
                anchors = []
                for row,direction in enumerate(ROWS):
                    root.rotation_euler.z = item["base_yaw"]+math.radians(row*45)
                    bpy.context.view_layer.update()
                    if rest_body is not None:
                        anchors.append(harness_points(scene,arm,meshes,row,rest_body))
                    render_frame(scene,raw/f"{clip}_{direction}_{i:02d}.png",args.scale,volume)
                if rest_body is not None:
                    report["harness"][clip].append(anchors)
        (out/"render.json").write_text(json.dumps(report,indent=2)+"\n")
    (args.out/"inventory.json").write_text(json.dumps(inventory,indent=2)+"\n")


if __name__ == "__main__":
    main()
