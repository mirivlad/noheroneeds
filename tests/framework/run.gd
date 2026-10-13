extends SceneTree
## Headless test runner (see tools/run_tests.sh):
##   godot --headless --path . -s res://tests/framework/run.gd -- [--only=path_part] [--test=name_part] [--bench]
## Finds tests/**/test_*.gd; with --bench also tests/bench/bench_*.gd (slow measurements).
## Exit code: 0 when every check passed, 1 otherwise.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var opts := _options()
	var suites: Array[String] = []
	_collect("res://tests", "test_", suites)
	if opts.has("bench"):
		_collect("res://tests/bench", "bench_", suites)
	suites.sort()
	var only: String = opts.get("only", "")
	var one: String = opts.get("test", "")
	var total := 0
	var failed := 0
	var t0 := Time.get_ticks_msec()
	for path in suites:
		if only != "" and not path.contains(only):
			continue
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			failed += 1
			print("FAIL %s: does not load" % path)
			continue
		var suite: TestCase = script.new()
		suite.options = opts
		for m in suite.get_method_list():
			var mname: String = m["name"]
			if not (mname.begins_with("test_") or mname.begins_with("bench_")):
				continue
			if one != "" and not mname.contains(one):
				continue
			total += 1
			suite.current = "%s::%s" % [path.get_file().get_basename(), mname]
			var before := suite.failures.size()
			var t := Time.get_ticks_msec()
			await suite.before_each()
			await suite.call(mname)
			await suite.after_each()
			var ok := suite.failures.size() == before
			print("%s %s (%d ms)" % ["PASS" if ok else "FAIL", suite.current, Time.get_ticks_msec() - t])
			for f in suite.failures.slice(before):
				print("    - " + f)
		failed += suite.failures.size()
	print("\n%d tests, %d failed checks, %.1fs" % [total, failed, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if failed == 0 and total > 0 else 1)


func _collect(dir: String, prefix: String, out: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(dir):
		if sub != "bench" and sub != "framework":
			_collect(dir.path_join(sub), prefix, out)
	for f in DirAccess.get_files_at(dir):
		if f.begins_with(prefix) and f.ends_with(".gd"):
			out.append(dir.path_join(f))


func _options() -> Dictionary:
	var opts := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var kv := arg.substr(2).split("=", true, 1)
			opts[kv[0]] = kv[1] if kv.size() > 1 else true
	return opts
