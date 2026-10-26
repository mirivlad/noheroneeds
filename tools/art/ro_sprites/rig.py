"""Pose channels for the base armature (Blender side).

A pose is a dict of channel values: degrees for joints, metres for body_*.
Every channel is one anatomical motion and + is its natural direction (an
elbow or a knee only bends with +). A rotation turns a bone about its head
around an axis given in the rest pose (world axes: the character faces +Y,
its left side is -X) and carried along by a frame bone: the arm swings in the
chest's frame, the forearm bends about the upper arm's hinge axis. So a pose
reads the same whatever the bone rolls are and however the trunk is turned.

Channels (s = L or R, the character's own left and right):
  body_x/y/z     move the whole body (metres; y forward); z is set by grounding
  hips_turn      + turns the whole body to its left;  hips_bend  + tips it forward
  spine_bend/chest_bend  + forward;  spine_turn/chest_turn  + to its left
  spine_side     + leans to its right;  neck_bend, head_bend  + chin down
  head_turn      + looks to its left;  head_tilt  + to its right
  s_arm_down     + lowers the arm from the T pose (74 hangs it beside the body)
  s_arm_fwd      + swings the arm forward and up;  s_arm_in  + across the front
  s_arm_twist    + turns the arm inwards about its length
  s_elbow, s_wrist  + flex (wrist towards the palm);  s_wrist_side  + towards the thumb
  s_fist         0 open hand .. 1 loose fist
  s_hip          + thigh forward;  s_hip_out  + outwards;  s_hip_twist  + toes out
  s_knee         + bends;  s_ankle  + toes up;  s_ankle_roll  + sole outwards
"""
import math

import bpy
from mathutils import Matrix, Vector

SIDES = ("L", "R")
K = {"L": 1, "R": -1}
X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
CURL = (40, 55, 40)  # finger joints of a loose fist


def _joints():
	"""(channel, bone, rest axis, sign, frame bone) in the order they are applied: parents first."""
	c = "J_Bip_C_"
	j = [
		("hips_turn", c + "Hips", Z, 1, None),
		("hips_bend", c + "Hips", X, -1, None),
		("spine_bend", c + "Spine", X, -1, c + "Hips"),
		("spine_turn", c + "Spine", Z, 1, c + "Hips"),
		("spine_side", c + "Spine", Y, 1, c + "Hips"),
		("chest_bend", c + "Chest", X, -1, c + "Spine"),
		("chest_turn", c + "Chest", Z, 1, c + "Spine"),
		("neck_bend", c + "Neck", X, -1, c + "UpperChest"),
		("head_bend", c + "Head", X, -1, c + "Neck"),
		("head_turn", c + "Head", Z, 1, c + "Neck"),
		("head_tilt", c + "Head", Y, 1, c + "Neck"),
	]
	for s in SIDES:
		k, b = K[s], f"J_Bip_{s}_"
		j += [
			(s + "_arm_down", b + "UpperArm", Y, -k, c + "UpperChest"),
			(s + "_arm_fwd", b + "UpperArm", X, 1, c + "UpperChest"),
			(s + "_arm_in", b + "UpperArm", Z, -k, c + "UpperChest"),
			(s + "_arm_twist", b + "UpperArm", "self", k, None),
			(s + "_elbow", b + "LowerArm", Z, -k, b + "UpperArm"),
			(s + "_wrist", b + "Hand", Y, -k, b + "LowerArm"),
			(s + "_wrist_side", b + "Hand", Z, -k, b + "LowerArm"),
			(s + "_hip", b + "UpperLeg", X, 1, c + "Hips"),
			(s + "_hip_out", b + "UpperLeg", Y, k, c + "Hips"),
			(s + "_hip_twist", b + "UpperLeg", Z, k, c + "Hips"),
			(s + "_knee", b + "LowerLeg", X, -1, b + "UpperLeg"),
			(s + "_ankle", b + "Foot", X, 1, b + "LowerLeg"),
			(s + "_ankle_roll", b + "Foot", Y, -k, b + "LowerLeg"),
		]
	return j


JOINTS = _joints()
CHANNELS = {j[0] for j in JOINTS} | {"body_x", "body_y", "body_z"} | {s + "_fist" for s in SIDES}

def _rotate(arm, bone, axis, degrees, frame):
	pb = arm.pose.bones[bone]
	if axis == "self":
		axis = pb.matrix.to_3x3().col[1].normalized()
	elif frame:
		f = arm.pose.bones[frame]
		axis = (f.matrix.to_3x3() @ f.bone.matrix_local.to_3x3().inverted()) @ axis
	head = pb.matrix.to_translation()
	r = Matrix.Rotation(math.radians(degrees), 4, axis)
	pb.matrix = Matrix.Translation(head) @ r @ Matrix.Translation(-head) @ pb.matrix
	bpy.context.view_layer.update()


def reset(arm):
	for pb in arm.pose.bones:
		pb.matrix_basis = Matrix()
	bpy.context.view_layer.update()


def _fist(arm, s, amount):
	k = K[s]
	for f in ("Index", "Middle", "Ring", "Little"):
		for i, deg in enumerate(CURL, 1):
			_rotate(arm, f"J_Bip_{s}_{f}{i}", Y, -deg * k * amount, f"J_Bip_{s}_Hand" if i == 1 else f"J_Bip_{s}_{f}{i - 1}")
	_rotate(arm, f"J_Bip_{s}_Thumb2", Z, 25 * k * amount, f"J_Bip_{s}_Thumb1")
	_rotate(arm, f"J_Bip_{s}_Thumb3", Z, 20 * k * amount, f"J_Bip_{s}_Thumb2")


def pose(arm, values, ground_mesh=None):
	"""Set the pose (channels left out are 0); with ground_mesh, the lowest vertex touches z = 0."""
	unknown = set(values) - CHANNELS
	assert not unknown, unknown
	reset(arm)
	hips = arm.pose.bones["J_Bip_C_Hips"]
	move = Vector((values.get("body_x", 0), values.get("body_y", 0), values.get("body_z", 0)))
	hips.matrix = Matrix.Translation(move) @ hips.matrix
	bpy.context.view_layer.update()
	for name, bone, axis, sign, frame in JOINTS:
		v = values.get(name, 0)
		if v:
			_rotate(arm, bone, axis, v * sign, frame)
		if name.endswith("_wrist_side") and values.get(name[0] + "_fist"):
			_fist(arm, name[0], values[name[0] + "_fist"])
	if ground_mesh is not None:
		low = lowest(ground_mesh)
		hips.matrix = Matrix.Translation((0, 0, -low)) @ hips.matrix
		bpy.context.view_layer.update()


def lowest(obj):
	dg = bpy.context.evaluated_depsgraph_get()
	ev = obj.evaluated_get(dg)
	me = ev.to_mesh()
	low = min((ev.matrix_world @ v.co).z for v in me.vertices)
	ev.to_mesh_clear()
	return low
