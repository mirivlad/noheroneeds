"""Build a small open forest shelter from poles, branches and patchy thatch.

blender -b -P tools/art/build_bandit_shelter.py -- build/bandits/shelter.blend assets/experiment_3d/bandits/shelter.glb
Original project model. Blender +Z up, opening toward -Y.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

blend_path, glb_path = map(os.path.abspath, sys.argv[sys.argv.index("--") + 1:][:2])
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)


def material(name, color):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*color, 1)
    m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = .95
    return m


bark = material("rough branch bark", (.12, .065, .025))
straw = [material("dry thatch %d" % i, c) for i, c in enumerate([
    (.32, .25, .095), (.26, .19, .065), (.38, .29, .12)])]
cord = material("cord", (.29, .20, .09))


def pole(name, start, end, radius, mat):
    a, b = Vector(start), Vector(end)
    bpy.ops.mesh.primitive_cylinder_add(vertices=7, radius=radius, depth=(b - a).length, location=(a + b) / 2)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = (b - a).to_track_quat("Z", "Y").to_euler()
    obj.data.materials.append(mat)
    return obj


# Raised thatch on a rough timber shack. Its bottom edge clears a standing
# RO human; normal game wood walls supply the physical sides/back. The
# five-cell length accommodates three sleeping places along a central aisle.
for y in (-2.35, 2.35):
    for x in (-1.5, 1.5):
        pole("upright", (x, y, 0), (x, y, 2.0), .065, bark)
        pole("rafter", (x, y, 2.0), (0, y, 2.9), .06, bark)
pole("ridge", (0, -2.5, 2.9), (0, 2.5, 2.9), .075, bark)
for side in (-1, 1):
    for row in range(7):
        t = (row + .5) / 7
        x, z = side * (1.6 * t), 2.0 + .9 * (1 - t)
        pole("thatch lath", (x, -2.45, z), (x, 2.45, z), .035, bark)
        # Separate thick strips make the thatch silhouette rough and readable.
        for col in range(25):
            y = -2.4 + col * .2
            bpy.ops.mesh.primitive_cube_add(size=1, location=(x, y, z + .045))
            obj = bpy.context.object
            obj.name = "bundle of reeds"
            obj.scale = (.34, .23, .09 + .012 * ((col + row) % 3))
            obj.rotation_euler.y = side * math.atan2(.9, 1.6)
            obj.data.materials.append(straw[(col + row) % len(straw)])
for x in (-1.0, 0, 1.0):
    pole("back woven branches", (x, 2.4, 2), (x * .1, 2.4, 2.8), .035, bark)
for y in (-2.2, 2.2):
    for x in (-.6, .6):
        pole("ridge binding", (x * .1, y - .08, 2.76), (-x * .1, y + .08, 2.96), .025, cord)

bpy.ops.object.select_all(action="SELECT")
bpy.context.view_layer.objects.active = bpy.context.selected_objects[0]
bpy.ops.object.convert(target="MESH")
bpy.ops.object.join()
bpy.context.object.name = "ForestShelter"
bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
os.makedirs(os.path.dirname(blend_path), exist_ok=True)
os.makedirs(os.path.dirname(glb_path), exist_ok=True)
open(os.path.join(os.path.dirname(blend_path), ".gdignore"), "a").close()
bpy.ops.wm.save_as_mainfile(filepath=blend_path)
bpy.ops.export_scene.gltf(filepath=glb_path, export_format="GLB", export_apply=True)
