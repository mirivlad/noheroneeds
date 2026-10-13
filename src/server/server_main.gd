extends SceneTree
## Dedicated server: godot --headless -s res://src/server/server_main.gd -- [options]
## (or tools/run_server.sh). Options:
##   --world=PATH         world database (default user://worlds/default/world.db)
##   --port=N             UDP port (default 24680)
##   --max-players=N      default 20
##   --identity=DIR       server key directory (default user://server_identity)
##   --content=DIR[,DIR]  content packs (default res://content/base)
##   --stop-file=PATH     stop cleanly when this file appears (default: STOP
##                        next to the world database; it is removed on start)
## Prints "LISTENING <port> <server id>" when ready.
##
## Stopping: type "stop" in the console, or create the stop file. Godot exits
## at once on SIGTERM and ignores SIGINT; that loses nothing acknowledged
## (the store is crash-safe) but drops the last unsaved positions.

var _server: GameServer
var _world: ServerWorld
var _transport: ENetTransport
var _accum := 0.0
var _stop_file := ""
var _stop_requested := false
var _stdin := Thread.new()
var _next_stop_check := 0


func _initialize() -> void:
	var o := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		o[kv[0]] = kv[1] if kv.size() > 1 else ""
	var world_path := ProjectSettings.globalize_path(String(o.get("world", "user://worlds/default/world.db")))
	DirAccess.make_dir_recursive_absolute(world_path.get_base_dir())
	var content := ContentRegistry.load_packs(String(o.get("content", "res://content/base")).split(","))
	if not content.errors.is_empty():
		return _fail("content errors:\n  " + "\n  ".join(content.errors))
	var identity := PlayerIdentity.load_or_create(ProjectSettings.globalize_path(String(o.get("identity", "user://server_identity"))))
	if identity == null:
		return _fail("cannot load or create the server key")
	_world = ServerWorld.open(world_path, content)
	if _world == null:
		return _fail("cannot open the world " + world_path)
	_transport = ENetTransport.new()
	var port := int(o.get("port", "24680"))
	var err := _transport.start_server(port, int(o.get("max-players", "20")))
	if err != OK:
		_world.close()
		return _fail("cannot listen on port %d: %s" % [port, error_string(err)])
	_server = GameServer.new(_world, _transport, identity)
	_stop_file = ProjectSettings.globalize_path(String(o.get("stop-file", world_path.get_base_dir().path_join("STOP"))))
	if FileAccess.file_exists(_stop_file):
		DirAccess.remove_absolute(_stop_file)
	_stdin.start(_read_console)
	print("LISTENING %d %s" % [port, identity.fingerprint])


func _process(delta: float) -> bool:
	if _server == null:
		return false
	if Time.get_ticks_msec() >= _next_stop_check:
		_next_stop_check = Time.get_ticks_msec() + 500
		if FileAccess.file_exists(_stop_file):
			DirAccess.remove_absolute(_stop_file)
			_stop_requested = true
	if _stop_requested:
		return true  # quit; _finalize() saves everything
	_accum += delta
	var tick_len := 1.0 / GameServer.TICK_RATE
	var steps := 0
	while _accum >= tick_len and steps < 4:  # catch up a little, never spiral
		_server.step()
		_accum -= tick_len
		steps += 1
	if _accum > tick_len * 4:
		_accum = 0.0
	return false


func _finalize() -> void:
	if _server:
		_server.shutdown()
		_transport.close()
		_world.close()
		print("STOPPED")


## Console commands, on their own thread (reading stdin blocks).
func _read_console() -> void:
	while true:
		var line := OS.read_string_from_stdin(256).strip_edges()
		if line == "stop" or line == "quit":
			_stop_requested = true
			return
		if line == "" and _stop_requested:
			return


func _fail(msg: String) -> void:
	printerr(msg)
	quit(1)
