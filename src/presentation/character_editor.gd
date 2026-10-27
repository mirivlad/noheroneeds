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
## The RO-style bodies (tools/art/ro_sprites) have their own faces drawn on, hairstyles
## of their own and hair of any colour (a colour wheel instead of the list).
const PLANS := ["base:human_m", "base:human_f", "base:human_ro_m", "base:human_ro_f"]
const RO_HAIRS := {"base:ro_hair_tousled": "Взъерошенная", "base:ro_hair_twintails": "Два хвоста",
	"base:ro_hair_bob": "Каре", "base:ro_hair_fluffy_bob": "Пышное каре", "base:ro_hair_fringe": "С чёлкой",
	"base:ro_hair_long": "Длинные", "base:ro_hair_side_tail": "Хвост набок", "base:ro_hair_cat_ears": "С ушками",
	"base:human_hair_bald": "Без волос"}
## Clothes to try on in the preview (not kept: a character starts in the world's outfit).
const TRY_ON := {"Стартовая одежда": {}, "Фетровая шляпа": {"headwear": "base:felt_hat"},
	"Железный шлем": {"headwear": "base:iron_helmet"},
	"Стражник": {"armor": "base:leather_armor", "headwear": "base:iron_helmet", "back_item": "base:wool_cloak"},
	"Охотник": {"headwear": "base:fur_hood", "back_item": "base:fur_cloak"}}
## The hairstyle an RO body starts with.
const RO_HAIR := {"base:human_ro_m": "base:ro_hair_tousled", "base:human_ro_f": "base:ro_hair_twintails"}
## RO hair with no colour chosen yet.
const RO_HAIR_COLOR := "#7d4513"

var content: ContentRegistry
var preview := CharacterPreview.new()
var name_edit := LineEdit.new()
var sex_pick: OptionButton
var face_pick: OptionButton
var hair_pick: OptionButton
var skin_pick: OptionButton
var color_pick: OptionButton
var eye_pick: OptionButton
## RO hair: any colour.
var color_wheel := ColorPickerButton.new()
## What the preview wears over the starting outfit (TRY_ON).
var try_pick := OptionButton.new()
var _fields := VBoxContainer.new()
## The hairstyles hair_pick lists now (HAIRS or RO_HAIRS).
var _hairs: Dictionary = HAIRS


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
	try_pick.name = "TryOnChoice"
	try_pick.tooltip_text = "Примерить (только для просмотра)"
	for title: String in TRY_ON:
		try_pick.add_item(title)
	try_pick.item_selected.connect(func(_i: int) -> void: _refresh())
	left.add_child(try_pick)
	_fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields.add_theme_constant_override("separation", 1)
	columns.add_child(_fields)
	name_edit.name = "CharacterName"
	name_edit.placeholder_text = "Имя персонажа"
	name_edit.max_length = PortableCharacter.NAME_MAX
	name_edit.text = character.name if character else ""
	_field("Имя", name_edit)
	sex_pick = _choice("Пол", "SexChoice", ["Мужской", "Женский", "Мужской · RO", "Женский · RO"], _plan_changed)
	face_pick = _choice("Лицо", "FaceChoice", FACES.values())
	hair_pick = _choice("Причёска", "HairChoice", HAIRS.values())
	skin_pick = _choice("Кожа", "SkinChoice", SKIN.values())
	color_pick = _choice("Волосы", "HairColorChoice", HAIR_COLORS.values())
	color_wheel.name = "HairColorWheel"
	color_wheel.edit_alpha = false
	color_wheel.color = Color(RO_HAIR_COLOR)
	color_wheel.get_picker().picker_shape = ColorPicker.SHAPE_HSV_WHEEL
	for hex: String in HAIR_COLORS:
		color_wheel.get_picker().add_preset(Color(hex))
	color_wheel.color_changed.connect(func(_c: Color) -> void: _refresh())
	_field("Волосы", color_wheel)
	eye_pick = _choice("Глаза", "EyeColorChoice", EYE_COLORS.values())
	if character:
		sex_pick.selected = PLANS.find(character.body_plan) if RO_HAIR.has(character.body_plan) \
			else (1 if character.body_plan.begins_with("base:human_f") else 0)
		face_pick.selected = maxi(0, FACES.keys().find(character.styles.get("face", "")))
		skin_pick.selected = maxi(0, SKIN.keys().find(character.colors.get("skin", "")))
		color_pick.selected = maxi(0, HAIR_COLORS.keys().find(character.colors.get("hair", "")))
		color_wheel.color = Color.from_string(String(character.colors.get("hair", "")), Color(RO_HAIR_COLOR))
		eye_pick.selected = maxi(0, EYE_COLORS.keys().find(character.colors.get("eyes", "")))
	_list_hairs(String(character.styles.get("hair", "")) if character else "")
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
	var plan: String = PLANS[sex_pick.selected]
	var hair: String = _hairs.keys()[hair_pick.selected]
	var ro := RO_HAIR.has(plan)
	return {"body_plan": plan, "styles": {"hair": hair} if ro else {"face": FACES.keys()[face_pick.selected], "hair": hair},
		"colors": {"skin": SKIN.keys()[skin_pick.selected],
			"hair": "#" + color_wheel.color.to_html(false) if ro else HAIR_COLORS.keys()[color_pick.selected],
			"eyes": EYE_COLORS.keys()[eye_pick.selected]}}


## The hairstyles of the chosen body in hair_pick, `keep` chosen if it is one of them; the
## colour list or the wheel.
func _list_hairs(keep: String) -> void:
	var plan: String = PLANS[sex_pick.selected]
	_hairs = RO_HAIRS if RO_HAIR.has(plan) else HAIRS
	hair_pick.clear()
	for title: String in _hairs.values():
		hair_pick.add_item(title)
	hair_pick.selected = _hairs.keys().find(keep) if _hairs.has(keep) else _hairs.keys().find(RO_HAIR.get(plan, ""))
	hair_pick.selected = maxi(0, hair_pick.selected)
	color_pick.get_parent().visible = not RO_HAIR.has(plan)
	color_wheel.get_parent().visible = RO_HAIR.has(plan)


## A hairstyle chosen stays; one a body only started with becomes the new body's.
func _plan_changed() -> void:
	var hair: String = _hairs.keys()[hair_pick.selected]
	_list_hairs("" if RO_HAIR.values().has(hair) else hair)
	_refresh()


func _refresh() -> void:
	var look := appearance()
	look["worn"] = WorldLibrary.STARTER_OUTFIT.merged(TRY_ON.values()[try_pick.selected])
	preview.show_look(content, look)


func _choice(label: String, node_name: String, choices: Array, changed := _refresh) -> OptionButton:
	var pick := OptionButton.new()
	pick.name = node_name
	for choice: String in choices:
		pick.add_item(choice)
	pick.item_selected.connect(func(_i: int) -> void: changed.call())
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
