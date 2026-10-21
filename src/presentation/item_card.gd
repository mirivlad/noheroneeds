class_name ItemCard
## The card of a thing (a tooltip on a cell, a quick slot, a worn slot):
## its name and count, what it does (damage, protection, warmth, food) and
## what this copy is like (ADR-0046: condition, wear, mends). Later marks of
## a copy (sharpening, enchantment) are shown here too.


## Where one mends, for people (the kinds of stations, ADR-0026).
const STATIONS := {"workbench": "у верстака", "forge": "у печи", "fire": "у костра"}


static func text(content: ContentRegistry, id: String, state: Dictionary, count := 1) -> String:
	var d := content.get_def(id)
	var title := String(d.get("name", id))
	var recipe := String(state.get("recipe", ""))
	if recipe != "":  # a blueprint (ADR-0047): of what
		title += ": " + String(content.get_def(recipe).get("name", recipe))
	var lines: Array[String] = [title + (" ×%d" % count if count > 1 else "")]
	if recipe != "":
		lines.append("Сделать по нему — наверняка и в полную силу; изучить — знать навсегда (K → Чертежи)")
	# How it was made (ADR-0047): quality, enhancements, the maker.
	if state.has("quality"):
		lines.append("Качество: %d%%" % roundi(Wear.quality(state) * 100.0))
	for m: Variant in Wear.mods(state):
		var md := content.get_def(String(m))
		lines.append("%s: %s" % [md.get("name", m), md.get("description", "")])
	var w: Dictionary = d.get("weapon", {})
	if not w.is_empty() and not bool(w.get("improvised", false)):
		lines.append("Урон: %d" % Wear.damage(content, id, state, int(w.get("damage", 0))))
	if int(d.get("armor", 0)) > 0:
		lines.append("Защита: %d" % Wear.armor(content, id, state) if not Wear.broken(content, id, state) else "Защита: нет, пока не починят")
	if int(d.get("warmth", 0)) > 0:
		lines.append("Тепло: %d" % Wear.warmth(content, id, state))
	var food: Dictionary = d.get("food", {})
	if not food.is_empty():
		lines.append("Сытость: %d, лечит: %d" % [int(food.get("satiety", 0)), int(food.get("heal", 0))])
	if Wear.wears(content, id):
		var pct := floori(Wear.condition(content, id, state) * 100.0 + 0.5)
		var line := "Состояние: %d%%" % pct
		if Wear.broken(content, id, state):
			line += " — сломано"
		elif Wear.dull(content, id, state):
			line += " — затупилось"
		lines.append(line)
		lines.append("Износ: %d из %d" % [mini(Wear.spent(state), Wear.limit(content, id, state)), Wear.limit(content, id, state)])
		if not d.has("repair"):
			lines.append("Не чинится: сломается — развалится")
		else:
			var left := Wear.mends_left(content, id, state)
			var where := Wear.mend_station(content, id)
			if left > 0:
				lines.append("Чинится %s, починок осталось: %d" % [String(STATIONS.get(where, where)) if where != "" else "в руках", left])
			else:
				lines.append("Больше не починить: сломается — развалится")
	if String(state.get("by", "")) != "":
		lines.append(("Записал: %s" if recipe != "" else "Работа мастера: %s") % String(state["by"]))
	return "\n".join(lines)
