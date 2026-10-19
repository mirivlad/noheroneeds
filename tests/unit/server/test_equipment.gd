extends TestCase

var w: ServerWorld
var content: ContentRegistry
var path := ""
var c: PortableCharacter


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	path = tmp_dir().path_join("world.db")
	w = ServerWorld.open(path, content, {"seed": 3})
	w.starter_outfit = WorldLibrary.STARTER_OUTFIT.duplicate()
	c = PortableCharacter.create("Аня", "base:human_f")
	c.styles = {"face": "base:human_face_soft", "hair": "base:human_hair_braid"}
	c.colors = {"skin": "#8b5a3f", "hair": "#33251f"}
	w.enter("owner", c)


func after_each() -> void:
	w.close()


func _req(r: Dictionary) -> Dictionary:
	if not r.has("request_id"):
		r["request_id"] = Uuid.v4()
	w.handle(c.character_id, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func test_equip_unequip_replace_are_durable_and_do_not_duplicate() -> void:
	var id := c.character_id
	w.grant(id, "base:felt_hat", 1)
	var request := {"type": "equip", "item": "base:felt_hat", "request_id": "same-equip"}
	check(_req(request).get("ok", false), "wear a carried hat")
	eq(w.inventory(id).count("base:felt_hat"), 0)
	eq(w.present[id]["appearance"]["worn"]["headwear"], "base:felt_hat")
	check(_req(request).get("ok", false), "repeat acknowledges the same result")
	eq(_req({"type": "equip", "item": "base:felt_hat"}).get("reason"), "not_carried")
	var remove := {"type": "unequip", "slot": "headwear", "request_id": "same-remove"}
	check(_req(remove).get("ok", false), "take it off")
	_req(remove)
	eq(w.inventory(id).count("base:felt_hat"), 1, "not two hats after retry")
	check(_req({"type": "unequip", "slot": "torso"}).get("ok", false), "starter clothes return to the bag")
	eq(w.inventory(id).count("base:linen_shirt"), 1)
	w.grant(id, "base:linen_shirt", 1)
	_req({"type": "equip", "item": "base:linen_shirt"})
	_req({"type": "equip", "item": "base:linen_shirt"})
	eq(w.inventory(id).count("base:linen_shirt"), 1, "replacing returns the old shirt")
	w.close()
	w = ServerWorld.open(path, content)
	eq(w.enter("owner", c), "")
	eq(w.inventory(id).count("base:felt_hat"), 1, "bag survives restart")
	_req(request)
	eq(w.inventory(id).count("base:felt_hat"), 1, "a repeated request after restart stays idempotent")
	check(not w.present[id]["appearance"]["worn"].has("headwear"), "the old successful equip is not applied twice")
	eq(w.present[id]["appearance"]["worn"]["torso"], "base:linen_shirt", "equipment survives restart")
	for slot: String in ["torso", "legs", "feet"]:
		_req({"type": "unequip", "slot": slot})
	w.leave(id)
	w.enter("owner", c)
	eq(w.present[id]["appearance"]["worn"], {}, "an empty outfit is never granted twice")
	eq(w.inventory(id).count("base:linen_shirt"), 2)


func test_invalid_equipment_does_not_change_possessions() -> void:
	var before := w.inventory(c.character_id).to_data()
	for request: Dictionary in [{"type":"equip","item":42}, {"type":"unequip","slot":[]},
			{"type":"equip","item":"base:oak"}, {"type":"equip","item":"base:axe"},
			{"type":"unequip","slot":"unknown"}, {"type":"unequip","slot":"headwear"}]:
		check(_req(request).get("ok") != true, "invalid request refused: " + str(request))
	eq(w.inventory(c.character_id).to_data(), before)


func test_offline_edit_updates_known_world_without_importing_possessions() -> void:
	var id := c.character_id
	w.grant(id, "base:stone", 7)
	_req({"type": "unequip", "slot": "torso"})
	c.body_plan = "base:human_f"
	c.styles["face"] = "base:human_face_square"
	c.inventory.add("base:stone", 1000)
	c.equipment = {"headwear": "base:felt_hat"}
	eq(w.enter("owner", c), "already_present", "editing cannot apply to a present actor")
	eq(w.present[id]["appearance"]["body_plan"], "base:human_f")
	w.leave(id)
	eq(w.enter("intruder", c), "not_owner")
	eq(w.enter("owner", c), "")
	eq(w.present[id]["appearance"]["body_plan"], "base:human_f")
	eq(w.inventory(id).count("base:stone"), 7, "incoming progress cannot replace the world's")
	check(not w.present[id]["appearance"]["worn"].has("torso"), "the editor cannot restore removed equipment")
	check(not w.present[id]["appearance"]["worn"].has("headwear"), "or import free equipment")


func test_equipment_obeys_death_drops_and_is_not_reissued() -> void:
	var id := c.character_id
	w.grant(id, "base:felt_hat", 1)
	_req({"type": "equip", "item": "base:felt_hat"})
	w.combat.hurt(id, 100, "")
	eq(w.present[id]["appearance"]["worn"], {})
	var hats := 0
	for item: Dictionary in w.items.values():
		if item["item"] == "base:felt_hat":
			hats += int(item["count"])
	eq(hats, 1, "the worn hat fell exactly once")
	w.leave(id)
	w.enter("owner", c)
	eq(w.present[id]["appearance"]["worn"], {}, "death and rejoin do not grant another outfit")
