class_name Protocol
## Network messages (ADR-0004): deterministic CBOR maps with the message type
## in "t". decode() checks the type and every field before anything trusts
## the message: input from the network is hostile until proven otherwise.
##
## Connection: client HELLO -> server CHALLENGE -> client AUTH -> client JOIN
## -> server WELCOME (or REJECT at any step). Then the client sends INPUT
## (STATE channel) and REQUEST (RELIABLE); the server sends SNAPSHOT (STATE),
## RESULT (RELIABLE) and CHUNK (BULK).
##
## Bump VERSION on any change to a message; servers refuse other versions.

## 2: "content" in HELLO is the rules fingerprint (ADR-0009).
## 3: snapshots key entities by short per-connection numbers; the full id
##    comes once, as "uid", when an entity enters the client's view.
## 4: LOCATION tells the client it is now in another location (stairs...).
## 5: an input is [seq, dx, dy, run]: run 1 moves 1.5 times as fast.
## 6: SNAPSHOT carries the world time (game ms) and its rate (ms a tick).
## 7: SNAPSHOT is a difference from what the client has acknowledged (no
##    "base"); positions go packed as int32 [net, x, y] in "hot", removed
##    nets as int32 in "removed".
## 8: SNAPSHOT "warm": int32 [net, health, max health, deaths] (ADR-0019);
##    REQUEST "attack".
## 9: maps (ADR-0020): MAP_KNOWN (the chunks a character has seen in a
##    location), MAP_REQUEST for their tiles, MAP_TILES.
## 10: WELCOME tells the height limit (max_levels), for blueprints (ADR-0021).
## 11: "warm" adds blows struck [.., swing] (count * 8 + octant), for swings to
##    be seen; the own private part carries "friends" with the inventory;
##    REQUESTs "lock", "befriend", "unfriend" (ADR-0016).
## 12: WELCOME tells the weather seed (ADR-0033); the own private part
##    carries "needs" (ADR-0032); REQUESTs "craft", "eat", "till", "sow", "feed".
## 13: SNAPSHOT may carry "died": [[x, y, creature kind]] of creatures that died
##    near this tick; a creature that strikes carries "hunting" (a bool) while
##    it hunts — for their voices. JOIN may carry "password" or "invite" (a
##    server with a password lets in only with one of them, ADR-0060).
const VERSION := 13


## A refusal's reason as a player reads it.
static func reason_text(reason: String) -> String:
	return "неверный пароль, или ссылка на мир устарела" if reason == "password" else reason
## Largest message accepted from a client (a character file is the biggest).
const MAX_CLIENT_MESSAGE := CharacterFile.MAX_BYTES + 4096
## Inputs repeated in each INPUT message, so one lost packet loses nothing.
const INPUT_REDUNDANCY := 4

const HELLO := "hello"
const CHALLENGE := "challenge"
const AUTH := "auth"
const JOIN := "join"
const WELCOME := "welcome"
const REJECT := "reject"
const INPUT := "input"
const REQUEST := "request"
const RESULT := "result"
const SNAPSHOT := "snapshot"
const CHUNK := "chunk"
const LOCATION := "location"
const MAP_KNOWN := "map_known"
const MAP_REQUEST := "map_request"
const MAP_TILES := "map_tiles"

## Field name -> Variant type, per message a client may send.
const CLIENT_FIELDS := {
	HELLO: {"v": TYPE_INT, "content": TYPE_STRING, "key_alg": TYPE_STRING, "public_key": TYPE_STRING},
	AUTH: {"sig_alg": TYPE_STRING, "signature": TYPE_PACKED_BYTE_ARRAY},
	JOIN: {"character": TYPE_PACKED_BYTE_ARRAY},
	# inputs: [[seq, dx, dy], ...] newest last; ack: newest snapshot id received
	INPUT: {"inputs": TYPE_ARRAY, "ack": TYPE_INT},
	REQUEST: {"request": TYPE_DICTIONARY},
	# chunks: int32 [cx, cy, ...] of seen chunks whose map tiles it wants
	MAP_REQUEST: {"location": TYPE_STRING, "chunks": TYPE_PACKED_BYTE_ARRAY},
}

## Same for messages from the server.
const SERVER_FIELDS := {
	CHALLENGE: {"nonce": TYPE_PACKED_BYTE_ARRAY, "server_id": TYPE_STRING},
	WELCOME: {"character_id": TYPE_STRING, "location": TYPE_STRING, "tick": TYPE_INT, "max_levels": TYPE_INT,
		"weather_seed": TYPE_INT},
	REJECT: {"reason": TYPE_STRING},
	# Differences from what the client acknowledged. hot: int32 [net, x, y]
	# positions; entities: {net number: {field: value}} - whole when new to
	# the client ("uid" with the entity id), else cold changes, inventory;
	# removed: int32 nets; input_ack: last input seq applied for this client
	SNAPSHOT: {"id": TYPE_INT, "tick": TYPE_INT, "hot": TYPE_PACKED_BYTE_ARRAY, "warm": TYPE_PACKED_BYTE_ARRAY,
		"entities": TYPE_DICTIONARY,
		"removed": TYPE_PACKED_BYTE_ARRAY, "input_ack": TYPE_INT, "time": TYPE_INT, "rate": TYPE_INT},
	RESULT: {"request_id": TYPE_STRING, "result": TYPE_DICTIONARY},
	CHUNK: {"location": TYPE_STRING, "cx": TYPE_INT, "cy": TYPE_INT, "data": TYPE_PACKED_BYTE_ARRAY},
	# z: the level label (0 surface, +1 first floor...); identity is the id.
	LOCATION: {"location": TYPE_STRING, "z": TYPE_INT},
	# chunks: int32 [cx, cy, ...]; z: the location's level label
	MAP_KNOWN: {"location": TYPE_STRING, "z": TYPE_INT, "chunks": TYPE_PACKED_BYTE_ARRAY},
	# tiles: [[cx, cy, MapTile bytes], ...]
	MAP_TILES: {"location": TYPE_STRING, "tiles": TYPE_ARRAY},
}


static func encode(type: String, fields: Dictionary) -> PackedByteArray:
	var m := fields.duplicate()
	m["t"] = type
	var out := Cbor.encode_fast(m)
	assert(not out.is_empty(), "unencodable %s: %s" % [type, Cbor.last_error])
	return out


## The message as a Dictionary, or {} if it is malformed or not allowed here.
static func decode(data: PackedByteArray, from_client: bool) -> Dictionary:
	if from_client and data.size() > MAX_CLIENT_MESSAGE:
		return {}
	var d := Cbor.decode(data)
	if not d.ok or typeof(d.value) != TYPE_DICTIONARY:
		return {}
	var m: Dictionary = d.value
	var schema: Dictionary = (CLIENT_FIELDS if from_client else SERVER_FIELDS).get(m.get("t", ""), {})
	if schema.is_empty():
		return {}
	for f: String in schema:
		if typeof(m.get(f)) != schema[f]:
			return {}
	return m


## [[seq, dx, dy], ...] -> only well-formed entries with dx, dy in -1..1.
static func clean_inputs(raw: Array) -> Array:
	var out: Array = []
	for e: Variant in raw.slice(-INPUT_REDUNDANCY):
		if typeof(e) == TYPE_ARRAY and (e as Array).size() == 4 and typeof(e[0]) == TYPE_INT \
				and typeof(e[1]) == TYPE_INT and typeof(e[2]) == TYPE_INT and absi(e[1]) <= 1 and absi(e[2]) <= 1 \
				and typeof(e[3]) == TYPE_INT and (e[3] == 0 or e[3] == 1):
			out.append(e)
	return out


## What a client signs in AUTH: the server's challenge bound to both parties.
static func auth_payload(nonce: PackedByteArray, server_id: String, player_fingerprint: String) -> PackedByteArray:
	return Cbor.encode({"nonce": nonce, "server_id": server_id, "player": player_fingerprint, "v": VERSION})
