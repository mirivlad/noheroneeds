class_name Inventory
extends RefCounted
## Stackable contents by content id. Unique items (own id, durability,
## modifiers) come with their own format version later.

const FORMAT := 1

var stacks := {}


func count(content_id: String) -> int:
	return stacks.get(content_id, 0)


func add(content_id: String, n: int) -> void:
	assert(n > 0)
	stacks[content_id] = count(content_id) + n


## False (and no change) when there is not enough.
func remove(content_id: String, n: int) -> bool:
	var have := count(content_id)
	if n <= 0 or have < n:
		return false
	if have == n:
		stacks.erase(content_id)
	else:
		stacks[content_id] = have - n
	return true


func has_all(costs: Dictionary) -> bool:
	for id: String in costs:
		if count(id) < int(costs[id]):
			return false
	return true


func to_data() -> Dictionary:
	return {"format": FORMAT, "stacks": stacks.duplicate()}


static func from_data(data: Dictionary) -> Inventory:
	var inv := Inventory.new()
	var s: Dictionary = data.get("stacks", {})
	for id: String in s:
		if int(s[id]) > 0:
			inv.stacks[id] = int(s[id])
	return inv
