class_name Cbor
## Deterministic CBOR (RFC 8949) for long-lived data (world entities, profiles).
## Our profile: definite lengths only, shortest integer heads, map keys sorted
## by the bytes of their encoding, floats always 64-bit, no tags.
## Values: null, bool, int, float, String/StringName, PackedByteArray, Array,
## Dictionary with int or String keys. Domain code converts vectors etc. itself.
## Decoding checks every length against the input: it is safe on untrusted bytes.

const MAX_DEPTH := 64

## Why the last encode() returned an empty buffer.
static var last_error := ""


class Decoded:
	var ok := false
	var value: Variant = null
	var error := ""


static func encode(value: Variant) -> PackedByteArray:
	last_error = ""
	var out := StreamPeerBuffer.new()
	out.big_endian = true
	if not _enc(out, value, 0, true):
		return PackedByteArray()
	return out.data_array


## Same format without sorting map keys: valid CBOR that decode() reads, but
## not byte-for-byte reproducible. For network messages, where speed matters
## and nothing is signed or stored; never for signed or stored data.
static func encode_fast(value: Variant) -> PackedByteArray:
	last_error = ""
	var out := StreamPeerBuffer.new()
	out.big_endian = true
	if not _enc(out, value, 0, false):
		return PackedByteArray()
	return out.data_array


static func decode(bytes: PackedByteArray) -> Decoded:
	var r := _Reader.new(bytes)
	var res := Decoded.new()
	var v: Variant = r.item(0)
	if r.error == "" and r.pos != bytes.size():
		r.error = "trailing bytes at %d" % r.pos
	res.error = r.error
	res.ok = r.error == ""
	res.value = v if res.ok else null
	return res


static func _head(out: StreamPeerBuffer, major: int, n: int) -> void:
	if n < 24:
		out.put_u8(major << 5 | n)
	elif n < 0x100:
		out.put_u8(major << 5 | 24)
		out.put_u8(n)
	elif n < 0x10000:
		out.put_u8(major << 5 | 25)
		out.put_u16(n)
	elif n < 0x100000000:
		out.put_u8(major << 5 | 26)
		out.put_u32(n)
	else:
		out.put_u8(major << 5 | 27)
		out.put_u64(n)


static func _enc(out: StreamPeerBuffer, v: Variant, depth: int, canonical: bool) -> bool:
	if depth > MAX_DEPTH:
		last_error = "nesting deeper than %d" % MAX_DEPTH
		return false
	match typeof(v):
		TYPE_NIL:
			out.put_u8(0xf6)
		TYPE_BOOL:
			out.put_u8(0xf5 if v else 0xf4)
		TYPE_INT:
			var i: int = v
			if i >= 0:
				_head(out, 0, i)
			else:
				_head(out, 1, -1 - i)
		TYPE_FLOAT:
			out.put_u8(0xfb)
			out.put_double(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var b := String(v).to_utf8_buffer()
			_head(out, 3, b.size())
			out.put_data(b)
		TYPE_PACKED_BYTE_ARRAY:
			var b: PackedByteArray = v
			_head(out, 2, b.size())
			out.put_data(b)
		TYPE_ARRAY:
			var a: Array = v
			_head(out, 4, a.size())
			for item: Variant in a:
				if not _enc(out, item, depth + 1, canonical):
					return false
		TYPE_DICTIONARY:
			var d: Dictionary = v
			if not canonical:
				_head(out, 5, d.size())
				for k: Variant in d:
					if typeof(k) != TYPE_INT and typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
						last_error = "map key of type %s" % type_string(typeof(k))
						return false
					_enc(out, k, depth + 1, false)
					if not _enc(out, d[k], depth + 1, false):
						return false
				return true
			var pairs: Array = []
			for k: Variant in d:
				if typeof(k) != TYPE_INT and typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
					last_error = "map key of type %s" % type_string(typeof(k))
					return false
				var kb := encode(k)
				pairs.append([kb, d[k]])
			pairs.sort_custom(func(a: Array, b: Array) -> bool: return _less(a[0], b[0]))
			for i in range(1, pairs.size()):
				if pairs[i][0] == pairs[i - 1][0]:
					last_error = "duplicate map key"
					return false
			_head(out, 5, pairs.size())
			for p: Array in pairs:
				out.put_data(p[0])
				if not _enc(out, p[1], depth + 1, true):
					return false
		_:
			last_error = "unsupported type %s" % type_string(typeof(v))
			return false
	return true


## Bytewise lexicographic order; a prefix sorts first.
static func _less(a: PackedByteArray, b: PackedByteArray) -> bool:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return a[i] < b[i]
	return a.size() < b.size()


class _Reader:
	var b: PackedByteArray
	var pos := 0
	var error := ""

	func _init(bytes: PackedByteArray) -> void:
		b = bytes

	func _fail(msg: String) -> Variant:
		if error == "":
			error = "%s at %d" % [msg, pos]
		return null

	func _uint(n: int) -> int:
		if pos + n > b.size():
			_fail("truncated")
			return 0
		var v := 0
		for i in n:
			v = (v << 8) | b[pos + i]
		pos += n
		return v

	## Returns the argument of a head, or -1 on error.
	func _arg(ai: int) -> int:
		if ai < 24:
			return ai
		if ai == 24:
			return _uint(1)
		if ai == 25:
			return _uint(2)
		if ai == 26:
			return _uint(4)
		if ai == 27:
			if pos < b.size() and b[pos] & 0x80:
				_fail("integer beyond 64-bit signed range")
				return -1
			return _uint(8)
		_fail("indefinite or reserved length")
		return -1

	func _bytes(n: int) -> PackedByteArray:
		if n < 0 or pos + n > b.size():
			_fail("truncated")
			return PackedByteArray()
		var out := b.slice(pos, pos + n)
		pos += n
		return out

	func item(depth: int) -> Variant:
		if depth > MAX_DEPTH:
			return _fail("nesting too deep")
		if pos >= b.size():
			return _fail("truncated")
		var ib := b[pos]
		pos += 1
		var major := ib >> 5
		var ai := ib & 0x1f
		if major == 7:
			match ai:
				20:
					return false
				21:
					return true
				22:
					return null
				25:
					return _half(_bytes(2))
				26:
					var f := _bytes(4)
					f.reverse()
					return f.decode_float(0) if error == "" else null
				27:
					var d := _bytes(8)
					d.reverse()
					return d.decode_double(0) if error == "" else null
			return _fail("unsupported simple value %d" % ai)
		var n := _arg(ai)
		if error != "":
			return null
		match major:
			0:
				return n
			1:
				return -1 - n
			2:
				return _bytes(n)
			3:
				return _bytes(n).get_string_from_utf8()
			4:
				if n > b.size() - pos:
					return _fail("array longer than input")
				var a: Array = []
				for i in n:
					a.append(item(depth + 1))
					if error != "":
						return null
				return a
			5:
				if n * 2 > b.size() - pos:
					return _fail("map longer than input")
				var d := {}
				for i in n:
					var k: Variant = item(depth + 1)
					if error != "":
						return null
					if typeof(k) != TYPE_INT and typeof(k) != TYPE_STRING:
						return _fail("unsupported map key")
					if d.has(k):
						return _fail("duplicate map key")
					d[k] = item(depth + 1)
					if error != "":
						return null
				return d
		return _fail("tags are not supported")

	func _half(h: PackedByteArray) -> Variant:
		if error != "":
			return null
		var bits := (h[0] << 8) | h[1]
		var e := (bits >> 10) & 0x1f
		var m := bits & 0x3ff
		var v: float
		if e == 0:
			v = m * pow(2.0, -24)
		elif e == 31:
			v = INF if m == 0 else NAN
		else:
			v = (1.0 + m / 1024.0) * pow(2.0, e - 15)
		return -v if bits & 0x8000 else v
