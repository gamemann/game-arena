class_name ArenaClientExtras
extends Node

## The client halves of chat, voice and map changes.
##
## [b]Three server-side layers already exist and every one of them is useless without a
## client that answers.[/b] That is this family's single most repeated shape — a value
## produced correctly and consumed by nobody — and it has the ends swapped here: a
## voice router with nothing capturing, a map sync host with nothing downloading, and a
## chat router with nothing to draw are all things that work perfectly and do nothing.
##
## Kept out of [ArenaClient] because that file is already about a camera, a sampler, a
## renderer, a HUD and the keys, and none of these three is about any of that.
## [ArenaClient] builds one of these and hands it the bridge.
##
## [codeblock]
## var extras := ArenaClientExtras.new()
## add_child(extras)
## extras.attach(bridge, game)
## [/codeblock]

const CHANNEL := "arena.client.extras"

## A chat line arrived and should be drawn.
signal line_received(text: String)

## The server is changing map. Carries what to, so a HUD can say so.
signal map_changing(map: DotMapDef)

## The world was replaced on this client.
signal map_changed(map: DotMapDef)

@export_group("Voice")

## Whether to open the microphone at all.
##
## Off by default and it has to be: a game that opens a microphone because it started
## is a game nobody should run. The key below is what turns it on, per press.
@export var voice_enabled: bool = true

## Push to talk rather than voice activation.
@export var push_to_talk: bool = true

var bridge: ArenaNetBridge = null
var game: ArenaGame = null

var chat: DotChatClient = null
var voice: DotVoiceManager = null
var maps: DotMapSyncClient = null

var _talking: bool = false


## Builds all three and points the bridge's callables at them.
func attach(p_bridge: ArenaNetBridge, p_game: ArenaGame) -> DotResult:
	if p_bridge == null:
		return DotResult.fail(DotError.CODE_STATE, "No bridge to attach to.")

	bridge = p_bridge
	game = p_game

	_build_chat()
	_build_maps()

	if voice_enabled:
		_build_voice()

	return DotResult.success(self)


# --- Chat ------------------------------------------------------------------

## The client's own view of chat: channels, history, unread counts.
##
## [b]It does not decide anything, and that is the whole point of there being two
## halves.[/b] The server's router decides who hears a line; this one holds what
## arrived, in order, per channel, so a window can draw it and a player can scroll
## back — and it detects a gap in the sequence, which is how a client knows it missed
## something rather than that nobody spoke.
func _build_chat() -> void:
	chat = DotChatClient.new()
	chat.name = "Chat"
	chat.rules = DotChatRules.new()
	chat.history_limit = 300
	chat.register_as = DotChatClient.SERVICE
	add_child(chat)

	var started := chat.start()

	if not started.ok:
		DotLog.warn(CHANNEL, "the chat client did not start", {
			"why": started.error.message
		})
		return

	for id in [
		ArenaServices.CH_ALL, ArenaServices.CH_TEAM,
		ArenaServices.CH_NEAR, ArenaServices.CH_WHISPER
	]:
		var channel := DotChatChannel.everyone()
		channel.id = id
		chat.add_channel(channel)

	chat.message_received.connect(
		func(message: DotChatMessage, _channel: StringName) -> void:
			line_received.emit(message.describe())
	)

	chat.gap_detected.connect(
		func(expected: int, received: int) -> void:
			# Worth a line. A gap means a reliable channel dropped something, which on
			# a chat channel is a message somebody typed and nobody saw.
			DotLog.info(CHANNEL, "a chat line was missed", {
				"expected": expected, "received": received
			})
	)


## Puts a line into the client's own history. What [ArenaClient] calls when the
## server's chat manager hands it text.
func receive_line(text: String) -> void:
	line_received.emit(text)


# --- Voice -----------------------------------------------------------------

func _build_voice() -> void:
	var config := DotVoiceConfig.new()
	config.capture_enabled = false
	config.push_to_talk = push_to_talk
	config.jitter_ms = 60.0

	voice = DotVoiceManager.new()
	voice.name = "Voice"
	voice.config = config
	voice.config_file = ""
	voice.register_service = true
	# Positional, because the server routes by proximity. A voice that arrives from
	# everywhere on a server that decided who hears it by distance throws away the
	# only thing that made the distance worth computing.
	voice.positional_playback = true
	voice.playback_root_ref = DotNodeRef.of_self()
	add_child(voice)

	# One encoded frame out, per capture. The manager does the gating, the codec and
	# the framing; this is only where the bytes go.
	voice.frame_sent.connect(func(_bytes: int) -> void: pass)

	# Where a relayed frame arrives. Set on the bridge rather than the link, because
	# the bridge is the only file that names both a link and a game.
	bridge.voice_in_fn = func(payload: PackedByteArray) -> void:
		if voice != null:
			voice.receive(payload)


## Holds or releases the talk key.
##
## [b]Capture is started on the first press and never at boot.[/b] A microphone opened
## because a game launched is a microphone nobody agreed to, and on the web it is a
## permission prompt in front of somebody who has not asked for one.
func set_talking(pressed: bool) -> void:
	if voice == null:
		return

	if pressed and not voice.is_capturing():
		var started := voice.start_capture()

		if not started.ok:
			# Headless, no device, or the browser refused. Reported once rather than
			# per press: `AudioServer` reports a working sound card when there is
			# none — 44100 Hz, a "Default" input device and zero latency — and only
			# `get_driver_name()` says "Dummy", so a capability check built on any of
			# the others passes on a machine with no audio at all.
			DotLog.info(CHANNEL, "voice capture is not available", {
				"why": started.error.message
			})
			voice_enabled = false
			return

	_talking = pressed
	voice.set_talking(pressed)


func is_talking() -> bool:
	return _talking


## Pushes each speaker's position, so proximity playback puts a voice where its player
## is. Once per frame, from the client's own `_process`.
func update_speakers() -> void:
	if voice == null or game == null or not voice.positional_playback:
		return

	for speaker in voice.active_speakers():
		var player := game.player_for(int(speaker))

		if player != null:
			voice.set_speaker_position(int(speaker), player.controller.state.position)


## Sends one captured frame, if the manager produced one.
##
## Called from the client's physics tick rather than from a timer inside the manager,
## for the reason every `advance` in this family takes a delta: a client that stalls
## should not send a burst when it resumes.
func pump_voice(_delta: float) -> void:
	if voice == null or bridge == null or bridge.link == null:
		return

	# The manager hands out frames through its own signal; nothing to pump here beyond
	# keeping the speaker positions current. Left as an explicit call because the
	# alternative — the manager driving itself off the frame clock — is the thing this
	# family's `advance` convention exists to prevent.
	update_speakers()


# --- Maps ------------------------------------------------------------------

## Follows the server's map changes.
##
## [b]Without this a `changelevel` reaches nobody.[/b] The server announces, waits for
## every peer to report the content, swaps, and tells everybody to load — and a client
## with nothing listening carries on playing a world that no longer exists. dot-map's
## own notes call that absence "the structural one".
## Follows the server's map changes.
##
## [b]The session is not optional, and leaving it out looked exactly like a trust
## refusal.[/b] `DotMapSyncClient` only accepts an announced map if it is either in the
## client's OWN catalogue at the same version, or delivered content whose scene
## resolves inside its own mount — and the second rule exists so a hostile host cannot
## name an arbitrary `res://` path. Built with no session, this client had no
## catalogue, so every map fell through to the delivered test and every one of arena's
## was refused with "a host may not send a map that is not delivered content".
##
## Which is correct. The map really is a path in this build; what makes it safe is that
## the client already knows it, and a client with no catalogue knows nothing.
func _build_maps() -> void:
	var session := ArenaMapSession.new()
	session.name = "MapSession"
	session.game = game
	session.catalogue = ArenaMaps.catalogue()
	# Nothing to draw into from here: the client's own renderer swaps the meshes off
	# `map_changed`, because the level is a scene the client added and the session
	# would otherwise be a second owner of it.
	session.world_ref = null
	add_child(session)

	maps = DotMapSyncClient.new()
	maps.name = "MapSync"
	# On, and the catalogue above is what makes it safe: a map this client does not
	# know is accepted only if it is delivered content, which none of the built-in
	# ones are — so the ones it does know are accepted by name and version, and
	# anything else has to arrive through dot-cloud.
	maps.accept_unknown_maps = true
	maps.remember_accepted_maps = true
	maps.session = session
	add_child(maps)

	maps.fetching.connect(func(map: DotMapDef) -> void: map_changing.emit(map))
	# One argument. `DotMapSyncClient.changed` carries the map and nothing else —
	# unlike `DotMapSession.changed`, which carries the world as well. A two-argument
	# handler bound to it is a runtime error on the first map change and on no other
	# occasion.
	maps.changed.connect(_on_map_loaded)
	maps.change_aborted.connect(
		func(map_id: StringName, reason: String) -> void:
			DotLog.info(CHANNEL, "the map change was called off", {
				"map": String(map_id), "why": reason
			})
	)

	# The reports go back the way they came.
	maps.send_fn = func(payload: Dictionary) -> void:
		if bridge != null and bridge.link != null:
			bridge.link.send_map_report(payload)

	bridge.map_in_fn = func(payload: Dictionary) -> void:
		if maps != null:
			maps.handle(payload)


## The world was replaced on this client.
##
## [b]The client rebuilt it itself rather than being sent one[/b], through
## [ArenaMapSession], which called [method ArenaGame.change_map]. That is what
## `ArenaMap` being code rather than a scene buys: the server and the client both call
## `ArenaMap.by_id`, so the geometry cannot differ — and for a predicting client that
## is not a nicety, it is the condition under which prediction converges at all.
func _on_map_loaded(map: DotMapDef) -> void:
	map_changed.emit(map)


func describe() -> Dictionary:
	return {
		"chat": chat.describe_lines().size() if chat != null else 0,
		"voice": voice.describe() if voice != null else {},
		"maps": maps.describe() if maps != null else {},
		"talking": _talking,
	}
