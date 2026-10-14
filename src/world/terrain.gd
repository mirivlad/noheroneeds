class_name Terrain
## Rules about cells that both the server and the client need.

## Layer of a structure part by its role (ADR-0007): ceilings and roofs cover a
## cell from above, everything else stands on it.
static func layer_for_role(role: String) -> String:
	match role:
		"ceiling":
			return "ceiling"
		"roof":
			return "roof"
	return "structure"


## Covered by a ceiling or a roof: inside, not outdoors.
static func is_covered(c: Chunk, lx: int, ly: int) -> bool:
	return c.get_cell("ceiling", lx, ly) != "" or c.get_cell("roof", lx, ly) != ""

## Layers that can block walking, bottom to top. A definition decides with its
## "solid" flag; unknown structure parts block, unknown ground and plants do not.
const BLOCKING_LAYERS := ["ground", "cover", "structure"]

## Bits of Chunk.traits: worked out; blocks walking; blocks sight; no ground.
const _KNOWN := 1
const _SOLID := 2
const _OPAQUE := 4
const _NO_GROUND := 8


## empty_ground_blocks: on building levels a cell without floor is a void.
static func is_solid(c: Chunk, lx: int, ly: int, content: ContentRegistry, empty_ground_blocks := false) -> bool:
	var t := _traits(c, lx, ly, content)
	return t & _SOLID != 0 or (empty_ground_blocks and t & _NO_GROUND != 0)


## Whether a cell blocks sight (ADR-0018): a part that is not see-through
## (walls; a door unless open), or a solid plant (a tree, a bush).
static func is_opaque(c: Chunk, lx: int, ly: int, content: ContentRegistry) -> bool:
	return _traits(c, lx, ly, content) & _OPAQUE != 0


## What a cell is, worked out once and kept in the chunk until the cell
## changes: walking and sight ask about the same cells many times a second.
static func _traits(c: Chunk, lx: int, ly: int, content: ContentRegistry) -> int:
	var i := Chunk.cell_index(lx, ly)
	if c.traits.is_empty():
		c.traits.resize(Chunk.CELLS)
	var t := c.traits[i]
	if t != 0:
		return t
	t = _KNOWN
	if c.get_cell("ground", lx, ly) == "":
		t |= _NO_GROUND
	for layer: String in BLOCKING_LAYERS:
		var id := c.get_cell(layer, lx, ly)
		if id == "":
			continue
		var d := content.get_def(id)
		if layer == "structure" and d.get("openable", false) and c.get_props(lx, ly).get("open", false):
			continue  # an open door
		if bool(d.get("solid", layer == "structure")):
			t |= _SOLID
			break
	var part := c.get_cell("structure", lx, ly)
	if part != "":
		var d := content.get_def(part)
		if not (d.get("openable", false) and c.get_props(lx, ly).get("open", false)) \
				and bool(d.get("opaque", String(d.get("role", "")) in ["wall", "door"])):
			t |= _OPAQUE
	else:
		var plant := c.get_cell("cover", lx, ly)
		if plant != "" and bool(content.get_def(plant).get("solid", false)):
			t |= _OPAQUE
	c.traits[i] = t
	return t
