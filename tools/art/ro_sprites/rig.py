"""Posing helpers for the base armature (Blender side).

Rotations are given about world axes through the bone's head, applied parent
first, so a pose reads the same whatever the bone rolls are. The character
faces +Y (towards the camera at direction S), its left side is -X.
"""
import math

import bpy
from mathutils import Matrix

SIDES = {"L": 1, "R": -1}


def rotate(arm, bone, axis, degrees):
	pb = arm.pose.bones[bone]
	head = pb.matrix.to_translation()
	r = Matrix.Rotation(math.radians(degrees), 4, axis)
	pb.matrix = Matrix.Translation(head) @ r @ Matrix.Translation(-head) @ pb.matrix
	bpy.context.view_layer.update()


def reset(arm):
	for pb in arm.pose.bones:
		pb.matrix_basis = Matrix()
	bpy.context.view_layer.update()


def fists(arm, curl=(40, 55, 40)):
	"""Loosely closed hands; call on the rest pose (T pose, palms down)."""
	for s, k in SIDES.items():
		for f in ("Index", "Middle", "Ring", "Little"):
			for j, deg in enumerate(curl, 1):
				rotate(arm, f"J_Bip_{s}_{f}{j}", "Y", -deg * k)
		rotate(arm, f"J_Bip_{s}_Thumb2", "Z", 25 * k)
		rotate(arm, f"J_Bip_{s}_Thumb3", "Z", 20 * k)


def stand(arm):
	"""Relaxed standing: arms down beside the body, elbows a little bent, palms in."""
	reset(arm)
	fists(arm)
	for s, k in SIDES.items():
		rotate(arm, f"J_Bip_{s}_UpperArm", "Y", -74 * k)
		rotate(arm, f"J_Bip_{s}_UpperArm", "X", 4)
		rotate(arm, f"J_Bip_{s}_LowerArm", "X", 10)
		rotate(arm, f"J_Bip_{s}_UpperLeg", "Y", 2 * k)
		rotate(arm, f"J_Bip_{s}_Foot", "Y", -2 * k)
	# chin a little up: the camera looks down, sprites show the face nearly frontal
	rotate(arm, "J_Bip_C_Head", "X", 8)


POSES = {"stand": stand, "rest": reset}
