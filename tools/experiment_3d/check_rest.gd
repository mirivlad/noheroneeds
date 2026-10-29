extends SceneTree
## Real game window, disposable profile: sleeping/death frames at several
## camera angles. No player's saves are opened.
var app: App
var g: GameScreen
var output := "res://build/rest-review"

func _initialize() -> void:
	call_deferred("run")

func pump(count: int) -> void:
	for i in count:
		g.game.step()
		g.view.update_view(1, .05)
		await process_frame

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func run() -> void:
	output = ProjectSettings.globalize_path(output)
	DirAccess.make_dir_recursive_absolute(output)
	app = App.new()
	app.configure({"profile_dir": output.path_join("profile-" + str(Time.get_ticks_usec())), "world": "rest", "body": "base:human_ro_m"})
	root.add_child(app)
	g = app.game
	g.set_process(false)
	await pump(50)
	var w := g.game.world
	w.world_time = 12 * Daylight.HOUR_MS
	var rng := RandomNumberGenerator.new()
	rng.seed = 43
	var sleepers: Array[Creature] = []
	for i in 3:
		var at := Vector2i(-3 + i * 3, 1)
		var c := w.creatures._spawn("base:villager", "surface", at, CreatureSim.villager_looks(rng), i)
		c.job = {"name": "Спящий", "profession": "base:farmer"}
		c.asleep = true
		c.face = [Vector2i.DOWN, Vector2i.RIGHT, Vector2i.UP][i]
		w.creatures._schedule(c, 1000000)
		sleepers.append(c)
	w.move_character(g.client.character_id, Vector2i(0, 4) * 256 + Vector2i(128, 128))
	g.view.zoom = 10
	await pump(100)
	var view := g.view as WorldView3D
	for angle in [0.0, 1.0, 2.3]:
		view.yaw = angle
		view.tilt = 40 if angle == 1.0 else 60
		await pump(8)
		await capture("sleep-yaw-%.1f" % angle)
	# The same frame used by death must keep the same projection.
	var actor := view._actors.get(sleepers[1].id) as BillboardActor3D
	var sleeping := actor != null and (actor.doll as RoSprite)._once == "dead"
	print("REST_POSE asleep=", sleeping)
	if actor:
		actor.doll.react("dead", 1000)
		await pump(20)
		await capture("fallen")
	var gpu := RenderingServer.get_video_adapter_name()
	print("REST_REVIEW gpu=", gpu, " output=", output)
	g.close()
	app.queue_free()
	await process_frame
	quit(0 if gpu.contains("RX 580") and sleeping else 1)
