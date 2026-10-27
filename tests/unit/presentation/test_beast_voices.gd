extends TestCase
## Beasts' voices (the author, 27.10.2026): rare, by events — a cow moos now and
## then, a wolf growls at its blow and howls once when it starts a hunt, all cry
## when they die.


func test_voices_come_as_data_by_events() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var moo := content.sound_of("base:cow", "voice")
	check(not moo.is_empty() and (moo["every"] as Array)[0] >= 30, "a cow moos, and not often: " + str(moo.get("every")))
	for event: String in ["attack", "chase", "death"]:
		check(not content.sound_of("base:wolf", event).is_empty(), "a wolf's " + event)
	check(content.sound_of("base:wolf", "voice").is_empty(), "a wolf is otherwise silent")
	for d: Dictionary in [moo, content.sound_of("base:wolf", "chase")]:
		for path: String in d["paths"]:
			check(Art.audio(path) != null, "plays: " + path)
