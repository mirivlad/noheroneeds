class_name WorldHydrology
extends RefCounted
## Global priority flood, from the oceans across the entire stored world.
## Its drainage graph is constructed once and persisted with the plan.

const DIRECTIONS := [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
	Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]
const LEVELS := 4096


static func index_at(plan: WorldPlan, p: Vector2i) -> int:
	if plan.preset == "single_continent":
		if p.x < 0 or p.y < 0 or p.x >= plan.size.x or p.y >= plan.size.y:
			return -1
	else:
		p.y = posmod(p.y, plan.size.y * 2)
		if p.y >= plan.size.y:
			p.y = plan.size.y * 2 - 1 - p.y
			p.x += plan.size.x / 2
		p.x = posmod(p.x, plan.size.x)
	return p.y * plan.size.x + p.x


static func build(plan: WorldPlan) -> void:
	var count := plan.size.x * plan.size.y
	plan.downstream.resize(count)
	plan.downstream.fill(-1)
	plan.river.resize(count)
	plan.lake.resize(count)
	var height := PackedFloat32Array()
	height.resize(count)
	var filled := PackedFloat32Array()
	filled.resize(count)
	var flow := PackedFloat32Array()
	flow.resize(count)
	var seen := PackedByteArray()
	seen.resize(count)
	var buckets: Array[Array] = []
	buckets.resize(LEVELS)
	for b in LEVELS:
		buckets[b] = []
	for k in count:
		height[k] = float(plan.fields[k * 3]) / 127.5 - 1.0
		flow[k] = (float(plan.fields[k * 3 + 2]) / 127.5) if height[k] >= 0.0 else 0.0
		if height[k] < 0.0:
			seen[k] = 1
			filled[k] = height[k]
			buckets[_bucket(height[k])].append(k)
	var order := PackedInt32Array()
	order.resize(count)
	var pointers := PackedInt32Array()
	pointers.resize(LEVELS)
	var done := 0
	var b := 0
	while b < LEVELS:
		var bucket: Array = buckets[b]
		if pointers[b] >= bucket.size():
			b += 1
			continue
		var k: int = bucket[pointers[b]]
		pointers[b] += 1
		order[done] = k
		done += 1
		var p := Vector2i(k % plan.size.x, k / plan.size.x)
		for direction: Vector2i in DIRECTIONS:
			var next := index_at(plan, p + direction)
			if next < 0 or seen[next]:
				continue
			seen[next] = 1
			filled[next] = maxf(height[next], filled[k] + 0.00002)
			plan.downstream[next] = k
			var nb := _bucket(filled[next])
			buckets[nb].append(next)
			b = mini(b, nb)
	for i in range(done - 1, -1, -1):
		var k := order[i]
		var dest := plan.downstream[k]
		if dest >= 0:
			flow[dest] += flow[k]
	for k in count:
		if filled[k] - height[k] >= 0.012 and filled[k] >= 0.0:
			plan.lake[k] = filled[k]
		elif height[k] >= 0.0 and flow[k] >= 20.0:
			plan.river[k] = clampf(1.5 + sqrt(flow[k] - 20.0) * 0.55, 1.5, 9.0)


static func _bucket(height: float) -> int:
	return clampi(int((height + 1.0) * 0.5 * (LEVELS - 1)), 0, LEVELS - 1)
