class_name TestCase
extends RefCounted
## Base class of a test suite. Every method named test_* is one test.
## A suite may override before_each/after_each; both may await.

var failures: Array[String] = []
var current := ""
## Command-line options of the run (--name=value pairs after "--").
var options: Dictionary = {}
## Engine errors the current test causes on purpose (a busy port); the
## runner fails a test only for errors beyond these.
var expected_errors := 0


func expect_errors(n: int) -> void:
	expected_errors += n


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func check(cond: bool, msg: String) -> bool:
	if not cond:
		failures.append("%s: %s" % [current, msg])
	return cond


func eq(actual: Variant, expected: Variant, msg := "") -> bool:
	# Compare by type as well: 1 == 1.0 must not pass for stored data.
	var same: bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		failures.append("%s: %sexpected %s, got %s" % [current, msg + ": " if msg else "", var_to_str(expected), var_to_str(actual)])
	return same


## Starts a Godot process of this project with a script; returns
## OS.execute_with_pipe()'s {stdio, stderr, pid} with non-blocking pipes.
func spawn_godot(script: String, user_args: Array) -> Dictionary:
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"), "-s", script, "--"]
	args.append_array(user_args)
	return OS.execute_with_pipe(OS.get_executable_path(), args, false)


## Reads the process output until a line starting with `prefix`; returns it,
## or "" if the process ended or the time ran out first. Never blocks forever
## (Godot's pipes do not report the end of a dead child's output).
func read_until(p: Dictionary, prefix: String, timeout_ms := 10000) -> String:
	var io: FileAccess = p["stdio"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var line := io.get_line()
		if line != "":
			if line.begins_with(prefix):
				return line
			continue
		if not OS.is_process_running(p["pid"]):
			return ""
		OS.delay_msec(5)
	return ""


## A clean directory for this test, as an absolute path.
func tmp_dir() -> String:
	var dir := ProjectSettings.globalize_path("user://test_tmp/" + current.replace("::", "/"))
	if DirAccess.dir_exists_absolute(dir):
		_remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


static func _remove_tree(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(sub))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
