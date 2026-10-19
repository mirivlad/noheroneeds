class_name CharacterEditor
extends VBoxContainer
## Appearance is edited only from the start screen, never over a live game.

signal accepted(char_name: String, body: String, styles: Dictionary, colors: Dictionary)
signal cancelled

const FACES := {"base:human_face_soft": "Овальное", "base:human_face_square": "Широкое", "base:human_face_angular": "Угловатое"}
const HAIRS := {"base:human_hair_short": "Взъерошенная", "base:human_hair_plain": "Аккуратная", "base:human_hair_long": "Длинная",
	"base:human_hair_ponytail": "Хвост", "base:human_hair_braid": "Коса", "base:human_hair_bald": "Без волос"}
## Colours are the middle steps of the LPC ramps they stand for (Art.lpc_ramp).
const SKIN := {"#e4a47c": "Светлый", "#ea9f54": "Тёплый", "#ae6b3f": "Смуглый", "#7f4c31": "Бронзовый",
	"#76513a": "Тёмный", "#442725": "Очень тёмный"}
const HAIR_COLORS := {"#1c2222": "Чёрный", "#421603": "Тёмно-каштановый", "#7d4513": "Каштановый", "#cc6901": "Рыжий",
	"#bf9d5a": "Русый", "#c0ab81": "Светлый", "#777777": "Седой"}
const EYE_COLORS := {"#544c2e": "Карие", "#5686ae": "Голубые", "#53b351": "Зелёные", "#8b8979": "Серые"}
## One build of each body for now (LPC's muscular body lacks clothes and a bow
## shot); old broad bodies are drawn as these and become them when edited.
const PLANS := ["base:human_m", "base:human_f"]

var content: ContentRegistry
var preview := CharacterPreview.new()
var name_edit := LineEdit.new()
var sex_pick: OptionButton
var face_pick: OptionButton
var hair_pick: OptionButton
var skin_pick: OptionButton
var color_pick: OptionButton
var eye_pick: OptionButton
var _fields := VBoxContainer.new()


func setup(registry: ContentRegistry, character: PortableCharacter = null) -> void:
	content = registry
	custom_minimum_size = Vector2(420, 0)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	add_child(columns)
	var left := VBoxContainer.new()
	columns.add_child(left)
	left.add_child(preview)
	var walk := CheckBox.new()
	walk.text = "Ходьба"
	walk.button_pressed = true
	walk.toggled.connect(func(on: bool) -> void: preview.walking = on)
	left.add_child(walk)
	_fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields.add_theme_constant_override("separation", 1)
	columns.add_child(_fields)
	name_edit.name = "CharacterName"
	name_edit.placeholder_text = "Имя персонажа"
	name_edit.max_length = PortableCharacter.NAME_MAX
	name_edit.text = character.name if character else ""
	_field("Имя", name_edit)
	sex_pick = _choice("Пол", "SexChoice", ["Мужской", "Женский"])
	face_pick = _choice("Лицо", "FaceChoice", FACES.values())
	hair_pick = _choice("Причёска", "HairChoice", HAIRS.values())
	skin_pick = _choice("Кожа", "SkinChoice", SKIN.values())
	color_pick = _choice("Волосы", "HairColorChoice", HAIR_COLORS.values())
	eye_pick = _choice("Глаза", "EyeColorChoice", EYE_COLORS.values())
	if character:
		sex_pick.selected = 1 if character.body_plan.begins_with("base:human_f") or character.body_plan == "base:wayfarer" else 0
		face_pick.selected = maxi(0, FACES.keys().find(character.styles.get("face", "")))
		hair_pick.selected = maxi(0, HAIRS.keys().find(character.styles.get("hair", "")))
		skin_pick.selected = maxi(0, SKIN.keys().find(character.colors.get("skin", "")))
		color_pick.selected = maxi(0, HAIR_COLORS.keys().find(character.colors.get("hair", "")))
		eye_pick.selected = maxi(0, EYE_COLORS.keys().find(character.colors.get("eyes", "")))
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	add_child(buttons)
	var save := Button.new()
	save.text = "Сохранить" if character else "Создать"
	save.pressed.connect(func() -> void:
		var look := appearance()
		accepted.emit(name_edit.text, look["body_plan"], look["styles"], look["colors"]))
	buttons.add_child(save)
	var cancel := Button.new()
	cancel.text = "Отмена"
	cancel.pressed.connect(func() -> void: cancelled.emit())
	buttons.add_child(cancel)
	_refresh()
	name_edit.grab_focus()


func appearance() -> Dictionary:
	return {"body_plan": PLANS[sex_pick.selected],
		"styles": {"face": FACES.keys()[face_pick.selected], "hair": HAIRS.keys()[hair_pick.selected]},
		"colors": {"skin": SKIN.keys()[skin_pick.selected], "hair": HAIR_COLORS.keys()[color_pick.selected],
			"eyes": EYE_COLORS.keys()[eye_pick.selected]}}


func _refresh() -> void:
	var look := appearance()
	look["worn"] = WorldLibrary.STARTER_OUTFIT.duplicate()
	preview.show_look(content, look)


func _choice(label: String, node_name: String, choices: Array) -> OptionButton:
	var pick := OptionButton.new()
	pick.name = node_name
	for choice: String in choices:
		pick.add_item(choice)
	pick.item_selected.connect(func(_i: int) -> void: _refresh())
	_field(label, pick)
	return pick


func _field(label: String, control: Control) -> void:
	var row := HBoxContainer.new()
	var text := Label.new()
	text.text = label
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	control.custom_minimum_size.x = 142
	row.add_child(control)
	_fields.add_child(row)
