extends TestCase
## Vectors from RFC 8949 appendix A, plus our deterministic rules and hostile input.


func _hex(v: Variant) -> String:
	return Cbor.encode(v).hex_encode()


func _dec(hex: String) -> Cbor.Decoded:
	var b := PackedByteArray()
	for i in range(0, hex.length(), 2):
		b.append(hex.substr(i, 2).hex_to_int())
	return Cbor.decode(b)


func test_rfc_vectors_encode() -> void:
	var cases := [
		[0, "00"], [23, "17"], [24, "1818"], [100, "1864"], [1000, "1903e8"],
		[1000000, "1a000f4240"], [1000000000000, "1b000000e8d4a51000"],
		[-1, "20"], [-10, "29"], [-100, "3863"], [-1000, "3903e7"],
		[1.1, "fb3ff199999999999a"], [false, "f4"], [true, "f5"], [null, "f6"],
		["", "60"], ["a", "6161"], ["IETF", "6449455446"], ["ü", "62c3bc"],
		[PackedByteArray([1, 2, 3, 4]), "4401020304"],
		[[], "80"], [[1, 2, 3], "83010203"], [{}, "a0"], [{1: 2, 3: 4}, "a201020304"],
		[{"a": 1, "b": [2, 3]}, "a26161016162820203"],
	]
	for c: Array in cases:
		eq(_hex(c[0]), c[1], var_to_str(c[0]))


func test_rfc_vectors_decode() -> void:
	var cases := [
		["f93c00", 1.0], ["f97bff", 65504.0], ["fa47c35000", 100000.0],
		["1b7fffffffffffffff", 9223372036854775807], ["3b7fffffffffffffff", -9223372036854775808],
		["a26161016162820203", {"a": 1, "b": [2, 3]}],
	]
	for c: Array in cases:
		var d := _dec(c[0])
		if check(d.ok, "%s decodes: %s" % [c[0], d.error]):
			eq(d.value, c[1], c[0])


func test_map_keys_sorted_by_encoding() -> void:
	# 10 -> 0a, "a" -> 6161, "b" -> 6162, whatever the insertion order.
	eq(_hex({"b": 1, "a": 2, 10: 3}), "a30a036161026162 01".replace(" ", ""))


func test_round_trip_nested() -> void:
	var v := {"id": Uuid.v4(), "pos": [12, -40], "hp": 7.5, "tags": ["a", "b"],
		"inv": {"base:oak_log": 12, "base:stone": 0}, "raw": PackedByteArray([0, 255]), "none": null}
	var d := Cbor.decode(Cbor.encode(v))
	check(d.ok, d.error)
	eq(d.value, v)
	eq(Cbor.encode(d.value), Cbor.encode(v), "re-encoding is byte-identical")


func test_unsupported_values_fail_loudly() -> void:
	eq(Cbor.encode(Vector2(1, 2)), PackedByteArray(), "vector")
	check(Cbor.last_error.contains("unsupported"), Cbor.last_error)
	eq(Cbor.encode({Vector2i(1, 1): 1}), PackedByteArray(), "vector key")


func test_hostile_input_is_rejected() -> void:
	var bad := {
		"truncated int": "19 01", "truncated text": "65 6869",
		"huge array": "9b 00ffffffffffffff", "huge map": "ba 7fffffff",
		"indefinite array": "9f 01 ff", "uint beyond int64": "1b ffffffffffffffff",
		"trailing": "01 02", "tag": "c1 1a514b67b0", "duplicate key": "a2 6161 01 6161 02",
		"array key": "a1 80 01", "empty": "",
	}
	for name: String in bad:
		var d := _dec(String(bad[name]).replace(" ", ""))
		check(not d.ok, name + " must fail")
	var deep := "81".repeat(100) + "01"
	check(not _dec(deep).ok, "nesting deeper than the limit")
