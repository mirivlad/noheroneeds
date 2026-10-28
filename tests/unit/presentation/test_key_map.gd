extends TestCase
## The keys (UI 2.0, stage F): defaults, a key set anew, no two actions on
## one key, kept in the settings.


func test_keys_set_anew_and_kept() -> void:
	var path := tmp_dir().path_join("settings.cfg")
	var s := GameSettings.load_from(path)
	eq(KeyMap.key(s, "things"), KEY_I, "by default")
	eq(KeyMap.action_of(s, KEY_E), "use")
	KeyMap.bind(s, "things", KEY_TAB)
	eq(KeyMap.key(s, "things"), KEY_TAB, "set anew")
	eq(KeyMap.action_of(s, KEY_I), "", "the old key does nothing now")
	KeyMap.bind(s, "jump", KEY_E)
	eq(KeyMap.key(s, "jump"), KEY_E, "taken from another action")
	eq(KeyMap.key(s, "use"), KEY_J, "which gets this one's old key: never two on one")
	s.save()
	var again := GameSettings.load_from(path)
	eq(KeyMap.key(again, "things"), KEY_TAB, "kept in the settings")
	KeyMap.bind(again, "things", KEY_I)
	check(not (again.get_value("keys") as Dictionary).has("things"), "a key as by default is not kept")
	var actions := KeyMap.ACTIONS.map(func(a: Array) -> int: return int(a[2]))
	eq(actions.size(), KeyMap.ACTIONS.size())
	for k: int in actions:
		eq(actions.count(k), 1, "defaults never share a key: %s" % KeyMap.key_name(k))
