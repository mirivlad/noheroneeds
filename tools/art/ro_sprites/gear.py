"""Clothes and gear of stage 4: what the game has and how each is filmed (pure Python).

Items follow content/base (characters.json, materials.json, underground.json)
and the game's equipment slots. Every item is a layer of its own: it is
rendered with the body as a holdout (invisible, but hiding what is behind it),
so the layer holds just the pixels of the item that show on that body, and
with a depth map that puts the layers together in any combination
(compose.py).

Held things play the game's swing for them (world_view.gd swing_kind: axes
chop, picks mine, the spear and the hoe thrust, the bow shoots, the rod casts) and
are carried in the clips that are not swings. Their cell is larger, with the
ground point at the same place relative to the body (HELD_CELL, HELD_FOOT).
"""
from clips import CLIPS

# Sprite pixels to a metre of the model, and the cells: a frame of a worn layer, and the
# larger one of a held thing, with the ground point at the same place relative to the body.
PX_PER_M = 77
CELL, FOOT = 172, 133
HELD_CELL, HELD_FOOT = 256, 176
CARRY = ["idle", "walk", "run", "sit", "pickup", "hurt", "dead"]

# item: (slot, swing clip for held things)
WORN = {
	"linen_shirt": "torso",
	"work_trousers": "legs",
	"boots": "feet",
	"leather_armor": "armor",
	"iron_helmet": "headwear",
	"felt_hat": "headwear",
	"fur_hood": "headwear",
	"wool_cloak": "back_item",
	"fur_cloak": "back_item",
}
HELD = {
	"flint_axe": "chop",
	"axe": "chop",
	"iron_axe": "chop",
	"flint_pick": "mine",
	"pickaxe": "mine",
	"iron_pickaxe": "mine",
	"hoe": "thrust",
	"spear": "thrust",
	"bow": "shoot",
	"fishing_rod": "cast",
}
# How a held thing is carried (clips of CARRY): the direction it keeps in the world (the
# character faces +Y, z is up) while the wrist turns it about the fist's hinge axis, so it
# stands the same way whatever the arm swing does; the fist's channel points forward, and
# without this every tool would stick straight out. Everything is carried head up: an axe
# with its head over the fist and the edge forward, a spear or a rod upright.
UP = (0, 0.3, 1)
CARRY_AIM = {item: UP for item in HELD}
AIM_ALWAYS = {"bow"}
# Lying flat, forward: along the body of one fallen on its back (render.carry turns carried
# things towards it in a fall and while they would go into the ground).
FLAT_AIM = (0, 1, -0.05)
# The bow's stave: half its length and how far its tips curve towards the archer (build_gear.py,
# render.py strings it).
BOW_HALF, BOW_DEPTH = 0.55, 0.13
# Layers that are not items: the body (with its drawn face) and the sample hair.
BASE_LAYERS = ["body", "hair_sample"]


def clips_of(layer):
	if layer in HELD:
		return CARRY + [HELD[layer]]
	return list(CLIPS)


def cell_of(layer):
	return (HELD_CELL, HELD_FOOT) if layer in HELD else (CELL, FOOT)


def all_layers():
	return BASE_LAYERS + list(WORN) + list(HELD)


# Sample outfits for previews (compose.py --outfit): layers from the body outwards.
OUTFITS = {
	"bare": ["body", "hair_sample"],
	"woodcutter": ["body", "hair_sample", "linen_shirt", "work_trousers", "boots", "felt_hat", "axe"],
	"miner": ["body", "hair_sample", "linen_shirt", "work_trousers", "boots", "iron_helmet", "iron_pickaxe"],
	"guard": ["body", "hair_sample", "linen_shirt", "work_trousers", "boots", "leather_armor", "iron_helmet",
		"wool_cloak", "spear"],
	"hunter": ["body", "hair_sample", "linen_shirt", "work_trousers", "boots", "fur_hood", "fur_cloak", "bow"],
	"farmer": ["body", "hair_sample", "linen_shirt", "work_trousers", "boots", "hoe"],
	"fisher": ["body", "hair_sample", "linen_shirt", "work_trousers", "fishing_rod"],
}
