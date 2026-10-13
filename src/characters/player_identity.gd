class_name PlayerIdentity
extends RefCounted
## A key pair that identifies a player (or a server) without any account
## service (ADR-0003, ADR-0006). The private key never leaves its owner.
## Every key and signature carries an algorithm id, so another scheme can be
## added later without breaking stored profiles.

const KEY_ALG := "rsa3072"
const SIG_ALG := "rsa-pkcs1v15-sha256"
const KEY_BITS := 3072

var key: CryptoKey
## SHA-256 of the DER public key, hex. The id servers know a player by.
var fingerprint := ""
var _crypto := Crypto.new()


static func generate() -> PlayerIdentity:
	var id := PlayerIdentity.new()
	id.key = id._crypto.generate_rsa(KEY_BITS)
	id.fingerprint = fingerprint_of(id.public_pem())
	return id


## Loads <dir>/identity.key, creating it on first use. Null on a damaged file.
static func load_or_create(dir: String) -> PlayerIdentity:
	var path := dir.path_join("identity.key")
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(dir)
		var fresh := generate()
		if fresh.key.save(path) != OK:
			return null
		if OS.get_name() != "Windows":
			OS.execute("chmod", ["600", path])  # private key: owner only
		return fresh
	var id := PlayerIdentity.new()
	id.key = CryptoKey.new()
	if id.key.load(path) != OK:
		return null
	id.fingerprint = fingerprint_of(id.public_pem())
	return id


func public_pem() -> String:
	return key.save_to_string(true)


func sign(data: PackedByteArray) -> PackedByteArray:
	return _crypto.sign(HashingContext.HASH_SHA256, Hash.sha256(data), key)


## Fingerprint of a PEM public key; empty if it is not one.
static func fingerprint_of(pem: String) -> String:
	var body := ""
	for line in pem.split("\n"):
		var l := line.strip_edges()
		if l != "" and not l.begins_with("-----"):
			body += l
	var der := Marshalls.base64_to_raw(body)
	return Hash.sha256(der).hex_encode() if der.size() > 0 else ""


static func verify(key_alg: String, sig_alg: String, pem: String, data: PackedByteArray, signature: PackedByteArray) -> bool:
	if key_alg != KEY_ALG or sig_alg != SIG_ALG or pem.length() > 4096:
		return false
	var pub := CryptoKey.new()
	if pub.load_from_string(pem, true) != OK:
		return false
	return Crypto.new().verify(HashingContext.HASH_SHA256, Hash.sha256(data), signature, pub)
