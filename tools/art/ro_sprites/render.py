"""Render animation clips of the base body in 8 directions (Blender side).

The camera is orthographic, looks down at ELEVATION degrees and stays put; the
character turns. The sun is fixed to the camera (upper left, in front), so every
direction is lit the same way on screen, as in Ragnarok Online sprites.
Frames are rendered SCALE times larger than the sprite cell; pixelate.py reduces
them. The ground point under the character lands on the same cell pixel in
every frame, and every pose is lowered or raised until the body touches z = 0.

Frames are written as <clip>_<direction>_<frame>.png; directions in order
s, se, e, ne, n, nw, w, sw (screen compass; s faces the viewer). anchors.json
(updated, so clips can be rendered one at a time) gets the face anchors
(eye_r, eye_l, mouth) of every frame as [x, y, facing,
visible] in cell pixels: facing is the cosine between where the anchor looks
and the direction to the viewer; visible is false when the body covers it.

--props adds stand-in tools in the hands (sword, axe, spear, bow, rod) for
checking grips; such renders are for review only.

Usage: blender -b BASE.blend -P render.py -- OUT_DIR [--clips idle walk ...|all] [--hair]
       [--props] [--dirs s se ...] [--cell 128] [--foot 100] [--px-per-m 58] [--elevation 22] [--scale 8]
"""
import argparse
import json
import math
import os
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clips  # noqa: E402
import rig  # noqa: E402

DIRECTIONS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]
ANCHORS = ["eye_r", "eye_l", "mouth"]
# Stand-in tools: clip -> [(grip, from, to along the grip axis in metres, radius, sRGB)]
PROPS = {
	"slash": [("grip_r", -0.1, 0.75, 0.018, "#c9ced6")],
	"chop": [("grip_r", -0.12, 0.5, 0.02, "#8a5a32"), ("grip_r", 0.42, 0.55, 0.05, "#7d828c")],
	"thrust": [("grip_r", -0.6, 0.9, 0.018, "#8a5a32"), ("grip_r", 0.9, 1.05, 0.03, "#c9ced6")],
	"shoot": [("grip_l", -0.5, 0.5, 0.016, "#7a4a28")],
	"cast": [("grip_r", -0.15, 1.1, 0.012, "#8a5a32")],
}


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("out")
	ap.add_argument("--clips", nargs="+", default=["all"])
	ap.add_argument("--dirs", nargs="+", default=DIRECTIONS)
	ap.add_argument("--hair", action="store_true")
	ap.add_argument("--props", action="store_true")
	ap.add_argument("--cell", type=int, default=128)
	ap.add_argument("--foot", type=int, default=100, help="cell row of the ground point")
	ap.add_argument("--px-per-m", type=float, default=58)
	ap.add_argument("--elevation", type=float, default=22)
	ap.add_argument("--scale", type=int, default=8)
	a = ap.parse_args(sys.argv[sys.argv.index("--") + 1:])
	names = list(clips.CLIPS) if a.clips == ["all"] else a.clips
	scene = bpy.context.scene
	arm = bpy.data.objects["Base"]
	arm.rotation_mode = "XYZ"
	body = bpy.data.objects["Body"]
	bpy.data.collections["hair_sample"].hide_render = not a.hair
	setup(scene, a)
	os.makedirs(a.out, exist_ok=True)
	anchors_path = os.path.join(a.out, "anchors.json")
	anchors = json.load(open(anchors_path)) if os.path.exists(anchors_path) else {}
	for name in names:
		frames, _, _, pose_at = clips.CLIPS[name]
		props = make_props(name) if a.props else []
		for i in range(frames):
			arm.rotation_euler = (0, 0, 0)
			rig.pose(arm, pose_at(clips.frame_t(name, i)), ground_mesh=body)
			for d in a.dirs:
				arm.rotation_euler = (0, 0, math.radians(45 * DIRECTIONS.index(d)))
				bpy.context.view_layer.update()
				frame = f"{name}_{d}_{i:02d}"
				scene.render.filepath = os.path.join(os.path.abspath(a.out), frame + ".png")
				bpy.ops.render.render(write_still=True)
				anchors[frame] = {n: anchor(scene, bpy.data.objects[n], a.cell) for n in ANCHORS}
		for p in props:
			bpy.data.objects.remove(p)
	with open(anchors_path, "w") as f:
		json.dump(anchors, f, indent=1)


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


def make_props(clip):
	import toon
	out = []
	for i, (grip, a, b, r, colour) in enumerate(PROPS.get(clip, [])):
		bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=r, depth=b - a)
		o = bpy.context.active_object
		o.name = f"prop_{clip}_{i}"
		o.data.transform(Matrix.Rotation(math.radians(-90), 4, "X") @ Matrix.Translation((0, 0, (a + b) / 2)))
		o.data.materials.append(toon.ramp_material(o.name, [(0.0, shade(colour, 0.55)), (0.12, shade(colour, 0.8)),
			(0.45, colour)]))
		o.parent = bpy.data.objects[grip]
		o.matrix_parent_inverse = Matrix()
		o.matrix_basis = Matrix()
		out.append(o)
	return out


def shade(hex_colour, k):
	return "#" + "".join("%02x" % int(int(hex_colour[i:i + 2], 16) * k) for i in (1, 3, 5))


def setup(scene, a):
	scene.render.engine = "BLENDER_EEVEE"
	scene.render.resolution_x = scene.render.resolution_y = a.cell * a.scale
	scene.render.resolution_percentage = 100
	scene.render.film_transparent = True
	scene.render.filter_size = 0.5
	scene.view_settings.view_transform = "Standard"
	scene.view_settings.look = "None"
	scene.eevee.taa_render_samples = 16
	world = bpy.data.worlds.new("none")
	world.use_nodes = True
	world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0
	scene.world = world

	e = math.radians(a.elevation)
	forward = Vector((0, -math.cos(e), -math.sin(e)))
	up = Vector((0, -math.sin(e), math.cos(e)))
	# put the ground point (0, 0, 0) at row `foot` of the cell
	centre = up * ((a.foot - a.cell / 2) / a.px_per_m)
	cam_data = bpy.data.cameras.new("sprite")
	cam_data.type = "ORTHO"
	cam_data.ortho_scale = a.cell / a.px_per_m
	cam_data.clip_start, cam_data.clip_end = 0.1, 40
	cam = bpy.data.objects.new("sprite", cam_data)
	scene.collection.objects.link(cam)
	cam.location = centre - forward * 20
	cam.rotation_euler = forward.to_track_quat("-Z", "Y").to_euler()
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


main()
