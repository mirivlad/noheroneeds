extends TestCase
## The player's worlds, characters and settings as the menu uses them.

var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])


func test_settings_keep_values_and_survive_bad_ones() -> void:
	var path := tmp_dir().path_join("settings.cfg")
	var s := GameSettings.load_from(path)
	eq(s.get_value("server_port"), 24680, "defaults without a file")
	s.set_value("fullscreen", true)
	s.set_value("view_zoom", 0.75)
	s.set_value("character", "abc")
	check(s.save(), "saved")
	var again := GameSettings.load_from(path)
	eq(again.get_value("fullscreen"), true)
	eq(again.get_value("view_zoom"), 0.75)
	eq(again.get_value("character"), "abc")
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "server_port", 80)
	cfg.set_value("settings", "volume", "loud")
	cfg.save(path)
	var fixed := GameSettings.load_from(path)
	eq(fixed.get_value("server_port"), 1024, "a port below 1024 is not offered")
	eq(fixed.get_value("volume"), 0.8, "a value of the wrong kind keeps the default")


func test_worlds_are_listed_last_played_first() -> void:
	var lib := WorldLibrary.new(tmp_dir())
	eq(lib.list(), [], "no worlds yet")
	var a := lib.create("Долина", {"seed": "42", "max_levels": 5, "starter_kit": false})
	var b := lib.create("Долина", {})
	check(a != b, "two worlds of one name: %s, %s" % [a, b])
	eq(lib.list(), [], "a world counts once it has a database")
	for id: String in [a, b]:
		var w := ServerWorld.open(lib.db_path(id), _content, {"seed": WorldLibrary.seed_of(lib.read_meta_only(id))})
		w.close()
	lib.touch(a)
	var all := lib.list()
	eq(all.size(), 2)
	eq(all[0]["id"], a, "last played first")
	eq(all[0]["max_levels"], 5)
	eq(all[0]["starter_kit"], false)
	eq(WorldLibrary.seed_of(all[0]), 42, "the seed as typed")
	eq(WorldLibrary.seed_of({"seed": "лес"}), WorldLibrary.seed_of({"seed": "лес"}), "a word is a seed too")
	var w := ServerWorld.open(lib.db_path(a), _content)
	WorldLibrary.apply_rules(all[0], w)
	eq(w.max_levels, 5, "the world's rules come with it")
	eq(w.starter_kit, {}, "no starter kit")
	eq(w.starter_outfit, WorldLibrary.STARTER_OUTFIT)
	w.close()


func test_a_world_from_before_the_library_is_kept() -> void:
	var root := tmp_dir()
	DirAccess.make_dir_recursive_absolute(root.path_join("local"))
	ServerWorld.open(root.path_join("local/world.db"), _content, {"seed": 7}).close()
	var all := WorldLibrary.new(root).list()
	eq(all.size(), 1)
	eq(all[0]["name"], "Мой мир")
	eq(all[0]["max_levels"], 3, "default rules")
	check(FileAccess.file_exists(root.path_join("local/world.json")), "its record is written")


func test_characters_create_list_and_choose() -> void:
	var root := tmp_dir()
	var me := PlayerIdentity.load_or_create(root.path_join("id"))
	var lib := CharacterLibrary.new(root.path_join("characters"), _content, me)
	var first := lib.current("")
	check(first != "", "a default character when there is none")
	var second := lib.create("Мара", {"hair": "base:human_hair_braid"})
	check(second != "", "created")
	eq(lib.create("X", {"hair": "base:no_such_hair"}), "", "an unknown style is refused")
	var names := []
	for c: Dictionary in lib.list():
		names.append(c["name"])
	eq(names, ["Мара", "Путник"])
	eq(lib.current(second), second, "the chosen one")
	eq(lib.current("gone"), lib.list()[0]["file"], "a missing choice falls back")
	eq(lib.load_character(second).styles["hair"], "base:human_hair_braid")
	check(CharacterFile.read(lib.file_bytes(second), _content).ok, "a signed file")


## Create a server and play: the host plays through the server, another
## player joins on the same port.
func test_hosted_game_takes_the_host_and_a_guest() -> void:
	var root := tmp_dir()
	var keys := root.path_join("keys")
	var host_id := PlayerIdentity.load_or_create(keys.path_join("host"))
	var guest_id := PlayerIdentity.load_or_create(keys.path_join("guest"))
	var host_c := PortableCharacter.create("Хозяин", "base:human_m")
	host_c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var guest_c := PortableCharacter.create("Гость", "base:human_m")
	guest_c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var port := 24900 + randi() % 500
	var g := HostedGame.start(root.path_join("world.db"), _content, host_id, PlayerIdentity.load_or_create(keys.path_join("server")),
		CharacterFile.export_signed(host_c, host_id, _content), port, 4, {"seed": 3})
	check(g.ok(), "hosting: " + g.error)
	var t := ENetTransport.new()
	t.start_client("127.0.0.1", port)
	var guest := GameClient.new(t, guest_id, CharacterFile.export_signed(guest_c, guest_id, _content), _content)
	for i in 200:
		g.step()
		guest.step()
		if g.client.state == "playing" and guest.state == "playing" and guest.entities.size() > 0:
			break
		OS.delay_msec(5)
	eq(g.client.state, "playing", "the host is in")
	eq(guest.state, "playing", "the guest is in")
	eq(g.world.present.size(), 2, "both in the world")
	expect_errors(2)  # ENet reports the busy port itself
	var busy := HostedGame.start(root.path_join("other.db"), _content, host_id, PlayerIdentity.load_or_create(keys.path_join("server")),
		CharacterFile.export_signed(host_c, host_id, _content), port, 4)
	check(not busy.ok() and busy.error.contains(str(port)), "a busy port is told: " + busy.error)
	t.close()
	g.close()
