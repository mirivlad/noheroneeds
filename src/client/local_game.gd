class_name LocalGame
extends RefCounted
## Single-player: the same authoritative server in this process, connected to
## the player's client over a MemoryTransport. Nothing skips the server.

var world: ServerWorld
var server: GameServer
var client: GameClient
var _net := MemoryTransport.MemoryNetwork.new()


## Opens (or creates) the world and joins it with the given character file.
## Null if the world cannot be opened.
## options: those of ServerWorld.open ("seed" for a new world).
static func start(world_path: String, content: ContentRegistry, player: PlayerIdentity,
		server_identity: PlayerIdentity, character_file: PackedByteArray, options := {}) -> LocalGame:
	var g := LocalGame.new()
	g.world = ServerWorld.open(world_path, content, options)
	if g.world == null:
		return null
	g.server = GameServer.new(g.world, g._net.server(), server_identity)
	g.client = GameClient.new(g._net.client(), player, character_file, content)
	return g


## One tick of both sides.
func step() -> void:
	server.step()
	client.step()


func close() -> void:
	server.shutdown()
	world.close()
