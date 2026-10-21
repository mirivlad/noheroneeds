class_name Inventory
extends RefCounted
## Contents by content id: how many of each, and for things whose copies
## differ (ADR-0046: wear; later sharpening, enchantment) each copy's own
## state. Copies are in order: what comes in goes to the end, what goes out
## leaves from the end unless a copy is named; the first is the one in use.

const FORMAT := 2

var stacks := {}
## id -> [state of each copy] (Dictionary, {} plain), as long as the stack;
## kept only while some copy has a state.
var states := {}


func count(content_id: String) -> int:
	return stacks.get(content_id, 0)


## A copy's state ({} plain, or no such copy).
func state_of(content_id: String, index: int) -> Dictionary:
	var list: Array = states.get(content_id, [])
	return list[index] if index >= 0 and index < list.size() else {}


## Every copy's state, as many as there are.
func states_of(content_id: String) -> Array:
	var out: Array = []
	for i in count(content_id):
		out.append(state_of(content_id, i).duplicate())
	return out


## Adds `n`; `with` are the states of the copies that come (plain if short).
func add(content_id: String, n: int, with: Array = []) -> void:
	assert(n > 0)
	var have := count(content_id)
	stacks[content_id] = have + n
	var marked := with.any(func(s: Variant) -> bool: return typeof(s) == TYPE_DICTIONARY and not (s as Dictionary).is_empty())
	if not marked and not states.has(content_id):
		return
	var list: Array = states.get(content_id, [])
	while list.size() < have:
		list.append({})
	for i in n:
		list.append((with[i] as Dictionary).duplicate() if i < with.size() and typeof(with[i]) == TYPE_DICTIONARY else {})
	states[content_id] = list
	_tidy(content_id)


## False (and no change) when there is not enough. The last copies go.
func remove(content_id: String, n: int) -> bool:
	return not take(content_id, n).is_empty()


## Takes `n` copies, from copy `from` on (-1: the last ones): their states,
## or [] (and no change) when there are not so many there.
func take(content_id: String, n: int, from := -1) -> Array:
	var have := count(content_id)
	if from < 0:
		from = have - n
	if n <= 0 or from < 0 or from + n > have:
		return []
	var out: Array = []
	for i in n:
		out.append(state_of(content_id, from + i).duplicate())
	if have == n:
		stacks.erase(content_id)
		states.erase(content_id)
		return out
	stacks[content_id] = have - n
	if states.has(content_id):
		var list: Array = states[content_id]
		while list.size() < have:
			list.append({})
		for i in n:
			list.remove_at(from)
		_tidy(content_id)
	return out


## Sets a copy's state.
func set_state(content_id: String, index: int, state: Dictionary) -> void:
	if index < 0 or index >= count(content_id):
		return
	var list: Array = states.get(content_id, [])
	while list.size() < count(content_id):
		list.append({})
	list[index] = state.duplicate()
	states[content_id] = list
	_tidy(content_id)


## Puts a copy first (the one in use).
func to_front(content_id: String, index: int) -> void:
	if index <= 0 or index >= count(content_id) or not states.has(content_id):
		return
	var list: Array = states[content_id]
	while list.size() < count(content_id):
		list.append({})
	var s: Variant = list[index]
	list.remove_at(index)
	list.insert(0, s)


func _tidy(content_id: String) -> void:
	var list: Array = states.get(content_id, [])
	if list.all(func(s: Dictionary) -> bool: return s.is_empty()):
		states.erase(content_id)


func has_all(costs: Dictionary) -> bool:
	for id: String in costs:
		if count(id) < int(costs[id]):
			return false
	return true


func to_data() -> Dictionary:
	return {"format": FORMAT, "stacks": stacks.duplicate(), "states": states.duplicate(true)}


static func from_data(data: Dictionary) -> Inventory:
	var inv := Inventory.new()
	var s: Dictionary = data.get("stacks", {})
	for id: String in s:
		if int(s[id]) > 0:
			inv.stacks[id] = int(s[id])
	var st: Dictionary = data.get("states", {})
	for id: String in st:
		if inv.stacks.has(id) and typeof(st[id]) == TYPE_ARRAY:
			var list: Array = (st[id] as Array).slice(0, inv.stacks[id]).map(
				func(v: Variant) -> Dictionary: return (v as Dictionary).duplicate() if typeof(v) == TYPE_DICTIONARY else {})
			inv.states[id] = list
			inv._tidy(id)
	return inv
