class_name Bag
## What one carries, as cells (ADR-0041): a character's things fill SIZE
## cells, a stack a cell, each item's stack as big as its "stack" says (logs
## 20, planks 99, an axe 1). The server keeps counts by item and refuses or
## drops what does not fit; the window lays the counts out in cells in the
## order the player arranged them (kept in the player's settings, like the
## quick slots), so moving a stack about never asks the server anything.

const SIZE := 36
const COLUMNS := 9


static func stack_of(content: ContentRegistry, id: String) -> int:
	return maxi(1, int(content.get_def(id).get("stack", 1)))


## Cells the stacks take.
static func used(content: ContentRegistry, stacks: Dictionary) -> int:
	var n := 0
	for id: String in stacks:
		n += ceili(float(stacks[id]) / stack_of(content, id))
	return n


## How many more of `id` go into `size` cells holding `stacks`.
static func room_for(content: ContentRegistry, stacks: Dictionary, id: String, size := SIZE) -> int:
	var per := stack_of(content, id)
	var have := int(stacks.get(id, 0))
	var free := maxi(0, size - used(content, stacks))
	return free * per + (ceili(float(have) / per) * per - have)


## The cells: `order` (an item id or "" per cell, as the player left them) is
## kept where it still fits what is carried; an item with more stacks than
## cells of its own takes the first free ones, cells of what is gone free up.
## Returns {"order": the order now, "cells": [[id, count], ...]} — at least
## `size` cells (more only for an overfull bag).
static func lay_out(content: ContentRegistry, stacks: Dictionary, order: Array, size := SIZE) -> Dictionary:
	var need := {}
	for id: String in stacks:
		if int(stacks[id]) > 0:
			need[id] = ceili(float(stacks[id]) / stack_of(content, id))
	var out: Array[String] = []
	var placed := {}
	for i in maxi(size, order.size()):
		var id := String(order[i]) if i < order.size() else ""
		if id != "" and int(placed.get(id, 0)) < int(need.get(id, 0)):
			placed[id] = int(placed.get(id, 0)) + 1
		else:
			id = ""
		out.append(id)
	var rest: Array = need.keys()
	rest.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	var free := 0
	for id: String in rest:
		while int(placed.get(id, 0)) < int(need[id]):
			while free < out.size() and out[free] != "":
				free += 1
			if free == out.size():
				out.append("")
			out[free] = id
			placed[id] = int(placed.get(id, 0)) + 1
	while out.size() > size and out[out.size() - 1] == "":
		out.pop_back()
	# Counts: full stacks first, what is left over in the item's last cell.
	var left := {}
	for id: String in need:
		left[id] = int(stacks[id])
	var cells: Array = []
	for id: String in out:
		if id == "":
			cells.append(["", 0])
			continue
		var n := mini(int(left[id]), stack_of(content, id))
		left[id] = int(left[id]) - n
		cells.append([id, n])
	return {"order": out, "cells": cells}
