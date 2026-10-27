"""Animation clips of the base body as pose-channel functions (pure Python).

A clip is (frames, fps, loop, pose(t)): pose(t) returns the channel values
(see rig.py) at t in [0, 1); frame i of a looping clip is t = i / frames, of a
one-shot clip t = i / (frames - 1), so its last frame is the end pose.
Cycles (walk, run, idle) are functions of the phase; actions are key poses with
smooth (ease in and out) blends between them. Channels a key leaves out keep
their standing value.

The weapon hand is the right one, as in Ragnarok Online. Frame counts and fps
follow the game's present human animations (tools/art/import_lpc.py).
"""
import math

SIDES = ("L", "R")

STAND = {
	"head_bend": -8,  # chin a little up: the camera looks down, sprites show the face nearly frontal
	**{s + "_arm_down": 74 for s in SIDES},
	**{s + "_arm_fwd": 4 for s in SIDES},
	**{s + "_elbow": 10 for s in SIDES},
	**{s + "_fist": 1.0 for s in SIDES},
	**{s + "_hip_out": 2 for s in SIDES},
	**{s + "_ankle_roll": 2 for s in SIDES},
}


def merged(*parts):
	out = dict(STAND)
	for p in parts:
		out.update(p)
	return out


def keyed(keys, t, loop=False):
	"""keys: [(t, pose dict)], t ascending from 0; the poses are merged over STAND."""
	poses = [(kt, merged(p)) for kt, p in keys]
	if loop:
		poses.append((1.0, poses[0][1]))
	if t <= poses[0][0]:
		return dict(poses[0][1])
	for (t0, a), (t1, b) in zip(poses, poses[1:]):
		if t <= t1:
			u = (t - t0) / (t1 - t0)
			u = u * u * (3 - 2 * u)
			return {c: a.get(c, 0) + (b.get(c, 0) - a.get(c, 0)) * u for c in set(a) | set(b)}
	return dict(poses[-1][1])


def both(name, value):
	return {s + "_" + name: value for s in SIDES}


# --- cycles -----------------------------------------------------------------

def idle(t):
	"""Breathing: chest and shoulders rise, the head follows a little."""
	b = (1 - math.cos(2 * math.pi * t)) / 2
	return merged({
		"chest_bend": -2 * b, "head_bend": -8 + 1.5 * b,
		**both("arm_down", 74 - 2 * b), **both("elbow", 10 + 3 * b),
	})


def gait(t, stride, knee, arm, elbow, lean, twist, ankle):
	"""Walk and run: the left leg is forward at t = 0.25, the right at 0.75."""
	p = 2 * math.pi * t
	s, c = math.sin(p), math.cos(p)
	out = {"spine_bend": lean, "hips_turn": -twist * s, "spine_turn": 1.6 * twist * s, "head_bend": -8 + lean * 0.5}
	for side, sign in (("L", 1), ("R", -1)):
		ss, cc = s * sign, c * sign
		out[side + "_hip"] = stride * ss
		# the knee folds while the leg swings forward (cc > 0), most when it passes under the body
		out[side + "_knee"] = 6 + knee * max(0.0, cc) ** 1.5 + 0.25 * knee * max(0.0, -ss) * max(0.0, -cc)
		out[side + "_ankle"] = ankle * ss
		out[side + "_arm_fwd"] = 4 - arm * ss
		out[side + "_elbow"] = elbow + 0.6 * elbow * max(0.0, -ss)
	return merged(out)


def walk(t):
	return gait(t, stride=24, knee=40, arm=22, elbow=14, lean=3, twist=5, ankle=10)


def run(t):
	out = gait(t, stride=38, knee=85, arm=38, elbow=70, lean=14, twist=8, ankle=16)
	out["cape"] = 4 * math.sin(4 * math.pi * t)  # a cloak streams back and flaps twice a cycle
	return out


# --- poses and reactions ------------------------------------------------------

SIT = {  # on the ground, knees up, hands on the knees
	"spine_bend": 22, "head_bend": -18,
	**both("hip", 95), **both("hip_out", 14), **both("hip_twist", 10), **both("knee", 75), **both("ankle", 10),
	**both("arm_fwd", 50), **both("arm_down", 72), **both("arm_in", 8), **both("elbow", 40),
}


def sit(t):
	return merged(SIT)


def pickup(t):
	crouch = {
		"spine_bend": 38, "head_bend": 10,
		**both("hip", 75), **both("knee", 95), **both("ankle", 20),
		"R_arm_fwd": 55, "R_arm_in": 8, "R_elbow": 12, "R_fist": 0.4,
		"L_arm_fwd": 20, "L_elbow": 35,
	}
	return keyed([(0.0, {}), (0.45, crouch), (0.6, crouch), (1.0, {})], t)


def hurt(t):
	hit = {  # flinch: thrown back, arms down and behind
		"spine_bend": -14, "chest_bend": -6, "head_bend": -22, "head_tilt": 8, "body_y": -0.04,
		**both("arm_down", 68), **both("arm_fwd", -12), **both("elbow", 30), **both("fist", 0.5),
		**both("knee", 12),
	}
	return keyed([(0.0, {}), (0.35, hit), (1.0, {**hit, "spine_bend": -6, "head_bend": -12})], t)


def dead(t):
	buckle = {"spine_bend": 25, "head_bend": 20, **both("hip", 45), **both("knee", 70), **both("arm_down", 65),
		**both("arm_fwd", 20), **both("elbow", 30), **both("fist", 0.5)}
	# body_y keeps the fallen body centred in the cell: legs reach 0.55 m ahead of the hips, the rest 0.75 m behind
	falling = {"hips_bend": -50, "body_y": 0.05, "spine_bend": -10, "head_bend": -10, **both("hip", 30), **both("knee", 50),
		**both("arm_down", 40), **both("arm_fwd", 40), **both("elbow", 25), **both("fist", 0.3)}
	lying = {"hips_bend": -88, "spine_bend": -2, "head_bend": -18, "head_turn": 20, "body_y": 0.1,
		"L_hip": 20, "L_knee": 35, "R_hip": 4, "R_knee": 8, **both("hip_out", 8),
		**both("arm_down", 30), **both("arm_fwd", 5), **both("elbow", 20), **both("fist", 0.2)}
	return keyed([(0.0, {}), (0.3, buckle), (0.65, falling), (1.0, lying)], t)


# --- tool and weapon swings (right hand) ----------------------------------------

READY = {"R_arm_fwd": 30, "R_elbow": 55, "R_arm_down": 72}


def slash(t):
	"""One-handed sword: up behind the right shoulder, down and across to the left."""
	wind = {"chest_turn": -25, "spine_turn": -10, "R_arm_fwd": 130, "R_arm_down": 40, "R_elbow": 95,
		"R_wrist_side": 20, "L_arm_fwd": 25, "L_elbow": 40, "R_hip": 10, "L_hip": -6}
	strike = {"chest_turn": 25, "spine_turn": 10, "spine_bend": 12, "R_arm_fwd": 40, "R_arm_down": 58,
		"R_arm_in": 28, "R_elbow": 12, "R_wrist_side": -35, "L_arm_fwd": -10, "L_elbow": 30, "R_hip": 22,
		"R_knee": 15, "L_hip": -10}
	return keyed([(0.0, READY), (0.3, wind), (0.55, strike), (0.75, strike), (1.0, READY)], t)


def tool(x, y, z, yaw, pitch, edge_yaw, edge_pitch):
	"""The right fist placed by the tool (rig.py R_tool): grip, handle and edge in the chest's frame."""
	return {"R_tool": 1, "R_tool_x": x, "R_tool_y": y, "R_tool_z": z, "R_tool_yaw": yaw, "R_tool_pitch": pitch,
		"R_tool_edge_yaw": edge_yaw, "R_tool_edge_pitch": edge_pitch}


def chop(t):
	"""Felling, with both hands on the handle (the left below the right): the axe goes back and
	up over the right shoulder as the trunk turns away, then comes round and down across the
	body as it turns into the blow, and bites in front at waist height with the blade only a
	little off level, as into a standing trunk."""
	grip = {"L_hold": -0.08, "R_arm_fwd": 40, "R_arm_down": 60, "R_elbow": 60}
	ready = {**grip, **tool(0.12, 0.3, -0.3, 0, 40, 0, -50)}
	wind = {**grip, **tool(0.3, -0.02, 0.22, -150, 35, -70, -10),
		"hips_turn": -10, "spine_turn": -15, "chest_turn": -30, "head_turn": 30, "spine_bend": -4, "R_hip": 6, "L_hip": -4}
	swing = {**grip, **tool(0.3, 0.2, -0.05, -70, 10, 0, -20),
		"hips_turn": -2, "spine_turn": -2, "chest_turn": -5, "head_turn": 10, "spine_bend": 6}
	strike = {**grip, **tool(0.1, 0.36, -0.28, 20, -8, 90, -15),
		"hips_turn": 8, "spine_turn": 12, "chest_turn": 25, "head_turn": -10, "spine_bend": 14,
		**both("knee", 14), "L_hip": 14, "R_hip": 4}
	return keyed([(0.0, ready), (0.35, wind), (0.5, wind), (0.62, swing), (0.74, strike), (0.88, strike), (1.0, ready)], t)


def mine(t):
	"""A pick, with both hands on the handle: raised straight up over the head with the point
	up and the body leaning back, then brought down in front, the trunk bending into the
	blow and the knees giving, the point driven down into the rock before the feet."""
	grip = {"L_hold": -0.08, "R_arm_fwd": 40, "R_arm_down": 60, "R_elbow": 60}
	ready = {**grip, **tool(0.12, 0.3, -0.3, 0, 40, 0, -50)}
	wind = {**grip, **tool(0.05, 0.12, 0.56, 180, 55, 0, 35),
		"spine_bend": -8, "head_bend": -10, "R_hip": 4, "L_hip": 10, "L_knee": 6}
	swing = {**grip, **tool(0.05, 0.32, 0.3, 0, 70, 0, -20),
		"spine_bend": 6, "L_hip": 12, "L_knee": 8}
	strike = {**grip, **tool(0.05, 0.42, -0.3, 0, -30, 180, -60),
		"spine_bend": 24, "head_bend": 10, **both("knee", 20), "L_hip": 24, "R_hip": 10}
	return keyed([(0.0, ready), (0.35, wind), (0.5, wind), (0.62, swing), (0.74, strike), (0.88, strike), (1.0, ready)], t)


def thrust(t):
	"""Spear or hoe: held low and level, drawn back, driven forward on a straight arm; the left
	hand holds the shaft behind the right one (L_hold) and slides along it."""
	ready = {"R_arm_fwd": 12, "R_elbow": 15, "L_arm_fwd": 30, "L_arm_in": 20, "L_elbow": 50, "L_hold": -0.4}
	stance = {"L_hip": 18, "L_knee": 12, "R_hip": -10, "R_knee": 8}
	back = {**stance, "L_hold": -0.35, "chest_turn": -20, "R_arm_fwd": -22, "R_arm_down": 70, "R_elbow": 20, "R_wrist_side": 25,
		"L_arm_fwd": 45, "L_arm_in": 25, "L_elbow": 55}
	out = {**stance, "L_hold": -0.5, "L_hip": 26, "L_knee": 22, "spine_bend": 10, "chest_turn": 22, "body_y": 0.05,
		"R_arm_fwd": 70, "R_arm_down": 70, "R_arm_in": 10, "R_elbow": 5, "R_wrist_side": -35,
		"L_arm_fwd": 55, "L_arm_in": 25, "L_elbow": 30}
	return keyed([(0.0, ready), (0.3, back), (0.55, out), (0.75, out), (1.0, ready)], t)


def shoot(t):
	"""Bow in the left hand: turn the left shoulder to the target, raise, draw to the chin, loose."""
	# the trunk turns 55 degrees to the right: the bow arm swings back left by as much to aim ahead
	turn = {"spine_turn": -30, "chest_turn": -25, "head_turn": 50, "L_hip_twist": -5, "R_hip_twist": 20}
	raised = {**turn, "L_arm_fwd": 85, "L_arm_down": 70, "L_arm_in": -55, "L_elbow": 6, "L_wrist_side": 20,
		"R_arm_fwd": 80, "R_arm_down": 70, "R_arm_in": 25, "R_elbow": 60}
	drawn = {**raised, "R_arm_fwd": 75, "R_arm_in": -15, "R_arm_down": 72, "R_elbow": 150, "R_wrist": 10}
	loosed = {**drawn, "R_arm_fwd": 70, "R_arm_in": -40, "R_elbow": 110, "R_fist": 0.3}
	return keyed([(0.0, {}), (0.2, turn), (0.4, raised), (0.65, drawn), (0.75, drawn), (0.85, loosed), (1.0, {})], t)


def cast(t):
	"""Fishing rod or spell: the right arm goes up and back, then sweeps forward and holds."""
	back = {"spine_bend": -6, "chest_turn": -15, "R_arm_fwd": 150, "R_arm_down": 55, "R_elbow": 50, "R_wrist": -20,
		"L_arm_fwd": 20, "L_elbow": 30}
	fwd = {"spine_bend": 12, "chest_turn": 15, "R_arm_fwd": 75, "R_arm_down": 72, "R_arm_in": 8, "R_elbow": 10,
		"R_wrist": 10, "L_arm_fwd": 10, "L_elbow": 25, "R_hip": 10, "L_hip": -4}
	return keyed([(0.0, READY), (0.3, back), (0.5, back), (0.7, fwd), (1.0, fwd)], t)


CLIPS = {
	# name: (frames, fps, loop, pose)
	"idle": (4, 3, True, idle),
	"walk": (8, 11, True, walk),
	"run": (8, 13, True, run),
	"sit": (1, 1, True, sit),
	"pickup": (6, 12, False, pickup),
	"hurt": (4, 12, False, hurt),
	"dead": (6, 10, False, dead),
	"slash": (6, 16, False, slash),
	"thrust": (8, 18, False, thrust),
	"chop": (10, 22, False, chop),
	"mine": (10, 22, False, mine),
	"shoot": (12, 22, False, shoot),
	"cast": (10, 18, False, cast),
}


def frame_t(clip, i):
	frames, _, loop, _ = CLIPS[clip]
	return i / frames if loop or frames == 1 else i / (frames - 1)
