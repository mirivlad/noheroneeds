class_name HostedGame
extends RefCounted
## "Create a server and play": the authoritative server runs in this process
## and listens on a UDP port for other players (ENet, as a dedicated server
## does); the host plays through an ordinary client connected to it over
## localhost. Nothing skips the server, the host has no special way in.

var world: ServerWorld
var server: GameServer
var client: GameClient
var port := 0
var error := ""
var _server_transport: ENetTransport


## Opens the world, listens on `port`, connects the host. On failure the
## result has `error` set and nothing is left open.
static func start(world_path: String, content: ContentRegistry, player: PlayerIdentity,
		server_identity: PlayerIdentity, character_file: PackedByteArray, listen_port: int,
		max_players: int, options := {}) -> HostedGame:
	var g := HostedGame.new()
	g.port = listen_port
	g.world = ServerWorld.open(world_path, content, options)
	if g.world == null:
		g.error = ServerWorld.open_error if ServerWorld.open_error != "" else "не удалось открыть мир"
		return g
	g._server_transport = ENetTransport.new()
	var err := g._server_transport.start_server(listen_port, max_players)
	if err != OK:
		g.world.close()
		g.world = null
		g.error = "порт %d занят или недоступен (%s)" % [listen_port, error_string(err)]
		return g
	g.server = GameServer.new(g.world, g._server_transport, server_identity)
	g.server.password = String(options.get("password", ""))
	g.server.new_invite()
	var t := ENetTransport.new()
	t.start_client("127.0.0.1", listen_port)
	g.client = GameClient.new(t, player, character_file, content)
	g.client.invite = g.server.invite  # the host comes in by its own invite
	return g


## A link to this running world for other players (ADR-0060): nhn://address:port/invite,
## the address the host is reached at on the local network (or this machine's).
func share_link() -> String:
	var at := "127.0.0.1"
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			at = a
			break
	return "nhn://%s:%d/%s" % [at, port, server.invite]


## Parses a share link: {address, port, invite}; {} when it is not one.
static func parse_link(text: String) -> Dictionary:
	var t := text.strip_edges()
	if not t.begins_with("nhn://"):
		return {}
	var rest := t.trim_prefix("nhn://")
	var slash := rest.find("/")
	var host_port := rest.left(slash) if slash >= 0 else rest
	var hp := host_port.rsplit(":", true, 1)
	if hp.size() != 2 or not hp[1].is_valid_int() or hp[0] == "":
		return {}
	return {"address": hp[0], "port": int(hp[1]), "invite": rest.substr(slash + 1) if slash >= 0 else ""}


func ok() -> bool:
	return error == "" and server != null


## One tick of the server, then of the host's client.
func step() -> void:
	server.step()
	client.step()


func close() -> void:
	if client:
		client.transport.close()
	if server:
		server.shutdown()
		_server_transport.close()
	if world:
		world.close()
	client = null
	server = null
	world = null
