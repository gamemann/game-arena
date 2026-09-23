extends Node

const ArenaEvent := preload("../game/arena_event.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapSession := preload("../game/arena_map_session.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaNetCommand := preload("../game/arena_net_command.gd")
const ArenaNetLink := preload("../game/arena_net_link.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerNet := preload("../game/arena_player_net.gd")

## Two clients, one server, one process, and a lossy wire between them.
##
## [b]This is the first time anything in this family runs netcode over more than one
## client.[/b] dot-net's own integration run adds exactly one peer, which is the one
## shape in which "replicate to everybody" and "replicate to whoever is served first"
## look identical — and that is precisely how a replication bug survived in dot-net
## until it was looked for. Two peers here is not thoroughness, it is the minimum that
## tests the thing at all.
##
## Everything is real except the socket: real managers, a real [ArenaGame] on all
## three sides, real bit-packed commands, real snapshots, real acknowledgements, and
## one packet in five dropped in each direction.

const TICK_RATE := 64
const SNAPSHOT_RATE := 16
const RUN_TICKS := 96
const LOSS_EVERY := 5

const CHECKS := 123

var _passed := 0
var _failed := 0

var _server_game: ArenaGame = null
var _server_net: DotNetManager = null
var _server_bridge: ArenaNetBridge = null

## peer id -> {game, net, bridge}
var _clients: Dictionary = {}

## Payloads in flight, server -> client. Each is {peer, bytes}.
var _downstream: Array = []
var _drop_down := 0
var _drop_up := 0
var _joins: Array[PackedByteArray] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("game-arena — netcode over two clients")

	_build_server()
	_build_client(2, 11)
	_build_client(3, 12)
	_test_command_wire()
	_test_event_wire()
	_test_config_agreement()
	_join_everyone()
	_run_ticks()
	_test_convergence()
	_test_acks_and_recovery()
	_test_owner_only()
	_test_ready_gate()
	_test_predicted_node_is_not_moved()
	await _test_map_sync_wire()
	_test_voice_wire()
	_test_forced_noclip_is_predicted()
	_test_disconnect()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s%s" % [what, "" if detail == "" else "  — " + detail])
	return condition


# --- Construction ----------------------------------------------------------

func _make_game(authority: bool) -> ArenaGame:
	var game := ArenaGame.new()
	game.name = "Arena%s" % ("Server" if authority else str(_clients.size()))
	game.tick_rate = TICK_RATE
	game.score_limit = 50
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = authority
	game.register_service = false
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())
	_check(ready.ok, "%s game sets up" % ("server" if authority else "client"), str(ready.error))

	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0
	game.start(0)
	return game


func _make_manager(is_server: bool, scope: StringName, peer_id: int) -> DotNetManager:
	var net := DotNetManager.new()
	net.name = "Net%s" % scope
	net.is_server = is_server
	net.service_scope = scope
	net.local_peer_id = peer_id
	net.auto_tick = false
	net.config_file = ""
	net.config = DotNetConfig.new()
	net.config.tick_rate = TICK_RATE
	net.config.snapshot_rate = SNAPSHOT_RATE
	# From the game, exactly as `ArenaModule` and `ArenaClient` do it. A suite that
	# left this at dot-net's default would agree with itself on both ends and prove
	# nothing about the two that actually ship — which is how the 128-against-256
	# mismatch survived until a browser drew sky in every direction.
	net.config.world_extent = ArenaGame.NET_WORLD_EXTENT
	add_child(net)

	_check(net.setup().ok, "%s manager sets up" % scope)

	# NOT started here. `DotNetManager.start` seals the message registry, and
	# `ArenaNetBridge.attach` registers this game's two message types — registering
	# after the seal fails, because ids are on the wire and adding a type would
	# renumber every id above it and silently reinterpret every message. So the order
	# is setup, attach, start, and it is the same order `ArenaModule` and
	# `ArenaClient` use. See `_start`.
	return net


## Seals the message registry and starts a manager. Called AFTER its bridge attached.
func _start(net: DotNetManager) -> void:
	net.messages.seal()
	net.start()


func _build_server() -> void:
	print("")
	print("[server]")

	_server_game = _make_game(true)
	_server_net = _make_manager(true, &"server", 1)

	_server_bridge = ArenaNetBridge.new()
	_server_bridge.name = "ServerBridge"
	add_child(_server_bridge)
	_check(_server_bridge.attach(_server_game, _server_net).ok, "the bridge attaches")
	_start(_server_net)

	# A game and a manager that disagree about authority is the one wiring mistake
	# that produces a server resolving nobody's hits, silently.
	var wrong := ArenaNetBridge.new()
	_check(
		not wrong.attach(_server_game, _make_manager(false, &"stray", 9)).ok,
		"a client manager behind an authoritative game is refused"
	)
	wrong.free()

	_server_bridge.player_announced.connect(func(payload: PackedByteArray) -> void:
		_joins.append(payload)
	)

	# The server's payloads land in the addressed client, with loss.
	_server_net.send_fn = func(peer_id: int, payload: PackedByteArray, _d: int) -> void:
		_drop_down += 1
		if _drop_down % LOSS_EVERY == 0:
			return
		_downstream.append({"peer": peer_id, "bytes": payload})


func _build_client(peer_id: int, session_id: int) -> void:
	print("")
	print("[client %d]" % peer_id)

	var game := _make_game(false)
	var net := _make_manager(false, &"client%d" % peer_id, peer_id)

	var bridge := ArenaNetBridge.new()
	bridge.name = "Bridge%d" % peer_id
	add_child(bridge)
	_check(bridge.attach(game, net).ok, "the bridge attaches")
	_start(net)

	# The clock is estimated from the server's ticks in a real deployment; this run
	# drives both sides tick for tick, so it is simply told.
	net.clock.tick = 0

	_clients[peer_id] = {
		"game": game, "net": net, "bridge": bridge, "session": session_id
	}


# --- The wire --------------------------------------------------------------

func _test_command_wire() -> void:
	print("")
	print("[command wire]")

	var move := DotFpsCommand.new()
	move.move = Vector2(0.6, -0.4)
	move.yaw = 137.5
	move.pitch = -12.0
	move.set_button(DotFpsCommand.BUTTON_JUMP, true)

	var fire := DotWeaponCommand.new()
	fire.slot = 2
	fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

	var sent := ArenaNetCommand.new()
	sent.tick = 4242
	sent.delta = 1.0 / float(TICK_RATE)
	sent.move = move
	sent.fire = fire

	var writer := DotNetWriter.new()
	sent.write(writer)

	var got := ArenaNetCommand.new()
	got.read(DotNetReader.new(writer.to_bytes()))

	_check(got.tick == 4242, "the tick survives the wire")
	_check(got.move.move.distance_to(move.move) < 0.01, "the move vector survives")
	_check(absf(got.move.yaw - move.yaw) < 0.2, "the yaw survives", str(got.move.yaw))
	_check(got.move.is_pressed(DotFpsCommand.BUTTON_JUMP), "jump survives")
	_check(got.fire.slot == 2, "the weapon slot survives")
	_check(got.fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK), "attack survives")
	_check(
		absf(got.fire.yaw - got.move.yaw) < 0.001,
		"the aim is the movement's, not a second copy"
	)

	# The one thing quantisation cannot bound: a legal pair of components with an
	# illegal length. Diagonal at full deflection is 41% more speed than anyone else.
	var cheat := ArenaNetCommand.new()
	cheat.move = DotFpsCommand.new()
	cheat.move.move = Vector2(1.0, 1.0)
	cheat.fire = DotWeaponCommand.new()
	cheat.sanitise(TICK_RATE)
	_check(
		cheat.move.move.length() <= 1.001,
		"a diagonal cannot outrun a straight line",
		str(cheat.move.move.length())
	)

	var greedy := ArenaNetCommand.new()
	greedy.move = DotFpsCommand.new()
	greedy.fire = DotWeaponCommand.new()
	greedy.delta = 10.0
	greedy.sanitise(TICK_RATE)
	_check(greedy.delta <= 2.0 / float(TICK_RATE), "a ten-second tick is refused")


# --- Joining ---------------------------------------------------------------

func _join_everyone() -> void:
	print("")
	print("[joins]")

	for peer_id in _clients:
		var entry: Dictionary = _clients[peer_id]
		var added := _server_bridge.add_player(
			peer_id, int(entry["session"]), "Player %d" % peer_id
		)
		_check(added.ok, "peer %d joins the server" % peer_id, str(added.error))

	_check(_joins.size() == 2, "both joins were announced", str(_joins.size()))
	_check(_server_net.registry.count() == 2, "two entities are replicated")

	# Every client learns about every player, itself included.
	for peer_id in _clients:
		var bridge: ArenaNetBridge = _clients[peer_id]["bridge"]

		for payload in _joins:
			_check(bridge.apply_join(payload).ok, "client %d mirrors a join" % peer_id)

		var net: DotNetManager = _clients[peer_id]["net"]
		_check(net.registry.count() == 2, "client %d knows both players" % peer_id)

		var mine := net.registry.owned_by(peer_id)
		_check(mine.size() == 1, "client %d owns exactly one" % peer_id)
		_check(mine[0].is_predicted(), "and predicts it")

	_check(
		not _clients[2]["bridge"].apply_join(PackedByteArray([1, 2])).ok,
		"a truncated join is refused"
	)


# --- Running ---------------------------------------------------------------

func _commands_for(peer_id: int, tick: int) -> Array:
	var move := DotFpsCommand.new()
	# Peer 2 runs one way and peer 3 the other, so a client that received only its
	# own entity's updates would still fail the convergence check below.
	move.move = Vector2(0.0, 1.0 if peer_id == 2 else -1.0)
	move.yaw = 0.0 if peer_id == 2 else 180.0

	var fire := DotWeaponCommand.new()
	fire.slot = 2

	if tick % 8 == 0:
		fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

	return [move, fire]


func _run_ticks() -> void:
	print("")
	print("[running %d ticks]" % RUN_TICKS)

	for tick in range(1, RUN_TICKS + 1):
		# Clients send input for the tick the server is about to run, which is what
		# "input runs ahead" means in practice.
		for peer_id in _clients:
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			var packet: PackedByteArray = entry["bridge"].encode_input(
				tick, pair[0], pair[1]
			)

			_drop_up += 1
			if _drop_up % LOSS_EVERY != 0:
				_server_bridge.receive_input(peer_id, packet)

		_server_bridge.server_tick(tick)

		for entry_down in _downstream:
			var peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if peer == 0 else [peer]

			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])

		_downstream.clear()

		for peer_id in _clients:
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			entry["net"].clock.tick = tick
			entry["bridge"].client_tick(tick, pair[0], pair[1])

	_check(_server_game.current_tick() == RUN_TICKS, "the server ticked once per tick",
		str(_server_game.current_tick()))
	_check(_server_net.stats.packets_sent > 0, "snapshots went out")


# --- What it proves --------------------------------------------------------

func _test_convergence() -> void:
	print("")
	print("[convergence]")

	for peer_id in _clients:
		var entry: Dictionary = _clients[peer_id]
		var net: DotNetManager = entry["net"]
		_check(
			net.stats.packets_received > 0,
			"client %d received snapshots" % peer_id,
			str(net.stats.packets_received)
		)
		_check(net.stats.decode_failures == 0, "client %d had no decode failures" % peer_id)

	# Every client's copy of every player has to track the server. A client that got
	# only the first peer's updates — the shape of dot-net's replication bug — passes
	# half of these and fails the other half.
	for peer_id in _clients:
		var bridge: ArenaNetBridge = _clients[peer_id]["bridge"]

		for other_peer in _clients:
			var session := int(_clients[other_peer]["session"])
			var mine: ArenaPlayerNet = bridge.behaviour_for(session)
			var theirs: ArenaPlayerNet = _server_bridge.behaviour_for(session)

			_check(mine != null and theirs != null, "client %d has player %d" % [peer_id, session])

			if mine == null or theirs == null:
				continue

			var apart := mine.player.controller.state.position.distance_to(
				theirs.player.controller.state.position
			)
			_check(
				apart < 1.5,
				"client %d tracks player %d within 1.5 m" % [peer_id, session],
				"%.2f m apart" % apart
			)

	var server_moved := _server_bridge.behaviour_for(11).player.controller.state.position
	_check(server_moved.length() > 1.0, "the server actually simulated movement",
		str(server_moved))


func _test_acks_and_recovery() -> void:
	print("")
	print("[acknowledgements]")

	for peer_id in _clients:
		_check(
			_server_net.peer_acks_wired(peer_id),
			"peer %d's acknowledgements are arriving" % peer_id
		)

	# A value that changes rarely is the one acknowledgements exist for: a position is
	# repaired by the next snapshot, health is not.
	var victim: ArenaPlayerNet = _server_bridge.behaviour_for(11)
	victim.player.health.health = maxf(1.0, victim.player.health.health - 37.0)

	for tick in range(RUN_TICKS + 1, RUN_TICKS + 41):
		for peer_id in _clients:
			var pair := _commands_for(peer_id, tick)
			var packet: PackedByteArray = _clients[peer_id]["bridge"].encode_input(
				tick, pair[0], pair[1]
			)
			_drop_up += 1
			if _drop_up % LOSS_EVERY != 0:
				_server_bridge.receive_input(peer_id, packet)

		_server_bridge.server_tick(tick)

		for entry_down in _downstream:
			var peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if peer == 0 else [peer]
			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])
		_downstream.clear()

		for peer_id in _clients:
			_clients[peer_id]["net"].clock.tick = tick
			var pair2 := _commands_for(peer_id, tick)
			_clients[peer_id]["bridge"].client_tick(tick, pair2[0], pair2[1])

	var authoritative := int(ceil(victim.player.health.health))

	for peer_id in _clients:
		var seen: ArenaPlayerNet = _clients[peer_id]["bridge"].behaviour_for(11)
		_check(
			absi(seen.net_health - authoritative) <= 1,
			"client %d has the right health for player 11" % peer_id,
			"saw %d, server has %d" % [seen.net_health, authoritative]
		)

	_check(
		_server_net.stats.packets_sent > 0 and _clients[3]["net"].stats.snapshots_lost > 0,
		"loss was real",
		"client 3 lost %d" % _clients[3]["net"].stats.snapshots_lost
	)


func _test_owner_only() -> void:
	print("")
	print("[audience]")

	# Client 2 owns player 11 and observes player 12. Ammunition is owner-only, so it
	# must know its own and not the other's — data never sent cannot be read out of a
	# modified client.
	var bridge: ArenaNetBridge = _clients[2]["bridge"]
	var own: ArenaPlayerNet = bridge.behaviour_for(11)
	var other: ArenaPlayerNet = bridge.behaviour_for(12)

	var declaration := own.find_var(&"net_magazine")
	_check(
		declaration != null and declaration.audience == DotNetVar.Audience.OWNER,
		"ammunition is declared owner-only"
	)
	_check(
		other.net_magazine == 0,
		"and an opponent's is never received",
		"received %d" % other.net_magazine
	)
	# Not asserted: that the owner's own ammunition arrives non-zero. It does travel —
	# the declaration above is what puts it on the wire for the owner alone — but a
	# client's arsenal is empty, because a loadout is resolved from a store on the
	# server and nothing replicates it yet. The predicted `pull()` then overwrites the
	# received value with the local arsenal's zero. Replicating the loadout is the
	# next piece of work here; see this project's CLAUDE.md.
	_check(other.net_health > 0, "while an opponent's health does arrive",
		str(other.net_health))


# --- Maps and voice over the link -------------------------------------------

## dot-map's announce/ready/load protocol, over this game's own link.
##
## [b]dot-map's own suite runs this over a loopback `send_fn` and never over
## dot-net.[/b] Its notes say so, and they say what follows from it: the seam between
## a map sync host and a real game's transport is the one nothing has run. This is
## that seam — two [ArenaNetLink]s, a real [DotMapSyncHost] and a real
## [DotMapSyncClient], with the payloads going through the same `send_map` a socket
## would use.
func _test_map_sync_wire() -> void:
	print("")
	print("[map sync over the link]")

	var server_link := ArenaNetLink.attached_to(self, _server_bridge, true)
	server_link.name = "MapServerLink"

	var client_entry: Dictionary = _clients[_clients.keys()[0]]
	var client_bridge: ArenaNetBridge = client_entry["bridge"]
	var client_link := ArenaNetLink.attached_to(self, client_bridge, false)
	client_link.name = "MapClientLink"

	# Both loopbacks, crossed. `send_map` refuses to fall through to an RPC when the
	# byte loopback is set, so a harness that wired one and not the other would get a
	# silent no-op rather than a crash — which is why the counters are asserted below
	# rather than only the outcome.
	server_link.loopback = func(_m: StringName, _p: int, _b: PackedByteArray) -> void: pass
	client_link.loopback = func(_m: StringName, _p: int, _b: PackedByteArray) -> void: pass

	server_link.loopback_map = func(m: StringName, peer: int, payload: Dictionary) -> void:
		client_link.deliver_map(m, peer, payload)

	client_link.loopback_map = func(m: StringName, _peer: int, payload: Dictionary) -> void:
		server_link.deliver_map(m, 2, payload)

	var catalogue := ArenaMaps.catalogue()

	var session := ArenaMapSession.new()
	session.name = "MapSession"
	session.game = _server_game
	session.catalogue = catalogue
	add_child(session)

	var host := DotMapSyncHost.new()
	host.name = "MapHost"
	host.session = session
	host.sync_timeout_sec = 5.0
	host.send_fn = func(peer: int, payload: Dictionary) -> void:
		server_link.send_map(peer, payload)
	add_child(host)

	# The FOLLOWER needs a catalogue too, and leaving it out looks exactly like a
	# trust refusal: `DotMapSyncClient` accepts an announced map only if it is in its
	# own catalogue at the same version, or is delivered content. With no session it
	# has no catalogue, so every one of this game's maps was refused with "a host may
	# not send a map that is not delivered content" — which is the correct answer to
	# the question it was actually being asked.
	var client_game: ArenaGame = client_entry["game"]

	var follower_session := ArenaMapSession.new()
	follower_session.name = "FollowerSession"
	follower_session.game = client_game
	follower_session.catalogue = ArenaMaps.catalogue()
	add_child(follower_session)

	var follower := DotMapSyncClient.new()
	follower.name = "MapFollower"
	follower.session = follower_session
	follower.accept_unknown_maps = true
	follower.send_fn = func(payload: Dictionary) -> void:
		client_link.send_map_report(payload)
	add_child(follower)

	# One argument. `DotMapSyncClient.changed` carries the map and nothing else, unlike
	# `DotMapSession.changed`, which carries the world as well.
	var loads: Array[StringName] = []
	follower.changed.connect(func(map: DotMapDef) -> void: loads.append(map.id))

	_server_bridge.map_report_fn = func(peer: int, payload: Dictionary) -> void:
		host.handle(peer, payload)

	client_bridge.map_in_fn = func(payload: Dictionary) -> void:
		follower.handle(payload)

	host.add_peer(2)

	var target: StringName = &"dm_atrium" if _server_game.map.id == &"dm_box" else &"dm_box"
	var changed: DotResult = await host.change_to(target)

	_check(changed.ok, "the server changes map with a peer following", str(changed.error))
	_check(
		server_link.map_sent > 0,
		"announcements went out on the link",
		"%d" % server_link.map_sent
	)
	_check(
		client_link.map_received > 0,
		"and the client received them",
		"%d" % client_link.map_received
	)

	# The report going back is the half that makes the wait mean anything. Without it
	# the host waits out its whole timeout and swaps without the client — which
	# `swap_without_stragglers` permits, so the change would still "work" and the peer
	# would still be on the old map.
	_check(
		server_link.map_received > 0,
		"the client reported back, so the host did not wait out its timeout",
		"%d" % server_link.map_received
	)

	_check(loads.has(target), "and the client was told to load the new map")
	_check(_server_game.map.id == target, "the server is on it")
	_check(
		client_game.map.id == target,
		"and so is the client, having rebuilt the world itself",
		String(client_game.map.id)
	)

	host.queue_free()
	follower.queue_free()
	follower_session.queue_free()
	remove_child(follower_session)
	session.queue_free()
	server_link.queue_free()
	client_link.queue_free()
	remove_child(host)
	remove_child(follower)
	remove_child(session)
	remove_child(server_link)
	remove_child(client_link)


## A voice frame, client to server to another client.
##
## [b]Deliberately not through [DotNetManager].[/b] dot-net decodes a bit-packed
## message against a sealed schema; a voice frame is an opaque blob from a codec and
## putting it through would mean a message type per codec — or a schema that changes
## when the codec does, and the schema hash is what both ends check to agree they are
## speaking the same game.
func _test_voice_wire() -> void:
	print("")
	print("[voice over the link]")

	var relayed: Array[Dictionary] = []
	var heard: Array[PackedByteArray] = []

	var server_link := ArenaNetLink.attached_to(self, _server_bridge, true)
	server_link.name = "VoiceServerLink"

	var client_entry: Dictionary = _clients[_clients.keys()[0]]
	var client_bridge: ArenaNetBridge = client_entry["bridge"]
	var client_link := ArenaNetLink.attached_to(self, client_bridge, false)
	client_link.name = "VoiceClientLink"

	client_link.loopback = func(m: StringName, peer: int, payload: PackedByteArray) -> void:
		server_link.deliver(m, 2, payload)

	server_link.loopback = func(m: StringName, peer: int, payload: PackedByteArray) -> void:
		client_link.deliver(m, peer, payload)

	_server_bridge.voice_relay_fn = func(speaker: int, bytes: PackedByteArray) -> void:
		relayed.append({"speaker": speaker, "bytes": bytes})
		# Straight back out, which is what DotVoiceRouter does after it has decided
		# who hears it. The router itself is checked on a real server in `dedicated`.
		server_link.send_voice(2, bytes)

	client_bridge.voice_in_fn = func(bytes: PackedByteArray) -> void:
		heard.append(bytes)

	var frame := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	client_link.send_voice_frame(frame)

	_check(relayed.size() == 1, "a captured frame reaches the server")

	if not relayed.is_empty():
		# [b]The speaker is stamped from the transport, never read out of the
		# payload.[/b] A client that could name its own speaker id could put words in
		# anybody's mouth, and the only symptom is words coming out of the wrong
		# player — which nobody would report as a security problem.
		_check(
			int(relayed[0]["speaker"]) == 2,
			"stamped with the peer the transport reported",
			str(relayed[0]["speaker"])
		)
		_check(
			(relayed[0]["bytes"] as PackedByteArray) == frame,
			"and the bytes are unchanged"
		)

	_check(heard.size() == 1, "and the relay reaches a listener")

	# Never a broadcast. `send(bytes, 0)` is how this family last delivered a private
	# message to every client at once, and a proximity voice packet sent to peer 0
	# would be exactly that bug with audio in it.
	var before := server_link.voice_sent
	server_link.send_voice(0, frame)
	_check(
		server_link.voice_sent == before,
		"and a voice frame addressed to peer 0 is refused rather than broadcast"
	)

	server_link.queue_free()
	client_link.queue_free()
	remove_child(server_link)
	remove_child(client_link)


func _test_disconnect() -> void:
	print("")
	print("[disconnect]")

	_server_bridge.remove_peer(3)
	_check(_server_net.registry.count() == 1, "the peer's entity is released",
		str(_server_net.registry.count()))
	_check(_server_game.player_for(12) == null, "and it leaves the game")
	_check(_server_bridge.behaviour_for(12) == null, "and the bridge forgets it")

	# The remaining player must keep working, which is the thing a removal most often
	# breaks: a stale entry in the command table would crash the next tick.
	var next := _server_game.current_tick() + 1
	_server_bridge.server_tick(next)
	_check(_server_game.current_tick() == next, "the server ticks on")


## An administrator noclips a player on the server, and the player's own client — which
## has no noclip permission of its own — has to PREDICT it.
##
## [b]The symptom this exists for is rubber-banding, and no server-side check can see
## it.[/b] Set naively — `state.mode = NOCLIP` on the server — the client's replay runs its
## own noclip gate, which is closed, drops the player to AIR on every replayed tick, and is
## pulled back by every snapshot: the player flickers between flying and falling while
## every number on the server is right. So this flies the player straight up for a second
## and compares, tick by tick, where the client predicted them against where the server
## put them — once the shipped way and once the naive way, and requires the first to agree
## and the second not to. Without the second half, "agrees" could be a window in which the
## client was never asked to disagree.
##
## [b]Not `DotNetPredictor.correction_rate`.[/b] That was the first measure written here and
## it read 0.0% for BOTH, with a worst error of 0.000 m across the whole run: it measures
## the player NODE before and after a reconcile, and in this harness nothing moves the
## node of a headless player between the two. A measure that cannot see the bug it is
## pointed at is the family's "reports its healthy case while blind", so the comparison is
## on the simulated state, which is what a player's camera follows.
func _test_forced_noclip_is_predicted() -> void:
	print("")
	print("[an admin's noclip, predicted by the client it happens to]")

	var entry: Dictionary = _clients[2]
	var session := int(entry["session"])
	var server_player: ArenaPlayer = _server_bridge.behaviour_for(session).player
	var client_player: ArenaPlayer = (entry["bridge"] as ArenaNetBridge).behaviour_for(session).player

	_check(
		not client_player.controller.tunables.can_noclip,
		"the client may not noclip on its own"
	)

	var on := DotFpsAdminModifiers.set_noclip(server_player.controller, true)
	_check(on.ok, "the server holds player %d in noclip" % session, str(on.error))

	var start_y: float = server_player.controller.state.position.y
	var shipped := _flight_window(2, 64, DotFpsCommand.BUTTON_JUMP)

	_check(
		DotFpsAdminModifiers.is_noclipped(client_player.controller)
		and client_player.controller.state.mode == DotFpsState.Mode.NOCLIP,
		"the client learned it from the snapshots and is flying too"
	)
	_check(
		server_player.controller.state.position.y > start_y + 5.0,
		"the server's player rose into the air",
		"y %.2f from %.2f" % [server_player.controller.state.position.y, start_y]
	)
	_check(
		int(shipped["grounded_ticks"]) == 0,
		"and the client never once predicted them out of noclip",
		"%d of 64 ticks" % int(shipped["grounded_ticks"])
	)
	_check(
		float(shipped["worst_gap"]) < 0.75,
		"and never predicted them more than a hand's width from the server",
		"worst %.2f m" % float(shipped["worst_gap"])
	)

	# Back to the ground, and then the version that does NOT work, for contrast.
	var _off := DotFpsAdminModifiers.set_noclip(server_player.controller, false)
	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	var _settle := _flight_window(0, 24, 0)

	server_player.controller.allow_noclip = true
	server_player.controller.tunables.can_noclip = true
	server_player.controller.state.mode = DotFpsState.Mode.NOCLIP

	var naive := _flight_window(2, 64, DotFpsCommand.BUTTON_JUMP)
	print("  measured: shipped %d ticks out of noclip, worst %.2f m; naive %d ticks, worst %.2f m" % [int(shipped["grounded_ticks"]), float(shipped["worst_gap"]), int(naive["grounded_ticks"]), float(naive["worst_gap"])])

	_check(
		int(naive["grounded_ticks"]) > 16 or float(naive["worst_gap"]) > 2.0,
		"a mode set without the modifier is one the client does not predict: the rubber band",
		"naive: %d ticks out of noclip, worst %.2f m — if this passes quietly, the checks above prove nothing"
		% [int(naive["grounded_ticks"]), float(naive["worst_gap"])]
	)

	server_player.controller.allow_noclip = false
	server_player.controller.tunables.can_noclip = false
	server_player.controller.state.mode = DotFpsState.Mode.AIR
	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	var _land := _flight_window(0, 24, 0)


## Runs [param ticks] more ticks with [param peer] holding [param buttons] and nothing else
## (0 for nobody), and reports how far that peer's prediction of itself strayed from the
## server's simulation of it: `{worst_gap, grounded_ticks}`, the second counting ticks the
## client predicted it out of noclip.
func _flight_window(peer: int, ticks: int, buttons: int) -> Dictionary:
	var first := _server_game.current_tick() + 1
	var worst := 0.0
	var grounded := 0

	# Measured only once a snapshot from inside the window has arrived. Until then the
	# client cannot know anything the server did at the top of it — the first run of this
	# measured 159 m, which was the client's copy still where an earlier section had
	# parked it — and "the client has not heard yet" is latency, not rubber-banding.
	var heard_before: int = (
		int(_clients[peer]["net"].stats.packets_received) if peer != 0 else 0
	)

	for tick in range(first, first + ticks):
		var commands := {}

		for peer_id in _clients:
			var pair := _commands_for(peer_id, tick)
			if peer_id == peer:
				var held := DotFpsCommand.new()
				held.buttons = buttons
				pair = [held, DotWeaponCommand.new()]
			commands[peer_id] = pair

			var packet: PackedByteArray = _clients[peer_id]["bridge"].encode_input(
				tick, pair[0], pair[1]
			)
			_drop_up += 1
			if _drop_up % LOSS_EVERY != 0:
				_server_bridge.receive_input(peer_id, packet)

		_server_bridge.server_tick(tick)

		for entry_down in _downstream:
			var target_peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if target_peer == 0 else [target_peer]
			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])
		_downstream.clear()

		for peer_id in _clients:
			var pair2: Array = commands[peer_id]
			_clients[peer_id]["net"].clock.tick = tick
			_clients[peer_id]["bridge"].client_tick(tick, pair2[0], pair2[1])

		if peer == 0 or int(_clients[peer]["net"].stats.packets_received) == heard_before:
			continue

		var session := int(_clients[peer]["session"])
		var predicted: ArenaPlayer = (_clients[peer]["bridge"] as ArenaNetBridge).behaviour_for(session).player
		var actual: ArenaPlayer = _server_bridge.behaviour_for(session).player
		worst = maxf(worst, predicted.controller.state.position.distance_to(
			actual.controller.state.position
		))
		if predicted.controller.state.mode != DotFpsState.Mode.NOCLIP:
			grounded += 1

	return {"worst_gap": worst, "grounded_ticks": grounded}

func _test_event_wire() -> void:
	print("")
	print("[events]")

	# Every encoder and its decoder, round-tripped. **The two ends of a serialisation
	# are exactly as capable of never meeting as the two ends of a wire** — this family
	# has shipped a stored voice mute that loaded back as a warning, and a leaderboard
	# reporter whose file format was not its wire format. Nothing checks that a pair are
	# inverses except a test that runs both.
	var hello := ArenaEvents.read_hello(DotNetReader.new(
		ArenaEvents.write_hello(128, 4242, 7, 90210, "dm_box", 25, 600.0)
	))
	_check(bool(hello["ok"]), "a HELLO round-trips")
	_check(int(hello["tick_rate"]) == 128, "with the tick rate", str(hello["tick_rate"]))
	_check(int(hello["session_id"]) == 4242, "the session id it names")
	_check(int(hello["peer_id"]) == 7, "the peer id")
	_check(int(hello["server_tick"]) == 90210, "the server's tick")
	_check(String(hello["map_name"]) == "dm_box", "and the map")
	_check(int(hello["score_limit"]) == 25, "and the rules")

	var kill := ArenaEvents.read_kill(DotNetReader.new(
		ArenaEvents.write_kill(11, 12, "rifle", true)
	))
	_check(bool(kill["ok"]), "a KILL round-trips")
	_check(
		int(kill["killer_id"]) == 11 and int(kill["victim_id"]) == 12,
		"with both players"
	)
	_check(String(kill["weapon"]) == "rifle", "the weapon")
	_check(bool(kill["headshot"]), "and the headshot flag")

	# The world kills as 0, not as a name. It is the one value with two shapes, and a
	# string on the wire for it is a string somebody eventually puts a name in.
	var world := ArenaEvents.read_kill(DotNetReader.new(
		ArenaEvents.write_kill(0, 12, "fall", false)
	))
	_check(int(world["killer_id"]) == 0, "and the world kills as 0")

	var state := ArenaEvents.read_match(DotNetReader.new(
		ArenaEvents.write_match(3, 1920, 5)
	))
	_check(bool(state["ok"]), "a MATCH round-trips")
	_check(int(state["state"]) == 3 and int(state["round"]) == 5, "with the state and round")
	_check(int(state["remaining_ticks"]) == 1920, "and the clock, in ticks")

	# Negative, because "no limit" is negative and a match past its clock reports a
	# negative remainder. A uint here would have wrapped it to four billion.
	var over := ArenaEvents.read_match(DotNetReader.new(
		ArenaEvents.write_match(3, -64, 5)
	))
	_check(int(over["remaining_ticks"]) == -64, "and a clock past zero stays negative")

	var leave := ArenaEvents.read_leave(DotNetReader.new(ArenaEvents.write_leave(99)))
	_check(bool(leave["ok"]) and int(leave["session_id"]) == 99, "a LEAVE round-trips")

	var notice := ArenaEvents.read_notice(DotNetReader.new(
		ArenaEvents.write_notice("Match point")
	))
	_check(
		bool(notice["ok"]) and String(notice["text"]) == "Match point",
		"a NOTICE round-trips"
	)

	var score := ArenaEvents.read_score(DotNetReader.new(ArenaEvents.write_score(11, 7, 3)))
	_check(
		bool(score["ok"]) and int(score["kills"]) == 7 and int(score["deaths"]) == 3,
		"a SCORE round-trips"
	)

	# A truncated body must not read as a valid event of nothing. `StreamPeerBuffer`
	# reads past its end by returning zeros rather than failing, and dot-timer shipped a
	# replay that parsed that way; `DotNetReader.ok()` is the equivalent here and it is
	# sticky, so a decoder that skipped the check gets a plausible value for the field
	# AFTER the overrun.
	var truncated := ArenaEvents.read_hello(DotNetReader.new(
		ArenaEvents.write_hello(128, 1, 1, 1, "dm_box", 25, 600.0).slice(0, 3)
	))
	_check(not bool(truncated["ok"]), "and a truncated HELLO is refused, not guessed")

	# Both message types validate their kind, so a peer that disagrees about the schema
	# is a refusal rather than an out-of-range read.
	_check(
		not ArenaEvent.new(ArenaEvents.Kind.size(), PackedByteArray()).validate().ok,
		"an unknown event kind is refused"
	)
	_check(
		ArenaEvent.new(ArenaEvents.Kind.HELLO, PackedByteArray()).validate().ok,
		"and a known one is not"
	)


func _test_ready_gate() -> void:
	print("")
	print("[the ready gate]")

	# **Nothing may be sent to a peer before it says it can receive.** dot-server's
	# signon finishes and THEN the client builds its scene, so everything sent in
	# between lands on a node that does not exist and is lost — one "Node not found"
	# per call, and a client that never learns who it is. game-hungario found this the
	# hard way and the gate is what came out of it.
	var sent: Array = []
	var bridge := ArenaNetBridge.new()
	bridge.name = "GateBridge"
	add_child(bridge)

	var game := _make_game(true)
	var net := _make_manager(true, &"gate", 1)
	_check(bridge.attach(game, net).ok, "a gate bridge attaches")
	_start(net)

	var link := bridge.open_link(bridge)
	link.loopback = func(method: StringName, peer: int, payload: PackedByteArray) -> void:
		sent.append([method, peer, payload.size()])

	bridge.send_event(77, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice("early"))
	_check(sent.is_empty(), "an event to a peer that has not said READY is dropped")

	bridge.mark_ready(77)
	var after_ready: int = sent.size()
	_check(after_ready > 0, "and marking it ready sends it the whole signon", str(after_ready))

	bridge.send_event(77, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice("late"))
	_check(sent.size() > after_ready, "and later events reach it")

	# A broadcast goes to ready peers only, which is the same rule stated the other way.
	sent.clear()
	bridge.send_event(0, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice("all"))
	_check(sent.size() == 1, "a broadcast reaches exactly the ready peers", str(sent.size()))

	bridge.queue_free()
	game.queue_free()
	net.queue_free()


func _test_predicted_node_is_not_moved() -> void:
	print("")
	print("[the predicted entity's node]")

	# `DotNetManager.receive_snapshot` calls `read_state` — and therefore
	# `_net_state_applied` — BEFORE `DotNetPredictor.reconcile`, and the first thing
	# reconcile does is read the node as "what the client is showing" so it can measure
	# the correction. Writing the server's position there first makes that measurement
	# the entire replay distance: every reconciliation logs a snap, the correction rate
	# reads near 1.0, and the simulation is right the whole time.
	#
	# game-hungario had this exact line and the family's notes have listed it as unfixed
	# here ever since. Nothing in this file could see it before: the check is not on a
	# position, it is on WHETHER THE NODE MOVED, which no assertion about the
	# simulation can reach.
	var behaviour := (_clients[2]["bridge"] as ArenaNetBridge).behaviour_for(11)

	if not _check(behaviour != null, "the local player's behaviour is found"):
		return

	var player := behaviour.player
	var predicted := behaviour.identity != null and behaviour.identity.is_predicted()

	_check(predicted, "and the local player is predicted, not server-driven")

	# Put the node somewhere the state is not, then hand the behaviour a state applied.
	var parked := Vector3(123.0, 4.0, 56.0)
	player.global_position = parked
	behaviour.net_position = Vector3(7.0, 0.0, 7.0)
	behaviour._net_state_applied((_clients[2]["net"] as DotNetManager).clock.tick)

	_check(
		player.global_position.is_equal_approx(parked),
		"applying state does NOT move a predicted player's node",
		str(player.global_position)
	)

	# The remote player is the other half, and it must move: its node is driven by
	# nothing else, so a guard that skipped it would leave every remote player standing
	# where they spawned.
	var remote := (_clients[2]["bridge"] as ArenaNetBridge).behaviour_for(12)

	if not _check(remote != null, "the remote player's behaviour is found"):
		return

	_check(
		remote.identity == null or not remote.identity.is_predicted(),
		"and the remote player is not predicted"
	)

	remote.player.global_position = parked
	remote.net_position = Vector3(3.0, 0.0, 3.0)
	remote._net_state_applied((_clients[2]["net"] as DotNetManager).clock.tick)

	_check(
		not remote.player.global_position.is_equal_approx(parked),
		"applying state DOES move a remote player's node",
		str(remote.player.global_position)
	)


func _test_config_agreement() -> void:
	print("")
	print("[the two ends agree]")

	# **A quantised value decoded against a different range is a different value, not a
	# less precise one.** `world_extent` is the range every replicated position is an
	# integer over, and the server and the client used to write it separately — 128 in
	# `ArenaModule`, 256 in `ArenaClient`, in two files a hundred lines apart.
	#
	# What that looked like, in a real browser against a real server: the client
	# connected, sealed an identical message schema, adopted its own player alive with
	# 100 health, logged every stage correctly — and drew sky in every direction with a
	# HUD reading zero. No error anywhere, because there is no error: both ends did
	# exactly what they were told.
	#
	# The fix is that there is now one constant and nothing to keep in step. This check
	# is what stops somebody typing a number into one of the two again.
	_check(
		is_equal_approx(_server_net.config.world_extent, ArenaGame.NET_WORLD_EXTENT),
		"the server quantises positions over the game's extent",
		"%.1f" % _server_net.config.world_extent
	)

	for peer_id in _clients:
		var net: DotNetManager = _clients[peer_id]["net"]

		_check(
			is_equal_approx(net.config.world_extent, _server_net.config.world_extent),
			"and client %d over the same one" % peer_id,
			"%.1f vs %.1f" % [net.config.world_extent, _server_net.config.world_extent]
		)

		# The tick rate is the other number the two ends must not disagree about, and
		# the one this family has already paid for: a client counting at its own rate
		# against a 128-tick server read a 0.218 s finish as 0.466 s and never
		# converged. HELLO carries it; `_adopt_tick_rate` is what applies it.
		_check(
			net.config.tick_rate == _server_net.config.tick_rate,
			"and counts at the same rate",
			"%d vs %d" % [net.config.tick_rate, _server_net.config.tick_rate]
		)

	# The schema hash is the third. Two peers that registered different message types,
	# or the same ones in a different order, hash differently — and `Array.sort()` on a
	# StringName sorts by interned POINTER, which every suite in this family missed by
	# running both ends in one process and sharing one intern table.
	var server_hash := _server_net.messages.schema_hash()

	for peer_id in _clients:
		var net: DotNetManager = _clients[peer_id]["net"]

		_check(
			net.messages.schema_hash() == server_hash,
			"and client %d sealed the same message schema" % peer_id,
			"%s vs %s" % [net.messages.schema_hash(), server_hash]
		)
