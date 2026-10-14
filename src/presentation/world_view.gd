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
## Covers sit on top of the walls: this far above their cell.
const COVER_LIFT := 16
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
## Sprites made see-through because they stand in front of the player.
var _faded: Array[Sprite2D] = []
const FADED := 0.4
var _room_from := Vector2i(1 << 30, 0)
var _sorted := Node2D.new()
## The hour's light over the whole world (ADR-0014), and the lights of the
## light sources drawn now (brighter as it gets dark).
var _tint := CanvasModulate.new()
var _lights: Array[PointLight2D] = []
static var _glow: GradientTexture2D
var _chunk_nodes := {}
var _characters := {}
## visual id -> [source id, first atlas cell Vector2i, variants]
var _tiles := {}
## Grounds that lap over lower neighbours (ART_STANDARD 5): ground id ->
## [source id, first atlas cell, grid, {mask: column}, priority, layer].
var _edges := {}
## Ground id -> priority, for every ground taking part (also the lowest).
var _edge_priority := {}
## Priority -> ground id.
var _by_rank: Array[String] = []
## Cell -> bits of the priorities whose edge is drawn on it.
var _edge_set := {}
## Drawn where the content has no picture (a texture pack may lack one): a
## loud magenta checker, so a gap is noticed rather than hidden.
var _missing_source := -1


func setup(registry: ContentRegistry, game_client: GameClient) -> void:
	content = registry
	client = game_client
	var ts := TileSet.new()
	ts.tile_size = Vector2i(CELL, CELL)
	var sources := {}
	for target: String in content.visuals:
		var v: Dictionary = content.visuals[target]
		if v["mode"] != "flat":
			continue
		var path: String = v["atlas_path"]
		if not sources.has(path):
			var src := TileSetAtlasSource.new()
			src.texture = texture(path)
			src.texture_region_size = Vector2i(CELL, CELL)
			sources[path] = [ts.add_source(src), src]
		var src: TileSetAtlasSource = sources[path][1]
		var first := Vector2i(v["rect"][0] / CELL, v["rect"][1] / CELL)
		var grid: Vector2i = v.get("grid_size", Vector2i(int(v["variants"]), 1))
		for j in grid.y:
			for i in grid.x:
				var at := first + Vector2i(i, j)
				if not src.has_tile(at):
					src.create_tile(at)
		_tiles[target] = [sources[path][0], first, int(v["variants"]), v.has("grid_size"), grid]
	var miss := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
	for y in CELL:
		for x in CELL:
			miss.set_pixel(x, y, Color.MAGENTA if (x / 4 + y / 4) % 2 == 0 else Color.BLACK)
	var ms := TileSetAtlasSource.new()
	ms.texture = ImageTexture.create_from_image(miss)
	ms.texture_region_size = Vector2i(CELL, CELL)
	ms.create_tile(Vector2i.ZERO)
	_missing_source = ts.add_source(ms)
	_setup_edges(ts)
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
	add_child(_ground)
	var lapping := _edges.keys()
	lapping.sort_custom(func(a: String, b: String) -> bool: return _edges[a][4] < _edges[b][4])
	for id: String in lapping:
		add_child(_edges[id][5])  # higher grounds drawn later, over lower ones
	add_child(_cover)
	add_child(_sorted)
	add_child(_covers)


func _setup_edges(ts: TileSet) -> void:
	var sources := {}
	for id: String in content.visuals:
		var e: Dictionary = content.visuals[id].get("edges", {})
		if e.is_empty():
			continue
		_edge_priority[id] = int(e["priority"])
		var path: String = e["atlas_path"]
		if not sources.has(path):
			var src := TileSetAtlasSource.new()
			src.texture = texture(path)
			src.texture_region_size = Vector2i(CELL, CELL)
			sources[path] = [ts.add_source(src), src]
		var src: TileSetAtlasSource = sources[path][1]
		var grid: Vector2i = content.visuals[id].get("grid_size", Vector2i.ONE)
		var masks: Array = e["masks"]
		var first := Vector2i(e["rect"][0] / CELL, e["rect"][1] / CELL)
		for row in grid.x * grid.y:
			for col in masks.size():
				var at := first + Vector2i(col, row)
				if not src.has_tile(at):
					src.create_tile(at)
		var column := {}
		for col in masks.size():
			column[int(masks[col])] = col
		var layer := TileMapLayer.new()
		layer.tile_set = ts
		layer.z_index = -2
		_edges[id] = [sources[path][0], first, grid, column, int(e["priority"]), layer]
	# Priorities become ranks 0..n-1, so they index small arrays and bits.
	var ids := _edge_priority.keys()
	ids.sort_custom(func(a: String, b: String) -> bool: return _edge_priority[a] < _edge_priority[b])
	for i in ids.size():
		_edge_priority[ids[i]] = i
		_by_rank.append(ids[i])
	for id: String in _edges:
		_edges[id][4] = _edge_priority[id]


## Neighbour bits as the art tool numbers them: sides N E S W, corners NE SE SW NW.
const _EDGE_BITS := [[Vector2i(0, -1), 1], [Vector2i(1, 0), 2], [Vector2i(0, 1), 4], [Vector2i(-1, 0), 8],
	[Vector2i(1, -1), 16], [Vector2i(1, 1), 32], [Vector2i(-1, 1), 64], [Vector2i(-1, -1), 128]]


## Where a higher ground meets a cell, its ragged edge laps over it. Done
## for a rectangle of cells at once: the grounds around are read once into
## an array of priorities (-1: takes no part, like a building floor).
func _paint_edges(location: String, x0: int, y0: int, w: int, h: int) -> void:
	var rw := w + 2
	var ranks := _ground_ranks(location, x0 - 1, y0 - 1, rw, h + 2)
	var offs := PackedInt32Array()
	var bits := PackedInt32Array()
	for b: Array in _EDGE_BITS:
		offs.append((b[0] as Vector2i).y * rw + (b[0] as Vector2i).x)
		bits.append(int(b[1]))
	var masks := PackedInt32Array()
	masks.resize(_by_rank.size())
	for y in h:
		for x in w:
			var i := (y + 1) * rw + x + 1
			var own := ranks[i]
			var cell := Vector2i(x0 + x, y0 + y)
			var had: int = _edge_set.get(cell, 0)
			if own < 0 and had == 0:
				continue
			masks.fill(0)
			var any := 0
			if own >= 0:
				for k in 8:
					var n := ranks[i + offs[k]]
					if n > own:
						masks[n] |= bits[k]
						any |= 1 << n
			for r in _by_rank.size():
				if any & (1 << r):
					_set_edge(_by_rank[r], cell, masks[r])
				elif had & (1 << r):
					(_edges[_by_rank[r]][5] as TileMapLayer).erase_cell(cell)
			if any == 0:
				_edge_set.erase(cell)
			else:
				_edge_set[cell] = any


func _set_edge(g: String, cell: Vector2i, m: int) -> void:
	var e: Array = _edges[g]
	# A corner counts only without a side next to it (the tool's shapes).
	if m & 3:
		m &= ~16
	if m & 6:
		m &= ~32
	if m & 12:
		m &= ~64
	if m & 9:
		m &= ~128
	var grid: Vector2i = e[2]
	var piece := _grid_piece(cell, grid)
	(e[5] as TileMapLayer).set_cell(cell, e[0], e[1] + Vector2i(e[3][m], piece.y * grid.x + piece.x))


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
			for id: String in c.palette:
				rank_of.append(_edge_priority.get(id, -1))
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


## Cells with an edge of a higher ground drawn over them -> bits of ranks.
func edge_cells() -> Dictionary:
	return _edge_set


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
	if keys.has("*"):
		_clear()
		keys = client.chunks.keys()
	for key: String in keys:
		_pending[key] = true
	_paint_pending()
	_update_light()
	_update_characters(alpha, delta)
	_update_room()
	_fade_occluders()


func _notification(what: int) -> void:
	# Layers made up front but never added (setup() not called) are freed too.
	if what == NOTIFICATION_PREDELETE:
		for n: Node in [_ground, _cover, _below, _covers, _sorted, _tint]:
			if is_instance_valid(n) and n.get_parent() == null:
				n.free()


func _update_light() -> void:
	if not client.has_time:
		return
	_tint.color = Daylight.tint(client.world_time)
	var dark := 1.0 - Daylight.sun(client.world_time)
	for i in range(_lights.size() - 1, -1, -1):
		var l := _lights[i]
		if not is_instance_valid(l):
			_lights.remove_at(i)
			continue
		l.energy = float(l.get_meta("intensity")) * dark * 1.6
		l.visible = dark > 0.02


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
	l.position = Vector2((cell.x + 0.5) * CELL, (cell.y + 0.5) * CELL - CELL)
	l.set_meta("intensity", float(def["intensity"]))
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


func pending_chunks() -> int:
	return _pending.size()


func _paint_pending() -> void:
	if _pending.is_empty():
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
		_paint(key)


## Forgets everything drawn (the client moved to another location).
func _clear() -> void:
	_ground.clear()
	_pending.clear()
	for g: String in _edges:
		(_edges[g][5] as TileMapLayer).clear()
	_edge_set.clear()
	_cover.clear()
	_below.clear()
	for key: String in _chunk_nodes:
		(_chunk_nodes[key] as Node).queue_free()
	_chunk_nodes.clear()
	for cell: Vector2i in _cover_sprites:
		(_cover_sprites[cell] as Node).queue_free()
	_cover_sprites.clear()
	_hidden_room.clear()
	_room_from = Vector2i(1 << 30, 0)


func own_pixel_position(alpha: float) -> Vector2:
	var a := Vector2(client.previous_position) / UNITS_PER_PIXEL
	var b := Vector2(client.position) / UNITS_PER_PIXEL
	return a.lerp(b, alpha)


func _paint(key: String, spread := true) -> void:
	var p := key.split("|")
	if not client.chunks.has(key):
		return
	var c: Chunk = client.chunks[key]
	if p[0] != client.location:
		if p[0] == Levels.SURFACE:
			_paint_below(c, int(p[1]) * Chunk.SIZE, int(p[2]) * Chunk.SIZE)
		return
	var ox := int(p[1]) * Chunk.SIZE
	var oy := int(p[2]) * Chunk.SIZE
	var holder: Node2D = _chunk_nodes.get(key)
	if holder:
		holder.queue_free()
	holder = Node2D.new()
	holder.y_sort_enabled = true
	_sorted.add_child(holder)
	_chunk_nodes[key] = holder
	for ly in Chunk.SIZE:
		for lx in Chunk.SIZE:
			var cell := Vector2i(ox + lx, oy + ly)
			_set_flat(_ground, cell, c.get_cell("ground", lx, ly))
			_cover.erase_cell(cell)
			_set_cover(cell, c.get_cell("roof", lx, ly) if c.get_cell("roof", lx, ly) != "" else c.get_cell("ceiling", lx, ly))
			for layer in ["cover", "structure"]:
				var id := c.get_cell(layer, lx, ly)
				if id == "":
					continue
				var v := content.visual_of(id)
				if v.get("mode") == "tall":
					var state := "open" if c.get_props(lx, ly).get("open", false) else ""
					var variant := _join_mask(p[0], cell, String(v.get("autotile", ""))) if v.has("autotile") else 0
					var facing := String(c.get_props(lx, ly).get("facing", ""))
					var s := _tall_sprite(v, cell, state, variant, facing)
					s.set_meta("cell", cell)
					holder.add_child(s)
					var light: Dictionary = content.get_def(id).get("light", {})
					if not light.is_empty():
						holder.add_child(_light_for(light, cell))
				else:
					_set_flat(_cover, cell, id)  # flat, or the missing-picture mark
			if c.get_props(lx, ly).get("stairs_down", false):
				var mark := _stairs_down_sprite(cell)
				if mark:
					holder.add_child(mark)
	# Walls on the edge join walls of the next chunk: redraw those once.
	if not _edges.is_empty():
		# Edges here, and on the rim of the chunks around, which depend on this one.
		_paint_edges(p[0], ox - 1, oy - 1, Chunk.SIZE + 2, Chunk.SIZE + 2)
	if spread:
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nk := ServerWorld.chunk_key(p[0], int(p[1]) + d.x, int(p[2]) + d.y)
			if _chunk_nodes.has(nk) and _edge_joins(c, d):
				_paint(nk, false)


## The surface under a building level: ground and flat plants, dimmed.
func _paint_below(c: Chunk, ox: int, oy: int) -> void:
	for ly in Chunk.SIZE:
		for lx in Chunk.SIZE:
			var cell := Vector2i(ox + lx, oy + ly)
			_set_flat(_below, cell, c.get_cell("ground", lx, ly))


func _set_cover(cell: Vector2i, id: String) -> void:
	var old: Sprite2D = _cover_sprites.get(cell)
	if old:
		old.queue_free()
		_cover_sprites.erase(cell)
	if id == "":
		return
	var v := content.visual_of(id)
	var s := Sprite2D.new()
	s.centered = false
	if v.is_empty():
		s.texture = _tile_texture(_missing_source)
	else:
		s.texture = texture(v["atlas_path"])
		s.region_enabled = true
		var piece := _grid_piece(cell, v["grid_size"]) * CELL if v.has("grid_size") else Vector2i.ZERO
		s.region_rect = Rect2(v["rect"][0] + piece.x, v["rect"][1] + piece.y, v["rect"][2], v["rect"][3])
	s.position = Vector2(cell.x * CELL, cell.y * CELL - COVER_LIFT)
	# Its shadow on the floor along its south edge, under the covers (the
	# next cover south hides it), so an overhang reads as one.
	var shade := ColorRect.new()
	shade.color = Color(0.08, 0.05, 0.04, 0.38)
	shade.size = Vector2(CELL, 4)
	shade.position = Vector2(0, COVER_LIFT)
	shade.z_index = -1
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(shade)
	s.visible = not _hidden_room.has(cell)
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
	var alts: Array = v.get("alternates", [])
	if not alts.is_empty() and state == "" and variant == 0:
		# The same picture for a cell every time and for every player.
		var k := absi((cell.x * 73856093) ^ (cell.y * 19349663)) % (alts.size() + 1)
		if k > 0:
			v = alts[k - 1]
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
	# The sprite's origin pixel sits on the cell's bottom-left corner; that corner sorts it.
	s.position = Vector2(cell.x * CELL, (cell.y + 1) * CELL)
	s.offset = -Vector2(v["origin"][0], v["origin"][1])
	return s


## Which neighbours (N=1, E=2, S=4, W=8) are drawn with the same join group.
func _join_mask(location: String, cell: Vector2i, group: String) -> int:
	var mask := 0
	var bits := [[Vector2i(0, -1), 1], [Vector2i(1, 0), 2], [Vector2i(0, 1), 4], [Vector2i(-1, 0), 8]]
	for b: Array in bits:
		var id := _cell_part(location, cell + (b[0] as Vector2i))
		if id != "" and content.visual_of(id).get("autotile", "") == group:
			mask |= int(b[1])
	return mask


func _cell_part(location: String, cell: Vector2i) -> String:
	var cx := floori(cell.x / float(Chunk.SIZE))
	var cy := floori(cell.y / float(Chunk.SIZE))
	var c: Chunk = client.chunks.get(ServerWorld.chunk_key(location, cx, cy))
	return c.get_cell("structure", cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE) if c else ""


## Whether a chunk has joining parts on its side facing direction d.
func _edge_joins(c: Chunk, d: Vector2i) -> bool:
	for i in Chunk.SIZE:
		var lx := Chunk.SIZE - 1 if d.x > 0 else (0 if d.x < 0 else i)
		var ly := Chunk.SIZE - 1 if d.y > 0 else (0 if d.y < 0 else i)
		var id := c.get_cell("structure", lx, ly)
		if id != "" and content.visual_of(id).has("autotile"):
			return true
	return false


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
	var body := Rect2(me.position + Vector2(-10, -30), Vector2(20, 30))
	for s: Sprite2D in _faded:
		if is_instance_valid(s):
			s.modulate.a = 1.0
	_faded.clear()
	var mc := Vector2i(floori(me.position.x / CELL / Chunk.SIZE), floori(me.position.y / CELL / Chunk.SIZE))
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var holder: Node2D = _chunk_nodes.get(ServerWorld.chunk_key(client.location, mc.x + dx, mc.y + dy))
			if holder == null:
				continue
			for n: Node in holder.get_children():
				var s := n as Sprite2D  # lights stand among the sprites
				if s and s.position.y > me.position.y and _sprite_rect(s).intersects(body):
					s.modulate.a = FADED
					_faded.append(s)
	for cell: Vector2i in _cover_sprites:
		var cs: Sprite2D = _cover_sprites[cell]
		if cs.visible and (cell.y + 1) * CELL > me.position.y and _sprite_rect(cs).intersects(body):
			cs.modulate.a = FADED
			_faded.append(cs)


func _sprite_rect(s: Sprite2D) -> Rect2:
	return Rect2(s.position + s.offset, s.region_rect.size)


## What the player points at: a visible cover, else a tall thing whose
## picture is under the point, else the cell under it. [cell, layer hint]
func pick(point: Vector2) -> Vector2i:
	for cell: Vector2i in _cover_sprites:
		var cs: Sprite2D = _cover_sprites[cell]
		if cs.visible and _sprite_rect(cs).has_point(point):
			return cell
	var best := Vector2i(floori(point.x / CELL), floori(point.y / CELL))
	var best_y := -INF
	for holder: Node2D in _chunk_nodes.values():
		for n: Node in holder.get_children():
			var s := n as Sprite2D
			if s and s.has_meta("cell") and s.position.y > best_y and _sprite_rect(s).has_point(point):
				best = s.get_meta("cell")
				best_y = s.position.y
	return best


func _update_characters(alpha: float, delta: float) -> void:
	var seen := {}
	if client.has_position:
		seen[client.character_id] = true
		var me := _character(client.character_id, client.own.get("appearance", {}))
		me.show_at(own_pixel_position(alpha), delta, true)
		me.modulate = Color.WHITE
		_health(client.character_id, me, client.own, delta)
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") == "item":
			seen[id] = true
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
		sprite.show_at(target - Vector2(0, COVER_LIFT * maxi(dz, 0)), delta, false)
		_at_level(sprite, client.z + dz)
		_health(id, sprite, e, delta)
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
	for id: String in _hp_seen.keys():
		if not seen.has(id):
			_hp_seen.erase(id)
			_flash.erase(id)


var _items := {}
var _projectiles := {}
## Health last drawn, and how much of a hurt flash is left (s), by id.
var _hp_seen := {}
var _flash := {}
const FLASH := 0.25


## An arrow in flight: its item's picture turned along its way, at the
## height it flies, easing to where the server has it.
func _projectile(id: String, e: Dictionary, delta: float) -> void:
	var target := Vector2(int(e.get("x", 0)), int(e.get("y", 0))) / UNITS_PER_PIXEL - Vector2(0, 10)
	var s: Sprite2D = _projectiles.get(id)
	if s == null:
		var v := content.visual_of(String(e.get("item", "")))
		s = Sprite2D.new()
		if not v.is_empty():
			s.texture = texture(v["atlas_path"])
			s.region_enabled = true
			s.region_rect = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
		# The picture points up and right; turn it along the flight.
		s.rotation = atan2(float(e.get("vy", 0)), float(e.get("vx", 1))) + PI / 4.0
		s.position = target
		s.z_index = 5
		add_child(s)
		_projectiles[id] = s
	s.position = s.position.lerp(target, minf(1.0, delta * 30.0))


## A health bar over one who is hurt, and a red flash when hurt again.
func _health(id: String, sprite: Node2D, e: Dictionary, delta: float) -> void:
	var top := int(e.get("max_health", 0))
	var h := int(e.get("health", top))
	if h < int(_hp_seen.get(id, h)):
		_flash[id] = FLASH
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
	s.position = Vector2(int(e["x"]), int(e["y"])) / UNITS_PER_PIXEL
	s.offset = Vector2(0, -4)
	_sorted.add_child(s)
	_items[id] = s
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
		v = content.visual_of("base:humanoid_adult")
	var layers := []
	for style: Variant in (looks.get("styles", {}) as Dictionary).values():
		var sv := content.visual_of(String(style))
		if sv.get("mode") == "layer":
			layers.append([String(sv.get("layer", "")), texture(sv["atlas_path"])])
	for item: Variant in (looks.get("worn", {}) as Dictionary).values():
		var worn: Dictionary = content.visual_of(String(item)).get("worn", {})
		if not worn.is_empty():
			layers.append([String(worn.get("layer", "")), texture(worn["atlas_path"])])
	var cs := CharacterSprite.new(texture(v["atlas_path"]), v, layers, looks.duplicate(true))
	cs.stepped.connect(func() -> void:
		if on_step.is_valid():
			on_step.call(cs.position))
	if old:
		cs.position = old.position
		old.queue_free()
	_sorted.add_child(cs)
	_characters[id] = cs
	return cs
