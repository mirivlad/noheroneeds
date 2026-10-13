class_name Hash
## Hashes of raw bytes (String has sha256_buffer(), PackedByteArray does not).


static func sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()
