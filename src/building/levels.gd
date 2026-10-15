class_name Levels
extends RefCounted
## Locations other than the surface (ADR-0007): the levels of buildings.
## A level lives in the same XY grid as the surface; its number z is only a
## label, its identity is the location id. A building is a group of ceilings
## joined side by side; its levels are {z: location id}.

const SURFACE := "surface"
const BUILDING_LEVEL := "building_level"
## A depth of the underground (ADR-0017): one for the whole world, known by
## its number ("depth:-1"), nothing to register or merge.
const DEPTH := "depth"
const DEPTH_PREFIX := "depth:"


static func depth_id(z_level: int) -> String:
	return DEPTH_PREFIX + str(z_level)


static func is_depth(location: String) -> bool:
	return location.begins_with(DEPTH_PREFIX)

## location id -> {"kind", "building", "z"}
var info := {}
## building id -> {z: location id}
var buildings := {}
## location ids to write, and ids to delete (absorbed by a merge)
var dirty := {}
var removed := {}


func load_rows(rows: Array) -> void:
	for row: Dictionary in rows:
		_put(row["location_id"], row["kind"], row["building"], int(row["z"]))


func kind(location: String) -> String:
	if location == SURFACE:
		return SURFACE
	if is_depth(location):
		return DEPTH
	return String(info.get(location, {}).get("kind", ""))


func z(location: String) -> int:
	if is_depth(location):
		return int(location.substr(DEPTH_PREFIX.length()))
	return int(info.get(location, {}).get("z", 0))


func building(location: String) -> String:
	return String(info.get(location, {}).get("building", ""))


## The location of a building's level z ("" if none). Level 0 is the surface.
func level(building_id: String, z_level: int) -> String:
	if z_level == 0:
		return SURFACE
	return String(buildings.get(building_id, {}).get(z_level, ""))


func create_level(building_id: String, z_level: int) -> String:
	var id := Uuid.v4()
	_put(id, BUILDING_LEVEL, building_id, z_level)
	dirty[id] = true
	return id


## Joins building `absorbed` into `survivor`. Returns [[from, to], ...] for
## levels both had (their cells must move from one location to the other;
## `from` then disappears). Levels only the absorbed one had simply change
## owner: nothing moves.
func absorb(survivor: String, absorbed: String) -> Array:
	var moves: Array = []
	var theirs: Dictionary = buildings.get(absorbed, {})
	for zl: int in theirs:
		var loc: String = theirs[zl]
		var ours := level(survivor, zl)
		if ours == "":
			info[loc]["building"] = survivor
			buildings[survivor][zl] = loc
			dirty[loc] = true
		else:
			moves.append([loc, ours])
	buildings.erase(absorbed)
	return moves


func forget(location: String) -> void:
	var b := building(location)
	if buildings.has(b):
		(buildings[b] as Dictionary).erase(z(location))
	info.erase(location)
	dirty.erase(location)
	removed[location] = true


func _put(id: String, k: String, b: String, zl: int) -> void:
	info[id] = {"kind": k, "building": b, "z": zl}
	if not buildings.has(b):
		buildings[b] = {}
	buildings[b][zl] = id
