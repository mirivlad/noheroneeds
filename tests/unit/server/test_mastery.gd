extends TestCase
## ADR-0047 on the server: one makes what one knows (the innate recipes and
## those learned); every attempt is practice; a failure spoils half of what
## is not precious; what one makes carries one's quality, enhancements and
## name; blueprints are made by once or studied; masters put recipes down
## as blueprints; dwellers teach on their terms, by their village's trust;
## a master's work sells for more; skills grow with work and give their
## effects; all of it kept with the character; old worlds are refused.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 5})
	var c := w.chunk("surface", 0, 0)
	for y in 12:
		for x in 12:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")


func after_each() -> void:
	if w:
		w.close()


func _player(name: String, n := 1) -> String:
	var c := PortableCharacter.create(name, "base:human_m")
	c.character_id = "00000000-0000-4000-8000-%012d" % n  # the same dice every run
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, Vector2i(3 * 256 + 128, 3 * 256 + 128))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _workbench(a: String) -> void:
	w.grant(a, "base:log", 4)
	check(_req(a, {"type": "build", "location": "surface", "x": 4, "y": 3, "part": "base:workbench"}).get("ok", false), "a workbench")


## Gives a character a recipe's mastery (and its skill) at a level.
func _master(a: String, recipe: String, level: int) -> void:
	var xp := 0
	while Mastery.level_of(xp, Mastery.RECIPE_K) < level:
		xp += 10
	w.knowledge.practise_recipe(a, recipe, xp)
	var skill := String(_content.get_def(recipe).get("skill", ""))
	var sxp := 0
	while Mastery.level_of(sxp, Mastery.SKILL_K) < level:
		sxp += 10
	w.knowledge.practise_skill(a, skill, sxp)


func test_one_makes_what_one_knows_and_practises_it() -> void:
	var a := _player("Аня")
	_workbench(a)
	check(w.knowledge.knows(a, "base:make_axe"), "a stone axe: known to all")
	check(not w.knowledge.knows(a, "base:make_bow"), "a bow: not")
	w.grant(a, "base:plank", 40)
	w.grant(a, "base:hide", 10)
	w.grant(a, "base:stone", 90)
	eq(_req(a, {"type": "craft", "recipe": "base:make_bow", "count": 1}).get("reason"), "unknown_recipe", "not known: not made")
	eq(w.inventory(a).count("base:plank"), 40, "and nothing taken")
	# Thirty attempts: the dice are real (every request rolls its own), the
	# bounds are some four deviations wide.
	var r := _req(a, {"type": "craft", "recipe": "base:make_axe", "count": 30})
	check(r.get("ok", false), str(r))
	var made := int((r["made"] as Dictionary).get("base:axe", 0))
	eq(made + int(r["failed"]), 30, "thirty attempts: %s" % str(r))
	check(made >= 17, "a novice makes most stone axes (78%% and more): %d" % made)
	eq(w.inventory(a).count("base:axe"), made)
	eq(w.inventory(a).count("base:stone"), 90 - 2 * made - int((r["lost"] as Dictionary).get("base:stone", 0)),
		"what failed spoiled half its stones")
	check(w.knowledge.mastery_level(a, "base:make_axe") > 0, "practice: mastery grew")
	check(w.knowledge.skill_level(a, "base:toolmaking") >= 0, "and its skill")
	var axe := w.inventory(a).state_of("base:axe", 0)
	eq(axe.get("by"), "Аня", "the maker's name on it")
	check(Wear.quality(axe) < 0.6, "a novice's: about half: %s" % str(axe))
	check(not axe.has("mods"), "and plain")


func test_a_master_makes_better_things_and_a_failure_keeps_the_iron() -> void:
	var a := _player("Аня")
	_workbench(a)
	w.knowledge.learn(a, "base:forge_iron_axe")
	w.grant(a, "base:stone", 10)
	check(_req(a, {"type": "build", "location": "surface", "x": 2, "y": 3, "part": "base:forge"}).get("ok", false), "a forge")
	w.grant(a, "base:plank", 30)
	w.grant(a, "base:iron_ingot", 40)
	var r := _req(a, {"type": "craft", "recipe": "base:forge_iron_axe", "count": 20})
	var made := int((r["made"] as Dictionary).get("base:iron_axe", 0))
	check(int(r["failed"]) >= 4, "a novice fails a hard one often (some 58%%): %s" % str(r))
	eq(w.inventory(a).count("base:iron_ingot"), 40 - 2 * made, "failures keep the iron (precious): %s" % str(r))
	check(int((r["lost"] as Dictionary).get("base:plank", 0)) == int(r["failed"]), "but spoil the plank")
	# A master's work.
	_master(a, "base:forge_iron_axe", 100)
	w.grant(a, "base:iron_ingot", 40)
	var before := w.inventory(a).count("base:iron_axe")
	r = _req(a, {"type": "craft", "recipe": "base:forge_iron_axe", "count": 10})
	check(int(r["failed"]) <= 2, "a master hardly fails (1%%): %s" % str(r))
	var states := w.inventory(a).states_of("base:iron_axe").slice(before)
	for st: Dictionary in states:
		eq(Wear.quality(st), 1.0, "whole")
		check(Wear.mods(st).size() >= 2, "two enhancements at least: %s" % str(st))
		for m: Variant in Wear.mods(st):
			check(Mastery.fitting(_content, "base:iron_axe").has(String(m)), "that fit an axe: %s" % m)
	check(Wear.limit(_content, "base:iron_axe", states[0]) >= 1200, "it lasts its full durability or more")


func test_a_blueprint_is_made_by_once_or_studied_for_good() -> void:
	var a := _player("Аня")
	_workbench(a)
	w.grant(a, "base:plank", 10)
	w.grant(a, "base:hide", 5)
	w.grant(a, "base:blueprint", 2, [{"recipe": "base:make_bow"}, {"recipe": "base:make_bow"}])
	var r := _req(a, {"type": "craft", "recipe": "base:make_bow", "count": 3, "blueprint": 0})
	check(r.get("ok", false), str(r))
	eq(r["made"], {"base:bow": 1}, "once, sure")
	eq(Wear.quality(w.inventory(a).state_of("base:bow", 0)), 1.0, "and whole")
	eq(w.inventory(a).count("base:blueprint"), 1, "the blueprint used up")
	check(not w.knowledge.knows(a, "base:make_bow"), "nothing learned")
	eq(_req(a, {"type": "craft", "recipe": "base:make_axe", "count": 1, "blueprint": 0}).get("reason"), "no_blueprint",
		"a blueprint of a bow makes no axe")
	check(_req(a, {"type": "study", "copy": 0}).get("ok", false), "studied")
	check(w.knowledge.knows(a, "base:make_bow"), "known for good")
	eq(w.inventory(a).count("base:blueprint"), 0, "the blueprint used up")
	w.grant(a, "base:blueprint", 1, [{"recipe": "base:make_bow"}])
	eq(_req(a, {"type": "study", "copy": 0}).get("reason"), "known_already", "nothing to learn: it is kept")
	eq(w.inventory(a).count("base:blueprint"), 1)


func test_a_master_puts_a_recipe_down_for_others() -> void:
	var a := _player("Аня", 1)
	var b := _player("Боря", 2)
	w.knowledge.learn(a, "base:make_bow")
	eq(_req(a, {"type": "draft", "recipe": "base:make_bow"}).get("reason"), "not_skilled", "a novice cannot teach it yet")
	_master(a, "base:make_bow", 50)
	eq(_req(a, {"type": "draft", "recipe": "base:make_bow"}).get("reason"), "materials", "it is written on leather")
	w.grant(a, "base:leather", 1)
	check(_req(a, {"type": "draft", "recipe": "base:make_bow"}).get("ok", false), "drafted")
	eq(w.inventory(a).state_of("base:blueprint", 0), {"recipe": "base:make_bow", "by": "Аня"}, "a blueprint, signed")
	eq(_req(a, {"type": "draft", "recipe": "base:make_axe"}).get("reason"), "unknown_recipe", "what all know is not drafted")
	check(_req(a, {"type": "transfer", "to": b, "item": "base:blueprint", "count": 1}).get("ok", false), "handed over")
	check(_req(b, {"type": "study", "copy": 0}).get("ok", false), "and learned by another")
	check(w.knowledge.knows(b, "base:make_bow"), "one player taught another")


func test_skills_grow_with_work_and_spare_the_tool() -> void:
	var a := _player("Аня")
	w.grant(a, "base:axe", 1)
	_req(a, {"type": "hold", "item": "base:axe"})
	var c := w.chunk("surface", 0, 0)
	c.set_cell("cover", 4, 3, "base:oak")
	for i in 5:
		w.tick += 30
		w.combat.step(w.tick)
		_req(a, {"type": "gather", "location": "surface", "x": 4, "y": 3, "layer": "cover", "item": "base:axe"})
	eq(int(w._known_character(a)["data"]["skills"]["base:woodcutting"]["xp"]), 5, "every blow is practice")
	# A master woodcutter's axe wears by chance, about seven blows in ten.
	w.knowledge.practise_skill(a, "base:woodcutting", 5000)
	eq(w.knowledge.skill_level(a, "base:woodcutting"), 100)
	w.inventory(a).set_state("base:axe", 0, {})
	var blows := 0
	for i in 40:
		c.set_cell("cover", 4, 3, "base:oak")
		c.set_props(4, 3, {})
		w.tick += 30
		w.combat.step(w.tick)
		if _req(a, {"type": "gather", "location": "surface", "x": 4, "y": 3, "layer": "cover", "item": "base:axe"}).get("ok", false):
			blows += 1
	var spent := Wear.spent(w.inventory(a).state_of("base:axe", 0))
	check(blows == 40 and spent >= 16 and spent <= 39, "spared (some 28 of 40): %d uses for %d blows" % [spent, blows])
	# Kept with the character.
	w.knowledge.learn(a, "base:make_bow")
	w.close()
	w = ServerWorld.open(_db, _content)
	check(w.knowledge.knows(a, "base:make_bow"), "learned, after a restart")
	eq(w.knowledge.skill_level(a, "base:woodcutting"), 100, "and the skill")


func test_a_world_of_an_older_format_is_refused_with_a_reason() -> void:
	w.close()
	w = null
	var s := WorldStore.new()
	check(s.open(_db), "the file")
	s.write_meta("world_format", "1")
	s.close()
	var old := ServerWorld.open(_db, _content)
	check(old == null, "not opened")
	check(ServerWorld.open_error.contains("старой версией игры"), ServerWorld.open_error)
	var fresh := ServerWorld.open(tmp_dir().path_join("new.db"), _content, {"seed": 1})
	check(fresh != null and ServerWorld.open_error == "", "a new world opens")
	fresh.close()
	w = ServerWorld.open(tmp_dir().path_join("other.db"), _content, {"seed": 2})


func test_starter_things_are_ordinary_work_and_the_easy_rules_apply() -> void:
	w.starter_kit = {"base:axe": 1, "base:plank": 5}
	w.starter_outfit = {"torso": "base:linen_shirt"}
	var a := _player("Аня", 7)
	eq(w.inventory(a).state_of("base:axe", 0), {"quality": 0.75}, "a starter axe: ordinary work")
	eq(w.inventory(a).states_of("base:plank"), [{}, {}, {}, {}, {}], "planks are just planks")
	eq(w.worn_of(a)["torso"], ["base:linen_shirt", {"quality": 0.75}], "and the shirt one wears")
	WorldLibrary.apply_rules({"all_recipes_known": true, "crafts_never_fail": true}, w)
	check(w.knowledge.knows(a, "base:forge_iron_helmet") and w.knowledge.never_fail, "an easy world's rules")
	WorldLibrary.apply_rules({}, w)
	check(not w.knowledge.all_known and not w.knowledge.never_fail, "off by default")

