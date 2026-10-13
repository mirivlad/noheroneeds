extends TestCase


func _sample() -> Chunk:
	var c := Chunk.new()
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			c.set_cell("ground", x, y, "base:grass" if (x + y) % 7 else "base:dirt")
	c.set_cell("structure", 3, 4, "base:wood_wall")
	c.set_cell("structure", 4, 4, "base:wood_door")
	c.set_props(3, 4, {"owner": "player-1", "damage": 2})
	c.meta = {"gen": "base:surface", "gen_version": 1}
	return c


func test_round_trip() -> void:
	var c := _sample()
	var back := ChunkCodec.decode(ChunkCodec.encode(c))
	if check(back != null, ChunkCodec.last_error):
		check(back.same_as(c), "same cells, props and meta")
		eq(back.get_cell("structure", 4, 4), "base:wood_door")
		eq(back.get_props(3, 4), {"owner": "player-1", "damage": 2})


func test_encoding_is_deterministic_and_compact() -> void:
	var c := _sample()
	# The same content reached by a different history: unused palette entries.
	var d := _sample()
	d.set_cell("cover", 1, 1, "base:old_flower")
	d.set_cell("cover", 1, 1, "")
	eq(ChunkCodec.encode(d), ChunkCodec.encode(c), "same bytes")
	check(ChunkCodec.encode(c).size() < 600, "zstd keeps a typical chunk small: %d" % ChunkCodec.encode(c).size())


func test_wide_palette_uses_u16() -> void:
	var c := Chunk.new()
	for i in Chunk.CELLS:
		c.set_cell("cover", i % Chunk.SIZE, i / Chunk.SIZE, "test:item_%d" % i)
	var back := ChunkCodec.decode(ChunkCodec.encode(c))
	if check(back != null, ChunkCodec.last_error):
		check(back.same_as(c), "1024 distinct ids survive")


func test_unknown_content_ids_survive() -> void:
	# Content that this build does not know (removed mod, newer pack) is kept as is.
	var c := Chunk.new()
	c.set_cell("structure", 0, 0, "somemod:crystal_wall")
	var back := ChunkCodec.decode(ChunkCodec.encode(c))
	eq(back.get_cell("structure", 0, 0), "somemod:crystal_wall")


func test_corrupt_data_is_rejected() -> void:
	var good := ChunkCodec.encode(_sample())
	check(ChunkCodec.decode(PackedByteArray()) == null, "empty")
	var future := good.duplicate()
	future.encode_u16(4, 99)
	check(ChunkCodec.decode(future) == null and ChunkCodec.last_error.contains("version"), "future codec")
	var cut := good.slice(0, good.size() - 5)
	check(ChunkCodec.decode(cut) == null, "truncated")
	var flipped := good.duplicate()
	flipped[20] = flipped[20] ^ 0xff
	check(ChunkCodec.decode(flipped) == null, "corrupted body")
