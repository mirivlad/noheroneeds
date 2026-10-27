"""Put hairstyles from other VRoid models on the base body (Blender side).

Each style of gear.HAIRS is the hair mesh of a VRoid model (CC0, fetch_base.sh):
it is fitted to the base head by the head's skin (scaled until as wide and deep
as the base head, its crown on the base crown), keeps its skinning on the main
bones the hair was hung from (a bone the base has not, a spring bone of the
hair, gives its weights to its nearest ancestor the base has), and rides the base armature. Every style gets the neutral grey ramp
(palette.HAIR): the game paints it any colour. A style's object and collection
are both named hair_<style>.

Usage: blender -b BASE.blend -P build_hair.py -- OUT.blend MODELS_DIR
"""
import os
import shutil
import sys
import tempfile

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_base  # noqa: E402
import gear  # noqa: E402
import palette  # noqa: E402
import toon  # noqa: E402


def main():
	args = sys.argv[sys.argv.index("--") + 1:]
	out, models = os.path.abspath(args[0]), args[1]
	arm, face = bpy.data.objects["Base"], bpy.data.objects["Face"]
	target = skull(face, [v.co for v in face.data.vertices])
	material = toon.ramp_material("hair", palette.HAIR)
	for style, model in gear.HAIRS.items():
		hair = transplant(os.path.join(models, model + ".vrm"), arm, target)
		hair.name = hair.data.name = "hair_" + style
		hair.data.materials.clear()
		hair.data.materials.append(material)
		col = bpy.data.collections.new(hair.name)
		bpy.context.scene.collection.children.link(col)
		for c in hair.users_collection:
			c.objects.unlink(hair)
		col.objects.link(hair)
		print("hair %s from %s: %d vertices" % (style, model, len(hair.data.vertices)))
	bpy.ops.wm.save_as_mainfile(filepath=out)


def skull(obj, cos):
	"""(crown, size) of the head's skin in world space: its top middle and its extent."""
	m = obj.matrix_world
	ps = [m @ c for c in cos]
	lo = Vector([min(p[i] for p in ps) for i in range(3)])
	hi = Vector([max(p[i] for p in ps) for i in range(3)])
	return Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z)), hi - lo


def transplant(path, arm, target):
	before = set(bpy.data.objects)
	with tempfile.TemporaryDirectory() as tmp:
		glb = os.path.join(tmp, "hair.glb")
		shutil.copyfile(path, glb)
		bpy.ops.import_scene.gltf(filepath=glb, bone_heuristic="TEMPERANCE")
	new = set(bpy.data.objects) - before
	src_arm = next(o for o in new if o.type == "ARMATURE")
	hair = next(o for o in new if o.type == "MESH" and o.name.startswith("Hair"))
	face = next(o for o in new if o.type == "MESH" and o.name.startswith("Face"))
	skin = {i for i, m in enumerate(face.data.materials) if "SKIN" in m.name}
	cos = [face.data.vertices[v].co for p in face.data.polygons if p.material_index in skin for v in p.vertices]
	crown, size = skull(face, cos)
	hang_on_base(hair, src_arm, arm)
	for mod in [m for m in hair.modifiers if m.type == "ARMATURE"]:
		hair.modifiers.remove(mod)
	world = hair.matrix_world.copy()
	hair.parent = None
	hair.data.transform(world)
	hair.matrix_world = Matrix.Identity(4)
	# as wide and as deep as the base head, the crown on the base crown
	s = (target[1].x / size.x + target[1].y / size.y) / 2
	hair.data.transform(Matrix.Translation(target[0]) @ Matrix.Scale(s, 4) @ Matrix.Translation(-crown))
	for o in new - {hair}:
		bpy.data.objects.remove(o)
	hair.parent = arm
	hair.modifiers.new("Armature", "ARMATURE").object = arm
	build_base.soft_normals(hair, 10)
	return hair


def hang_on_base(hair, src_arm, arm):
	"""Give the weights of each bone the base armature has not to its nearest ancestor it has."""
	for g in list(hair.vertex_groups):
		if g.name in arm.data.bones:
			continue
		bone = src_arm.data.bones.get(g.name)
		while bone and bone.name not in arm.data.bones:
			bone = bone.parent
		if bone is None:
			raise SystemExit("hair weights on %s, which hangs from no bone of the base" % g.name)
		target = hair.vertex_groups.get(bone.name) or hair.vertex_groups.new(name=bone.name)
		for v in hair.data.vertices:
			for w in v.groups:
				if w.group == g.index and w.weight > 0:
					target.add([v.index], w.weight, "ADD")
		hair.vertex_groups.remove(g)


main()
