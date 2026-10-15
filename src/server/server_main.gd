extends SceneTree
## Dedicated server from the sources: godot --headless -s res://src/server/server_main.gd -- [options]
## (or tools/run_server.sh); a built game: noheroneeds --headless -- --server [options].
## The options and what it prints: DedicatedServer.


func _initialize() -> void:
	var o := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		o[kv[0]] = kv[1] if kv.size() > 1 else ""
	var server := DedicatedServer.new()
	root.add_child(server)
	var err := server.start(o)
	if err != "":
		printerr(err)
		quit(1)
