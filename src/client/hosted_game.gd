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
		g.error = "не удалось открыть мир"
		return g
	g._server_transport = ENetTransport.new()
	var err := g._server_transport.start_server(listen_port, max_players)
	if err != OK:
		g.world.close()
		g.world = null
		g.error = "порт %d занят или недоступен (%s)" % [listen_port, error_string(err)]
		return g
	g.server = GameServer.new(g.world, g._server_transport, server_identity)
	var t := ENetTransport.new()
	t.start_client("127.0.0.1", listen_port)
	g.client = GameClient.new(t, player, character_file, content)
	return g


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
