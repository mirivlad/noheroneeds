class_name WorldView
extends Node2D
## Draws what the client knows: ground and flat plants as tile layers, tall
## things (trees, bushes, walls) and characters as Y-sorted sprites. Every
## picture comes from the content's visual definitions; nothing here knows a
## particular tree or wall.

const CELL := 16
## Simulation units per screen pixel (Movement.UNIT / CELL).
const UNITS_PER_PIXEL := Movement.UNIT / CELL

var content: ContentRegistry
var client: GameClient
var _ground := TileMapLayer.new()
var _cover := TileMapLayer.new()
var _sorted := Node2D.new()
var _chunk_nodes := {}
var _characters := {}
var _textures := {}
## visual id -> [source id, first atlas cell Vector2i, variants]
var _tiles := {}


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
	_ground.tile_set = ts
	_cover.tile_set = ts
	_ground.z_index = -2
	_cover.z_index = -1
	_sorted.y_sort_enabled = true
	add_child(_ground)
	add_child(_cover)
	add_child(_sorted)


func texture(path: String) -> Texture2D:
	if not _textures.has(path):
		if path.begins_with("res://"):
			_textures[path] = load(path)
		else:
			_textures[path] = ImageTexture.create_from_image(Image.load_from_file(path))
	return _textures[path]


## Call every frame. alpha: how far we are between the last tick and the next (0..1).
func update_view(alpha: float, delta: float) -> void:
	for key: String in client.changed_chunks:
		_paint(key)
	client.changed_chunks.clear()
	_update_characters(alpha, delta)


func own_pixel_position(alpha: float) -> Vector2:
	var a := Vector2(client.previous_position) / UNITS_PER_PIXEL
	var b := Vector2(client.position) / UNITS_PER_PIXEL
	return a.lerp(b, alpha)


func _paint(key: String) -> void:
	var p := key.split("|")
	if p[0] != client.location:
		return
	var c: Chunk = client.chunks[key]
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
			for layer in ["cover", "structure"]:
				var id := c.get_cell(layer, lx, ly)
				if id == "":
					continue
				var v := content.visual_of(id)
				if v.get("mode") == "flat":
					_set_flat(_cover, cell, id)
				elif v.get("mode") == "tall":
					holder.add_child(_tall_sprite(v, cell))


func _set_flat(layer: TileMapLayer, cell: Vector2i, id: String) -> void:
	var t: Array = _tiles.get(id, [])
	if t.is_empty():
		layer.erase_cell(cell)
		return
	var variant := (cell.x * 73856093 ^ cell.y * 19349663) & 0x7fffffff
	layer.set_cell(cell, t[0], t[1] + Vector2i(variant % t[2], 0))


func _tall_sprite(v: Dictionary, cell: Vector2i) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = texture(v["atlas_path"])
	s.region_enabled = true
	s.region_rect = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
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
		if e.get("kind") != "character":
			continue
		seen[id] = true
		var target := Vector2(int(e.get("x", 0)), int(e.get("y", 0))) / UNITS_PER_PIXEL
		_character(id, e.get("appearance", {}).get("body_plan", "")).show_at(target, delta, false)
	for id: String in _characters.keys():
		if not seen.has(id):
			_characters[id].queue_free()
			_characters.erase(id)


func _character(id: String, plan: String) -> CharacterSprite:
	if not _characters.has(id):
		var v := content.visual_of(plan)
		if v.is_empty():
			v = content.visual_of("base:humanoid_adult")
		var cs := CharacterSprite.new(texture(v["atlas_path"]), v)
		_sorted.add_child(cs)
		_characters[id] = cs
	return _characters[id]
