extends TestCase
## Export, signatures, attestations and the receiving server's import checks.

static var _keys := {}
var reg: ContentRegistry


func before_each() -> void:
	reg = ContentRegistry.load_packs(["res://content/base"])


## Keys persist between runs (RSA-3072 generation takes seconds).
func _key(who: String) -> PlayerIdentity:
	if not _keys.has(who):
		_keys[who] = PlayerIdentity.load_or_create(ProjectSettings.globalize_path("user://test_keys/" + who))
	return _keys[who]


func _sample() -> PortableCharacter:
	var c := PortableCharacter.create("Мирослава", "base:humanoid_adult")
	c.styles = {"hair": "base:hair_braid", "face": "base:face_soft", "eyes": "base:eyes_round"}
	c.colors = {"skin": "#eab295", "hair": "#8a3a20", "eyes": "#2f7a52"}
	c.attributes = {"base:strength": 6, "base:agility": 9, "base:wits": 11}
	c.skills = {"base:carpentry": {"level": 12, "xp": 340}, "base:archery": {"level": 3, "xp": 20}}
	c.inventory.add("base:plank", 14)
	c.inventory.add("base:axe", 1)
	c.equipment = {"torso": "base:linen_shirt", "legs": "base:work_trousers", "feet": "base:boots"}
	c.known_recipes = PackedStringArray(["base:saw_planks"])
	c.achievements = PackedStringArray(["base:first_house"])
	return c


func _edit_body(file: PackedByteArray, change: Callable, signer: PlayerIdentity) -> PackedByteArray:
	var f: Dictionary = Cbor.decode(file).value
	var data: Dictionary = Cbor.decode(f["body"]).value
	change.call(data)
	f["body"] = Cbor.encode(data)
	f["owner"]["public_key"] = signer.public_pem()
	f["owner"]["signature"] = signer.sign(f["body"])
	return Cbor.encode(f)


func test_round_trip_keeps_everything() -> void:
	var c := _sample()
	eq(c.check_content(reg), PackedStringArray(), "sample is valid")
	var r := CharacterFile.read(CharacterFile.export_signed(c, _key("owner"), reg), reg)
	if check(r.ok, ", ".join(r.errors)):
		eq(r.character.to_data(), c.to_data())
		eq(r.owner, _key("owner").fingerprint)


func test_profile_holds_no_world_data() -> void:
	var keys := _sample().to_data().keys()
	keys.sort()
	eq(keys, ["achievements", "appearance", "attributes", "character_id", "created_with", "equipment",
		"inventory", "known_recipes", "name", "schema", "skills"])


func test_tampering_breaks_the_owner_signature() -> void:
	var file := CharacterFile.export_signed(_sample(), _key("owner"), reg)
	var f: Dictionary = Cbor.decode(file).value
	var body: PackedByteArray = f["body"]
	body[body.size() - 3] ^= 1
	f["body"] = body
	var r := CharacterFile.read(Cbor.encode(f), reg)
	check(not r.ok and r.errors[0].contains("signature"), ", ".join(r.errors))


func test_owner_can_resign_so_limits_belong_to_the_server() -> void:
	# A player edits their own file and signs it again: the signature is valid,
	# which is exactly why it proves authorship only.
	var file := CharacterFile.export_signed(_sample(), _key("owner"), reg)
	var cheat := _edit_body(file, func(d: Dictionary) -> void: d["skills"]["base:carpentry"]["level"] = 99, _key("owner"))
	check(CharacterFile.read(cheat, reg).ok, "the signature alone accepts it")
	var strict := CharacterFile.read(cheat, reg, {"max_skill_level": 50})
	check(not strict.ok, "a server limit refuses it")
	var over := _edit_body(file, func(d: Dictionary) -> void: d["skills"]["base:carpentry"]["level"] = 101, _key("owner"))
	check(not CharacterFile.read(over, reg).ok, "above the skill's own maximum")


func test_attestation() -> void:
	var server := _key("server")
	var file := CharacterFile.attest(CharacterFile.export_signed(_sample(), _key("owner"), reg), server, 1760000000)
	var trusted := CharacterFile.read(file, reg, {"trusted_servers": [server.fingerprint], "require_attestation": true})
	check(trusted.ok, ", ".join(trusted.errors))
	eq(trusted.trusted_attestations, PackedStringArray([server.fingerprint]))
	var stranger := CharacterFile.read(file, reg, {"trusted_servers": ["someone-else"], "require_attestation": true})
	check(not stranger.ok, "attestation from an untrusted server does not count")
	# Edited after the server vouched for it: the attestation no longer matches.
	var edited := _edit_body(file, func(d: Dictionary) -> void: d["name"] = "Другая", _key("owner"))
	var r := CharacterFile.read(edited, reg, {"trusted_servers": [server.fingerprint]})
	check(not r.ok and ", ".join(r.errors).contains("attestation"), ", ".join(r.errors))


func test_unknown_content_is_refused_with_its_name() -> void:
	var c := _sample()
	c.inventory.add("crystalmod:shard", 2)
	var r := CharacterFile.read(CharacterFile.export_signed(c, _key("owner"), reg), reg)
	check(not r.ok and ", ".join(r.errors).contains("crystalmod:shard"), ", ".join(r.errors))


func test_wrong_slot_and_body_plan_are_refused() -> void:
	var c := _sample()
	c.equipment = {"torso": "base:boots"}
	check(not c.check_content(reg).is_empty(), "boots on the torso")
	var d := _sample()
	d.styles.erase("eyes")
	check(not d.check_content(reg).is_empty(), "appearance slot left empty")


func test_hostile_files() -> void:
	var good := CharacterFile.export_signed(_sample(), _key("owner"), reg)
	var big := PackedByteArray()
	big.resize(CharacterFile.MAX_BYTES + 1)
	check(not CharacterFile.read(big, reg).ok, "oversized")
	check(not CharacterFile.read(PackedByteArray([1, 2, 3]), reg).ok, "garbage")
	var f: Dictionary = Cbor.decode(good).value
	var future := f.duplicate(true)
	future["version"] = 2
	check(not CharacterFile.read(Cbor.encode(future), reg).ok, "future file version")
	var alg := f.duplicate(true)
	alg["owner"]["sig_alg"] = "none"
	check(not CharacterFile.read(Cbor.encode(alg), reg).ok, "unknown signature algorithm")
	var bad_bodies := {
		"future schema": func(d: Dictionary) -> void: d["schema"] = 99,
		"bad uuid": func(d: Dictionary) -> void: d["character_id"] = "x",
		"long name": func(d: Dictionary) -> void: d["name"] = "a".repeat(200),
		"negative stack": func(d: Dictionary) -> void: d["inventory"]["stacks"]["base:plank"] = -5,
		"bad color": func(d: Dictionary) -> void: d["appearance"]["colors"]["skin"] = "red",
		"skills not a map": func(d: Dictionary) -> void: d["skills"] = [1, 2],
	}
	for name: String in bad_bodies:
		check(not CharacterFile.read(_edit_body(good, bad_bodies[name], _key("owner")), reg).ok, name)


func test_identity_persists() -> void:
	var dir := tmp_dir()
	var a := PlayerIdentity.load_or_create(dir)
	var b := PlayerIdentity.load_or_create(dir)
	eq(b.fingerprint, a.fingerprint, "same key after reload")
	check(PlayerIdentity.verify(PlayerIdentity.KEY_ALG, PlayerIdentity.SIG_ALG, a.public_pem(), PackedByteArray([1]), b.sign(PackedByteArray([1]))), "signs with the loaded key")
	if OS.get_name() != "Windows":
		var out: Array = []
		OS.execute("stat", ["-c", "%a", dir.path_join("identity.key")], out)
		eq(String(out[0]).strip_edges(), "600", "private key readable by the owner only")
