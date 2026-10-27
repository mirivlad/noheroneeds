"""Render the character's layers in 8 directions for every frame of their clips (Blender side).

The camera is orthographic, looks down at ELEVATION degrees and stays put; the
character turns. The sun is fixed to the camera (upper left, in front), so every
direction is lit the same way on screen, as in Ragnarok Online sprites. Frames
are rendered SCALE times larger than the sprite cell; pixelate.py reduces them.
The ground point under the character lands on the same pixel of its cell in
every frame, and every pose is lowered or raised until the body touches z = 0.

Layers (gear.py): "body" (the body and the face mesh), "hair_sample" and every
item. Each layer is rendered alone, with the body as a holdout: the body does
not show but hides what is behind it, so a layer holds exactly the pixels of it
that are seen on that body. Nothing shows under the ground either. Each
frame also gets a depth map (nearer is brighter), by which compose.py puts any
set of layers together.

Written per layer: <out>/<layer>/<clip>_<direction>_<NN>.png (colour) and
<clip>_<direction>_<NN>.depth.png (16-bit grey, DEPTH_SCALE times the cell; 0 is
empty), directions s, se, e, ne, n, nw, w, sw (screen compass; s faces the
viewer). <out>/body/anchors.json (updated, so clips can be rendered one at a
time) gets the face anchors (eye_r, eye_l, mouth) of every frame as
[x, y, facing, visible] in cell pixels: facing is the cosine between where the
anchor looks and the direction to the viewer; visible is false when the body
covers it.

Usage: blender -b GEAR.blend -P render.py -- OUT_DIR [--layers body linen_shirt ...|all]
       [--clips idle walk ...|all] [--dirs s se ...] [--px-per-m 77] [--elevation 22] [--scale 8]
"""
import argparse
import json
import math
import os
import sys

import bmesh
import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clips  # noqa: E402
import gear  # noqa: E402
import rig  # noqa: E402

DIRECTIONS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]
ANCHORS = ["eye_r", "eye_l", "mouth"]
DEPTH_SCALE = 2
# Depth range mapped to the 16-bit grey: metres from the camera (it stands CAMERA_DISTANCE off).
CAMERA_DISTANCE, NEAR, FAR = 20, 17, 23


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("out")
	ap.add_argument("--layers", nargs="+", default=["all"])
	ap.add_argument("--clips", nargs="+", default=["all"])
	ap.add_argument("--dirs", nargs="+", default=DIRECTIONS)
	ap.add_argument("--px-per-m", type=float, default=gear.PX_PER_M)
	ap.add_argument("--elevation", type=float, default=22)
	ap.add_argument("--scale", type=int, default=8)
	a = ap.parse_args(sys.argv[sys.argv.index("--") + 1:])
	layers = gear.all_layers() if a.layers == ["all"] else a.layers
	wanted = list(clips.CLIPS) if a.clips == ["all"] else a.clips
	scene = bpy.context.scene
	arm = bpy.data.objects["Base"]
	arm.rotation_mode = "XYZ"
	body = bpy.data.objects["Body"]
	members = {layer: objects_of(layer) for layer in layers}
	everything = {o for layer in gear.all_layers() for o in objects_of(layer)}
	setup(scene, a)
	depth = depth_material()
	for layer in layers:
		os.makedirs(os.path.join(a.out, layer), exist_ok=True)
	anchors_path = os.path.join(a.out, "body", "anchors.json")
	anchors = json.load(open(anchors_path)) if "body" in layers and os.path.exists(anchors_path) else {}
	for name in wanted:
		todo = [layer for layer in layers if name in gear.clips_of(layer)]
		if not todo:
			continue
		for i in range(clips.CLIPS[name][0]):
			arm.rotation_euler = (0, 0, 0)
			rig.pose(arm, clips.CLIPS[name][3](clips.frame_t(name, i)), ground_mesh=body)
			carry(todo, name)
			drawn = string_bow() if "bow" in todo else False
			for d in a.dirs:
				arm.rotation_euler = (0, 0, math.radians(45 * DIRECTIONS.index(d)))
				bpy.context.view_layer.update()
				frame = f"{name}_{d}_{i:02d}"
				for layer in todo:
					show(layer, members[layer], everything, hidden=set() if drawn else {"bow_arrow"})
					path = os.path.join(os.path.abspath(a.out), layer, frame)
					render(scene, a, layer, path + ".png")
					render(scene, a, layer, path + ".depth.png", depth)
					if layer == "body":
						anchors[frame] = {n: anchor(scene, bpy.data.objects[n], gear.CELL) for n in ANCHORS}
	if "body" in layers:
		with open(anchors_path, "w") as f:
			json.dump(anchors, f, indent=1)


def carry(layers, clip):
	"""Turn carried things in the fist towards gear.CARRY_AIM, and over towards lying flat
	(gear.FLAT_AIM) as far as the pelvis tips over (a fall) and further while an end of the
	thing would go into the ground (picking up); in its own swing a thing sits straight in the
	grip (the swing was posed for that)."""
	hips = bpy.data.objects["Base"].pose.bones["J_Bip_C_Hips"]
	# against the bone's own rest direction: the female body's hips bone points down
	tipped = min(1.0, (hips.matrix.to_3x3() @ Vector((0, 1, 0))).angle(hips.bone.matrix_local.to_3x3() @ Vector((0, 1, 0)))
		/ math.radians(90))
	for layer in layers:
		if layer not in gear.HELD:
			continue
		own = [o for o in bpy.data.collections[layer].objects if o.name != "bow_arrow"]
		turn = 0.0
		if clip in gear.CARRY or layer in gear.AIM_ALWAYS:
			main = bpy.data.objects[layer]
			ends = [Vector((0, y, 0)) for y in (min(c[1] for c in main.bound_box), max(c[1] for c in main.bound_box))]
			w = tipped
			while True:
				turn = aim_turn(main.parent, gear.CARRY_AIM[layer], w)
				m = main.parent.matrix_world @ Matrix.Rotation(math.radians(turn), 4, "Z")
				if w >= 1 or min((m @ p).z for p in ends) > 0.01:
					break
				w = min(1.0, w + 0.1)
		for o in own:
			o.matrix_basis = Matrix.Rotation(math.radians(turn), 4, "Z")
	bpy.context.view_layer.update()


def aim_turn(grip, aim, flat):
	"""Degrees about the fist's hinge axis that bring the thing nearest to the aim, blended
	`flat` of the way to lying flat."""
	want = Vector(aim).normalized().lerp(Vector(gear.FLAT_AIM).normalized(), flat)
	v = grip.matrix_world.to_3x3().inverted() @ want
	return max(-100.0, min(100.0, math.degrees(math.atan2(-v.x, v.y))))


def objects_of(layer):
	if layer == "body":
		return [bpy.data.objects["Body"], bpy.data.objects["Face"]]
	if layer == "hair_sample":
		return [bpy.data.objects["HairSample"]]
	return list(bpy.data.collections[layer].objects)


def show(layer, own, everything, hidden):
	for o in everything:
		mine = o in own and o.name not in hidden
		o.hide_render = not (mine or (o.name in ("Body", "Face")))
		o.is_holdout = not mine
	bpy.data.objects["ground"].hide_render = False


def render(scene, a, layer, path, override=None):
	cell, foot = gear.cell_of(layer)
	r = scene.render
	r.resolution_x = r.resolution_y = cell * a.scale
	r.resolution_percentage = 100 * DEPTH_SCALE // a.scale if override else 100
	scene.camera.data.ortho_scale = cell / a.px_per_m
	place_camera(scene.camera, a, cell, foot)
	scene.view_layers[0].material_override = override
	scene.eevee.taa_render_samples = 1 if override else 16
	r.filter_size = 0.0 if override else 0.5
	scene.view_settings.view_transform = "Raw" if override else "Standard"
	im = r.image_settings
	im.color_mode, im.color_depth = ("BW", "16") if override else ("RGBA", "8")
	r.filepath = path
	bpy.ops.render.render(write_still=True)


def anchor(scene, obj, cell):
	cam = scene.camera
	p = obj.matrix_world.to_translation()
	u, v, _ = world_to_camera_view(scene, cam, p)
	to_viewer = cam.matrix_world.to_3x3().col[2].normalized()
	facing = obj.matrix_world.to_3x3().col[1].normalized().dot(to_viewer)
	start = p + to_viewer * 5
	hit, loc, _, _, who, _ = scene.ray_cast(bpy.context.evaluated_depsgraph_get(), start, -to_viewer)
	covered = hit and who.name in ("Body", "Face") and (loc - start).length < 5 - 0.012
	return [u * cell, (1 - v) * cell, facing, not covered]


def string_bow():
	"""String the bow for this pose: straight between the tips, or pulled to the right fist
	when that is behind the string; the arrow lies from the fist over the grip. Returns drawn."""
	stave, grip_r = bpy.data.objects["bow"], bpy.data.objects["grip_r"]
	nock = stave.matrix_world.inverted() @ grip_r.matrix_world.to_translation()
	h, x = gear.BOW_HALF, gear.BOW_DEPTH
	drawn = nock.x > x + 0.04 and abs(nock.y) < 0.3 and abs(nock.z) < 0.2
	tips = [Vector((x, h, 0)), Vector((x, -h, 0))]
	bm = bmesh.new()
	for a, b in ((tips[0], nock), (nock, tips[1])) if drawn else ((tips[0], tips[1]),):
		strand(bm, a, b, 0.55 / gear.PX_PER_M)
	me = bpy.data.objects["bow_string"].data
	bm.to_mesh(me)
	bm.free()
	arrow = bpy.data.objects["bow_arrow"]
	if drawn:
		along = (-nock).normalized()
		arrow.matrix_basis = stave.matrix_basis @ Matrix.Translation(nock) @ Vector((0, 1, 0)).rotation_difference(along).to_matrix().to_4x4()
	bpy.context.view_layer.update()
	return drawn


def strand(bm, a, b, r):
	vs = bmesh.ops.create_cone(bm, cap_ends=True, segments=6, radius1=r, radius2=r, depth=(b - a).length)["verts"]
	turn = Vector((0, 0, 1)).rotation_difference(b - a).to_matrix().to_4x4()
	bmesh.ops.transform(bm, verts=vs, matrix=Matrix.Translation((a + b) / 2) @ turn)


def depth_material():
	"""Grey by distance from the camera: 1 at NEAR, 0 at FAR (an emission, read raw)."""
	mat = bpy.data.materials.new("depth")
	mat.use_nodes = True
	nodes, links = mat.node_tree.nodes, mat.node_tree.links
	nodes.clear()
	cam = nodes.new("ShaderNodeCameraData")
	m = nodes.new("ShaderNodeMapRange")
	m.inputs["From Min"].default_value, m.inputs["From Max"].default_value = NEAR, FAR
	m.inputs["To Min"].default_value, m.inputs["To Max"].default_value = 1.0, 0.0
	links.new(cam.outputs["View Z Depth"], m.inputs["Value"])
	emit = nodes.new("ShaderNodeEmission")
	links.new(m.outputs["Result"], emit.inputs["Color"])
	out = nodes.new("ShaderNodeOutputMaterial")
	links.new(emit.outputs[0], out.inputs["Surface"])
	return mat


def place_camera(cam, a, cell, foot):
	e = math.radians(a.elevation)
	forward = Vector((0, -math.cos(e), -math.sin(e)))
	up = Vector((0, -math.sin(e), math.cos(e)))
	# put the ground point (0, 0, 0) at row `foot` of the cell
	centre = up * ((foot - cell / 2) / a.px_per_m)
	cam.location = centre - forward * CAMERA_DISTANCE
	cam.rotation_euler = forward.to_track_quat("-Z", "Y").to_euler()


def setup(scene, a):
	scene.render.engine = "BLENDER_EEVEE"
	scene.render.film_transparent = True
	scene.view_settings.look = "None"
	world = bpy.data.worlds.new("none")
	world.use_nodes = True
	world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0
	scene.world = world

	cam_data = bpy.data.cameras.new("sprite")
	cam_data.type = "ORTHO"
	cam_data.clip_start, cam_data.clip_end = 0.1, 40
	cam = bpy.data.objects.new("sprite", cam_data)
	scene.collection.objects.link(cam)
	scene.camera = cam

	sun_data = bpy.data.lights.new("sun", "SUN")
	sun_data.energy = math.pi
	sun_data.angle = 0
	sun_data.use_shadow = False  # cast shadows break the flat tones into specks
	sun = bpy.data.objects.new("sun", sun_data)
	scene.collection.objects.link(sun)
	# from the upper left of the screen (+X is screen left), somewhat towards the viewer
	towards_light = Vector((0.8, 0.35, 0.7)).normalized()
	sun.rotation_euler = (-towards_light).to_track_quat("-Z", "Y").to_euler()

	bpy.ops.mesh.primitive_plane_add(size=20, location=(0, 0, -0.002))
	ground = bpy.context.active_object
	ground.name = "ground"
	ground.is_holdout = True


main()
