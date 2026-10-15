class_name MapTile
## A chunk as a map shows it (ADR-0020): for each cell the id of what one
## sees from above — a part standing there, else a roof, a ceiling, a plant,
## the ground — as indices into the tile's own palette. Small (packed and
## compressed), the same on the server and the client, colours left to the
## client (its pictures).

const LAYERS := ["structure", "roof", "ceiling", "cover", "ground"]


## {"palette": PackedStringArray, "cells": PackedByteArray of Chunk.CELLS}.
## Straight over the layers' index arrays (the chunk's palette is the tile's):
## a client makes one for every chunk it receives.
static func of(c: Chunk) -> Dictionary:
	var layers: Array[PackedInt32Array] = []
	for layer: String in LAYERS:
		var a: PackedInt32Array = c.layers.get(layer, PackedInt32Array())
		if not a.is_empty():
			layers.append(a)
	var cells := PackedByteArray()
	cells.resize(Chunk.CELLS)
	var palette := c.palette.duplicate()
	var remap := {}
	if palette.size() > 255:
		# A rare crowded chunk: only the ids used here, and the first 254.
		palette = PackedStringArray([""])
	for i in Chunk.CELLS:
		var k := 0
		for a: PackedInt32Array in layers:
			if a[i] != 0:
				k = a[i]
				break
		if c.palette.size() > 255 and k != 0:
			if not remap.has(k):
				remap[k] = palette.size() if palette.size() < 255 else 0
				if palette.size() < 255:
					palette.append(c.palette[k])
			k = remap[k]
		cells[i] = k
	return {"palette": palette, "cells": cells}


static func encode(t: Dictionary) -> PackedByteArray:
	return Cbor.encode_fast({"p": Array(t["palette"]), "c": (t["cells"] as PackedByteArray).compress(FileAccess.COMPRESSION_DEFLATE)})


## {} if the bytes are not a tile.
static func decode(data: PackedByteArray) -> Dictionary:
	var d := Cbor.decode(data)
	if not d.ok or typeof(d.value) != TYPE_DICTIONARY:
		return {}
	var v: Dictionary = d.value
	if typeof(v.get("p")) != TYPE_ARRAY or typeof(v.get("c")) != TYPE_PACKED_BYTE_ARRAY:
		return {}
	var cells := (v["c"] as PackedByteArray).decompress(Chunk.CELLS, FileAccess.COMPRESSION_DEFLATE)
	if cells.size() != Chunk.CELLS:
		return {}
	var palette := PackedStringArray()
	for id: Variant in v["p"]:
		palette.append(String(id))
	for b in cells:
		if b >= palette.size():
			return {}
	return {"palette": palette, "cells": cells}
