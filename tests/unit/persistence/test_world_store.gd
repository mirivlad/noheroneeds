extends TestCase


func _open(dir: String, options := {}) -> WorldStore:
	var s := WorldStore.new()
	check(s.open(dir.path_join("world.db"), options), s.last_error)
	return s


func test_new_world_gets_current_schema() -> void:
	var s := _open(tmp_dir())
	eq(s.schema_version(), WorldStore.SCHEMA_VERSION)
	eq(s.read_meta("created_with"), GameInfo.VERSION)
	check(s.integrity_ok(), "integrity")
	s.close()


func test_data_survives_reopen() -> void:
	var dir := tmp_dir()
	var s := _open(dir)
	var c := Chunk.new()
	c.set_cell("structure", 1, 2, "base:stone_wall")
	check(s.begin(), s.last_error)
	s.put_chunk("surface", -3, 7, ChunkCodec.encode(c))
	s.put_inventory("p1", Cbor.encode({"base:stone": 5}))
	s.put_request("p1", "r1", 10, Cbor.encode({"ok": true}))
	check(s.commit(), s.last_error)
	s.close()
	var t := _open(dir)
	var back := ChunkCodec.decode(t.get_chunk("surface", -3, 7))
	check(back != null and back.same_as(c), "chunk")
	eq(Cbor.decode(t.get_inventory("p1")).value, {"base:stone": 5})
	check(not t.get_request("p1", "r1").is_empty(), "request ledger")
	check(t.get_chunk("surface", 0, 0).is_empty(), "missing chunk is empty")
	t.close()


func test_rollback_leaves_nothing() -> void:
	var s := _open(tmp_dir())
	s.begin()
	s.put_inventory("p1", Cbor.encode({"x": 1}))
	s.rollback()
	check(s.get_inventory("p1").is_empty(), "rolled back")
	s.close()


func test_newer_world_is_not_touched() -> void:
	var dir := tmp_dir()
	var s := _open(dir)
	s.write_meta("schema_version", "999")
	s.close()
	var before := FileAccess.get_file_as_bytes(dir.path_join("world.db"))
	var t := WorldStore.new()
	check(not t.open(dir.path_join("world.db")), "refuses a newer schema")
	check(t.last_error.contains("newer"), t.last_error)
	eq(FileAccess.get_file_as_bytes(dir.path_join("world.db")), before, "file unchanged")


func test_migration_backs_up_first_and_keeps_data() -> void:
	var dir := tmp_dir()
	var s := _open(dir)
	s.put_inventory("p1", Cbor.encode({"base:stone": 5}))
	s.close()
	# A later build adds a step: the old data must survive, and a backup must exist.
	var steps: Array = WorldStore.MIGRATIONS.duplicate()
	steps.append(["ALTER TABLE inventories ADD COLUMN note TEXT NOT NULL DEFAULT ''"])
	var t := _open(dir, {"migrations": steps})
	eq(t.schema_version(), 2)
	eq(Cbor.decode(t.get_inventory("p1")).value, {"base:stone": 5}, "data kept")
	check(t.backup_path != "" and FileAccess.file_exists(t.backup_path), "backup made: " + t.backup_path)
	t.close()
	var old := WorldStore.new()
	check(old.open(t.backup_path), old.last_error)
	eq(old.schema_version(), 1, "backup is the old version")
	old.close()
