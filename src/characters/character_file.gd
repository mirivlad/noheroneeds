class_name CharacterFile
## The exported character (.nhnchar), ADR-0006. Deterministic CBOR:
##   {"format": "nhn.character", "version": 1,
##    "body": bytes — CBOR of PortableCharacter.to_data() + content manifest,
##    "owner": {"key_alg", "public_key", "sig_alg", "signature" over body},
##    "attestations": [{"payload": bytes — CBOR {character_id, body_sha256,
##        server_id, issued_at}, "key_alg", "public_key", "sig_alg", "signature"}]}
## Signatures cover exact bytes, so nothing needs re-canonicalising.
##
## The owner's signature proves who issued the file, not that its contents are
## honest: the owner can edit and re-sign. A server attestation says the
## character had this exact body on that server. Neither prevents copying;
## protection against duplication across servers is a separate design (Q-01).

const FORMAT := "nhn.character"
const VERSION := 1
const MAX_BYTES := 256 * 1024
const MAX_ATTESTATIONS := 16


class Imported:
	var ok := false
	var errors := PackedStringArray()
	var character: PortableCharacter
	## Fingerprint of the owner's key.
	var owner := ""
	## Server ids (key fingerprints) whose attestation is valid and trusted by the policy.
	var trusted_attestations := PackedStringArray()


static func export_signed(c: PortableCharacter, owner: PlayerIdentity, reg: ContentRegistry) -> PackedByteArray:
	var data := c.to_data()
	data["content"] = c.content_manifest(reg)
	var body := Cbor.encode(data)
	return Cbor.encode({
		"format": FORMAT, "version": VERSION, "body": body,
		"owner": {"key_alg": PlayerIdentity.KEY_ALG, "public_key": owner.public_pem(),
			"sig_alg": PlayerIdentity.SIG_ALG, "signature": owner.sign(body)},
		"attestations": [],
	})


## A server vouches for the body in `file` as it is now. Returns the new file.
static func attest(file: PackedByteArray, server: PlayerIdentity, issued_at: int) -> PackedByteArray:
	var d := Cbor.decode(file)
	if not d.ok:
		return PackedByteArray()
	var f: Dictionary = d.value
	var body: PackedByteArray = f["body"]
	var payload := Cbor.encode({"character_id": Cbor.decode(body).value["character_id"],
		"body_sha256": Hash.sha256(body), "server_id": server.fingerprint, "issued_at": issued_at})
	(f["attestations"] as Array).append({"payload": payload, "key_alg": PlayerIdentity.KEY_ALG,
		"public_key": server.public_pem(), "sig_alg": PlayerIdentity.SIG_ALG, "signature": server.sign(payload)})
	return Cbor.encode(f)


## Full check on the receiving server. policy:
##   "trusted_servers": Array of server ids whose attestations count,
##   "require_attestation": bool — refuse without a trusted attestation,
##   "max_skill_level": int — this server's own ceiling (optional).
static func read(file: PackedByteArray, reg: ContentRegistry, policy := {}) -> Imported:
	var r := Imported.new()
	if file.size() > MAX_BYTES:
		r.errors.append("file larger than %d bytes" % MAX_BYTES)
		return r
	var d := Cbor.decode(file)
	if not d.ok or typeof(d.value) != TYPE_DICTIONARY:
		r.errors.append("not a character file: " + d.error)
		return r
	var f: Dictionary = d.value
	if f.get("format") != FORMAT:
		r.errors.append("not a character file")
		return r
	if typeof(f.get("version")) != TYPE_INT or int(f["version"]) != VERSION:
		r.errors.append("unsupported file version %s" % str(f.get("version")))
		return r
	var body: Variant = f.get("body")
	var owner: Variant = f.get("owner")
	if typeof(body) != TYPE_PACKED_BYTE_ARRAY or typeof(owner) != TYPE_DICTIONARY:
		r.errors.append("body or owner missing")
		return r
	if not _signed(owner, body):
		r.errors.append("owner signature does not match the contents")
		return r
	r.owner = PlayerIdentity.fingerprint_of(String(owner["public_key"]))
	var bd := Cbor.decode(body)
	if not bd.ok or typeof(bd.value) != TYPE_DICTIONARY:
		r.errors.append("body unreadable: " + bd.error)
		return r
	var data := PortableCharacter.migrate(bd.value)
	if data.is_empty():
		r.errors.append("unsupported character schema %s" % str((bd.value as Dictionary).get("schema")))
		return r
	r.errors.append_array(PortableCharacter.check_structure(data))
	if not r.errors.is_empty():
		return r
	var c := PortableCharacter.from_data(data)
	r.errors.append_array(c.check_content(reg))
	if policy.has("max_skill_level"):
		for s: String in c.skills:
			if int(c.skills[s]["level"]) > int(policy["max_skill_level"]):
				r.errors.append("skill '%s' above this server's limit" % s)
	var atts: Variant = f.get("attestations", [])
	if typeof(atts) != TYPE_ARRAY or (atts as Array).size() > MAX_ATTESTATIONS:
		r.errors.append("attestations malformed")
		return r
	var trusted: Array = policy.get("trusted_servers", [])
	for a: Variant in atts:
		var server := _attestation_server(a, body, c.character_id)
		if server == "":
			r.errors.append("an attestation is invalid or does not match this character")
		elif trusted.has(server):
			r.trusted_attestations.append(server)
	if policy.get("require_attestation", false) and r.trusted_attestations.is_empty():
		r.errors.append("no attestation from a server this one trusts")
	r.ok = r.errors.is_empty()
	r.character = c if r.ok else null
	return r


static func _signed(sig: Dictionary, data: PackedByteArray) -> bool:
	if typeof(sig.get("public_key")) != TYPE_STRING or typeof(sig.get("signature")) != TYPE_PACKED_BYTE_ARRAY:
		return false
	return PlayerIdentity.verify(String(sig.get("key_alg", "")), String(sig.get("sig_alg", "")),
		sig["public_key"], data, sig["signature"])


## The server id of a valid attestation for exactly this body, or "".
static func _attestation_server(a: Variant, body: PackedByteArray, character_id: String) -> String:
	if typeof(a) != TYPE_DICTIONARY or typeof(a.get("payload")) != TYPE_PACKED_BYTE_ARRAY:
		return ""
	if not _signed(a, a["payload"]):
		return ""
	var p := Cbor.decode(a["payload"])
	if not p.ok or typeof(p.value) != TYPE_DICTIONARY:
		return ""
	var pv: Dictionary = p.value
	var server := PlayerIdentity.fingerprint_of(String(a["public_key"]))
	if pv.get("server_id") != server or pv.get("character_id") != character_id or pv.get("body_sha256") != Hash.sha256(body):
		return ""
	return server
