class_name DevRuns
extends RefCounted
## Development runs of the game screen (command-line options after "--", see
## App): a demo house and yard (--demo[=...]), going somewhere (--goto=...),
## a window opened for a picture (--ui=...), a blow caught midway, the own
## RO character held in poses and photographed (--poses=PREFIX), things put on
## (--wear=base:felt_hat,...)... Nothing
## here is for players; GameScreen calls step() each frame when any is given.

var g: GameScreen
## --poses=PREFIX [--pose_list=clip:dir:frame,...]: the own RO-style character is held in each
## pose in turn (RoSprite.pinned) and the screen saved as PREFIX_<clip>_<dir>_<frame>.png; then
## the game quits. Without a list: idle, walk and run frames and the whole chop, in n s e ne se.
const POSE_DIRS := ["n", "s", "e", "ne", "se"]
var _poses: Array = []
var _pose_at := -1
var _pose_wait := 0


func _init(screen: GameScreen) -> void:
	g = screen


func step(delta: float) -> void:
	if g._opts.has("audio_debug") and g._frames % 60 == 59:  # dev: what is heard, and from where
		var a := g.audio
		var amb := PackedStringArray()
		for path: String in a._amb:
			var p: AudioStreamPlayer = a._amb[path][0]
			amb.append("%s %s %.1fdB" % [path.get_file(), "on" if p.playing else "off", p.volume_db])
		var near := 0
		for v: AudioStreamPlayer2D in a._voices:
			if v.playing:
				near += 1
		var cam := g.get_viewport().get_camera_2d()
		print("AUDIO amb=[", ", ".join(amb), "] forest=%.2f voices_playing=%d calls=%d cam=%s cam_pos=%s me=%s" % [a.forest_share, near,
			a._calls.size(), cam != null, cam.global_position if cam else Vector2.ZERO, g.view.own_pixel_position(1.0)])
		for v: AudioStreamPlayer2D in a._voices:
			if v.playing:
				print("  VOICE ", v.stream.resource_name.get_file() if v.stream else "?", " at ", v.global_position, " vol ", v.volume_db)
	if g._opts.has("pick_debug") and g._frames % 60 == 59:  # dev: what the ray under each dweller's middle hits
		var v := g.view as WorldView3D
		for id: String in v._actors:
			var a := v._actors[id] as BillboardActor3D
			if a == null or id == g.client.character_id:
				continue
			var at := a.global_position + Vector3.UP * 0.8
			if not v.eye.is_position_in_frustum(at):
				continue
			var screen := v.eye.unproject_position(at) / v._pixel
			var p := v.screen_point(screen)
			var hit := v.pick_target(p)
			print("PICK ", id, " ", (g.client.entities.get(id, {}) as Dictionary).get("kind", ""), " at ", screen.round(), " -> ", hit.get("kind", ""), " ", hit.get("id", ""), " ", hit.get("layer", ""), " cell ", hit.get("cell", ""))
	if g._opts.has("hour") and g.game and g._frames == 5:  # dev: the world's clock set to an hour of day one
		g.game.world.world_time = float(g._opts["hour"]) * Daylight.HOUR_MS
	if g._opts.has("poses"):
		_photograph_poses()
	if g._opts.has("demo") and not g._demo_done and g.client.state == "playing" and g.client.has_position:
		g._demo_done = true
		if g.game:
			g.game.world.grant(g.client.character_id, "base:plank", 120)  # dev only: enough for the demo
		# A plank floor under the house, laid first: the walls stand on it.
		for y in range(-4, 3):
			for x in range(-3, 4):
				g.client.request({"type": "build", "location": g.client.location, "x": x, "y": y, "part": "base:plank_floor"})
		for x in range(-3, 4):
			for y in [-4, 2]:
				var part := "base:wood_door" if x == 0 and y == 2 else ("base:stone_wall" if y == -4 else "base:wood_wall")
				var facing := ""
				if absi(x) == 2:  # windows to the front, a loophole to the back (ADR-0015)
					part = "base:wood_window" if y == 2 else "base:loophole"
					facing = "s" if y == 2 else "n"
				g.client.request({"type": "build", "location": g.client.location, "x": x, "y": y, "part": part, "facing": facing})
		for y in range(-3, 2):
			for x in [-3, 3]:
				g.client.request({"type": "build", "location": g.client.location, "x": x, "y": y, "part": "base:wood_wall"})
		# A ceiling over the room, thatch over its back row, stairs to the floor above.
		for y in range(-3, 2):
			for x in range(-2, 3):
				var part := "base:thatch_roof" if y == -3 else "base:wood_ceiling"
				g.client.request({"type": "build", "location": g.client.location, "x": x, "y": y, "part": part})
		g.client.request({"type": "build", "location": g.client.location, "x": 1, "y": 0, "part": "base:wood_stairs"})
		# Beside the house: a wall with a walk on top, stairs up to it from
		# both ends, turned east and west (ADR-0013).
		for x in range(-1, 2):
			g.client.request({"type": "build", "location": g.client.location, "x": x, "y": 4, "part": "base:wood_wall"})
			g.client.request({"type": "build", "location": g.client.location, "x": x, "y": 4, "part": "base:wood_ceiling"})
		g.client.request({"type": "build", "location": g.client.location, "x": -2, "y": 4, "part": "base:wood_stairs", "facing": "e"})
		g.client.request({"type": "build", "location": g.client.location, "x": 2, "y": 4, "part": "base:wood_stairs", "facing": "w"})
		g.client.request({"type": "drop", "item": "base:stone", "count": 2})
		for x in [-2, 2]:  # torches by the door (ADR-0014)
			g.client.request({"type": "build", "location": g.client.location, "x": x, "y": 3, "part": "base:torch"})
		if g.game:  # a yard with the stations of g.crafts (ADR-0026)
			g.game.world.grant(g.client.character_id, "base:log", 12)
			g.game.world.grant(g.client.character_id, "base:stone", 10)
			g.game.world.grant(g.client.character_id, "base:workbench_item", 1)  # set up from the bag (ADR-0048)
		for p: Array in [[4, 0, "base:workbench"], [5, 1, "base:forge"], [4, 2, "base:campfire"]]:
			g.client.request({"type": "build", "location": g.client.location, "x": p[0], "y": p[1], "part": p[2]})
		if g.game:  # a field by the house, sown at days apart (ADR-0027)
			var w := g.game.world
			for i in 8:
				var at := Vector2i(-6 + i % 4, 6 + i / 4)
				var c := w.chunk(g.client.location, at.x >> 5, at.y >> 5)
				c.set_cell("ground", at.x & 31, at.y & 31, "base:farmland")
				c.set_cell("cover", at.x & 31, at.y & 31, "base:wheat_crop" if i < 4 else "base:carrot_crop")
				w._set_layer_props(c, "cover", at.x & 31, at.y & 31, {"planted": w.world_time - (i % 4) * 16 * Daylight.HOUR_MS})
				w._changed(ServerWorld.chunk_key(g.client.location, at.x >> 5, at.y >> 5))
			# fenced round, a gate in its front
			for x in range(-7, -1):
				for y in range(5, 9):
					if x in [-7, -2] or y in [5, 8]:
						var c := w.chunk(g.client.location, x >> 5, y >> 5)
						c.set_cell("structure", x & 31, y & 31, "base:wood_gate" if x == -4 and y == 8 else "base:wood_fence")
						w._changed(ServerWorld.chunk_key(g.client.location, x >> 5, y >> 5))
	if g._opts.get("demo") == "" and g._frames == 30:
		g.client.request({"type": "use", "location": g.client.location, "x": 0, "y": 2})
	if g._opts.get("demo") == "fight" and g.game:  # dev only: a wolf, a hurt deer, an arrow (ADR-0019)
		var me := Vector2i(0, 7)
		if g._frames == 40:
			g.game.world.move_character(g.client.character_id, me * 256 + Vector2i(128, 128))
			var deer := g.game.world.creatures._spawn("base:deer", "surface", me + Vector2i(-3, 0), {}, 1)
			g.game.world.combat.hurt(deer.id, 4, "")
			g.game.world.creatures._spawn("base:wolf", "surface", me + Vector2i(4, -1), {}, 2)
			g.game.world.combat.hurt(g.client.character_id, 6, "")
		if g._frames == 100:
			g.client.request({"type": "attack", "item": "base:bow", "x": (me.x + 10) * 256, "y": me.y * 256 + 128})
	if g._opts.get("demo") == "cave" and g.game:  # dev only: down the way near the spawn point (ADR-0017)
		var way := g.game.world._spawn_way()
		if g._frames == 40:
			g.game.world.move_character(g.client.character_id, way * 256 + Vector2i(128, 128))
		if g._frames == 50:
			g.client.request({"type": "climb", "location": "surface", "x": way.x, "y": way.y})
		if g._frames == 70:
			g.game.world.grant(g.client.character_id, "base:log", 2)
			g.client.request({"type": "build", "location": g.client.location, "x": way.x + 1, "y": way.y + 1, "part": "base:torch"})
	if g._opts.get("demo") == "fish" and g.game:  # dev only: a pond and a rod (fishing)
		var me := Vector2i(0, 7)
		if g._frames == 40:
			var w := g.game.world
			for y in range(me.y - 1, me.y + 3):
				for x in range(me.x + 1, me.x + 5):
					var c := w.chunk("surface", x >> 5, y >> 5)
					c.set_cell("ground", x & 31, y & 31, "base:water")
					c.set_cell("cover", x & 31, y & 31, "")
					c.set_cell("structure", x & 31, y & 31, "")
					w._changed(ServerWorld.chunk_key("surface", x >> 5, y >> 5))
			w.move_character(g.client.character_id, me * 256 + Vector2i(128, 128))
			w.grant(g.client.character_id, "base:fishing_rod", 1)
		if g._frames == 50:
			g.hotbar.put(0, "base:fishing_rod", -1)
			g._choose_slot(0)
	if g._opts.get("demo") == "farm" and g.game and g._frames == 40:  # dev only: a herd of one's own in the pen (ADR-0030)
		var w := g.game.world
		var i := 0
		for kind: String in ["base:sheep", "base:sheep", "base:cow", "base:chicken", "base:chicken", "base:chicken"]:
			var c := w.creatures._spawn(kind, g.client.location, Vector2i(-6 + i % 4, 6 + (i / 4)), {}, i + 1)
			c.owner = g.client.character_id
			c.fed_at = w.world_time
			c.changed()
			i += 1
		w.move_character(g.client.character_id, Vector2i(-4, 10) * 256 + Vector2i(128, 128))
		w.grant(g.client.character_id, "base:wheat", 5)
	if g._opts.get("demo") == "sleep" and g.game:  # dev only: a bed by the house, one asleep in it (ADR-0035)
		var bed := Vector2i(1, 7)
		if g._frames == 40:
			var w := g.game.world
			var c := w.chunk(g.client.location, bed.x >> 5, bed.y >> 5)
			for y in range(bed.y - 2, bed.y + 3):  # nothing growing over it
				for x in range(bed.x - 2, bed.x + 3):
					c.set_cell("cover", x & 31, y & 31, "")
			c.set_cell("structure", bed.x & 31, bed.y & 31, "base:bed")
			w._changed(ServerWorld.chunk_key(g.client.location, bed.x >> 5, bed.y >> 5))
			w.move_character(g.client.character_id, Vector2i(0, 7) * 256 + Vector2i(128, 128))
			w.needs.set_energy(g.client.character_id, 10.0)
		if g._frames == 60:
			g.client.request({"type": "sleep", "location": g.client.location, "x": bed.x, "y": bed.y})
	if g._opts.has("wear") and g.game and g._frames == 45:  # dev only: given and put on
		for item: String in String(g._opts["wear"]).split(","):
			g.game.world.grant(g.client.character_id, item, 1)
			g.client.request({"type": "equip", "item": item})
	if g._opts.has("goto") and g.game and g._frames == 40:  # dev only: --goto=X,Y (or "village") puts one at a cell
		var cell := Vector2i.ZERO
		if String(g._opts["goto"]).begins_with("village") and not String(g._opts["goto"]).begins_with("village@"):  # "village" or "village,DX,DY" from its fire
			var home := g.game.world.generator.settlements.home_plan()
			var off := String(g._opts["goto"]).split(",")
			if not home.is_empty():
				cell = (home["fire"] as Vector2i) + (Vector2i(int(off[1]), int(off[2])) if off.size() == 3 else Vector2i(2, 0))
		elif String(g._opts["goto"]).begins_with("village@"):  # "village@base:rocky": the nearest in that biome
			var g := g.game.world.generator
			for p: Dictionary in g.settlements.plans_near(Vector2i.ZERO, 3000):
				if g.biome_id_at(p["centre"].x, p["centre"].y) == String(g._opts["goto"]).trim_prefix("village@") \
						and (cell == Vector2i.ZERO or Vector2(p["centre"]).length() < Vector2(cell).length()):
					cell = (p["fire"] as Vector2i) + Vector2i(2, 0)
		elif String(g._opts["goto"]) == "pen":  # beside the home village's pen, at its gate
			var home := g.game.world.generator.settlements.home_plan()
			if not (home.get("pen", {}) as Dictionary).is_empty():
				cell = (home["pen"]["gate"] as Vector2i) + Vector2i(0, -2)
		elif String(g._opts["goto"]) == "cave":  # beside the way down near the spawn point, on the surface
			cell = g.game.world._spawn_way() + Vector2i(2, 1)
		elif String(g._opts["goto"]) == "bridge":  # the nearest road over water
			var g := g.game.world.generator
			var best := Vector2i(1 << 20, 0)
			for ry in range(-1, 2):
				for rx in range(-1, 2):
					for road: Dictionary in g.settlements.roads_of(0, rx, ry):
						for at: Vector2i in (road["cells"] as Dictionary):
							if g.biome_id_at(at.x, at.y) == "" and Vector2(at).length() < Vector2(best).length():
								best = at  # "" — water under it
			if best.x != 1 << 20:
				cell = best
		elif String(g._opts["goto"]) == "hanging":  # the nearest hanging bridge's end on land (ADR-0064)
			var g := g.game.world.generator
			var best := Vector2i(1 << 20, 0)
			var way := Vector2i.RIGHT
			for ky in range(-40, 41):  # a bridge crosses between two neighbouring sites, at their middle
				for kx in range(-40, 41):
					for d: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE, Vector2i(1, -1)]:
						var a := g._chasm_site(Vector2i(kx, ky))
						var b := g._chasm_site(Vector2i(kx, ky) + d)
						var mid := Vector2i(((a + b) * 0.5).floor())
						if Vector2(mid).length() < Vector2(best).length() and g.land_at(mid.x, mid.y)["what"] == "bridge":
							best = mid
							way = Vector2i.RIGHT if absf(b.x - a.x) >= absf(b.y - a.y) else Vector2i.DOWN
			if best.x != 1 << 20:
				cell = best
				while g.land_at(cell.x, cell.y)["what"] == "bridge":
					cell += way
				cell += way  # on the land beyond its end
		elif String(g._opts["goto"]).begins_with("biome:"):  # "biome:base:taiga": the nearest middle of one
			var want := String(g._opts["goto"]).trim_prefix("biome:")
			var g := g.game.world.generator
			for r in range(0, 3000, 24):
				for k in 32:
					var p := Vector2i(Vector2(r, 0).rotated(k * TAU / 32))
					if [Vector2i.ZERO, Vector2i(12, 0), Vector2i(-12, 0), Vector2i(0, 12), Vector2i(0, -12)].all(func(d: Vector2i) -> bool:
							return g.biome_id_at(p.x + d.x, p.y + d.y) == want):
						cell = p
						break
				if cell != Vector2i.ZERO:
					break
		else:
			var to := String(g._opts["goto"]).split(",")
			cell = Vector2i(int(to[0]), int(to[1]))
		g.game.world.move_character(g.client.character_id, cell * 256 + Vector2i(128, 128))
	if g._opts.get("demo") == "doors" and g.game:  # dev only: doors and walls built in either order, west of the house
		var me := Vector2i(-16, 0)
		var w := g.game.world
		var build := func(x: int, y: int, part: String) -> void:
			g.client.request({"type": "build", "location": g.client.location, "x": me.x + x, "y": me.y + y, "part": part})
		if g._frames == 45:
			for y in range(-14, 4):  # a clear lot
				for x in range(-8, 14):
					var at := me + Vector2i(x, y)
					var c := w.chunk(g.client.location, at.x >> 5, at.y >> 5)
					c.set_cell("cover", at.x & 31, at.y & 31, "")
					c.set_cell("ground", at.x & 31, at.y & 31, "base:grass")
					w._changed(ServerWorld.chunk_key(g.client.location, at.x >> 5, at.y >> 5))
			w.grant(g.client.character_id, "base:plank", 300)
			w.move_character(g.client.character_id, (me + Vector2i(2, 0)) * Movement.UNIT + Vector2i(128, 128))
		if g._frames == 70:
			build.call(0, -3, "base:wood_door")  # A: the door first, the walls after
			for x in [-3, -2, -1, 1, 2, 3]:
				build.call(x, -7, "base:wood_wall")  # B: the walls first, the door after
			build.call(-6, -3, "base:wood_door")  # C: a wall put under a door past the rules
			for x in range(1, 6):
				build.call(x, 3, "base:wood_wall" if x != 3 else "base:wood_door")  # D: a house front, a porch roofed
			for x in range(1, 6):
				for y in [2, 3, 4, 5]:
					build.call(x, y, "base:wood_ceiling")
		if g._frames == 90:
			for x in [-3, -2, -1, 1, 2, 3]:
				build.call(x, -3, "base:wood_wall")
			build.call(0, -7, "base:wood_door")
			var at := me + Vector2i(-6, -2)
			w.chunk(g.client.location, at.x >> 5, at.y >> 5).set_cell("structure", at.x & 31, at.y & 31, "base:wood_wall")
			w._changed(ServerWorld.chunk_key(g.client.location, at.x >> 5, at.y >> 5))
	if g._opts.get("demo") == "occlude" and g.game and g._frames == 40:  # dev only: a wall south and one aside, a tree south
		var w := g.game.world
		var me := Vector2i(0, 7)
		var c := w.chunk(g.client.location, 0, 0)
		for y in range(5, 12):
			for x in range(-3, 4):
				var cc := w.chunk(g.client.location, x >> 5, y >> 5)
				cc.set_cell("cover", x & 31, y & 31, "")
				cc.set_cell("structure", x & 31, y & 31, "")
		for x in range(-1, 2):
			c.set_cell("structure", x & 31, 8, "base:stone_wall")
		for y in range(5, 8):
			c.set_cell("structure", 2, y, "base:stone_wall")
		c.set_cell("cover", (-2) & 31, 9, "base:oak")
		if g._opts.has("tree"):  # a crown over the player instead of the walls
			for x in range(-1, 2):
				c.set_cell("structure", x & 31, 8, "")
			c.set_cell("cover", 0, 9, "base:oak")
		w._changed(ServerWorld.chunk_key(g.client.location, 0, 0))
		w._changed(ServerWorld.chunk_key(g.client.location, -1, 0))
		w.move_character(g.client.character_id, me * 256 + Vector2i(128, 128))
	if g._opts.get("demo") == "armor" and g.game and g._frames == 40:  # dev only: leather and a helmet on (ADR-0029)
		for item: String in ["base:leather_armor", "base:iron_helmet"]:
			g.game.world.grant(g.client.character_id, item, 1)
			g.client.request({"type": "equip", "item": item})
	if g._opts.get("demo") == "loot" and g.game:  # dev only: looters by things lying about (ADR-0016)
		var me := Vector2i(0, 7)
		if g._frames == 40:
			g.game.world.move_character(g.client.character_id, me * 256 + Vector2i(128, 128))
			g.game.world.creatures._spawn("base:poring", "surface", me + Vector2i(3, 0), {}, 1)
			g.game.world.creatures._spawn("base:poporing", "surface", me + Vector2i(-3, 1), {}, 2)
			g.game.world.place_item("surface", (me + Vector2i(5, 1)) * 256 + Vector2i(128, 128), "base:plank", 3)
			g.game.world.place_item("surface", (me + Vector2i(-5, -1)) * 256 + Vector2i(128, 128), "base:stone", 2)
	if g._opts.has("glide") and g.game and g._frames > 80 and g.client.has_position:  # dev: run east through anything (load spikes)
		var pos: Vector2i = g.game.world.present[g.client.character_id]["pos"]
		g.game.world.move_character(g.client.character_id, pos + Vector2i(int(delta * Movement.TICK_RATE * Movement.WALK * 1.5), 0))
	if g._opts.has("swing") and g._frames == int(g._opts.get("frames", "120")) - int(g._opts["swing"]):  # dev: a blow caught midway
		g.view.swing_own(Vector2.RIGHT)
	if g._opts.has("hold") and g.game and g._frames == 60:  # dev: --hold=ITEM: given and in the hands
		var item := String(g._opts["hold"])
		g.game.world.grant(g.client.character_id, item, 3)
		g.hotbar.put(0, item, -1)
		g._choose_slot(0)
	if g._opts.has("say") and g._frames == int(g._opts.get("frames", "120")) - 20:  # dev: --say=TEXT over the nearest dweller
		var best := ""
		for id: String in g.client.entities:
			var e: Dictionary = g.client.entities[id]
			if e.has("said") and (best == "" or Vector2(int(e["x"]), int(e["y"])).distance_to(Vector2(g.client.position))
					< Vector2(int(g.client.entities[best]["x"]), int(g.client.entities[best]["y"])).distance_to(Vector2(g.client.position))):
				best = id
		if best != "":
			var e: Dictionary = g.client.entities[best]
			e["said"] = int(e["said"]) + 1
			e["say"] = String(g._opts["say"])
			g.view.popup_at(Vector2(int(e["x"]), int(e["y"])) / WorldView.UNITS_PER_PIXEL + Vector2(14, -20), "−3", Color(1.0, 0.45, 0.4))
	if g._opts.has("open_map") and g._frames == int(g._opts.get("frames", "120")) - 30:  # dev: a picture of the map
		g.world_map.open()
		g._places_rid = g.client.request({"type": "places"})
	if g._opts.has("ui") and g._frames == int(g._opts.get("frames", "120")) - (40 if String(g._opts["ui"]) in ["trade", "talk", "journal"] else 8):  # dev: a picture of a panel
		match String(g._opts["ui"]):
			"catalog":
				g.catalog.open(g.client.inventory())
			"crafts":
				g.crafts.open()
			"inventory":
				g.open_window("things")
			"journal":
				g.open_window("journal")
			"character":
				g.character_panel.show_for(g.client.own, g.hotbar.held(g.client.inventory()))
			"trade", "talk":  # the nearest dweller, one stepped up to it
				var best := ""
				for id: String in g.client.entities:
					var e: Dictionary = g.client.entities[id]
					if String(e.get("profession", "")) != "" and (best == "" or Vector2(int(e["x"]), int(e["y"])).distance_to(Vector2(g.client.position))
							< Vector2(int(g.client.entities[best]["x"]), int(g.client.entities[best]["y"])).distance_to(Vector2(g.client.position))):
						best = id
				if best != "" and g.game:
					var c := g.game.world.creatures.get_creature(best)
					g.game.world.move_character(g.client.character_id, c.pos + Vector2i(Movement.UNIT, 0))
					if String(g._opts["ui"]) == "talk":
						g._talk_rids[g.client.request({"type": "talk", "creature": best})] = best
					else:
						g._trade_rids[g.client.request({"type": "trade_look", "creature": best})] = best
			"pin":
				g.pin_panel.open_for(Vector2i(0, 2), false)
			"menu":  # the right button's list over the door of the demo house
				g.mouse_at = Vector2(0 * WorldView.CELL + 8, 2 * WorldView.CELL + 8)
				g._update_target()
				g._open_menu()
			"plan":  # a row of walls dragged, part of it out of reach
				var me := Movement.cell_of(g.client.position)
				g._blueprint = "base:wood_wall"
				g._drag_from = me + Vector2i(-4, 2)
				g.mouse_at = Vector2((me.x + 9) * WorldView.CELL + 8, (me.y + 2) * WorldView.CELL + 8)
	if g._opts.get("demo") == "outside" and g._frames == 40 and g.game:
		g.game.world.move_character(g.client.character_id, Vector2i(128, 7 * 256 + 128))  # dev only: before the house
	if g._opts.get("demo") == "behind" and g._frames == 40 and g.game:
		g.game.world.move_character(g.client.character_id, Vector2i(128, -5 * 256 + 200))  # dev only: behind the back wall
	if g._opts.get("demo") in ["hole", "upstairs"] and g.game and g._frames == 36:
		g.game.world.move_character(g.client.character_id, Vector2i(1 * 256 + 128, 1 * 256 + 128))  # dev only: by the stairs
	if g._opts.get("demo") == "hole" and g.game:  # dev only: up, then the stairs gone: the opening stays
		if g._frames == 40:
			g.client.request({"type": "climb", "location": g.client.location, "x": 1, "y": 0})
		if g._frames == 90:
			g.game.world._take_down("surface", g.game.world.chunk("surface", 0, 0), ["surface", 0, 0, 1, 0], "structure",
				"base:wood_stairs", "")
	if g._opts.get("demo") == "upstairs" and g._frames == 40:
		g.client.request({"type": "climb", "location": g.client.location, "x": 1, "y": 0})
	if g._opts.get("demo") == "upstairs" and g._frames == 60 and g.client.z == 1:
		# Part of the first level roofed over: floor and ceiling side by side.
		for y in range(-3, 0):
			for x in range(-2, 1):
				g.client.request({"type": "build", "location": g.client.location, "x": x, "y": y, "part": "base:wood_ceiling"})


func _photograph_poses() -> void:
	if g.client == null or g.client.state != "playing" or not g.client.has_position or g._frames < 90:
		return
	if g.view is WorldView3D and g._frames < 1200 and _pose_at < 0 \
			and not ((g.view as WorldView3D)._queued.is_empty() and (g.view as WorldView3D)._job.is_empty()):
		return  # the ground around still being built
	var doll := _own_doll() as RoSprite
	if doll == null:
		return
	if _pose_at < 0:
		_poses = _pose_list()
		_pose_at = 0
		_pose_wait = 0
	if _pose_at >= _poses.size():
		return
	var pose: Array = _poses[_pose_at]
	if _pose_wait == 0:
		doll.pinned = [pose[0], RoSprite.ROWS.find(pose[1]), int(pose[2])]
		doll._frame({}, 0)
	_pose_wait += 1
	if _pose_wait < 4:  # drawn, and in 3D through the billboard's viewport too
		return
	g.get_viewport().get_texture().get_image().save_png("%s_%s_%s_%d.png" % [g._opts["poses"], pose[0], pose[1], int(pose[2])])
	_pose_at += 1
	_pose_wait = 0
	if _pose_at >= _poses.size():
		doll.pinned = []
		g.screenshot_taken.emit()


func _pose_list() -> Array:
	var out := []
	if g._opts.has("pose_list"):
		for p: String in String(g._opts["pose_list"]).split(","):
			out.append(Array(p.split(":")))
		return out
	for d: String in POSE_DIRS:
		for p: Array in [["idle", 0], ["walk", 2], ["run", 2]]:
			out.append([p[0], d, p[1]])
		for i in 10:
			out.append(["chop", d, i])
	return out


func _own_doll() -> CharacterSprite:
	var actor: BillboardActor3D = g.view._actors.get(g.client.character_id)
	return actor.doll if actor else null
