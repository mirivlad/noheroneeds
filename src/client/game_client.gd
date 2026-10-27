class_name GameClient
extends RefCounted
## The player's side of the connection (ADR-0004). Holds a mirror of what the
## server shows this player, predicts its own movement with the same code as
## the server and corrects it from snapshots. Presentation reads this mirror;
## it never decides outcomes.

var transport: Transport
var identity: PlayerIdentity
## The signed character file this client joins with.
var character_file := PackedByteArray()
## Same content as the server, for the handshake and for predicting walls.
var content: ContentRegistry

## connecting -> challenged -> joining -> playing; rejected / disconnected
var state := "connecting"
var reject_reason := ""
var character_id := ""
## The own character as the server shows it to others (name, appearance).
var own := {}
## The world time (game ms, ADR-0014): the server's from each snapshot,
## carried on between snapshots at the server's rate.
var world_time := 0.0
var time_rate := 0
var has_time := false
## The world's weather (ADR-0033) is worked out here from this and the time.
var weather_seed := 0
## The world's geography (ADR-0049) for the climate of places (ADR-0055); null
## — a world without one (all places mild).
var geography: Geography
var location := ""
## The level label of the location (0 on the surface).
var z := 0
var server_id := ""
## Predicted own position (1/256 cell units).
var position := Vector2i.ZERO
var has_position := false
## Movement intention for the next ticks, each axis -1..1.
var move := Vector2i.ZERO
## Running (held key), 1.5 times as fast.
var run := false
## Other entities as of the newest snapshot: id -> state.
var entities := {}
## chunk key -> Chunk
var chunks := {}
## request id -> result, as acknowledged by the server
var results := {}
## Own position before the last tick, for drawing between ticks.
var previous_position := Vector2i.ZERO
## Chunk keys received since the presentation last asked.
var changed_chunks: Array[String] = []
## Changes seen in the world since the view last took them (see _note_changes).
var world_events: Array[Dictionary] = []
## What the player has in the hands (ADR-0021), as told to the server with
## hold(); told again first thing after a reconnect.
var held := ""
## The server's height limit (ADR-0007), for showing blueprints.
var max_levels := 3
var _quiet := {}
var _hold_sent_at := -100000
## Maps (ADR-0020): location -> {"z": level label, "chunks": {Vector2i: true}}
## the character has seen; "location|cx|cy" -> MapTile ({palette, cells}).
var map_known := {}
var map_tiles := {}
## Tiles changed since the map last looked (keys as map_tiles).
var map_changed: Array[String] = []
var _map_asked := {}
## Times a prediction had to be corrected (for tests and diagnostics).
var corrections := 0

## short net number -> entity id (this connection)
var _uid_of := {}
var _latest_snapshot := 0
var _input_seq := 0
var _unacked_inputs: Array = []
var _requests := {}


func _init(net: Transport, player: PlayerIdentity, file: PackedByteArray, registry: ContentRegistry) -> void:
	transport = net
	identity = player
	character_file = file
	content = registry


## One client tick.
func step() -> void:
	for e in transport.poll():
		match e.kind:
			Transport.Kind.CONNECTED:
				_send(Transport.Channel.RELIABLE, Protocol.HELLO, {"v": Protocol.VERSION, "content": content.fingerprint(),
					"key_alg": PlayerIdentity.KEY_ALG, "public_key": identity.public_pem()})
			Transport.Kind.DISCONNECTED:
				if state != "rejected":
					state = "disconnected"
			Transport.Kind.PACKET:
				_on_message(Protocol.decode(e.data, false))
	_reassert_hold()
	if has_time:
		world_time += time_rate
	if state == "playing" and has_position:
		_input_seq += 1
		_unacked_inputs.append([_input_seq, move.x, move.y, 1 if run else 0])
		previous_position = position
		position = _step(position, move.x, move.y, run)
		_send(Transport.Channel.STATE, Protocol.INPUT, {"inputs": _unacked_inputs.slice(-Protocol.INPUT_REDUNDANCY),
			"ack": _latest_snapshot})


## Takes `item` into the hands ("" empty) and tells the server, if it changed.
## Requests go in order on one reliable channel: an action sent after this is
## done with this item, however quickly it follows.
func hold(item: String) -> void:
	if item == held:
		return
	held = item
	if state == "playing":
		_send_hold()


## Takes a certain copy of a thing into the hands (ADR-0046: the axe of
## two that is less worn): it becomes the first, the one in use. Quiet.
func hold_copy(item: String, copy: int) -> void:
	held = item
	if state != "playing":
		return
	_hold_sent_at = Time.get_ticks_msec()
	var rid := Uuid.v4()
	_quiet[rid] = true
	_send(Transport.Channel.RELIABLE, Protocol.REQUEST, {"request": {"type": "hold", "item": item, "copy": copy, "request_id": rid}})


## If the server shows other hands than ours (it emptied them when the thing
## ran out, and we got another since), we tell it again, now and then.
func _reassert_hold() -> void:
	if state != "playing" or not own.has("held") or String(own["held"]) == held:
		return
	if Time.get_ticks_msec() - _hold_sent_at < 1000:
		return
	_send_hold()


func _send_hold() -> void:
	_hold_sent_at = Time.get_ticks_msec()
	var rid := Uuid.v4()
	_quiet[rid] = true  # its answer is not news for the player
	_send(Transport.Channel.RELIABLE, Protocol.REQUEST, {"request": {"type": "hold", "item": held, "request_id": rid}})


## Sends a request (build, transfer...) and returns its id. It is resent after
## a reconnect until its result arrives; the server applies it only once.
func request(op: Dictionary) -> String:
	var rid := Uuid.v4()
	var r := op.duplicate(true)
	r["request_id"] = rid
	_requests[rid] = r
	if state == "playing":
		_send(Transport.Channel.RELIABLE, Protocol.REQUEST, {"request": r})
	return rid


## Starts over on a new connection, keeping unanswered requests.
func reconnect(net: Transport) -> void:
	transport = net
	state = "connecting"
	has_position = false
	entities.clear()
	own = {}
	chunks.clear()
	_map_asked.clear()
	_uid_of.clear()
	_latest_snapshot = 0
	_unacked_inputs.clear()


## The own inventory as the server last showed it: {item id: count}.
func inventory() -> Dictionary:
	return own.get("inventory", {})


## Each carried copy's own state (ADR-0046: wear): {item id: [state, ...]}
## for things whose copies differ; the first copy is the one in the hands.
func item_states() -> Dictionary:
	return own.get("states", {})


## A carried copy's state ({} plain).
func state_of(item: String, copy := 0) -> Dictionary:
	var list: Array = item_states().get(item, [])
	return list[copy] if copy >= 0 and copy < list.size() and typeof(list[copy]) == TYPE_DICTIONARY else {}


## What the character knows and how well (ADR-0047): {"known": [recipe...],
## "skills": {skill: {level, xp}}, "mastery": {recipe: {level, xp}}}.
func knowledge() -> Dictionary:
	return own.get("knowledge", {})


## Whether the character knows a recipe (innate ones always).
func knows(content: ContentRegistry, recipe: String) -> bool:
	return bool(content.get_def(recipe).get("innate", false)) or (knowledge().get("known", []) as Array).has(recipe)


func skill_level(skill: String) -> int:
	return int(((knowledge().get("skills", {}) as Dictionary).get(skill, {}) as Dictionary).get("level", 0))


func mastery_level(recipe: String) -> int:
	return int(((knowledge().get("mastery", {}) as Dictionary).get(recipe, {}) as Dictionary).get("level", 0))


## The states of what is worn: {slot: state}.
func worn_states() -> Dictionary:
	return own.get("worn_states", {})


## Characters the player has befriended (ADR-0016): they open its chests and
## locked doors.
func friends() -> Array:
	return own.get("friends", [])


func unanswered_requests() -> int:
	return _requests.size()


func _on_message(m: Dictionary) -> void:
	match String(m.get("t", "")):
		Protocol.CHALLENGE:
			server_id = m["server_id"]
			_send(Transport.Channel.RELIABLE, Protocol.AUTH, {"sig_alg": PlayerIdentity.SIG_ALG,
				"signature": identity.sign(Protocol.auth_payload(m["nonce"], server_id, identity.fingerprint))})
			_send(Transport.Channel.RELIABLE, Protocol.JOIN, {"character": character_file})
			state = "joining"
		Protocol.WELCOME:
			character_id = m["character_id"]
			location = m["location"]
			max_levels = int(m["max_levels"])
			weather_seed = int(m.get("weather_seed", 0))
			# The land's climate (ADR-0055), worked out here as the server does.
			var seed_value := int(m.get("world_seed", -1))
			geography = Geography.of(seed_value) if seed_value != -1 else null
			state = "playing"
			# The server knows nothing of our hands after a (re)join: they come
			# before anything resent that may be done with them.
			if held != "":
				_send_hold()
			for rid: String in _requests:
				_send(Transport.Channel.RELIABLE, Protocol.REQUEST, {"request": _requests[rid]})
		Protocol.LOCATION:
			location = m["location"]
			z = m["z"]
			has_position = false  # the next snapshot places us
			_unacked_inputs.clear()
			changed_chunks.append("*")  # the view redraws everything for the new place
		Protocol.REJECT:
			reject_reason = m["reason"]
			state = "rejected"
		Protocol.RESULT:
			if _quiet.has(m["request_id"]):
				_quiet.erase(m["request_id"])
				return
			results[m["request_id"]] = m["result"]
			_requests.erase(m["request_id"])
		Protocol.CHUNK:
			var c := ChunkCodec.decode(m["data"])
			if c:
				var key := ServerWorld.chunk_key(m["location"], m["cx"], m["cy"])
				var old: Chunk = chunks.get(key)
				if old:
					_note_changes(String(m["location"]), Vector2i(int(m["cx"]), int(m["cy"])) * Chunk.SIZE, old, c)
				chunks[key] = c
				changed_chunks.append(key)
				_known_on_map(String(m["location"]), int(m["cx"]), int(m["cy"]), MapTile.of(c))
		Protocol.MAP_KNOWN:
			var known: Dictionary = map_known.get_or_add(String(m["location"]), {"z": int(m["z"]), "chunks": {}})
			known["z"] = int(m["z"])
			var pairs := (m["chunks"] as PackedByteArray).to_int32_array()
			for i in range(0, pairs.size() - 1, 2):
				known["chunks"][Vector2i(pairs[i], pairs[i + 1])] = true
		Protocol.MAP_TILES:
			for t: Variant in m["tiles"]:
				if typeof(t) != TYPE_ARRAY or (t as Array).size() != 3 or typeof(t[2]) != TYPE_PACKED_BYTE_ARRAY:
					continue
				var tile := MapTile.decode(t[2])
				if not tile.is_empty():
					_known_on_map(String(m["location"]), int(t[0]), int(t[1]), tile)
		Protocol.SNAPSHOT:
			_on_snapshot(m)


## What changed in a chunk the client already had, for sounds and effects:
## {"type": "build"|"dismantle"|"open"|"close", "location", "cell", "part"}.
## A chunk seen for the first time is no news.
func _note_changes(loc: String, origin: Vector2i, old: Chunk, new: Chunk) -> void:
	for layer: String in ["structure", "cover", "ceiling", "roof"]:
		var a: PackedInt32Array = old.layers.get(layer, PackedInt32Array())
		var b: PackedInt32Array = new.layers.get(layer, PackedInt32Array())
		if a.is_empty() and b.is_empty():
			continue
		for i in Chunk.CELLS:
			var was := old.palette[a[i]] if not a.is_empty() else ""
			var now := new.palette[b[i]] if not b.is_empty() else ""
			if was == now:
				continue
			var cell := origin + Vector2i(i % Chunk.SIZE, i / Chunk.SIZE)
			if was != "":
				world_events.append({"type": "dismantle", "location": loc, "cell": cell, "part": was})
			if now != "":
				world_events.append({"type": "build", "location": loc, "cell": cell, "part": now})
	var seen := {}
	for i: int in new.props.keys() + old.props.keys():
		if seen.has(i):
			continue
		seen[i] = true
		var was_open := bool((old.props.get(i, {}) as Dictionary).get("open", false))
		var now_open := bool((new.props.get(i, {}) as Dictionary).get("open", false))
		if was_open != now_open:
			var cell := origin + Vector2i(i % Chunk.SIZE, i / Chunk.SIZE)
			var part := new.get_cell("structure", i % Chunk.SIZE, i / Chunk.SIZE)
			world_events.append({"type": "open" if now_open else "close", "location": loc, "cell": cell, "part": part})


func _known_on_map(location: String, cx: int, cy: int, tile: Dictionary) -> void:
	var known: Dictionary = map_known.get_or_add(location, {"z": z if location == self.location else 0, "chunks": {}})
	known["chunks"][Vector2i(cx, cy)] = true
	var key := "%s|%d|%d" % [location, cx, cy]
	map_tiles[key] = tile
	map_changed.append(key)


## Asks the server for the map tiles of seen chunks we do not have (once each).
func request_map(location: String, wanted: Array) -> void:
	var pairs := PackedInt32Array()
	for at: Vector2i in wanted:
		var key := "%s|%d|%d" % [location, at.x, at.y]
		if map_tiles.has(key) or _map_asked.has(key):
			continue
		_map_asked[key] = true
		pairs.append(at.x)
		pairs.append(at.y)
		if pairs.size() >= 512:
			_send(Transport.Channel.RELIABLE, Protocol.MAP_REQUEST, {"location": location, "chunks": pairs.to_byte_array()})
			pairs = PackedInt32Array()
	if not pairs.is_empty() and state == "playing":
		_send(Transport.Channel.RELIABLE, Protocol.MAP_REQUEST, {"location": location, "chunks": pairs.to_byte_array()})


## Snapshots (protocol 7) are differences from what this client last
## acknowledged; the newest one applies on top of what we have, older or
## repeated ones are dropped (the server repeats what we may have missed).
func _on_snapshot(m: Dictionary) -> void:
	var sid: int = m["id"]
	if sid <= _latest_snapshot:
		return
	var removed := (m["removed"] as PackedByteArray).to_int32_array()
	for n in removed:
		entities.erase(_uid_of.get(n, ""))
	var changed: Dictionary = m["entities"]
	for n: Variant in changed:
		var fields: Dictionary = changed[n]
		if typeof(fields.get("uid")) == TYPE_STRING:
			_uid_of[n] = fields["uid"]
			fields.erase("uid")
		var id: String = _uid_of.get(n, "")
		if id == "":
			continue  # a number we were never introduced to: wait for a full state
		if id == character_id:
			own.merge(fields, true)
		else:
			# A creature starts hunting someone: its call (a wolf's howl).
			var before: Dictionary = entities.get(id, {})
			if fields.get("hunting", false) and not before.get("hunting", false) and before.has("x"):
				world_events.append({"type": "chase", "location": location, "part": String(before.get("creature", "")),
					"cell": Movement.cell_of(Vector2i(int(before["x"]), int(before["y"])))})
			if fields.get("kind") == "projectile" and not entities.has(id):
				world_events.append({"type": "shoot", "location": location, "part": String(fields.get("item", "")),
					"cell": Movement.cell_of(Vector2i(int(fields.get("x", 0)), int(fields.get("y", 0))))})
			(entities.get_or_add(id, {}) as Dictionary).merge(fields, true)
	var hot := (m["hot"] as PackedByteArray).to_int32_array()
	for i in range(0, hot.size() - 2, 3):
		var id: String = _uid_of.get(hot[i], "")
		var e: Dictionary = own if id == character_id else entities.get(id, {})
		if id != "" and (id == character_id or entities.has(id)):
			e["x"] = hot[i + 1]
			e["y"] = hot[i + 2]
	var warm := (m["warm"] as PackedByteArray).to_int32_array()
	for i in range(0, warm.size() - 4, 5):
		var id: String = _uid_of.get(warm[i], "")
		var e: Dictionary = own if id == character_id else entities.get(id, {})
		if id != "" and (id == character_id or entities.has(id)):
			if warm[i + 1] < int(e.get("health", warm[i + 1])) and e.has("x"):
				world_events.append({"type": "hit", "location": location, "part": "",
					"cell": Movement.cell_of(Vector2i(int(e["x"]), int(e["y"])))})
			# A blow struck (ADR-0019): others' swings are seen and heard; the
			# own one was shown when it was asked for.
			if e.has("swing") and warm[i + 4] != int(e["swing"]) and id != character_id and e.has("x"):
				world_events.append({"type": "swing", "id": id, "octant": warm[i + 4] & 7, "location": location,
					"part": String(e.get("held", "")), "cell": Movement.cell_of(Vector2i(int(e["x"]), int(e["y"])))})
				if e.get("kind") == "creature":  # a beast's blow: its growl
					world_events.append({"type": "attack", "location": location, "part": String(e.get("creature", "")),
						"cell": Movement.cell_of(Vector2i(int(e["x"]), int(e["y"])))})
			e["health"] = warm[i + 1]
			e["max_health"] = warm[i + 2]
			e["deaths"] = warm[i + 3]
			e["swing"] = warm[i + 4]
	# Creatures that died near: a death cry (AudioDirector plays "death" for its kind).
	for d: Variant in m.get("died", []):
		if typeof(d) == TYPE_ARRAY and (d as Array).size() == 3:
			world_events.append({"type": "death", "location": location, "part": String(d[2]),
				"cell": Movement.cell_of(Vector2i(int(d[0]), int(d[1])))})
	_latest_snapshot = sid
	time_rate = int(m["rate"])
	# The server's clock, unless ours is just ahead by the ticks in flight.
	if not has_time or absf(world_time - float(m["time"])) > time_rate * 10:
		world_time = float(m["time"])
	has_time = true
	if own.has("x"):
		_reconcile(Vector2i(own["x"], own["y"]), m["input_ack"])


## The server's position after input `ack`, plus our inputs it has not seen yet.
func _reconcile(server_pos: Vector2i, ack: int) -> void:
	while not _unacked_inputs.is_empty() and _unacked_inputs[0][0] <= ack:
		_unacked_inputs.pop_front()
	var replay := server_pos
	for e: Array in _unacked_inputs:
		replay = _step(replay, e[1], e[2], e[3] == 1)
	if has_position and replay != position:
		corrections += 1
	if not has_position:
		previous_position = replay
	position = replay
	has_position = true


## Whether a cell of the client's location is solid, as far as it knows.
func is_solid(x: int, y: int) -> bool:
	return _solid(x, y)


func _solid(x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var c: Chunk = chunks.get(ServerWorld.chunk_key(location, cx, cy))
	if c == null:
		return false  # unknown ground: the server will correct us
	return Terrain.is_solid(c, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, content, location != Levels.SURFACE, true)


## A step as the server takes it: in water one swims (ADR-0050), slowly;
## through shallows one wades, not running (ADR-0051); in a boat the one at
## the helm rows it over water, the others sit (ADR-0052).
func _step(pos: Vector2i, dx: int, dy: int, run: bool) -> Vector2i:
	if aboard() != "":
		if not bool(own.get("helm", false)):
			return pos
		var boat: Dictionary = entities.get(aboard(), {})
		var speed := int(content.get_def(String(boat.get("item", ""))).get("vessel", {}).get("speed", Movement.WALK))
		return Movement.step_at(pos, dx, dy, _keeps_boat_out, speed)
	var swim := in_water(pos)
	return Movement.step(pos, dx, dy, _solid, run and not swim and not in_shallows(pos),
		Vector2i(Movement.HALF_X, Movement.HALF_Y), swim)


## The climate of a cell of the surface (ADR-0055): Vector2(warmth, rain).
func climate_at(cell: Vector2i) -> Vector2:
	return geography.climate_at(cell.x, cell.y) if geography and location == Levels.SURFACE else Vector2.ZERO


## Where we are, for the weather: our cell and its climate.
func weather_place() -> Vector2i:
	return Movement.cell_of(position)


func climate() -> Vector2:
	return climate_at(weather_place())


## The boat we are in ("" — none, ADR-0052).
func aboard() -> String:
	return String(own.get("aboard", ""))


## Whether a cell keeps a boat out: all but water and shallows (ADR-0052).
func _keeps_boat_out(x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var c: Chunk = chunks.get(ServerWorld.chunk_key(location, cx, cy))
	return c != null and not Terrain.floats(c, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, content)


## Whether a cell of our location is water or shallows a boat goes on.
func floats(cell: Vector2i) -> bool:
	var cx := floori(float(cell.x) / Chunk.SIZE)
	var cy := floori(float(cell.y) / Chunk.SIZE)
	var c: Chunk = chunks.get(ServerWorld.chunk_key(location, cx, cy))
	return c != null and Terrain.floats(c, cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE, content)


## Whether a position (movement units) on our location is in water.
func in_water(pos: Vector2i) -> bool:
	var cell := Movement.cell_of(pos)
	var cx := floori(float(cell.x) / Chunk.SIZE)
	var cy := floori(float(cell.y) / Chunk.SIZE)
	var c: Chunk = chunks.get(ServerWorld.chunk_key(location, cx, cy))
	return c != null and Terrain.is_water(c, cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE, content)


## Whether a position on our location is in shallows (ADR-0051).
func in_shallows(pos: Vector2i) -> bool:
	var cell := Movement.cell_of(pos)
	var cx := floori(float(cell.x) / Chunk.SIZE)
	var cy := floori(float(cell.y) / Chunk.SIZE)
	var c: Chunk = chunks.get(ServerWorld.chunk_key(location, cx, cy))
	return c != null and Terrain.is_shallow(c, cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE, content)


func _send(channel: Transport.Channel, type: String, fields: Dictionary) -> void:
	transport.send(Transport.SERVER, channel, Protocol.encode(type, fields))
