extends TestCase
## Hashes of raw bytes, the empty input too (it is hashed, quietly).


func test_sha256_of_bytes_and_of_nothing() -> void:
	eq(Hash.sha256(PackedByteArray()).hex_encode(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	eq(Hash.sha256("abc".to_utf8_buffer()).hex_encode(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
