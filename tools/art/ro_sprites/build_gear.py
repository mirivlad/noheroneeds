"""Build the clothes and gear of stage 4 on the base body (Blender side).

Every item of gear.py gets a collection of its own name in a copy of the base
file. Worn clothes are shells of the body: the body's faces of the covered
part pushed out along their normals, with the body's skin weights, so they
bend in every pose exactly as the body under them. Headwear is a shell around
the head and the hairstyles, cut along the brow and the nape, riding the head
bone. A cloak is a sheet hanging from the shoulders on two cape bones
(Cape1, Cape2) that rig.py swings clear of the legs. Held things are built
along the grip axis of the fist: +Y out of the thumb side, +X the way the
forearm points for the right hand (an axe's edge), the other way for the left.

Materials are the flat toon ramps of toon.py with the colours of palette.py; a
second ramp is painted on faces with the "trim" attribute (bands, rims, fur).

Usage: blender -b BASE.blend -P build_gear.py -- OUT.blend
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gear  # noqa: E402
import palette as pal  # noqa: E402
import toon  # noqa: E402

C = "J_Bip_C_"
TORSO = {C + "Spine", C + "Chest", C + "UpperChest", "J_Bip_L_Shoulder", "J_Bip_R_Shoulder"}
ARMS = {f"J_Bip_{s}_{b}" for s in "LR" for b in ("UpperArm", "LowerArm")}
UPPER_LEGS = {"J_Bip_L_UpperLeg", "J_Bip_R_UpperLeg"}
LOWER_LEGS = {"J_Bip_L_LowerLeg", "J_Bip_R_LowerLeg"}
FEET = {f"J_Bip_{s}_{b}" for s in "LR" for b in ("Foot", "ToeBase")}
# The middle of the head (with the hair): this far above the eyes (set in main()).
HEAD_ABOVE_EYES = 0.04
# How much hair headwear makes room for over the skull, metres.
HAIR_ROOM = 0.05
# The keep-out of headwear (gear.KEEP_OUT_LAYERS): everything over its rim within this
# many metres of the head's upright axis.
KEEP_OUT_RADIUS = 0.45
# Rims of the headwear: (point, normal) of the plane its keep-out starts at (set by each).
RIMS = {}
# Smallest width that survives as a pixel: a block of the 8x supersampled render is one pixel.
PIXEL = 1 / gear.PX_PER_M


def main():
	out = os.path.abspath(sys.argv[sys.argv.index("--") + 1])
	global ARM, BODY, BONE, BROW, FACE_FRONT, HEAD_CENTRE, SHOULDER, ANKLE, KNEE, MOUTH
	ARM, BODY = bpy.data.objects["Base"], bpy.data.objects["Body"]
	BONE = {b.name: b.head_local.copy() for b in ARM.data.bones}
	eyes = bpy.data.objects["eye_r"].matrix_world.to_translation().z
	BROW = eyes + 0.035
	HEAD_CENTRE = Vector((0, -0.01, eyes + HEAD_ABOVE_EYES))
	MOUTH = bpy.data.objects["mouth"].matrix_world.to_translation().z
	# heights the clothes are cut at, from the body's own bones (the bodies differ in size)
	SHOULDER = BONE["J_Bip_L_UpperArm"].z
	ANKLE = BONE["J_Bip_L_Foot"].z
	KNEE = BONE["J_Bip_L_LowerLeg"].z
	FACE_FRONT = max(v.co.y for v in bpy.data.objects["Face"].data.vertices)
	cape_bones()
	for item in list(gear.WORN) + list(gear.HELD):
		col = bpy.data.collections.new(item)
		bpy.context.scene.collection.children.link(col)
		for o in BUILD[item]():
			for c in o.users_collection:
				c.objects.unlink(o)
			col.objects.link(o)
			o["layer"] = item
	for hat in gear.HEADWEAR:
		for side, inward in (("_keep_out", False), ("_keep_out_back", True)):
			col = bpy.data.collections.new(hat + side)
			bpy.context.scene.collection.children.link(col)
			o = keep_out(hat + side, *RIMS[hat], inward)
			for c in o.users_collection:
				c.objects.unlink(o)
			col.objects.link(o)
	bpy.ops.wm.save_as_mainfile(filepath=out)
	print("gear:", ", ".join(c.name for c in bpy.data.collections if c.name in BUILD))


# --- shells of the body ---------------------------------------------------------

def shell(name, keep, offset, trim=None):
	"""The body faces whose vertices all pass keep(co, bone), each vertex pushed out by
	offset(co, bone) metres; trim(co) marks faces (by their centre) for the second colour."""
	bm = body_bmesh()
	normals = smooth_normals(bm)
	deform = bm.verts.layers.deform.verify()
	groups = {g.index: g.name for g in BODY.vertex_groups}
	moves, drop = {}, []
	for v in bm.verts:
		w = v[deform]
		bone = groups[max(w.items(), key=lambda kv: kv[1])[0]] if len(w) else ""
		if keep(v.co, bone):
			moves[v] = normals[v] * offset(v.co, bone)
		else:
			drop.append(v)
	bmesh.ops.delete(bm, geom=drop, context="VERTS")
	for v, d in moves.items():
		if v.is_valid:
			v.co += d
	marks = [bool(trim and trim(f.calc_center_median())) for f in bm.faces]
	me = bpy.data.meshes.new(name)
	bm.to_mesh(me)
	bm.free()
	if "trunks" in me.attributes:
		me.attributes.remove(me.attributes["trunks"])
	obj = skinned(name, me)
	for g in BODY.vertex_groups:  # in index order, so the copied weights keep their groups
		obj.vertex_groups.new(name=g.name)
	set_trim(me, marks)
	return obj


def body_bmesh():
	bm = bmesh.new()
	bm.from_mesh(BODY.data)
	# the glTF import splits vertices along UV seams: weld them, or the shell tears open there
	bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
	bm.normal_update()
	return bm


def smooth_normals(bm, rounds=3):
	"""Vertex normals averaged with their neighbours': pushed out along them a shell does not
	fold into the body in creases (under the breast, the armpit)."""
	n = {v: v.normal.copy() for v in bm.verts}
	for _ in range(rounds):
		n = {v: (n[v] + sum((n[e.other_vert(v)] for e in v.link_edges), Vector())).normalized() for v in bm.verts}
	return n


def skinned(name, me):
	obj = bpy.data.objects.new(name, me)
	bpy.context.scene.collection.objects.link(obj)
	obj.parent = ARM  # the armature modifier deforms in the armature's space: turn with it as well
	mod = obj.modifiers.new("armature", "ARMATURE")
	mod.object = ARM
	return obj


def set_trim(me, marks):
	att = me.attributes.new("trim", "FLOAT", "FACE")
	att.data.foreach_set("value", [1.0 if m else 0.0 for m in marks])


def ramp(t, lo, hi):
	return min(1.0, max(0.0, (t - lo) / (hi - lo)))


def material(obj, name, colours, trim=None):
	obj.data.materials.append(toon.ramp_material(name, colours, under=("trim", trim) if trim else None))


def linen_shirt():
	hem = BONE["J_Bip_L_UpperLeg"].z + 0.035
	elbow, wrist = BONE["J_Bip_R_LowerArm"].x, BONE["J_Bip_R_Hand"].x

	def keep(co, bone):
		return bone in TORSO | ARMS or (bone == C + "Hips" and co.z > hem)

	def offset(co, bone):
		cuff = 0.016 * ramp(abs(co.x), elbow, wrist) if "LowerArm" in bone else 0.0
		return 0.008 + cuff + 0.008 * (1 - ramp(co.z, hem, hem + 0.05))

	o = shell("linen_shirt", keep, offset)
	material(o, "linen", pal.LINEN)
	return [o]


def work_trousers():
	waist = BONE[C + "Hips"].z + 0.035

	def keep(co, bone):
		return (bone in UPPER_LEGS | LOWER_LEGS and co.z > ANKLE + 0.014) or (bone == C + "Hips" and co.z < waist)

	def offset(co, bone):
		return 0.006 + 0.010 * (1 - ramp(co.z, ANKLE + 0.014, ANKLE + 0.08))

	o = shell("work_trousers", keep, offset, trim=lambda co: co.z > waist - 0.025)
	material(o, "walnut", pal.WALNUT, pal.DARK_LEATHER)  # a belt at the waist
	return [o]


def boots():
	top = KNEE - 0.085

	def keep(co, bone):
		return bone in FEET or (bone in LOWER_LEGS and co.z < top)

	def offset(co, bone):
		return 0.012 + 0.007 * ramp(co.z, top - 0.04, top)

	o = shell("boots", keep, offset, trim=lambda co: co.z > top - 0.035)
	material(o, "boot_leather", pal.BOOT_LEATHER, pal.BOOT_CUFF)
	return [o]


def leather_armor():
	hem = BONE["J_Bip_L_UpperLeg"].z - 0.04
	waist = BONE[C + "Spine"].z

	def keep(co, bone):
		return bone in TORSO or (bone == C + "Hips" and co.z > hem)

	def offset(co, bone):
		pad = 0.014 if "Shoulder" in bone else 0.0  # pauldrons
		return 0.021 + pad + 0.01 * (1 - ramp(co.z, hem, hem + 0.06))

	o = shell("leather_armor", keep, offset,
		trim=lambda co: co.z < hem + 0.022 or abs(co.z - waist) < 0.014)
	material(o, "tan_leather", pal.TAN_LEATHER, pal.DARK_LEATHER)
	return [o]


# --- headwear ----------------------------------------------------------------------

def envelope(margin, smooth=3, segments=(48, 24)):
	"""A sphere around the head and the hairstyles, drawn in onto them from outside and kept
	`margin` metres off; bumps of hair strands are filled out first. Hair counts only up to
	HAIR_ROOM over the head: long tails and buns stay out (hair outside headwear is cut off
	in the game, as in Ragnarok Online). The same for every style: one hat fits them all."""
	dg = bpy.context.evaluated_depsgraph_get()
	head = [BVHTree.FromObject(bpy.data.objects[n], dg) for n in ("Face", "Body")]
	hairs = [BVHTree.FromObject(bpy.data.objects[n], dg) for n in gear.HAIR_LAYERS]
	bm = bmesh.new()
	bmesh.ops.create_uvsphere(bm, u_segments=segments[0], v_segments=segments[1], radius=1.0)
	r = {}
	for v in bm.verts:
		u = v.co.normalized()
		start, skull = HEAD_CENTRE + u * 0.5, 0.11
		for t in head:
			hit = t.ray_cast(start, -u, 0.5)
			if hit[0] is not None:
				skull = max(skull, (hit[0] - HEAD_CENTRE).length)
		hits = [t.ray_cast(start, -u, 0.5)[0] for t in hairs]
		hair_r = max([(h - HEAD_CENTRE).length for h in hits if h is not None], default=0.0)
		r[v] = max(skull, min(hair_r, skull + HAIR_ROOM))
	near = {v: [e.other_vert(v) for e in v.link_edges] for v in bm.verts}
	for _ in range(smooth):
		r = {v: max(r[v], sum(r[n] for n in near[v]) / len(near[v])) for v in bm.verts}
	for _ in range(smooth):
		r = {v: (r[v] + sum(r[n] for n in near[v]) / len(near[v])) / 2 for v in bm.verts}
	for v in bm.verts:
		v.co = HEAD_CENTRE + v.co.normalized() * (r[v] + margin)
	return bm


def cut(bm, point, normal):
	"""Remove everything below the plane (on the side opposite to its normal)."""
	geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
	bmesh.ops.bisect_plane(bm, geom=geom, plane_co=point, plane_no=Vector(normal).normalized(), clear_inner=True)


def rigid(name, bm, trim=None, bone=C + "Head"):
	"""A mesh riding one bone; trim(face) marks faces for the second colour."""
	marks = [bool(trim and trim(f)) for f in bm.faces]
	me = bpy.data.meshes.new(name)
	bm.to_mesh(me)
	bm.free()
	me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
	obj = skinned(name, me)
	obj.vertex_groups.new(name=bone).add(range(len(me.vertices)), 1.0, "REPLACE")
	set_trim(me, marks)
	return obj


def keep_out(name, point, normal, inward):
	"""A closed upright cylinder about the head cut at the rim plane, all of it over the rim;
	inward: its faces turned in, so a camera culling back faces sees its far side."""
	bm = bmesh.new()
	bmesh.ops.create_cone(bm, cap_ends=True, segments=32, radius1=KEEP_OUT_RADIUS, radius2=KEEP_OUT_RADIUS,
		depth=1.2, matrix=Matrix.Translation(HEAD_CENTRE + Vector((0, 0, 0.1))))
	cut(bm, point, normal)
	bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary], sides=0)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	if inward:
		bmesh.ops.reverse_faces(bm, faces=bm.faces)
	return rigid(name, bm)


def above(point, normal):
	n = Vector(normal).normalized()
	return lambda co: (co - Vector(point)).dot(n)


def iron_helmet():
	rim_point, rim_normal = (0, FACE_FRONT - 0.01, BROW + 0.005), (0, -0.38, 1)
	RIMS["iron_helmet"] = (rim_point, rim_normal)
	bm = envelope(0.014)
	cut(bm, rim_point, rim_normal)
	height = above(rim_point, rim_normal)
	# the nasal: a bar down the nose from the rim
	nose = bmesh.ops.create_cube(bm, size=1.0)["verts"]
	bmesh.ops.transform(bm, verts=nose, matrix=Matrix.Translation((0, FACE_FRONT + 0.012, BROW - 0.045))
		@ Matrix.Diagonal((PIXEL * 1.1, 0.014, 0.085, 1)))
	o = rigid("iron_helmet", bm, trim=lambda f: height(f.calc_center_median()) < 0.02)
	material(o, "iron", pal.IRON, pal.IRON_DARK)
	return [o]


def felt_hat():
	base_point, base_normal = (0, 0, BROW + 0.03), (0, -0.15, 1)
	RIMS["felt_hat"] = (base_point, base_normal)
	bm = envelope(0.012, smooth=6)
	cut(bm, base_point, base_normal)
	height = above(base_point, base_normal)
	rim = [e for e in bm.edges if e.is_boundary]
	new = bmesh.ops.extrude_edge_only(bm, edges=rim)["geom"]
	brim = [g for g in new if isinstance(g, bmesh.types.BMVert)]
	for v in brim:
		out = Vector((v.co.x - HEAD_CENTRE.x, v.co.y - HEAD_CENTRE.y, 0)).normalized()
		v.co += out * 0.05 + Vector((0, 0, -0.008))
	brim_faces = {f for v in brim for f in v.link_faces}
	o = rigid("felt_hat", bm, trim=lambda f: f not in brim_faces and height(f.calc_center_median()) < 0.024)
	material(o, "felt", pal.FELT, pal.HAT_BAND)
	return [o]


def fur_hood():
	bm = envelope(0.022, smooth=6)
	RIMS["fur_hood"] = ((0, 0, MOUTH - 0.03), (0, 0, 1))
	cut(bm, *RIMS["fur_hood"])
	face_hole = [v for v in bm.verts
		if (v.co - HEAD_CENTRE).normalized().y > 0.42 and v.co.z < BROW + 0.012]
	bmesh.ops.delete(bm, geom=face_hole, context="VERTS")
	opening = {v for v in bm.verts if v.is_boundary and v.co.y > HEAD_CENTRE.y + 0.02}
	hood = rigid("fur_hood", bm, trim=lambda f: any(v in opening for v in f.verts))
	material(hood, "fur_hood", pal.FUR_BROWN, pal.FUR_LIGHT)
	return [hood, capelet("fur_hood_capelet", 0.026, SHOULDER - 0.068)]


def capelet(name, thickness, bottom):
	"""Fur over the shoulders and the neck, the light fur along its lower edge."""
	def keep(co, bone):
		on = bone in {C + "UpperChest", C + "Neck", "J_Bip_L_Shoulder", "J_Bip_R_Shoulder"} \
			or (bone in ARMS and abs(co.x) < 0.22)
		return on and co.z > bottom

	def offset(co, bone):
		return thickness + 0.012 * (1 - ramp(co.z, bottom, bottom + 0.04))

	o = shell(name, keep, offset, trim=lambda co: co.z < bottom + 0.022)
	material(o, name, pal.FUR_BROWN, pal.FUR_LIGHT)
	return o


# --- cloaks ----------------------------------------------------------------------

def cape_bones():
	bpy.context.view_layer.objects.active = ARM
	bpy.ops.object.mode_set(mode="EDIT")
	eb = ARM.data.edit_bones
	y = -0.06
	c1 = eb.new("Cape1")
	waist = BONE["J_Bip_L_UpperLeg"].z + 0.035
	c1.head, c1.tail = (0, y, SHOULDER - 0.018), (0, y, waist)
	c1.parent = eb[C + "UpperChest"]
	c2 = eb.new("Cape2")
	c2.head, c2.tail = (0, y, waist), (0, y, ANKLE + 0.08)
	c2.parent, c2.use_connect = c1, True
	bpy.ops.object.mode_set(mode="OBJECT")


def torso_tree():
	"""The trunk and the thighs without the arms (in the T pose they stick out at shoulder height)."""
	bm = body_bmesh()
	deform = bm.verts.layers.deform.verify()
	groups = {g.index: g.name for g in BODY.vertex_groups}
	keep = TORSO | UPPER_LEGS | {C + "Hips", C + "Neck"}
	drop = [v for v in bm.verts if not len(v[deform]) or groups[max(v[deform].items(), key=lambda kv: kv[1])[0]] not in keep]
	bmesh.ops.delete(bm, geom=drop, context="VERTS")
	tree = BVHTree.FromBMesh(bm)
	bm.free()
	return tree


def cape(name, bottom, flare, colours, trim=None, hem=0.0):
	"""A sheet around the back from the shoulders down to `bottom`, widening by `flare` per metre
	and kept off the trunk and thighs; its lowest `hem` metres take the trim colour."""
	tree = torso_tree()
	top, cols, rows, spread = SHOULDER + 0.002, 24, 14, math.radians(100)
	waist = BONE["J_Bip_L_UpperLeg"].z + 0.035
	groups = [C + "UpperChest", "Cape1", "Cape2"]
	bm = bmesh.new()
	deform = bm.verts.layers.deform.verify()

	def body_radius(out, z):
		axis = Vector((0, 0, z))
		hit = tree.ray_cast(axis + out * 0.6, -out, 0.6)
		return (hit[0] - axis).length if hit[0] is not None else 0.0

	outs = [Vector((math.sin(p), -math.cos(p), 0)) for p in
		(-spread + 2 * spread * j / cols for j in range(cols + 1))]
	tops = [body_radius(out, top) + 0.03 for out in outs]
	verts, marks = [], []
	for i in range(rows + 1):
		z = top + (bottom - top) * i / rows
		line = []
		for out, r_top in zip(outs, tops):
			r = max(r_top + (top - z) * flare, body_radius(out, z) + 0.03)
			v = bm.verts.new(Vector((0, 0, z)) + out * r)
			if z > SHOULDER - 0.058:
				v[deform][0] = 1.0
			else:
				low = ramp(waist - z, 0, 0.2)
				v[deform][1] = 1 - low
				if low:
					v[deform][2] = low
			line.append(v)
		verts.append(line)
	for i in range(rows):
		for j in range(cols):
			bm.faces.new((verts[i][j], verts[i][j + 1], verts[i + 1][j + 1], verts[i + 1][j]))
			marks.append(hem > 0 and top + (bottom - top) * (i + 0.5) / rows < bottom + hem)
	me = bpy.data.meshes.new(name)
	bm.to_mesh(me)
	bm.free()
	me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
	obj = skinned(name, me)
	for g in groups:
		obj.vertex_groups.new(name=g)
	set_trim(me, marks)
	material(obj, name, colours, trim)
	return obj


def mantle(name, thickness, colours, trim=None):
	def keep(co, bone):
		on = bone in {C + "UpperChest", C + "Neck", "J_Bip_L_Shoulder", "J_Bip_R_Shoulder"} \
			or (bone in ARMS and abs(co.x) < 0.22)
		return on and SHOULDER - 0.043 < co.z < SHOULDER + 0.062

	o = shell(name, keep, lambda co, bone: thickness)
	material(o, name, colours, trim)
	return o


def wool_cloak():
	return [mantle("wool_cloak_mantle", 0.03, pal.WOOL_GREY), cape("wool_cloak", ANKLE + 0.08, 0.22, pal.WOOL_GREY)]


def fur_cloak():
	return [mantle("fur_cloak_mantle", 0.042, pal.FUR_LIGHT),
		cape("fur_cloak", ANKLE + 0.05, 0.25, pal.FUR_BROWN, pal.FUR_LIGHT, hem=0.04)]


# --- held things -------------------------------------------------------------------

class Kit:
	"""A held thing built in its grip's frame from cones and flat prisms, one material per part."""

	def __init__(self, name, grip="grip_r"):
		self.name, self.grip, self.bm, self.mats = name, grip, bmesh.new(), []

	def mat(self, colours):
		key = id(colours)
		if key not in [k for k, _ in self.mats]:
			self.mats.append((key, colours))
		return [k for k, _ in self.mats].index(key)

	def add(self, verts, colours):
		m = self.mat(colours)
		for f in {f for v in verts for f in v.link_faces}:
			f.material_index = m

	def rod(self, y0, y1, r0, colours, r1=None, x=0.0, sides=8):
		"""A cone along +Y from y0 to y1."""
		r0, r1 = max(r0, PIXEL / 2), max(r1 if r1 is not None else r0, PIXEL / 2)
		vs = bmesh.ops.create_cone(self.bm, cap_ends=True, segments=sides, radius1=r0, radius2=r1,
			depth=y1 - y0)["verts"]
		bmesh.ops.transform(self.bm, verts=vs, matrix=Matrix.Translation((x, (y0 + y1) / 2, 0))
			@ Matrix.Rotation(math.radians(-90), 4, "X"))
		self.add(vs, colours)

	def plate(self, outline, thick, colours, edge=0.4):
		"""A flat prism of an (x, y) outline, `thick` metres through Z; points with x beyond
		the middle of the outline are thinned to `edge` of it (a cutting edge)."""
		xs = [p[0] for p in outline]
		mid, span = (max(xs) + min(xs)) / 2, (max(xs) - min(xs)) / 2 or 1
		top, bottom = [], []
		for x, y in outline:
			k = 1 - (1 - edge) * max(0.0, (x - mid) / span) if edge < 1 else 1
			h = max(thick * k, PIXEL * 0.6) / 2
			top.append(self.bm.verts.new((x, y, h)))
			bottom.append(self.bm.verts.new((x, y, -h)))
		self.bm.faces.new(top)
		self.bm.faces.new(list(reversed(bottom)))
		n = len(outline)
		for i in range(n):
			self.bm.faces.new((bottom[i], bottom[(i + 1) % n], top[(i + 1) % n], top[i]))
		self.add(top + bottom, colours)

	def done(self):
		me = bpy.data.meshes.new(self.name)
		bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
		self.bm.to_mesh(me)
		self.bm.free()
		obj = bpy.data.objects.new(self.name, me)
		bpy.context.scene.collection.objects.link(obj)
		for i, (_, colours) in enumerate(self.mats):
			obj.data.materials.append(toon.ramp_material(f"{self.name}_{i}", colours))
		obj.parent = bpy.data.objects[self.grip]
		obj.matrix_parent_inverse = Matrix()
		obj.matrix_basis = Matrix()
		return obj


def crescent(x0, x1, y_top, y_bottom, bow_top, bow_bottom, n=8):
	"""Outline of a curved head from x0 to x1: top and bottom edges bowed down at the ends."""
	pts = []
	for i in range(n + 1):
		x = x0 + (x1 - x0) * i / n
		u = (2 * (x - x0) / (x1 - x0) - 1) ** 2
		pts.append((x, y_top - bow_top * u))
	for i in range(n, -1, -1):
		x = x0 + (x1 - x0) * i / n
		u = (2 * (x - x0) / (x1 - x0) - 1) ** 2
		pts.append((x, y_bottom - bow_bottom * u))
	return pts


def flint_axe():
	k = Kit("flint_axe")
	k.rod(-0.08, 0.42, 0.016, pal.WOOD)
	k.plate([(-0.03, 0.33), (0.08, 0.31), (0.14, 0.36), (0.13, 0.45), (0.06, 0.46), (-0.03, 0.44)], 0.035, pal.FLINT)
	k.rod(0.35, 0.43, 0.021, pal.CORD)
	return [k.done()]


def axe():
	k = Kit("axe")
	k.rod(-0.1, 0.52, 0.017, pal.WOOD)
	k.plate([(-0.05, 0.40), (0.1, 0.38), (0.15, 0.42), (0.15, 0.51), (0.1, 0.53), (-0.05, 0.51)], 0.042, pal.STONE)
	k.rod(0.38, 0.47, 0.022, pal.CORD)
	return [k.done()]


def iron_axe():
	k = Kit("iron_axe")
	k.rod(-0.1, 0.56, 0.017, pal.WOOD)
	k.plate([(-0.035, 0.47), (0.05, 0.47), (0.13, 0.37), (0.16, 0.42), (0.16, 0.58), (0.05, 0.56), (-0.035, 0.56)],
		0.024, pal.IRON, edge=0.35)
	return [k.done()]


def flint_pick():
	k = Kit("flint_pick")
	k.rod(-0.1, 0.5, 0.017, pal.WOOD)
	k.plate([(-0.03, 0.43), (0.08, 0.44), (0.19, 0.47), (0.08, 0.5), (-0.03, 0.52)], 0.032, pal.FLINT, edge=0.3)
	k.rod(0.41, 0.51, 0.021, pal.CORD)
	return [k.done()]


def pickaxe():
	k = Kit("pickaxe")
	k.rod(-0.1, 0.55, 0.017, pal.WOOD)
	k.plate([(-0.18, 0.5), (-0.06, 0.47), (0.06, 0.47), (0.18, 0.5), (0.06, 0.56), (-0.06, 0.56)], 0.036, pal.STONE, edge=1)
	k.rod(0.45, 0.56, 0.022, pal.CORD)
	return [k.done()]


def iron_pickaxe():
	k = Kit("iron_pickaxe")
	k.rod(-0.1, 0.58, 0.017, pal.WOOD)
	k.plate(crescent(-0.21, 0.21, 0.6, 0.555, 0.05, 0.085), 0.024, pal.IRON, edge=1)
	return [k.done()]


def hoe():
	k = Kit("hoe")
	k.rod(-0.5, 0.86, 0.016, pal.WOOD)
	# the blade stands off the end of the handle towards the ground at the end of a chop
	vs = bmesh.ops.create_cube(k.bm, size=1.0)["verts"]
	bmesh.ops.transform(k.bm, verts=vs, matrix=Matrix.Translation((0.07, 0.85, 0)) @ Matrix.Diagonal((0.14, 0.014, 0.1, 1)))
	k.add(vs, pal.IRON)
	k.rod(0.8, 0.88, 0.022, pal.IRON)
	return [k.done()]


def spear():
	k = Kit("spear")
	k.rod(-0.6, 0.95, 0.016, pal.WOOD)
	k.plate([(0, 0.92), (0.04, 1.0), (0.025, 1.09), (0, 1.18), (-0.025, 1.09), (-0.04, 1.0)], 0.022, pal.FLINT, edge=1)
	k.rod(0.88, 0.96, 0.021, pal.CORD)
	return [k.done()]


def fishing_rod():
	k = Kit("fishing_rod")
	k.rod(-0.15, 1.3, 0.013, pal.WOOD, r1=PIXEL / 2)
	k.rod(-0.12, 0.1, 0.017, pal.CORD)
	return [k.done()]


BOW_HALF, BOW_DEPTH = gear.BOW_HALF, gear.BOW_DEPTH


def bow():
	"""The stave in the left hand (+X of grip_l is towards the archer, the tips curve that way);
	the string is its own object, re-strung to the right hand while it draws (render.py)."""
	k = Kit("bow", grip="grip_l")
	n, rings = 14, []
	for i in range(n + 1):
		y = -BOW_HALF + 2 * BOW_HALF * i / n
		x = BOW_DEPTH * (y / BOW_HALF) ** 2
		r = max(0.015 - 0.006 * abs(y) / BOW_HALF, PIXEL / 2)
		ring = []
		for s in range(6):
			a = 2 * math.pi * s / 6
			ring.append(k.bm.verts.new((x + r * math.cos(a), y, r * math.sin(a))))
		rings.append(ring)
	for a, b in zip(rings, rings[1:]):
		for s in range(6):
			k.bm.faces.new((a[s], a[(s + 1) % 6], b[(s + 1) % 6], b[s]))
	k.bm.faces.new(rings[0])
	k.bm.faces.new(list(reversed(rings[-1])))
	k.add([v for r in rings for v in r], pal.WOOD)
	k.rod(-0.07, 0.07, 0.019, pal.CORD)
	stave = k.done()
	string = Kit("bow_string", grip="grip_l")
	string.bm.verts.new((0, 0, 0))  # strung for each frame by render.py
	string.mat(pal.BOW_STRING)
	string = string.done()
	arrow = Kit("bow_arrow", grip="grip_l")
	arrow.rod(0, 0.75, PIXEL * 0.55, pal.WOOD)
	arrow.plate([(0, 0.75), (0.02, 0.73), (0, 0.8), (-0.02, 0.73)], 0.01, pal.FLINT, edge=1)
	arrow = arrow.done()
	return [stave, string, arrow]


BUILD = {
	"linen_shirt": linen_shirt, "work_trousers": work_trousers, "boots": boots, "leather_armor": leather_armor,
	"iron_helmet": iron_helmet, "felt_hat": felt_hat, "fur_hood": fur_hood,
	"wool_cloak": wool_cloak, "fur_cloak": fur_cloak,
	"flint_axe": flint_axe, "axe": axe, "iron_axe": iron_axe, "flint_pick": flint_pick, "pickaxe": pickaxe,
	"iron_pickaxe": iron_pickaxe, "hoe": hoe, "spear": spear, "bow": bow, "fishing_rod": fishing_rod,
}

main()
