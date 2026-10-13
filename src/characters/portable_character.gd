class_name PortableCharacter
extends RefCounted
## The part of a character that belongs to the player, not to a world
## (ADR-0006): appearance, attributes, skills, inventory, equipment, known
## recipes, achievements. Position, buildings, world chests, local reputation
## and rights live in the world (WorldCharacterState), never here.

const SCHEMA := 1
const NAME_MAX := 32
## Upper bounds for untrusted data, far above anything legitimate.
const MAX_ENTRIES := 4096
const MAX_STACK := 1000000

## MIGRATIONS[n] turns a schema n+1 body into schema n+2 (Callable on Dictionary).
const MIGRATIONS: Array[Callable] = []

static var _color := RegEx.create_from_string("^#[0-9a-f]{6}$")

var character_id := ""
var name := ""
var body_plan := ""
## appearance slot -> style id
var styles := {}
## color name -> "#rrggbb"
var colors := {}
## attribute id -> value
var attributes := {}
## skill id -> {"level": int, "xp": int}
var skills := {}
var inventory := Inventory.new()
## equipment slot -> item id
var equipment := {}
var known_recipes := PackedStringArray()
var achievements := PackedStringArray()
var created_with := ""


static func create(char_name: String, plan: String) -> PortableCharacter:
	var c := PortableCharacter.new()
	c.character_id = Uuid.v4()
	c.name = char_name
	c.body_plan = plan
	c.created_with = GameInfo.VERSION
	return c


func to_data() -> Dictionary:
	return {
		"schema": SCHEMA, "character_id": character_id, "name": name, "created_with": created_with,
		"appearance": {"body_plan": body_plan, "styles": styles.duplicate(), "colors": colors.duplicate()},
		"attributes": attributes.duplicate(), "skills": skills.duplicate(true),
		"inventory": inventory.to_data(), "equipment": equipment.duplicate(),
		"known_recipes": Array(known_recipes), "achievements": Array(achievements),
	}


## Expects data that passed check_structure().
static func from_data(d: Dictionary) -> PortableCharacter:
	var c := PortableCharacter.new()
	c.character_id = d["character_id"]
	c.name = d["name"]
	c.created_with = d.get("created_with", "")
	var app: Dictionary = d["appearance"]
	c.body_plan = app["body_plan"]
	c.styles = app["styles"]
	c.colors = app["colors"]
	c.attributes = d["attributes"]
	c.skills = d["skills"]
	c.inventory = Inventory.from_data(d["inventory"])
	c.equipment = d["equipment"]
	c.known_recipes = PackedStringArray(d["known_recipes"])
	c.achievements = PackedStringArray(d["achievements"])
	return c


## Brings an older body up to SCHEMA. Returns an empty Dictionary if impossible.
static func migrate(d: Dictionary) -> Dictionary:
	var v := int(d.get("schema", 0))
	if v < 1 or v > SCHEMA:
		return {}
	while v < SCHEMA:
		d = MIGRATIONS[v - 1].call(d)
		v += 1
		d["schema"] = v
	return d


## Shape and size checks that need no content: safe on any decoded input.
static func check_structure(d: Variant) -> PackedStringArray:
	var e := PackedStringArray()
	if typeof(d) != TYPE_DICTIONARY:
		return PackedStringArray(["body is not a map"])
	if not Uuid.is_valid(String(d.get("character_id", ""))):
		e.append("character_id is not a UUID")
	var n: Variant = d.get("name")
	if typeof(n) != TYPE_STRING or String(n).strip_edges() == "" or String(n).length() > NAME_MAX:
		e.append("name must be 1..%d characters" % NAME_MAX)
	var app: Variant = d.get("appearance")
	if typeof(app) != TYPE_DICTIONARY:
		e.append("appearance missing")
	else:
		if typeof(app.get("body_plan")) != TYPE_STRING:
			e.append("appearance.body_plan missing")
		_map_of(e, "appearance.styles", app.get("styles"), TYPE_STRING)
		_map_of(e, "appearance.colors", app.get("colors"), TYPE_STRING)
		if typeof(app.get("colors")) == TYPE_DICTIONARY:
			for k: Variant in app["colors"]:
				if _color.search(String(app["colors"][k])) == null:
					e.append("color '%s' is not #rrggbb" % k)
	_map_of(e, "attributes", d.get("attributes"), TYPE_INT)
	_map_of(e, "skills", d.get("skills"), TYPE_DICTIONARY)
	if typeof(d.get("skills")) == TYPE_DICTIONARY:
		for k: Variant in d["skills"]:
			var s: Dictionary = d["skills"][k]
			if typeof(s.get("level")) != TYPE_INT or typeof(s.get("xp")) != TYPE_INT or int(s["level"]) < 0 or int(s["xp"]) < 0:
				e.append("skill '%s' needs non-negative level and xp" % k)
	var inv: Variant = d.get("inventory")
	if typeof(inv) != TYPE_DICTIONARY or int(inv.get("format", 0)) != Inventory.FORMAT:
		e.append("inventory missing or of unknown format")
	else:
		_map_of(e, "inventory.stacks", inv.get("stacks"), TYPE_INT)
		if typeof(inv.get("stacks")) == TYPE_DICTIONARY:
			for k: Variant in inv["stacks"]:
				if int(inv["stacks"][k]) < 1 or int(inv["stacks"][k]) > MAX_STACK:
					e.append("inventory count of '%s' out of range" % k)
	_map_of(e, "equipment", d.get("equipment"), TYPE_STRING)
	_list_of_strings(e, "known_recipes", d.get("known_recipes"))
	_list_of_strings(e, "achievements", d.get("achievements"))
	return e


## Every id must exist in this server's content and fit where it is used.
func check_content(reg: ContentRegistry) -> PackedStringArray:
	var e := PackedStringArray()
	if reg.kind_of(body_plan) != "body_plan":
		e.append("unknown body plan '%s'" % body_plan)
		return e
	var plan := reg.get_def(body_plan)
	for slot: String in styles:
		var st := reg.get_def(String(styles[slot]))
		if st.get("kind") != "style":
			e.append("unknown style '%s'" % styles[slot])
		elif st["slot"] != slot or not (st["body_plans"] as Array).has(body_plan):
			e.append("style '%s' does not fit slot '%s' of %s" % [styles[slot], slot, body_plan])
	for slot: String in plan["appearance_slots"]:
		if not styles.has(slot):
			e.append("appearance slot '%s' is not chosen" % slot)
	for c: String in colors:
		if not (plan["colors"] as Array).has(c):
			e.append("body plan has no color '%s'" % c)
	for a: String in attributes:
		var ad := reg.get_def(a)
		if ad.get("kind") != "attribute":
			e.append("unknown attribute '%s'" % a)
		elif int(attributes[a]) < int(ad["min"]) or int(attributes[a]) > int(ad["max"]):
			e.append("attribute '%s' out of range" % a)
	for s: String in skills:
		var sd := reg.get_def(s)
		if sd.get("kind") != "skill":
			e.append("unknown skill '%s'" % s)
		elif int(skills[s]["level"]) > int(sd["max_level"]):
			e.append("skill '%s' above its maximum" % s)
	for id: String in inventory.stacks:
		if reg.kind_of(id) != "item":
			e.append("unknown item '%s'" % id)
	for slot: String in equipment:
		var item := reg.get_def(String(equipment[slot]))
		if item.get("kind") != "item":
			e.append("unknown item '%s'" % equipment[slot])
		elif item.get("equip_slot", "") != slot or not (plan["slots"] as Array).has(slot):
			e.append("'%s' cannot be worn in slot '%s'" % [equipment[slot], slot])
	for r in known_recipes:
		if reg.kind_of(r) != "recipe":
			e.append("unknown recipe '%s'" % r)
	for a in achievements:
		if reg.kind_of(a) != "achievement":
			e.append("unknown achievement '%s'" % a)
	return e


## Packs (and versions) whose content this character refers to.
func content_manifest(reg: ContentRegistry) -> Dictionary:
	var ids: Array = [body_plan]
	ids.append_array(styles.values())
	ids.append_array(attributes.keys())
	ids.append_array(skills.keys())
	ids.append_array(inventory.stacks.keys())
	ids.append_array(equipment.values())
	ids.append_array(Array(known_recipes))
	ids.append_array(Array(achievements))
	var out := {}
	for id: Variant in ids:
		var pack := String(id).get_slice(":", 0)
		if reg.packs.has(pack):
			out[pack] = reg.packs[pack]["version"]
	return out


static func _map_of(e: PackedStringArray, field: String, v: Variant, value_type: int) -> void:
	if typeof(v) != TYPE_DICTIONARY:
		e.append(field + " missing")
		return
	if (v as Dictionary).size() > MAX_ENTRIES:
		e.append(field + " too large")
	for k: Variant in v:
		if typeof(k) != TYPE_STRING or typeof(v[k]) != value_type:
			e.append("%s has a bad entry" % field)
			return


static func _list_of_strings(e: PackedStringArray, field: String, v: Variant) -> void:
	if typeof(v) != TYPE_ARRAY or (v as Array).size() > MAX_ENTRIES:
		e.append(field + " missing or too large")
		return
	for x: Variant in v:
		if typeof(x) != TYPE_STRING:
			e.append(field + " has a non-text entry")
			return
