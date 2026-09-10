class_name ArenaServices
extends Node

## Chat, voice and moderation on a dedicated arena server.
##
## [b]This is the second file in the project that names dot-server, and the first
## version of this work tried very hard for it to be the first.[/b] [ArenaModule] is
## the bridge between a game and a server; this is the bridge between a server and
## three addons that are not about the game at all — who may speak, who may be heard,
## and who is allowed in. Folding it into the module made a five-hundred-line file
## whose two halves shared nothing, so it is its own node and the rule is now "two
## files name dot-server, and here is what each is for".
##
## [codeblock]
## dot-chat        the policy: channels, audiences, sanitisation, rate limits,
##                 command prefixes. NOT the transport.
## dot-server      the transport: it already has a chat RPC on both ends.
## dot-voice       the whole path, because dot-server has no voice at all.
## dot-moderation  who is banned, gagged or muted, durably.
## [/codeblock]
##
## [b]dot-chat and dot-server's own chat are not two chat systems here.[/b] They would
## be if both delivered lines, so exactly one does: the `player_chat` event is hooked
## and [b]cancelled[/b], the text goes to [DotChatRouter] instead, and the router's
## `send_fn` hands each recipient's line back to dot-server's manager to put on the
## wire. What that buys is everything dot-server's chat does not have — a radius
## channel, a whisper, markup and invisible-character stripping, per-channel history, a
## backlog for a joining player, and `!` commands the game can claim.
##
## [b]dot-moderation exists because dot-server's mute is two booleans on a session
## object, and a session dies with its connection.[/b] A muted player reconnects and
## talks. Every punishment issued here is a durable record with an expiry and a scope,
## and the two registry services it publishes — `dot_mute_source` and `dot_ban_source`
## — are consulted by dot-chat's router, dot-voice's router and dot-server's admission
## check without any of the four importing another.

const CHANNEL := "arena.services"

## Channel ids. StringNames, so a typo is an identifier rather than a string that
## silently never matches.
const CH_ALL := &"all"
const CH_TEAM := &"team"
const CH_NEAR := &"near"
const CH_WHISPER := &"whisper"

## A player said something the router accepted.
signal said(peer: int, message: DotChatMessage)

## A player typed a `!command`. The module claims the ones it knows.
signal command_entered(peer: int, command: String, args: PackedStringArray)

@export_group("Moderation")

## Where punishments live. Empty keeps them in memory, which loses them on restart.
@export_file("*.json") var punishments_file: String = ""

## What this server's punishments apply to. Empty means every server that shares the
## store, which is what a single-community deployment wants.
##
## [b]The unconfigured case is the one that has to work.[/b] dot-moderation shipped
## with a server that had no scope seeing no scoped punishments — so the only case a
## one-server community ever has was the case that silently enforced nothing.
@export var server_scope: String = ""

@export_group("Voice")

## Whether voice is relayed at all.
@export var voice_enabled: bool = true

## Metres a proximity packet carries.
@export_range(0.0, 500.0, 1.0) var voice_range: float = 40.0

var server: DotServer = null
var game: ArenaGame = null
var link: ArenaNetLink = null

var chat: DotChatRouter = null
var voice: DotVoiceRouter = null
var moderation: DotModerationManager = null

var _started: bool = false


## Builds all three. Call from the module's load, after the game is found.
func setup(p_server: DotServer, p_game: ArenaGame, p_link: ArenaNetLink) -> DotResult:
	if _started:
		return DotResult.fail(DotError.CODE_STATE, "Already set up.")

	if p_server == null or p_game == null:
		return DotResult.fail(
			DotError.CODE_STATE, "Services need a server and a game."
		)

	server = p_server
	game = p_game
	link = p_link

	# Moderation FIRST, and the order is load-bearing. It publishes `dot_mute_source`
	# on `_ready`, and both routers below look that name up when they start — a chat
	# router that started first would find nothing, warn once, and then enforce no gag
	# for the life of the server.
	var moderated: DotResult = await _build_moderation()

	if not moderated.ok:
		return moderated

	var chatted := _build_chat()

	if not chatted.ok:
		return chatted

	if voice_enabled:
		var voiced := _build_voice()

		if not voiced.ok:
			return voiced

	_started = true
	return DotResult.success(self)


# --- Moderation ------------------------------------------------------------

func _build_moderation() -> DotResult:
	moderation = DotModerationManager.new()
	moderation.name = "Moderation"
	moderation.server_scope = server_scope
	moderation.register_mute_source = true
	moderation.register_ban_source = true

	if punishments_file != "":
		var file_store := DotPunishmentStoreFile.new()
		file_store.path = punishments_file
		moderation.store = file_store

	# How a peer maps to a person. dot-moderation's documented seam, and it has to be
	# set here because only the host knows: a peer id is reassigned the moment somebody
	# reconnects, and a ban keyed on one would be served to the next player to join.
	moderation.key_for_peer = func(peer: int) -> String:
		var session := server.session_of(peer)

		if session == null:
			return ""

		return DotPunishmentSubject.for_uid(str(session.userid))

	add_child(moderation)

	# Awaited and assigned to a typed variable, which is the pattern this family's
	# notes insist on: a punishment store may be a shared database behind a
	# community's four servers, and an un-awaited coroutine returns at its first
	# suspension — so the branch below would be reading a Signal.
	var loaded: DotResult = await moderation.load_all()

	if not loaded.ok:
		# Not fatal, and loudly not silent. A server whose punishment store could not
		# be read is a server enforcing nothing, and the operator has to know that
		# rather than find out when a banned player walks back in.
		DotLog.warn(CHANNEL, "the punishment store could not be read", {
			"why": loaded.error.message
		})

	return DotResult.success(moderation)


# --- Chat ------------------------------------------------------------------

func _build_chat() -> DotResult:
	chat = DotChatRouter.new()
	chat.name = "Chat"
	chat.rules = _chat_rules()
	# The defaults are everyone/team/direct. This game wants a radius channel as well,
	# so the channels are installed by hand below.
	chat.install_default_channels = false
	chat.handle_me_command = true

	chat.send_fn = _send_chat
	chat.peers_fn = _playing_peers
	chat.name_fn = func(peer: int) -> String:
		var session := server.session_of(peer)
		return session.display_name if session != null else "unnamed"

	# The durable key, which is the session id and not the peer id. Everything that
	# outlives a connection — a gag, a history row, a report — is filed under this.
	chat.key_fn = func(peer: int) -> String:
		var session := server.session_of(peer)
		return str(session.userid) if session != null else ""

	chat.team_fn = func(peer: int) -> StringName:
		var player := _player_of(peer)
		return StringName(str(player.team)) if player != null else &"0"

	chat.position_fn = func(peer: int) -> Vector3:
		var player := _player_of(peer)
		return player.controller.state.position if player != null else Vector3.ZERO

	chat.is_admin_fn = func(peer: int) -> bool:
		var session := server.session_of(peer)
		return session != null and session.permissions.has(DotAdminFlags.CHAT)

	# Consulted only when no `dot_mute_source` is registered. dot-moderation registers
	# one above, so this is the fallback for a build without it — and it reads
	# dot-server's own per-session flag, which is exactly the thing that does not
	# survive a reconnect.
	chat.gag_fn = func(peer: int) -> bool:
		var session := server.session_of(peer)
		return session != null and session.gagged

	add_child(chat)

	var started := chat.start()

	if not started.ok:
		return started.wrap("The arena chat router could not start")

	for channel in _channels():
		var added := chat.add_channel(channel)

		if not added.ok:
			return added.wrap("A chat channel was refused")

	chat.message_accepted.connect(_on_message_accepted)
	chat.command_entered.connect(_on_command_entered)

	# The interception. dot-server's chat manager sanitises, rate limits and then
	# broadcasts; cancelling the event stops the broadcast and leaves everything before
	# it — which is the half that is genuinely dot-server's job, because it holds the
	# session.
	if server.events != null:
		server.events.hook_pre("player_chat", _on_player_chat)

	return DotResult.success(chat)


## The four channels this server runs.
##
## [b]A radius channel on a deathmatch server is not a novelty.[/b] It is the only one
## of the four whose audience the players can change by moving, which makes it the only
## one that is part of the game rather than beside it.
func _channels() -> Array[DotChatChannel]:
	var out: Array[DotChatChannel] = []

	var everyone := DotChatChannel.everyone()
	everyone.id = CH_ALL
	out.append(everyone)

	var team := DotChatChannel.team()
	team.id = CH_TEAM
	out.append(team)

	var near := DotChatChannel.make(CH_NEAR, "Nearby", DotChatChannel.Scope.RADIUS)
	near.prefix = "(near)"
	near.radius = 30.0
	near.colour = Color(0.75, 0.85, 0.70)
	out.append(near)

	var whisper := DotChatChannel.direct()
	whisper.id = CH_WHISPER
	out.append(whisper)

	return out


func _chat_rules() -> DotChatRules:
	var rules := DotChatRules.new()

	rules.max_length = 200
	rules.refuse_over_length = false
	rules.allow_newlines = false
	# Both on, and both for the same reason: a chat line is drawn by a client that may
	# render BBCode, and a player who can write markup can write anything the renderer
	# understands — including something that looks like a server announcement.
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true

	rules.rate_per_minute = 25
	rules.burst = 4.0
	rules.duplicate_window_sec = 6.0
	rules.duplicate_depth = 3

	# `!` and `/`, which is what twenty years of servers taught everybody's fingers.
	rules.command_prefixes = PackedStringArray(["!", "/"])
	rules.broadcast_unknown_commands = false

	return rules


## dot-server's `player_chat`, intercepted.
##
## [b]Cancelled every time, and the cancel reason is empty on purpose.[/b] The event's
## contract is that a cancelled message is refused and the player told why; here the
## message is not refused at all, it is delivered by somebody else — so a reason would
## put "Message blocked" in front of a player whose line went out perfectly.
func _on_player_chat(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	var text := event.get_string("text", "")
	var channel: StringName = CH_TEAM if event.get_bool("team_only", false) else CH_ALL

	# A free-for-all has no teams, so a team message would reach the one player whose
	# team number matches — themselves. Falling back is better than refusing: the
	# player pressed the team key and something has to happen.
	if channel == CH_TEAM and game.mode != null and not game.mode.is_team_mode():
		channel = CH_ALL

	var submitted := chat.submit(session.peer_id, channel, text)

	if not submitted.ok:
		# The router refused it — rate, duplicate, gag, length. Its own
		# `message_refused` signal has already fired with the reason; telling the
		# player is dot-server's job because it is the one holding the session.
		server.chat.send_system_to(session, submitted.error.message)

	event.cancel("")


## What the router calls to put one line in front of some peers.
func _send_chat(wire: Dictionary, recipients: PackedInt32Array) -> void:
	if server.chat == null:
		return

	var message := DotChatMessage.from_dictionary(wire)

	if not message.ok:
		return

	var line := (message.value as DotChatMessage).describe()

	for peer in recipients:
		var session := server.session_of(peer)

		if session != null:
			server.chat.send_system_to(session, line)


func _playing_peers() -> PackedInt32Array:
	var out := PackedInt32Array()

	for session in server.playing_sessions():
		out.append(session.peer_id)

	return out


func _on_message_accepted(
	message: DotChatMessage, _recipients: PackedInt32Array
) -> void:
	said.emit(message.sender_peer, message)


func _on_command_entered(
	peer: int, command: String, args: PackedStringArray, _raw: String
) -> void:
	command_entered.emit(peer, command, args)


## Tells the router the game handled a command, so it is not broadcast as chat.
func claim_command() -> void:
	if chat != null:
		chat.claim_command()


## A line from the server to everybody.
func announce(text: String) -> void:
	if chat != null:
		chat.announce(text, CH_ALL)


## A line from the server to one player.
func notice(peer: int, text: String) -> void:
	if chat != null:
		chat.notice(peer, text, CH_ALL)


# --- Voice -----------------------------------------------------------------

func _build_voice() -> DotResult:
	voice = DotVoiceRouter.new()
	voice.name = "Voice"
	voice.config = DotVoiceConfig.new()
	voice.default_channel = DotVoiceRouter.Channel.PROXIMITY
	voice.proximity_range = voice_range
	voice.max_bytes_per_second = 6144

	# One peer at a time, and the loop is inside the router where it can be seen.
	voice.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		if link != null:
			link.send_voice(peer, bytes)

	voice.team_fn = func(peer: int) -> StringName:
		var player := _player_of(peer)
		return StringName(str(player.team)) if player != null else &"0"

	voice.position_fn = func(peer: int) -> Vector3:
		var player := _player_of(peer)
		return player.controller.state.position if player != null else Vector3.ZERO

	add_child(voice)

	return DotResult.success(voice)


## Where a client's captured audio arrives. Pointed at by the bridge.
func relay_voice(speaker_peer: int, bytes: PackedByteArray) -> void:
	if voice != null:
		voice.relay(speaker_peer, bytes)


# --- Sessions --------------------------------------------------------------

## A client is in the game. Gives them the chat backlog and lets them be heard.
func add_peer(peer: int) -> void:
	if voice != null:
		voice.add_peer(peer)

	if chat == null:
		return

	# The backlog, which is the difference between joining a conversation and joining
	# a silence. dot-chat keeps it per channel and only for channels that asked.
	var session := server.session_of(peer)

	if session != null:
		for row in chat.backlog_for(peer):
			var message := DotChatMessage.from_dictionary(row)

			if message.ok:
				server.chat.send_system_to(
					session, (message.value as DotChatMessage).describe()
				)

	chat.join_notice(peer, CH_ALL)


func remove_peer(peer: int) -> void:
	if chat != null:
		chat.leave_notice(peer, CH_ALL)
		# Its rate window, its duplicate history and its silence timer. Without this a
		# server that has been up for a week holds a row per peer that ever connected.
		chat.forget(peer)

	if voice != null:
		voice.remove_peer(peer)


# --- Admission -------------------------------------------------------------

## Whether a session may join, by dot-moderation's records.
##
## Both halves: the person and the address. A ban on an address that the person can
## walk round by reconnecting is not a ban, and one on a person who can change address
## is not either.
func check_admission(session: DotClientSession) -> DotResult:
	if moderation == null or session == null:
		return DotResult.success(null)

	return moderation.check_admission(str(session.userid), session.address)


func _player_of(peer: int) -> ArenaPlayer:
	var session := server.session_of(peer)
	return game.player_for(session.userid) if session != null else null


func describe() -> Dictionary:
	return {
		"chat": chat.describe() if chat != null else {},
		"voice": voice.describe() if voice != null else {},
		"moderation": moderation.describe() if moderation != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if chat != null:
		out.append_array(chat.describe_lines())

	if voice != null:
		out.append_array(voice.describe_lines())

	if moderation != null:
		out.append_array(moderation.describe_lines())

	return out
