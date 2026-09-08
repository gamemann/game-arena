class_name ArenaModule
extends DotModule

## Binds an [ArenaGame] to a [DotServer].
##
## [b]This is the only file in the project that names dot-server, and it is the only
## place the family's own documentation says such a bridge belongs.[/b] dot-match does
## not import dot-server, dot-combat does not, and dot-loadout does not — so a game
## that wants a dedicated server writes about forty lines, and they are these.
##
## Loaded the way any module is:
##
## [codeblock]
## server.modules.load_module("res://game/arena_module.gd")
## [/codeblock]
##
## The game itself is found through [DotRegistry] rather than being handed in, which is
## what makes loading by path rather than by instance work at all.

const CHANNEL := "arena.module"

var game: ArenaGame = null

## The netcode. Owned here rather than by the game, because a headless match and a
## dedicated server are different deployments of the same game and only one of them
## replicates.
var net: DotNetManager = null
var bridge: ArenaNetBridge = null

## dot-server session id -> whether we have put them in the match.
var _joined: Dictionary = {}

## The authoritative tick. Counted here because the module is what drives it.
var _tick: int = 0


func _module_name() -> String:
	return "arena"


func _module_version() -> String:
	return "0.1.0"


func _module_description() -> String:
	return "Deathmatch: match flow, combat, loadouts and spawning."


func _module_author() -> String:
	return "dot"


func _module_load() -> DotResult:
	game = DotRegistry.get_node_service(ArenaGame.SERVICE) as ArenaGame

	if game == null:
		# Refusing to load is right: a module that loaded and then did nothing would
		# leave a server that accepts players into a match that does not exist, and
		# the symptom is players who connect and never spawn.
		return DotResult.fail(
			DotError.CODE_STATE,
			"No ArenaGame is registered. Create one and call setup() before loading "
			+ "this module."
		)

	hook_post("client_spawn", _on_client_spawn)

	add_command(
		"arena_status", _cmd_status, "Show the match state", DotAdminFlags.GENERIC
	)
	add_command(
		"arena_score", _cmd_score, "Show the scoreboard", ""
	)
	add_command(
		"arena_restart", _cmd_restart, "Restart the match", DotAdminFlags.CHANGEMAP
	)

	add_cvar("arena_scorelimit", str(game.score_limit), "Kills to win the match")

	# [b]How many players before a round starts, and it has to be an operator's
	# choice.[/b] The default is 2, which is right for a deathmatch and makes a public
	# demonstration server look broken: one person connects, the match sits in WARMUP
	# for ever, nobody spawns, and the only thing on screen is a HUD saying WARMUP. A
	# server with one player and no bots is a legitimate configuration and the operator
	# is the one who knows whether it is theirs.
	add_cvar(
		"arena_minplayers",
		str(game.match_node.rules.min_players),
		"Players needed before a round starts",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_min(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.match_node.rules.min_players = maxi(new_value.to_int(), 1)
			log_info("minimum players changed", {
				"min_players": game.match_node.rules.min_players
			})
	)

	add_command(
		"arena_net", _cmd_net, "Show the netcode's state", ""
	)

	server.client_disconnected.connect(_on_client_disconnected)
	game.player_killed.connect(_on_player_killed)

	var netted := _build_netcode()

	if not netted.ok:
		return netted.wrap("The arena netcode could not start")

	_register_game()

	log_info("arena loaded", {"map": game.map.display_name})
	return DotResult.success(null)


## The manager, the bridge and the link.
##
## [b]The module drives the tick, not the game.[/b] The game's tick has to happen
## INSIDE dot-net's — between applying each peer's inputs and building the snapshot —
## which is what `ArenaNetBridge.server_tick` arranges through
## `ArenaPlayerNet._net_simulate`. A game ticking itself as well would move everybody
## twice.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = ArenaGame.NET_SNAPSHOT_RATE
	config.enable_prediction = true
	# On, and it is the reason dot-combat has a rewind hook at all: a player shooting
	# at where they SEE somebody is shooting at where that player was half a round trip
	# ago, and without compensation every shot at a moving target misses behind them.
	config.enable_lag_compensation = true
	config.max_entities_per_snapshot = 64
	# From the game, so the client cannot be given a different one. See
	# ArenaGame.NET_WORLD_EXTENT.
	config.world_extent = ArenaGame.NET_WORLD_EXTENT
	net.config = config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = ArenaNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	# Under the DotServer node, whose name is the first half of the RPC routing. The
	# client parents its copy under `DotClientLink`, which is named to match.
	bridge.open_link(server)

	# Sealed once, on both ends, after every type is registered. `seal()` assigns wire
	# ids from a sort of the type names, so a type registered after this would renumber
	# every id above it and silently reinterpret every message.
	net.messages.seal()

	return net.start()


## One authoritative tick.
func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null:
		return

	_tick += 1
	bridge.server_tick(_tick)

	# The clock, once a second rather than once a state change.
	#
	# `match_state_changed` covers the transitions and nothing covers the time passing
	# INSIDE one, so a client told the state at signon showed a frozen clock for the
	# whole round — a number produced correctly on the server and never sent, which is
	# this family's most repeated shape. Once a second because it is a clock displayed
	# to whole seconds; at the tick rate it would be 64 reliable messages a second per
	# client to move a digit sixty times less often than that.
	if _tick % maxi(game.tick_rate, 1) == 0:
		bridge.announce_match_state()


## So `changegame`, a vote and the server browser have something to name.
##
## Ships inside the build, so `client_scene` stays empty and the signon takes the
## documented "you already have it" path — dot-server used to fall back to the server's
## own absolute path there, which `DotClientLink` correctly refuses, and the client
## then failed signon and timed out.
func _register_game() -> void:
	if server.games == null or server.games.find_game("arena") != null:
		return

	var descriptor := DotGameDescriptor.new()
	descriptor.game_id = "arena"
	descriptor.display_name = "Arena"
	descriptor.scene = "res://scenes/arena_server.tscn"
	descriptor.module = "res://game/arena_module.gd"
	server.games.add_game(descriptor)


func _module_unload() -> void:
	if net != null and is_instance_valid(net):
		net.stop()

	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	if game != null and is_instance_valid(game):
		if game.player_killed.is_connected(_on_player_killed):
			game.player_killed.disconnect(_on_player_killed)

		# Every player this module put in the match comes back out. A module that
		# unloaded and left them there would leave the game holding bodies whose
		# sessions no longer exist, and the next kill would credit a ghost.
		for userid in _joined.keys():
			var session := server.session_by_userid(int(userid)) if server != null else null

			if session != null and bridge != null and is_instance_valid(bridge):
				bridge.remove_peer(session.peer_id)
			else:
				game.remove_player(int(userid))

	_joined.clear()


# --- Sessions --------------------------------------------------------------

## A client finished the signon and is in the world.
##
## [b]`client_spawn`, not `client_connected`.[/b] A connected client has a socket and
## nothing else — no identity, no content, no confirmation it can load the map. Adding
## them to the match there produces a body for someone who may still fail to join.
func _on_client_spawn(event: DotEvent) -> void:
	# [b]`client_spawn` carries `userid` and `name`. It does not carry `peer_id`.[/b]
	# This read `event.get_int("peer_id")`, which is 0 on every event, so `session_of(0)`
	# returned null and the function returned — **nobody ever joined a dedicated arena
	# server**, silently, for as long as this module has existed. A null session is a
	# legitimate thing to find, so nothing errored, and `dedicated.tscn` passes its
	# twenty-one checks without noticing because it never connects a client.
	#
	# The family's notes have carried this exact bug, found in game-hungario, since
	# before this module was written. Nobody checked here.
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	_add(session)


func _add(session: DotClientSession) -> void:
	if _joined.has(session.userid):
		return

	# The session id, not the peer id. A peer id is reassigned the moment someone
	# reconnects, and everything downstream of this -- the scoreboard, the combat
	# entity, the damage attribution -- would then be handed to the next player to
	# join. dot-server's userid is stable for the life of the session.
	#
	# Through the bridge, which adds them to the game AND registers them as a
	# replicated entity owned by their peer. `game.add_player` alone gives the server a
	# player nothing is ever sent about: the manager only builds snapshots for peers it
	# knows and only holds an input buffer for those, so the server would simulate them
	# perfectly and alone.
	var added := bridge.add_player(
		session.peer_id, session.userid, session.display_name
	)

	if not added.ok:
		log_warn("could not add a player to the match", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true

	log_info("player joined the match", {
		"userid": session.userid, "name": session.display_name
	})


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	if not _joined.has(session.userid):
		return

	# Through the bridge again: it releases the peer's entities, its input buffer and
	# its acknowledgement record as well as taking the player out of the match.
	bridge.remove_peer(session.peer_id)
	_joined.erase(session.userid)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	# The kill feed as chat is a placeholder for a real one, and it is deliberately
	# not nothing: a dedicated server with no HUD still has to be able to show an
	# operator what is happening in the match it is running.
	if server.chat == null:
		return

	server.broadcast_message(str(entry))


# --- Commands --------------------------------------------------------------

func _cmd_net(ctx: DotCmdContext) -> void:
	if net == null:
		ctx.reply("The netcode is not running.")
		return

	for line in net.describe_lines():
		ctx.reply(line)

	if bridge != null:
		ctx.reply(str(bridge.describe()))


func _cmd_status(ctx: DotCmdContext) -> void:
	for line in game.describe_lines():
		ctx.reply(line)


func _cmd_score(ctx: DotCmdContext) -> void:
	for line in game.match_node.scoreboard.describe_lines():
		ctx.reply(line)


func _cmd_restart(ctx: DotCmdContext) -> void:
	game.start(game.current_tick())
	ctx.reply("Match restarted.")
