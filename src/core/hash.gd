class_name Hash
## Hashes of raw bytes (String has sha256_buffer(), PackedByteArray does not).


static func sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not data.is_empty():  # nothing to add is a valid input (the engine complains of it)
		ctx.update(data)
	return ctx.finish()
