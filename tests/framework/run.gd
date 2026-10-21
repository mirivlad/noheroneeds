extends SceneTree
## Headless test runner (see tools/run_tests.sh):
##   godot --headless --path . -s res://tests/framework/run.gd -- [--only=path_part] [--test=name_part] [--bench]
## Finds tests/**/test_*.gd; with --bench also tests/bench/bench_*.gd (slow measurements).
## Exit code: 0 when every check passed, 1 otherwise.
## A test that runs over TEST_LIMIT_S (--test_limit=S; an hour with --bench) or
## makes over ErrorCounter.FLOOD engine errors stops the run at once, loudly
## (on stderr): broken code must not grind on for the whole timeout.


## Counts engine and script errors, so a test whose code broke fails even if
## no check of its own failed. A flood of them (code that breaks every frame)
## stops the run at once instead of letting it grind on to the timeout.
class ErrorCounter:
	extends Logger
	var count := 0
	var last := ""
	## Errors when the running test began, and its name ("" between tests).
	var base := 0
	var test := ""
	## Errors a test may make before the run is stopped as broken.
	const FLOOD := 500

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtrace: Array[ScriptBacktrace]) -> void:
		count += 1
		last = "%s (%s:%d %s)" % [rationale if rationale != "" else code, file.get_file(), line, function]
		if test != "" and count - base > FLOOD:
			stop("ERROR FLOOD: %s made over %d engine errors, last: %s" % [test, FLOOD, last])

	## Stops the whole run, loudly: what is broken would only grind on to the
	## timeout (tests step frames in loops a timer cannot break into).
	static func stop(why: String) -> void:
		printerr("\n" + why + "\nSTOPPED: the run was ended early")
		OS.kill(OS.get_process_id())


## Seconds a test may run before the run is stopped (its waits never came true).
const TEST_LIMIT_S := 180

var _errors := ErrorCounter.new()
var _watchdog := Thread.new()
var _test_began := 0
var _limit_s := TEST_LIMIT_S
var _done := false


func _watch() -> void:
	while not _done:
		OS.delay_msec(1000)
		if _errors.test != "" and Time.get_ticks_msec() - _test_began > _limit_s * 1000:
			ErrorCounter.stop("TOO LONG: %s ran over %d s (a wait in it never came true: something broke)" % [_errors.test, _limit_s])


func _initialize() -> void:
	OS.add_logger(_errors)
	_watchdog.start(_watch)
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
	var expected := 0
	var t0 := Time.get_ticks_msec()
	if opts.has("bench"):
		_limit_s = 3600  # measurements take their time
	if opts.has("test_limit"):
		_limit_s = int(opts["test_limit"])
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
			var errors_before := _errors.count
			suite.expected_errors = 0
			var t := Time.get_ticks_msec()
			_test_began = t
			_errors.base = _errors.count
			_errors.test = suite.current
			await suite.before_each()
			await suite.call(mname)
			await suite.after_each()
			_errors.test = ""
			expected += mini(suite.expected_errors, _errors.count - errors_before)
			if _errors.count - errors_before > suite.expected_errors:
				suite.failures.append("%s: %d engine/script error(s), last: %s" % [suite.current,
					_errors.count - errors_before - suite.expected_errors, _errors.last])
			var ok := suite.failures.size() == before
			print("%s %s (%d ms)" % ["PASS" if ok else "FAIL", suite.current, Time.get_ticks_msec() - t])
			for f in suite.failures.slice(before):
				print("    - " + f)
		failed += suite.failures.size()
	_done = true
	_watchdog.wait_to_finish()
	Art.clear()  # cached pictures and the theme, not to be held at exit
	print("expected engine errors: %d" % expected)
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
