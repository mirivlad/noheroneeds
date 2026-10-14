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
## Fields only a player sees (texts). They and "visual" definitions are left
## out of the rules fingerprint (ADR-0009): translations and texture packs
## never stop anyone from joining.
const PRESENTATION_FIELDS := ["name", "description"]
## Fields the registry adds while loading.
const DERIVED_FIELDS := ["pack", "atlas_path"]
## What a structure part is for (ADR-0007). Columns and beams are decoration.
const STRUCTURE_ROLES := ["wall", "door", "window", "fence", "column", "beam", "ceiling", "roof", "stairs", "furniture"]
const DEFS_FORMAT := 1

static var _id_pattern := RegEx.create_from_string("^[a-z0-9_]+:[a-z0-9_/]+$")

## id -> definition Dictionary (with "pack" added)
var defs := {}
## pack id -> {"version", "depends", "dir"}
var packs := {}
## content id -> visual definition that draws it; a later pack's visual
## replaces an earlier one (reskins), logic definitions cannot be replaced.
var visuals := {}
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
		if d.get("kind") == "visual":
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
				d["stack"] = int(d.get("stack", 1))
				if d["stack"] < 1:
					errors.append("%s: stack must be at least 1" % id)
			"structure":
				_check_amounts(id, "cost", d.get("cost", {}), true)
				d["role"] = String(d.get("role", "wall"))
				if not STRUCTURE_ROLES.has(d["role"]):
					errors.append("%s: unknown role '%s'" % [id, d["role"]])
				d["openable"] = bool(d.get("openable", false))
				if d["role"] == "ceiling" and kind_of(String(d.get("floor", ""))) != "ground":
					errors.append("%s: a ceiling needs the floor (a ground) it makes above" % id)
			"recipe":
				_check_amounts(id, "inputs", d.get("inputs", {}), true)
				_check_amounts(id, "outputs", d.get("outputs", {}), true)
			"body_plan":
				_check_strings(id, "slots", d.get("slots", []))
				_check_strings(id, "appearance_slots", d.get("appearance_slots", []))
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
			"biome":
				_check_weights(id, "ground", d.get("ground"), ["ground"])
				_check_weights(id, "cover", d.get("cover", {}), ["plant"], false)
				d["cover_density"] = float(d.get("cover_density", 0.0))
				if d["cover_density"] < 0.0 or d["cover_density"] > 1.0:
					errors.append("%s: cover_density must be within 0..1" % id)
			var other:
				errors.append("%s: unknown kind '%s'" % [id, other])


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
	var target := String(d.get("for", ""))
	if not defs.has(target) or kind_of(target) == "visual":
		errors.append("%s: draws '%s', which is not defined" % [id, target])
		return
	if not ["flat", "tall", "cover", "character", "item"].has(d.get("mode")):
		errors.append("%s: mode must be flat, tall, cover, character or item" % id)
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
	for f: String in ["rect", "origin"]:
		var v: Variant = d.get(f)
		if typeof(v) != TYPE_ARRAY or (v as Array).size() != (4 if f == "rect" else 2):
			errors.append("%s: bad %s" % [id, f])
			return
		d[f] = (v as Array).map(func(n: Variant) -> int: return int(n))
	d["variants"] = maxi(1, int(d.get("variants", 1)))
	var dir: String = packs.get(d["pack"], {}).get("dir", "")
	d["atlas_path"] = dir.path_join(String(d.get("atlas", ""))) if dir != "" else ""
	if dir != "" and not FileAccess.file_exists(d["atlas_path"]) and not ResourceLoader.exists(d["atlas_path"]):
		errors.append("%s: atlas %s not found" % [id, d["atlas_path"]])
	var old: Dictionary = visuals.get(target, {})
	if old.is_empty() or _pack_order(d["pack"]) >= _pack_order(old["pack"]):
		visuals[target] = d


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


func _check_strings(id: String, field: String, list: Variant) -> void:
	if typeof(list) != TYPE_ARRAY or (list as Array).is_empty():
		errors.append("%s: '%s' must be a non-empty list" % [id, field])
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
