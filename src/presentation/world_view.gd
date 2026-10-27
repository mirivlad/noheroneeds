class_name WorldView
extends Node2D
## Draws what the client knows: ground and flat plants as tile layers, tall
## things (trees, bushes, walls) and characters as Y-sorted sprites, ceilings
## and roofs as covers above the walls. Every picture comes from the content's
## visual definitions; nothing here knows a particular tree or wall.
##
## Only the client's own location is drawn in full. On a building level the
## surface below shows dimmed. On any level the cover over the room the
## player stands in is hidden, so the inside is visible (GDD scenario 7).

const CELL := 16
## Simulation units per screen pixel (Movement.UNIT / CELL).
const UNITS_PER_PIXEL := Movement.UNIT / CELL
## A storey (ADR-0024: 64 px on screen): covers sit this far above their
## cell, on top of the walls, and one standing a level up is lifted by it.
const COVER_LIFT := 32
## A storey in cells (a wall's top is drawn this many cells above its foot).
const STOREY_CELLS := COVER_LIFT / CELL
const UNDERGROUND_TINT := Color(0.32, 0.3, 0.34)
## Largest room whose cover is hidden around the player.
const MAX_ROOM := 2048

var content: ContentRegistry
var client: GameClient
## Called with the point (pixels) where a character's foot came down.
var on_step := Callable()
var _ground := TileMapLayer.new()
var _cover := TileMapLayer.new()
## The surface seen from a building level, dimmed.
var _below := TileMapLayer.new()
var _covers := Node2D.new()
## cell -> Sprite2D of the ceiling or roof over it
var _cover_sprites := {}
var _hidden_room := {}
## Crops drawn (cell -> [Sprite2D, visual, def, sown at]): they grow by the
## world's clock with nothing sent, so their stage is looked at now and then.
var _crops := {}
var _crops_seen := 0.0
## The season the trees are drawn in (Seasons index; -1 not yet): when the
## world's turns, everything is drawn again in the new one.
const SEASON_KEYS := ["spring", "summer", "autumn", "winter"]
var _season_drawn := -1
## Whether the land was drawn wintry (it freezes where we are, ADR-0055).
var _wintry := false
## Things that move (a fire): [sprite, first frame's x, frames, ms a frame, phase].
var _animated: Array = []
## Sprites made see-through because they stand in front of the player.
var _faded: Array[Sprite2D] = []
## Things in front of the player are seen through a window round the body.
var _see_through := ShaderMaterial.new()
## The drawn body of a character (world pixels from its feet): what may be hidden.
const BODY_SEEN := Rect2(-5, -24, 10, 24)
var _room_from := Vector2i(1 << 30, 0)
var _sorted := Node2D.new()
## The hour's light over the whole world (ADR-0014), and the lights of the
## light sources drawn now (brighter as it gets dark).
var _tint := CanvasModulate.new()
var _lights: Array[PointLight2D] = []
static var _glow: GradientTexture2D
## Light keeps to rooms and caves: walls, shut doors and cave rock stop it
## (an occluder on the cell they stand on; windows let it through). The walls
## and rock themselves are lit without shadows (their faces are drawn above
## their cells: a room's back wall must not be darkened by its own foot).
const LIT_UNSHADOWED := 2
## On the surface the land, its plants and the walls' feet are not shadowed:
## a wall's foot is all that stops light, and its shadow on the open ground
## would fall like a post's. Light still keeps out of rooms (floors and those
## inside are shadowed); in caves the rock's shadows lie on the floor.
var _outdoors_unshadowed := true
const STOPS_LIGHT := ["wall", "door"]
static var _cell_occluder: OccluderPolygon2D
var _chunk_nodes := {}
## Chunk key -> {cell: [Sprite2D]}: the tall things of a drawn chunk by the
## cell they stand on, so what is near a point is found without looking at
## them all (fading, picking).
var _cell_sprites := {}
## Cave rock: a tile in its own cell (its top, or its face where a passage
## is south), never over a passage, so nothing goes in front of or behind it
## — tiles, not sprites, and a cave is mostly rock (thousands of them).
var _rock_tops := TileMapLayer.new()
## visual id -> [source id, first atlas cell] of its tops.
var _rock_top_tiles := {}
## Chunks drawn are those within this many chunks of the player's (and one
## more is kept before being let go): sprites far away cost every frame.
const DRAW_RADIUS := 2
var _drawn_around := Vector2i(1 << 30, 0)
var _characters := {}
## visual id -> [source id, first atlas cell Vector2i, variants]
var _tiles := {}
## Grounds drawn as LPC terrains on the grid of cell corners (ADR-0024): a
## tile sits between four cells, its corners are theirs; a ground of a
## higher rank is drawn with its edge over the lower ones. Ground id ->
## [source id, atlas row, fills, rank]; ranks in order; a layer per rank.
var _terrain := {}
var _terrain_rank := {}
var _by_rank: Array[String] = []
var _terrain_layers: Array[TileMapLayer] = []
## Corner point (the tile between cells x-1..x, y-1..y) -> bits of the
## ranks drawn there.
var _terrain_set := {}
## The surface seen from a building level: terrain fills, a tile a cell.
var _below_terrain := TileMapLayer.new()
## Terrain tiles are 32 px, drawn at half (16 world pixels a cell).
const TERRAIN_TILE := 32
## The tiles of LPC pictures (terrain, floors), and the layers of flat LPC
## things a tile a cell: floors over the ground, flat things over floors.
var _ts32 := TileSet.new()
var _floor32 := TileMapLayer.new()
var _cover32 := TileMapLayer.new()
## Drawn where the content has no picture (a texture pack may lack one): a
## loud magenta checker, so a gap is noticed rather than hidden.
var _missing_source := -1


func setup(registry: ContentRegistry, game_client: GameClient) -> void:
	content = registry
	client = game_client
	var ts := TileSet.new()
	ts.tile_size = Vector2i(CELL, CELL)
	_ts32.tile_size = Vector2i(TERRAIN_TILE, TERRAIN_TILE)
	var sources := {}
	for target: String in content.visuals:
		var v: Dictionary = content.visuals[target]
		if v["mode"] != "flat" or v.has("terrain"):
			continue
		# LPC pictures (half a world pixel a texel) are 32 px tiles on their own layers.
		var big := float(v.get("pixel_scale", 1.0)) < 1.0
		var size := TERRAIN_TILE if big else CELL
		var path: String = v["atlas_path"]
		if not sources.has(path):
			var src := TileSetAtlasSource.new()
			src.texture = texture(path)
			src.texture_region_size = Vector2i(size, size)
			sources[path] = [(_ts32 if big else ts).add_source(src), src]
		var src: TileSetAtlasSource = sources[path][1]
		var first := Vector2i(v["rect"][0] / size, v["rect"][1] / size)
		var grid: Vector2i = v.get("grid_size", Vector2i(int(v["variants"]), 1))
		for j in grid.y:
			for i in grid.x:
				var at := first + Vector2i(i, j)
				if not src.has_tile(at):
					src.create_tile(at)
		_tiles[target] = [sources[path][0], first, int(v["variants"]), v.has("grid_size"), grid, big]
	var miss := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
	for y in CELL:
		for x in CELL:
			miss.set_pixel(x, y, Color.MAGENTA if (x / 4 + y / 4) % 2 == 0 else Color.BLACK)
	var ms := TileSetAtlasSource.new()
	ms.texture = ImageTexture.create_from_image(miss)
	ms.texture_region_size = Vector2i(CELL, CELL)
	ms.create_tile(Vector2i.ZERO)
	_missing_source = ts.add_source(ms)
	_setup_terrain()
	for target: String in content.visuals:
		var v: Dictionary = content.visuals[target]
		if v["mode"] != "tall" or v.get("autotile") != "rock":
			continue
		# The top of each variant: the picture's first tile (LPC: 32 px).
		var src := TileSetAtlasSource.new()
		src.texture = texture(v["atlas_path"])
		src.texture_region_size = Vector2i(TERRAIN_TILE, TERRAIN_TILE)
		var first := Vector2i(int(v["rect"][0]) / TERRAIN_TILE, int(v["rect"][1]) / TERRAIN_TILE)
		if _ts32.get_occlusion_layers_count() == 0:
			_ts32.add_occlusion_layer()
		var square := OccluderPolygon2D.new()
		var h := TERRAIN_TILE / 2.0
		square.polygon = PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])
		var sid := _ts32.add_source(src)  # first: its tiles then know the occlusion layer
		for i in int(v["variants"]):
			src.create_tile(first + Vector2i(i, 0))
			var td := src.get_tile_data(first + Vector2i(i, 0), 0)
			td.set_occluder_polygons_count(0, 1)
			td.set_occluder_polygon(0, 0, square)  # cave rock stops light
		_rock_top_tiles[target] = [sid, first]
	_rock_tops.tile_set = _ts32
	_rock_tops.scale = Vector2.ONE * float(CELL) / TERRAIN_TILE
	_ground.tile_set = ts
	_cover.tile_set = ts
	_below.tile_set = ts
	_below.z_index = -3
	_below.modulate = Color(0.42, 0.42, 0.52)
	_ground.z_index = -2
	_cover.z_index = -1
	_sorted.y_sort_enabled = true
	_covers.z_index = 10
	add_child(_tint)
	add_child(_below)
	add_child(_below_terrain)
	for layer: TileMapLayer in _terrain_layers:
		add_child(layer)  # higher grounds drawn later, over lower ones
	add_child(_ground)  # floors over the ground
	add_child(_floor32)
	add_child(_cover)
	add_child(_cover32)
	_rock_tops.z_index = -1
	_rock_tops.light_mask = LIT_UNSHADOWED
	add_child(_rock_tops)
	add_child(_sorted)
	add_child(_covers)


func _setup_terrain() -> void:
	var ts := _ts32
	var sources := {}
	var ids: Array[String] = []
	for id: String in content.visuals:
		var v: Dictionary = content.visuals[id]
		if v["mode"] != "flat" or not v.has("terrain"):
			continue
		var path: String = v["atlas_path"]
		if not sources.has(path):
			var src := TileSetAtlasSource.new()
			src.texture = texture(path)
			src.texture_region_size = Vector2i(TERRAIN_TILE, TERRAIN_TILE)
			sources[path] = [ts.add_source(src), src]
		var src: TileSetAtlasSource = sources[path][1]
		var row := int(v["rect"][1]) / TERRAIN_TILE
		var fills := int(v["terrain"].get("fills", 1))
		for col in range(1, 15 + fills):
			if not src.has_tile(Vector2i(col, row)):
				src.create_tile(Vector2i(col, row))
		_terrain[id] = [sources[path][0], row, fills, int(v["terrain"]["priority"])]
		ids.append(id)
	# Priorities become ranks 0..n-1, so they index small arrays and bits.
	ids.sort_custom(func(a: String, b: String) -> bool: return _terrain[a][3] < _terrain[b][3])
	for i in ids.size():
		_terrain[ids[i]][3] = i
		_terrain_rank[ids[i]] = i
		_by_rank.append(ids[i])
		var layer := TileMapLayer.new()
		layer.tile_set = ts
		layer.z_index = -2
		layer.scale = Vector2.ONE * float(CELL) / TERRAIN_TILE
		layer.position = -Vector2.ONE * CELL / 2.0  # tiles centred on cell corners
		_terrain_layers.append(layer)
	_below_terrain.tile_set = ts
	_below_terrain.scale = Vector2.ONE * float(CELL) / TERRAIN_TILE
	_floor32.tile_set = ts
	_floor32.scale = _below_terrain.scale
	_floor32.z_index = -2
	_cover32.tile_set = ts
	_cover32.scale = _below_terrain.scale
	_cover32.z_index = -1
	_below_terrain.z_index = -3
	_below_terrain.modulate = Color(0.42, 0.42, 0.52)


## The terrain tiles at the corners of a rectangle of cells (corner x is
## between cells x-1 and x). The four cells round a corner give its tile in
## each rank: the lowest of them is a fill, each higher one that a corner has
## is its edge over that — so a pond's bank lies over the grass, and where a
## corner is a floor or unknown (rank -1) nothing of the ground is drawn.
func _paint_terrain(location: String, x0: int, y0: int, w: int, h: int) -> void:
	if _terrain_layers.is_empty():
		return
	var rw := w + 2  # cells x0-1 .. x0+w: both sides of every corner
	var ranks := _ground_ranks(location, x0 - 1, y0 - 1, rw, h + 2)
	for y in range(h + 1):
		for x in range(w + 1):
			var corner := Vector2i(x0 + x, y0 + y)
			var tl := ranks[y * rw + x]
			var tr := ranks[y * rw + x + 1]
			var bl := ranks[(y + 1) * rw + x]
			var br := ranks[(y + 1) * rw + x + 1]
			var had: int = _terrain_set.get(corner, 0)
			var want := 0
			var lo := 1 << 30
			for r in [tl, tr, bl, br]:
				if r >= 0:
					want |= 1 << r
					lo = mini(lo, r)
			for r in _by_rank.size():
				var bit := 1 << r
				if want & bit:
					# The lowest fills every known corner; the others their own and higher.
					var m := (1 if tl >= r else 0) | (2 if tr >= r else 0) | (4 if bl >= r else 0) | (8 if br >= r else 0)
					if r == lo:
						m = (1 if tl >= 0 else 0) | (2 if tr >= 0 else 0) | (4 if bl >= 0 else 0) | (8 if br >= 0 else 0)
					var t: Array = _terrain[_by_rank[r]]
					var col := m
					if m == 15:
						col = 15 + ((corner.x * 73856093 ^ corner.y * 19349663) & 0x7fffffff) % int(t[2])
					_terrain_layers[r].set_cell(corner, t[0], Vector2i(col, t[1]))
				elif had & bit:
					_terrain_layers[r].erase_cell(corner)
			if want == 0:
				_terrain_set.erase(corner)
			else:
				_terrain_set[corner] = want


func _ground_ranks(location: String, x0: int, y0: int, w: int, h: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(w * h)
	out.fill(-1)
	for cy in range(floori(y0 / float(Chunk.SIZE)), floori((y0 + h - 1) / float(Chunk.SIZE)) + 1):
		for cx in range(floori(x0 / float(Chunk.SIZE)), floori((x0 + w - 1) / float(Chunk.SIZE)) + 1):
			var c: Chunk = client.chunks.get(ServerWorld.chunk_key(location, cx, cy))
			if c == null:
				continue
			var cells: PackedInt32Array = c.layers.get("ground", PackedInt32Array())
			if cells.is_empty():
				continue
			var rank_of := PackedInt32Array()
			var winter := _wintry and location == Levels.SURFACE
			for id: String in c.palette:
				# In winter the land lies under snow ("winter" of a ground), roads and fields not.
				var seen := String(content.get_def(id).get("winter", id)) if winter else id
				rank_of.append(_terrain_rank.get(seen, -1))
			var ax := maxi(x0, cx * Chunk.SIZE)
			var bx := mini(x0 + w, (cx + 1) * Chunk.SIZE)
			for y in range(maxi(y0, cy * Chunk.SIZE), mini(y0 + h, (cy + 1) * Chunk.SIZE)):
				var src := (y - cy * Chunk.SIZE) * Chunk.SIZE - cx * Chunk.SIZE
				var dst := (y - y0) * w - x0
				for x in range(ax, bx):
					out[dst + x] = rank_of[cells[src + x]]
	return out


## The ground of a cell as the client knows it ("" if its chunk is not here).
func ground_at(location: String, cell: Vector2i) -> String:
	var cx := floori(cell.x / float(Chunk.SIZE))
	var cy := floori(cell.y / float(Chunk.SIZE))
	var c: Chunk = client.chunks.get(ServerWorld.chunk_key(location, cx, cy))
	return c.get_cell("ground", cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE) if c else ""


## Cell corners with terrain drawn -> bits of the ranks drawn there.
func terrain_tiles() -> Dictionary:
	return _terrain_set


## The terrain layer of a ground (tests, tools).
func terrain_layer(ground: String) -> TileMapLayer:
	return _terrain_layers[_terrain_rank[ground]] if _terrain_rank.has(ground) else null


## The tile layer of the ground (or floors) of the client's location.
func ground_layer() -> TileMapLayer:
	return _ground


## Cells whose cover is hidden because the player stands in that room.
func hidden_room() -> Dictionary:
	return _hidden_room


func texture(path: String) -> Texture2D:
	return Art.texture(path)


## Call every frame. alpha: how far we are between the last tick and the next (0..1).
func update_view(alpha: float, delta: float) -> void:
	var keys := client.changed_chunks.duplicate()
	client.changed_chunks.clear()
	var outdoors := client.location == Levels.SURFACE
	if outdoors != _outdoors_unshadowed:
		_outdoors_unshadowed = outdoors
		keys = ["*"]  # plants drawn again with their light
	for l: CanvasItem in _terrain_layers + [_cover, _cover32]:
		l.light_mask = LIT_UNSHADOWED if outdoors else 1
	if client.has_time and (Seasons.of(client.world_time) != _season_drawn or _freezing_here() != _wintry):
		_season_drawn = Seasons.of(client.world_time)
		_wintry = _freezing_here()
		keys = ["*"]
	if keys.has("*"):
		_clear()
		keys = client.chunks.keys()
	for key: String in keys:
		_pending[key] = true
	_keep_near()
	_paint_pending()
	_update_light()
	_animate()
	_update_characters(alpha, delta)
	_update_room()
	_fade_occluders()
	_crops_seen += delta
	if _crops_seen >= 1.0:
		_crops_seen = 0.0
		_grow_crops()


## The crops drawn, at the stage the world's clock has brought them to.
func _grow_crops() -> void:
	for cell: Vector2i in _crops.keys():
		var c: Array = _crops[cell]
		if not is_instance_valid(c[0]):  # gone with its cell (dug, cleared): not a typed read of a freed one
			_crops.erase(cell)
			continue
		var s: Sprite2D = c[0]
		var r: Array = (c[1] as Dictionary)["states"].get("stage_%d" % Crops.stage(c[2], c[3], client.world_time, _crop_weather(),
			cell, client.climate_at(cell)), [])
		if not r.is_empty():
			s.region_rect = Rect2(r[0], r[1], r[2], r[3])


func _notification(what: int) -> void:
	# Layers made up front but never added (setup() not called) are freed too.
	if what == NOTIFICATION_PREDELETE:
		for n: Node in [_ground, _cover, _below, _covers, _sorted, _tint, _rock_tops,
				_below_terrain, _floor32, _cover32]:
			if is_instance_valid(n) and n.get_parent() == null:
				n.free()


func _update_light() -> void:
	if not client.has_time:
		return
	# Underground (ADR-0017) no day: dark but for torches; a little to see by.
	_tint.color = Daylight.tint(client.world_time) if client.z >= 0 else UNDERGROUND_TINT
	if client.z >= 0:  # an overcast sky is darker and greyer (ADR-0033)
		var dim := 1.0 - 0.25 * Weather.clouds(client.weather_seed, client.world_time, client.weather_place(), client.climate())
		_tint.color = Color(_tint.color.r * dim, _tint.color.g * dim, _tint.color.b * (dim * 0.5 + 0.5))
		if _wintry:  # a colder light (ADR-0036), where it freezes (ADR-0055)
			_tint.color = Color(_tint.color.r * 0.86, _tint.color.g * 0.92, _tint.color.b)
	var dark := 1.0 - Daylight.sun(client.world_time) if client.z >= 0 else 1.0  # below, always night
	for i in range(_lights.size() - 1, -1, -1):
		var l := _lights[i]
		if not is_instance_valid(l):
			_lights.remove_at(i)
			continue
		l.energy = float(l.get_meta("intensity")) * dark * 1.6
		l.visible = dark > 0.02
		if l.has_meta("flicker"):  # a fire's light trembles: brighter and dimmer, a little wider and narrower
			var t := Time.get_ticks_msec() / 1000.0 + float(l.get_meta("flicker"))
			var f := 0.08 * sin(t * 11.0) + 0.05 * sin(t * 23.7 + 1.3) + 0.04 * sin(t * 47.1 + 0.4)
			l.energy *= 1.0 + f
			l.texture_scale = float(l.get_meta("scale")) * (1.0 + f * 0.35)


## Frames of the things that move: in order, then the same mirrored (twice
## the round, less even to the eye).
func _animate() -> void:
	var now := Time.get_ticks_msec()
	for i in range(_animated.size() - 1, -1, -1):
		var a: Array = _animated[i]
		if not is_instance_valid(a[0]):
			_animated.remove_at(i)
			continue
		var s: Sprite2D = a[0]
		var n: int = a[2]
		var k := (now / int(a[3]) + int(a[4])) % (n * 2)
		s.region_rect.position.x = float(a[1]) + (k % n) * s.region_rect.size.x
		s.flip_h = k >= n


## A light carried (a torch in the hands): on the one who holds it, at hand
## height; gone when the thing is put away.
func _held_light(sprite: Node2D, held: String) -> void:
	var l: PointLight2D = sprite.get_node_or_null("held_light")
	var light: Dictionary = content.get_def(held).get("light", {}) if held != "" else {}
	if l and (light.is_empty() or l.get_meta("item") != held):
		_lights.erase(l)
		l.free()
		l = null
	if light.is_empty() or l:
		return
	l = _light_for(light, Vector2i.ZERO)
	l.name = "held_light"
	l.set_meta("item", held)
	l.position = Vector2(0, -10)
	sprite.add_child(l)
	_update_light()  # lit at once, not at the next hour's light


## What stops light on a cell (a wall, a shut door).
func _occluder_at(cell: Vector2i) -> LightOccluder2D:
	if _cell_occluder == null:
		_cell_occluder = OccluderPolygon2D.new()
		_cell_occluder.polygon = PackedVector2Array([Vector2.ZERO, Vector2(CELL, 0), Vector2(CELL, CELL), Vector2(0, CELL)])
	var o := LightOccluder2D.new()
	o.occluder = _cell_occluder
	o.position = Vector2(cell * CELL)
	return o


## A light source's glow: a soft round light the size of its radius.
func _light_for(def: Dictionary, cell: Vector2i) -> PointLight2D:
	if _glow == null:
		_glow = GradientTexture2D.new()
		_glow.fill = GradientTexture2D.FILL_RADIAL
		_glow.fill_from = Vector2(0.5, 0.5)
		_glow.fill_to = Vector2(1.0, 0.5)
		_glow.width = 128
		_glow.height = 128
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_glow.gradient = g
	var l := PointLight2D.new()
	l.texture = _glow
	l.color = Color(String(def["color"]))
	l.texture_scale = float(def["radius"]) * CELL * 2.0 / _glow.width
	# A little above the ground, within its own cell (from inside a wall it would light nothing).
	l.position = Vector2((cell.x + 0.5) * CELL, cell.y * CELL + 2)
	l.shadow_enabled = true
	l.shadow_filter = Light2D.SHADOW_FILTER_PCF5
	l.shadow_filter_smooth = 1.5
	l.range_item_cull_mask = 1 | LIT_UNSHADOWED
	l.shadow_item_cull_mask = 1
	l.set_meta("intensity", float(def["intensity"]))
	l.set_meta("scale", l.texture_scale)
	if def.get("flicker", false):
		l.set_meta("flicker", float(absi((cell.x * 73856093) ^ (cell.y * 19349663)) % 1000))
	l.energy = 0.0
	_lights.append(l)
	return l


## Chunks waiting to be drawn. Those in sight are drawn at once, the rest
## nearest first within a time budget per frame, so arriving on another level
## (every known chunk redrawn) or a burst of chunks never stalls a frame.
var _pending := {}
const PAINT_BUDGET_USEC := 6000
## Around the player, in pixels: what a frame shows, also zoomed out.
const SIGHT := Vector2(640, 360)


## Nodes drawn for the chunks of the own location (dev measurements).
func sprite_count() -> int:
	var n := 0
	for holder: Node in _chunk_nodes.values():
		n += holder.get_child_count()
	return n


## Chunks not drawn whole yet (waiting, being drawn, or their last steps).
func pending_chunks() -> int:
	return _pending.size() + _jobs.size() + _after.size()


## The player's chunk changed: chunks come into the drawing radius (painted)
## or leave it (their sprites let go; ground tiles stay, they cost little).
func _keep_near() -> void:
	if not client.has_position:
		return
	var at := Movement.cell_of(client.position)
	var mine := Vector2i(floori(at.x / float(Chunk.SIZE)), floori(at.y / float(Chunk.SIZE)))
	if mine == _drawn_around:
		return
	_drawn_around = mine
	for key: String in _chunk_nodes.keys():
		if not _near(key, DRAW_RADIUS + 1):
			(_chunk_nodes[key] as Node).queue_free()
			_chunk_nodes.erase(key)
			_cell_sprites.erase(key)
			_jobs.erase(key)
	for key: String in client.chunks:
		if _near(key, DRAW_RADIUS) and not _chunk_nodes.has(key) and key.begins_with(client.location + "|"):
			_pending[key] = true


func _near(key: String, radius: int) -> bool:
	if _drawn_around.x == 1 << 30:
		return true
	var p := key.split("|")
	return absi(int(p[1]) - _drawn_around.x) <= radius and absi(int(p[2]) - _drawn_around.y) <= radius


func _paint_pending() -> void:
	if _pending.is_empty():
		_paint_jobs()
		return
	var me := Vector2(client.position) / UNITS_PER_PIXEL if client.has_position else Vector2.ZERO
	var sight := Rect2(me - SIGHT / 2, SIGHT)
	var span := float(Chunk.SIZE * CELL)
	var keys := _pending.keys()
	var dist := {}
	for key: String in keys:
		var p := key.split("|")
		var r := Rect2(int(p[1]) * span, int(p[2]) * span, span, span)
		# Own location first, then by distance; in sight means now.
		dist[key] = -1.0 if r.intersects(sight) else r.get_center().distance_to(me) + (0.0 if p[0] == client.location else 1e6)
	keys.sort_custom(func(a: String, b: String) -> bool: return dist[a] < dist[b])
	var start := Time.get_ticks_usec()
	for key: String in keys:
		if dist[key] >= 0.0 and Time.get_ticks_usec() - start > PAINT_BUDGET_USEC:
			break
		_pending.erase(key)
		_paint(key, true, dist[key] < 0.0)  # out of sight: a few rows a frame
	_paint_jobs()


## Forgets everything drawn (the client moved to another location).
func _clear() -> void:
	_ground.clear()
	_crops.clear()
	_animated.clear()
	_floor32.clear()
	_cover32.clear()
	_pending.clear()
	for layer: TileMapLayer in _terrain_layers:
		layer.clear()
	_terrain_set.clear()
	_cover.clear()
	_below.clear()
	_below_terrain.clear()
	for key: String in _chunk_nodes:
		(_chunk_nodes[key] as Node).queue_free()
	_chunk_nodes.clear()
	_cell_sprites.clear()
	_jobs.clear()
	_after.clear()
	_rock_tops.clear()
	_drawn_around = Vector2i(1 << 30, 0)
	for cell: Vector2i in _cover_sprites:
		(_cover_sprites[cell] as Node).queue_free()
	_cover_sprites.clear()
	_hidden_room.clear()
	_room_from = Vector2i(1 << 30, 0)


func own_pixel_position(alpha: float) -> Vector2:
	var a := Vector2(client.previous_position) / UNITS_PER_PIXEL
	var b := Vector2(client.position) / UNITS_PER_PIXEL
	return a.lerp(b, alpha)


## Chunks being drawn a few rows a frame (out of sight): key -> PaintContext.
var _jobs := {}
## What is left to do for chunks drawn whole (ground edges, the sides of the
## chunks around), a step at a time within the budget.
var _after: Array[Callable] = []
const JOB_BUDGET_USEC := 3000


## Draws a chunk: at once (`now`), or a few rows a frame (_paint_pending).
func _paint(key: String, spread := true, now := true) -> void:
	var p := key.split("|")
	if not client.chunks.has(key):
		return
	var c: Chunk = client.chunks[key]
	if p[0] != client.location:
		if p[0] == Levels.SURFACE:
			_paint_below(c, int(p[1]) * Chunk.SIZE, int(p[2]) * Chunk.SIZE)
		return
	if not _near(key, DRAW_RADIUS):
		var old: Node = _chunk_nodes.get(key)
		if old:
			old.queue_free()
			_chunk_nodes.erase(key)
			_cell_sprites.erase(key)
		_jobs.erase(key)
		return  # drawn when the player comes near (_keep_near)
	var holder: Node2D = _chunk_nodes.get(key)
	if holder:
		holder.queue_free()
	holder = Node2D.new()
	holder.y_sort_enabled = true
	_sorted.add_child(holder)
	_chunk_nodes[key] = holder
	_cell_sprites[key] = {}
	var ctx := _context(key, c)
	ctx.spread = spread
	_jobs.erase(key)
	if not now:
		_jobs[key] = ctx
		return
	for ly in Chunk.SIZE:
		for lx in Chunk.SIZE:
			_paint_cell(ctx, lx, ly)
	for step in _finish(ctx):
		step.call()


## Rows of the chunks being drawn, and steps after them, within the frame's budget.
func _paint_jobs() -> void:
	var start := Time.get_ticks_usec()
	while not _after.is_empty():
		_after.pop_front().call()
		if Time.get_ticks_usec() - start > JOB_BUDGET_USEC:
			return
	for key: String in _jobs.keys():
		var ctx: PaintContext = _jobs[key]
		while ctx.row < Chunk.SIZE:
			for lx in Chunk.SIZE:
				_paint_cell(ctx, lx, ctx.row)
			ctx.row += 1
			if Time.get_ticks_usec() - start > JOB_BUDGET_USEC:
				return
		_jobs.erase(key)
		_after.append_array(_finish(ctx))
		if Time.get_ticks_usec() - start > JOB_BUDGET_USEC:
			return


## What is left once a chunk is drawn whole, as steps: its ground edges, and
## the side of each chunk around that faces it.
func _finish(ctx: PaintContext) -> Array[Callable]:
	var p := ctx.key.split("|")
	var steps: Array[Callable] = []
	# Its terrain, corners on its rim too (shared with the chunks around).
	if not _terrain_layers.is_empty():
		steps.append(func() -> void:
			if p[0] == client.location:
				_paint_terrain(p[0], ctx.ox, ctx.oy, Chunk.SIZE, Chunk.SIZE))
	if ctx.spread:
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nk := ServerWorld.chunk_key(p[0], int(p[1]) + d.x, int(p[2]) + d.y)
			steps.append(func() -> void: _border(nk, d))
	return steps


## The side of a drawn chunk facing a chunk drawn now (-d from it): only that
## row or column depends on its neighbour (joins, rock deep in the mass).
func _border(nk: String, d: Vector2i) -> void:
	if not (_chunk_nodes.has(nk) and client.chunks.has(nk)):
		return
	var nctx := _context(nk, client.chunks[nk])
	var done := Chunk.SIZE
	if _jobs.has(nk):
		# Still being drawn: it goes on with what is known now, and
		# only its rows drawn so far are drawn again.
		var job: PaintContext = _jobs[nk]
		nctx.row = job.row
		nctx.spread = job.spread
		_jobs[nk] = nctx
		done = job.row
	for i in Chunk.SIZE:
		var lx := (Chunk.SIZE - 1 if d.x < 0 else 0) if d.x != 0 else i
		var ly := (Chunk.SIZE - 1 if d.y < 0 else 0) if d.y != 0 else i
		if ly >= done:
			continue
		_clear_cell(nctx, lx, ly)
		_paint_cell(nctx, lx, ly)


## What painting a chunk's cells needs, read once: its layers as ids, and the
## join groups of its parts with a rim of one cell from the chunks around.
class PaintContext:
	var key := ""
	var location := ""
	var ox := 0
	var oy := 0
	var chunk: Chunk
	var holder: Node2D
	var by_cell: Dictionary
	## The chunk's palette and its layers' cells as indices into it (empty: a
	## layer it has nothing on) — read in place, not turned into ids.
	var palette: PackedStringArray
	var ground: PackedInt32Array
	var structure: PackedInt32Array
	var cover: PackedInt32Array
	var roof: PackedInt32Array
	var ceiling: PackedInt32Array

	func at(cells: PackedInt32Array, i: int) -> String:
		return palette[cells[i]] if not cells.is_empty() else ""
	## The structure layers of the chunk and the eight around it (index
	## (dy + 1) * 3 + dx + 1), and their palettes' join group codes.
	var near_cells: Array[PackedInt32Array] = []
	var near_codes: Array[PackedInt32Array] = []
	var row := 0
	var spread := true

	## The join group code (0: none) of the part on a cell, -1..SIZE around.
	func group(lx: int, ly: int) -> int:
		var dx := -1 if lx < 0 else (1 if lx >= Chunk.SIZE else 0)
		var dy := -1 if ly < 0 else (1 if ly >= Chunk.SIZE else 0)
		var k := (dy + 1) * 3 + dx + 1
		var cells := near_cells[k]
		if cells.is_empty():
			return 0
		return near_codes[k][cells[(ly - dy * Chunk.SIZE) * Chunk.SIZE + lx - dx * Chunk.SIZE]]


var _group_codes := {"": 0}


func _group_of(id: String) -> int:
	if id == "":
		return 0
	var g := String(content.visual_of(id).get("autotile", ""))
	if g == "":
		return 0
	return _group_codes.get_or_add(g, _group_codes.size())


func _context(key: String, c: Chunk) -> PaintContext:
	var p := key.split("|")
	var ctx := PaintContext.new()
	ctx.key = key
	ctx.location = p[0]
	ctx.ox = int(p[1]) * Chunk.SIZE
	ctx.oy = int(p[2]) * Chunk.SIZE
	ctx.chunk = c
	ctx.holder = _chunk_nodes[key]
	ctx.by_cell = _cell_sprites[key]
	ctx.palette = c.palette
	ctx.ground = c.layers.get("ground", PackedInt32Array())
	ctx.structure = c.layers.get("structure", PackedInt32Array())
	ctx.cover = c.layers.get("cover", PackedInt32Array())
	ctx.roof = c.layers.get("roof", PackedInt32Array())
	ctx.ceiling = c.layers.get("ceiling", PackedInt32Array())
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var n: Chunk = c if dx == 0 and dy == 0 else client.chunks.get(ServerWorld.chunk_key(p[0], int(p[1]) + dx, int(p[2]) + dy))
			var cells: PackedInt32Array = n.layers.get("structure", PackedInt32Array()) if n else PackedInt32Array()
			var codes := PackedInt32Array()
			if not cells.is_empty():
				for id in n.palette:
					codes.append(_group_of(id))
			ctx.near_cells.append(cells)
			ctx.near_codes.append(codes)
	return ctx


## Lets go of what was drawn for a cell (to draw it again).
func _clear_cell(ctx: PaintContext, lx: int, ly: int) -> void:
	var cell := Vector2i(ctx.ox + lx, ctx.oy + ly)
	for n: Node in ctx.by_cell.get(cell, []):
		if is_instance_valid(n):
			n.queue_free()
	ctx.by_cell.erase(cell)


func _paint_cell(ctx: PaintContext, lx: int, ly: int) -> void:
	var i := ly * Chunk.SIZE + lx
	var cell := Vector2i(ctx.ox + lx, ctx.oy + ly)
	var ground := ctx.at(ctx.ground, i)
	_set_flat(_ground, cell, "" if _terrain.has(ground) else ground)  # terrain: _paint_terrain
	_cover.erase_cell(cell)
	var roof := ctx.at(ctx.roof, i)
	var ceiling := ctx.at(ctx.ceiling, i)
	if roof != "" or ceiling != "" or _cover_sprites.has(cell):
		_set_cover(cell, roof if roof != "" else ceiling, "roof" if roof != "" else "ceiling")
	_rock_tops.erase_cell(cell)
	var c := ctx.chunk
	for layer in ["cover", "structure"]:
		var id := ctx.at(ctx.cover, i) if layer == "cover" else ctx.at(ctx.structure, i)
		if layer == "cover" and id != "" and _wintry and ctx.location == Levels.SURFACE:
			id = String(content.get_def(id).get("winter", id))  # small green things are under the snow
		if id == "":
			continue
		var v := content.visual_of(id)
		if v.get("mode") == "tall":
			var own := ctx.group(lx, ly) if layer == "structure" else 0
			var variant := 0
			var north := 0
			if own != 0:
				north = ctx.group(lx, ly - 1)
				variant = (1 if north == own else 0) | (2 if ctx.group(lx + 1, ly) == own else 0) \
					| (4 if ctx.group(lx, ly + 1) == own else 0) | (8 if ctx.group(lx - 1, ly) == own else 0)
			if layer == "structure" and own != 0 and own == _group_codes.get("rock", -1) and _rock_top_tiles.has(id):
				# Cave rock is drawn in its own cell, flat (its face too, where a
				# passage is south): it never stands over a passage — a tile.
				var t: Array = _rock_top_tiles[id]
				_rock_tops.set_cell(cell, t[0], (t[1] as Vector2i) + Vector2i(variant, 0))
				continue
			var props := c.get_props(lx, ly)
			var state := "open" if props.get("open", false) else ""
			var planted: Variant = (props.get("cover", {}) as Dictionary).get("planted") if layer == "cover" else null
			var crop := content.get_def(id) if planted != null else {}
			if planted != null and crop.has("crop"):
				state = "stage_%d" % Crops.stage(crop, float(planted), client.world_time, _crop_weather(), cell, client.climate_at(cell))
			var s := _tall_sprite(v, cell, state, variant, String(props.get("facing", "")))
			if planted != null and crop.has("crop"):
				_crops[cell] = [s, v, crop, float(planted)]
			if v.has("frames"):  # each one out of step with the others, the same for every player
				_animated.append([s, s.region_rect.position.x, int(v["frames"]), int(v.get("frame_ms", 150)),
					absi((cell.x * 73856093) ^ (cell.y * 19349663)) % 97])
			s.set_meta("cell", cell)
			s.set_meta("layer", layer)
			s.set_meta("id", id)
			var damage := int(props.get("damage", 0)) if layer == "structure" else 0
			if damage > 0:  # worn: darker as it nears breaking (ADR-0021)
				var ratio := clampf(float(damage) / maxf(1.0, float(content.get_def(id).get("durability", 1))), 0.0, 1.0)
				s.self_modulate = Color.WHITE.lerp(Color(0.5, 0.45, 0.45), ratio)
			var work := int((props.get(layer, {}) as Dictionary).get("work", 0)) if layer != "structure" else 0
			if work > 0:  # being felled: paler as it nears falling
				var of := maxf(1.0, float(content.get_def(id).get("gather", {}).get("work", 1)))
				s.self_modulate = Color.WHITE.lerp(Color(0.75, 0.62, 0.5), clampf(work / of, 0.0, 1.0))
			_add(ctx, cell, s)
			if own != 0 and own == _group_codes.get("wall", -1):
				# Walls, doors (shut or open) and windows: their faces are drawn
				# above their cells — lit, never shadowed by their neighbours' feet.
				s.light_mask = LIT_UNSHADOWED
				if String(content.get_def(id).get("role", "")) in STOPS_LIGHT and state != "open":
					_add(ctx, cell, _occluder_at(cell))
			elif layer == "cover" and _outdoors_unshadowed:
				s.light_mask = LIT_UNSHADOWED
			var light: Dictionary = content.get_def(id).get("light", {})
			if not light.is_empty():
				var l := _light_for(light, cell)
				_add(ctx, cell, l)
			var fx: Dictionary = content.get_def(id).get("effects", {})
			for kind: String in fx:
				var e := Effects.of(kind)
				if e:
					e.position = Vector2((cell.x + 0.5) * CELL, (cell.y + 1) * CELL) + Vector2(fx[kind][0], fx[kind][1])
					_add(ctx, cell, e)
		else:
			_set_flat(_cover, cell, id)  # flat, or the missing-picture mark
	if c.props.has(i):
		if c.get_props(lx, ly).get("stairs_down", false):
			var mark := _stairs_down_sprite(cell)
			if mark:
				_add(ctx, cell, mark)
	if client.z > 0 and ground == "":
		_drop_rims(ctx, cell)


func _add(ctx: PaintContext, cell: Vector2i, n: Node2D) -> void:
	ctx.holder.add_child(n)
	(ctx.by_cell.get_or_add(cell, []) as Array).append(n)


## The surface under a building level: ground and flat plants, dimmed.
func _paint_below(c: Chunk, ox: int, oy: int) -> void:
	for ly in Chunk.SIZE:
		for lx in Chunk.SIZE:
			var cell := Vector2i(ox + lx, oy + ly)
			var ground := c.get_cell("ground", lx, ly)
			if _terrain.has(ground):
				var t: Array = _terrain[ground]
				_below_terrain.set_cell(cell, t[0], Vector2i(15, t[1]))
				_below.erase_cell(cell)
			else:
				_set_flat(_below, cell, ground)


func _set_cover(cell: Vector2i, id: String, layer := "ceiling") -> void:
	var old: Sprite2D = _cover_sprites.get(cell)
	if old:
		old.queue_free()
		_cover_sprites.erase(cell)
	if id == "":
		return
	var v := content.visual_of(id)
	var s := Sprite2D.new()
	s.light_mask = LIT_UNSHADOWED  # over a wall's foot: lit, not shadowed by it
	s.centered = false
	if v.is_empty():
		s.texture = _tile_texture(_missing_source)
	else:
		s.texture = texture(v["atlas_path"])
		s.region_enabled = true
		s.scale = Vector2.ONE * float(v.get("pixel_scale", 1.0))
		var piece := _grid_piece(cell, v["grid_size"]) * int(v["rect"][2]) if v.has("grid_size") else Vector2i.ZERO
		s.region_rect = Rect2(v["rect"][0] + piece.x, v["rect"][1] + piece.y, v["rect"][2], v["rect"][3])
	s.position = Vector2(cell.x * CELL, cell.y * CELL - COVER_LIFT)
	# Its shadow on the floor along its south edge, under the covers (the
	# next cover south hides it), so an overhang reads as one.
	var shade := ColorRect.new()
	shade.color = Color(0.08, 0.05, 0.04, 0.38)
	shade.size = Vector2(CELL, 4) / s.scale
	shade.position = Vector2(0, COVER_LIFT) / s.scale
	shade.z_index = -1
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(shade)
	s.visible = not _hidden_room.has(cell)
	s.set_meta("layer", layer)
	s.set_meta("id", id)
	_covers.add_child(s)
	_cover_sprites[cell] = s
	_room_from = Vector2i(1 << 30, 0)  # covers changed: find the room again


## Hides the covers of the room the player stands in: every covered cell
## reachable from the player's cell through covered cells.
func _update_room() -> void:
	if not client.has_position:
		return
	var me := Movement.cell_of(client.position)
	if me == _room_from:
		return
	_room_from = me
	var room := {}
	if _cover_sprites.has(me):
		var todo: Array[Vector2i] = [me]
		room[me] = true
		while not todo.is_empty() and room.size() < MAX_ROOM:
			var c: Vector2i = todo.pop_back()
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n := c + d
				if _cover_sprites.has(n) and not room.has(n):
					room[n] = true
					todo.append(n)
	for cell: Vector2i in _hidden_room:
		if _cover_sprites.has(cell) and not room.has(cell):
			(_cover_sprites[cell] as Sprite2D).visible = true
	for cell: Vector2i in room:
		(_cover_sprites[cell] as Sprite2D).visible = false
	_hidden_room = room


func _set_flat(layer: TileMapLayer, cell: Vector2i, id: String) -> void:
	# The same layer's twin for LPC tiles (32 px): what is drawn is on one of the two.
	var twin: TileMapLayer = {_ground: _floor32, _cover: _cover32, _below: _below_terrain}.get(layer)
	if twin and id != "" and _tiles.has(id) and _tiles[id][5]:
		layer.erase_cell(cell)
		layer = twin
	elif twin and twin != _below_terrain:
		twin.erase_cell(cell)
	if id == "":
		layer.erase_cell(cell)
		return
	var t: Array = _tiles.get(id, [])
	if t.is_empty():
		layer.set_cell(cell, _missing_source, Vector2i.ZERO)
		return
	if t[3]:
		# A seamless texture over a grid of tiles: each cell takes its piece.
		layer.set_cell(cell, t[0], t[1] + _grid_piece(cell, t[4]))
		return
	var variant := (cell.x * 73856093 ^ cell.y * 19349663) & 0x7fffffff
	layer.set_cell(cell, t[0], t[1] + Vector2i(variant % t[2], 0))


func _grid_piece(cell: Vector2i, grid: Vector2i) -> Vector2i:
	return Vector2i(posmod(cell.x, grid.x), posmod(cell.y, grid.y))


## A tall thing's sprite: its state's picture (an open door), else its
## facing's (ADR-0013; "mirror" draws a facing as another one flipped), else
## its own (or an alternate, picked by the cell).
func _tall_sprite(v: Dictionary, cell: Vector2i, state := "", variant := 0, facing := "") -> Sprite2D:
	var season: String = SEASON_KEYS[_season_drawn] if _season_drawn >= 0 else ""
	if v.has("seasons") and (v["seasons"] as Dictionary).has(season):  # a tree through the year
		v = v.merged(v["seasons"][season], true)
	var alts: Array = v.get("alternates", [])
	if not alts.is_empty() and state == "" and variant == 0:
		# The same picture for a cell every time and for every player.
		var k := absi((cell.x * 73856093) ^ (cell.y * 19349663)) % (alts.size() + 1)
		if k > 0:
			v = v.merged(alts[k - 1], true)  # its own picture, the visual's scale
	var s := Sprite2D.new()
	s.texture = texture(v["atlas_path"])
	s.region_enabled = true
	var flip := false
	var turned := facing
	if v.get("mirror", {}).has(facing):
		turned = String(v["mirror"][facing])
		flip = true
	var r: Array = v.get("states", {}).get(state, v.get("rotations", {}).get(turned, v["rect"]))
	s.region_rect = Rect2(r[0] + variant * r[2], r[1], r[2], r[3])
	s.flip_h = flip
	s.centered = false
	s.scale = Vector2.ONE * float(v.get("pixel_scale", 1.0))  # LPC sheets: a texel is half a world pixel
	# The sprite's origin pixel sits on the cell's bottom-left corner; that corner sorts it.
	s.position = Vector2(cell.x * CELL, (cell.y + 1) * CELL)
	s.offset = -Vector2(v["origin"][0], v["origin"][1])
	return s


## Tall things standing on cells within `left`..`right` columns and `up`..
## `down` rows of `around` (drawn chunks only).
func _sprites_near(around: Vector2i, left: int, right: int, up: int, down: int) -> Array:
	var out := []
	for y in range(around.y - up, around.y + down + 1):
		for x in range(around.x - left, around.x + right + 1):
			var key := ServerWorld.chunk_key(client.location, floori(x / float(Chunk.SIZE)), floori(y / float(Chunk.SIZE)))
			var by_cell: Dictionary = _cell_sprites.get(key, {})
			for n: Node in by_cell.get(Vector2i(x, y), []):
				if n is Sprite2D:
					out.append(n)
	return out


func _cell_part(location: String, cell: Vector2i) -> String:
	var cx := floori(cell.x / float(Chunk.SIZE))
	var cy := floori(cell.y / float(Chunk.SIZE))
	var c: Chunk = client.chunks.get(ServerWorld.chunk_key(location, cx, cy))
	return c.get_cell("structure", cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE) if c else ""


## On a building level a cell without floor is a drop — an opening, or the
## level's edge: its sides along the floor are shaded, so an opening reads as
## a hole one may jump down through (ADR-0007), not as more floor.
const RIM := 4


func _drop_rims(ctx: PaintContext, cell: Vector2i) -> void:
	for d: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		if ground_at(client.location, cell + d) == "":
			continue
		var r := ColorRect.new()
		r.color = Color(0.05, 0.04, 0.06, 0.6)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		r.size = Vector2(CELL if d.x == 0 else RIM, RIM if d.x == 0 else CELL)
		r.position = Vector2(cell * CELL) + Vector2(CELL - RIM if d.x > 0 else 0, CELL - RIM if d.y > 0 else 0)
		r.z_as_relative = false
		r.z_index = -1
		ctx.holder.add_child(r)
		(ctx.by_cell.get_or_add(cell, []) as Array).append(r)


## On a building level, where the stairs from below come up: the way down.
func _stairs_down_sprite(cell: Vector2i) -> Sprite2D:
	for id: String in content.visuals:
		var v: Dictionary = content.visuals[id]
		if content.get_def(id).get("role") == "stairs" and v.get("states", {}).has("down"):
			var s := _tall_sprite(v, cell, "down")
			s.z_index = -1
			return s
	return null


## Tall things drawn in front of the player's character fade, so the player
## is never lost behind a wall, a tree or a roof (houses, fortresses).
func _fade_occluders() -> void:
	if not client.has_position or not _characters.has(client.character_id):
		return
	var me: Node2D = _characters[client.character_id]
	var body := Rect2(me.position + BODY_SEEN.position, BODY_SEEN.size)
	for s: Sprite2D in _faded:
		if is_instance_valid(s) and s.material == _see_through:
			s.material = null
	_faded.clear()
	if client.own.get("asleep", false):
		return  # in bed one is drawn over it: nothing hides one to see through
	if _see_through.shader == null:
		_see_through.shader = load("res://src/presentation/see_through.gdshader")
	_see_through.set_shader_parameter("hole", body.get_center())
	# What stands in front (south) of the player and covers the drawn body.
	var at := Vector2i(floori(me.position.x / CELL), floori((me.position.y - 1) / CELL))
	for s: Sprite2D in _sprites_near(at, 4, 4, 0, 6):
		if is_instance_valid(s) and s.material == null and s.position.y > me.position.y and _sprite_rect(s).intersects(body):
			s.material = _see_through
			_faded.append(s)
	for cell: Vector2i in _cover_sprites:
		var cs: Sprite2D = _cover_sprites[cell]
		if cs.visible and cs.material == null and (cell.y + 1) * CELL > me.position.y and _sprite_rect(cs).intersects(body):
			cs.material = _see_through
			_faded.append(cs)


func _sprite_rect(s: Sprite2D) -> Rect2:
	return Rect2(s.position + s.offset * s.scale, s.region_rect.size * s.scale)


## What the player points at: a visible cover, else a tall thing whose
## picture is under the point, else the cell under it. [cell, layer hint]
## What is under a point of the screen (ADR-0021), nearest the eye first:
##   {"kind": "entity", "id", "entity": its state} — a person, a creature, a thing;
##   {"kind": "part", "layer", "id", "cell"} — a part, a plant, a roof or ceiling;
##   {"kind": "ground", "id", "cell"} — the ground.
## Always with "location" (the client's own).
func pick_target(point: Vector2) -> Dictionary:
	var best := {}
	var best_y := -INF
	for id: String in _characters:
		var s: CharacterSprite = _characters[id]
		if Rect2(s.position + Vector2(-9, -30), Vector2(18, 32)).has_point(point) and s.position.y > best_y \
				and (id == client.character_id or client.entities.has(id)):
			best = {"kind": "entity", "id": id, "entity": client.own if id == client.character_id else client.entities[id]}
			best_y = s.position.y
	for id: String in _items:
		var it: Sprite2D = _items[id]
		if Rect2(it.position - Vector2(8, 12), Vector2(16, 16)).has_point(point) and it.position.y > best_y \
				and client.entities.has(id):
			best = {"kind": "entity", "id": id, "entity": client.entities[id]}
			best_y = it.position.y
	if not best.is_empty() and best["id"] != client.character_id:
		best["location"] = client.location
		return best
	for cell: Vector2i in _cover_sprites:
		var cs: Sprite2D = _cover_sprites[cell]
		if cs.visible and _sprite_rect(cs).has_point(point):
			return {"kind": "part", "layer": cs.get_meta("layer"), "id": cs.get_meta("id"), "cell": cell,
				"location": client.location}
	best_y = -INF
	var under := Vector2i(floori(point.x / CELL), floori(point.y / CELL))
	for s: Sprite2D in _sprites_near(under, 4, 4, 0, 6):
		if is_instance_valid(s) and s.has_meta("layer") and s.position.y > best_y and _sprite_rect(s).has_point(point):
			best = {"kind": "part", "layer": s.get_meta("layer"), "id": s.get_meta("id"), "cell": s.get_meta("cell"),
				"location": client.location}
			var at_cell := props_at(s.get_meta("cell"))
			var worn: Dictionary = at_cell if s.get_meta("layer") == "structure" else at_cell.get(s.get_meta("layer"), {})
			var damage := int(worn.get("damage", 0))
			if damage > 0:
				best["damage"] = damage
			if int(worn.get("work", 0)) > 0:
				best["work"] = int(worn["work"])
			best_y = s.position.y
	if not best.is_empty():
		return best
	var cell := under
	if _rock_tops.get_cell_source_id(cell) != -1:  # cave rock, drawn as a tile in its own cell
		return part_target(cell)
	var flat := _cell_layer(cell, "cover")
	if flat != "":
		return {"kind": "part", "layer": "cover", "id": flat, "cell": cell, "location": client.location}
	return {"kind": "ground", "id": ground_at(client.location, cell), "cell": cell, "location": client.location}


## The solid thing on a cell as a target: its part, else its plant (a tree).
func part_target(cell: Vector2i) -> Dictionary:
	var layer := "structure" if _cell_layer(cell, "structure") != "" else "cover"
	var out := {"kind": "part", "layer": layer, "id": _cell_layer(cell, layer), "cell": cell, "location": client.location}
	var at_cell := props_at(cell)
	var worn: Dictionary = at_cell if layer == "structure" else at_cell.get(layer, {})
	if int(worn.get("damage", 0)) > 0:
		out["damage"] = int(worn["damage"])
	if int(worn.get("work", 0)) > 0:
		out["work"] = int(worn["work"])
	return out


func _cell_layer(cell: Vector2i, layer: String) -> String:
	var cx := floori(cell.x / float(Chunk.SIZE))
	var cy := floori(cell.y / float(Chunk.SIZE))
	var c: Chunk = client.chunks.get(ServerWorld.chunk_key(client.location, cx, cy))
	return c.get_cell(layer, cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE) if c else ""


## The props of a cell of the client's location ({} if unknown).
func props_at(cell: Vector2i) -> Dictionary:
	var cx := floori(cell.x / float(Chunk.SIZE))
	var cy := floori(cell.y / float(Chunk.SIZE))
	var c: Chunk = client.chunks.get(ServerWorld.chunk_key(client.location, cx, cy))
	return c.get_props(cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE) if c else {}


func pick(point: Vector2) -> Vector2i:
	for cell: Vector2i in _cover_sprites:
		var cs: Sprite2D = _cover_sprites[cell]
		if cs.visible and _sprite_rect(cs).has_point(point):
			return cell
	var best := Vector2i(floori(point.x / CELL), floori(point.y / CELL))
	var best_y := -INF
	for s: Sprite2D in _sprites_near(best, 4, 4, 0, 6):
		if is_instance_valid(s) and s.has_meta("cell") and s.position.y > best_y and _sprite_rect(s).has_point(point):
			best = s.get_meta("cell")
			best_y = s.position.y
	return best


func _update_characters(alpha: float, delta: float) -> void:
	var seen := {}
	if client.has_position:
		seen[client.character_id] = true
		var me := _character(client.character_id, client.own.get("appearance", {}))
		me.submerged = client.in_water(client.position) or client.aboard() != ""  # swimming (ADR-0050), in a boat (ADR-0052)
		me.show_at(own_pixel_position(alpha), delta, true)
		me.modulate = Color.WHITE
		_health(client.character_id, me, client.own, delta)
		var in_hands := "" if me.submerged else own_held
		me.hold(item_picture(in_hands), item_grip(in_hands), in_hands)
		_held_light(me, own_held)
		_lie(me, bool(client.own.get("asleep", false)))
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") == "item":
			seen[id] = true
			if content.get_def(String(e.get("item", ""))).has("vessel"):
				_at_level(_boat(id, e, delta), int(e.get("z", client.z)))
			else:
				_at_level(_item(id, e), int(e.get("z", client.z)))
			continue
		if e.get("kind") == "projectile":
			seen[id] = true
			_projectile(id, e, delta)
			continue
		var kind := String(e.get("kind", ""))
		if kind != "character" and kind != "creature":
			continue
		seen[id] = true
		var target := Vector2(int(e.get("x", 0)), int(e.get("y", 0))) / UNITS_PER_PIXEL
		# An NPC with looks is a paper doll like a character; an animal is
		# drawn from its own sheet (its creature's visual).
		var looks: Dictionary = e.get("appearance", {})
		if kind == "creature" and looks.is_empty():
			looks = {"body_plan": String(e.get("creature", ""))}
		# Seen on another level (ADR-0015): one on a walkway stands on the
		# ceiling's picture, lifted as covers are; the street seen from upstairs
		# lies dimmed under the floor, as the surface there does.
		var dz := int(e.get("z", client.z)) - client.z
		var sprite := _character(id, looks)
		sprite.submerged = kind == "character" and dz == 0 and (client.in_water(Vector2i(int(e.get("x", 0)), int(e.get("y", 0))))
			or String(e.get("aboard", "")) != "")
		var held := "" if sprite.submerged else String(e.get("held", ""))
		sprite.hold(item_picture(held), item_grip(held), held)
		_held_light(sprite, held)
		var blows := int(e.get("swing", 0))
		if _swing_seen.has(id) and int(_swing_seen[id]) != blows:
			sprite.swing(Vector2.RIGHT.rotated((blows & 7) * PI / 4), swing_kind(String(e.get("held", ""))))
		_swing_seen[id] = blows
		sprite.scale = Vector2.ONE
		sprite.show_at(target - Vector2(0, COVER_LIFT * maxi(dz, 0)), delta, false)
		sprite.scale *= 0.6 if e.get("young", false) else 1.0
		_at_level(sprite, client.z + dz)
		_health(id, sprite, e, delta)
		_lie(sprite, bool(e.get("asleep", false)))
		_speech(id, sprite, e, delta)
	for id: String in _characters.keys():
		if not seen.has(id):
			_characters[id].queue_free()
			_characters.erase(id)
	for id: String in _items.keys():
		if not seen.has(id):
			_items[id].queue_free()
			_items.erase(id)
	for id: String in _projectiles.keys():
		if not seen.has(id):
			_projectiles[id].queue_free()
			_projectiles.erase(id)
	for id: String in _swing_seen.keys():
		if not seen.has(id):
			_swing_seen.erase(id)
	for id: String in _hp_seen.keys():
		if not seen.has(id):
			_hp_seen.erase(id)
			_flash.erase(id)
	for id: String in _said_seen.keys():
		if not seen.has(id):
			_said_seen.erase(id)


## Words a dweller said (ADR-0039), last seen count by id; its bubble.
var _said_seen := {}
const SPEECH_S := 4.0


## A bubble over one who has just said something, for a few seconds.
func _speech(id: String, sprite: Node2D, e: Dictionary, delta: float) -> void:
	if not e.has("said"):
		return
	var said := int(e["said"])
	var bubble: Label = sprite.get_node_or_null("Speech")
	var first := not _said_seen.has(id)  # words said before it came into view are not shown
	var fresh := not first and int(_said_seen[id]) != said
	_said_seen[id] = said
	if fresh:
		if bubble == null:
			bubble = Label.new()
			bubble.name = "Speech"
			_world_text(bubble, Color(0.1, 0.08, 0.06))
			var box := StyleBoxFlat.new()
			box.bg_color = Color(0.97, 0.94, 0.86, 0.94)
			box.set_corner_radius_all(4)
			box.content_margin_left = 6
			box.content_margin_right = 6
			box.content_margin_top = 2
			box.content_margin_bottom = 2
			bubble.add_theme_stylebox_override("normal", box)
			bubble.z_index = 20
			sprite.add_child(bubble)
		bubble.text = String(e.get("say", ""))
		# A long saying wraps (in the label's own pixels, twice the world's).
		var wide := Art.font().get_string_size(bubble.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wide > SPEECH_WIDTH else TextServer.AUTOWRAP_OFF
		bubble.custom_minimum_size = Vector2.ZERO
		bubble.size = Vector2(minf(wide, SPEECH_WIDTH) + 12.0, 0.0)  # its margins round the words
		# As many lines as the words take at that width, no more.
		bubble.size.y = bubble.get_line_count() * bubble.get_line_height() + 4.0
		bubble.position = Vector2(-bubble.size.x * bubble.scale.x / 2.0, -38.0 - bubble.size.y * bubble.scale.y)
		bubble.set_meta("left", SPEECH_S)
	if bubble:
		var left := float(bubble.get_meta("left", 0.0)) - delta
		bubble.set_meta("left", left)
		if left <= 0.0:
			bubble.queue_free()


## Asleep in a bed (ADR-0035), seen from above as such games show it: the
## head on the pillow, facing up, the bed's own blanket over the body (the
## lower part of the bed's picture, drawn over the sleeper); up on waking.
const BLANKET_FROM := 28  # texels of the bed picture above the blanket: the pillows
const LIE_UP := -3.0  # the feet this far above the middle of the bed's cell


func _lie(sprite: CharacterSprite, asleep: bool) -> void:
	var blanket: Sprite2D = sprite.get_node_or_null("Blanket")
	if not asleep:
		sprite.z_index = 0
		if blanket:
			blanket.queue_free()
		return
	var cell := Vector2i(floori(sprite.position.x / CELL), floori(sprite.position.y / CELL))
	var v := content.visual_of(_cell_part(client.location, cell))
	sprite.turn_to(Vector2.DOWN)
	sprite.position = Vector2((cell.x + 0.5) * CELL, (cell.y + 0.5) * CELL + LIE_UP)
	sprite.z_index = 1  # over the bed, under nothing else of its row
	if v.is_empty():
		return
	if blanket == null:
		blanket = Sprite2D.new()
		blanket.name = "Blanket"
		blanket.centered = false
		blanket.region_enabled = true
		blanket.z_index = 2
		blanket.texture = texture(v["atlas_path"])
		var r: Array = v["rect"]
		blanket.region_rect = Rect2(r[0], r[1] + BLANKET_FROM, r[2], r[3] - BLANKET_FROM)
		blanket.scale = Vector2.ONE * float(v.get("pixel_scale", 1.0))
		sprite.add_child(blanket)
	# Where the bed's picture is (as _tall_sprite places it), from the sleeper.
	var scale := float(v.get("pixel_scale", 1.0))
	var bed_at := Vector2(cell.x * CELL, (cell.y + 1) * CELL) - Vector2(v["origin"][0], v["origin"][1]) * scale
	blanket.position = bed_at + Vector2(0, BLANKET_FROM * scale) - sprite.position


## Blows last seen struck, by id (a change: a swing to show).
var _swing_seen := {}


## The weather crops here grow under (ADR-0033): the sky's, or none below.
## Whether it freezes where we are now (winter drawn: snow, a colder light).
func _freezing_here() -> bool:
	return Seasons.freezing(client.world_time, client.climate().x)


func _crop_weather() -> int:
	return client.weather_seed if client.z >= 0 else -1


## How a blow with a thing looks (CharacterSprite.swing).
func swing_kind(held: String) -> String:
	if held != "" and content.get_def(held).has("swing"):
		return String(content.get_def(held)["swing"])  # a tool's own motion (a hoe thrusts)
	var w: Dictionary = content.get_def(held).get("weapon", {}) if held != "" else {}
	if w.get("kind") == "ranged":
		return "draw"
	if w.get("kind") == "melee" and float(w.get("arc", 90)) < 60.0:
		return "thrust"
	return "chop" if held != "" else "lunge"


var _deaths_seen := {}


## The own character plays a clip once (a stoop to pick up).
func react_own(clip: String) -> void:
	var me: CharacterSprite = _characters.get(client.character_id)
	if me:
		me.react(clip)


## The own character strikes toward `dir` at once, before the server answers.
func swing_own(dir: Vector2) -> void:
	var me: CharacterSprite = _characters.get(client.character_id)
	if me:
		me.swing(dir, swing_kind(own_held))


## The own character draws its bow toward `dir` and holds it (loose_own lets go).
func draw_own(dir: Vector2) -> void:
	var me: CharacterSprite = _characters.get(client.character_id)
	if me:
		me.pull_string(dir, swing_kind(own_held))


func loose_own(dir: Vector2) -> void:
	var me: CharacterSprite = _characters.get(client.character_id)
	if me:
		me.loose(dir)


var _items := {}
var _projectiles := {}
## What the own character holds (set by the game at once, before the server knows).
var own_held := ""
var _pictures := {}


## An item's picture (its visual's first frame), cached; null for none.
func item_picture(id: String) -> Texture2D:
	if id == "":
		return null
	if _pictures.has(id):
		return _pictures[id]
	var v := content.visual_of(id)
	var at: AtlasTexture = null
	if not v.is_empty():
		at = AtlasTexture.new()
		at.atlas = texture(v["atlas_path"])
		at.region = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
	_pictures[id] = at
	return at


## The drawn grip in pixels from the item's centre; old visuals use GRIP.
func item_grip(id: String) -> Vector2:
	var visual := content.visual_of(id)
	var grip: Array = visual.get("grip", [])
	if grip.is_empty():
		return CharacterSprite.GRIP
	return Vector2(float(grip[0]) - float(visual["rect"][2]) / 2.0,
		float(grip[1]) - float(visual["rect"][3]) / 2.0)


## Health last drawn, and how much of a hurt flash is left (s), by id.
var _hp_seen := {}
var _flash := {}
const FLASH := 0.25


## An arrow in flight: its item's picture turned along its way, at the
## height it flies, easing to where the server has it.
func _projectile(id: String, e: Dictionary, delta: float) -> void:
	var dz := int(e.get("z", client.z)) - client.z
	var target := Vector2(int(e.get("x", 0)), int(e.get("y", 0))) / UNITS_PER_PIXEL - Vector2(0, 10 + COVER_LIFT * maxi(dz, 0))
	var s: Sprite2D = _projectiles.get(id)
	if s == null:
		var v := content.visual_of(String(e.get("item", "")))
		s = Sprite2D.new()
		if not v.is_empty():
			s.texture = texture(v["atlas_path"])
			s.region_enabled = true
			s.region_rect = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
			s.scale = Vector2.ONE * float(v.get("pixel_scale", 1.0))
		# The picture points up and right; turn it along the flight.
		s.rotation = atan2(float(e.get("vy", 0)), float(e.get("vx", 1))) + PI / 4.0
		s.position = target
		s.z_index = 5
		add_child(s)
		_projectiles[id] = s
	s.position = s.position.lerp(target, minf(1.0, delta * 30.0))
	_at_level(s, client.z + dz)
	if dz == 0:
		s.z_index = 5


## A health bar over one who is hurt, and a red flash when hurt again.
func _health(id: String, sprite: Node2D, e: Dictionary, delta: float) -> void:
	var top := int(e.get("max_health", 0))
	var h := int(e.get("health", top))
	if h < int(_hp_seen.get(id, h)) and sprite is CharacterSprite:
		(sprite as CharacterSprite).react("dead" if h <= 0 else "hurt", 2.0 if h <= 0 else 0.0)
	if int(e.get("deaths", 0)) > int(_deaths_seen.get(id, e.get("deaths", 0))) and sprite is CharacterSprite:
		(sprite as CharacterSprite).react("dead", 2.0)  # fell (ADR-0019): lies a while
	_deaths_seen[id] = int(e.get("deaths", 0))
	if h < int(_hp_seen.get(id, h)):
		_flash[id] = FLASH
		var at := to_local(sprite.global_position) + Vector2(0, -10)
		burst_at(at, "blood")
		popup_at(at + Vector2(0, -14), "−%d" % (int(_hp_seen[id]) - h), Color(1.0, 0.45, 0.4))
	_hp_seen[id] = h
	var bar: Node2D = sprite.get_node_or_null("hp")
	if top > 0 and h < top:
		if bar == null:
			bar = Node2D.new()
			bar.name = "hp"
			bar.position = Vector2(-7, -38)
			var back := ColorRect.new()
			back.size = Vector2(14, 2)
			back.color = Color(0.1, 0.08, 0.08, 0.8)
			var fill := ColorRect.new()
			fill.name = "fill"
			fill.size = Vector2(14, 2)
			fill.color = Color(0.85, 0.25, 0.2)
			bar.add_child(back)
			bar.add_child(fill)
			sprite.add_child(bar)
		(bar.get_node("fill") as ColorRect).size.x = 14.0 * h / top
	elif bar:
		bar.queue_free()
	var f := float(_flash.get(id, 0.0))
	if f > 0.0:
		sprite.modulate = sprite.modulate.lerp(Color(1.0, 0.3, 0.3), f / FLASH)
		_flash[id] = f - delta


## A short burst of something at a point of the world (Effects.burst).
func burst_at(at: Vector2, kind: String, tint := Color.WHITE) -> void:
	var p := Effects.burst(kind, tint)
	if p:
		p.position = at
		add_child(p)


## Words drawn in the world as on the screen: the pixel font at its own size
## (16) on a label half as big, which the camera's zoom brings back to 16 —
## at half size the font's pixels would break and blur.
const SPEECH_WIDTH := 300.0
func _world_text(l: Label, color: Color) -> void:
	l.add_theme_font_override("font", Art.font())
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", color)
	l.scale = Vector2.ONE * 0.5


## A word that floats up from a point and fades (a blow's damage, a find).
func popup_at(at: Vector2, text: String, color := Art.TEXT) -> void:
	var l := Label.new()
	l.text = text
	_world_text(l, color)
	l.add_theme_color_override("font_outline_color", Art.INK)
	l.add_theme_constant_override("outline_size", 4)
	l.z_index = 20
	l.position = at - Vector2(8, 6)
	add_child(l)
	var t := l.create_tween()
	t.set_parallel(true)
	t.tween_property(l, "position:y", l.position.y - 12, 0.9)
	t.tween_property(l, "modulate:a", 0.0, 0.9).set_delay(0.3)
	t.chain().tween_callback(l.queue_free)


## Draws a thing of level z over the covers (above us) or dimmed with the
## surface below (under us), or as usual on our own level.
func _at_level(n: Node2D, z: int) -> void:
	if z > client.z:
		n.z_index = 11
		n.modulate = Color.WHITE
	elif z < client.z:
		n.z_index = -3
		n.modulate = _below.modulate
	else:
		n.z_index = 0
		n.modulate = Color.WHITE


## How big a thing on the ground is drawn, of its picture (a full picture filled a
## whole cell: too big beside the people, the author 27.10.2026).
const GROUND_ITEM_SCALE := 0.6


## A thing on the ground: its picture, standing where it lies.
func _item(id: String, e: Dictionary) -> Sprite2D:
	if _items.has(id):
		return _items[id]
	var v := content.visual_of(String(e.get("item", "")))
	var s := Sprite2D.new()
	if v.is_empty():
		s.texture = _tile_texture(_missing_source)
	else:
		s.texture = texture(v["atlas_path"])
		s.region_enabled = true
		s.region_rect = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
		s.scale = Vector2.ONE * float(v.get("pixel_scale", 1.0)) * GROUND_ITEM_SCALE
	s.position = Vector2(int(e["x"]), int(e["y"])) / UNITS_PER_PIXEL
	s.offset = Vector2(0, -4) / s.scale
	_sorted.add_child(s)
	_items[id] = s
	return s


## A boat (ADR-0052): its hull lying along its course, easing to where the
## server has it; drawn just under its crew.
func _boat(id: String, e: Dictionary, delta: float) -> Sprite2D:
	var target := Vector2(int(e["x"]), int(e["y"])) / UNITS_PER_PIXEL
	var v := content.visual_of(String(e.get("item", "")))
	var s: Sprite2D = _items.get(id)
	if s == null:
		s = Sprite2D.new()
		s.texture = texture(v["atlas_path"]) if not v.is_empty() else _tile_texture(_missing_source)
		s.region_enabled = not v.is_empty()
		s.scale = Vector2.ONE * float(v.get("pixel_scale", 1.0))
		s.position = target - Vector2(0, 1)
		s.set_meta("along", "we")
		_sorted.add_child(s)
		_items[id] = s
	var was := s.position + Vector2(0, 1)
	var to := was.lerp(target, minf(1.0, delta * 15.0))
	var moved := target - was
	if moved.length() > 0.5:
		s.set_meta("along", "we" if absf(moved.x) >= absf(moved.y) else "ns")
	if not v.is_empty():
		var rect: Array = (v.get("states", {}) as Dictionary).get(String(s.get_meta("along")), v["rect"])
		s.region_rect = Rect2(rect[0], rect[1], rect[2], rect[3])
	s.position = to - Vector2(0, 1)  # a pixel above its crew: drawn under them
	s.offset = Vector2(0, 5) / s.scale
	return s


func _tile_texture(source: int) -> Texture2D:
	return (_ground.tile_set.get_source(source) as TileSetAtlasSource).texture


## A character as a paper doll: its body plan's body, then a layer for each
## chosen style and worn thing that has a picture. Rebuilt when looks change.
func _character(id: String, looks: Dictionary) -> CharacterSprite:
	var old: CharacterSprite = _characters.get(id)
	if old and old.look == looks:
		return old
	var v := content.visual_of(String(looks.get("body_plan", "")))
	if v.is_empty():
		v = content.visual_of("base:human_m")
	# A creature keeps the same variant across frames, reloads and clients.
	var alternates: Array = v.get("alternates", [])
	var variant := posmod(id.hash(), alternates.size() + 1)
	if variant > 0:
		v = v.merged(alternates[variant - 1], true)
	if old and Art.same_kind(old, v):
		Art.dress(old, content, v, looks)
		return old
	if old:
		old.queue_free()
	var cs := Art.character_sprite(content, v, looks)
	cs.stepped.connect(func() -> void:
		if on_step.is_valid():
			on_step.call(cs.position))
	_sorted.add_child(cs)
	_characters[id] = cs
	return cs
