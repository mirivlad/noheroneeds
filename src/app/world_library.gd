class_name WorldLibrary
extends RefCounted
## The player's saved worlds: a directory each (worlds/<id>/) with the world
## database and world.json — its name and the rules it was made with
## (ServerWorld settings: height, starter things) plus when it was last
## played. A world made before the library (worlds/local/ without
## world.json) is taken in with default rules.

const META := "world.json"
## Rules a new world gets unless the player changes them.
const RULES := {
	"seed": "",
	"max_levels": 3,
	"starter_kit": true,
	"starter_outfit": true,
	## How long a game day lasts, real minutes (ADR-0014).
	"day_minutes": 24,
	## Characters hurting characters (ADR-0016): "off" or "free".
	"pvp": "off",
	## A character that dies leaves what it carried where it fell (ADR-0019).
	"death_drops": true,
	## Whether one may break someone else's building (ADR-0016, ADR-0021).
	"break_others": false,
}
## What "starter kit" and "starter outfit" give (world rules of the base game).
const STARTER_KIT := {"base:plank": 120, "base:stone": 30, "base:log": 20, "base:axe": 1, "base:bow": 1, "base:arrow": 20, "base:pickaxe": 1}
const STARTER_OUTFIT := {"torso": "base:linen_shirt", "legs": "base:work_trousers", "feet": "base:boots"}

var root := ""


func _init(dir: String) -> void:
	root = dir


## [{id, name, created, last_played, rules...}], last played first.
func list() -> Array:
	var out := []
	var d := DirAccess.open(root)
	if d == null:
		return out
	for id in d.get_directories():
		var info := read(id)
		if not info.is_empty():
			out.append(info)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["last_played"]) > int(b["last_played"]) or (
			int(a["last_played"]) == int(b["last_played"]) and String(a["name"]) < String(b["name"])))
	return out


## One world's record ({} if there is no world there).
func read(id: String) -> Dictionary:
	var dir := root.path_join(id)
	if not FileAccess.file_exists(dir.path_join("world.db")):
		return {}
	var info := {}
	var text := FileAccess.get_file_as_string(dir.path_join(META))
	var parsed: Variant = JSON.parse_string(text) if text != "" else null
	if typeof(parsed) == TYPE_DICTIONARY:
		info = parsed
	else:
		# Made before the library: keep it, under a plain name.
		info = {"name": "Мой мир" if id == "local" else id, "created": _mtime(dir), "last_played": _mtime(dir)}
		info.merge(RULES)
		_write(id, info)
	for key: String in RULES:
		if not info.has(key):
			info[key] = RULES[key]
	info["id"] = id
	info["created"] = int(info.get("created", 0))
	info["last_played"] = int(info.get("last_played", 0))
	info["max_levels"] = int(info["max_levels"])
	return info


## A world's record before its database exists (a new world), or {}.
func read_meta_only(id: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(root.path_join(id).path_join(META)))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Makes a world's record and directory; the database appears when it is
## first opened. Returns its id.
func create(name: String, rules: Dictionary) -> String:
	var id := _free_id(name)
	DirAccess.make_dir_recursive_absolute(root.path_join(id))
	var info := {"name": name.strip_edges() if name.strip_edges() != "" else "Новый мир",
		"created": int(Time.get_unix_time_from_system()), "last_played": 0}
	for key: String in RULES:
		info[key] = rules.get(key, RULES[key])
	info["max_levels"] = clampi(int(info["max_levels"]), 1, 20)
	info["day_minutes"] = clampi(int(info["day_minutes"]), 2, 600)
	_write(id, info)
	return id


func db_path(id: String) -> String:
	return root.path_join(id).path_join("world.db")


func touch(id: String) -> void:
	var info := read(id)
	if info.is_empty():
		info = {"name": id}
		info.merge(RULES)
	info["last_played"] = int(Time.get_unix_time_from_system())
	info.erase("id")
	_write(id, info)


## The seed to open a new world with (the rules' text, or random).
static func seed_of(info: Dictionary) -> int:
	var text := String(info.get("seed", "")).strip_edges()
	if text == "":
		return randi()
	return int(text) if text.is_valid_int() else hash(text)


## Puts a world record's rules into the running world.
static func apply_rules(info: Dictionary, world: ServerWorld) -> void:
	world.max_levels = int(info.get("max_levels", RULES["max_levels"]))
	world.starter_kit = STARTER_KIT.duplicate() if info.get("starter_kit", true) else {}
	world.starter_outfit = STARTER_OUTFIT.duplicate() if info.get("starter_outfit", true) else {}
	world.set_day_minutes(float(info.get("day_minutes", RULES["day_minutes"])))
	world.combat.pvp = "free" if String(info.get("pvp", RULES["pvp"])) == "free" else "off"
	world.combat.death_drops = bool(info.get("death_drops", RULES["death_drops"]))
	world.break_others = bool(info.get("break_others", RULES["break_others"]))


func _write(id: String, info: Dictionary) -> void:
	var f := FileAccess.open(root.path_join(id).path_join(META), FileAccess.WRITE)
	if f:
		var keep := info.duplicate()
		keep.erase("id")
		f.store_string(JSON.stringify(keep, "  ", true))
		f.close()


func _free_id(name: String) -> String:
	var base := ""
	for ch in name.to_lower():
		base += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	base = base.strip_edges().trim_prefix("_").trim_suffix("_")
	if base.replace("_", "") == "":
		base = "world"
	var id := base
	var n := 2
	while DirAccess.dir_exists_absolute(root.path_join(id)):
		id = "%s_%d" % [base, n]
		n += 1
	return id


static func _mtime(dir: String) -> int:
	return FileAccess.get_modified_time(dir.path_join("world.db"))
