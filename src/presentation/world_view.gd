class_name WorldView
extends Node2D
## What the game's world view gives the rest of the game, whatever draws it: the
## cells the client knows, the pictures and grips of things, how a blow with a
## thing looks, the own character's doings shown at once. The world is drawn in
## 3D (WorldView3D, ADR-0063: the 2D sprite view is gone); this is its base.

const CELL := 16
## Simulation units per world pixel (Movement.UNIT / CELL).
const UNITS_PER_PIXEL := Movement.UNIT / CELL
## A storey in world pixels (ADR-0024), for what is lifted a level up.
const COVER_LIFT := 32
const SEASON_KEYS := ["spring", "summer", "autumn", "winter"]
## How big a thing on the ground is drawn, of its picture (a full picture filled a
## whole cell: too big beside the people, the author 27.10.2026).
const GROUND_ITEM_SCALE := 0.6

var content: ContentRegistry
var client: GameClient
## Called with the point (pixels) where a character's foot came down.
var on_step := Callable()
## What the own character holds (set by the game at once, before the server knows).
var own_held := ""
## Blows, health and deaths last seen, by id: what changed is shown once.
var _swing_seen := {}
var _hp_seen := {}
var _deaths_seen := {}
var _pictures := {}


func setup(registry: ContentRegistry, game_client: GameClient) -> void:
	content = registry
	client = game_client


## Call every frame. alpha: how far we are between the last tick and the next (0..1).
func update_view(_alpha: float, _delta: float) -> void:
	pass


func ground_at(location: String, cell: Vector2i) -> String:
	return client.cell_at(location, cell, "ground")


## Cells hidden because the player is inside under them (the room one is in).
func hidden_room() -> Dictionary:
	return {}


func texture(path: String) -> Texture2D:
	return Art.texture(path)


## Where the own character is drawn, in world pixels, between the last tick and the next.
func own_pixel_position(alpha: float) -> Vector2:
	var a := Vector2(client.previous_position) / UNITS_PER_PIXEL
	var b := Vector2(client.position) / UNITS_PER_PIXEL
	return a.lerp(b, alpha)


## What is at a point of the world (pixels): a being or a thing lying within half
## a cell of it (the nearest), else the topmost thing on its cell as seen from
## above (a roof, a ceiling, a part, a plant), else the ground.
func pick_target(point: Vector2) -> Dictionary:
	var best := {}
	var best_d := CELL * 0.6
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if not String(e.get("kind", "")) in ["character", "creature", "item"] or not e.has("x") \
				or int(e.get("z", client.z)) != client.z:
			continue
		var d := (Vector2(int(e["x"]), int(e["y"])) / UNITS_PER_PIXEL).distance_to(point)
		if d < best_d:
			best = {"kind": "entity", "id": id, "entity": e, "location": client.location}
			best_d = d
	if not best.is_empty():
		return best
	var cell := Vector2i(floori(point.x / CELL), floori(point.y / CELL))
	for layer: String in (["roof", "ceiling"] if covers_shown(cell) else []) + ["structure", "cover"]:
		if _cell_layer(cell, layer) != "":
			return layer_target(cell, layer)
	return {"kind": "ground", "id": ground_at(client.location, cell), "cell": cell, "location": client.location}


## Whether a cell's roof and ceiling are drawn (not cut away round the player).
func covers_shown(_cell: Vector2i) -> bool:
	return true


## The solid thing on a cell as a target: its part, else its plant (a tree).
func part_target(cell: Vector2i) -> Dictionary:
	return layer_target(cell, "structure" if _cell_layer(cell, "structure") != "" else "cover")


## What lies on a layer of a cell as a target, with how worn and how far worked it is.
func layer_target(cell: Vector2i, layer: String) -> Dictionary:
	var out := {"kind": "part", "layer": layer, "id": _cell_layer(cell, layer), "cell": cell, "location": client.location}
	var at_cell := props_at(cell)
	var worn: Dictionary = at_cell if layer == "structure" else at_cell.get(layer, {})
	if int(worn.get("damage", 0)) > 0:
		out["damage"] = int(worn["damage"])
	if int(worn.get("work", 0)) > 0:
		out["work"] = int(worn["work"])
	return out


func _cell_layer(cell: Vector2i, layer: String) -> String:
	return client.cell_at(client.location, cell, layer)


## The props of a cell of the client's location ({} if unknown).
func props_at(cell: Vector2i) -> Dictionary:
	return client.props_of(client.location, cell)


## How a blow with a thing looks (CharacterSprite.swing).
func swing_kind(held: String) -> String:
	return swing_of(content, held)


static func swing_of(content: ContentRegistry, held: String) -> String:
	if held != "" and content.get_def(held).has("swing"):
		return String(content.get_def(held)["swing"])  # a tool's own motion (a hoe thrusts)
	var w: Dictionary = content.get_def(held).get("weapon", {}) if held != "" else {}
	if w.get("kind") == "ranged":
		return "draw"
	if w.get("kind") == "melee" and float(w.get("arc", 90)) < 60.0:
		return "thrust"
	return "chop" if held != "" else "lunge"


## The own character plays a clip once (a stoop to pick up).
func react_own(_clip: String) -> void:
	pass


## The own character strikes toward `dir` at once, before the server answers.
func swing_own(_dir: Vector2) -> void:
	pass


## The own character draws its bow toward `dir` and holds it (loose_own lets go).
func draw_own(_dir: Vector2) -> void:
	pass


func loose_own(_dir: Vector2) -> void:
	pass


## The visual a being is drawn by: its body's, in its own variant of the
## body's alternates (a creature keeps one across frames, reloads and clients).
func visual_for(id: String, looks: Dictionary) -> Dictionary:
	var v := content.visual_of(String(looks.get("body_plan", "")))
	if v.is_empty():
		v = content.visual_of("base:human_m")
	var alternates: Array = v.get("alternates", [])
	var variant := posmod(id.hash(), alternates.size() + 1)
	return v.merged(alternates[variant - 1], true) if variant > 0 else v


## A being's doll for its looks: `old` itself when they are the same, `old`
## dressed anew when it can be (its walk, facing, tool and blow go on), else a new one.
func doll_for(id: String, looks: Dictionary, old: CharacterSprite = null) -> CharacterSprite:
	if old and old.look == looks:
		return old
	var v := visual_for(id, looks)
	if old and Art.same_kind(old, v):
		Art.dress(old, content, v, looks)
		return old
	return Art.character_sprite(content, v, looks)


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


## Marks the cell one was sent to (Vector2i.MAX: none); none by default.
func mark_walk(_cell: Vector2i) -> void:
	pass


## Effects at a point of the world (chips off what is worked); none by default.
func burst_at(_at: Vector2, _kind: String, _tint := Color.WHITE) -> void:
	pass


## A number or a word floating up from a point of the world; none by default.
func popup_at(_at: Vector2, _text: String, _color := Art.TEXT) -> void:
	pass


func sprite_count() -> int:
	return 0


func pending_chunks() -> int:
	return 0
