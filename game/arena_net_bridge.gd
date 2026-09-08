class_name ArenaNetBridge
extends Node

## Joins [ArenaGame] to a [DotNetManager]. The netcode seam, and the only file in
## game-arena that names both.
##
## [b]Every other join in this project is a few lines because the addons refuse to
## know about each other; this one is a file because the ordering is the hard part.[/b]
## dot-net drives simulation per entity, and this game's tick order is a whole-game
## property — everybody moves, then every shot is resolved against the world as it is
## afterwards, then the match clock runs. Those two facts have to be reconciled
## somewhere, and this is where.
##
## [codeblock]
## # server
## bridge.attach(game, net)
## bridge.add_player(peer_id, session_id, "Ada")
## bridge.server_tick(tick)                      # instead of game.tick()
##
## # client
## bridge.attach(game, net)
## bridge.apply_join(join_bytes)                 # from the server
## socket.send(bridge.encode_input(tick, move, fire))
## bridge.receive_snapshot(payload)
## bridge.client_tick(tick, move, fire)
## [/codeblock]

const CHANNEL := "arena.net"

## Bytes [method DotNetManager.encode_ack] produces, and the prefix of every input
## packet. Fixed width, so the command that follows starts at a known offset.
const ACK_BYTES := 4

## Announced a player. Server side: these bytes go to every client.
signal player_announced(payload: PackedByteArray)

var game: ArenaGame = null
var net: DotNetManager = null

## player id -> ArenaPlayerNet, for the ones this process knows about.
var _behaviours: Dictionary = {}

## peer id -> player id.
var _players_by_peer: Dictionary = {}

var _game_ticked_for: int = -1
var _tick: int = 0

## The RPC surface, on both ends. Created by [method attach].
var link: ArenaNetLink = null

## How the client learns its round-trip time, in milliseconds.
##
## [b]Nothing in dot-net writes an RTT sample, and it needs one.[/b]
## `DotNetStats` has a median and a mean-absolute-deviation behind it, and
## `receive_snapshot` reads `rtt_percentile(0.5)` on every snapshot to feed the clock —
## while no caller anywhere in dot-net writes a sample, because dot-net never touches a
## transport. The host has to feed it and nothing said so. A client points this at
## `DotClientLink.ping_ms`.
##
## What it costs when it is unset: the clock's input lead has to include the flight
## time, because a command stamped for tick N must be in the server's hands BEFORE it
## simulates N. With no samples the lead is a guess, and on any link past about 30 ms
## every input arrives after its tick has passed and is discarded as late — the player
## moves perfectly on their own screen and nowhere else.
var rtt_source: Callable = Callable()

## Peers that have said they can receive. Server side.
##
## [b]Nothing may be sent to a peer before it says READY.[/b] dot-server's signon
## finishes and *then* the client builds its scene, so everything sent in between lands
## on a node that does not exist and is lost — one "Node not found" per call, and a
## client that never learns who it is.
var _ready_peers: Dictionary = {}

## Whether this end has had its HELLO. Client side.
var _hello: Dictionary = {}



## Emitted on a client when HELLO arrives, with what it said.
signal hello_received(info: Dictionary)

## Emitted on a client for anything the server wants shown as text.
signal notice_received(text: String)

## Emitted on a client when the server reports a kill.
signal kill_received(info: Dictionary)

## Emitted on a client when the match state or clock changes.
signal match_received(info: Dictionary)


## Binds a game and a manager to each other.
func attach(p_game: ArenaGame, p_net: DotNetManager) -> DotResult:
	if p_game == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs both halves.")

	if p_game.is_authority != p_net.is_server:
		# A game that thinks it is authoritative behind a client manager would
		# resolve its own hits; a server whose game is not authoritative would
		# resolve nobody's. Both are silent, and both are unplayable.
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game.is_authority=%s, net.is_server=%s"
				% [p_game.is_authority, p_net.is_server]
		)

	game = p_game
	net = p_net

	net.send_fn = _send

	# Registered on BOTH ends, in the same order, because `DotNetMessageRegistry.seal`
	# assigns wire ids from a sort of the type names and hashes the resulting schema.
	# A type registered on one end only is two different ids and two different schema
	# hashes, and the peers disagree on the first connection. That is not theoretical:
	# `Array.sort()` on a StringName sorts by interned pointer, which every suite in
	# this family missed by running both ends in one process and sharing one intern
	# table, and a browser client — a genuinely separate program — found immediately.
	var event := net.messages.register(
		ArenaEvent.NAME,
		ArenaEvent,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		ArenaRequest.NAME,
		ArenaRequest,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(ArenaEvent.NAME, _on_event)
	net.messages.on(ArenaRequest.NAME, _on_request)

	if net.is_server:
		game.player_killed.connect(_on_player_killed)
		game.match_state_changed.connect(_on_match_state_changed)

	return DotResult.success(self)


## Creates the RPC surface under [param parent].
##
## Separate from [method attach] because the parent differs by end and by deployment:
## on a server it is the [DotServer] node, on a client the [DotClientLink], and in the
## headless suite it is a bare [Node] with a loopback in place of a socket. All three
## must be NAMED the same, because the name is the routing.
func open_link(parent: Node) -> ArenaNetLink:
	link = ArenaNetLink.attached_to(parent, self, net != null and net.is_server)
	return link


## Where dot-net's own outgoing bytes go.
##
## [param delivery] decides the call, not the caller: a snapshot is unreliable and an
## event is not, and dot-net knows which is which.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	else:
		link.send_event(peer_id, payload)


# --- Membership ------------------------------------------------------------

## Adds a player and makes them a replicated entity. Server side.
##
## [param session_id] is the id everything downstream uses — the scoreboard key, the
## combat entity id, the damage attribution and the loadout key. [b]It is not the peer
## id.[/b] A peer id is reassigned the moment someone reconnects, and everything keyed
## by one would be handed to the next player to join.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var added := game.add_player(session_id, display_name)

	if not added.ok:
		return added

	# Before registering, not after: the manager only builds snapshots for peers it
	# knows about and only holds an input buffer for those, so an entity registered
	# to an unknown peer is an entity nothing is ever sent about and nothing can be
	# driven by. It is silent — the server simulates it perfectly and alone.
	net.add_peer(peer_id)

	var identity := _build_identity(added.value as ArenaPlayer, peer_id)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		net.remove_peer(peer_id)
		game.remove_player(session_id)
		return registered

	_players_by_peer[peer_id] = session_id
	player_announced.emit(join_payload(session_id))

	return DotResult.success(identity)


## Mirrors a player the server has announced. Client side.
func mirror_player(
	net_id: int,
	peer_id: int,
	session_id: int,
	display_name: String
) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client mirrors.")

	if _behaviours.has(session_id):
		return DotResult.success(_behaviours[session_id])

	var added := game.add_player(session_id, display_name)

	if not added.ok:
		return added

	var identity := _build_identity(added.value as ArenaPlayer, peer_id)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		game.remove_player(session_id)
		return registered

	_players_by_peer[peer_id] = session_id
	return DotResult.success(identity)


## Builds the identity and behaviour that make an [ArenaPlayer] replicate.
##
## The behaviour is added before the identity on purpose: [DotNetIdentity] collects
## its behaviours in [code]_ready[/code], by walking the entity's subtree, and a
## behaviour added afterwards would never be found — the entity would register with
## nothing to replicate and simply never move on any other machine.
func _build_identity(player: ArenaPlayer, peer_id: int) -> DotNetIdentity:
	var behaviour := ArenaPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED, not SERVER: the server stays authoritative and corrects, and the owning
	# client predicts. `DotNetIdentity.is_predicted()` is false for any other
	# authority, so SERVER would mean a client that sees its own movement a full
	# round trip late — noticeable at 80 ms and unplayable at 150.
	identity.authority = DotNetIdentity.Authority.SHARED
	player.add_child(identity)

	_behaviours[player.player_id] = behaviour
	return identity


## Drops a peer's player from the game and from replication.
func remove_peer(peer_id: int) -> void:
	if not _players_by_peer.has(peer_id):
		return

	var session_id := int(_players_by_peer[peer_id])
	_players_by_peer.erase(peer_id)
	_behaviours.erase(session_id)
	_ready_peers.erase(peer_id)

	# Announced BEFORE the entity is unregistered, and to everybody still here.
	# A client that is only told an entity stopped arriving in snapshots has no way to
	# tell that from a player who walked out of its interest rectangle, so it would
	# leave a body standing in the arena for ever.
	if net != null and net.is_server:
		send_event(0, ArenaEvents.Kind.LEAVE, ArenaEvents.write_leave(session_id))

	if net != null:
		if net.is_server:
			# Releases the peer's entities, its input buffer and its acknowledgement
			# record in one place, so nothing is left keyed by a peer id that the
			# next player to connect will be given.
			net.remove_peer(peer_id)
		else:
			for identity in net.registry.take_owned_by(peer_id):
				net.registry.unregister(identity.net_id)

	game.remove_player(session_id)


func behaviour_for(session_id: int) -> ArenaPlayerNet:
	return _behaviours.get(session_id)


func session_for_peer(peer_id: int) -> int:
	return int(_players_by_peer.get(peer_id, 0))


# --- The tick --------------------------------------------------------------

## One authoritative tick. Server side, and it replaces [method ArenaGame.tick].
##
## [method DotNetManager.server_tick] hands each peer's input to the entities it owns,
## simulates, records history for lag compensation and sends snapshots — in that
## order, and the game tick has to happen between the first two. It does, from
## [method ArenaPlayerNet._net_simulate], through [method ensure_game_ticked].
##
## The call afterwards is not redundant. A server with no players registered runs no
## behaviours at all, and the match clock still has to advance — otherwise an empty
## server's warmup never ends and the first player to join arrives into a match that
## has been frozen since it booted.
func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1

	if net != null:
		net.server_tick(tick)

	ensure_game_ticked(tick)


## Runs the whole game for a tick, at most once.
##
## Called from every replicated player's [code]_net_simulate[/code]; the first one
## through does the work.
func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick
	game.tick(_commands())


## The command table [method ArenaGame.tick] takes, built from what each peer sent.
func _commands() -> Dictionary:
	var out: Dictionary = {}

	for session_id in _behaviours:
		var behaviour: ArenaPlayerNet = _behaviours[session_id]
		out[int(session_id)] = [behaviour.last_move, behaviour.last_fire]

	return out


## One client tick: record the local command, predict, reconcile.
##
## The command is recorded into the behaviour and into the manager's input history
## before predicting, because reconciliation replays that history — an input the
## buffer never saw is a tick the replay cannot reproduce, and the correction is then
## measured against a state the server never computed.
func client_tick(tick: int, move: DotFpsCommand, fire: DotCombatCommand) -> void:
	_tick = tick

	if net == null or net.is_server:
		return

	var command := ArenaNetCommand.new()
	command.tick = tick
	command.delta = net.clock.tick_duration()
	command.move = move
	command.fire = fire

	net.local_inputs().push(command)

	for identity in net.registry.predicted():
		for behaviour in identity.behaviours:
			if behaviour.has_method("_net_apply_input"):
				behaviour.call("_net_apply_input", command, tick)
			behaviour._net_simulate(tick, net.clock.tick_duration())


## Applies a snapshot. Client side.
##
## [b]Reconciliation is [DotNetManager]'s, not this file's.[/b]
## [method DotNetManager.receive_snapshot] already routes a predicted entity's state to
## [method DotNetPredictor.reconcile] rather than applying it — applying it directly would
## undo everything predicted since — and acknowledges the inputs that state covers.
##
## This used to do a second pass on top of that, reconciling against
## [method DotNetBehaviour.snapshot_values] which by then held values that had [i]already[/i]
## been rewound and replayed. The inputs were therefore replayed twice, and one correction
## became two. Nothing failed: the client still converged, because the second replay
## started from the first one's answer.
##
## What it cost was visible only in the number that exists to measure it.
## [method DotNetPredictor.correction_rate] read [b]0.500[/b] with the extra pass and
## [b]0.032[/b] without — and a correction rate near a half is precisely the reading that
## class documents as "the two simulations disagree, and no smoothing will fix that". It
## was found in dot-2d-hungry, whose bridge was written from this one and inherited it.
func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	# The one place an RTT sample is written. `DotNetStats` has a median and a
	# mean-absolute-deviation behind it and `receive_snapshot` reads
	# `rtt_percentile(0.5)` on every snapshot to feed the clock — and no caller
	# anywhere in dot-net writes a sample, because dot-net never touches a transport.
	# Without this the clock's input lead omits the flight time and, past about 30 ms
	# of latency, every command arrives after its tick and is discarded as late.
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


# --- The client-to-server channel ------------------------------------------

## An input packet, with the snapshot acknowledgement in front of it.
##
## [b]dot-net does not send either of these for you.[/b] It owns no client-to-server
## channel — inventing one would need a second socket or make every payload ambiguous
## with a message — so the four bytes of acknowledgement ride inside the input packet
## a host already sends every tick. Wiring it is what makes a property lost to a
## dropped packet get re-sent instead of sitting at a stale value until it happens to
## change again; a game that skips it still works, and a player's health is then
## whatever the last packet that arrived said.
##
## The acknowledgement goes first because it is fixed width. A bit-packed command is
## not, so a reader that had to skip it would need to decode it to know where it ends.
func encode_input(tick: int, move: DotFpsCommand, fire: DotCombatCommand) -> PackedByteArray:
	var command := ArenaNetCommand.new()
	command.tick = tick
	command.delta = net.clock.tick_duration()
	command.move = move
	command.fire = fire

	var writer := DotNetWriter.new()
	command.write(writer)

	var out := net.encode_ack()
	out.append_array(writer.to_bytes())
	return out


## Takes one of those packets. Server side.
##
## The acknowledgement is applied even when the command is refused: they are
## independent claims, and a duplicate or late input says nothing about which
## snapshots arrived.
func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	var command := ArenaNetCommand.new()
	command.read(DotNetReader.new(payload.slice(ACK_BYTES)))

	return net.input_buffer_for(peer_id).push(command)


# --- Joins -----------------------------------------------------------------

## Everything a client needs to mirror one player.
##
## A message rather than a spawn: [DotNetSpawner] builds entities from a prefab table,
## and an [ArenaPlayer] is built by [method ArenaGame.add_player] so that the netted
## and the headless deployments get the same player rather than two that drift.
func join_payload(session_id: int) -> PackedByteArray:
	var behaviour: ArenaPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null:
		return PackedByteArray()

	var writer := DotNetWriter.new()
	writer.write_varint(behaviour.identity.net_id)
	writer.write_varint(behaviour.identity.owner_peer_id)
	writer.write_varint(session_id)
	writer.write_string(behaviour.player.display_name, 64)
	return writer.to_bytes()


## Mirrors whatever a [method join_payload] described. Client side.
func apply_join(payload: PackedByteArray) -> DotResult:
	var reader := DotNetReader.new(payload)
	var net_id := reader.read_varint()
	var peer_id := reader.read_varint()
	var session_id := reader.read_varint()
	var display_name := reader.read_string(64)

	if not reader.ok():
		return DotResult.fail(DotError.CODE_PARSE, "Truncated join.")

	return mirror_player(net_id, peer_id, session_id, display_name)


# --- Events and requests ---------------------------------------------------
#
# Everything the server tells a client that is not a snapshot, and everything a client
# asks for. Both ride one message type with a kind inside it — see [ArenaEvent] — so
# adding one is not a wire-id change on two separately-built programs.


## Sends an event to one peer, or to every ready peer when [param peer_id] is 0.
##
## [b]Ready peers, not connected ones.[/b] A peer that has finished dot-server's signon
## has a socket and has not yet built its scene; an RPC to it lands on a node that does
## not exist and is lost with one "Node not found" per call. The gate is [enum
## ArenaEvents.Ask].READY.
func send_event(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or link == null:
		return

	var message := ArenaEvent.of(kind, body)
	var writer := DotNetWriter.new()
	var wrote := net.messages.encode(message, writer)

	if not wrote.ok:
		DotLog.warn(CHANNEL, "could not encode an event", {
			"kind": ArenaEvents.kind_name(kind), "error": str(wrote.error)
		})
		return

	var payload := writer.to_bytes()

	if peer_id != 0:
		if _ready_peers.has(peer_id):
			link.send_event(peer_id, payload)
		return

	for ready_peer in _ready_peers:
		link.send_event(int(ready_peer), payload)


## Sends a request to the server. Client side.
func send_request(kind: int, body: PackedByteArray = PackedByteArray()) -> void:
	if net == null or net.is_server or link == null:
		return

	var writer := DotNetWriter.new()
	var wrote := net.messages.encode(ArenaRequest.of(kind, body), writer)

	if not wrote.ok:
		return

	link.send_request(writer.to_bytes())


## Everything a joining peer has to be told, in the order it has to be told it.
##
## HELLO first, because it carries the tick rate and the client's own id and nothing
## else can be interpreted without them; then one JOIN per player already in the match,
## including the joining peer's own; then the match state.
func send_signon(peer_id: int) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_for_peer(peer_id)

	send_event(peer_id, ArenaEvents.Kind.HELLO, ArenaEvents.write_hello(
		net.config.tick_rate,
		session_id,
		peer_id,
		net.clock.tick,
		game.map.display_name if game.map != null else "",
		game.score_limit,
		game.time_limit_sec
	))

	# Every player already here, this peer's own included. A client that was only told
	# about players who joined AFTER it would see an empty arena on a busy server, and
	# nothing would ever correct it.
	for existing in _behaviours.keys():
		send_event(
			peer_id, ArenaEvents.Kind.JOIN, join_payload(int(existing))
		)

	_send_match_state(peer_id)


## Tells every ready peer where the match is. Server side.
func announce_match_state() -> void:
	_send_match_state(0)


func _send_match_state(peer_id: int) -> void:
	if game == null or game.match_node == null:
		return

	# Ticks, not seconds, because seconds are what the two ends would disagree about:
	# `seconds_remaining` is derived from the tick rate, and the client's rate is
	# whatever HELLO told it. Sending the count and letting each end divide by the rate
	# it is running keeps one number on the wire and one conversion on each side.
	send_event(peer_id, ArenaEvents.Kind.MATCH, ArenaEvents.write_match(
		int(game.match_node.state),
		int(round(game.match_node.seconds_remaining() * float(net.config.tick_rate))),
		game.match_node.round_number
	))


func _on_match_state_changed(_from: int, _to: int) -> void:
	_send_match_state(0)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	# The killer key is a string here and 0-means-the-world on the wire. dot-match
	# reads an empty killer key as "the world"; this game never writes "0" for it,
	# because that would create a scoreboard record for a player who does not exist.
	var killer := int(entry.killer_key) if String(entry.killer_key).is_valid_int() else 0

	send_event(0, ArenaEvents.Kind.KILL, ArenaEvents.write_kill(
		killer,
		int(entry.victim_key) if String(entry.victim_key).is_valid_int() else 0,
		String(entry.cause),
		entry.headshot
	))


## An event arrived. Client side.
##
## Through `DotNetManager.receive` rather than straight to the registry: that is where
## the payload cap, the per-peer rate limit and the direction check live, and a bridge
## that decoded for itself would be a second entry point with none of them.
func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


## A request arrived. Server side.
func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


func _on_event(message: DotNetMessage) -> void:
	var event := message as ArenaEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		ArenaEvents.Kind.HELLO:
			var info := ArenaEvents.read_hello(reader)
			if not bool(info["ok"]):
				return
			_hello = info
			_adopt_tick_rate(int(info["tick_rate"]))
			hello_received.emit(info)
		ArenaEvents.Kind.JOIN:
			apply_join(event.body)
		ArenaEvents.Kind.LEAVE:
			var left := ArenaEvents.read_leave(reader)
			if bool(left["ok"]):
				_drop_session(int(left["session_id"]))
		ArenaEvents.Kind.KILL:
			var kill := ArenaEvents.read_kill(reader)
			if bool(kill["ok"]):
				kill_received.emit(kill)
		ArenaEvents.Kind.MATCH:
			var state := ArenaEvents.read_match(reader)
			if bool(state["ok"]):
				match_received.emit(state)
		ArenaEvents.Kind.NOTICE:
			var notice := ArenaEvents.read_notice(reader)
			if bool(notice["ok"]):
				notice_received.emit(String(notice["text"]))
		_:
			pass


func _on_request(message: DotNetMessage) -> void:
	var request := message as ArenaRequest

	if request == null or net == null or not net.is_server:
		return

	# The sender the TRANSPORT reported, carried onto the message by
	# `DotNetManager.receive`. Never a peer id out of the body: that would be a claim.
	var peer_id := request.sender_peer_id

	if peer_id <= 0:
		return

	match request.kind:
		ArenaEvents.Ask.READY:
			mark_ready(peer_id)
		ArenaEvents.Ask.RESPAWN:
			# Asked for, never taken. dot-match owns respawning and has its own
			# timer; a client that could respawn itself could respawn instantly.
			pass
		_:
			pass


## A peer has built its scene and may be sent things.
func mark_ready(peer_id: int) -> void:
	if net == null or not net.is_server or _ready_peers.has(peer_id):
		return

	_ready_peers[peer_id] = true
	send_signon(peer_id)

	DotLog.info(CHANNEL, "a peer is ready", {"peer": peer_id})


## The client's own tick rate comes from the SERVER, and from nowhere else.
##
## [b]This is the largest measured error in this family's history.[/b] g2gfast's client
## took its rate from `Engine.physics_ticks_per_second`, which a browser shell never
## sets — 60 against a 128-tick server. Correction rate 0.96, prediction never
## converging, and every replicated time wrong by the ratio of the two rates. HELLO has
## always carried the number; nothing read it back out.
##
## All four copies move together, and the engine's is one of them: the fraction a
## renderer interpolates at is a fraction through a PHYSICS frame, which is a fraction
## through a tick only while the two rates agree.
func _adopt_tick_rate(rate: int) -> void:
	if rate <= 0 or game == null or net == null:
		return

	game.tick_rate = rate
	net.config.tick_rate = rate
	# A copy taken at setup() that writing the config does not touch.
	net.clock.tick_rate = rate
	Engine.physics_ticks_per_second = rate


## Forgets a player a LEAVE named. Client side.
func _drop_session(session_id: int) -> void:
	var behaviour: ArenaPlayerNet = _behaviours.get(session_id)

	if behaviour == null:
		return

	if net != null and behaviour.identity != null:
		net.registry.unregister(behaviour.identity.net_id)

	_behaviours.erase(session_id)

	for peer_id in _players_by_peer.keys():
		if int(_players_by_peer[peer_id]) == session_id:
			_players_by_peer.erase(peer_id)

	game.remove_player(session_id)


func describe() -> Dictionary:
	return {
		"players": _behaviours.size(),
		"peers": _players_by_peer.size(),
		"tick": _tick,
		"ticked_for": _game_ticked_for,
	}
