extends TestCase


func _write(dir: String, file: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join(file), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


func test_base_pack_loads_clean() -> void:
	var reg := ContentRegistry.load_packs(["res://content/base"])
	eq(reg.errors, PackedStringArray(), "no errors")
	eq(reg.structure_cost("base:wood_wall"), {"base:plank": 3}, "integer counts")
	eq(ContentRegistry.from_defs([{"id": "test:g", "kind": "ground"},
		{"id": "test:visual/g", "kind": "visual", "for": "test:g", "mode": "flat", "rect": [0, 0, 16, 16], "origin": [0, 16], "grid": [4, 0]}]) \
		.errors.has("test:visual/g: grid needs two positive numbers"), true, "a grid needs positive sizes")
	eq(reg.visual_of("base:grass").get("grid_size"), Vector2i(4, 4), "ground is a seamless 4 x 4 texture")
	check(reg.fingerprint().length() == 64, "fingerprint")


## GDD scenario 18: a new tree, item and recipe come as data only, and the
## server builds the new part without any code knowing its name.
func test_new_content_is_data_only() -> void:
	var root := tmp_dir()
	var mod := root.path_join("orchard")
	_write(mod, "pack.json", {"format": 1, "id": "orchard", "version": "1.0.0", "depends": ["base"]})
	_write(mod, "defs.json", {"format": 1, "defs": [
		{"id": "orchard:apple_log", "kind": "item", "stack": 20},
		{"id": "orchard:apple_wall", "kind": "structure", "cost": {"orchard:apple_log": 2, "base:plank": 1}},
		{"id": "orchard:split_apple_log", "kind": "recipe", "inputs": {"orchard:apple_log": 1}, "outputs": {"base:plank": 3}},
	]})
	var reg := ContentRegistry.load_packs(["res://content/base", mod])
	eq(reg.errors, PackedStringArray())
	var w := ServerWorld.open(root.path_join("world.db"), reg)
	w.grant("a", "orchard:apple_log", 2)
	w.grant("a", "base:plank", 1)
	w.handle("a", {"request_id": "r1", "type": "build", "location": "surface", "x": 0, "y": 0, "part": "orchard:apple_wall"})
	w.sync()
	eq(w.take_acks(), [["a", "r1", {"ok": true}]])
	eq(w.inventory("a").stacks, {}, "paid with the new item")
	w.close()


## ADR-0009: texts, pictures and texture packs never change the rules fingerprint.
func test_fingerprint_ignores_presentation() -> void:
	var root := tmp_dir()
	var p := root.path_join("p")
	_write(p, "pack.json", {"format": 1, "id": "p", "version": "1", "depends": []})
	_write(p, "a.json", {"format": 1, "defs": [{"id": "p:x", "kind": "item", "name": "Камень"}]})
	var f1 := ContentRegistry.load_packs([p]).fingerprint()
	_write(p, "a.json", {"format": 1, "defs": [{"id": "p:x", "kind": "item", "name": "Stone", "description": "grey"}]})
	_write(p, "pack.json", {"format": 1, "id": "p", "version": "7", "depends": []})
	eq(ContentRegistry.load_packs([p]).fingerprint(), f1, "translation and pack version")
	var base := ContentRegistry.load_packs(["res://content/base"])
	var tex := root.path_join("tex")
	_write(tex, "pack.json", {"format": 1, "id": "tex", "version": "1", "depends": ["base"]})
	var img := Image.create(48, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color.ORANGE)
	img.save_png(tex.path_join("oak.png"))
	_write(tex, "visuals.json", {"format": 1, "defs": [{"id": "tex:visual/oak", "kind": "visual", "for": "base:oak",
		"atlas": "oak.png", "rect": [0, 0, 48, 64], "origin": [16, 64], "mode": "tall"}]})
	var with_pack := ContentRegistry.load_packs(["res://content/base", tex])
	eq(with_pack.errors, PackedStringArray())
	eq(with_pack.fingerprint(), base.fingerprint(), "a texture pack")
	eq(with_pack.visual_of("base:oak")["pack"], "tex", "the pack redraws the oak")


## Alternate pictures of one thing (two spruces): checked and resolved like
## the main picture, and still outside the rules.
func test_visual_alternates() -> void:
	var root := tmp_dir()
	var tex := root.path_join("tex")
	_write(tex, "pack.json", {"format": 1, "id": "tex", "version": "1", "depends": ["base"]})
	var img := Image.create(32, 64, false, Image.FORMAT_RGBA8)
	img.save_png(tex.path_join("a.png"))
	img.save_png(tex.path_join("b.png"))
	var def := {"id": "tex:visual/spruce", "kind": "visual", "for": "base:spruce", "atlas": "a.png",
		"rect": [0, 0, 32, 64], "origin": [8, 62], "mode": "tall",
		"alternates": [{"atlas": "b.png", "rect": [0, 0, 30, 60], "origin": [7, 58]}]}
	_write(tex, "visuals.json", {"format": 1, "defs": [def]})
	var reg := ContentRegistry.load_packs(["res://content/base", tex])
	eq(reg.errors, PackedStringArray())
	var alt: Dictionary = reg.visual_of("base:spruce")["alternates"][0]
	eq(alt["atlas_path"], tex.path_join("b.png"), "resolved in the pack")
	eq(alt["origin"], [7, 58], "integers")
	eq(reg.fingerprint(), ContentRegistry.load_packs(["res://content/base"]).fingerprint(), "not rules")
	def["alternates"] = [{"atlas": "missing.png", "rect": [0, 0, 1, 1], "origin": [0, 0]}, {"atlas": "b.png"}]
	_write(tex, "visuals.json", {"format": 1, "defs": [def]})
	eq(ContentRegistry.load_packs(["res://content/base", tex]).errors.size(), 2, "missing file, missing rect")


func test_fingerprint_follows_content() -> void:
	var root := tmp_dir()
	var p := root.path_join("p")
	_write(p, "pack.json", {"format": 1, "id": "p", "version": "1", "depends": []})
	_write(p, "a.json", {"format": 1, "defs": [{"id": "p:x", "kind": "item"}]})
	var f1 := ContentRegistry.load_packs([p]).fingerprint()
	eq(ContentRegistry.load_packs([p]).fingerprint(), f1, "stable")
	_write(p, "a.json", {"format": 1, "defs": [{"id": "p:x", "kind": "item", "stack": 5}]})
	check(ContentRegistry.load_packs([p]).fingerprint() != f1, "changes with a definition")


func test_problems_are_reported() -> void:
	var cases := {
		"bad id": [{"id": "Test:Thing", "kind": "item"}],
		"foreign namespace": [{"id": "base:thing", "kind": "item"}],
		"duplicate": [{"id": "test:a", "kind": "item"}, {"id": "test:a", "kind": "item"}],
		"unknown kind": [{"id": "test:a", "kind": "spaceship"}],
		"dangling reference": [{"id": "test:w", "kind": "structure", "cost": {"test:nothing": 1}}],
		"reference to non-item": [{"id": "test:w", "kind": "structure", "cost": {"test:v": 1}},
			{"id": "test:v", "kind": "structure", "cost": {"test:w": 1}}],
		"zero count": [{"id": "test:i", "kind": "item"}, {"id": "test:w", "kind": "structure", "cost": {"test:i": 0}}],
	}
	for name: String in cases:
		check(not ContentRegistry.from_defs(cases[name]).errors.is_empty(), name)


func test_missing_dependency_and_cycle() -> void:
	var root := tmp_dir()
	var a := root.path_join("a")
	var b := root.path_join("b")
	_write(a, "pack.json", {"format": 1, "id": "a", "version": "1", "depends": ["b"]})
	_write(b, "pack.json", {"format": 1, "id": "b", "version": "1", "depends": ["a"]})
	check(not ContentRegistry.load_packs([a, b]).errors.is_empty(), "cycle")
	check(not ContentRegistry.load_packs([a]).errors.is_empty(), "missing dependency")


func test_part_whose_pack_is_gone_is_kept() -> void:
	var root := tmp_dir()
	var full := ContentRegistry.from_defs([{"id": "test:plank", "kind": "item"},
		{"id": "test:glass_wall", "kind": "structure", "cost": {"test:plank": 1}}])
	var w := ServerWorld.open(root.path_join("world.db"), full)
	w.grant("a", "test:plank", 1)
	w.handle("a", {"request_id": "r1", "type": "build", "location": "surface", "x": 2, "y": 2, "part": "test:glass_wall"})
	w.sync()
	# The world is opened by a build without that structure.
	w.close()
	var w2 := ServerWorld.open(root.path_join("world.db"), ContentRegistry.from_defs([{"id": "test:plank", "kind": "item"}]))
	w2.handle("a", {"request_id": "r2", "type": "dismantle", "location": "surface", "x": 2, "y": 2})
	w2.sync()
	eq(w2.take_acks()[0][2], {"ok": false, "reason": "unknown_part"})
	eq(w2.chunk("surface", 0, 0).get_cell("structure", 2, 2), "test:glass_wall", "kept as it was")
	w2.close()
