class_name Terrain
## Rules about cells that both the server and the client need.

## Layers that can block walking, bottom to top. A definition decides with its
## "solid" flag; unknown structure parts block, unknown ground and plants do not.
const BLOCKING_LAYERS := ["ground", "cover", "structure"]


static func is_solid(c: Chunk, lx: int, ly: int, content: ContentRegistry) -> bool:
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
