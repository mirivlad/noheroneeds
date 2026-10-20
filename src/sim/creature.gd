class_name Creature
extends RefCounted
## A living creature's state (ADR-0018): an animal or an NPC. What it is lies
## in its content definition (kind); here is only what changes. It knows the
## world only through its memory, which perception fills.

const NO_TARGET := Vector2i(1 << 30, 1 << 30)

var id := ""
## Content id of its definition (base:hare...).
var kind := ""
var location := ""
## Position in movement units (Movement.UNIT a cell).
var pos := Vector2i.ZERO
## The cell its life goes round: where it grazes, where a villager lives.
var home := Vector2i.ZERO
## Behaviour state: graze, wander, flee, alert, rest, idle, go_home, home...
var state := "idle"
var target := NO_TARGET
var running := false
## What it knows: id -> {"pos": Vector2i, "time": world ms, "what": "character"|"noise"}.
var memory := {}
## World time it last thought (for catching up after a time away).
var last_time := 0
## Health (ADR-0019); -1 until it is given its definition's.
var health := -1
## What a looter swallowed (ADR-0016): [{"item", "count", "at": world ms}],
## digested in time, given back if it is killed first.
var stomach: Array = []
## Husbandry (ADR-0030): whose it is ("" wild), feeds toward taming, world
## ms it was last fed, last bred, last gave its produce.
var owner := ""
var fed := 0
var fed_at := -1
var bred_at := -1
var made_at := -1
## World ms it last filled a container (a cow milked, ADR-0037).
var filled_at := -1
## A villager's place in its settlement (ADR-0039): {"village", "home" (its
## index), "profession", "water" (a fisher's spot, once found)}.
var job := {}
## Not saved — what others see of it: the thing in its hands, its last words
## and how many it has said, whether it sleeps.
var held := ""
var say := ""
var said := 0
var said_at := -1
var asleep := false
## Not saved: the way it walks (cells where it turns) and where it leads.
var path: Array[Vector2i] = []
var path_to := NO_TARGET
## Looks of an NPC (as a character's appearance); empty for animals.
var looks := {}
## Its own random sequence, from its id: the same world gives the same lives.
var seed := 0
## Not saved: the tick it thinks next, ticks it has not moved while walking.
var next_think := 0
var stuck := 0
## Not saved: the key of the chunk it was last found in, for that chunk and location.
var chunk_key := ""
var chunk_at := Vector2i(1 << 30, 0)
var chunk_location := ""
## Bumped by every change worth saving; saved_version: the last one saved.
var version := 1
var saved_version := 0


func to_data() -> Dictionary:
	var mem := {}
	for k: String in memory:
		var m: Dictionary = memory[k]
		mem[k] = {"x": (m["pos"] as Vector2i).x, "y": (m["pos"] as Vector2i).y, "time": int(m["time"]), "what": String(m["what"])}
	return {"kind": kind, "x": pos.x, "y": pos.y, "hx": home.x, "hy": home.y, "state": state,
		"tx": target.x, "ty": target.y, "run": running, "memory": mem, "last_time": last_time,
		"looks": looks.duplicate(true), "seed": seed, "health": health, "stomach": stomach.duplicate(true),
		"owner": owner, "fed": fed, "fed_at": fed_at, "bred_at": bred_at, "made_at": made_at, "filled_at": filled_at, "job": job.duplicate()}


static func from_data(cid: String, loc: String, d: Dictionary) -> Creature:
	var c := Creature.new()
	c.id = cid
	c.location = loc
	c.kind = String(d.get("kind", ""))
	c.pos = Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	c.home = Vector2i(int(d.get("hx", 0)), int(d.get("hy", 0)))
	c.state = String(d.get("state", "idle"))
	c.target = Vector2i(int(d.get("tx", NO_TARGET.x)), int(d.get("ty", NO_TARGET.y)))
	c.running = bool(d.get("run", false))
	c.last_time = int(d.get("last_time", 0))
	c.looks = d.get("looks", {})
	c.seed = int(d.get("seed", 0))
	c.health = int(d.get("health", -1))
	c.owner = String(d.get("owner", ""))
	c.fed = int(d.get("fed", 0))
	c.fed_at = int(d.get("fed_at", -1))
	c.bred_at = int(d.get("bred_at", -1))
	c.made_at = int(d.get("made_at", -1))
	c.filled_at = int(d.get("filled_at", -1))
	c.job = d.get("job", {}) if d.get("job") is Dictionary else {}
	for e: Variant in d.get("stomach", []):
		if e is Dictionary:
			c.stomach.append({"item": String(e.get("item", "")), "count": int(e.get("count", 0)), "at": int(e.get("at", 0))})
	var mem: Dictionary = d.get("memory", {})
	for k: String in mem:
		var m: Dictionary = mem[k]
		c.memory[k] = {"pos": Vector2i(int(m["x"]), int(m["y"])), "time": int(m["time"]), "what": String(m["what"])}
	c.saved_version = c.version
	return c


func cell() -> Vector2i:
	return Movement.cell_of(pos)


func changed() -> void:
	version += 1


## A random number 0..1 from its seed and a counter (deterministic).
func rand(salt: int) -> float:
	var h := hash([seed, salt])
	return float(absi(h) % 1000003) / 1000003.0
