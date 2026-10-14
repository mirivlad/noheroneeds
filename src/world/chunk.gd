class_name Chunk
extends RefCounted
## A square of cells in one location's grid. Each named layer stores, per cell,
## an index into this chunk's own palette of content ids ("" = empty), so the
## stored form never depends on global numbering of content.

const SIZE := 32
const CELLS := SIZE * SIZE

## palette[0] is always "" (empty cell).
var palette := PackedStringArray([""])
## layer name -> PackedInt32Array of CELLS palette indices
var layers := {}
## cell index -> Dictionary of CBOR-compatible properties (owner, damage...)
var props := {}
## Free-form CBOR-compatible metadata, e.g. which generator made the chunk.
var meta := {}
## Derived, not stored: per cell, what Terrain worked out about it (solid,
## opaque...), 0 when not yet; a change of the cell forgets it.
var traits := PackedByteArray()
var _index := {"": 0}


static func cell_index(x: int, y: int) -> int:
	return y * SIZE + x


func get_cell(layer: String, x: int, y: int) -> String:
	var cells: PackedInt32Array = layers.get(layer, PackedInt32Array())
	if cells.is_empty():
		return ""
	return palette[cells[cell_index(x, y)]]


func set_cell(layer: String, x: int, y: int, content_id: String) -> void:
	var cells: PackedInt32Array = layers.get(layer, PackedInt32Array())
	if cells.is_empty():
		if content_id == "":
			return
		cells.resize(CELLS)
	var i: int = _index.get(content_id, -1)
	if i < 0:
		i = palette.size()
		palette.append(content_id)
		_index[content_id] = i
	cells[cell_index(x, y)] = i
	layers[layer] = cells
	if not traits.is_empty():
		traits[cell_index(x, y)] = 0


func get_props(x: int, y: int) -> Dictionary:
	return props.get(cell_index(x, y), {})


func set_props(x: int, y: int, value: Dictionary) -> void:
	if value.is_empty():
		props.erase(cell_index(x, y))
	else:
		props[cell_index(x, y)] = value
	if not traits.is_empty():
		traits[cell_index(x, y)] = 0


## Cells of a layer as content ids (for comparisons and tools; not for hot paths).
func layer_ids(layer: String) -> PackedStringArray:
	var out := PackedStringArray()
	out.resize(CELLS)
	var cells: PackedInt32Array = layers.get(layer, PackedInt32Array())
	if not cells.is_empty():
		for i in CELLS:
			out[i] = palette[cells[i]]
	return out


## Same cells, props and meta, regardless of palette order.
func same_as(other: Chunk) -> bool:
	if props != other.props or meta != other.meta:
		return false
	var names := {}
	for n: String in layers:
		names[n] = true
	for n: String in other.layers:
		names[n] = true
	for n: String in names:
		if layer_ids(n) != other.layer_ids(n):
			return false
	return true


## An independent copy (packed arrays are copy-on-write, so this is cheap):
## the writer thread encodes it while the simulation keeps changing the original.
func snapshot() -> Chunk:
	var c := Chunk.new()
	c.palette = palette.duplicate()
	c._index = _index.duplicate()
	for n: String in layers:
		c.layers[n] = (layers[n] as PackedInt32Array).duplicate()
	c.props = props.duplicate(true)
	c.meta = meta.duplicate(true)
	return c


## Rebuilds the palette lookup after the palette was replaced (codec use).
func _reindex() -> void:
	_index.clear()
	for i in palette.size():
		_index[palette[i]] = i
