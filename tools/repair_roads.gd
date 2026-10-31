extends SceneTree
## Old worlds: find roads that still run into open water and, with --apply,
## lay a bridge deck over the clear water cells. It touches only common water
## on a road: no land, deep water, buildings, plants, props or things lying
## there are changed (those cells are only named). ADR-0038.
##
## Stop the game or server first: it holds the world database.
##   godot --headless --path . -s res://tools/repair_roads.gd -- --world=PATH
##   godot --headless --path . -s res://tools/repair_roads.gd -- --world=PATH --apply
## Without --world it uses user://worlds/default/world.db.

const SHOWN := 12


func _init() -> void:
	var o := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		o[kv[0]] = kv[1] if kv.size() > 1 else ""
	var path := ProjectSettings.globalize_path(String(o.get("world", "user://worlds/default/world.db")))
	if not FileAccess.file_exists(path):
		printerr("нет файла мира: " + path)
		quit(1)
		return
	var content := ContentRegistry.load_packs(["res://content/base"])
	if not content.errors.is_empty():
		printerr("ошибки содержимого:\n  " + "\n  ".join(content.errors))
		quit(1)
		return
	var w := ServerWorld.open(path, content, {})
	if w == null:
		printerr("мир не открылся: " + ServerWorld.open_error)
		quit(1)
		return
	var apply := o.has("apply")
	var report := w.road_audit(apply)
	print("Мир: %s" % path)
	print("Кусков поверхности: %d, клеток дорог: %d" % [int(report["chunks"]), int(report["checked"])])
	_tell("Вода на дороге без моста", report["bridged"], apply)
	_tell("Глубокая вода (не трогаем)", report["deep"], false)
	_tell("Занятые клетки (не трогаем)", report["blocked"], false)
	if apply:
		w.sync()
		print("Мосты уложены и мир сохранён.")
	else:
		print("Это только отчёт; чтобы уложить мосты, повторите с --apply.")
	w.close()
	quit(0)


func _tell(what: String, cells: Array, done: bool) -> void:
	if cells.is_empty():
		return
	print("%s: %d%s" % [what, cells.size(), " (исправлено)" if done else ""])
	var shown := cells.slice(0, SHOWN)
	var text := PackedStringArray()
	for at: Vector2i in shown:
		text.append("(%d, %d)" % [at.x, at.y])
	print("  " + ", ".join(text) + (" …" if cells.size() > SHOWN else ""))