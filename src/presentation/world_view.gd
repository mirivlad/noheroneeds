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
var _ground := TileMapLayer.new()
var _cover := TileMapLayer.new()
## The surface seen from a building level, dimmed.
var _below := TileMapLayer.new()
var _covers := Node2D.new()
## cell -> Sprite2D of the ceiling or roof over it
var _cover_sprites := {}
var _hidden_room := {}
var _room_from := Vector2i(1 << 30, 0)
var _sorted := Node2D.new()
var _chunk_nodes := {}
var _characters := {}
var _textures := {}
## visual id -> [source id, first atlas cell Vector2i, variants]
var _tiles := {}
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
		for i in int(v["variants"]):
			var at := first + Vector2i(i, 0)
			if not src.has_tile(at):
				src.create_tile(at)
		_tiles[target] = [sources[path][0], first, int(v["variants"])]
	var miss := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
	for y in CELL:
		for x in CELL:
			miss.set_pixel(x, y, Color.MAGENTA if (x / 4 + y / 4) % 2 == 0 else Color.BLACK)
	var ms := TileSetAtlasSource.new()
	ms.texture = ImageTexture.create_from_image(miss)
	ms.texture_region_size = Vector2i(CELL, CELL)
	ms.create_tile(Vector2i.ZERO)
	_missing_source = ts.add_source(ms)
	_ground.tile_set = ts
	_cover.tile_set = ts
	_below.tile_set = ts
	_below.z_index = -3
	_below.modulate = Color(0.42, 0.42, 0.52)
	_ground.z_index = -2
	_cover.z_index = -1
	_sorted.y_sort_enabled = true
	_covers.z_index = 10
	add_child(_below)
	add_child(_ground)
	add_child(_cover)
	add_child(_sorted)
	add_child(_covers)


## The tile layer of the ground (or floors) of the client's location.
func ground_layer() -> TileMapLayer:
	return _ground


## Cells whose cover is hidden because the player stands in that room.
func hidden_room() -> Dictionary:
	return _hidden_room


func texture(path: String) -> Texture2D:
	if not _textures.has(path):
		if path.begins_with("res://"):
			_textures[path] = load(path)
		else:
			_textures[path] = ImageTexture.create_from_image(Image.load_from_file(path))
	return _textures[path]


## Call every frame. alpha: how far we are between the last tick and the next (0..1).
func update_view(alpha: float, delta: float) -> void:
	var keys := client.changed_chunks.duplicate()
	client.changed_chunks.clear()
	if keys.has("*"):
		_clear()
		keys = client.chunks.keys()
	for key: String in keys:
		_paint(key)
	_update_characters(alpha, delta)
	_update_room()


## Forgets everything drawn (the client moved to another location).
func _clear() -> void:
	_ground.clear()
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


func _paint(key: String) -> void:
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
					holder.add_child(_tall_sprite(v, cell, state))
				else:
					_set_flat(_cover, cell, id)  # flat, or the missing-picture mark


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
		s.region_rect = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
	s.position = Vector2(cell.x * CELL, cell.y * CELL - COVER_LIFT)
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
	var variant := (cell.x * 73856093 ^ cell.y * 19349663) & 0x7fffffff
	layer.set_cell(cell, t[0], t[1] + Vector2i(variant % t[2], 0))


func _tall_sprite(v: Dictionary, cell: Vector2i, state := "") -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = texture(v["atlas_path"])
	s.region_enabled = true
	var r: Array = v.get("states", {}).get(state, v["rect"])
	s.region_rect = Rect2(r[0], r[1], r[2], r[3])
	s.centered = false
	# The sprite's origin pixel sits on the cell's bottom-left corner; that corner sorts it.
	s.position = Vector2(cell.x * CELL, (cell.y + 1) * CELL)
	s.offset = -Vector2(v["origin"][0], v["origin"][1])
	return s


func _update_characters(alpha: float, delta: float) -> void:
	var seen := {}
	if client.has_position:
		seen[client.character_id] = true
		_character(client.character_id, client.location).show_at(own_pixel_position(alpha), delta, true)
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") == "item":
			seen[id] = true
			_item(id, e)
			continue
		if e.get("kind") != "character":
			continue
		seen[id] = true
		var target := Vector2(int(e.get("x", 0)), int(e.get("y", 0))) / UNITS_PER_PIXEL
		_character(id, e.get("appearance", {}).get("body_plan", "")).show_at(target, delta, false)
	for id: String in _characters.keys():
		if not seen.has(id):
			_characters[id].queue_free()
			_characters.erase(id)
	for id: String in _items.keys():
		if not seen.has(id):
			_items[id].queue_free()
			_items.erase(id)


var _items := {}


## A thing on the ground: its picture, standing where it lies.
func _item(id: String, e: Dictionary) -> void:
	if _items.has(id):
		return
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


func _tile_texture(source: int) -> Texture2D:
	return (_ground.tile_set.get_source(source) as TileSetAtlasSource).texture


func _character(id: String, plan: String) -> CharacterSprite:
	if not _characters.has(id):
		var v := content.visual_of(plan)
		if v.is_empty():
			v = content.visual_of("base:humanoid_adult")
		var cs := CharacterSprite.new(texture(v["atlas_path"]), v)
		_sorted.add_child(cs)
		_characters[id] = cs
	return _characters[id]
