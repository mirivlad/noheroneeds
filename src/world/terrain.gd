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


## empty_ground_blocks: on building levels a cell without floor is a void.
static func is_solid(c: Chunk, lx: int, ly: int, content: ContentRegistry, empty_ground_blocks := false) -> bool:
	if empty_ground_blocks and c.get_cell("ground", lx, ly) == "":
		return true
	for layer: String in BLOCKING_LAYERS:
		var id := c.get_cell(layer, lx, ly)
		if id == "":
			continue
		var d := content.get_def(id)
		if layer == "structure" and d.get("openable", false) and c.get_props(lx, ly).get("open", false):
			continue  # an open door
		if bool(d.get("solid", layer == "structure")):
			return true
	return false
