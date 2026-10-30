extends TestCase
var panel: TalkPanel

func before_each() -> void:
	panel = TalkPanel.new()
	panel.setup(ContentRegistry.load_packs(["res://content/base"]))
	(Engine.get_main_loop() as SceneTree).root.add_child(panel)

func after_each() -> void:
	panel.free()
	await (Engine.get_main_loop() as SceneTree).process_frame

func _talk() -> Dictionary:
	return {"ok": true, "creature": "host", "name": "Анна", "profession": "base:innkeeper", "establishment": "Тёплый очаг", "village": "Ключи",
		"services": [{"kind": "meal", "id": "bread", "name": "Хлеб", "price": 3, "satiety": 40, "heal": 5, "why": ""},
			{"kind": "bed", "id": "0", "name": "Общая спальня, кровать 1", "price": 6, "hours": 12.0, "z": 1, "why": "", "mine": false},
			{"kind": "bed", "id": "1", "name": "Отдельная комната, кровать 2", "price": 15, "hours": 24.0, "z": 1, "why": "", "mine": false}]}

func test_service_choice_displays_terms_and_keeps_the_paid_bed_selected() -> void:
	var talk := _talk()
	panel.open_for(talk)
	panel._lodging.pressed.emit()
	eq(panel._services.item_count, 2)
	panel._services.select(1)
	panel._select_service(1)
	check(panel._service_info.text.contains("24"), "the rental duration is visible")
	check(panel._pay.text.contains("15"), "the exact price is visible before payment")
	var sent := []
	panel.service.connect(func(who: String, kind: String, choice: String) -> void: sent.append([who, kind, choice]))
	panel._pay.pressed.emit()
	eq(sent, [["host", "bed", "1"]])
	talk["services"][2].merge({"why": "already_rented", "mine": true, "until": Daylight.DAY_MS}, true)
	panel.open_for(talk)
	eq(panel._services.get_selected_items(), PackedInt32Array([1]), "the reply keeps the chosen private bed")
	check(panel._pay.disabled and panel._service_info.text.contains("Оплачено"), "a paid bed is identified and cannot be charged again")
	panel._pay.pressed.emit()
	eq(sent.size(), 1)
