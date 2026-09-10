class_name ArenaNetLink
extends Node

## The four remote calls this game needs, on one node that exists on both ends.
##
## Copied from game-g2gfast's, which was copied from game-hungario's — deliberately,
## per the family rule that games copy what they need rather than sharing a helper —
## because it encodes the one thing that cost this family a day:
##
## **Godot refuses an RPC unless both ends declare the same set of `@rpc` methods**, and
## routes it by the receiver's node path relative to its `MultiplayerAPI` root. Using
## the same script on both ends makes the method-set checksum identical by
## construction; naming the node the same on both ends, and parenting it to a node that
## is itself named the same — [DotServer] on one side and [DotClientLink] on the other,
## both called `Server` — is the whole of the routing.
##
## One extra `@rpc` method on one side makes **every** RPC between them fail, not just
## that one, including the handshake, whose only symptom is a timeout.
##
## [codeblock]
## Server            <- DotServer, or DotClientLink named to match
##   Chat            <- DotChatManager / DotClientChat
##   Arena           <- this, on both
## [/codeblock]

const CHANNEL := "arena.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"Arena"

## Everything here rides [constant DotTransport.Channel.STATE], which dot-server
## reserves for exactly this and uses for nothing itself. Sharing chat's channel would
## make a burst of snapshots delay a chat line, and a chat line delay a snapshot.
const CHANNEL_STATE := 1

## Voice rides its own channel, and that is not a nicety.
##
## A talk spurt is fifty frames a second per speaker relayed to every listener. On the
## state channel it would sit in the same ordered queue as the snapshots, so somebody
## holding the talk key would add a frame of latency to everybody's movement — and a
## burst of snapshots would arrive as a gap in the audio, which is the one artefact a
## jitter buffer cannot hide.
##
## [b]UDP on a desktop and TCP in a browser, and neither is chosen here.[/b] The calls
## below are declared `unreliable`, which is what voice wants: a lost frame is 20 ms of
## silence a jitter buffer conceals, and a resent one arrives after the frames either
## side of it have already played. What that becomes on the wire is
## `DotTransportAuto`'s decision and it has exactly one sensible answer either way —
## ENet honours the unreliable channel as UDP; a browser has no UDP at all, so
## WebSocket delivers it reliably and in order over TCP whatever anybody asks for.
##
## So the platform rule falls out rather than being written: a desktop client's voice
## is unreliable UDP, a browser client's is TCP, and this file names neither. Trying to
## pick per platform here would mean a game naming a transport, which is the one thing
## `DotTransport` exists to stop.
const CHANNEL_VOICE := 2

## The bridge these calls are delivered to. Set by whoever creates this node.
var bridge: ArenaNetBridge = null

## Whether this end is the authority. Only used to refuse an obviously misrouted call
## early, with a log line naming the node rather than a silent no-op.
var is_server: bool = false

## Where calls go instead of onto the network.
##
## Signature: [code]func(method: StringName, peer_id: int, payload: PackedByteArray)[/code],
## with [param method] one of [code]snapshot[/code], [code]event[/code],
## [code]input[/code] or [code]request[/code].
##
## [b]A test seam, and the only way this netcode can be checked at all.[/b] A real
## socket does not reproduce the same latency, reordering and loss twice, so the
## integration run puts a server and a client in one process with a lossy loopback
## between them. Unset — which is every real deployment — every send goes out as an RPC.
var loopback: Callable = Callable()

## The [Dictionary]-carrying half of [member loopback].
##
## [b]A second callable rather than a wider signature on the first.[/b] `loopback`
## takes a [PackedByteArray] and four call sites hand it one; widening it to a Variant
## would make every one of those pass a byte array through a parameter that no longer
## says so, and the map messages are the only thing on this link that is not bytes.
var loopback_map: Callable = Callable()

## Counters, for `arena_net` and for the self-test.
var snapshots_sent: int = 0
var snapshots_received: int = 0
var events_sent: int = 0
var events_received: int = 0
var inputs_sent: int = 0
var inputs_received: int = 0
var requests_sent: int = 0
var requests_received: int = 0
var voice_sent: int = 0
var voice_received: int = 0
var map_sent: int = 0
var map_received: int = 0


static func attached_to(
	parent: Node, p_bridge: ArenaNetBridge, server: bool
) -> ArenaNetLink:
	var link := ArenaNetLink.new()
	link.name = NODE_NAME
	link.bridge = p_bridge
	link.is_server = server
	parent.add_child(link)
	return link


func _live() -> bool:
	if loopback.is_valid():
		return true

	return is_inside_tree() \
		and multiplayer != null \
		and multiplayer.has_multiplayer_peer()


# --- Sending ---------------------------------------------------------------

## A state snapshot. Server to one client, or to all of them when [param peer_id] is 0.
func send_snapshot(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	snapshots_sent += 1

	if loopback.is_valid():
		loopback.call(&"snapshot", peer_id, payload)
	elif peer_id == 0:
		_net_snapshot.rpc(payload)
	else:
		_net_snapshot.rpc_id(peer_id, payload)


func send_event(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	events_sent += 1

	if loopback.is_valid():
		loopback.call(&"event", peer_id, payload)
	elif peer_id == 0:
		_net_event.rpc(payload)
	else:
		_net_event.rpc_id(peer_id, payload)


func send_input(payload: PackedByteArray) -> void:
	if not _live():
		return

	inputs_sent += 1

	if loopback.is_valid():
		loopback.call(&"input", 1, payload)
	else:
		_net_client_input.rpc_id(1, payload)


func send_request(payload: PackedByteArray) -> void:
	if not _live():
		return

	requests_sent += 1

	if loopback.is_valid():
		loopback.call(&"request", 1, payload)
	else:
		_net_request.rpc_id(1, payload)


## One encoded voice frame, server to one listener.
##
## [b]Never a broadcast, and the loop over listeners is deliberately not here.[/b]
## [DotVoiceRouter] decides who hears a speaker — everybody, a team, or whoever is
## within range — and a `send(bytes, 0)` convention here would quietly deliver a
## proximity packet to the whole server. This family has shipped that exact bug once
## already, through a bot registered as peer 0.
func send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if not _live() or peer_id <= 0:
		return

	voice_sent += 1

	if loopback.is_valid():
		loopback.call(&"voice", peer_id, payload)
	else:
		_net_voice.rpc_id(peer_id, payload)



## One captured voice frame, client to server.
func send_voice_frame(payload: PackedByteArray) -> void:
	if not _live():
		return

	voice_sent += 1

	if loopback.is_valid():
		loopback.call(&"voice_frame", 1, payload)
	else:
		_net_voice_frame.rpc_id(1, payload)


## One dot-map protocol message, server to one peer.
##
## [b]A [Dictionary] rather than bytes, and it is the one thing on this link that is
## not bit-packed.[/b] dot-map's messages are five kinds of announcement that happen a
## few times an hour — a bit-packed wire for them would be a second schema to keep in
## step with dot-map's own, for a saving of about forty bytes per map change. The
## bit-packing exists for the snapshot, which is thirty-two of them a second.
func send_map(peer_id: int, payload: Dictionary) -> void:
	if not _live() or peer_id <= 0:
		return

	map_sent += 1

	# [b]`loopback_map`, not `loopback` — and tested separately.[/b] A harness that set
	# the byte loopback and not this one would otherwise call an invalid Callable, which
	# is a crash in a test that was only trying not to open a socket. Falling through to
	# the RPC is wrong too when there is no multiplayer peer, so the send is simply
	# dropped and counted, which is what a lost packet looks like anyway.
	if loopback.is_valid():
		if loopback_map.is_valid():
			loopback_map.call(&"map", peer_id, payload)
	else:
		_net_map.rpc_id(peer_id, payload)


## A client's answer: how far through the download it is, or that it is ready.
func send_map_report(payload: Dictionary) -> void:
	if not _live():
		return

	map_sent += 1

	if loopback.is_valid():
		if loopback_map.is_valid():
			loopback_map.call(&"map_report", 1, payload)
	else:
		_net_map_report.rpc_id(1, payload)


# --- Receiving -------------------------------------------------------------

## State from the authority. Unreliable: a newer snapshot supersedes a lost one, and
## re-sending a hundred-millisecond-old position is worse than useless.
@rpc("authority", "unreliable", "call_remote", CHANNEL_STATE)
func _net_snapshot(payload: PackedByteArray) -> void:
	snapshots_received += 1

	if bridge != null:
		bridge.receive_snapshot(payload)


## Anything from the authority that must arrive: HELLO, joins, kills, the match state.
@rpc("authority", "reliable", "call_remote", CHANNEL_STATE)
func _net_event(payload: PackedByteArray) -> void:
	events_received += 1

	if bridge != null:
		bridge.receive_event(payload)


## A client's intent. Unreliable, and deliberately not resent: the next tick's packet
## carries a newer command anyway, and a retransmit would arrive after its tick passed.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_STATE)
func _net_client_input(payload: PackedByteArray) -> void:
	inputs_received += 1

	if bridge != null:
		# The sender comes from the transport, never from inside the payload. A peer
		# id in a body is a claim; this is a fact.
		bridge.receive_input(multiplayer.get_remote_sender_id(), payload)


## A client asking for something. Reliable and rare.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_STATE)
func _net_request(payload: PackedByteArray) -> void:
	requests_received += 1

	if bridge != null:
		bridge.receive_request(multiplayer.get_remote_sender_id(), payload)


## A relayed voice frame. Unreliable: a lost frame is 20 ms of silence a jitter buffer
## conceals, and a resent one arrives after the frames either side of it have played.
@rpc("authority", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice(payload: PackedByteArray) -> void:
	voice_received += 1

	if bridge != null:
		bridge.receive_voice(payload)


## A client's captured audio. The speaker is stamped by the server from the transport's
## sender, never read out of the payload — a client that could name its own speaker id
## could put words in anybody's mouth, and the only symptom is exactly that.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice_frame(payload: PackedByteArray) -> void:
	voice_received += 1

	if bridge != null:
		bridge.receive_voice_frame(multiplayer.get_remote_sender_id(), payload)


## A map-change announcement from the server.
@rpc("authority", "reliable", "call_remote", CHANNEL_STATE)
func _net_map(payload: Dictionary) -> void:
	map_received += 1

	if bridge != null:
		bridge.receive_map(payload)


## A client's progress or readiness. The peer comes from the transport.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_STATE)
func _net_map_report(payload: Dictionary) -> void:
	map_received += 1

	if bridge != null:
		bridge.receive_map_report(multiplayer.get_remote_sender_id(), payload)


## Hands a [Dictionary] payload to this end as though it had arrived over the wire.
func deliver_map(method: StringName, from_peer_id: int, payload: Dictionary) -> void:
	if bridge == null:
		return

	map_received += 1

	if method == &"map":
		bridge.receive_map(payload)
	else:
		bridge.receive_map_report(from_peer_id, payload)


## Hands a payload to this end as though it had arrived over the wire.
##
## What the other end's [member loopback] calls. It goes through the same counters and
## the same bridge entry points the RPCs do, so a test exercises the real path minus
## the socket.
func deliver(method: StringName, from_peer_id: int, payload: PackedByteArray) -> void:
	if bridge == null:
		return

	match method:
		&"snapshot":
			snapshots_received += 1
			bridge.receive_snapshot(payload)
		&"event":
			events_received += 1
			bridge.receive_event(payload)
		&"input":
			inputs_received += 1
			bridge.receive_input(from_peer_id, payload)
		&"request":
			requests_received += 1
			bridge.receive_request(from_peer_id, payload)
		&"voice":
			voice_received += 1
			bridge.receive_voice(payload)
		&"voice_frame":
			voice_received += 1
			bridge.receive_voice_frame(from_peer_id, payload)


func describe() -> Dictionary:
	return {
		"server": is_server,
		"snapshots": [snapshots_sent, snapshots_received],
		"events": [events_sent, events_received],
		"inputs": [inputs_sent, inputs_received],
		"requests": [requests_sent, requests_received],
		"voice": [voice_sent, voice_received],
		"map": [map_sent, map_received],
	}
