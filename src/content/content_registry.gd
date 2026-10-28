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
## "effects": what a thing gives off on the screen ({flames|sparks|smoke|embers: [x, y]
## world pixels from its cell's bottom middle}).
## "ambient": life over a ground or plant (fireflies, mist, drift, leaves).
## "winter": the ground it is drawn as in winter (under snow).
const PRESENTATION_FIELDS := ["name", "description", "effects", "ambient", "winter"]
## Fields the registry adds while loading.
const DERIVED_FIELDS := ["pack", "atlas_path", "paths", "body_size"]
## Kinds that only show or sound, never rule.
const PRESENTATION_KINDS := ["visual", "sound"]
## What a sound answers to (sounds.json, ADR-0009).
const SOUND_EVENTS := ["step", "build", "dismantle", "open", "close", "pickup", "drop", "climb", "click", "ambience", "wind",
	"swing", "hit", "shoot", "fill", "pour", "drink", "eat", "splash", "till", "sow", "craft", "gather", "thunder",
	"rain", "equip", "sleep", "feed", "voice", "attack", "chase", "death"]
## What a structure part is for (ADR-0007). Columns and beams are decoration.
const STRUCTURE_ROLES := ["wall", "door", "window", "fence", "column", "beam", "ceiling", "roof", "stairs", "furniture", "floor",
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
				if d.has("light"):  # carried, it lights round the one who holds it
					_check_light(id, d)
				if d.has("weapon"):
					_check_weapon(id, "weapon", d["weapon"], true)
				# A tool's power: the work a blow does (ADR-0026: iron does more).
				if d.has("power") and (typeof(d["power"]) not in [TYPE_INT, TYPE_FLOAT] or int(d["power"]) < 1):
					errors.append("%s: power is the work of a blow, at least 1" % id)
				# A liquid in a container (ADR-0037): poured out, the empty one is left.
				if d.has("liquid") and (typeof(d["liquid"]) != TYPE_DICTIONARY or kind_of(String(d["liquid"].get("empty", ""))) != "item"):
					errors.append("%s: liquid needs {empty: the container left}" % id)
				# What worn armour takes off every blow (ADR-0029).
				if d.has("armor") and (typeof(d["armor"]) not in [TYPE_INT, TYPE_FLOAT] or int(d["armor"]) < 0 \
						or String(d.get("equip_slot", "")) in ["", "main_hand", "off_hand"]):
					errors.append("%s: armor is what a worn thing takes off a blow, 0 or more" % id)
				# What keeps the cold off (ADR-0034).
				if d.has("warmth") and (typeof(d["warmth"]) not in [TYPE_INT, TYPE_FLOAT] or int(d["warmth"]) < 0 \
						or String(d.get("equip_slot", "")) in ["", "main_hand", "off_hand"]):
					errors.append("%s: warmth is what a worn thing keeps off the cold, 0 or more" % id)
				# A seed (ADR-0027): the plant it sows.
				if d.has("plants") and kind_of(String(d["plants"])) != "plant":
					errors.append("%s: plants names a plant" % id)
				# A sapling to plant (ADR-0056): the plant it becomes in the ground.
				if d.has("seedling") and kind_of(String(d["seedling"])) != "plant":
					errors.append("%s: seedling names the plant it is planted as" % id)
				# Food (ADR-0026): eaten, it heals.
				# Food heals, fills (ADR-0032 satiety), or both.
				if d.has("food") and (typeof(d["food"]) != TYPE_DICTIONARY or int(d["food"].get("heal", 0)) < 0
						or float(d["food"].get("satiety", 0)) < 0.0
						or int(d["food"].get("heal", 0)) + float(d["food"].get("satiety", 0)) <= 0.0):
					errors.append("%s: food needs heal or satiety above 0" % id)
				d["stack"] = int(d.get("stack", 1))
				if d["stack"] < 1:
					errors.append("%s: stack must be at least 1" % id)
				# Things of their own (ADR-0048): what is worn, held, worked with or
				# set up is a copy of its own, never a stack.
				if d["stack"] != 1 and (d.has("equip_slot") or d.has("tools") or d.has("weapon") or d.has("armor")
						or d.has("warmth") or d.has("places") or d.has("liquid") or d.has("durability") or d.has("vessel")):
					errors.append("%s: a thing of its own (worn, held, set up) is not stacked: stack 1" % id)
				# A boat (ADR-0052): how many sit in it, how fast it goes (units a
				# tick: less than a cell).
				if d.has("vessel"):
					var v: Variant = d["vessel"]
					if typeof(v) != TYPE_DICTIONARY or int(v.get("seats", 0)) < 1 or int(v.get("speed", 0)) < 1 \
							or int(v.get("speed", 0)) >= Movement.UNIT:
						errors.append("%s: a vessel has seats (1 or more) and a speed (1..%d)" % [id, Movement.UNIT - 1])
					else:
						d["vessel"] = {"seats": int(v["seats"]), "speed": int(v["speed"])}
				# Furniture carried and set up (ADR-0048): the part it becomes, which costs it.
				if d.has("places") and (kind_of(String(d["places"])) != "structure" or structure_cost(String(d["places"])).size() != 1
						or int(structure_cost(String(d["places"])).get(id, 0)) != 1):
					errors.append("%s: places a part that costs just this thing" % id)
				# Wear (ADR-0046): uses a copy lasts; mended at a station for materials.
				if d.has("durability") and (typeof(d["durability"]) not in [TYPE_INT, TYPE_FLOAT] or int(d["durability"]) < 1 or d["stack"] != 1):
					errors.append("%s: durability is the uses a thing of a stack of 1 lasts, 1 or more" % id)
				if d.has("repair"):
					var mend: Variant = d["repair"]
					if typeof(mend) != TYPE_DICTIONARY or not d.has("durability") \
							or (mend.has("station") and (typeof(mend["station"]) != TYPE_STRING or String(mend["station"]) == "")):
						errors.append("%s: repair is {station, materials} of a thing that wears" % id)
					else:
						_check_amounts(id, "repair materials", mend.get("materials", {}), true)
						if (mend.get("materials", {}) as Dictionary).has(id):
							errors.append("%s: a thing is not mended with itself" % id)
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
				if d["role"] == "floor" and kind_of(String(d.get("ground", ""))) != "ground":
					errors.append("%s: a floor names the ground it lays" % id)
				d["rotations"] = _check_rotations(id, d.get("rotations", []))
				if d.has("light"):
					_check_light(id, d)
				if d.has("bed") and typeof(d["bed"]) != TYPE_BOOL:
					errors.append("%s: bed is true or false (one sleeps on it, ADR-0035)" % id)
				if d.has("heat") and (typeof(d["heat"]) not in [TYPE_INT, TYPE_FLOAT] or float(d["heat"]) < 0.0):
					errors.append("%s: heat is the warmth a part gives near it an hour, 0 or more" % id)
				_check_height(id, d, 1.0)
				if d.has("opening"):
					_check_opening(id, d)
				if d.has("gather"):
					_check_gather(id, d)
				# What mending it takes when it is not what it cost (furniture set up, ADR-0048).
				if d.has("repair_cost"):
					_check_amounts(id, "repair_cost", d["repair_cost"], true)
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
				# Knowledge (ADR-0047): its skill, how hard it is, whether all know it.
				d["difficulty"] = int(d.get("difficulty", 30))
				if d["difficulty"] < 0 or d["difficulty"] > 100:
					errors.append("%s: difficulty is 0..100" % id)
				d["innate"] = bool(d.get("innate", false))
				if d.has("skill") and kind_of(String(d["skill"])) != "skill":
					errors.append("%s: skill '%s' is not a skill" % [id, d["skill"]])
			"modifier":
				# An enhancement a master's thing may come with (ADR-0047).
				if typeof(d.get("fits")) != TYPE_ARRAY or (d["fits"] as Array).is_empty() \
						or (d["fits"] as Array).any(func(k: Variant) -> bool: return not String(k) in ["tool", "weapon", "armor", "clothes", "furniture"]):
					errors.append("%s: fits lists tool, weapon, armor, clothes, furniture" % id)
				var fx: Variant = d.get("effects", {})
				if typeof(fx) != TYPE_DICTIONARY or (fx as Dictionary).keys().any(
						func(k: Variant) -> bool: return not String(k) in ["durability", "pace", "damage", "armor", "warmth", "yield"]):
					errors.append("%s: effects are durability, pace, damage, armor, warmth, yield" % id)
				d["value"] = float(d.get("value", 1.2))
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
				# What practises it (ADR-0047) and what it gives at its height.
				_check_strings(id, "trained_by", d.get("trained_by", []), true)
				var fx: Variant = d.get("effects", {})
				if typeof(fx) != TYPE_DICTIONARY or (fx as Dictionary).keys().any(
						func(k: Variant) -> bool: return not String(k) in ["pace", "wear", "chance", "damage", "yield"]):
					errors.append("%s: skill effects are pace, wear, chance, damage, yield" % id)
			"attribute":
				d["min"] = int(d.get("min", 0))
				d["max"] = int(d.get("max", 0))
				if d["max"] < d["min"]:
					errors.append("%s: max below min" % id)
			"achievement":
				pass
			"ground", "plant":
				_check_winter(id, d)
				_check_fills(id, d)
				d["solid"] = bool(d.get("solid", false))
				# Water (ADR-0050, ADR-0051): one swims in it; wades (no running);
				# how much harder than common water swimming in it is.
				d["swim"] = bool(d.get("swim", false))
				d["wade"] = bool(d.get("wade", false))
				d["effort"] = float(d.get("effort", 1.0))
				if d["effort"] < 1.0:
					errors.append("%s: effort (how hard swimming in it is) is 1 or more" % id)
				if d.has("gather"):
					_check_gather(id, d)
				_check_height(id, d, 1.0)
				# Fields (ADR-0027): what a ground is tilled into; how a crop grows.
				if d.has("tilled") and kind_of(String(d["tilled"])) != "ground":
					errors.append("%s: tilled names a ground" % id)
				# Plants live (ADR-0056): picked, one comes back in "regrows" hours;
				# what "grows" turns into another plant in its hours ("@species":
				# the tree it was sown of).
				if d.has("regrows") and (typeof(d["regrows"]) not in [TYPE_INT, TYPE_FLOAT] or float(d["regrows"]) <= 0.0):
					errors.append("%s: regrows is the hours a picked one takes to come back, above 0" % id)
				if d.has("grows"):
					var gr: Variant = d["grows"]
					if typeof(gr) != TYPE_DICTIONARY or float(gr.get("hours", 0)) <= 0.0 \
							or (String(gr.get("into", "")) != "@species" and kind_of(String(gr.get("into", ""))) != "plant"):
						errors.append("%s: grows is {into: a plant or @species, hours above 0}" % id)
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
				# How rich under lowland, hills, mountains (ADR-0053).
				var relief: Variant = d.get("relief", [1.0, 1.0, 1.0])
				if typeof(relief) != TYPE_ARRAY or (relief as Array).size() != 3 \
						or (relief as Array).any(func(v: Variant) -> bool: return typeof(v) not in [TYPE_INT, TYPE_FLOAT] or float(v) < 0.0):
					errors.append("%s: relief is [lowland, hills, mountains], each 0 or more" % id)
					relief = [1.0, 1.0, 1.0]
				d["relief"] = [float(relief[0]), float(relief[1]), float(relief[2])]
				if d["threshold"] <= 0.0 or d["threshold"] >= 1.0:
					errors.append("%s: threshold (how much of the rock it takes) must be within 0..1" % id)
			"generator":
				for f: String in ["water", "shore"]:
					if kind_of(String(d.get(f, ""))) != "ground":
						errors.append("%s: '%s' must be a ground" % [id, f])
				# Water one wades through and deep water (ADR-0051), if any.
				for f: String in ["shallows", "deep"]:
					if d.has(f) and kind_of(String(d[f])) != "ground":
						errors.append("%s: '%s' must be a ground" % [id, f])
				_check_weights(id, "shore_cover", d.get("shore_cover", {}), ["plant"], false)
				d["shore_cover_density"] = float(d.get("shore_cover_density", 0.0))
				d["spawn_clearing"] = int(d.get("spawn_clearing", 0))
				# A flat world: all dry land of one height, no sea, rivers nor
				# heights (worlds made for a purpose, tests).
				d["flat"] = bool(d.get("flat", false))
				# What the heights are made of (ADR-0049).
				if d.has("rock") and kind_of(String(d["rock"])) != "structure":
					errors.append("%s: rock must be a part (natural rock)" % id)
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
				# Where it lies: [warmth, wetness], each -1..1; a place has the
				# biome whose climate is nearest its own (SurfaceGenerator).
				var climate: Variant = d.get("climate", [0.0, 0.0])
				if typeof(climate) != TYPE_ARRAY or (climate as Array).size() != 2 \
						or absf(float(climate[0])) > 1.0 or absf(float(climate[1])) > 1.0:
					errors.append("%s: climate is [warmth, wetness], each within -1..1" % id)
					climate = [0.0, 0.0]
				d["climate"] = [float(climate[0]), float(climate[1])]  # plain numbers: rules are CBOR (fingerprint)
				# The heights it lies at (ADR-0049: about -1..1, the sea at 0) and
				# whether it needs wet lowland by water (a swamp).
				var span: Variant = d.get("elevation", [-1.0, 2.0])
				if typeof(span) != TYPE_ARRAY or (span as Array).size() != 2 or float(span[0]) > float(span[1]):
					errors.append("%s: elevation is [lowest, highest]" % id)
					span = [-1.0, 2.0]
				d["elevation"] = [float(span[0]), float(span[1])]
				d["wet_lowland"] = bool(d.get("wet_lowland", false))
			"creature":
				_check_creature(id, d)
			"settlement":
				_check_settlement(id, d)
			"profession":
				_check_profession(id, d)
			"names":
				for f: String in ["male", "female", "villages"]:
					if typeof(d.get(f)) != TYPE_ARRAY or (d[f] as Array).is_empty():
						errors.append("%s: names need lists male, female and villages" % id)
			"story":
				_check_story(id, d)
			var other:
				errors.append("%s: unknown kind '%s'" % [id, other])


## A living creature (ADR-0018): how it behaves is data, the code knows
## only the behaviours by name.
const BEHAVIORS := ["prey", "villager", "predator", "looter"]


## A kind of settlement (ADR-0038): where it may be, how many houses, what
## it is built of, its buildings (their size, furniture, who lives there),
## fields and a pen. The generator only lays them out.
func _check_settlement(id: String, d: Dictionary) -> void:
	# Styles by biome (ADR-0038): what is built otherwise where its middle
	# lies in one of "biomes" — each must make a whole settlement too.
	var styles: Variant = d.get("styles", [])
	if typeof(styles) != TYPE_ARRAY:
		errors.append("%s: styles is a list of {biomes, ...what differs}" % id)
		styles = []
	for st: Variant in styles:
		if typeof(st) != TYPE_DICTIONARY or typeof((st as Dictionary).get("biomes")) != TYPE_ARRAY:
			errors.append("%s: a style needs biomes" % id)
			continue
		_check_refs(id, "style biomes", st["biomes"], "biome")
		var whole := d.duplicate(true)
		whole.erase("styles")
		whole.merge((st as Dictionary).duplicate(true), true)
		whole.erase("biomes")
		_check_settlement(id + " (style)", whole)
	# Clusters (ADR-0054): districts of district_chunks; a cluster of
	# villages [least, most] in cluster_chance of them, within spread cells
	# of its first; joined with a neighbouring cluster by link_chance.
	d["district_chunks"] = int(d.get("district_chunks", 24))
	d["cluster_chance"] = float(d.get("cluster_chance", 0.0))
	d["link_chance"] = float(d.get("link_chance", 0.0))
	d["spread"] = int(d.get("spread", 300))
	if d["district_chunks"] < 8 or d["cluster_chance"] < 0.0 or d["cluster_chance"] > 1.0 \
			or d["link_chance"] < 0.0 or d["link_chance"] > 1.0 or d["spread"] < Settlements.APART:
		errors.append("%s: district_chunks at least 8, cluster_chance and link_chance within 0..1, spread at least %d" % [id, Settlements.APART])
	var count: Variant = d.get("villages", [1, 1])
	if typeof(count) != TYPE_ARRAY or (count as Array).size() != 2 or int(count[0]) < 1 or int(count[1]) < int(count[0]):
		errors.append("%s: villages is [least, most] in a cluster, at least one" % id)
	# Ways of life by the place (ADR-0054): the first whose "near" fits.
	var ways: Variant = d.get("ways", [])
	if typeof(ways) != TYPE_ARRAY:
		errors.append("%s: ways is a list" % id)
		ways = []
	var ids := (d.get("buildings", []) as Array).map(func(b: Variant) -> String:
		return String(b.get("id", "")) if typeof(b) == TYPE_DICTIONARY else "")
	for w: Variant in ways:
		if typeof(w) != TYPE_DICTIONARY or String(w.get("id", "")) == "" \
				or not String(w.get("near", "")) in ["", "water", "mountains", "grassland"] \
				or typeof(w.get("buildings", {})) != TYPE_DICTIONARY \
				or (w.get("buildings", {}) as Dictionary).keys().any(func(b: Variant) -> bool: return not ids.has(b)) \
				or (w.has("first") and not ids.has(w["first"])):
			errors.append("%s: a way has an id, near (water, mountains, grassland or none), its buildings and first building by id" % id)
	var houses: Variant = d.get("houses")
	if typeof(houses) != TYPE_ARRAY or (houses as Array).size() != 2 or int(houses[0]) < 1 or int(houses[1]) < int(houses[0]):
		errors.append("%s: houses is [least, most], at least one" % id)
	if d.has("bridge") and kind_of(String(d["bridge"])) != "ground":
		errors.append("%s: 'bridge' must be a ground" % id)
	for f: String in ["road", "floor"]:
		if kind_of(String(d.get(f, ""))) != "ground":
			errors.append("%s: '%s' must be a ground" % [id, f])
	for f: String in ["wall", "door", "window", "roof", "square"]:
		if kind_of(String(d.get(f, ""))) != "structure":
			errors.append("%s: '%s' must be a part" % [id, f])
	var buildings: Variant = d.get("buildings")
	if typeof(buildings) != TYPE_ARRAY or (buildings as Array).is_empty():
		errors.append("%s: buildings must list at least one" % id)
		return
	for b: Variant in buildings:
		var size: Variant = b.get("size") if typeof(b) == TYPE_DICTIONARY else null
		if typeof(size) != TYPE_ARRAY or (size as Array).size() != 2 or int(size[0]) < 4 or int(size[1]) < 4 \
				or int(size[0]) > 12 or int(size[1]) > 10 or String(b.get("dweller", "")) == "":
			errors.append("%s: a building needs a size of 4..12 by 4..10 and a dweller" % id)
			continue
		_check_refs(id, "furniture", b.get("furniture", []), "structure")
		if kind_of(String(b["dweller"])) != "profession":
			errors.append("%s: a building's dweller '%s' is not a profession" % [id, b["dweller"]])
		if (b.get("furniture", []) as Array).size() > int(size[0]) - 2:
			errors.append("%s: more furniture than fits along a building's back wall" % id)
	var fields: Dictionary = d.get("fields", {})
	if not fields.is_empty():
		if kind_of(String(fields.get("ground", ""))) != "ground":
			errors.append("%s: fields' ground must be a ground" % id)
		_check_weights(id, "fields' crops", fields.get("crops", {}), ["plant"])
	var pen: Dictionary = d.get("pen", {})
	if not pen.is_empty():
		for f: String in ["fence", "gate"]:
			if kind_of(String(pen.get(f, ""))) != "structure":
				errors.append("%s: the pen's '%s' must be a part" % [id, f])
		_check_weights(id, "pen's animals", pen.get("animals", {}), ["creature"], false)


## A villager's trade (ADR-0039): where it works ("field", "pen", "water",
## "station:<kind>" — a station of that kind in its home), from which hour to
## which, what it holds while at it, what it says (by situation).
func _check_profession(id: String, d: Dictionary) -> void:
	var work := String(d.get("work", ""))
	if not (work in ["field", "pen", "water"] or (work.begins_with("station:") and work.length() > 8)):
		errors.append("%s: work is field, pen, water or station:<kind>" % id)
	var hours: Variant = d.get("hours")
	if typeof(hours) != TYPE_ARRAY or (hours as Array).size() != 2 or float(hours[0]) < 0.0 or float(hours[1]) > 24.0 \
			or float(hours[0]) >= float(hours[1]):
		errors.append("%s: hours is [from, to] within a day" % id)
	if String(d.get("holds", "")) != "" and kind_of(String(d["holds"])) != "item":
		errors.append("%s: holds '%s', which is not an item" % [id, d["holds"]])
	# What it trades (ADR-0040): sells {item: [a day's stock, price]}, buys
	# {item: price}, a purse for a day; prices in coins.
	var trade: Variant = d.get("trade", {})
	if typeof(trade) != TYPE_DICTIONARY:
		errors.append("%s: trade is {sells, buys, purse}" % id)
	elif not (trade as Dictionary).is_empty():
		trade["purse"] = int(trade.get("purse", 0))
		for item: Variant in trade.get("sells", {}):
			var v: Variant = trade["sells"][item]
			if kind_of(String(item)) != "item" or typeof(v) != TYPE_ARRAY or (v as Array).size() != 2 or int(v[0]) < 1 or int(v[1]) < 1:
				errors.append("%s: sells '%s' needs an item and [stock, price], both at least 1" % [id, item])
		for item: Variant in trade.get("buys", {}):
			if kind_of(String(item)) != "item" or typeof(trade["buys"][item]) not in [TYPE_INT, TYPE_FLOAT] or int(trade["buys"][item]) < 1:
				errors.append("%s: buys '%s' needs an item and a price of at least 1" % [id, item])
		# Blueprints it sells (ADR-0047): {recipe: price}; the quality of its goods.
		for r: Variant in trade.get("blueprints", {}):
			if kind_of(String(r)) != "recipe" or int(trade["blueprints"][r]) < 1:
				errors.append("%s: blueprints '%s' needs a recipe and a price" % [id, r])
		var q: Variant = trade.get("quality", [1.0, 1.0])
		if typeof(q) != TYPE_ARRAY or (q as Array).size() != 2 or float(q[0]) < Mastery.WORST_QUALITY or float(q[1]) > 1.0 or float(q[0]) > float(q[1]):
			errors.append("%s: quality is [from, to] within 0.5..1" % id)
	# What it teaches (ADR-0047): {recipe: {price, standing, skill?: {skill: level}}}.
	var teaches: Variant = d.get("teaches", {})
	if typeof(teaches) != TYPE_DICTIONARY:
		errors.append("%s: teaches maps a recipe to its terms" % id)
	else:
		for r: Variant in teaches:
			var t: Variant = teaches[r]
			if kind_of(String(r)) != "recipe" or typeof(t) != TYPE_DICTIONARY or int(t.get("price", -1)) < 0:
				errors.append("%s: teaches '%s' needs a recipe and {price, standing}" % [id, r])
				continue
			for sk: Variant in t.get("skill", {}):
				if kind_of(String(sk)) != "skill":
					errors.append("%s: teaches '%s' asks for '%s', not a skill" % [id, r, sk])
	var lines: Variant = d.get("lines", {})
	if typeof(lines) != TYPE_DICTIONARY:
		errors.append("%s: lines map a situation to what is said" % id)
		return
	for k: Variant in lines:
		if not String(k) in ["greet", "work", "evening", "rain", "night"] or typeof(lines[k]) != TYPE_ARRAY:
			errors.append("%s: lines '%s': a situation (greet, work, evening, rain, night) and a list" % [id, k])


## A story a village's chronicle grows by (ADR-0042): what it grows from
## ("founding", "predators", "season:<name>", "dweller_killed",
## "dweller_hurt"), the entry it writes, and maybe a request one of the
## dwellers makes of whoever asks: hunt (a kind seen by the village, near
## it), fetch (an item, so many), find (a thing lost in a cave near it).
const STORY_FROM := ["founding", "predators", "season:spring", "season:summer", "season:autumn", "season:winter",
	"dweller_killed", "dweller_hurt", "livestock_killed"]


func _check_story(id: String, d: Dictionary) -> void:
	if not String(d.get("from", "")) in STORY_FROM:
		errors.append("%s: from is one of %s" % [id, ", ".join(STORY_FROM)])
	if typeof(d.get("entry")) != TYPE_STRING or String(d["entry"]) == "":
		errors.append("%s: a story writes an entry" % id)
	if String(d.get("needs", "")) not in ["", "cave"]:
		errors.append("%s: needs is \"cave\" or nothing" % id)
	if not d.has("request"):
		return
	var r: Variant = d["request"]
	if typeof(r) != TYPE_DICTIONARY:
		errors.append("%s: request is {kind, asker, ...}" % id)
		return
	for f: String in ["ask", "doing", "done", "goal", "deed"]:
		if typeof(r.get(f)) != TYPE_STRING:
			errors.append("%s: a request says %s" % [id, f])
	r["count"] = int(r.get("count", 1))
	r["reward"] = int(r.get("reward", 0))
	r["radius"] = int(r.get("radius", 48))
	var asker := String(r.get("asker", ""))
	if not (asker == "any" or asker.begins_with("work:") or kind_of(asker) == "profession"):
		errors.append("%s: asker is any, work:<place> or a profession" % id)
	match String(r.get("kind", "")):
		"hunt":
			if d["from"] != "predators":
				errors.append("%s: a hunt grows from predators seen" % id)
		"fetch":
			if kind_of(String(r.get("item", ""))) != "item" or r["count"] < 1:
				errors.append("%s: fetch needs an item and a count" % id)
		"find":
			if d.get("needs") != "cave":
				errors.append("%s: a thing to find is lost in a cave (needs cave)" % id)
			_check_refs(id, "items", r.get("items", []), "item")
			if (r.get("items", []) as Array).is_empty():
				errors.append("%s: find needs items to lose" % id)
		var k:
			errors.append("%s: unknown request kind '%s'" % [id, k])


## What fills a container from a ground or a creature (ADR-0037):
## {empty container: what it becomes}.
func _check_fills(id: String, d: Dictionary) -> void:
	if not d.has("fills"):
		return
	if typeof(d["fills"]) != TYPE_DICTIONARY or (d["fills"] as Dictionary).is_empty():
		errors.append("%s: fills maps a container to what it becomes" % id)
		return
	for k: Variant in d["fills"]:
		if kind_of(String(k)) != "item" or kind_of(String(d["fills"][k])) != "item":
			errors.append("%s: fills '%s' -> '%s' are not both items" % [id, k, d["fills"][k]])


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
	# What it does when struck (one struck near it counts if it is of its kind
	# and it sees who did it, "kin"): runs, or strikes back. A predator also
	# attacks first (its behaviour).
	var r: Variant = d.get("reaction", {})
	if typeof(r) != TYPE_DICTIONARY:
		errors.append("%s: reaction is {hurt, kin}" % id)
		r = {}
	var hurt := String(r.get("hurt", "fight" if String(d.get("behavior", "")) == "predator" else "flee"))
	if not hurt in ["flee", "fight"]:
		errors.append("%s: reaction hurt is flee or fight" % id)
	elif hurt == "fight" and not d.has("attack"):
		errors.append("%s: one that fights back needs an attack" % id)
	d["reaction"] = {"hurt": hurt, "kin": bool(r.get("kin", false))}
	if d.has("drops"):
		_check_amounts(id, "drops", d["drops"], false)
	if d.has("life"):
		_check_animal_life(id, d["life"], d.has("attack"))
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
	_check_fills(id, d)
	if d.has("fills") and float(d.get("fill_hours", 12.0)) <= 0.0:
		errors.append("%s: fill_hours must be above 0" % id)
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


func _check_animal_life(id: String, life: Variant, armed: bool) -> void:
	if not life is Dictionary:
		errors.append("%s: life is {mature_hours, breed_hours, forage or prey}" % id)
		return
	for f: String in ["mature_hours", "breed_hours", "hunt_hours"]:
		if not (life.get(f, 6) is float or life.get(f, 6) is int) or float(life.get(f, 0 if f != "hunt_hours" else 6)) <= 0:
			errors.append("%s: life %s must be above 0" % [id, f])
	var forage: Variant = life.get("forage", [])
	var prey: Variant = life.get("prey", [])
	if not forage is Array or not prey is Array:
		errors.append("%s: life forage and prey are arrays" % id)
		return
	if forage.is_empty() and prey.is_empty():
		errors.append("%s: life needs forage or prey" % id)
	for food: Variant in forage:
		if not kind_of(String(food)) in ["ground", "plant"]:
			errors.append("%s: life forage must name ground or plants" % id)
	if not prey.is_empty():
		_check_refs(id, "life prey", prey, "creature")
	if not prey.is_empty() and (not armed or prey.has(id)):
		errors.append("%s: a hunter needs an attack and cannot eat its own kind" % id)
	if not forage.is_empty() and (not (life.get("food_cells", 128) is int or life.get("food_cells", 128) is float) \
			or int(life.get("food_cells", 128)) < 16):
		errors.append("%s: life food_cells must be at least 16" % id)


## A light source (ADR-0014): {"radius" cells 1..8, "intensity" 0..1,
## "color" "#rrggbb", "flicker": true — a fire's, it trembles on the screen}.
## A rule: how light it is decides what creatures see.
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
## A ground's or plant's look in winter (presentation): one of its kind, or "" — none.
func _check_winter(id: String, d: Dictionary) -> void:
	if d.has("winter") and String(d["winter"]) != "" and kind_of(String(d["winter"])) != kind_of(id):
		errors.append("%s: winter '%s' is not a thing of its kind" % [id, d["winter"]])


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
	# What it is after (a berry bush picked is a bush); "" — gone.
	g["becomes"] = String(g.get("becomes", ""))
	if g["becomes"] != "" and kind_of(String(g["becomes"])) != kind_of(id):
		errors.append("%s: gather becomes '%s', not a thing of its kind" % [id, g["becomes"]])


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
	elif d.get("format") == "ro":
		_check_ro(id, d, dir)
	for worn: Variant in worn_layers:
		if typeof(worn) == TYPE_DICTIONARY and worn.has("sheets") and String(worn.get("layer", "")) != "":
			for sheet: Variant in worn["sheets"]:
				if d.get("format") == "ro":
					_check_ro_sheet(id, sheet, dir)
				else:
					_check_sheet(id, sheet, dir)
			if worn.has("keep_out"):  # RO headwear: where hair under it is cut (RoSprite)
				_check_ro_sheet(id, worn["keep_out"], dir)
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


## A body from the RO sprite pipeline (tools/art/ro_sprites/export_game.py):
## its own sheet, clips with frames and fps, the clip of each swing and the
## order its layers are drawn in, frame by frame (RoSprite).
func _check_ro(id: String, d: Dictionary, dir: String) -> void:
	_check_ro_sheet(id, d, dir)
	var clips: Variant = d.get("clips")
	if typeof(clips) != TYPE_DICTIONARY or not ["idle", "walk"].all(func(c: String) -> bool: return clips.has(c)):
		errors.append("%s: clips need idle and walk" % id)
		return
	for c: String in clips:
		var clip: Variant = clips[c]
		if typeof(clip) != TYPE_DICTIONARY or int(clip.get("frames", 0)) < 1 \
				or typeof(clip.get("fps")) not in [TYPE_INT, TYPE_FLOAT] or float(clip["fps"]) <= 0.0:
			errors.append("%s: clip '%s' needs frames and fps" % [id, c])
	for kind: Variant in d.get("swings", {}):
		if not clips.has(d["swings"][kind]):
			errors.append("%s: swing '%s' plays an unknown clip" % [id, kind])
	if typeof(d.get("layers")) != TYPE_ARRAY or typeof(d.get("order")) != TYPE_DICTIONARY:
		errors.append("%s: an RO body needs its layers and their order" % id)


## One RO layer: an atlas of frames of one size, eight rows of directions,
## clips as [first column, frames], bands of rows past `columns` columns.
func _check_ro_sheet(id: String, sheet: Variant, dir: String) -> void:
	if typeof(sheet) != TYPE_DICTIONARY or String(sheet.get("atlas", "")) == "" or typeof(sheet.get("anims")) != TYPE_DICTIONARY \
			or typeof(sheet.get("frame")) != TYPE_ARRAY or (sheet["frame"] as Array).size() != 2 \
			or typeof(sheet.get("origin")) != TYPE_ARRAY or (sheet["origin"] as Array).size() != 2 or int(sheet.get("columns", 0)) < 1:
		errors.append("%s: an RO sheet needs atlas, frame, origin, columns and anims" % id)
		return
	sheet["atlas_path"] = dir.path_join(String(sheet["atlas"])) if dir != "" else ""
	if dir != "" and not FileAccess.file_exists(sheet["atlas_path"]) and not ResourceLoader.exists(sheet["atlas_path"]):
		errors.append("%s: atlas %s not found" % [id, sheet["atlas_path"]])
	sheet["frame"] = (sheet["frame"] as Array).map(func(n: Variant) -> int: return int(n))
	sheet["origin"] = (sheet["origin"] as Array).map(func(n: Variant) -> int: return int(n))
	sheet["columns"] = int(sheet["columns"])
	for c: String in sheet["anims"]:
		var r: Variant = sheet["anims"][c]
		if typeof(r) != TYPE_ARRAY or (r as Array).size() != 2 or int(r[1]) < 1:
			errors.append("%s: RO sheet clip '%s' needs a first column and frames" % [id, c])
			continue
		sheet["anims"][c] = [int(r[0]), int(r[1])]


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
	var every: Variant = d.get("every")  # a beast's call now and then: [lo, hi] seconds
	if every != null and (typeof(every) != TYPE_ARRAY or (every as Array).size() != 2 or float(every[0]) <= 0 or float(every[1]) < float(every[0])):
		errors.append("%s: every must be [shortest, longest] seconds" % id)
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
