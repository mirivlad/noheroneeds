extends TestCase
## ADR-0053: what lies in the ground follows the land — ore richer under
## mountains, silver and gold only under hills and mountains, pebbles (flint)
## on the shores; nothing dug or picked up comes back.

var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())


func test_richness_follows_the_height_of_the_land() -> void:
	var relief := [0.5, 1.3, 2.0]
	eq(UndergroundGenerator.relief_factor(relief, -INF), 1.0, "no land known: as it is")
	eq(UndergroundGenerator.relief_factor(relief, 0.0), 0.5, "lowland")
	check(is_equal_approx(UndergroundGenerator.relief_factor(relief, (Geography.HILLS + Geography.MOUNTAINS) * 0.5), 1.3), "hills")
	eq(UndergroundGenerator.relief_factor(relief, 1.0), 2.0, "mountains")


## Ore under the mountains and under the lowland of one world, counted.
func test_ore_is_richer_under_mountains() -> void:
	var surface := SurfaceGenerator.new(2, _content)
	var under := UndergroundGenerator.new(2, _content)
	under.geography = surface.geography
	var r := surface.geography.region(Vector2i.ZERO)
	var high: Array[Vector2i] = []
	var low: Array[Vector2i] = []
	for k in GeoRegion.SIZE * GeoRegion.SIZE:
		var at := (r.first + Vector2i(k % GeoRegion.SIZE, k / GeoRegion.SIZE)) * Geography.STEP - surface.geography.origin
		var chunk := Vector2i(floori(at.x / 32.0), floori(at.y / 32.0))
		if r.height[k] > Geography.MOUNTAINS + 0.05 and high.size() < 6:
			high.append(chunk)
		elif r.height[k] > 0.02 and r.height[k] < Geography.HILLS * 0.4 and low.size() < 6 and k % 7 == 0:
			low.append(chunk)
	check(high.size() == 6 and low.size() == 6, "mountains and lowland found: %d, %d" % [high.size(), low.size()])
	var ore_high := _ores(under, high)
	var ore_low := _ores(under, low)
	check(ore_high["all"] > ore_low["all"] * 1.5, "more ore under mountains: %s vs %s" % [ore_high, ore_low])
	eq(int(ore_low.get("base:silver_ore_rock", 0)) + int(ore_low.get("base:gold_ore_rock", 0)), 0, "no silver nor gold under lowland")
	check(int(ore_high.get("base:silver_ore_rock", 0)) + int(ore_high.get("base:gold_ore_rock", 0)) > 0, "silver or gold under mountains: %s" % ore_high)


func _ores(under: UndergroundGenerator, chunks: Array[Vector2i]) -> Dictionary:
	var out := {"all": 0}
	for at: Vector2i in chunks:
		for z in [-3, -4]:
			for id: String in under.generate(z, at.x, at.y).layer_ids("structure"):
				if id.ends_with("_ore_rock") or id == "base:gem_rock":
					out[id] = int(out.get(id, 0)) + 1
					out["all"] = int(out["all"]) + 1
	return out


func test_pebbles_lie_on_shores() -> void:
	var gen := SurfaceGenerator.new(2, _content)
	var shores := 0
	var pebbles := 0
	for cy in range(-6, 6):
		for cx in range(-6, 6):
			var c := gen.generate(cx, cy)
			for i in Chunk.CELLS:
				var lx := i % Chunk.SIZE
				var ly := i / Chunk.SIZE
				if c.get_cell("ground", lx, ly) == "base:sand":
					shores += 1
					if c.get_cell("cover", lx, ly) == "base:pebbles":
						pebbles += 1
	check(shores > 0 and pebbles > shores / 30, "pebbles (flint) on the shores: %d of %d" % [pebbles, shores])


## What is dug or picked up is gone for good: no time brings it back, nor
## the chunk going out of memory and coming back.
func test_minerals_never_come_back() -> void:
	var db := tmp_dir().path_join("world.db")
	var w := ServerWorld.open(db, _content, {"seed": 2})
	var c := w.chunk("surface", 0, 0)
	c.set_cell("cover", 20, 20, "base:iron_outcrop")
	c.set_cell("cover", 21, 20, "base:pebbles")
	w.mark_chunk_dirty("surface", 0, 0)
	var ch := PortableCharacter.create("Аня", "base:human_m")
	ch.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + ch.character_id, ch)
	var a := ch.character_id
	w.move_character(a, Vector2i(20 * 256 + 128, 21 * 256 + 128))
	w.grant(a, "base:pickaxe", 1)
	_req(w, a, {"type": "hold", "item": "base:pickaxe"})
	for i in 60:
		for t in 25:
			w.tick += 1
			w.combat.step(w.tick)
		_req(w, a, {"type": "gather", "location": "surface", "x": 20, "y": 20, "layer": "cover", "item": "base:pickaxe"})
		if w.chunk("surface", 0, 0).get_cell("cover", 20, 20) == "":
			break
	eq(w.chunk("surface", 0, 0).get_cell("cover", 20, 20), "", "the outcrop is worked out")
	check(w.inventory(a).count("base:iron_ore") > 0, "ore got")
	for t in 25:
		w.tick += 1
		w.combat.step(w.tick)
	_req(w, a, {"type": "gather", "location": "surface", "x": 21, "y": 20, "layer": "cover"})
	eq(w.chunk("surface", 0, 0).get_cell("cover", 21, 20), "", "the pebbles picked up")
	w.world_time += Daylight.DAY_MS * 30
	w.needs.step()
	w.close()
	var again := ServerWorld.open(db, _content)
	again.world_time += Daylight.DAY_MS * 60
	eq(again.chunk("surface", 0, 0).get_cell("cover", 20, 20), "", "a season later: still worked out")
	eq(again.chunk("surface", 0, 0).get_cell("cover", 21, 20), "", "and the pebbles still gone")
	again.close()


func _req(w: ServerWorld, actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}
