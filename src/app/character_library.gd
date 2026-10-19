class_name CharacterLibrary
extends RefCounted
## The player's characters: signed character files (characters/<id>.nhnchar,
## ADR-0006) and which one is played. The first character, characters/
## main.nhnchar, is one of them like any other.

const EXT := ".nhnchar"
const STYLE_DEFAULTS := {"hair": "base:hair_short", "face": "base:face_soft", "eyes": "base:eyes_round"}
## The editor's first choices (middle steps of LPC ramps: light skin, brown hair and eyes).
const COLOR_DEFAULTS := {"skin": "#e4a47c", "hair": "#7d4513", "eyes": "#544c2e"}

var root := ""
var content: ContentRegistry
var player: PlayerIdentity
## Why the last create() refused.
var last_error := ""


func _init(dir: String, registry: ContentRegistry, identity: PlayerIdentity) -> void:
	root = dir
	content = registry
	player = identity


## [{file, name, character_id, hair}] of the readable characters, by name.
func list() -> Array:
	var out := []
	var d := DirAccess.open(root)
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(EXT):
			continue
		var c := load_character(f.trim_suffix(EXT))
		if c:
			out.append({"file": f.trim_suffix(EXT), "name": c.name, "character_id": c.character_id,
				"hair": String(c.styles.get("hair", "")), "body_plan": c.body_plan})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["name"]) < String(b["name"]))
	return out


func load_character(file_id: String) -> PortableCharacter:
	var r := CharacterFile.read(file_bytes(file_id), content)
	return r.character if r.ok else null


func file_bytes(file_id: String) -> PackedByteArray:
	var path := root.path_join(file_id + EXT)
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()


## A new character with the player's choices; returns its file id ("" if
## it could not be written).
func create(char_name: String, styles: Dictionary, colors: Dictionary = {}, body_plan := "base:humanoid_adult") -> String:
	var clean := char_name.strip_edges().left(PortableCharacter.NAME_MAX)
	var c := PortableCharacter.create(clean if clean != "" else "Путник", body_plan)
	for slot: String in STYLE_DEFAULTS:
		if (content.get_def(STYLE_DEFAULTS[slot]).get("body_plans", []) as Array).has(body_plan):
			c.styles[slot] = STYLE_DEFAULTS[slot]
	c.styles.merge(styles, true)
	c.colors = COLOR_DEFAULTS.duplicate()
	c.colors.merge(colors, true)
	var errors := c.check_content(content)
	if not errors.is_empty():
		last_error = "; ".join(errors)
		return ""
	var file_id := c.character_id
	return file_id if _write(file_id, CharacterFile.export_signed(c, player, content)) else ""


## Offline editing preserves identity, progress and possessions, and signs anew.
func edit(file_id: String, char_name: String, body_plan: String, styles: Dictionary, colors: Dictionary) -> bool:
	var c := load_character(file_id)
	if c == null:
		last_error = "персонаж не найден"
		return false
	c.name = char_name.strip_edges().left(PortableCharacter.NAME_MAX)
	if c.name == "":
		last_error = "укажите имя"
		return false
	c.body_plan = body_plan
	c.styles = styles.duplicate()
	c.colors = colors.duplicate()
	var errors := PortableCharacter.check_structure(c.to_data())
	errors.append_array(c.check_content(content))
	if not errors.is_empty():
		last_error = "; ".join(errors)
		return false
	return _write(file_id, CharacterFile.export_signed(c, player, content))


## The character to play: the chosen one if it is still there, else the
## first, else a new default character.
func current(chosen: String) -> String:
	if chosen != "" and load_character(chosen) != null:
		return chosen
	var all := list()
	if not all.is_empty():
		return all[0]["file"]
	return create("Путник", {})


func _write(file_id: String, bytes: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(root)
	var path := root.path_join(file_id + EXT)
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		last_error = "не удалось записать файл"
		return false
	f.store_buffer(bytes)
	var error := f.get_error()
	f.close()
	if error != OK or DirAccess.rename_absolute(path + ".tmp", path) != OK:
		last_error = "не удалось сохранить файл"
		return false
	return true
