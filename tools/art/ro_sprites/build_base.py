"""Build the Ragnarok-Online-proportioned male base body (stage 1 of the sprite pipeline).

Source: VRoid HairSample_Male (CC0, tools/art/ro_sprites/fetch_base.sh). The
clothes and the 3D eyes, brows and mouth are removed; the head is enlarged and
the neck, torso, arms and legs shortened to about four heads; the eye and
mouth openings are closed and levelled, and empties on the head bone mark where
the eyes and the mouth are: the face is drawn in pixels over the sprite
(face2d.py) at their projected points. Tight trunks are a face attribute of the body. Materials are flat toon ramps fed to
an emission shader, so a render holds only the palette colours.

The sample hair stays in the file as object "HairSample" (collection
"hair_sample", not rendered by default) for previews.

Usage: blender -b --factory-startup -P build_base.py -- SRC.vrm OUT.blend LAYOUT.json
"""
import bpy
import bmesh
import json
import math
import os
import shutil
import sys
import tempfile
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import palette  # noqa: E402
import toon  # noqa: E402

# Scale of a bone along world axes (x, y, z) in the source rest pose.
# Ragnarok Online sprites measure about 1 : 1 : 1 for head (with hair) : chin to
# crotch : legs, so the legs lose more than half their length and every limb
# gets thicker.
PROPORTIONS = {
	"J_Bip_C_Spine": (1.0, 1.0, 0.77),
	"J_Bip_C_Neck": (1.0, 1.0, 0.8),
	"J_Bip_C_Head": (1.45, 1.45, 1.45),
	"J_Bip_L_UpperArm": (0.65, 1.1, 1.1),
	"J_Bip_R_UpperArm": (0.65, 1.1, 1.1),
	"J_Bip_L_Hand": (1.15, 1.15, 1.15),
	"J_Bip_R_Hand": (1.15, 1.15, 1.15),
	"J_Bip_L_UpperLeg": (1.15, 1.15, 0.47),
	"J_Bip_R_UpperLeg": (1.15, 1.15, 0.47),
}
# These keep their own size instead of inheriting the parent's scale.
OWN_SCALE = [
	"J_Bip_C_Spine", "J_Bip_C_Neck", "J_Bip_C_Head", "J_Bip_L_UpperArm", "J_Bip_R_UpperArm",
	"J_Bip_L_Hand", "J_Bip_R_Hand", "J_Bip_L_UpperLeg", "J_Bip_R_UpperLeg", "J_Bip_L_Foot", "J_Bip_R_Foot",
]
# Trunks: from this far below the top of the thighs up to this far above the hips joint.
TRUNKS_BELOW_LEGS = 0.10
TRUNKS_ABOVE_HIPS = 0.03
# The eyes look this far outwards from the face direction (for how much of each shows).
EYE_SPLAY = 25
GRIP_SLANT = 22


def main():
	args = sys.argv[sys.argv.index("--") + 1:]
	src, out_blend, out_layout = args[0], os.path.abspath(args[1]), os.path.abspath(args[2])
	bpy.ops.wm.read_factory_settings(use_empty=True)
	with tempfile.TemporaryDirectory() as tmp:
		glb = os.path.join(tmp, "base.glb")
		shutil.copyfile(src, glb)
		bpy.ops.import_scene.gltf(filepath=glb, bone_heuristic="TEMPERANCE")
	arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
	body, face, hair = bpy.data.objects["Body"], bpy.data.objects["Face"], bpy.data.objects["Hair001"]
	for o in list(bpy.data.objects):
		if o not in (arm, body, face, hair):
			bpy.data.objects.remove(o)
	arm.name = arm.data.name = "Base"
	hair.name = "HairSample"
	face.shape_key_clear()

	reshape(arm, [body, face, hair])
	drop = ground(arm, [body, face, hair])
	layout = face_layout(face)
	keep_material(body, ["Body_00_SKIN"])
	# the eyeballs stay as skin: they plug the eye openings; lids, lashes and brows go
	keep_material(face, ["Face_00_SKIN", "EyeWhite", "EyeIris"])
	close_holes(face)
	flatten_face(face, layout)
	face_anchors(arm, face, layout)
	grips(arm)
	for o, n in ((body, 150), (face, 30), (hair, 10)):
		soft_normals(o, n)
	trunks(body, arm)
	remove_unused_bones(arm)

	body.data.materials.clear()
	body.data.materials.append(toon.ramp_material("skin", palette.SKIN, under=("trunks", palette.TRUNKS)))
	face.data.materials.clear()
	face.data.materials.append(body.data.materials[0])
	hair.data.materials.clear()
	hair.data.materials.append(toon.ramp_material("hair_sample", palette.HAIR_SILVER))
	col = bpy.data.collections.new("hair_sample")
	bpy.context.scene.collection.children.link(col)
	for c in hair.users_collection:
		c.objects.unlink(hair)
	col.objects.link(hair)

	layout["height"] = max((body.matrix_world @ v.co).z for v in body.data.vertices)
	layout["head_top"] = max((face.matrix_world @ v.co).z for v in face.data.vertices)
	layout["ground_shift"] = drop
	os.makedirs(os.path.dirname(out_blend), exist_ok=True)
	bpy.ops.wm.save_as_mainfile(filepath=out_blend)
	with open(out_layout, "w") as f:
		json.dump(layout, f, indent=1)
	print("base height %.3f m, head top %.3f m" % (layout["height"], layout["head_top"]))


def local_scale(bone, world):
	"""World-axis scale (x, y, z) as the bone's local scale (bones here are axis aligned)."""
	m = bone.matrix_local.to_3x3()
	return [world[max(range(3), key=lambda k: abs(m.col[i][k]))] for i in range(3)]


def reshape(arm, meshes):
	for name in OWN_SCALE:
		arm.data.bones[name].inherit_scale = "NONE"
	for name, s in PROPORTIONS.items():
		arm.pose.bones[name].scale = local_scale(arm.data.bones[name], s)
	bpy.context.view_layer.update()
	for o in meshes:
		mod = next(m for m in o.modifiers if m.type == "ARMATURE")
		bpy.context.view_layer.objects.active = o
		bpy.ops.object.modifier_apply(modifier=mod.name)
	bpy.context.view_layer.objects.active = arm
	bpy.ops.object.mode_set(mode="POSE")
	bpy.ops.pose.select_all(action="SELECT")
	bpy.ops.pose.armature_apply(selected=False)
	bpy.ops.object.mode_set(mode="OBJECT")
	for b in arm.data.bones:
		b.inherit_scale = "FULL"
	for o in meshes:
		o.modifiers.new("Armature", "ARMATURE").object = arm


def ground(arm, meshes):
	"""Put the soles on z = 0; returns the shift."""
	body = meshes[0]
	low = min((body.matrix_world @ v.co).z for v in body.data.vertices)
	bpy.context.view_layer.objects.active = arm
	bpy.ops.object.mode_set(mode="EDIT")
	for b in arm.data.edit_bones:
		b.head.z -= low
		b.tail.z -= low
	bpy.ops.object.mode_set(mode="OBJECT")
	for o in meshes:
		d = o.matrix_world.inverted().to_3x3() @ Vector((0, 0, -low))
		o.data.transform(Matrix.Translation(d))
	return low


def part_verts(obj, key):
	mats = [i for i, m in enumerate(obj.data.materials) if key in m.name]
	return [obj.matrix_world @ obj.data.vertices[v].co
		for p in obj.data.polygons if p.material_index in mats for v in p.vertices]


def box(vs):
	lo = Vector([min(v[i] for v in vs) for i in range(3)])
	hi = Vector([max(v[i] for v in vs) for i in range(3)])
	return lo, hi


def face_layout(face):
	"""Where the removed 3D eyes, brows and mouth were: [centre, size] in world space."""
	whites = part_verts(face, "EyeWhite")
	out = {"eyes": []}
	for side in (1, -1):  # +x: the character's right eye
		lo, hi = box([v for v in whites if v.x * side > 0])
		out["eyes"].append([list((lo + hi) / 2), list(hi - lo)])
	for key, name in (("FaceBrow", "brows"), ("FaceMouth", "mouth")):
		lo, hi = box(part_verts(face, key))
		out[name] = [list((lo + hi) / 2), list(hi - lo)]
	return out


def flatten_face(face, layout):
	"""Lift the eye sockets and the mouth to a smooth surface fitted to the rest of the face,
	so the drawn eyes are not hidden under the brow when seen from above."""
	import numpy as np
	me = face.data
	co = np.array([face.matrix_world @ v.co for v in me.vertices])
	ny = np.array([(face.matrix_world.to_3x3() @ v.normal).normalized().y for v in me.vertices])
	areas = layout["eyes"] + [layout["mouth"]]

	def inside(c, s, grow):
		return (np.abs(co[:, 0] - c[0]) < s[0] / 2 * grow) & (np.abs(co[:, 2] - c[2]) < s[2] / 2 * grow + 0.004)

	zs = [a[0][2] for a in areas]
	xs = max(abs(a[0][0]) + a[1][0] / 2 for a in areas)
	front = (ny > 0.3) & (co[:, 2] > min(zs) - 0.06) & (co[:, 2] < max(zs) + 0.07) & (np.abs(co[:, 0]) < xs + 0.03)
	holes = np.zeros(len(co), bool)
	for c, s in areas:
		holes |= inside(c, s, 1.5)
	fit = front & ~holes
	x, z = co[fit, 0], co[fit, 2]
	basis = lambda x, z: np.stack([np.ones_like(x), x, z, x * x, z * z, x * z], 1)  # noqa: E731
	k, *_ = np.linalg.lstsq(basis(x, z), co[fit, 1], rcond=None)
	surface = basis(co[:, 0], co[:, 2]) @ k
	lift = np.zeros(len(co))
	for c, s in areas:
		for grow, w in ((1.9, 0.5), (1.5, 1.0)):
			lift = np.where(inside(c, s, grow) & (co[:, 1] > c[1] - 0.05), np.maximum(lift, w), lift)
	inv = face.matrix_world.inverted()
	for i, v in enumerate(me.vertices):
		if lift[i] > 0 and co[i, 1] < surface[i]:
			p = Vector(co[i])
			p.y += (surface[i] - co[i, 1]) * lift[i]
			v.co = inv @ p


def keep_material(obj, keys):
	bm = bmesh.new()
	bm.from_mesh(obj.data)
	keep = [i for i, m in enumerate(obj.data.materials) if any(k in m.name for k in keys)]
	bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.material_index not in keep], context="FACES")
	bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
	for f in bm.faces:
		f.material_index = 0
	bm.to_mesh(obj.data)
	bm.free()


def close_holes(face):
	"""Cap the mouth opening (and the neck) left by the removed parts."""
	bm = bmesh.new()
	bm.from_mesh(face.data)
	res = bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary], sides=0)
	bmesh.ops.triangulate(bm, faces=res["faces"])
	bm.to_mesh(face.data)
	bm.free()


def face_anchors(arm, face, layout):
	"""Empties on the head bone at the face surface: eye_r, eye_l, mouth; local +Y is where each looks."""
	inv = face.matrix_world.inverted()

	def surface(x, z):
		hit, loc, *_ = face.ray_cast(inv @ Vector((x, 1.0, z)), inv.to_3x3() @ Vector((0, -1, 0)))
		assert hit, (x, z)
		return (face.matrix_world @ loc).y

	spots = [("eye_r", layout["eyes"][0][0], EYE_SPLAY), ("eye_l", layout["eyes"][1][0], -EYE_SPLAY),
		("mouth", layout["mouth"][0], 0)]
	for name, c, turn in spots:
		e = bpy.data.objects.new(name, None)
		e.empty_display_size = 0.02
		bpy.context.scene.collection.objects.link(e)
		e.parent = arm
		e.parent_type = "BONE"
		e.parent_bone = "J_Bip_C_Head"
		x = 0.0 if name == "mouth" else c[0]
		e.matrix_world = Matrix.Translation((x, surface(x, c[2]), c[2])) @ Matrix.Rotation(math.radians(-turn), 4, "Z")
		layout[name] = list(e.matrix_world.to_translation())


def grips(arm):
	"""Empties grip_l / grip_r in the middle of each fist, parented to the hand: their local +Y
	runs along a held handle and points out on the thumb side (forward when the arm hangs).
	A handle crosses the palm slantwise, from the base of the little finger to between
	thumb and index, so the axis leans GRIP_SLANT degrees towards the fingers."""
	for s in ("L", "R"):
		bones = arm.data.bones
		hand = bones[f"J_Bip_{s}_Hand"].head_local
		knuckle = bones[f"J_Bip_{s}_Middle1"].head_local
		centre = knuckle - (knuckle - hand) * 0.1 + Vector((0, 0.005, -0.028))
		e = bpy.data.objects.new("grip_" + s.lower(), None)
		e.empty_display_size = 0.05
		e.empty_display_type = "ARROWS"
		bpy.context.scene.collection.objects.link(e)
		e.parent = arm
		e.parent_type = "BONE"
		e.parent_bone = f"J_Bip_{s}_Hand"
		lean = GRIP_SLANT if s == "L" else -GRIP_SLANT  # the fingers point to -X on the left
		e.matrix_world = Matrix.Translation(centre) @ Matrix.Rotation(math.radians(lean), 4, "Z")


def soft_normals(obj, iterations):
	"""Shade by the normals of a smoothed copy: VRoid's ribs and knees break flat tones into specks."""
	src = obj.copy()
	src.data = obj.data.copy()
	bpy.context.scene.collection.objects.link(src)
	src.modifiers.clear()
	sm = src.modifiers.new("smooth", "SMOOTH")
	sm.factor, sm.iterations = 1.0, iterations
	dt = obj.modifiers.new("soft_normals", "DATA_TRANSFER")
	dt.object = src
	dt.use_loop_data = True
	dt.data_types_loops = {"CUSTOM_NORMAL"}
	dt.loop_mapping = "POLYINTERP_NEAREST"
	bpy.context.view_layer.objects.active = obj
	bpy.ops.object.modifier_move_to_index(modifier=dt.name, index=0)
	bpy.ops.object.modifier_apply(modifier=dt.name)
	bpy.data.objects.remove(src)


def trunks(body, arm):
	legs = arm.data.bones["J_Bip_L_UpperLeg"].head_local.z
	hips = arm.data.bones["J_Bip_C_Hips"].head_local.z
	lo, hi = legs - TRUNKS_BELOW_LEGS, hips + TRUNKS_ABOVE_HIPS
	me = body.data
	att = me.attributes.new("trunks", "FLOAT", "FACE")
	for p in me.polygons:
		z = (body.matrix_world @ p.center).z
		att.data[p.index].value = 1.0 if lo <= z <= hi else 0.0


def remove_unused_bones(arm):
	bpy.context.view_layer.objects.active = arm
	bpy.ops.object.mode_set(mode="EDIT")
	for b in list(arm.data.edit_bones):
		if b.name.startswith("J_Sec_"):
			arm.data.edit_bones.remove(b)
	bpy.ops.object.mode_set(mode="OBJECT")


main()
