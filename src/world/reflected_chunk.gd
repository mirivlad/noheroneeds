class_name ReflectedChunk
extends Chunk
## A north/south-reflected view of one canonical chunk at a planet's pole.
## Cell writes go directly to the canonical chunk; encoded views are snapshots.

var source: Chunk
var _synced_serial := -1


func _init(original: Chunk) -> void:
	source = original
	refresh()


func refresh() -> void:
	if _synced_serial == source._serial:
		return
	var image := snapshot()
	palette = image.palette
	_index = image._index
	layers = image.layers
	props = image.props
	meta = source.meta
	_synced_serial = source._serial


func get_cell(layer: String, x: int, y: int) -> String:
	return source.get_cell(layer, x, SIZE - 1 - y)


func set_cell(layer: String, x: int, y: int, content_id: String) -> void:
	refresh()
	source.set_cell(layer, x, SIZE - 1 - y, content_id)
	super.set_cell(layer, x, y, content_id)
	_synced_serial = source._serial


func get_props(x: int, y: int) -> Dictionary:
	return source.get_props(x, SIZE - 1 - y)


func set_props(x: int, y: int, value: Dictionary) -> void:
	refresh()
	source.set_props(x, SIZE - 1 - y, value)
	super.set_props(x, y, value)
	_synced_serial = source._serial


func layer_ids(layer: String) -> PackedStringArray:
	var ids := source.layer_ids(layer)
	var result := PackedStringArray()
	result.resize(CELLS)
	for y in SIZE:
		for x in SIZE:
			result[y * SIZE + x] = ids[(SIZE - 1 - y) * SIZE + x]
	return result


func snapshot() -> Chunk:
	var result := Chunk.new()
	result.palette = source.palette.duplicate()
	result._reindex()
	for layer: String in source.layers:
		var src: PackedInt32Array = source.layers[layer]
		var dst := PackedInt32Array()
		dst.resize(CELLS)
		for y in SIZE:
			for x in SIZE:
				dst[y * SIZE + x] = src[(SIZE - 1 - y) * SIZE + x]
		result.layers[layer] = dst
	for i: int in source.props:
		result.props[(SIZE - 1 - i / SIZE) * SIZE + i % SIZE] = source.props[i].duplicate(true)
	result.meta = source.meta.duplicate(true)
	return result
