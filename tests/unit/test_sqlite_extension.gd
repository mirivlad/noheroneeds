extends TestCase
## The SQLite extension is present and behaves as the storage layer expects.


func test_blob_and_int64_round_trip() -> void:
	var db := SQLite.new()
	db.path = tmp_dir().path_join("t.db")
	db.verbosity_level = SQLite.QUIET
	check(db.open_db(), "open")
	db.query("CREATE TABLE t(k TEXT PRIMARY KEY, n INTEGER, b BLOB) WITHOUT ROWID")
	var blob := PackedByteArray([0, 1, 2, 255])
	check(db.query_with_bindings("INSERT INTO t VALUES(?,?,?)", ["a", 9007199254740993, blob]), "insert")
	db.query_with_bindings("SELECT n, b FROM t WHERE k=?", ["a"])
	eq(db.query_result[0]["n"], 9007199254740993, "int64")
	eq(db.query_result[0]["b"], blob, "blob")
	db.close_db()


func test_wal_mode() -> void:
	var db := SQLite.new()
	db.path = tmp_dir().path_join("t.db")
	db.verbosity_level = SQLite.QUIET
	db.open_db()
	db.query("PRAGMA journal_mode=WAL")
	eq(db.query_result[0]["journal_mode"], "wal")
	db.close_db()
