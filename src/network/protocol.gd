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
const VERSION := 5
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

## Field name -> Variant type, per message a client may send.
const CLIENT_FIELDS := {
	HELLO: {"v": TYPE_INT, "content": TYPE_STRING, "key_alg": TYPE_STRING, "public_key": TYPE_STRING},
	AUTH: {"sig_alg": TYPE_STRING, "signature": TYPE_PACKED_BYTE_ARRAY},
	JOIN: {"character": TYPE_PACKED_BYTE_ARRAY},
	# inputs: [[seq, dx, dy], ...] newest last; ack: newest snapshot id received
	INPUT: {"inputs": TYPE_ARRAY, "ack": TYPE_INT},
	REQUEST: {"request": TYPE_DICTIONARY},
}

## Same for messages from the server.
const SERVER_FIELDS := {
	CHALLENGE: {"nonce": TYPE_PACKED_BYTE_ARRAY, "server_id": TYPE_STRING},
	WELCOME: {"character_id": TYPE_STRING, "location": TYPE_STRING, "tick": TYPE_INT},
	REJECT: {"reason": TYPE_STRING},
	# entities: {net number: {field: value}} changed since the acknowledged
	# base ("uid" with the entity id when it enters the view); removed:
	# [net number]; input_ack: last input seq applied for this client
	SNAPSHOT: {"id": TYPE_INT, "base": TYPE_INT, "tick": TYPE_INT, "entities": TYPE_DICTIONARY,
		"removed": TYPE_ARRAY, "input_ack": TYPE_INT},
	RESULT: {"request_id": TYPE_STRING, "result": TYPE_DICTIONARY},
	CHUNK: {"location": TYPE_STRING, "cx": TYPE_INT, "cy": TYPE_INT, "data": TYPE_PACKED_BYTE_ARRAY},
	# z: the level label (0 surface, +1 first floor...); identity is the id.
	LOCATION: {"location": TYPE_STRING, "z": TYPE_INT},
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
