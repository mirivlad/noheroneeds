"""Build the caravan cart in Blender, then export an editable blend and glTF.

blender -b -P tools/art/build_caravan_cart.py -- build/caravan/cart.blend assets/experiment_3d/caravan/cart.glb
Blender coordinates: +Y is forward, +Z is up; the glTF exporter converts them.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
blend_path, glb_path = map(os.path.abspath, args[:2])
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)


def material(name, color):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*color, 1)
    m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = .88
    return m


wood = material("weathered oak", (.14, .06, .018))
boards = material("oak boards", (.22, .105, .035))
iron = material("iron", (.045, .05, .06))
rope = material("rope", (.35, .25, .12))
cargo = material("canvas sacks", (.30, .23, .14))


def cube(name, pos, size, mat):
    bpy.ops.mesh.primitive_cube_add(size=1, location=pos)
    obj = bpy.context.object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    return obj


def rod(name, start, end, radius, mat, vertices=10):
    a, b = Vector(start), Vector(end)
    direction = b - a
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=direction.length, location=(a + b) / 2)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    obj.data.materials.append(mat)
    return obj


# Bed length 1.8 m; front at +Y. The seat is deliberately visible above it.
cube("floor", (0, 0, .69), (1.28, 1.8, .13), boards)
for x in (-.64, .64):
    cube("side rail", (x, -.05, .95), (.10, 1.7, .43), wood)
    cube("side top", (x, -.05, 1.19), (.14, 1.8, .08), boards)
cube("back board", (0, -.87, .95), (1.28, .10, .43), boards)
cube("front board", (0, .84, .90), (1.28, .10, .36), boards)
cube("driver bench", (0, .59, 1.08), (1.13, .34, .12), boards)
for x in (-.43, .43):
    cube("bench leg", (x, .59, .88), (.08, .08, .35), wood)
    cube("shaft", (x, 2.15, .53), (.10, 3.8, .10), wood)

# Four spoked wheels; their plane is YZ and their axle lies across X.
wheel_parts = []
for y in (-.59, .59):
    rod("axle", (-.83, y, .46), (.83, y, .46), .065, iron)
    for x in (-.78, .78):
        bpy.ops.mesh.primitive_torus_add(major_segments=24, minor_segments=8,
                                        location=(x, y, .46), rotation=(0, math.pi / 2, 0),
                                        major_radius=.39, minor_radius=.06)
        bpy.context.object.name = "wheel rim"
        bpy.context.object.data.materials.append(wood)
        parts = [bpy.context.object, rod("hub", (x - .1, y, .46), (x + .1, y, .46), .1, iron)]
        for i in range(8):
            a = i * math.tau / 8
            parts.append(rod("spoke", (x, y, .46), (x, y + math.sin(a) * .39, .46 + math.cos(a) * .39), .035, boards, 8))
        wheel_parts.append(parts)

# Cargo is part of the wagon's silhouette, distinct from the seat.
cube("crate", (-.25, -.35, .94), (.46, .55, .38), boards)
cube("crate band", (-.25, -.35, 1.14), (.48, .08, .025), iron)
for x, y in ((.27, -.48), (.23, .02)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=8, location=(x, y, .91))
    obj = bpy.context.object
    obj.name = "sack"
    obj.scale = (.24, .27, .21)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(cargo)

# Reins reach forward from the driver's hands to the horse's bridle.
for x in (-.2, .2):
    rod("rein", (x, .69, 1.30), (x * 1.15, 3.9, 1.03), .018, rope, 6)

# Keep a mesh for the body and one per wheel. Each wheel's origin stays at
# its axle so the game can turn it in proportion to distance travelled.
wheel_objects = {obj for parts in wheel_parts for obj in parts}
body_objects = [obj for obj in bpy.context.scene.objects if obj not in wheel_objects]


def join(objects, name):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    obj = bpy.context.object
    obj.name = name
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)


join(body_objects, "CaravanCart")
for i, parts in enumerate(wheel_parts):
    join(parts, "Wheel%d" % i)

os.makedirs(os.path.dirname(blend_path), exist_ok=True)
os.makedirs(os.path.dirname(glb_path), exist_ok=True)
# The editable file is a Blender intermediate, not a Godot import source.
with open(os.path.join(os.path.dirname(blend_path), ".gdignore"), "a", encoding="utf-8"):
    pass
bpy.ops.wm.save_as_mainfile(filepath=blend_path)
bpy.ops.export_scene.gltf(filepath=glb_path, export_format="GLB", export_apply=True)

# A separate pair of panniers for a horse that carries a load without a cart.
# They share the horse's ground origin and are turned with its facing.
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
for x in (-.32, .32):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=8, location=(x, 0, 1.82))
    obj = bpy.context.object
    obj.name = "pannier"
    obj.scale = (.25, .43, .30)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(cargo)
    rod("pannier strap", (x, -.28, 2.03), (x, .28, 2.03), .028, rope, 8)
rod("saddle strap", (-.40, 0, 2.08), (.40, 0, 2.08), .035, wood, 8)
rod("lead rope", (0, .75, 1.65), (0, 1.8, 1.0), .018, rope, 6)
join(list(bpy.context.scene.objects), "CaravanPacks")
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(os.path.dirname(blend_path), "packs.blend"))
bpy.ops.export_scene.gltf(filepath=os.path.join(os.path.dirname(glb_path), "packs.glb"), export_format="GLB", export_apply=True)
