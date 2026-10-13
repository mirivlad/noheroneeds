class_name ChunkCodec
## Binary form of a Chunk for the world store (ADR-0005).
##
## Header (little-endian): "NHCK", u16 codec version, u8 flags (1 = zstd body),
## u32 raw body size. Body v1: u8 chunk size; u16 palette count, then each id
## as u16 length + UTF-8 (empty id is implicit index 0); u8 layer count, then
## each layer as u8 name length + name, u8 encoding (0 empty, 1 u8 indices,
## 2 u16 indices) + cells; u32 length + CBOR {"meta", "props"}.
## Unused palette entries are dropped and the rest sorted, so equal chunks
## encode to equal bytes. Every older codec version stays readable.

const MAGIC := "NHCK"
const VERSION := 1
const FLAG_ZSTD := 1
## Refuse absurd sizes from corrupt data before allocating.
const MAX_RAW := 1 << 24

static var last_error := ""


static func encode(chunk: Chunk) -> PackedByteArray:
	# Compact the palette: only ids in use, sorted for deterministic output.
	var used := {}
	var names: Array = chunk.layers.keys()
	names.sort()
	for n: String in names:
		var cells: PackedInt32Array = chunk.layers[n]
		for i in Chunk.CELLS:
			used[cells[i]] = true
	var ids: Array = []
	for i: int in used:
		if i != 0:
			ids.append(chunk.palette[i])
	ids.sort()
	var remap := PackedInt32Array()
	remap.resize(chunk.palette.size())
	for k in ids.size():
		var old: int = chunk._index[ids[k]]
		remap[old] = k + 1
	var body := StreamPeerBuffer.new()
	body.put_u8(Chunk.SIZE)
	body.put_u16(ids.size())
	for id: String in ids:
		var b := id.to_utf8_buffer()
		body.put_u16(b.size())
		body.put_data(b)
	var kept: Array = []
	for n: String in names:
		var cells: PackedInt32Array = chunk.layers[n]
		if cells.count(0) != Chunk.CELLS:
			kept.append(n)
	body.put_u8(kept.size())
	for n: String in kept:
		var nb := n.to_utf8_buffer()
		body.put_u8(nb.size())
		body.put_data(nb)
		var cells: PackedInt32Array = chunk.layers[n]
		var data := PackedByteArray()
		if ids.size() < 256:
			body.put_u8(1)
			data.resize(Chunk.CELLS)
			for i in Chunk.CELLS:
				data[i] = remap[cells[i]]
		else:
			body.put_u8(2)
			data.resize(Chunk.CELLS * 2)
			for i in Chunk.CELLS:
				data.encode_u16(i * 2, remap[cells[i]])
		body.put_data(data)
	var tail := Cbor.encode({"meta": chunk.meta, "props": chunk.props})
	body.put_u32(tail.size())
	body.put_data(tail)
	var raw := body.data_array
	var out := StreamPeerBuffer.new()
	out.put_data(MAGIC.to_ascii_buffer())
	out.put_u16(VERSION)
	out.put_u8(FLAG_ZSTD)
	out.put_u32(raw.size())
	out.put_data(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return out.data_array


## Returns null and sets last_error on bad data.
static func decode(bytes: PackedByteArray) -> Chunk:
	last_error = ""
	if bytes.size() < 11 or bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		return _fail("not a chunk")
	var version := bytes.decode_u16(4)
	if version != 1:
		return _fail("unknown chunk codec version %d" % version)
	var flags := bytes[6]
	var raw_size := bytes.decode_u32(7)
	if raw_size > MAX_RAW:
		return _fail("body too large")
	var raw := bytes.slice(11)
	if flags & FLAG_ZSTD:
		raw = raw.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		return _fail("body size mismatch")
	return _decode_v1(raw)


static func _decode_v1(raw: PackedByteArray) -> Chunk:
	var r := StreamPeerBuffer.new()
	r.data_array = raw
	if raw.size() < 3 or r.get_u8() != Chunk.SIZE:
		return _fail("unexpected chunk size")
	var chunk := Chunk.new()
	var count := r.get_u16()
	for i in count:
		var n := r.get_u16()
		if r.get_position() + n > raw.size():
			return _fail("palette truncated")
		chunk.palette.append(r.get_data(n)[1].get_string_from_utf8())
	chunk._reindex()
	if chunk.palette.size() != count + 1:
		return _fail("duplicate palette entries")
	var nlayers := r.get_u8()
	for l in nlayers:
		var nn := r.get_u8()
		var name: String = r.get_data(nn)[1].get_string_from_utf8()
		var enc := r.get_u8()
		var width := 1 if enc == 1 else 2 if enc == 2 else 0
		if width == 0 or r.get_position() + Chunk.CELLS * width > raw.size():
			return _fail("bad layer " + name)
		var data: PackedByteArray = r.get_data(Chunk.CELLS * width)[1]
		var cells := PackedInt32Array()
		cells.resize(Chunk.CELLS)
		for i in Chunk.CELLS:
			var v := data[i] if width == 1 else data.decode_u16(i * 2)
			if v > count:
				return _fail("index outside palette in " + name)
			cells[i] = v
		chunk.layers[name] = cells
	if r.get_position() + 4 > raw.size():
		return _fail("tail truncated")
	var tl := r.get_u32()
	if r.get_position() + tl != raw.size():
		return _fail("tail size mismatch")
	var tail := Cbor.decode(r.get_data(tl)[1])
	if not tail.ok or typeof(tail.value) != TYPE_DICTIONARY:
		return _fail("tail: " + tail.error)
	var t: Dictionary = tail.value
	chunk.meta = t.get("meta", {})
	chunk.props = t.get("props", {})
	return chunk


static func _fail(msg: String) -> Chunk:
	last_error = msg
	return null
