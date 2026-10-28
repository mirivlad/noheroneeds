class_name KeyMap
extends RefCounted
## The game's keys (UI 2.0, stage F): each action's key, as the player set it
## in the settings ("keys": action -> key, physical: the same place on any
## layout) or by default. Ctrl (run), Shift, 1–9, Esc and the mouse stay.

## [action, what it does, default key], in the order the settings list them.
const ACTIONS := [
	["up", "Идти вперёд", KEY_W], ["left", "Идти влево", KEY_A], ["down", "Идти назад", KEY_S],
	["right", "Идти вправо", KEY_D], ["use", "Взаимодействие", KEY_E], ["climb", "Переход (Shift — вниз)", KEY_F],
	["jump", "Прыжок с края", KEY_J], ["weapon", "Оружие в руки", KEY_Q], ["drop", "Выбросить из рук", KEY_G],
	["rotate", "Повернуть чертёж", KEY_R], ["things", "Вещи", KEY_I], ["character", "Персонаж", KEY_C],
	["crafts", "Ремёсла", KEY_K], ["build", "Строительство", KEY_B], ["journal", "Журнал", KEY_L], ["map", "Карта", KEY_M],
]


static func default_key(action: String) -> int:
	for a: Array in ACTIONS:
		if a[0] == action:
			return int(a[2])
	return KEY_NONE


## The key of an action now.
static func key(settings: GameSettings, action: String) -> int:
	var keys: Dictionary = settings.get_value("keys") if settings else {}
	return int(keys.get(action, default_key(action)))


## The action a key does ("" — none).
static func action_of(settings: GameSettings, k: int) -> String:
	for a: Array in ACTIONS:
		if key(settings, String(a[0])) == k:
			return String(a[0])
	return ""


## Sets an action's key; another action that had it gets this one's old key
## (two actions never share a key).
static func bind(settings: GameSettings, action: String, k: int) -> void:
	var keys: Dictionary = (settings.get_value("keys") as Dictionary).duplicate()
	var other := action_of(settings, k)
	if other != "" and other != action:
		keys[other] = key(settings, action)
	keys[action] = k
	for a: Array in ACTIONS:  # what is as by default is not kept
		if int(keys.get(a[0], -1)) == int(a[2]):
			keys.erase(a[0])
	settings.set_value("keys", keys)


static func key_name(k: int) -> String:
	return OS.get_keycode_string(k)
