extends SceneTree
## Real App/LocalGame/GameClient, generated seed 431 and the normal UI.
## Test profile only; no player save is opened or changed.
var app: App
var g: GameScreen
var w: ServerWorld
var output := ""
var failures: Array[String] = []
var checks := 0
var hour := -1.0

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)

func pump(count: int, hud := true) -> void:
	for i in count:
		if hour >= 0 and w != null:
			w.world_time = int(hour * Daylight.HOUR_MS)
		g.game.step()
		g.painter.refresh()
		g.view.update_view(1, .05)
		if hud:
			g._update_hud()
			g._place_windows()
		await process_frame

func settle() -> void:
	for i in 500:
		await pump(1)
		if g.view.pending_chunks() == 0 and g.view._geometry.size() >= 9:
			break
	await pump(8)

func move_to(at: Vector2i) -> void:
	w.move_character(g.client.character_id, at * 256 + Vector2i(128, 128))
	await pump(12)

func request(r: Dictionary) -> Dictionary:
	var rid := g.client.request(r)
	for i in 120:
		await pump(1, false)
		if g.client.results.has(rid):
			var result: Dictionary = g.client.results[rid]
			g.client.results.erase(rid)
			g._update_hud()
			return result
	return {"ok": false, "reason": "timeout"}

func capture(name: String) -> void:
	g._update_hud()
	g._place_windows()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func run() -> void:
	output = ProjectSettings.globalize_path("res://build/hospitality-review")
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-%d" % Time.get_ticks_usec())
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var id := library.create("Таверны", {"seed": "431", "starter_kit": true})
	var prepared := ServerWorld.open(library.db_path(id), ContentRegistry.load_packs(["res://content/base"]), {"seed": 431})
	prepared.close()
	app = App.new()
	app.configure({"world": id, "profile_dir": profile, "body": "base:human_ro_m"})
	root.add_child(app)
	g = app.game
	g.set_process(false)
	w = g.game.world
	g.game.server.wait_for_disk = true
	await pump(50)
	w.world_time = 12 * Daylight.HOUR_MS
	var gpu := RenderingServer.get_video_adapter_name()
	verify(gpu.contains("RX 580"), "native RX 580 renderer")
	verify(g.client.state == "playing", "real local server joined")
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var plans := s.inns.of_cluster(0, district.x, district.y)
	var inns := plans.filter(func(p: Dictionary) -> bool: return p["site"] == "inn")
	var taverns := plans.filter(func(p: Dictionary) -> bool: return p["site"] == "tavern")
	verify(not inns.is_empty() and not taverns.is_empty(), "generated village tavern and roadside inn")
	if inns.is_empty():
		g.close()
		quit(1)
		return
	var p: Dictionary = inns[0]
	var door: Vector2i = p["door"]
	await move_to(door + Vector2i(0, 4))
	g.view.zoom = 23
	g.view.yaw = -.5
	g.view.tilt = 57
	await settle()
	await capture("inn-exterior")
	await move_to(door + Vector2i.DOWN)
	var opened := await request({"type": "use", "location": "surface", "x": door.x, "y": door.y})
	verify(opened.get("ok", false), "ordinary front door opens")
	g.client.move = Vector2i.UP
	await pump(25)
	g.client.move = Vector2i.ZERO
	await pump(5)
	verify(Movement.cell_of(g.client.position).y < door.y, "client walks through the actual entrance")
	g.view.zoom = 15
	await settle()
	await capture("inn-hall")
	var host := w.creatures.get_creature(String(w.hospitality.state(String(p["id"]))["host"]))
	verify(host != null, "persistent host exists")
	if host == null:
		g.close()
		quit(1)
		return
	await move_to(host.cell() + Vector2i(0, 2))
	w.grant(g.client.character_id, "base:coin", 30)
	w.needs.set_satiety(g.client.character_id, 10)
	w.needs.set_energy(g.client.character_id, 10)
	g._talk_rids[g.client.request({"type": "talk", "creature": host.id})] = host.id
	await pump(25)
	verify(g.talk_panel.visible and g.talk_panel.talk.has("services"), "normal conversation exposes services")
	g.talk_panel._food.pressed.emit()
	await pump(4)
	await capture("inn-food")
	var coins := w.inventory(g.client.character_id).count("base:coin")
	g.talk_panel._pay.pressed.emit()
	await pump(25)
	verify(w.needs.satiety_of(g.client.character_id) > 49, "UI order feeds the player through the server")
	verify(w.inventory(g.client.character_id).count("base:coin") == coins - 3, "UI order pays the fixed price")
	verify(w.inventory(g.client.character_id).count("base:bread") == 0, "service creates no resellable food")
	g.talk_panel._lodging.pressed.emit()
	await pump(4)
	g.talk_panel._pay.pressed.emit()
	await pump(25)
	verify(w.hospitality.lease(String(p["id"]), 0).get("actor", "") == g.client.character_id, "UI rents a specific bed")
	await capture("inn-lodging")
	g.talk_panel._ask_news.pressed.emit()
	await pump(4)
	await capture("inn-news")
	g.talk_panel.hide()
	var stairs := Vector2i.MAX
	for at: Vector2i in p["cells"]:
		if p["cells"][at].get("structure", "") == "base:wood_stairs":
			stairs = at
	await move_to(stairs + Vector2i.DOWN)
	var up := await request({"type": "climb", "location": "surface", "x": stairs.x, "y": stairs.y, "dir": "up"})
	verify(up.get("ok", false) and g.client.z == 1, "ordinary stairs reach the second floor over the network")
	var bed: Dictionary = p["beds"][0]
	await move_to(Vector2i(int(bed["x"]), int(bed["y"])))
	var slept := await request({"type": "sleep", "location": g.client.location, "x": int(bed["x"]), "y": int(bed["y"])})
	verify(slept.get("ok", false), "ordinary sleep accepts the rented upstairs bed")
	g.view.zoom = 12
	await settle()
	await pump(30)
	await capture("inn-bedroom")
	w.wake(g.client.character_id)
	await move_to(stairs + Vector2i.UP)
	var down := await request({"type": "climb", "location": g.client.location, "x": stairs.x, "y": stairs.y, "dir": "down"})
	verify(down.get("ok", false) and g.client.z == 0, "guest returns downstairs")
	if not taverns.is_empty():
		var tavern: Dictionary = taverns[0]
		await move_to((tavern["door"] as Vector2i) + Vector2i(0, 3))
		g.view.zoom = 19
		await settle()
		await capture("village-tavern")
		hour = 19.8
		await move_to((tavern["door"] as Vector2i) + Vector2i(0, -2))
		await pump(1000)
		var visitors := w.creatures.creatures.values().filter(func(c: Creature) -> bool:
			return c.state == "visit" and (tavern["rect"] as Rect2i).has_point(c.cell()))
		verify(visitors.size() >= 2, "existing residents actually visit and sit in the tavern")
		await settle()
		await capture("village-tavern-evening")
	hour = 12.0
	var large := {}
	for dy in range(district.y - 1, district.y + 2):
		for dx in range(district.x - 1, district.x + 2):
			for site: Dictionary in s.inns.of_cluster(0, dx, dy):
				if site["template"] == "base:roadside_inn_large":
					large = site
	if not large.is_empty():
		await move_to((large["door"] as Vector2i) + Vector2i(0, 4))
		g.view.zoom = 30
		await settle()
		await capture("inn-large-exterior")
		await move_to((large["door"] as Vector2i) + Vector2i(0, -2))
		await settle()
		await capture("inn-large-hall")
		plans = plans.duplicate()
		plans.append(large)
	verify(not large.is_empty(), "third layout exists in the generated world")
	var report := {"gpu": gpu, "checks": checks, "failures": failures, "sites": plans.map(func(site: Dictionary) -> Dictionary:
		return {"template": site["template"], "name": site["name"], "centre": [site["centre"].x, site["centre"].y]})}
	var file := FileAccess.open(output.path_join("runtime.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	g.close()
	app.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
