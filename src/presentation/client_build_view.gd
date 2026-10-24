class_name ClientBuildView
extends RefCounted
## The client's view for BuildRules (ADR-0021): the chunks it has, the people
## it sees, its own place and the server's height limit. It shows blueprints
## as the server will judge them; the server still decides each cell.

var client: GameClient


func _init(game_client: GameClient) -> void:
	client = game_client


func build_chunk(location: String, cx: int, cy: int) -> Chunk:
	return client.chunks.get(ServerWorld.chunk_key(location, cx, cy))


func build_kind(location: String) -> String:
	if location == Levels.SURFACE:
		return Levels.SURFACE
	return Levels.DEPTH if Levels.is_depth(location) else Levels.BUILDING_LEVEL


func build_z(location: String) -> int:
	return client.z if location == client.location else 0


func build_max_levels() -> int:
	return client.max_levels


func build_rain(location: String, x: int, y: int) -> float:
	var c := build_chunk(location, x >> 5, y >> 5)
	if Levels.is_depth(location) or c == null or Terrain.is_covered(c, x & 31, y & 31):
		return 0.0
	var cell := Vector2i(x, y)
	return Weather.rain(client.weather_seed, client.world_time, cell, client.climate_at(cell))


func build_someone_on(location: String, x: int, y: int) -> bool:
	if location != client.location:
		return false
	if client.has_position and BuildRules.stands_on(client.position, x, y):
		return true
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") == "character" and int(e.get("z", client.z)) == client.z \
				and BuildRules.stands_on(Vector2i(int(e.get("x", 0)), int(e.get("y", 0))), x, y):
			return true
	return false
