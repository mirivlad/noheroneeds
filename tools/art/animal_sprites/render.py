"""Render the horse candidate with the existing RO farm's camera and materials.

blender -b --python-exit-code 1 -P tools/art/animal_sprites/render.py -- OUT
Use --clips idle --frames 1 for a cheap eight-direction model review.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "ro_sprites"))
import horse
import toon
from palette import tones

DIRECTIONS = ["s","se","e","ne","n","nw","w","sw"]
CLIPS = {"idle": (4,3), "walk": (16,12), "run": (13,25), "graze": (8,5)}
CELL, FOOT, PX_PER_M = 256, 204, 77
ART_SCALE = .78  # Withers below the accepted RO human's shoulders; head near its height.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path)
    parser.add_argument("--clips", nargs="+", choices=list(CLIPS), default=list(CLIPS))
    parser.add_argument("--frames", type=int)
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument("--check-only", action="store_true", help="validate deformed hoof contacts without rendering")
    args = parser.parse_args(sys.argv[sys.argv.index("--")+1:])
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out/".gdignore").touch()
    raw = args.out/"raw"
    raw.mkdir(exist_ok=True)
    materials = {
        "coat":toon.ramp_material("Chestnut", tones("#613923","#985d36","#c08850")),
        "hair":toon.ramp_material("Dark mane", tones("#211d1b","#3b2e26","#594438")),
        "hoof":toon.ramp_material("Hoof", tones("#272823","#45463a","#686855")),
        "white":toon.ramp_material("Ivory markings", tones("#a39a83","#d5ceb7","#eee8d3")),
        "eye":toon.ramp_material("Eye", tones("#17140f","#30251a","#593e26")),
        "nose":toon.ramp_material("Muzzle", tones("#44332d","#695047","#8b6a56")),
    }
    arm = horse.build(materials)
    arm.scale = (ART_SCALE,)*3
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.film_transparent = True
    scene.render.resolution_x = scene.render.resolution_y = CELL*args.scale
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
    data.type, data.ortho_scale = "ORTHO", CELL/PX_PER_M
    camera = bpy.data.objects.new("RO camera", data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    elevation = math.radians(22)
    forward = Vector((0,-math.cos(elevation),-math.sin(elevation)))
    up = Vector((0,-math.sin(elevation),math.cos(elevation)))
    camera.location = up*((FOOT-CELL/2)/PX_PER_M)-forward*20
    camera.rotation_euler = forward.to_track_quat("-Z","Y").to_euler()
    light = bpy.data.lights.new("RO sun", "SUN")
    light.energy, light.angle, light.use_shadow = math.pi, 0, False
    sun = bpy.data.objects.new("RO sun",light)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (-Vector((.8,.35,.7))).to_track_quat("-Z","Y").to_euler()
    bpy.ops.mesh.primitive_plane_add(size=20, location=(0,0,-.002))
    bpy.context.object.name = "Ground holdout"
    bpy.context.object.is_holdout = True
    report = {"species":"horse","stage":"candidate","cell":CELL,"foot":FOOT,"px_per_m":PX_PER_M,
        "scale":args.scale,"art_scale":ART_SCALE,"directions":DIRECTIONS,"clips":{},"contacts":{},"anatomy":horse.validate(arm),
        "sources":{str(p.relative_to(HERE.parent.parent.parent)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (HERE/"horse.py",HERE/"render.py",HERE.parent/"ro_sprites/toon.py",HERE.parent/"ro_sprites/pixelate.py")}}
    bpy.ops.wm.save_as_mainfile(filepath=str(args.out/"horse.blend"))
    for clip in args.clips:
        frames = min(args.frames,CLIPS[clip][0]) if args.frames else CLIPS[clip][0]
        report["clips"][clip] = {"frames":frames,"fps":CLIPS[clip][1]}
        for i in range(frames):
            arm.rotation_euler = (0,0,0)
            try:
                report["contacts"][f"{clip}_{i:02d}"] = horse.pose(arm,clip,i/CLIPS[clip][0])
            except (ValueError,AssertionError) as error:
                raise ValueError(f"{clip} frame {i}: {error}") from error
            if args.check_only:
                continue
            for row,direction in enumerate(DIRECTIONS):
                arm.rotation_euler.z = math.radians(row*45)
                bpy.context.view_layer.update()
                scene.render.filepath = str(raw/f"{clip}_{direction}_{i:02d}.png")
                bpy.ops.render.render(write_still=True)
    (args.out/"render.json").write_text(json.dumps(report,indent=2)+"\n")


main()
