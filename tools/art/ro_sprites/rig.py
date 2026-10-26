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
  L_hold         two-hand grip: when not 0, the left fist goes onto the right hand's
                 shaft this many metres along the grip axis (negative: behind the fist)
  cape           extra backward swing of a cloak (degrees; it already hangs clear of
                 the legs and of a forward bend)
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
CHANNELS = {j[0] for j in JOINTS} | {"body_x", "body_y", "body_z", "L_hold", "cape"} | {s + "_fist" for s in SIDES}

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
	if values.get("L_hold"):
		_hold(arm, "L", values["L_hold"])
	if "Cape1" in arm.pose.bones:
		_cape(arm, values)
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


def _turn(arm, bone, have, want):
	"""Turn a bone about its head by the smallest rotation taking direction `have` to `want`
	(armature space)."""
	have, want = have.normalized(), want.normalized()
	axis = have.cross(want)
	if axis.length < 1e-6:
		return
	_rotate(arm, bone, axis.normalized(), math.degrees(have.angle(want)), None)


def _hold(arm, s, along):
	"""Put the s fist on the shaft held by the other hand, `along` metres down its grip axis:
	the fist turns to close around the shaft, the arm reaches with the elbow kept on its side."""
	to_arm = arm.matrix_world.inverted()
	other = bpy.data.objects["grip_" + ("r" if s == "L" else "l")].matrix_world
	target = to_arm @ (other @ Vector((0, along, 0)))
	shaft = (to_arm.to_3x3() @ other.to_3x3() @ Y).normalized()
	grip = bpy.data.objects["grip_" + s.lower()]
	b = f"J_Bip_{s}_"
	upper, lower, hand = (arm.pose.bones[b + n] for n in ("UpperArm", "LowerArm", "Hand"))
	for _ in range(4):
		g = to_arm @ grip.matrix_world
		axis = (g.to_3x3() @ Y).normalized()
		_turn(arm, hand.name, axis, shaft if axis.dot(shaft) >= 0 else -shaft)
		offset = (to_arm @ grip.matrix_world).to_translation() - hand.head
		_reach(arm, upper, lower, hand, target - offset)


def _reach(arm, upper, lower, hand, wrist):
	"""Two-bone reach of the wrist (the hand's head) towards a point, as far as the arm goes."""
	shoulder, elbow = upper.head.copy(), lower.head.copy()
	l1, l2 = (elbow - shoulder).length, (hand.head - elbow).length
	d = wrist - shoulder
	dist = min(max(d.length, 1e-4), (l1 + l2) * 0.999)
	dn = d.normalized()
	bend = (elbow - shoulder) - dn * (elbow - shoulder).dot(dn)
	bend = bend.normalized() if bend.length > 1e-4 else Vector((0, -0.3, -1)).normalized()
	a = math.acos(max(-1.0, min(1.0, (l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist))))
	want_elbow = shoulder + (dn * math.cos(a) + bend * math.sin(a)) * l1
	_turn(arm, upper.name, elbow - shoulder, want_elbow - shoulder)
	_turn(arm, lower.name, hand.head - lower.head, shoulder + dn * dist - lower.head)


def _cape(arm, values):
	"""Swing the cloak about the shoulders. It is fixed to the chest, so a forward bend already
	swings its hem back: that is taken back to let it hang plumb. It also clears a thigh swung
	back and a heel kicked up behind."""
	lean = values.get("hips_bend", 0) + values.get("spine_bend", 0) + values.get("chest_bend", 0)
	back = max([0.0] + [-values.get(s + "_hip", 0) for s in SIDES])
	kick = max([0.0] + [values.get(s + "_knee", 0) for s in SIDES if values.get(s + "_hip", 0) < 10])
	lift = 3 - 0.8 * max(0.0, lean) + 0.6 * back + 0.2 * kick + values.get("cape", 0)
	_rotate(arm, "Cape1", X, -lift, "J_Bip_C_UpperChest")
	_rotate(arm, "Cape2", X, -0.35 * max(0.0, lift), "Cape1")
