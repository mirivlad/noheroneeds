extends TestCase
## The dedicated server entry point as a separate process, and single-player.


func test_dedicated_server_process() -> void:
	var dir := tmp_dir()
	var port := 41100 + randi() % 400
	var p := spawn_godot("res://src/server/server_main.gd", ["--world=" + dir.path_join("world.db"),
		"--seed=431", "--preset=small", "--climate=cold",
		"--port=%d" % port, "--identity=" + ProjectSettings.globalize_path("user://test_keys/server")])
	var ready := read_until(p, "LISTENING")
	if not check(ready != "", "server started: " + (p["stderr"] as FileAccess).get_as_text()):
		OS.kill(p["pid"])
		return
	var content := ContentRegistry.load_packs(["res://content/base"])
	var owner := PlayerIdentity.load_or_create(ProjectSettings.globalize_path("user://test_keys/owner"))
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var ct := ENetTransport.new()
	ct.start_client("127.0.0.1", port)
	var client := GameClient.new(ct, owner, CharacterFile.export_signed(c, owner, content), content)
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and not (client.state == "playing" and client.has_position):
		client.step()
		OS.delay_msec(10)
	eq(client.state, "playing", client.reject_reason)
	eq(client.server_id, ready.split(" ")[2], "the server identified itself by its key")
	client.move = Vector2i(1, 0)
	for i in 30:
		client.step()
		OS.delay_msec(20)
	client.move = Vector2i.ZERO
	for i in 30:  # let the server confirm every input before leaving
		client.step()
		OS.delay_msec(20)
	var moved_to := client.position
	check(moved_to.x > 0, "moved")
	ct.close()
	# Clean stop through the stop file: everything is written before exit.
	FileAccess.open(dir.path_join("STOP"), FileAccess.WRITE).close()
	var stopped := read_until(p, "STOPPED") == "STOPPED"
	if not stopped:
		OS.kill(p["pid"])
	check(stopped, "stopped cleanly")
	var store := WorldStore.new()
	store.open(dir.path_join("world.db"))
	var place: Dictionary = Cbor.decode(store.get_world_character(c.character_id)).value
	eq(Vector2i(place["x"], place["y"]), moved_to, "last position saved on stop")
	var made: Variant = JSON.parse_string(store.read_meta("world_plan"))
	check(made is Dictionary, "the dedicated server wrote a global plan")
	if made is Dictionary:
		eq(int(made["seed"]), 431, "the dedicated server used the requested seed")
		eq(String(made["preset"]), "small", "and the requested preset")
		eq(String(made["climate"]), "cold", "and the requested climate")
	store.close()


func test_single_player_goes_through_the_server() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	c.inventory.add("base:plank", 3)
	var g := LocalGame.start(tmp_dir().path_join("world.db"), content, owner,
		PlayerIdentity.load_or_create(keys + "server"), CharacterFile.export_signed(c, owner, content))
	g.server.wait_for_disk = true
	for i in 20:
		g.step()
	eq(g.client.state, "playing", g.client.reject_reason)
	var rid := g.client.request({"type": "build", "location": "surface", "x": 1, "y": 1, "part": "base:wood_wall"})
	for i in 10:
		g.step()
	eq(g.client.results.get(rid), {"ok": true})
	g.close()
