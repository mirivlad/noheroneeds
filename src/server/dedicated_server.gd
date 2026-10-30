class_name DedicatedServer
extends Node
## A dedicated server (ADR-0004) as a node: the same in the sources
## (src/server/server_main.gd, tools/run_server.sh) and in a built game
## (`noheroneeds --headless -- --server [options]`). Options (without "--"
## in the dictionary):
##   --world=PATH         world database (default user://worlds/default/world.db)
##   --port=N             UDP port (default 24680)
##   --max-players=N      default 20
##   --identity=DIR       server key directory (default user://server_identity)
##   --content=DIR[,DIR]  content packs (default res://content/base)
##   --console            read commands ("stop") from the terminal
##   --stats=SECONDS      print "STATS {...}" (tick times, traffic) this often
##   --max-levels=N       highest building level new ceilings may create
##                        (default 3; lowering it keeps existing levels)
##   --starter-kit=ID:N[,ID:N]  items each character gets on its first arrival
##                        in this world (a world rule; none by default)
##   --starter-outfit=SLOT:ID[,SLOT:ID]  what a character wears when it wears
##                        nothing, e.g. torso:base:linen_shirt (none by default)
##   --day-minutes=N      how long a game day lasts in real minutes (default 24)
##   --pvp=off|free       whether characters may hurt characters (default off)
##   --death-drops=yes|no a character that dies leaves what it carried where it
##                        fell (default yes)
##   --break-others=yes|no  whether one may break someone else's building (no)
##   --all-recipes-known=yes|no  everyone knows every recipe (no; ADR-0047)
##   --crafts-never-fail=yes|no  attempts at a recipe always work (no)
##   --populate=N         (load tests) N more creatures around the spawn point
##   --stop-file=PATH     stop cleanly when this file appears (default: STOP
##                        next to the world database; it is removed on start)
##   --password=TEXT      only those who give it come in (or an invite; ADR-0060)
## Prints "LISTENING <port> <server id>" when ready, and "INVITE <invite>" for
## share links (nhn://address:port/invite) when there is a password.
##
## Stopping: type "stop" in the console, or create the stop file. Godot exits
## at once on SIGTERM and ignores SIGINT; that loses nothing acknowledged
## (the store is crash-safe) but drops the last unsaved positions.

var _server: GameServer
var _world: ServerWorld
var _transport: ENetTransport
## When the next tick is due (µs). Absolute time, not summed frame deltas:
## Godot smooths and caps deltas, which made the server drift below 20 Hz.
var _next_tick := 0
var _stop_file := ""
var _stop_requested := false
var _stdin := Thread.new()
var _next_stop_check := 0
var _stats_every := 0
var _next_stats := 0


## Starts serving with the options above (without "--"); "" or what went wrong.
func start(o: Dictionary) -> String:
	var world_path := ProjectSettings.globalize_path(String(o.get("world", "user://worlds/default/world.db")))
	DirAccess.make_dir_recursive_absolute(world_path.get_base_dir())
	var content := ContentRegistry.load_packs(String(o.get("content", "res://content/base")).split(","))
	if not content.errors.is_empty():
		return "content errors:\n  " + "\n  ".join(content.errors)
	var identity := PlayerIdentity.load_or_create(ProjectSettings.globalize_path(String(o.get("identity", "user://server_identity"))))
	if identity == null:
		return "cannot load or create the server key"
	_world = ServerWorld.open(world_path, content, {"require_planned": true})
	if _world == null:
		return "cannot open the world %s: %s" % [world_path, ServerWorld.open_error]
	_transport = ENetTransport.new()
	var port := int(o.get("port", "24680"))
	var err := _transport.start_server(port, int(o.get("max-players", "20")))
	if err != OK:
		_world.close()
		return "cannot listen on port %d: %s" % [port, error_string(err)]
	if o.has("max-levels"):
		_world.max_levels = int(o["max-levels"])
	for pair in String(o.get("starter-kit", "")).split(",", false):
		var at := pair.rfind(":")
		_world.starter_kit[pair.left(at)] = int(pair.substr(at + 1))
	if o.has("day-minutes"):
		_world.set_day_minutes(float(o["day-minutes"]))
	_world.combat.pvp = "free" if String(o.get("pvp", "off")) == "free" else "off"
	_world.combat.death_drops = String(o.get("death-drops", "yes")) != "no"
	_world.break_others = String(o.get("break-others", "no")) == "yes"
	_world.knowledge.all_known = String(o.get("all-recipes-known", "no")) == "yes"
	_world.knowledge.never_fail = String(o.get("crafts-never-fail", "no")) == "yes"
	for pair in String(o.get("starter-outfit", "")).split(",", false):
		var at := pair.find(":")
		_world.starter_outfit[pair.left(at)] = pair.substr(at + 1)
	if o.has("populate"):  # load tests: a crowd of creatures around the spawn point
		_world.creatures.spawn_crowd(int(o["populate"]), 40)
	_server = GameServer.new(_world, _transport, identity)
	_server.password = String(o.get("password", ""))
	_server.new_invite()
	_stats_every = int(o.get("stats", "0")) * 1000
	_next_stats = Time.get_ticks_msec() + _stats_every
	_stop_file = ProjectSettings.globalize_path(String(o.get("stop-file", world_path.get_base_dir().path_join("STOP"))))
	if FileAccess.file_exists(_stop_file):
		DirAccess.remove_absolute(_stop_file)
	if o.has("console"):
		_stdin.start(_read_console)
	print("LISTENING %d %s" % [port, identity.fingerprint])
	if _server.password != "":
		print("INVITE %s" % _server.invite)
	return ""


func _process(_delta: float) -> void:
	if _server == null:
		return
	if Time.get_ticks_msec() >= _next_stop_check:
		_next_stop_check = Time.get_ticks_msec() + 500
		if FileAccess.file_exists(_stop_file):
			DirAccess.remove_absolute(_stop_file)
			_stop_requested = true
	if _stop_requested:
		stop()
		return
	if _stats_every > 0 and Time.get_ticks_msec() >= _next_stats:
		_next_stats += _stats_every
		print("STATS " + JSON.stringify(_server.take_stats()))
	var tick_usec := 1000000 / GameServer.TICK_RATE
	var now := Time.get_ticks_usec()
	if _next_tick == 0:
		_next_tick = now
	var steps := 0
	while now >= _next_tick and steps < 4:  # catch up a little, never spiral
		_server.step()
		_next_tick += tick_usec
		steps += 1
		now = Time.get_ticks_usec()
	if now - _next_tick > tick_usec * 4:
		_next_tick = now  # too far behind: drop the backlog rather than rush
	elif now < _next_tick:
		OS.delay_usec(mini(_next_tick - now, 2000))  # do not spin a core while waiting


## Saves everything, lets everyone go and ends the program.
func stop() -> void:
	if _server:
		_server.shutdown()
		_transport.close()
		_world.close()
		_server = null
		print("STOPPED")
	if _stdin.is_started() and not _stdin.is_alive():
		_stdin.wait_to_finish()
	get_tree().quit()


## Console commands, on their own thread (reading stdin blocks).
func _read_console() -> void:
	while true:
		var line := OS.read_string_from_stdin(256).strip_edges()
		if line == "stop" or line == "quit":
			_stop_requested = true
			return
		if line == "" and _stop_requested:
			return
