"""Render a pose of the base body in 8 directions (Blender side).

The camera is orthographic, looks down at ELEVATION degrees and stays put; the
character turns. The sun is fixed to the camera (upper left, in front), so every
direction is lit the same way on screen, as in Ragnarok Online sprites.
Frames are rendered SCALE times larger than the sprite cell; pixelate.py reduces them.
The ground point under the character lands on the same cell pixel in every frame.
For each frame anchors.json gets the face anchors (eye_r, eye_l, mouth) as
[x, y, facing, visible] in cell pixels: facing is the cosine between where the
anchor looks and the direction to the viewer; visible is false when the body
covers it. face2d.py draws the face there.

Directions, in order: s, se, e, ne, n, nw, w, sw (screen compass; s faces the viewer).

Usage: blender -b BASE.blend -P render_dirs.py -- OUT_DIR [--pose stand] [--hair]
       [--cell 96] [--foot 88] [--px-per-m 58] [--elevation 22] [--scale 8]
"""
import argparse
import json
import math
import os
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rig  # noqa: E402

DIRECTIONS = ["s", "se", "e", "ne", "n", "nw", "w", "sw"]
ANCHORS = ["eye_r", "eye_l", "mouth"]


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("out")
	ap.add_argument("--pose", default="stand")
	ap.add_argument("--hair", action="store_true")
	ap.add_argument("--cell", type=int, default=96)
	ap.add_argument("--foot", type=int, default=88, help="cell row of the ground point")
	ap.add_argument("--px-per-m", type=float, default=58)
	ap.add_argument("--elevation", type=float, default=22)
	ap.add_argument("--scale", type=int, default=8)
	a = ap.parse_args(sys.argv[sys.argv.index("--") + 1:])
	scene = bpy.context.scene
	arm = bpy.data.objects["Base"]
	bpy.data.collections["hair_sample"].hide_render = not a.hair
	setup(scene, a)
	rig.POSES[a.pose](arm)
	arm.rotation_mode = "XYZ"
	os.makedirs(a.out, exist_ok=True)
	anchors = {}
	for i, name in enumerate(DIRECTIONS):
		arm.rotation_euler = (0, 0, math.radians(45 * i))
		bpy.context.view_layer.update()
		frame = f"{a.pose}_{name}"
		scene.render.filepath = os.path.join(os.path.abspath(a.out), frame + ".png")
		bpy.ops.render.render(write_still=True)
		anchors[frame] = {n: anchor(scene, bpy.data.objects[n], a.cell) for n in ANCHORS}
	with open(os.path.join(a.out, "anchors.json"), "w") as f:
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
	width_m = a.cell / a.px_per_m
	# put the ground point (0, 0, 0) at row `foot` of the cell
	centre = up * ((a.foot - a.cell / 2) / a.px_per_m)
	cam_data = bpy.data.cameras.new("sprite")
	cam_data.type = "ORTHO"
	cam_data.ortho_scale = width_m
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
