extends TestCase


func test_v4_format_and_uniqueness() -> void:
	var seen := {}
	for i in 1000:
		var u := Uuid.v4()
		if not check(Uuid.is_valid(u), "valid v4: " + u):
			return
		seen[u] = true
	eq(seen.size(), 1000, "no repeats")


func test_rejects_other_text() -> void:
	check(not Uuid.is_valid(""), "empty")
	check(not Uuid.is_valid("123e4567-e89b-12d3-a456-426614174000"), "version 1")
	check(not Uuid.is_valid("9F1C2A3B-0000-4000-8000-000000000000"), "uppercase")
