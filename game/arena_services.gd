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

@export_group("Website chat")

## The relay's configuration. Left null, a default is built and the relay stays OFF.
##
## Off is the right default for the same reason `pg_arena` is: a relay carries what your
## players type to a web page and back, and that is an operator's decision rather than a
## consequence of installing an addon.
@export var relay_config: DotChatRelayConfig = null

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

## The website chat relay, when one is configured. See [method _build_relay].
var relay: DotChatRelay = null

## The backbone client the relay posts through. Assigned by the module BEFORE
## [method setup], because [ArenaIdentity] is what owns one and is built first.
##
## [b]An [Object], not a [DotBackboneClient].[/b] Same reasoning as dot-chat's own: this
## file is happy to name the type and the relay is not, and keeping one spelling across
## the seam means the duck-typed contract is the only contract.
var backbone: Object = null

var _started: bool = false

## Latched by [method claim_command] for the duration of one command dispatch.
var _command_claimed: bool = false


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

	# After chat, because it needs the router; not fatal, because a relay that cannot
	# start is a server that still runs a perfectly good match.
	var relayed := _build_relay()
	DotLog.result(CHANNEL, "the website chat relay", relayed)

	if voice_enabled:
		var voiced := _build_voice()

		if not voiced.ok:
			return voiced

	_started = true
	return DotResult.success(self)


# --- The website relay -----------------------------------------------------

## Joins this server's chat to its room on the website.
##
## [b]Three seams, and every one of them points at something that already existed.[/b]
## The backbone client is dot-auth's. The permission answer is dot-server's admin
## manager, through `uid_has_permission` — the method written for exactly this, deciding
## what somebody may do when they are not connected. The command runner is the console,
## with a context built the way RCON builds one.
##
## Nothing here is a new policy. A relayed command is checked against the same file, by
## the same flags, as the same person typing it in game.
func _build_relay() -> DotResult:
	if relay_config == null:
		relay_config = DotChatRelayConfig.new()

	if not relay_config.enabled:
		return DotResult.success(null)

	if backbone == null:
		# **Found, not handed over.** A backbone client is built by whatever owns the
		# server's credential — dot-server-deploy's `TmcReport`, or this game's own
		# identity layer — and a relay built during module load exists before any host
		# could assign one. `DotBackboneClient` publishes itself under this name for
		# exactly that reason; the ordering trap is the one that left dot-server's audit
		# log unopened in every default configuration.
		backbone = DotRegistry.get_service(&"dot_backbone_client")

	if backbone == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The chat relay is on but no backbone client was handed to services. "
				+ "ArenaIdentity builds one when report_to_backbone is set."
		)

	relay = DotChatRelay.new()
	relay.name = "ChatRelay"
	relay.router = chat
	relay.config = relay_config
	relay.client = backbone
	relay.permission_fn = _uid_has_permission
	relay.command_fn = _run_relayed_command

	add_child(relay)

	var started := relay.start()

	if not started.ok:
		remove_child(relay)
		relay.queue_free()
		relay = null
		return started

	relay.site_command.connect(_on_site_command)

	return DotResult.success(relay)


func _uid_has_permission(uid: String, flag: String) -> bool:
	if server == null or server.admins == null:
		return false
	return server.admins.uid_has_permission(uid, flag)


## Runs a command typed on the website, as the site member who typed it.
##
## [b]dot-server's, not this game's.[/b] Every game in this family that has a relay needs
## exactly this and the glue is identical in all of them — a context built by hand, the
## uid's own flags on it, the console asked. Five copies of that is the shape this tree
## has shipped in four shell scripts and three vendoring lists, so it lives in
## `DotServer.run_command_as_uid` and this is the call.
func _run_relayed_command(
	uid: String, command: String, args: PackedStringArray, source: int
) -> void:
	if server == null:
		return

	for reply in server.run_command_as_uid(uid, command, args, source):
		DotLog.info(CHANNEL, "relayed command reply", {"uid": uid, "line": reply})


func _on_site_command(uid: String, command: String, allowed: bool) -> void:
	# Audited either way. A refusal is the half worth having a record of: it is somebody
	# trying to drive the server from a web page without the rights to.
	if server != null and server.audit != null:
		server.audit.record(
			"relay_command", "web:%s" % uid, command, {"allowed": allowed}
		)


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

		# **And `player_command`, without which none of this game's chat commands
		# exist.** dot-server's chat manager checks for a command prefix BEFORE it
		# fires `player_chat`, and `_handle_command` returns on every path — including
		# the unknown-command one, which is silently ignored. Its prefixes are `["!",
		# "/"]`, identical to `DotChatRules`'.
		#
		# So a line beginning with `!` never reached `DotChatRouter` at all, and
		# `command_entered` — which this game connects, and which `_on_chat_command`
		# below switches on — **could not fire.** `!nominate`, `!timeleft`, `!score`
		# and `!stats` have no console equivalent and therefore did nothing whatever;
		# `!rtv` and `!vote` only appeared to work because dot-server has commands of
		# those names of its own.
		#
		# `player_command` is fired before the console lookup and is cancellable, which
		# is exactly the seam for this: the game gets first refusal, claims what it
		# knows, and anything it does not claim carries on to the console as before.
		server.events.hook_pre("player_command", _on_player_command)

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
##
## Also latches for the `player_command` path, where there is no router message to
## claim — the handler runs inside the event and what "claimed" means there is
## "cancel the event so dot-server does not also look it up".
func claim_command() -> void:
	_command_claimed = true

	if chat != null:
		chat.claim_command()


## A `!command` from dot-server's chat manager, before it reaches the console.
func _on_player_command(event: DotEvent) -> void:
	var session := event.get_session()

	if session == null:
		return

	_command_claimed = false

	var raw_args: Array = event.data.get("args", [])
	var args := PackedStringArray()

	for arg in raw_args:
		args.append(str(arg))

	command_entered.emit(session.peer_id, event.get_string("command"), args)

	# Only what the game actually took. Anything else goes on to the console exactly as
	# it did before, which is what keeps `!kick` and every other dot-server command
	# working — and keeps the "do not confirm which commands exist" answer for the rest.
	if _command_claimed:
		event.cancel("handled by the game", CHANNEL)


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
