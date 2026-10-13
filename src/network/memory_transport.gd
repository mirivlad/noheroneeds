class_name MemoryTransport
extends Transport
## In-process transport: a server endpoint and any number of client endpoints
## share a MemoryNetwork. Used by tests and by single-player (local server).
## The network can lose, duplicate and reorder STATE packets and delay
## everything by whole steps, to test the protocol under bad conditions.


class MemoryNetwork:
	extends RefCounted
	## Chance to drop / duplicate a STATE packet; reliable channels never lose.
	var state_loss := 0.0
	var state_duplicate := 0.0
	## Packets are delivered this many deliver() calls after sending.
	var delay_steps := 0
	var rng := RandomNumberGenerator.new()
	## id -> WeakRef of the endpoint (endpoints point back at the network)
	var endpoints := {}
	## Endpoints that are cut: they still receive what was already sent to them.
	var _closed := {}
	var _next_id := 2
	var _in_flight: Array = []  # [due_step, to, Event]
	var _step := 0

	func server() -> MemoryTransport:
		var t := MemoryTransport.new(self, Transport.SERVER)
		endpoints[Transport.SERVER] = weakref(t)
		return t

	## A client endpoint, connected at once (the server sees CONNECTED on its next poll).
	func client() -> MemoryTransport:
		var id := _next_id
		_next_id += 1
		var t := MemoryTransport.new(self, id)
		endpoints[id] = weakref(t)
		_queue(Transport.SERVER, Transport.Event.new(Transport.Kind.CONNECTED, id))
		_queue(id, Transport.Event.new(Transport.Kind.CONNECTED, Transport.SERVER))
		return t

	func cut(id: int) -> void:
		if not endpoints.has(id) or _closed.has(id):
			return
		_closed[id] = true
		if id == Transport.SERVER:
			for other: int in endpoints:
				_queue(other, Transport.Event.new(Transport.Kind.DISCONNECTED, Transport.SERVER))
		else:
			_queue(Transport.SERVER, Transport.Event.new(Transport.Kind.DISCONNECTED, id))
			_queue(id, Transport.Event.new(Transport.Kind.DISCONNECTED, Transport.SERVER))

	## Moves due packets into the receivers' inboxes. Called by poll().
	func deliver() -> void:
		_step += 1
		var later: Array = []
		var due: Array = []
		for f: Array in _in_flight:
			(due if f[0] <= _step else later).append(f)
		_in_flight = later
		# STATE packets may arrive out of order; reliable ones keep their order.
		for f: Array in due:
			var ref: WeakRef = endpoints.get(f[1])
			var t: MemoryTransport = ref.get_ref() if ref else null
			if t:
				t._inbox.append(f[2])

	func _queue(to: int, e: Transport.Event) -> void:
		_in_flight.append([_step + delay_steps, to, e])

	func _send(from: int, to: int, channel: Transport.Channel, data: PackedByteArray) -> void:
		if not endpoints.has(from) or not endpoints.has(to) or _closed.has(from) or _closed.has(to):
			return
		var e := Transport.Event.new(Transport.Kind.PACKET, from, channel, data)
		if channel == Transport.Channel.STATE:
			if rng.randf() < state_loss:
				return
			if rng.randf() < state_duplicate:
				_in_flight.append([_step + delay_steps + rng.randi_range(0, 2), to, e])
			_in_flight.append([_step + delay_steps + rng.randi_range(0, 1 if state_loss > 0 else 0), to, e])
			return
		_queue(to, e)


var _net: MemoryNetwork
var _id := 0
var _inbox: Array[Transport.Event] = []


func _init(net: MemoryNetwork, id: int) -> void:
	_net = net
	_id = id


func poll() -> Array[Transport.Event]:
	if _id == Transport.SERVER:
		_net.deliver()
	var out := _inbox
	_inbox = []
	return out


func send(peer: int, channel: Transport.Channel, data: PackedByteArray) -> void:
	_net._send(_id, peer, channel, data)


func disconnect_peer(peer: int) -> void:
	_net.cut(peer)


func own_id() -> int:
	return _id


func close() -> void:
	_net.cut(_id)
