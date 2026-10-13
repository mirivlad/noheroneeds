class_name Transport
extends RefCounted
## Packet transport under our protocol (ADR-0004). Poll-based, so the server
## needs no scene tree. Peer 1 is always the server.
##
## Channels:
##   RELIABLE   requests, results, handshake, events — reliable, ordered
##   STATE      inputs and snapshots — unreliable, newest wins (sequenced)
##   BULK       chunks and locations — reliable, separate from RELIABLE so
##              a large transfer never delays an acknowledgement

enum Channel { RELIABLE, STATE, BULK }
enum Kind { CONNECTED, DISCONNECTED, PACKET }

const SERVER := 1


class Event:
	var kind: Kind
	var peer := 0
	var channel: Channel = Channel.RELIABLE
	var data := PackedByteArray()

	func _init(k: Kind, p: int, ch: Channel = Channel.RELIABLE, d := PackedByteArray()) -> void:
		kind = k
		peer = p
		channel = ch
		data = d


## Events since the last call, in arrival order.
func poll() -> Array[Event]:
	return []


func send(_peer: int, _channel: Channel, _data: PackedByteArray) -> void:
	pass


func disconnect_peer(_peer: int) -> void:
	pass


## This endpoint's own peer id (1 on the server).
func own_id() -> int:
	return 0


func close() -> void:
	pass
