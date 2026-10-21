extends SceneTree
## Overview maps of a world (ADR-0049), without a window: the regions round
## spawn's a pixel a chunk — relief, sea, lakes, rivers, biomes, settlements
## — and, with --detail, a piece of it cell by cell, as the game makes it. Usage (tools/world_map.sh does the importing first):
##   godot --headless -s res://tools/world_map.gd -- --seed=N[,M...]
##       [--regions=REACH] [--out=DIR] [--detail=CELLS] [--villages=RADIUS]

var _content: ContentRegistry
var _opts := {}


func _init() -> void:
	var o := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		o[kv[0]] = kv[1] if kv.size() > 1 else ""
	_opts = o
	var out := String(o.get("out", "user://maps"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	_content = ContentRegistry.load_packs(["res://content/base"])
	if not _content.errors.is_empty():
		printerr("content errors: ", _content.errors)
		quit(1)
		return
	var seeds: Array = String(o.get("seed", "1")).split(",")
	var reach := int(o.get("regions", "1"))
	for s: String in seeds:
		var seed_value := int(s) if s.is_valid_int() else hash(s)
		var t := Time.get_ticks_msec()
		var gen := SurfaceGenerator.new(seed_value, _content)
		var geo := gen.geography
		var shares := []
		for rj in range(-reach, reach + 1):
			for ri in range(-reach, reach + 1):
				shares.append("%d%%" % roundi(geo.region(Vector2i(ri, rj)).land_share() * 100.0))
		print("seed %s: %d regions in %d ms, spawn at %s, land %s" % [s, shares.size(), Time.get_ticks_msec() - t, geo.origin, " ".join(shares)])
		var base := ProjectSettings.globalize_path(out).path_join("world-%s" % s)
		_overview(gen, geo, reach).save_png(base + ".png")
		_climate(geo, reach).save_png(base + "-climate.png")
		if o.has("detail"):
			var cells := int(o["detail"]) if String(o["detail"]).is_valid_int() else 512
			t = Time.get_ticks_msec()
			_detail(gen, cells).save_png(base + "-detail.png")
			print("  detail %d cells round spawn in %d ms" % [cells, Time.get_ticks_msec() - t])
		print("  -> " + base + ".png")
	quit(0)


## Colours of biomes, grounds and water on the maps.
const SEA := Color(0.16, 0.3, 0.55)
const DEEP := Color(0.08, 0.17, 0.36)
const LAKE := Color(0.22, 0.42, 0.7)
const RIVER := Color(0.25, 0.5, 0.85)
const ROAD := Color(0.55, 0.36, 0.2)
const VILLAGE := Color(0.95, 0.15, 0.1)
const BIOME_COLOURS := {
	"base:meadow": Color(0.55, 0.75, 0.35), "base:forest": Color(0.2, 0.5, 0.22), "base:taiga": Color(0.18, 0.4, 0.33),
	"base:grove": Color(0.62, 0.62, 0.25), "base:swamp": Color(0.33, 0.42, 0.3), "base:steppe": Color(0.78, 0.72, 0.42),
	"base:tundra": Color(0.82, 0.86, 0.88), "base:rocky": Color(0.55, 0.5, 0.45), "base:desert": Color(0.9, 0.8, 0.55),
	"base:mountains": Color(0.48, 0.44, 0.42), "base:peaks": Color(0.93, 0.93, 0.96),
}


## Regions round spawn's, `reach` each way, a pixel a coarse point: the
## biome a point's middle has, shaded by height; water; rivers; settlements;
## the borders of regions faintly.
func _overview(gen: SurfaceGenerator, geo: Geography, reach: int) -> Image:
	var n := GeoRegion.SIZE
	var side := n * (2 * reach + 1)
	var img := Image.create(side, side, false, Image.FORMAT_RGB8)
	for rj in range(-reach, reach + 1):
		for ri in range(-reach, reach + 1):
			var r := geo.region(Vector2i(ri, rj))
			for j in n:
				for i in n:
					var k := j * n + i
					var h := r.height[k]
					var c: Color
					if h < Geography.SEA:
						c = SEA.lerp(DEEP, clampf(-h * 2.0, 0.0, 1.0))
					elif r.is_lake(k):
						c = LAKE
					else:
						var at := (r.first + Vector2i(i, j)) * Geography.STEP + Vector2i(Geography.STEP / 2, Geography.STEP / 2) - geo.origin
						c = BIOME_COLOURS.get(gen.biome_id_at(at.x, at.y), Color(0.85, 0.78, 0.55))  # none: a shore
						c = c.darkened(clampf(0.25 - h * 0.6, 0.0, 0.25)).lightened(clampf((h - 0.4) * 0.5, 0.0, 0.3))
						if r.river[k] > 0.0:
							c = RIVER.lerp(c, 0.2)
					if i == 0 or j == 0:
						c = c.darkened(0.15)
					img.set_pixel((ri + reach) * n + i, (rj + reach) * n + j, c)
	var corner := Vector2i(-reach, -reach) * n  # the image's first point, in geo points
	if gen.settlements and int(_opts.get("villages", "0")) > 0:
		for p: Dictionary in gen.settlements.plans_near(Vector2i.ZERO, int(_opts["villages"])):
			_dot(img, (Vector2i(p["centre"]) + geo.origin) / Geography.STEP - corner, VILLAGE)
	_dot(img, geo.origin / Geography.STEP - corner, Color.WHITE)  # spawn
	var big := img.duplicate() as Image
	big.resize(side * 2, side * 2, Image.INTERPOLATE_NEAREST)
	return big


func _dot(img: Image, at: Vector2i, c: Color) -> void:
	for d: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		var p := at + d
		if p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height():
			img.set_pixelv(p, c)


## Warmth (red-blue) and rain (green) side by side.
func _climate(geo: Geography, reach: int) -> Image:
	var n := GeoRegion.SIZE
	var side := n * (2 * reach + 1)
	var img := Image.create(side * 2, side, false, Image.FORMAT_RGB8)
	for rj in range(-reach, reach + 1):
		for ri in range(-reach, reach + 1):
			var r := geo.region(Vector2i(ri, rj))
			for j in n:
				for i in n:
					var k := j * n + i
					var x := (ri + reach) * n + i
					var y := (rj + reach) * n + j
					var sea := r.height[k] < Geography.SEA
					var t := (r.warmth[k] + 1.0) / 2.0
					img.set_pixel(x, y, Color(t, 0.2, 1.0 - t).darkened(0.5 if sea else 0.0))
					var w := (r.rain[k] + 1.0) / 2.0
					img.set_pixel(side + x, y, Color(0.6 - w * 0.5, 0.3 + w * 0.6, 0.2).darkened(0.6 if sea else 0.0))
	return img


## A square of `cells` round spawn, cell by cell as the game makes it: what
## stands, grows or lies there by its map colour.
func _detail(gen: SurfaceGenerator, cells: int) -> Image:
	var img := Image.create(cells, cells, false, Image.FORMAT_RGB8)
	var half := cells / 2
	var colours := {}
	for cy in range(floori(-half / 32.0), ceili(half / 32.0)):
		for cx in range(floori(-half / 32.0), ceili(half / 32.0)):
			var c := gen.generate(cx, cy)
			for ly in Chunk.SIZE:
				for lx in Chunk.SIZE:
					var x := cx * Chunk.SIZE + lx + half
					var y := cy * Chunk.SIZE + ly + half
					if x < 0 or y < 0 or x >= cells or y >= cells:
						continue
					var id := ""
					for layer: String in ["structure", "roof", "cover", "ground"]:
						id = c.get_cell(layer, lx, ly)
						if id != "":
							break
					if not colours.has(id):
						colours[id] = _colour_of(id)
					img.set_pixel(x, y, colours[id])
	return img


func _colour_of(id: String) -> Color:
	var d := _content.get_def(id)
	var name := id.get_slice(":", 1)
	if name in ["water"]:
		return SEA
	if name in ["deep_water"]:
		return DEEP
	if name in ["shallows"]:
		return Color(0.45, 0.62, 0.75)
	if name in ["sand", "gravel"]:
		return Color(0.85, 0.78, 0.55)
	if name in ["snow"]:
		return Color(0.93, 0.94, 0.97)
	if d.get("role") == "rock":
		return Color(0.42, 0.4, 0.4)
	if String(d.get("kind")) == "structure":
		return VILLAGE
	if name in ["dirt", "farmland", "mud"] or name.begins_with("road"):
		return ROAD
	if d.get("solid", false) and String(d.get("kind")) == "plant":
		return Color(0.12, 0.35, 0.15)  # trees, bushes
	if String(d.get("kind")) == "plant":
		return Color(0.45, 0.65, 0.3)
	return Color(0.5, 0.7, 0.35)
