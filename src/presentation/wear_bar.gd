class_name WearBar
extends Control
## A thin bar under a thing's picture (ADR-0046): what is left of it —
## green, yellow from half, red once it is dull; dark red when broken.
## Hidden while the thing is whole or does not wear.

## What is left, 0..1; below 0 — nothing to show.
var value := -1.0:
	set(v):
		value = v
		visible = v >= 0.0 and v < 1.0
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


## The bar of a copy of a thing, as Wear has it.
func show_state(content: ContentRegistry, id: String, state: Dictionary) -> void:
	value = Wear.condition(content, id, state) if id != "" and Wear.wears(content, id) else -1.0


static func tint(left: float) -> Color:
	if left <= 0.0:
		return Color(0.45, 0.08, 0.08)
	if left < Wear.DULL:
		return Color(0.9, 0.2, 0.15)
	if left < 0.5:
		return Color(0.95, 0.8, 0.2)
	return Color(0.35, 0.85, 0.3)


func _draw() -> void:
	if value < 0.0 or value >= 1.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.04, 0.05, 0.85))
	if value <= 0.0:
		draw_rect(Rect2(Vector2(1, 1), size - Vector2(2, 2)), tint(0.0))
		return
	draw_rect(Rect2(Vector2(1, 1), Vector2(maxf(1.0, (size.x - 2) * value), size.y - 2)), tint(value))
