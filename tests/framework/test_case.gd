class_name TestCase
extends RefCounted
## Base class of a test suite. Every method named test_* is one test.
## A suite may override before_each/after_each; both may await.

var failures: Array[String] = []
var current := ""
## Command-line options of the run (--name=value pairs after "--").
var options: Dictionary = {}


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
