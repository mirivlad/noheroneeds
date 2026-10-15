class_name WorldStore
extends RefCounted
## One world in one SQLite database (ADR-0005). Holds encoded blobs; it does
## not know game rules. Writes that must land together go inside
## begin()/commit(); a failed commit is rolled back and reported.

const SCHEMA_VERSION := 3

## MIGRATIONS[n] upgrades schema version n to n + 1. Never edit a published
## step: add a new one. Step 0 creates the first schema.
const MIGRATIONS: Array = [
	[
		"CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID",
		"CREATE TABLE chunks(location TEXT NOT NULL, cx INTEGER NOT NULL, cy INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(location, cx, cy)) WITHOUT ROWID",
		"CREATE TABLE entities(id TEXT PRIMARY KEY, location TEXT NOT NULL, cx INTEGER NOT NULL, cy INTEGER NOT NULL, kind TEXT NOT NULL, data BLOB NOT NULL) WITHOUT ROWID",
		"CREATE INDEX entities_by_chunk ON entities(location, cx, cy)",
		"CREATE TABLE inventories(owner TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID",
		"CREATE TABLE requests(actor TEXT NOT NULL, request_id TEXT NOT NULL, tick INTEGER NOT NULL, result BLOB NOT NULL, PRIMARY KEY(actor, request_id)) WITHOUT ROWID",
		"CREATE INDEX requests_by_tick ON requests(tick)",
	],
	# 1 -> 2: characters as this world knows them, apart from their place in it.
	[
		"CREATE TABLE characters(character_id TEXT PRIMARY KEY, owner TEXT NOT NULL, data BLOB NOT NULL) WITHOUT ROWID",
		"CREATE TABLE world_characters(character_id TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID",
	],
	# 2 -> 3: locations other than the surface (building levels; later caves).
	[
		"CREATE TABLE locations(location_id TEXT PRIMARY KEY, kind TEXT NOT NULL, building TEXT NOT NULL, z INTEGER NOT NULL, data BLOB NOT NULL) WITHOUT ROWID",
		"CREATE INDEX locations_by_building ON locations(building, z)",
	],
]

var path := ""
var last_error := ""
## Set when open() made a backup before migrating.
var backup_path := ""
var _db: SQLite
var _migrations: Array = MIGRATIONS
var _in_tx := false


## options: "synchronous" ("FULL" default, or "NORMAL"); "migrations" (tests only).
func open(db_path: String, options := {}) -> bool:
	path = db_path
	_migrations = options.get("migrations", MIGRATIONS)
	_db = SQLite.new()
	_db.path = db_path
	_db.verbosity_level = SQLite.QUIET
	if not _db.open_db():
		return _fail("cannot open " + db_path)
	if not (_exec("PRAGMA journal_mode=WAL") and _exec("PRAGMA synchronous=" + String(options.get("synchronous", "FULL")))
			and _exec("PRAGMA busy_timeout=5000")):
		return false
	var version := _schema_version()
	if version < 0:
		return false
	if version > _migrations.size():
		# Made by a newer build: never touch it.
		_db.close_db()
		return _fail("world schema %d is newer than this build (%d)" % [version, _migrations.size()])
	if version < _migrations.size():
		return _migrate(version)
	return true


func close() -> void:
	if _db:
		_db.close_db()
		_db = null


func schema_version() -> int:
	return _schema_version()


func begin() -> bool:
	if _in_tx:
		return _fail("nested transaction")
	_in_tx = _exec("BEGIN IMMEDIATE")
	return _in_tx


func commit() -> bool:
	_in_tx = false
	if _exec("COMMIT"):
		return true
	var err := last_error
	_exec("ROLLBACK")
	return _fail("commit failed: " + err)


func rollback() -> void:
	_in_tx = false
	_exec("ROLLBACK")


# --- meta ----------------------------------------------------------------

func read_meta(key: String, default := "") -> String:
	_db.query_with_bindings("SELECT value FROM meta WHERE key=?", [key])
	return _db.query_result[0]["value"] if _db.query_result.size() else default


func write_meta(key: String, value: String) -> bool:
	return _exec_b("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])


# --- chunks --------------------------------------------------------------

func put_chunk(location: String, cx: int, cy: int, data: PackedByteArray) -> bool:
	return _exec_b("INSERT INTO chunks(location, cx, cy, data) VALUES(?, ?, ?, ?) ON CONFLICT(location, cx, cy) DO UPDATE SET data=excluded.data",
		[location, cx, cy, data])


## Empty when the chunk was never stored.
func get_chunk(location: String, cx: int, cy: int) -> PackedByteArray:
	_db.query_with_bindings("SELECT data FROM chunks WHERE location=? AND cx=? AND cy=?", [location, cx, cy])
	return _db.query_result[0]["data"] if _db.query_result.size() else PackedByteArray()


func count_chunks() -> int:
	_db.query("SELECT count(*) AS n FROM chunks")
	return _db.query_result[0]["n"]


# --- entities ------------------------------------------------------------

func put_entity(id: String, location: String, cx: int, cy: int, kind: String, data: PackedByteArray) -> bool:
	return _exec_b("INSERT INTO entities(id, location, cx, cy, kind, data) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET location=excluded.location, cx=excluded.cx, cy=excluded.cy, kind=excluded.kind, data=excluded.data",
		[id, location, cx, cy, kind, data])


func delete_entity(id: String) -> bool:
	return _exec_b("DELETE FROM entities WHERE id=?", [id])


## Drops every entity of a kind (things on the ground go when a world starts).
func delete_entities_of_kind(kind: String) -> bool:
	return _exec_b("DELETE FROM entities WHERE kind=?", [kind])


## Array of {id, kind, data}.
func entities_in_chunk(location: String, cx: int, cy: int) -> Array:
	_db.query_with_bindings("SELECT id, kind, data FROM entities WHERE location=? AND cx=? AND cy=?", [location, cx, cy])
	return _db.query_result


# --- inventories ---------------------------------------------------------

func put_inventory(owner: String, data: PackedByteArray) -> bool:
	return _exec_b("INSERT INTO inventories(owner, data) VALUES(?, ?) ON CONFLICT(owner) DO UPDATE SET data=excluded.data", [owner, data])


func get_inventory(owner: String) -> PackedByteArray:
	_db.query_with_bindings("SELECT data FROM inventories WHERE owner=?", [owner])
	return _db.query_result[0]["data"] if _db.query_result.size() else PackedByteArray()


func all_inventory_owners() -> PackedStringArray:
	_db.query("SELECT owner FROM inventories")
	var out := PackedStringArray()
	for row: Dictionary in _db.query_result:
		out.append(row["owner"])
	return out


# --- characters ----------------------------------------------------------

## The portable part as held by this world, and the key that owns it.
func put_character(character_id: String, owner: String, data: PackedByteArray) -> bool:
	return _exec_b("INSERT INTO characters(character_id, owner, data) VALUES(?, ?, ?) ON CONFLICT(character_id) DO UPDATE SET owner=excluded.owner, data=excluded.data",
		[character_id, owner, data])


## {owner, data} or {} if this world has never seen the character.
func get_character(character_id: String) -> Dictionary:
	_db.query_with_bindings("SELECT owner, data FROM characters WHERE character_id=?", [character_id])
	return _db.query_result[0] if _db.query_result.size() else {}


## Where the character is in this world (location, position...).
func put_world_character(character_id: String, data: PackedByteArray) -> bool:
	return _exec_b("INSERT INTO world_characters(character_id, data) VALUES(?, ?) ON CONFLICT(character_id) DO UPDATE SET data=excluded.data",
		[character_id, data])


func get_world_character(character_id: String) -> PackedByteArray:
	_db.query_with_bindings("SELECT data FROM world_characters WHERE character_id=?", [character_id])
	return _db.query_result[0]["data"] if _db.query_result.size() else PackedByteArray()


# --- locations -----------------------------------------------------------

func put_location(location_id: String, kind: String, building: String, z: int, data: PackedByteArray) -> bool:
	return _exec_b("INSERT INTO locations(location_id, kind, building, z, data) VALUES(?, ?, ?, ?, ?) ON CONFLICT(location_id) DO UPDATE SET kind=excluded.kind, building=excluded.building, z=excluded.z, data=excluded.data",
		[location_id, kind, building, z, data])


func delete_location(location_id: String) -> bool:
	return _exec_b("DELETE FROM locations WHERE location_id=?", [location_id])


## Every location: [{location_id, kind, building, z, data}]
func all_locations() -> Array:
	_db.query("SELECT location_id, kind, building, z, data FROM locations")
	return _db.query_result


## Chunk coordinates stored for a location: [{cx, cy}]
func chunks_of(location: String) -> Array:
	_db.query_with_bindings("SELECT cx, cy FROM chunks WHERE location=?", [location])
	return _db.query_result


func delete_chunk(location: String, cx: int, cy: int) -> bool:
	return _exec_b("DELETE FROM chunks WHERE location=? AND cx=? AND cy=?", [location, cx, cy])


# --- processed requests (idempotency ledger) -----------------------------

func put_request(actor: String, request_id: String, tick: int, result: PackedByteArray) -> bool:
	return _exec_b("INSERT INTO requests(actor, request_id, tick, result) VALUES(?, ?, ?, ?)", [actor, request_id, tick, result])


func get_request(actor: String, request_id: String) -> PackedByteArray:
	_db.query_with_bindings("SELECT result FROM requests WHERE actor=? AND request_id=?", [actor, request_id])
	return _db.query_result[0]["result"] if _db.query_result.size() else PackedByteArray()


func prune_requests(before_tick: int) -> bool:
	return _exec_b("DELETE FROM requests WHERE tick < ?", [before_tick])


# --- maintenance ---------------------------------------------------------

## Consistent copy of a live database.
func backup_to(target: String) -> bool:
	if not _db.backup_to(target):
		return _fail("backup to %s failed: %s" % [target, _db.error_message])
	return true


func integrity_ok() -> bool:
	_db.query("PRAGMA integrity_check")
	return _db.query_result.size() == 1 and _db.query_result[0].values()[0] == "ok"


## Moves the WAL into the main file (on shutdown, or to keep the WAL small).
func checkpoint() -> bool:
	return _exec("PRAGMA wal_checkpoint(TRUNCATE)")


func query_rows(sql: String, bindings := []) -> Array:
	_db.query_with_bindings(sql, bindings)
	return _db.query_result


# --- internals -----------------------------------------------------------

func _schema_version() -> int:
	_db.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='meta'")
	if _db.query_result[0]["n"] == 0:
		return 0
	_db.query("SELECT value FROM meta WHERE key='schema_version'")
	if _db.query_result.is_empty():
		_fail("meta table without schema_version")
		return -1
	return int(_db.query_result[0]["value"])


func _migrate(from: int) -> bool:
	if from > 0:
		backup_path = "%s.v%d-%d.bak" % [path.get_basename(), from, int(Time.get_unix_time_from_system())]
		if not backup_to(backup_path):
			return false
	if not begin():
		return false
	for v in range(from, _migrations.size()):
		for sql: String in _migrations[v]:
			if not _exec(sql):
				rollback()
				return _fail("migration %d -> %d failed: %s" % [v, v + 1, last_error])
	if not write_meta("schema_version", str(_migrations.size())):
		rollback()
		return false
	if from == 0:
		write_meta("created_with", GameInfo.VERSION)
	write_meta("last_opened_with", GameInfo.VERSION)
	return commit()


func _exec(sql: String) -> bool:
	if not _db.query(sql):
		return _fail("%s: %s" % [sql.left(60), _db.error_message])
	return true


func _exec_b(sql: String, bindings: Array) -> bool:
	if not _db.query_with_bindings(sql, bindings):
		return _fail("%s: %s" % [sql.left(60), _db.error_message])
	return true


func _fail(msg: String) -> bool:
	last_error = msg
	return false
