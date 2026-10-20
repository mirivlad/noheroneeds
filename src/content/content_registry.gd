class_name ContentRegistry
extends RefCounted
## Definitions of everything in the world, loaded from content packs (JSON).
## Code never branches on a particular id: it reads the definition's fields.
##
## A pack is a directory with pack.json ({format, id, version, depends}) and
## any number of *.json files ({format, defs: [{id, kind, ...}]}). Ids are
## "<pack>:<name>"; a pack defines ids only in its own namespace. Each kind
## has a validator that checks fields and references to other definitions.

const PACK_FORMAT := 1
## Fields only a player sees (texts). They, "visual" and "sound" definitions
## are left out of the rules fingerprint (ADR-0009): translations, texture
## and sound packs never stop anyone from joining.
const PRESENTATION_FIELDS := ["name", "description"]
## Fields the registry adds while loading.
const DERIVED_FIELDS := ["pack", "atlas_path", "paths", "body_size"]
## Kinds that only show or sound, never rule.
const PRESENTATION_KINDS := ["visual", "sound"]
## What a sound answers to (sounds.json, ADR-0009).
const SOUND_EVENTS := ["step", "build", "dismantle", "open", "close", "pickup", "drop", "climb", "click", "ambience", "wind",
	"swing", "hit", "shoot"]
## What a structure part is for (ADR-0007). Columns and beams are decoration.
const STRUCTURE_ROLES := ["wall", "door", "window", "fence", "column", "beam", "ceiling", "roof", "stairs", "furniture",
	"rock", "shaft"]
## Which way a part can be turned (ADR-0013): north is up the screen. A part
## lists the facings it allows, the first is its default; none: it does not turn.
const FACINGS := {"n": Vector2i(0, -1), "e": Vector2i(1, 0), "s": Vector2i(0, 1), "w": Vector2i(-1, 0)}
const DEFS_FORMAT := 1

static var _id_pattern := RegEx.create_from_string("^[a-z0-9_]+:[a-z0-9_/]+$")

## id -> definition Dictionary (with "pack" added)
var defs := {}
## pack id -> {"version", "depends", "dir"}
var packs := {}
## content id -> visual definition that draws it; a later pack's visual
## replaces an earlier one (reskins), logic definitions cannot be replaced.
var visuals := {}
## content id (or "*" for anything without its own) -> {event: sound
## definition}; a later pack's sound replaces an earlier one.
var sounds := {}
## Problems found while loading; a registry with errors must not be used.
var errors: PackedStringArray = []


static func is_valid_id(id: String) -> bool:
	return _id_pattern.search(id) != null


## Loads packs in dependency order and validates the result.
static func load_packs(dirs: PackedStringArray) -> ContentRegistry:
	var reg := ContentRegistry.new()
	var pending := {}
	for dir in dirs:
		var manifest := reg._read_json(dir.path_join("pack.json"))
		if manifest.is_empty():
			continue
		if int(manifest.get("format", 0)) != PACK_FORMAT:
			reg.errors.append("%s: unknown pack format %s" % [dir, manifest.get("format")])
			continue
		var pid := String(manifest.get("id", ""))
		if not pid.is_valid_identifier() or pid != pid.to_lower():
			reg.errors.append("%s: bad pack id '%s'" % [dir, pid])
			continue
		if pending.has(pid):
			reg.errors.append("pack '%s' given twice" % pid)
			continue
		pending[pid] = {"version": String(manifest.get("version", "")), "depends": manifest.get("depends", []), "dir": dir}
	var loaded := {}
	while loaded.size() < pending.size():
		var progress := false
		for pid: String in pending:
			if loaded.has(pid):
				continue
			var ready := true
			for dep: Variant in pending[pid]["depends"]:
				if not pending.has(String(dep)):
					reg.errors.append("pack '%s' needs missing pack '%s'" % [pid, dep])
					loaded[pid] = true
					ready = false
					break
				if not loaded.has(String(dep)):
					ready = false
			if ready and not loaded.has(pid):
				reg._load_pack(pid, pending[pid])
				loaded[pid] = true
				progress = true
		if not progress and loaded.size() < pending.size():
			reg.errors.append("packs depend on each other in a cycle")
			break
	reg._validate()
	return reg


## For tests and tools: a registry from definitions in memory (pack "test").
static func from_defs(list: Array) -> ContentRegistry:
	var reg := ContentRegistry.new()
	reg.packs["test"] = {"version": "0", "depends": [], "dir": ""}
	for d: Dictionary in list:
		reg._add(d.duplicate(true), "test", "memory")
	reg._validate()
	return reg


func has(id: String) -> bool:
	return defs.has(id)


func get_def(id: String) -> Dictionary:
	return defs.get(id, {})


func kind_of(id: String) -> String:
	return String(defs.get(id, {}).get("kind", ""))


## Materials a structure part costs: {item id: count}; empty if not a structure.
func structure_cost(id: String) -> Dictionary:
	var d: Dictionary = defs.get(id, {})
	return d.get("cost", {}) if d.get("kind") == "structure" else {}


## How a definition is drawn ({} if nothing draws it).
func visual_of(id: String) -> Dictionary:
	return visuals.get(id, {})


## Identifies the game rules this content defines (ADR-0009): every
## definition except visuals, without texts and loading details, as
## deterministic CBOR. File bytes, pack versions and pictures do not count.
func fingerprint() -> String:
	var rules := {}
	for id: String in defs:
		var d: Dictionary = defs[id]
		if PRESENTATION_KINDS.has(d.get("kind")):
			continue
		var r := d.duplicate(true)
		for f: String in PRESENTATION_FIELDS + DERIVED_FIELDS:
			r.erase(f)
		rules[id] = r
	return Hash.sha256(Cbor.encode(rules)).hex_encode()


func _load_pack(pid: String, info: Dictionary) -> void:
	packs[pid] = info
	var dir: String = info["dir"]
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		if not f.ends_with(".json") or f == "pack.json":
			continue
		var path := dir.path_join(f)
		var data := _read_json(path)
		if data.is_empty():
			continue
		if int(data.get("format", 0)) != DEFS_FORMAT:
			errors.append("%s: unknown definitions format %s" % [path, data.get("format")])
			continue
		for d: Variant in data.get("defs", []):
			if typeof(d) != TYPE_DICTIONARY:
				errors.append("%s: a definition is not an object" % path)
				continue
			_add(d, pid, path)


func _add(d: Dictionary, pid: String, where: String) -> void:
	var id := String(d.get("id", ""))
	if not is_valid_id(id):
		errors.append("%s: bad id '%s'" % [where, id])
		return
	if id.get_slice(":", 0) != pid:
		errors.append("%s: '%s' is outside pack namespace '%s'" % [where, id, pid])
		return
	if defs.has(id):
		errors.append("%s: '%s' is already defined in pack '%s'" % [where, id, defs[id]["pack"]])
		return
	d["pack"] = pid
	defs[id] = d


func _validate() -> void:
	for id: String in defs:
		var d: Dictionary = defs[id]
		match String(d.get("kind", "")):
			"item":
				if d.has("weapon"):
					_check_weapon(id, "weapon", d["weapon"], true)
				# A tool's power: the work a blow does (ADR-0026: iron does more).
				if d.has("power") and (typeof(d["power"]) not in [TYPE_INT, TYPE_FLOAT] or int(d["power"]) < 1):
					errors.append("%s: power is the work of a blow, at least 1" % id)
				# What worn armour takes off every blow (ADR-0029).
				if d.has("armor") and (typeof(d["armor"]) not in [TYPE_INT, TYPE_FLOAT] or int(d["armor"]) < 0 \
						or String(d.get("equip_slot", "")) in ["", "main_hand", "off_hand"]):
					errors.append("%s: armor is what a worn thing takes off a blow, 0 or more" % id)
				# A seed (ADR-0027): the plant it sows.
				if d.has("plants") and kind_of(String(d["plants"])) != "plant":
					errors.append("%s: plants names a plant" % id)
				# Food (ADR-0026): eaten, it heals.
				# Food heals, fills (ADR-0032 satiety), or both.
				if d.has("food") and (typeof(d["food"]) != TYPE_DICTIONARY or int(d["food"].get("heal", 0)) < 0
						or float(d["food"].get("satiety", 0)) < 0.0
						or int(d["food"].get("heal", 0)) + float(d["food"].get("satiety", 0)) <= 0.0):
					errors.append("%s: food needs heal or satiety above 0" % id)
				d["stack"] = int(d.get("stack", 1))
				if d["stack"] < 1:
					errors.append("%s: stack must be at least 1" % id)
				# What its blows do to parts of a material (ADR-0016): a pick
				# against stone; otherwise the part's toughness counts.
				var against: Variant = d.get("against", {})
				if typeof(against) != TYPE_DICTIONARY or (against as Dictionary).values().any(
						func(v: Variant) -> bool: return typeof(v) not in [TYPE_INT, TYPE_FLOAT] or v < 0):
					errors.append("%s: against maps a material to how much of a blow it takes" % id)
			"structure":
				# Natural parts (rock, cave ways) are found, not built: no cost.
				d["natural"] = bool(d.get("natural", false))
				if not d["natural"] or d.has("cost"):
					_check_amounts(id, "cost", d.get("cost", {}), true)
				d["role"] = String(d.get("role", "wall"))
				if not STRUCTURE_ROLES.has(d["role"]):
					errors.append("%s: unknown role '%s'" % [id, d["role"]])
				d["openable"] = bool(d.get("openable", false))
				d["rotations"] = _check_rotations(id, d.get("rotations", []))
				if d.has("light"):
					_check_light(id, d)
				_check_height(id, d, 1.0)
				if d.has("opening"):
					_check_opening(id, d)
				if d.has("gather"):
					_check_gather(id, d)
				# How much it takes before it breaks (ADR-0021); natural rock is dug, not broken.
				d["durability"] = int(d.get("durability", 0 if d["natural"] else 30))
				if d["durability"] < 0:
					errors.append("%s: durability must not be negative" % id)
				# What it is made of, and how much of a blow by a thing not made
				# for that material it takes (stone: little).
				d["material"] = String(d.get("material", ""))
				d["toughness"] = float(d.get("toughness", 1.0))
				if d["toughness"] < 0.0 or d["toughness"] > 1.0:
					errors.append("%s: toughness is the share of a blow it takes, 0..1" % id)
				if d.has("container"):
					var box: Variant = d["container"]
					if typeof(box) != TYPE_DICTIONARY or int(box.get("slots", 0)) < 1:
						errors.append("%s: a container needs {slots}" % id)
					else:
						box["slots"] = int(box["slots"])
				if d["role"] == "shaft" and not ["up", "down"].has(String(d.get("leads", ""))):
					errors.append("%s: a shaft leads up or down" % id)
				if d["role"] == "ceiling" and kind_of(String(d.get("floor", ""))) != "ground":
					errors.append("%s: a ceiling needs the floor (a ground) it makes above" % id)
			"recipe":
				_check_amounts(id, "inputs", d.get("inputs", {}), true)
				_check_amounts(id, "outputs", d.get("outputs", {}), true)
				# Made at a kind of station (ADR-0026), or in the hands.
				if d.has("station") and (typeof(d["station"]) != TYPE_STRING or String(d["station"]) == ""):
					errors.append("%s: station names a kind of station" % id)
			"body_plan":
				d["body_size"] = BodySize.parse(id, d.get("size"), errors)
				d["health"] = int(d.get("health", 20))
				var fall: Variant = d.get("fall_damage", [0, 2, 6, 12, 20])
				if typeof(fall) != TYPE_ARRAY or (fall as Array).is_empty() \
						or (fall as Array).any(func(n: Variant) -> bool: return typeof(n) not in [TYPE_INT, TYPE_FLOAT] or n < 0):
					errors.append("%s: fall_damage lists the hurt of a fall by levels fallen" % id)
				else:
					d["fall_damage"] = (fall as Array).map(func(n: Variant) -> int: return int(n))
				if d.has("unarmed"):
					_check_weapon(id, "unarmed", d["unarmed"], false)
				_check_strings(id, "slots", d.get("slots", []))
				_check_strings(id, "appearance_slots", d.get("appearance_slots", []), true)
				_check_strings(id, "colors", d.get("colors", []))
				var dirs := int(d.get("directions", 0))
				d["directions"] = dirs
				if dirs != 4 and dirs != 8:
					errors.append("%s: directions must be 4 or 8" % id)
			"style":
				if String(d.get("slot", "")) == "":
					errors.append("%s: a style needs a slot" % id)
				_check_refs(id, "body_plans", d.get("body_plans", []), "body_plan")
			"skill":
				d["max_level"] = int(d.get("max_level", 0))
				if d["max_level"] < 1:
					errors.append("%s: max_level must be at least 1" % id)
			"attribute":
				d["min"] = int(d.get("min", 0))
				d["max"] = int(d.get("max", 0))
				if d["max"] < d["min"]:
					errors.append("%s: max below min" % id)
			"achievement":
				pass
			"ground", "plant":
				d["solid"] = bool(d.get("solid", false))
				if d.has("gather"):
					_check_gather(id, d)
				_check_height(id, d, 1.0)
				# Fields (ADR-0027): what a ground is tilled into; how a crop grows.
				if d.has("tilled") and kind_of(String(d["tilled"])) != "ground":
					errors.append("%s: tilled names a ground" % id)
				if d.has("crop") and (typeof(d["crop"]) != TYPE_DICTIONARY or int(d["crop"].get("stages", 0)) < 2
						or float(d["crop"].get("grow_hours", 0)) <= 0.0):
					errors.append("%s: a crop has two stages or more and grows some hours" % id)
			"generator" when String(d.get("space", "surface")) == "underground":
				_check_underground(id, d)
			"deposit":
				if kind_of(String(d.get("rock", ""))) != "structure":
					errors.append("%s: a deposit's rock must be a structure part" % id)
				var depths: Variant = d.get("depths")
				if typeof(depths) != TYPE_ARRAY or (depths as Array).size() != 2 or int(depths[0]) > -1 or int(depths[1]) > int(depths[0]):
					errors.append("%s: depths are [top, bottom], both below the surface (-1, -2...), top first" % id)
				if not ["vein", "single"].has(String(d.get("shape", "vein"))):
					errors.append("%s: shape must be vein or single" % id)
				d["threshold"] = float(d.get("threshold", 0.0))
				if d["threshold"] <= 0.0 or d["threshold"] >= 1.0:
					errors.append("%s: threshold (how much of the rock it takes) must be within 0..1" % id)
			"generator":
				for f: String in ["water", "shore"]:
					if kind_of(String(d.get(f, ""))) != "ground":
						errors.append("%s: '%s' must be a ground" % [id, f])
				_check_weights(id, "shore_cover", d.get("shore_cover", {}), ["plant"], false)
				d["shore_cover_density"] = float(d.get("shore_cover_density", 0.0))
				d["spawn_clearing"] = int(d.get("spawn_clearing", 0))
				d["water_threshold"] = float(d.get("water_threshold", 0.5))
				d["shore_width"] = float(d.get("shore_width", 0.0))
			"visual":
				_check_visual(id, d)
			"sound":
				_check_sound(id, d)
			"biome":
				_check_weights(id, "ground", d.get("ground"), ["ground"])
				_check_weights(id, "cover", d.get("cover", {}), ["plant"], false)
				d["cover_density"] = float(d.get("cover_density", 0.0))
				if d["cover_density"] < 0.0 or d["cover_density"] > 1.0:
					errors.append("%s: cover_density must be within 0..1" % id)
				_check_weights(id, "fauna", d.get("fauna", {}), ["creature"], false)
				d["fauna_density"] = float(d.get("fauna_density", 0.0))  # creatures a chunk, on average
			"creature":
				_check_creature(id, d)
			var other:
				errors.append("%s: unknown kind '%s'" % [id, other])


## A living creature (ADR-0018): how it behaves is data, the code knows
## only the behaviours by name.
const BEHAVIORS := ["prey", "villager", "predator", "looter"]


func _check_creature(id: String, d: Dictionary) -> void:
	d["body_size"] = BodySize.parse(id, d.get("size"), errors)
	if not BEHAVIORS.has(String(d.get("behavior", ""))):
		errors.append("%s: behavior must be one of %s" % [id, ", ".join(BEHAVIORS)])
	for f: String in ["speed", "run_speed", "sight", "dark_sight", "hearing", "flee_distance", "home_radius", "memory_s"]:
		d[f] = float(d.get(f, 0.0))
		if d[f] < 0.0:
			errors.append("%s: %s must not be negative" % [id, f])
	d["think_ticks"] = maxi(1, int(d.get("think_ticks", 10)))
	d["fauna_since"] = maxi(1, int(d.get("fauna_since", 1)))  # CreatureSim.FAUNA_VERSION it came with
	d["health"] = int(d.get("health", 5))
	d["territory"] = float(d.get("territory", 0.0))
	if d["health"] < 1:
		errors.append("%s: health must be at least 1" % id)
	if d.has("attack"):
		_check_weapon(id, "attack", d["attack"], false)
	elif String(d.get("behavior", "")) == "predator":
		errors.append("%s: a predator needs an attack" % id)
	if d.has("drops"):
		_check_amounts(id, "drops", d["drops"], false)
	# A looter (ADR-0016): picks up what lies about, digests it in time.
	if String(d.get("behavior", "")) == "looter":
		d["digest_s"] = float(d.get("digest_s", 7200.0))
		d["stomach"] = int(d.get("stomach", 10))
		if d["digest_s"] <= 0.0 or d["stomach"] < 1:
			errors.append("%s: a looter needs digest_s above 0 and a stomach of at least 1 stack" % id)
	# Husbandry (ADR-0030): fed what it eats `feeds` times it is one's own;
	# fed, it breeds every breed_hours and gives its produce every hours.
	if d.has("tame"):
		var t: Variant = d["tame"]
		if typeof(t) != TYPE_DICTIONARY or typeof(t.get("food")) != TYPE_ARRAY or (t["food"] as Array).is_empty():
			errors.append("%s: tame needs {food: [items], feeds, breed_hours}" % id)
		else:
			_check_refs(id, "tame food", t["food"], "item")
			t["feeds"] = int(t.get("feeds", 1))
			t["breed_hours"] = float(t.get("breed_hours", 0.0))
			if t["feeds"] < 1 or t["breed_hours"] < 0.0:
				errors.append("%s: tame feeds at least 1, breed_hours not negative (0: it does not breed)" % id)
	if d.has("produce"):
		var pr: Variant = d["produce"]
		if typeof(pr) != TYPE_DICTIONARY or kind_of(String(pr.get("item", ""))) != "item" or float(pr.get("hours", 0)) <= 0.0 \
				or not d.has("tame"):
			errors.append("%s: produce needs {item, hours above 0} and a tame kind" % id)
		else:
			pr["hours"] = float(pr["hours"])
	if d["speed"] <= 0.0 or d["run_speed"] < d["speed"] or d["run_speed"] * Movement.WALK >= Movement.UNIT:
		errors.append("%s: speeds must be positive, running not slower, a step shorter than a cell" % id)
	if d["dark_sight"] > 1.0:
		errors.append("%s: dark_sight is a share, 0..1" % id)
	if d.has("body_plan") and kind_of(String(d["body_plan"])) != "body_plan":
		errors.append("%s: body_plan '%s' is not a body plan" % [id, d["body_plan"]])


## A light source (ADR-0014): {"radius" cells 1..8, "intensity" 0..1,
## "color" "#rrggbb"}. A rule: how light it is decides what creatures see.
func _check_light(id: String, d: Dictionary) -> void:
	var l: Variant = d["light"]
	if typeof(l) != TYPE_DICTIONARY:
		errors.append("%s: light must be {radius, intensity, color}" % id)
		return
	l["radius"] = float(l.get("radius", 0))
	l["intensity"] = float(l.get("intensity", 1.0))
	l["color"] = String(l.get("color", "#ffffff"))
	if l["radius"] <= 0.0 or l["radius"] > Lighting.MAX_RADIUS or l["intensity"] <= 0.0 or l["intensity"] > 1.0 \
			or not _color.search(String(l["color"])):
		errors.append("%s: light needs a radius of 1..%d cells, an intensity of 0..1 and a #rrggbb color" % [id, Lighting.MAX_RADIUS])


static var _color := RegEx.create_from_string("^#[0-9a-fA-F]{6}$")


## A way to hurt (ADR-0019): {"kind": "melee", "damage", "reach" cells,
## "arc" degrees, "cooldown_ms"} or, where ranged is allowed, {"kind":
## "ranged", "damage", "range" cells, "speed" cells a second, "ammo" item,
## "cooldown_ms"}.
func _check_weapon(id: String, field: String, w: Variant, ranged_ok: bool) -> void:
	if typeof(w) != TYPE_DICTIONARY:
		errors.append("%s: %s must be a weapon {kind, damage...}" % [id, field])
		return
	w["kind"] = String(w.get("kind", "melee"))
	# A tool one can strike with (a pick): not what Q snatches to fight.
	w["improvised"] = bool(w.get("improvised", false))
	w["damage"] = int(w.get("damage", 0))
	w["cooldown_ms"] = float(w.get("cooldown_ms", 800))
	if w["damage"] < 1 or w["cooldown_ms"] < 50.0:
		errors.append("%s: %s needs damage of at least 1 and a cooldown of at least 50 ms" % [id, field])
	match String(w["kind"]):
		"melee":
			w["reach"] = float(w.get("reach", 1.0))
			w["arc"] = float(w.get("arc", 90))
			if w["reach"] <= 0.0 or w["reach"] > 4.0 or w["arc"] <= 0.0 or w["arc"] > 360.0:
				errors.append("%s: %s needs a reach of up to 4 cells and an arc of up to 360 degrees" % [id, field])
		"ranged":
			if not ranged_ok:
				errors.append("%s: %s cannot be ranged" % [id, field])
			w["range"] = float(w.get("range", 0))
			w["speed"] = float(w.get("speed", 0))
			if w["range"] <= 0.0 or w["range"] > 64.0 or w["speed"] <= 0.0 or w["speed"] > 60.0:
				errors.append("%s: %s needs a range of up to 64 cells and a speed of up to 60 cells a second" % [id, field])
			if kind_of(String(w.get("ammo", ""))) != "item":
				errors.append("%s: %s shoots '%s', which is not an item" % [id, field, w.get("ammo", "")])
		_:
			errors.append("%s: %s kind must be melee or ranged" % [id, field])


## What is got from a part or a plant (ADR-0017, ADR-0021): rock dug, a tree
## felled. {"tool": the kind of tool to hold ("" bare hands), "verb": the
## action's name, "drops": {item: n}}. Any tool whose "tools" list has that
## kind does it: a new tool or a new thing to gather is data only.
func _check_gather(id: String, d: Dictionary) -> void:
	var g: Variant = d["gather"]
	# By luck (ADR-0031): a ground's chance a try, a pick by weight, a stock.
	if typeof(g) == TYPE_DICTIONARY and g.has("chance"):
		if kind_of(id) != "ground" or typeof(g.get("pick")) != TYPE_DICTIONARY or (g["pick"] as Dictionary).is_empty() \
				or typeof(g["chance"]) not in [TYPE_INT, TYPE_FLOAT] or float(g["chance"]) <= 0.0 or float(g["chance"]) > 1.0:
			errors.append("%s: a gather by luck is a ground's, with chance (0..1] and pick {item: weight}" % id)
			return
		_check_weights(id, "gather pick", g["pick"], ["item"])
		g["stock"] = float(g.get("stock", 5))
		g["restock_hours"] = float(g.get("restock_hours", 6))
		if g["stock"] <= 0.0 or g["restock_hours"] <= 0.0:
			errors.append("%s: gather stock and restock_hours must be positive" % id)
	if typeof(g) != TYPE_DICTIONARY:
		errors.append("%s: gather must be {tool, verb, drops}" % id)
		return
	g["tool"] = String(g.get("tool", ""))
	g["verb"] = String(g.get("verb", "Добыть"))
	_check_amounts(id, "gather drops", g.get("drops", {}), false)
	# Blows of the tool it takes (a big tree more than a thin one); 1: at once.
	g["work"] = int(g.get("work", 1))
	if g["work"] < 1:
		errors.append("%s: gather work is the blows it takes, at least 1" % id)


## The underground generator: its floor, rock, pool water, the parts at the
## ends of natural ways, how much is caves and how often a way goes down.
func _check_underground(id: String, d: Dictionary) -> void:
	for f: String in ["floor"]:
		if kind_of(String(d.get(f, ""))) != "ground":
			errors.append("%s: '%s' must be a ground" % [id, f])
	if d.has("water") and kind_of(String(d["water"])) != "ground":
		errors.append("%s: 'water' must be a ground" % id)
	for f: String in ["rock", "way_down_surface", "way_down", "way_up"]:
		if kind_of(String(d.get(f, ""))) != "structure":
			errors.append("%s: '%s' must be a structure part" % [id, f])
	_check_weights(id, "fauna", d.get("fauna", {}), ["creature"], false)
	d["fauna_density"] = float(d.get("fauna_density", 0.0))
	d["entrance_chance"] = float(d.get("entrance_chance", 0.0))
	if d["entrance_chance"] < 0.0 or d["entrance_chance"] > 1.0:
		errors.append("%s: entrance_chance is a share of chunks, 0..1" % id)


## How tall it stands, in levels (ADR-0015: sight is checked on the plan with
## the heights of what is in the way): a wall 1, a bush 0.7, a tree 2.
func _check_height(id: String, d: Dictionary, default: float) -> void:
	d["height"] = float(d.get("height", default))
	if d["height"] <= 0.0 or d["height"] > 4.0:
		errors.append("%s: height is in levels, above 0 and at most 4" % id)


## A window or a loophole (ADR-0015): {"sector" degrees 1..180, "range"
## cells}; it looks where the part faces, so the part must turn.
func _check_opening(id: String, d: Dictionary) -> void:
	var o: Variant = d["opening"]
	if typeof(o) != TYPE_DICTIONARY:
		errors.append("%s: opening must be {sector, range}" % id)
		return
	o["sector"] = float(o.get("sector", 0))
	o["range"] = float(o.get("range", 0))
	if o["sector"] < 1.0 or o["sector"] > 180.0 or o["range"] <= 0.0 or o["range"] > 64.0:
		errors.append("%s: an opening needs a sector of 1..180 degrees and a range of 1..64 cells" % id)
	if (d["rotations"] as Array).is_empty():
		errors.append("%s: an opening looks where the part faces: it needs rotations" % id)


## The facings a part may be built in: distinct, among n, e, s, w.
func _check_rotations(id: String, turns: Variant) -> Array:
	if typeof(turns) != TYPE_ARRAY:
		errors.append("%s: rotations must be a list of facings" % id)
		return []
	var seen := {}
	for f: Variant in turns:
		if not FACINGS.has(f) or seen.has(f):
			errors.append("%s: rotations must be distinct facings among n, e, s, w" % id)
			return []
		seen[f] = true
	return turns


func _check_amounts(id: String, field: String, amounts: Variant, required: bool) -> void:
	if typeof(amounts) != TYPE_DICTIONARY or (required and (amounts as Dictionary).is_empty()):
		errors.append("%s: '%s' must list items and counts" % [id, field])
		return
	for ref: Variant in amounts:
		amounts[ref] = int(amounts[ref])  # JSON numbers arrive as floats
		if kind_of(String(ref)) != "item":
			errors.append("%s: '%s' refers to '%s', which is not an item" % [id, field, ref])
		elif int(amounts[ref]) < 1:
			errors.append("%s: '%s' needs a positive count of '%s'" % [id, field, ref])


func _check_visual(id: String, d: Dictionary) -> void:
	if d.has("pixel_scale"):
		var value: Variant = d["pixel_scale"]
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)) or float(value) <= 0.0:
			errors.append("%s: pixel_scale must be a finite positive number" % id)
	var target := String(d.get("for", ""))
	if not defs.has(target) or kind_of(target) == "visual":
		errors.append("%s: draws '%s', which is not defined" % [id, target])
		return
	if not ["flat", "tall", "cover", "character", "item", "layer"].has(d.get("mode")):
		errors.append("%s: mode must be flat, tall, cover, character, item or layer" % id)
	var states: Variant = d.get("states", {})
	if typeof(states) != TYPE_DICTIONARY:
		errors.append("%s: states must map a state name to a rect" % id)
	else:
		for st: Variant in states:
			var rect: Variant = states[st]
			if typeof(rect) != TYPE_ARRAY or (rect as Array).size() != 4:
				errors.append("%s: state '%s' needs a rect" % [id, st])
			else:
				states[st] = (rect as Array).map(func(n: Variant) -> int: return int(n))
	# Pictures of a turned part (ADR-0013): facing -> rect; the default
	# facing is "rect" itself; "mirror": {"w": "e"} draws one flipped.
	var turned: Variant = d.get("rotations", {})
	if typeof(turned) != TYPE_DICTIONARY:
		errors.append("%s: rotations must map a facing to a rect" % id)
	else:
		for f: Variant in turned:
			var rect: Variant = turned[f]
			if not FACINGS.has(f) or typeof(rect) != TYPE_ARRAY or (rect as Array).size() != 4:
				errors.append("%s: rotation '%s' needs a facing and a rect" % [id, f])
			else:
				turned[f] = (rect as Array).map(func(n: Variant) -> int: return int(n))
	var mirror: Variant = d.get("mirror", {})
	if typeof(mirror) != TYPE_DICTIONARY or (mirror as Dictionary).keys().any(func(f: Variant) -> bool:
			return not FACINGS.has(f) or not FACINGS.has(mirror[f])):
		errors.append("%s: mirror must map a facing to the facing it flips" % id)
	for f: String in ["rect", "origin"]:
		var v: Variant = d.get(f)
		if typeof(v) != TYPE_ARRAY or (v as Array).size() != (4 if f == "rect" else 2):
			errors.append("%s: bad %s" % [id, f])
			return
		d[f] = (v as Array).map(func(n: Variant) -> int: return int(n))
	d["variants"] = maxi(1, int(d.get("variants", 1)))
	if d.has("grip"):
		var grip: Variant = d["grip"]
		if typeof(grip) != TYPE_ARRAY or (grip as Array).size() != 2 or (grip as Array).any(
				func(n: Variant) -> bool: return typeof(n) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(n))):
			errors.append("%s: grip needs finite x and y" % id)
		elif grip[0] < 0 or grip[0] >= d["rect"][2] or grip[1] < 0 or grip[1] >= d["rect"][3]:
			errors.append("%s: grip outside the frame" % id)
	# A ground drawn as an LPC terrain on cell corners (WorldView): its rank
	# over other grounds and how many fills follow its 15 corner tiles.
	if d.has("terrain"):
		var t: Variant = d["terrain"]
		if typeof(t) != TYPE_DICTIONARY or typeof(t.get("priority")) not in [TYPE_INT, TYPE_FLOAT] \
				or int(t.get("fills", 1)) < 1:
			errors.append("%s: terrain needs a whole priority and at least one fill" % id)
	# A seamless texture laid over grid[0] x grid[1] tiles (ground, roofs).
	if d.has("grid"):
		var g: Variant = d["grid"]
		if typeof(g) != TYPE_ARRAY or (g as Array).size() != 2 or int(g[0]) < 1 or int(g[1]) < 1:
			errors.append("%s: grid needs two positive numbers" % id)
		else:
			d["grid_size"] = Vector2i(int(g[0]), int(g[1]))
	var dir: String = packs.get(d["pack"], {}).get("dir", "")
	d["atlas_path"] = dir.path_join(String(d.get("atlas", ""))) if dir != "" else ""
	if dir != "" and not FileAccess.file_exists(d["atlas_path"]) and not ResourceLoader.exists(d["atlas_path"]):
		errors.append("%s: atlas %s not found" % [id, d["atlas_path"]])
	# A paper-doll layer (ADR-0001): a sheet on the body plan's frame grid.
	# A style is one ("mode": "layer"); a wearable item has one as "worn".
	if d.get("mode") == "layer" and String(d.get("layer", "")) == "":
		errors.append("%s: a layer needs the slot it is drawn in ('layer')" % id)
	# Optional per-frame wrists: [cell x, cell y, tool rotation in degrees].
	var hands: Variant = d.get("hands", {})
	if typeof(hands) != TYPE_DICTIONARY:
		errors.append("%s: hands must map directions to frame anchors" % id)
	else:
		for direction: Variant in hands:
			var row: Variant = hands[direction]
			if not ["s", "se", "e", "ne", "n"].has(direction) or typeof(row) != TYPE_ARRAY:
				errors.append("%s: bad hand direction or frame list" % id)
				continue
			for hand: Variant in row:
				if typeof(hand) != TYPE_ARRAY or (hand as Array).size() != 3 or (hand as Array).any(
						func(n: Variant) -> bool: return typeof(n) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(n))):
					errors.append("%s: a hand needs finite x, y and rotation" % id)
				elif hand[0] < 0 or hand[0] >= d["rect"][2] or hand[1] < 0 or hand[1] >= d["rect"][3]:
					errors.append("%s: hand outside the frame" % id)
	var hand_behind: Variant = d.get("hand_behind", {})
	if typeof(hand_behind) != TYPE_DICTIONARY:
		errors.append("%s: hand_behind must map directions to booleans" % id)
	else:
		for direction: Variant in hand_behind:
			if not ["s", "se", "e", "ne", "n"].has(direction) or typeof(hand_behind[direction]) != TYPE_BOOL:
				errors.append("%s: bad hand depth direction or boolean" % id)
	# Ground lapping over lower grounds: its edge shapes and its priority.
	var edges: Variant = d.get("edges")
	if edges != null:
		if typeof(edges) != TYPE_DICTIONARY or typeof(edges.get("masks")) != TYPE_ARRAY \
				or typeof(edges.get("rect")) != TYPE_ARRAY or not edges.has("priority"):
			errors.append("%s: edges need atlas, rect, masks and priority" % id)
		else:
			edges["rect"] = (edges["rect"] as Array).map(func(n: Variant) -> int: return int(n))
			edges["masks"] = (edges["masks"] as Array).map(func(n: Variant) -> int: return int(n))
			edges["priority"] = int(edges["priority"])
			edges["atlas_path"] = dir.path_join(String(edges.get("atlas", ""))) if dir != "" else ""
			if dir != "" and not FileAccess.file_exists(edges["atlas_path"]) and not ResourceLoader.exists(edges["atlas_path"]):
				errors.append("%s: atlas %s not found" % [id, edges["atlas_path"]])
	var overrides: Variant = d.get("worn_overrides", {})
	if typeof(overrides) != TYPE_DICTIONARY:
		errors.append("%s: worn_overrides must map items to fitted layers" % id)
		overrides = {}
	for item: Variant in overrides:
		if kind_of(String(item)) != "item":
			errors.append("%s: fitted layer for unknown item '%s'" % [id, item])
	var worn_layers: Array = overrides.values()
	var styles: Variant = d.get("style_overrides", {})
	if typeof(styles) != TYPE_DICTIONARY:
		errors.append("%s: style_overrides must map styles to fitted layers" % id)
		styles = {}
	for style: String in styles:
		if kind_of(style) != "style":
			errors.append("%s: fitted layer for unknown style '%s'" % [id, style])
	worn_layers.append_array(styles.values())
	if d.has("worn"):
		worn_layers.append(d["worn"])
	# Things in the hands drawn with their own frames (LPC tools and weapons).
	var held: Variant = d.get("held_overrides", {})
	if typeof(held) != TYPE_DICTIONARY:
		errors.append("%s: held_overrides must map items to layers" % id)
		held = {}
	for item: Variant in held:
		if kind_of(String(item)) != "item":
			errors.append("%s: held layer for unknown item '%s'" % [id, item])
	worn_layers.append_array(held.values())
	if d.get("format") == "lpc":
		_check_lpc(id, d, dir)
	for worn: Variant in worn_layers:
		if typeof(worn) == TYPE_DICTIONARY and worn.has("sheets") and String(worn.get("layer", "")) != "":
			for sheet: Variant in worn["sheets"]:
				_check_sheet(id, sheet, dir)
		elif typeof(worn) != TYPE_DICTIONARY or String(worn.get("atlas", "")) == "" or String(worn.get("layer", "")) == "":
			errors.append("%s: worn needs atlas and layer" % id)
		else:
			worn["atlas_path"] = dir.path_join(String(worn["atlas"])) if dir != "" else ""
			if dir != "" and not FileAccess.file_exists(worn["atlas_path"]) and not ResourceLoader.exists(worn["atlas_path"]):
				errors.append("%s: atlas %s not found" % [id, worn["atlas_path"]])
	# Other pictures of the same thing (two spruces, kinds of grass): the
	# view picks one by the cell, so it is the same for every player.
	var alts: Variant = d.get("alternates", [])
	if typeof(alts) != TYPE_ARRAY:
		errors.append("%s: alternates must be a list" % id)
		alts = []
	for alt: Variant in alts:
		if typeof(alt) != TYPE_DICTIONARY or typeof(alt.get("rect")) != TYPE_ARRAY or (alt["rect"] as Array).size() != 4 \
				or typeof(alt.get("origin")) != TYPE_ARRAY or (alt["origin"] as Array).size() != 2:
			errors.append("%s: an alternate needs atlas, rect and origin" % id)
			continue
		alt["rect"] = (alt["rect"] as Array).map(func(n: Variant) -> int: return int(n))
		alt["origin"] = (alt["origin"] as Array).map(func(n: Variant) -> int: return int(n))
		alt["atlas_path"] = dir.path_join(String(alt.get("atlas", d.get("atlas", "")))) if dir != "" else ""
		if dir != "" and not FileAccess.file_exists(alt["atlas_path"]) and not ResourceLoader.exists(alt["atlas_path"]):
			errors.append("%s: atlas %s not found" % [id, alt["atlas_path"]])
	d["alternates"] = alts
	var old: Dictionary = visuals.get(target, {})
	if old.is_empty() or _pack_order(d["pack"]) >= _pack_order(old["pack"]):
		visuals[target] = d


## A body drawn from LPC layers (tools/art/import_lpc.py): its own sheet,
## the palettes it recolours by, rows of directions, animations as frames
## of its sheets and the animation of each kind of swing.
func _check_lpc(id: String, d: Dictionary, dir: String) -> void:
	_check_sheet(id, d, dir)
	if d.has("palettes"):  # what it recolours by (people; animals keep their colours)
		d["palettes_path"] = dir.path_join(String(d["palettes"])) if dir != "" else ""
		if dir != "" and not FileAccess.file_exists(d["palettes_path"]):
			errors.append("%s: palettes %s not found" % [id, d["palettes_path"]])
	if d.get("rows") != ["n", "w", "s", "e"]:
		errors.append("%s: rows must be n, w, s, e" % id)
	var animations: Variant = d.get("animations")
	if typeof(animations) != TYPE_DICTIONARY or not ["idle", "walk"].all(func(a: String) -> bool: return animations.has(a)):
		errors.append("%s: animations need idle and walk" % id)
		return
	for a: String in animations:
		var an: Variant = animations[a]
		if typeof(an) != TYPE_DICTIONARY or typeof(an.get("frames")) != TYPE_ARRAY or (an["frames"] as Array).is_empty() \
				or typeof(an.get("fps")) not in [TYPE_INT, TYPE_FLOAT] or float(an["fps"]) <= 0.0:
			errors.append("%s: animation '%s' needs frames and fps" % [id, a])
	for kind: Variant in d.get("swings", {}):
		if not animations.has(d["swings"][kind]):
			errors.append("%s: swing '%s' plays an unknown animation" % [id, kind])


## One LPC layer: an atlas of animations, each [x, y, frame size, frames]
## over four rows of directions.
func _check_sheet(id: String, sheet: Variant, dir: String) -> void:
	if typeof(sheet) != TYPE_DICTIONARY or String(sheet.get("atlas", "")) == "" or typeof(sheet.get("anims")) != TYPE_DICTIONARY:
		errors.append("%s: a sheet needs atlas and anims" % id)
		return
	sheet["atlas_path"] = dir.path_join(String(sheet["atlas"])) if dir != "" else ""
	if dir != "" and not FileAccess.file_exists(sheet["atlas_path"]) and not ResourceLoader.exists(sheet["atlas_path"]):
		errors.append("%s: atlas %s not found" % [id, sheet["atlas_path"]])
	for a: String in sheet["anims"]:
		var r: Variant = sheet["anims"][a]
		if typeof(r) != TYPE_ARRAY or not (r as Array).size() in [4, 5] \
				or (r as Array).slice(0, 4).any(func(n: Variant) -> bool: return typeof(n) not in [TYPE_INT, TYPE_FLOAT]):
			errors.append("%s: sheet animation '%s' needs x, y, size and frames" % [id, a])
			continue
		var out: Array = (r as Array).slice(0, 4).map(func(n: Variant) -> int: return int(n))
		# Columns of another animation, played in this order (LPC's own
		# timelines: a rod's cast is the body's thrust).
		if (r as Array).size() == 5:
			var columns: Variant = r[4]
			if typeof(columns) != TYPE_ARRAY or (columns as Array).is_empty() or (columns as Array).any(func(n: Variant) -> bool:
					return typeof(n) not in [TYPE_INT, TYPE_FLOAT] or int(n) < 0 or int(n) >= out[3]):
				errors.append("%s: sheet animation '%s' borrows columns it does not have" % [id, a])
				continue
			out.append((columns as Array).map(func(n: Variant) -> int: return int(n)))
		sheet["anims"][a] = out
	sheet["z"] = int(sheet.get("z", 0))


## The sound of an event for a thing: its own, else the general one ("*").
func sound_of(id: String, event: String) -> Dictionary:
	var own: Dictionary = sounds.get(id, {}).get(event, {})
	return own if not own.is_empty() else sounds.get("*", {}).get(event, {})


func _check_sound(id: String, d: Dictionary) -> void:
	var target := String(d.get("for", ""))
	if target != "*" and (not defs.has(target) or PRESENTATION_KINDS.has(kind_of(target))):
		errors.append("%s: sounds for '%s', which is not defined" % [id, target])
		return
	var event := String(d.get("event", ""))
	if not SOUND_EVENTS.has(event):
		errors.append("%s: event must be one of %s" % [id, ", ".join(SOUND_EVENTS)])
		return
	var files: Variant = d.get("files")
	if typeof(files) != TYPE_ARRAY or (files as Array).is_empty():
		errors.append("%s: a sound needs files" % id)
		return
	var dir: String = packs.get(d["pack"], {}).get("dir", "")
	var paths := PackedStringArray()
	for f: Variant in files:
		var path := dir.path_join(String(f)) if dir != "" else String(f)
		if dir != "" and not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
			errors.append("%s: file %s not found" % [id, path])
		paths.append(path)
	d["paths"] = paths
	d["volume_db"] = float(d.get("volume_db", 0.0))
	var pitch: Variant = d.get("pitch", [1.0, 1.0])
	d["pitch"] = [float(pitch[0]), float(pitch[1])] if typeof(pitch) == TYPE_ARRAY and (pitch as Array).size() == 2 else [1.0, 1.0]
	d["loop"] = bool(d.get("loop", false))
	var by_event: Dictionary = sounds.get(target, {})
	var old: Dictionary = by_event.get(event, {})
	if old.is_empty() or _pack_order(d["pack"]) >= _pack_order(old["pack"]):
		by_event[event] = d
	sounds[target] = by_event


func _pack_order(pid: String) -> int:
	return packs.keys().find(pid)


## {content id: weight} where every id is one of `kinds`; weights become floats.
func _check_weights(id: String, field: String, weights: Variant, kinds: Array, required := true) -> void:
	if typeof(weights) != TYPE_DICTIONARY or (required and (weights as Dictionary).is_empty()):
		errors.append("%s: '%s' must map ids to weights" % [id, field])
		return
	for ref: Variant in weights:
		weights[ref] = float(weights[ref])
		if not kinds.has(kind_of(String(ref))):
			errors.append("%s: '%s' refers to '%s', which is not a %s" % [id, field, ref, "/".join(kinds)])
		elif float(weights[ref]) <= 0.0:
			errors.append("%s: '%s' weight of '%s' must be positive" % [id, field, ref])


func _check_strings(id: String, field: String, list: Variant, allow_empty := false) -> void:
	if typeof(list) != TYPE_ARRAY or (not allow_empty and (list as Array).is_empty()):
		errors.append("%s: '%s' must be a %slist" % [id, field, "" if allow_empty else "non-empty "])
		return
	for v: Variant in list:
		if typeof(v) != TYPE_STRING or String(v) == "":
			errors.append("%s: '%s' has a bad entry" % [id, field])


func _check_refs(id: String, field: String, list: Variant, kind: String) -> void:
	if typeof(list) != TYPE_ARRAY or (list as Array).is_empty():
		errors.append("%s: '%s' must list %s ids" % [id, field, kind])
		return
	for v: Variant in list:
		if kind_of(String(v)) != kind:
			errors.append("%s: '%s' refers to '%s', which is not a %s" % [id, field, v, kind])


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		errors.append("%s: missing" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s: not a JSON object" % path)
		return {}
	return parsed
