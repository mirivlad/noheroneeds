class_name ENetTransport
extends Transport
## Transport over ENet through Godot's MultiplayerPeer (ADR-0004), used
## directly: no RPCs and no scene tree. RELIABLE and STATE share ENet's
## default channel (it keeps reliable and unreliable traffic apart); BULK
## has a channel of its own so big transfers never hold up acknowledgements.

const BULK_CHANNEL := 1

var peer := ENetMultiplayerPeer.new()
var _events: Array[Transport.Event] = []


func start_server(port: int, max_clients: int) -> Error:
	var err := peer.create_server(port, max_clients, 1)
	if err == OK:
		_connect_signals()
	return err


func start_client(address: String, port: int) -> Error:
	var err := peer.create_client(address, port, 1)
	if err == OK:
		_connect_signals()
	return err


func poll() -> Array[Transport.Event]:
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var ch := peer.get_packet_channel()
		var mode := peer.get_packet_mode()
		var data := peer.get_packet()
		var channel := Transport.Channel.BULK if ch == BULK_CHANNEL else (
			Transport.Channel.STATE if mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE else Transport.Channel.RELIABLE)
		_events.append(Transport.Event.new(Transport.Kind.PACKET, from, channel, data))
	var out := _events
	_events = []
	return out


func send(to: int, channel: Transport.Channel, data: PackedByteArray) -> void:
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	peer.set_target_peer(to)
	match channel:
		Transport.Channel.STATE:
			peer.transfer_channel = 0
			peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		Transport.Channel.BULK:
			peer.transfer_channel = BULK_CHANNEL
			peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
		_:
			peer.transfer_channel = 0
			peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	peer.put_packet(data)


func disconnect_peer(p: int) -> void:
	peer.disconnect_peer(p)


func own_id() -> int:
	return peer.get_unique_id()


func close() -> void:
	peer.close()


func _connect_signals() -> void:
	peer.peer_connected.connect(_on_connected)
	peer.peer_disconnected.connect(_on_disconnected)


func _on_connected(id: int) -> void:
	_events.append(Transport.Event.new(Transport.Kind.CONNECTED, id))


func _on_disconnected(id: int) -> void:
	_events.append(Transport.Event.new(Transport.Kind.DISCONNECTED, id))
