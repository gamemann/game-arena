extends Node

const ArenaAvatars := preload("arena_avatars.gd")
const ArenaBrowser := preload("arena_browser.gd")
const ArenaClientExtras := preload("arena_client_extras.gd")
const ArenaEvents := preload("arena_events.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaHud := preload("arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMenus := preload("arena_menus.gd")
const ArenaNetBridge := preload("arena_net_bridge.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaPresentation := preload("arena_presentation.gd")

## A playable game-arena: one local player, a camera, a HUD, menus and the keys.
##
## [b]Separate from [ArenaGame], which is the simulation and runs headless.[/b] A
## dedicated server never loads this. That split is the reason `headless_match` can play
## a whole deathmatch with no renderer and no window, and it is the reason this file is
## the only one in the project that mentions a `Camera3D` or an `InputEvent`.
##
## Until this existed, game-arena was the reference game with nothing to sit down at:
## `ArenaNetBridge` ran, `headless_net` drove it, and there was no camera rig, no input
## sampling, no renderer and no sound. Everything here is modelled on `G2GClient`,
## which is the one in this family proven over a real socket and in a browser.
##
## [codeblock]
## WASD          move                Space   jump (hold; auto-hop is on)
## Ctrl          crouch              Mouse1  fire
## R             reload              1..4    weapon slots  (wheel cycles)
## Tab (hold)    scoreboard          Esc     pause menu / release the mouse
## [/codeblock]

const CHANNEL := "arena.client"

## The player pressed Leave on the pause menu.
##
## [b]Announced rather than acted on, and it used to be neither.[/b] What "leave" means
## belongs to whatever loaded this client — the shell goes back to its own menu, an embedded
## page closes the frame — so a client that called `get_tree().quit()` itself would be one
## that cannot be embedded in anything. What it did before was nothing at all: the button
## existed, emitted its signal, and the only thing this file did with the pause menu was
## `var _unused := pause`.
signal leave_requested()

## Where a dot-server client link publishes itself.
const LINK_SERVICE := &"dot_client_link"

## Field of view, horizontal at 4:3. An arena shooter's number, not Godot's.
const FIELD_OF_VIEW := 100.0

var game: ArenaGame = null
var player: ArenaPlayer = null
var hud: ArenaHud = null
var menus: DotScreenStack = null
var net: DotNetManager = null
var bridge: ArenaNetBridge = null
var link: Node = null

## Chat, voice and map changes: the client halves of what [ArenaServices] and
## [ArenaMapDirector] run on the server.
##
## [b]Null offline, deliberately.[/b] All three are about a server that is telling this
## client something, and an offline game has nobody to be told by. Building them anyway
## would open a microphone in a single-player match.
var extras: ArenaClientExtras = null

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many bots to add when playing offline. Zero is an empty arena.
@export_range(0, 15, 1) var offline_bots: int = 3

var _offline := true
var _sampler: DotFpsSampler = null
var _fire := DotWeaponCommand.new()

## A weapon slot the player asked for this tick, or 0 for "no change". Cleared once
## sent — see [method _read_fire].
var _wanted_slot: int = 0

## What the server last said was left on the clock, in seconds. Negative for "no
## limit", which is what `DotMatch.seconds_remaining` returns and what the HUD reads as
## "show the state name instead".
var _match_seconds_remaining: float = -1.0

## Seconds since the last position report. See `_process`.
var _report_timer: float = 0.0

## Whether the cursor is waiting for a click before it can be captured. Web only.
var _awaiting_click := false

## Who [member player] should be, whether or not that player exists yet.
##
## [b]HELLO names you and JOIN creates you, in that order.[/b] A client that resolved
## the player here and never tried again holds null for the whole session — and the
## list of what that breaks is the interesting part: the HUD binds by id and works, the
## camera follows the entity and works, movement works because `DotFpsSampler.sample`
## polls the `InputMap` rather than reading events, and *everything below the
## `player == null` guard in `_unhandled_input` does not*. A client that connects,
## draws, shows a live HUD and walks around, with a dead mouse and a dead keyboard.
## g2gfast shipped exactly that and a person had to report it.
var _watch_id: int = -1

## Bots this client drives, offline only. Session id -> a simple aim-and-hold brain.
var _bots: Dictionary = {}

## The settings and bindings the menus are generated from.
var _ui_config: DotUiConfig = null

## The meshes of the map currently drawn. Replaced on a map change.
var _level: Node3D = null

## dot-browser's client half, and the screen over it.
var browser: ArenaBrowser = null

## Settings, audio, effects and the console. Everything that belongs to the person at the
## keyboard rather than to the match.
var presentation: ArenaPresentation = null

## Whether this client believes it is holding a prop.
##
## [b]A belief, not a fact, and the distinction is the whole reason props are not
## predicted.[/b] The server decides whether a grab happened; this is only what the
## next press of the same key should ask for. A rigid body's contact solver is not
## reproducible across machines, so a client that tracked a held prop's position
## locally would be corrected on every snapshot.
var _holding: bool = false


func _ready() -> void:
	link = DotRegistry.get_node_service(LINK_SERVICE)
	_offline = force_offline \
		or link == null \
		or OS.get_cmdline_user_args().has("--offline")

	game = ArenaGame.new()
	game.name = "Game"
	game.is_authority = _offline

	# [b]HEADLESS collision, on a client with a screen.[/b] It reads like the wrong
	# setting and it is the only correct one here.
	#
	# `Mode.HEADLESS` is not a degraded mode — it is `ArenaMap`'s analytic geometry, and
	# `ArenaMap`'s whole design is that the meshes, the physics bodies and the analytic
	# boxes come from ONE list of `AABB`s so they cannot drift. What matters for a
	# client is the last clause of dot-player-controller's own note on it: *it gives the
	# same answer on a client replaying a tick and a server that ran it.*
	#
	# A predicting client MUST use the same collision backend as the server it is
	# predicting against. The server is headless and analytic; a client on Godot physics
	# is a second solver with its own contact epsilons and its own idea of a step, so
	# every replay would land somewhere slightly different and reconciliation would
	# correct a client that had done nothing wrong. That is the 0.500 correction rate
	# this project already paid for once.
	#
	# Measured the first time it was tried the other way: `Mode.PHYSICS` needs a
	# collision shape on the player node, `ArenaPlayer` is a plain `Node3D`, and the
	# player fell through a floor that was drawn perfectly — a void with one box in it
	# and no error anywhere.
	#
	# The visible level below is still added: it is what the player SEES, and nothing
	# collides against it.
	game.headless = true
	game.register_service = _offline
	add_child(game)

	# Connected here, before anything can create a player, rather than inside
	# `_watch`. HELLO and JOIN are both reliable and ordered so HELLO does arrive
	# first — but "the ordering happens to save us" is exactly the reasoning that put
	# this bug in game-g2gfast, and a connection that costs nothing is cheaper than
	# depending on it. `_watch_id` is -1 until HELLO names us, so nothing matches
	# before then.
	game.player_added.connect(_on_player_added)

	var built := game.setup(ArenaMap.dm_box())

	if not built.ok:
		DotLog.result(CHANNEL, "the arena could not be built", built)
		return

	# The world, which the server does not need and a player cannot do without. Held,
	# because a map change has to take it away again — see `_on_map_changed`.
	_level = game.map.to_scene()
	_classify_level()
	add_child(_level)
	_light()

	_sampler = DotFpsSampler.new(ArenaPlayer.arena_tunables())
	DotFpsSampler.register_default_actions(_sampler)

	# Before the interface, because the field of view and the crosshair come out of the
	# settings document and a screen built first would have laid itself out from the
	# defaults.
	_build_presentation()
	_build_interface()

	# The player's look and crosshair settings, onto the two things they shape. After both
	# exist, and pushed rather than waited for: a value loaded from disk has not changed,
	# so a binding that only listened would leave a saved sensitivity doing nothing.
	if presentation != null:
		presentation.bind_look(_sampler.tunables)
		if hud != null:
			presentation.bind_crosshair(hud.crosshair)

	if _offline:
		_start_offline()
	else:
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "netcode", netted)

	_grab_mouse()


## A sun and an ambient sky, because a dev-textured arena under no light is black.
func _light() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)

	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.36, 0.42, 0.52)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.58, 0.64)
	environment.ambient_light_energy = 0.75
	world.environment = environment
	add_child(world)


func _build_interface() -> void:
	hud = ArenaHud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.build(game)

	menus = DotScreenStack.new()
	menus.name = "Menus"
	menus.register_service = false
	# [b]The stack does NOT own the mouse here, and that is the one place this client
	# departs from dot-ui's default.[/b] `DotScreenStack.manage_mouse` forces CAPTURED
	# whenever nothing is open, which is right on a desktop and impossible in a
	# browser: pointer lock needs transient user activation, a browser refuses it
	# *silently*, and `Input.mouse_mode` then reads back as CAPTURED while the cursor
	# sits on top of the game. Two owners fighting over it is a cursor that flickers —
	# dot-ui's own documentation says so — so there is exactly one, and it is
	# [method _apply_mouse] below, which knows about the click.
	menus.manage_mouse = false
	add_child(menus)

	_ui_config = DotUiConfig.new()
	var pause := ArenaMenus.install(
		menus,
		game,
		_ui_config,
		presentation.settings if presentation != null else null
	)

	# The server browser, which is the only screen here that is about something other
	# than this game. Built whether or not this client is connected: looking for a
	# server is what you do when you are not on one.
	browser = ArenaBrowser.new()
	browser.name = "Browser"
	add_child(browser)

	var listed := browser.setup()
	DotLog.result(CHANNEL, "the server browser", listed)

	if listed.ok:
		var screen := ArenaBrowser.BrowserScreen.new()
		screen.name = "Servers"
		screen.build(browser)
		menus.register(screen)

		browser.listing_changed.connect(screen.redraw)
		screen.join_pressed.connect(_on_join_requested)

		# [b]And now something opens it.[/b] The browser screen was registered under
		# `&"servers"` and **nothing anywhere pushed it** — a whole server list, with
		# sources, a filter, favourites and a join, built on every launch and unreachable.
		# The pause menu has a Servers button now and this is the line that lights it up,
		# which has to happen here rather than in `install` because the browser is built
		# after the menus and only when its list came up.
		ArenaMenus.note_screens(menus, pause)

	# Leave was wired to nothing at all. `var _unused := pause` is what stood here, so the
	# button was drawn, pressed, and answered by nobody.
	pause.chosen.connect(func(id: StringName) -> void:
		if id != ArenaMenus.LEAVE:
			return

		# Closed first, so a client that cannot actually leave — an embedded one, a
		# single-process test — is not left staring at a pause menu over a game that
		# carried on running behind it.
		menus.pop(&"pause")
		leave_requested.emit()
	)


# --- Offline ---------------------------------------------------------------

func _start_offline() -> void:
	game.start(0)

	# [b]Named as ours BEFORE it exists.[/b] `add_player` emits `player_added`
	# synchronously, and `_on_player_added` gives every player it does not recognise as
	# ours a body to be seen as. With `_watch_id` still -1 that was this one: the local
	# player wore a capsule and a nose with the camera inside it, and the nose was a pale
	# slab across the bottom of every offline frame. A networked client never had it,
	# because HELLO names the session before JOIN creates it.
	_watch_id = 1

	var added := game.add_player(1, "Player")

	if added.ok:
		_adopt(added.value as ArenaPlayer)

	for i in range(offline_bots):
		var bot := game.add_player(100 + i, "Bot %d" % (i + 1))

		if bot.ok:
			var body := bot.value as ArenaPlayer
			# A stock avatar, deterministic in the id, so an offline bot looks the
			# same every launch and different from the bot beside it.
			body.attach_body_mesh(
				Color.from_hsv(float(i) / 6.0, 0.55, 0.85),
				ArenaAvatars.stock_avatar(
					StringName(ArenaGame.storage_key(body.player_id))
				)
			)
			_bots[body.player_id] = body


# --- Networked -------------------------------------------------------------

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = ArenaGame.NET_SNAPSHOT_RATE
	config.enable_prediction = true
	# Off on a client: rewinding is what a server does to resolve somebody else's shot,
	# and a client resolves nobody's.
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	# From the game, not written here. See ArenaGame.NET_WORLD_EXTENT — this line said
	# 256 while the server said 128, and a quantised position decoded against the wrong
	# range is a different position rather than a less precise one.
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

	# Under the link, and NAMED the same as the server's — the name is the routing.
	bridge.open_link(link)
	net.messages.seal()

	# The client halves. Built here rather than in `_ready` because every one of them
	# needs the bridge, and there is no bridge offline.
	extras = ArenaClientExtras.new()
	extras.name = "Extras"
	add_child(extras)

	var extra := extras.attach(bridge, game)
	DotLog.result(CHANNEL, "the client's chat, voice and map layers", extra)

	extras.line_received.connect(_on_chat_line)
	extras.said.connect(_on_said)

	# What the server says is carrying chat. It decides whether the box is drawn at all
	# when the player's setting is `auto`.
	extras.chat_relay_changed.connect(func(relayed: bool) -> void:
		if presentation != null:
			presentation.set_chat_relayed(relayed)
	)

	# [b]Where chat actually arrives.[/b] `ArenaServices` routes a line through
	# dot-chat and then hands it to dot-server's manager to put on the wire, so on
	# this end it lands on `DotClientLink.chat_received` — not on anything dot-chat
	# owns. Without this connection the client's `DotChatClient` is a history nothing
	# feeds: empty scrollback, zero unread, and chat working perfectly on screen.
	if link != null and link.has_signal("chat_received"):
		link.connect("chat_received", extras.receive_wire)
	extras.map_changing.connect(_on_map_changing)
	extras.map_changed.connect(_on_map_changed)

	bridge.hello_received.connect(_on_hello)
	bridge.notice_received.connect(_on_notice)
	bridge.vote_received.connect(_on_vote)
	bridge.kill_received.connect(_on_kill)
	bridge.match_received.connect(_on_match)

	# The one thing that writes an RTT sample. dot-net never touches a transport, so
	# nothing in it can; without this the clock's input lead omits the flight time and
	# past ~30 ms every command arrives after its tick and is discarded as late.
	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	# READY, and not one byte before the scene exists. dot-server's signon finishes and
	# THEN the client builds this; anything the server sent in between landed on a node
	# that did not exist and was lost, one "Node not found" per call.
	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


func _say_ready() -> void:
	if bridge != null:
		bridge.send_request(ArenaEvents.Ask.READY)


## A chat line, on the HUD's notice line.
##
## The HUD is the whole chat window this game has, which is a level of ambition rather
## than an oversight: a scrolling window with an input field is a screen, and a screen
## is [DotScreenStack]'s. [DotChatClient] is holding the history the moment somebody
## writes one.
func _on_chat_line(text: String) -> void:
	if hud != null:
		hud.notice(text)


# --- Chat ------------------------------------------------------------------

## Joins the chat box to the two things it needs: a way out, and a way to stop the player.
##
## [b]The sampler is the half that is easy to forget.[/b] `swallows_input` keeps typed keys
## out of `_unhandled_input`, but movement here is POLLED — `DotFpsSampler.sample` reads
## the device every physics frame and does not care what consumed an event. Without
## `suspended`, typing "sw" walks you backwards off whatever you were standing on.
## `DotFpsSampler.suspended` is documented "for a chat box or a menu" and until now
## nothing in this game had ever set it.
func _wire_chat_window() -> void:
	var window: DotChatWindow = presentation.chat_window if presentation != null else null

	if window == null:
		return

	window.submitted.connect(_on_chat_submitted)

	window.opened.connect(func(_channel: StringName) -> void:
		if _sampler != null:
			_sampler.suspended = true
	)

	window.closed.connect(func() -> void:
		if _sampler != null:
			_sampler.suspended = false
	)


## What a player typed, on its way to the server.
##
## [b]Nothing is filtered here.[/b] The server decides what a line may contain and its
## answer is the only one that counts; a client that filtered first would be a second
## filter that drifts from the real one.
func _on_chat_submitted(text: String, channel: StringName) -> void:
	if _offline:
		# Offline there is no server to decide anything, so the line goes straight to the
		# log. Saying nothing at all would read as a chat box that does not work.
		if presentation != null and presentation.chat_window != null:
			presentation.chat_window.add_said(
				_local_display_name(), text, Color(0.62, 0.78, 1.0)
			)
		return

	if link != null and link.has_method("send_chat"):
		link.send_chat(text, channel == &"team")


## What to draw beside an offline player's own line.
func _local_display_name() -> String:
	if player != null and player.display_name != "":
		return player.display_name

	return "You"


## A line somebody said, in the chat box, with the name drawn apart from the text.
func _on_said(speaker: String, text: String, kind: String) -> void:
	if presentation == null or presentation.chat_window == null:
		return

	# The server has already decided who hears a team line; the colour is only so that a
	# player can see which of their own lines went where.
	var speaker_colour := Color(0.55, 0.85, 0.60) if kind == "team" else Color(0.62, 0.78, 1.0)

	if speaker == "":
		presentation.chat_window.add_text(text, Color(0.80, 0.82, 0.86))
		return

	presentation.chat_window.add_said(speaker, text, speaker_colour)


func _on_map_changing(map: DotMapDef) -> void:
	if hud != null:
		hud.notice("Changing map to %s…" % map.name_or_id())


## The world was replaced under this client.
##
## [b]The meshes have to go with it, and nothing else does that.[/b]
## `ArenaGame.change_map` replaces the collision, the trace and the match; the level a
## player can SEE is a scene this client added, and a client that rebuilt one and not
## the other would walk through walls it can see and stop at walls it cannot.
func _on_map_changed(map: DotMapDef) -> void:
	# **The client has to ADOPT the map it was handed, and this is where that was
	# missing.** `ArenaGame.map` is assigned in exactly three places — `setup`, the
	# module's mode change, and `change_map` — and every one of them runs on the
	# SERVER. A mirroring client never calls `change_map`; it is told the new map by
	# `DotMapSyncClient` and that is the only notice it ever gets.
	#
	# So this handler received the correct `DotMapDef` and then rebuilt the level from
	# `game.map`, which was still whatever it had been at signon. Measured on a live
	# server: the server swapped dm_atrium for dm_box and reported `all peers have the
	# map`, and the client tore down its level and rebuilt **the same one**. The player
	# was then standing in geometry the server no longer had, with the server's
	# collision somewhere else entirely — which reads as the client freezing, because
	# every move they make is refused by a wall they cannot see.
	#
	# Nothing errored on either end. The server was right, the protocol completed, the
	# handshake reported success, and the one line that mattered read a stale field.
	var adopted := ArenaMap.by_id(map.id)

	if adopted != null:
		game.map = adopted
	else:
		# A delivered map this build has no geometry for. The level cannot be drawn,
		# and drawing the OLD one is what this whole comment is about — so say so
		# rather than silently showing a world that is not there.
		DotLog.warn(CHANNEL, "the announced map has no local geometry", {
			"map": String(map.id),
		})

	if _level != null and is_instance_valid(_level):
		remove_child(_level)
		# free(), not queue_free(): the new one goes in on this line and a deferred
		# free would leave two levels drawn over each other for a frame.
		_level.free()

	_level = game.map.to_scene()
	_classify_level()
	add_child(_level)

	if presentation != null:
		# Everything drawn for the old map is meaningless now -- a decal is a hole in a
		# wall that no longer exists, and a decal ring that survives a map change is one
		# that survives the map it was about.
		presentation.on_map_changed()

	if hud != null:
		hud.notice("Now playing %s." % map.name_or_id())


## Asks the server to do something with a prop.
##
## [b]An intent over the wire, and the aim is the only thing on it.[/b] The server
## already knows where this player is — it simulated them — and a client that could
## name its own origin could grab a prop from across the map. What it cannot know is
## where they were looking between two ticks, so that is the claim, and
## `DotPropTool.may_act_on` is what decides whether it reaches.
func _ask_prop(action: int) -> void:
	if _offline or bridge == null or player == null:
		return

	var state := player.controller.state

	bridge.send_request(
		ArenaEvents.Ask.PROP_TOOL,
		ArenaEvents.write_prop_act(action, state.yaw, state.pitch)
	)


## The player picked a server.
##
## [b]It does not connect, and that is honest rather than lazy.[/b] Joining means
## tearing down this client's netcode, opening a transport at a new address and going
## through dot-server's signon again — which is a launcher's job, and this game is
## loaded BY one. What this does is note the visit, so the server lands in the
## player's history, and say where to go.
func _on_join_requested(entry: DotBrowserEntry) -> void:
	if browser != null:
		browser.note_connected(entry.key())

	if hud != null:
		hud.notice("Join %s at %s" % [entry.name, entry.join_address()])

	DotLog.info(CHANNEL, "the player picked a server", {
		"name": entry.name, "address": entry.join_address()
	})


func _on_hello(info: Dictionary) -> void:
	_watch(int(info["session_id"]))

	if hud != null:
		hud.notice("Connected to %s" % String(info["map_name"]))


## The server's match state, put where the HUD already reads it.
##
## [b]The client's own `DotMatch` never runs.[/b] Nothing ticks it, it has no spawn
## points and its scoreboard is fed by replication, so every value on it is whatever it
## was constructed with — and `ArenaHud` reads `match_node.state` and
## `seconds_remaining()` directly. Before this, a connected browser client showed
## "IDLE" for ever while the server was playing a round: not a stale value, a value
## nothing had ever written.
##
## Written onto the node rather than into a parallel copy so the HUD stays one code
## path. A HUD that read one field on a server and another on a client would be two
## HUDs, and only one of them would ever be looked at.
func _on_match(info: Dictionary) -> void:
	if game == null or game.match_node == null:
		return

	game.match_node.state = int(info["state"]) as DotMatch.State
	game.match_node.round_number = int(info["round"])

	# Ticks, divided by OUR rate — which HELLO set to the server's, so the two agree.
	# Sending seconds instead would have been a number derived from the sender's rate
	# and read as though it were derived from the receiver's.
	var ticks := int(info["remaining_ticks"])
	_match_seconds_remaining = (
		-1.0 if ticks < 0 else float(ticks) / float(maxi(game.tick_rate, 1))
	)

	if hud != null:
		hud.remaining_override = _match_seconds_remaining


func _on_notice(text: String) -> void:
	if hud != null:
		hud.notice(text)


## The map vote's cue and countdown. The ballot itself arrives as chat, which is where
## `announce_fn` sends it; this is what chat cannot carry.
func _on_vote(info: Dictionary) -> void:
	var seconds_left := int(info.get("seconds_left", 0))

	if seconds_left > 0 and hud != null:
		hud.notice(
			"%s in %d…" % ["Runoff" if bool(info.get("runoff", false)) else "Map vote", seconds_left]
		)

	if presentation != null:
		presentation.on_vote_cue(StringName(str(info.get("cue", ""))))


func _on_kill(info: Dictionary) -> void:
	# The feed is dot-ui's and takes an entry, not a dictionary. Rebuilt here rather
	# than replicated as one, because a `DotKillFeed.Entry` has ten fields and three of
	# them are only meaningful on the server that scored it.
	if hud == null or game == null:
		return

	var entry := DotKillFeed.Entry.new()
	entry.killer_key = str(int(info["killer_id"])) if int(info["killer_id"]) != 0 else ""
	entry.victim_key = str(int(info["victim_id"]))
	entry.cause = StringName(String(info["weapon"]))
	entry.headshot = bool(info["headshot"])

	var killer := game.player_for(int(info["killer_id"]))
	var victim := game.player_for(int(info["victim_id"]))
	entry.killer_name = killer.display_name if killer != null else "the world"
	entry.victim_name = victim.display_name if victim != null else "?"

	hud.show_kill(entry)


# --- Following the local player --------------------------------------------

## Follows a player: the camera, the HUD, and everything the keys act on.
func _watch(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.player_for(session_id))

## A player exists. Ours is one of them; the rest need something to be seen as.
##
## [b]`player_added`, not `player_spawned`.[/b] `player_spawned` comes out of
## dot-match's respawn queue, which runs on the AUTHORITY — a mirroring client never
## fires it, so a client waiting on it waits for ever. The symptom is precise and
## misleading: the HUD binds by id and works, the scoreboard works, the connection is
## live, and there is no camera and no world at all, because both hang off the
## reference this sets. Seen in a real browser against a real server; nothing headless
## could show it, because nothing headless has a camera to be missing.
func _on_player_added(added: ArenaPlayer) -> void:
	if added == null:
		return

	_hear_beacon(added)

	if player == null and added.player_id == _watch_id:
		_adopt(added)
		return

	if added != player and added.body_mesh == null:
		# A stock avatar until the server says otherwise. It is a real document over
		# the same schema and deterministic in the player's storage key, so a remote
		# player looks the same on every client that draws them — which is the whole
		# reason `stock_avatar` hashes an id rather than picking at random.
		added.attach_body_mesh(
			Color.from_hsv(fmod(float(added.player_id) * 0.37, 1.0), 0.55, 0.85),
			ArenaAvatars.stock_avatar(
				StringName(ArenaGame.storage_key(added.player_id))
			)
		)


## Settings, audio, effects and the console.
func _build_presentation() -> void:
	presentation = ArenaPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	DotLog.result(CHANNEL, "the presentation layer", presentation.setup())

	_wire_chat_window()

	presentation.settings.changed.connect(func(key: StringName, _v: Variant, _w: StringName) -> void:
		# The field of view is the one setting that has to reach something already built.
		# A camera that keeps the value it was created with is exactly the "produced
		# correctly and consumed by nothing" this family keeps finding.
		if key == &"field_of_view" and player != null:
			player.attach_camera(_field_of_view())
	)


func _adopt(candidate: ArenaPlayer) -> void:
	if candidate == null or player != null:
		return

	player = candidate
	_hear_beacon(player)
	# The player's own field of view, capped by whatever the server clamped it to. A
	# server capping it is a legitimate competitive rule; the player's *choice* is what is
	# saved, so leaving the server gives it back rather than editing their settings.
	player.attach_camera(_field_of_view())

	if hud != null:
		hud.follow(player)

	if _sampler != null:
		_sampler.tunables = player.controller.tunables
		# A different tunables object, carrying the default sensitivity again.
		if presentation != null:
			presentation.bind_look(_sampler.tunables)

	_hear_the_local_player()

	# Logged because this is the moment everything a person can see comes into
	# existence — the camera, the HUD's subject and every key below the `player == null`
	# guard. When a client draws a world and shows a dead HUD, this line is what says
	# whether the local player was ever found; without it the two failures look
	# identical from a browser console.
	DotLog.info(CHANNEL, "following the local player", {
		"id": player.player_id,
		"name": player.display_name,
		"health": player.health.health if player.health != null else -1.0,
		"alive": player.is_alive(),
	})


# --- The loop --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	_read_fire(move)

	if _offline:
		if game != null:
			_drive_bots()
			game.tick(_local_commands(move))
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# The clock says how many ticks this frame is worth, which on a client whose engine
	# runs at the server's rate is almost always exactly one.
	var ticks := net.clock.advance(delta)

	for _i in range(ticks):
		if not net.clock.is_synced():
			continue

		var tick := net.clock.input_tick()
		bridge.client_tick(tick, move, _fire)

		if bridge.link != null:
			bridge.link.send_input(bridge.encode_input(tick, move, _fire))


func _local_commands(move: DotFpsCommand) -> Dictionary:
	var out: Dictionary = {}

	if player != null:
		out[player.player_id] = [move, _fire]

	for id in _bots:
		var bot: ArenaPlayer = _bots[id]
		out[int(id)] = [bot.get_meta("bot_move", DotFpsCommand.new()), bot.get_meta("bot_fire", DotWeaponCommand.new())]

	return out


## The bots from `headless_match`, in a client: aim at whoever is nearest and hold the
## trigger. Offline only — a server's bots are the server's.
func _drive_bots() -> void:
	for id in _bots:
		var bot: ArenaPlayer = _bots[id]

		if not bot.is_alive():
			continue

		var nearest: ArenaPlayer = null
		var best := INF

		for other in game.players():
			if other == bot or not other.is_alive():
				continue

			var distance := bot.global_position.distance_to(other.global_position)

			if distance < best:
				best = distance
				nearest = other

		var move := DotFpsCommand.new()
		var fire := DotWeaponCommand.new()

		if nearest != null:
			var to := nearest.global_position - bot.global_position
			move.yaw = rad_to_deg(atan2(-to.x, -to.z))
			move.pitch = 0.0
			move.move = Vector2(0.0, 1.0)
			fire.yaw = move.yaw
			fire.pitch = move.pitch
			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, best < 40.0)

		bot.set_meta("bot_move", move)
		bot.set_meta("bot_fire", fire)


func _process(delta: float) -> void:
	if net != null and not _offline:
		# Once a frame, and it is not optional: `DotNetInterpolator` blends two
		# snapshots perfectly and the result sits in a property nothing reads unless
		# this runs. Remote players otherwise step at the snapshot rate.
		net.interpolate_frame()

	# Where every speaker is, so a proximity voice comes from the player who said it.
	# The server already decided who hears whom by distance; playing the result from
	# nowhere in particular throws away the only thing that made the distance worth
	# computing.
	if extras != null:
		extras.pump_voice(delta)

	if presentation != null:
		# dot-audio culls by distance from the listener and dot-fx ages what it spawned;
		# neither ticks itself, for the reason everything tickable in this family is
		# explicit -- `_process` does not run while a tree is paused, and a pause menu is
		# exactly when nothing finishes.
		var eye := camera_position()
		var forward := Vector3.FORWARD
		if player != null and player.camera != null:
			forward = -player.camera.global_transform.basis.z
		presentation.present(delta, eye, forward)
		_apply_shake()

	# A position report, once a second, for as long as the client has a player.
	#
	# [b]There is no other way to see where a browser client thinks it is.[/b] Every
	# assertion available runs headless and has no camera; a screenshot shows what was
	# drawn and not the number it was drawn from. When a client renders sky in every
	# direction, this is the line that says whether the player is somewhere wrong or
	# the world is somewhere wrong, and those have completely different fixes.
	_report_timer += delta

	if _report_timer >= 1.0 and player != null:
		_report_timer = 0.0
		var st := player.controller.state
		DotLog.info(CHANNEL, "where the local player is", {
			"position": st.position,
			"node": player.global_position,
			"camera": camera_position(),
			"yaw": st.yaw,
			"pitch": st.pitch,
			"grounded": st.is_grounded(),
			"predicted": _is_predicted(),
		})

	if game == null:
		return

	for body in game.players():
		body.present(delta)

	_drive_spectator_camera()


## Where a dead player looks.
##
## [b]Until this existed the camera stayed where the body fell.[/b] That is the one
## thing a first-person game must not do: the corpse is on the floor, so the view is on
## the floor, and the seconds before a respawn are spent looking at a wall from ankle
## height. dot-spectate decides what to look at and the server decides whether it is
## allowed; this is the four lines that put the answer on the camera.
##
## Once a FRAME rather than once a tick, deliberately. A camera moved on the tick
## timeline steps at the tick rate however smoothly the thing it is following is
## interpolated — which is the jitter this family measured at 47% in g2gfast and spent
## a day on.
func _drive_spectator_camera() -> void:
	if game.spectate == null or player == null or player.camera == null:
		return

	var id := player.player_id

	if not game.spectate.is_spectating(id):
		if not player.camera.current:
			player.camera.current = true
		return

	var where := game.spectate.camera_for(id)

	if where == Transform3D.IDENTITY:
		return

	player.camera.global_transform = where


## The fire command, from the keyboard and the mouse.
##
## [b]`DotWeaponCommand` is a button BITMASK, not a set of booleans.[/b] `set_button`
## is the accessor; assigning `.attack` creates nothing and errors at runtime with
## "Invalid assignment of property or key 'attack'". Also the aim, which is read from
## the movement command's angles rather than sampled again — sampling the mouse twice
## gives a shot that leaves at a different angle than the player was looking along.
func _read_fire(move: DotFpsCommand) -> void:
	var firing := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

	_fire.set_button(DotWeaponCommand.BUTTON_ATTACK, firing)
	_fire.set_button(DotWeaponCommand.BUTTON_RELOAD, Input.is_key_pressed(KEY_R))
	_fire.yaw = move.yaw
	_fire.pitch = move.pitch

	# `DotArsenal` reads `command.slot > 0` as "switch to this" and 0 as "leave it
	# alone", so this is a REQUEST that is cleared once made rather than a mirror of
	# the current slot. Reading the arsenal back into the command instead would make
	# every tick a switch to the weapon already held, and `select()` refuses that — so
	# it would have looked like it worked while doing nothing.
	_fire.slot = _wanted_slot
	_wanted_slot = 0


# --- The mouse -------------------------------------------------------------

## Asks a browser for the cursor rather than telling it.
##
## Pointer lock needs **transient user activation** — a real click — and `_ready()` is
## the one moment guaranteed not to have one. A browser refuses it *silently*:
## `Input.mouse_mode` reads back as CAPTURED, the view still turns, and the cursor sits
## on top of the game and wanders out of the window.
func _grab_mouse() -> void:
	if not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_awaiting_click = true

	if hud != null:
		hud.notice("Click to play")



## Puts the drawn level on the layout's `world` layer.
##
## A client draws the level and that is what puts it in the physics space, so the client
## is where its collision layers have to be set — and they have to be the SAME numbers the
## server used, which is why the layout is built on every instance rather than only where
## `apply_physics` is on. See `ArenaPlayerStack._build_physics`.
func _classify_level() -> void:
	if _level == null or game == null or game.player_stack == null:
		return

	var done := game.player_stack.classify_tree(_level, &"world")
	DotLog.debug(CHANNEL, "level classified", {"bodies": done})


func _unhandled_input(event: InputEvent) -> void:
	# [b]The console first, and before the click that captures the mouse.[/b] Without it,
	# a click inside an open console grabs pointer lock and the next keystroke goes to
	# movement -- so typing `noclip` walks the player forward, which is the single most
	# reported bug in every game that ships a console and forgets this line.
	if presentation != null and presentation.swallows_input():
		return

	# Before the `player == null` guard, deliberately. A browser player clicks while
	# the world is still loading more often than not, and a click swallowed for want of
	# a player is a click that never captures anything — after which the only
	# affordance the game offers is one it has already ignored.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and menus.top() == null:
			_awaiting_click = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

			if hud != null:
				hud.notice("")

			return

	if event.is_action_pressed(&"ui_cancel"):
		# Escape RELEASES and does not toggle. Escape is how a browser itself exits
		# pointer lock, and it then refuses to re-enter for about a second — so a
		# toggle bound to it silently does nothing every other press on the web. One
		# key that releases and one gesture that captures is the same contract on
		# every platform.
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			menus.toggle(&"pause")
			_apply_mouse()
		return

	if player == null:
		return

	if event is InputEventMouseMotion:
		if _sampler != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_sampler.handle_event(event)
		return

	if not (event is InputEventKey) or event.is_echo():
		return

	# Push to talk, and it is handled BEFORE the "is this a press" filter above,
	# because a talk key needs the release as much as the press: a key whose release
	# nobody reads is a microphone that never closes.
	if (event as InputEventKey).physical_keycode == KEY_V:
		if extras != null:
			extras.set_talking(event.is_pressed())

		return

	if not event.is_pressed():
		return

	match (event as InputEventKey).physical_keycode:
		KEY_E:
			# Grab, or let go of what is already held. One key for both, because a
			# player who has to remember which of two keys they pressed last is a
			# player holding a crate they cannot put down.
			_ask_prop(
				ArenaEvents.PropAct.RELEASE if _holding
				else ArenaEvents.PropAct.GRAB
			)
			_holding = not _holding
		KEY_F:
			_ask_prop(ArenaEvents.PropAct.FREEZE)
		KEY_G:
			_ask_prop(ArenaEvents.PropAct.PUNT)
			_holding = false
		KEY_1, KEY_2, KEY_3, KEY_4:
			# Requested through the COMMAND, never by calling the arsenal directly.
			# A client that switched its own weapon would be predicting a switch the
			# server never simulated, and the next snapshot would take it back.
			_wanted_slot = (event as InputEventKey).physical_keycode - KEY_1 + 1
		KEY_TAB:
			menus.toggle(&"scoreboard")
		_:
			pass


## The cursor, from one place.
##
## A screen that wants the mouse gets it; otherwise the game does, subject to the
## browser having been clicked at least once.
func _apply_mouse() -> void:
	if menus != null and menus.top() != null:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if _awaiting_click:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Connects the local player's own noises and pictures.
##
## [b]Only the local player's.[/b] Somebody else being hurt is their business: a damage
## tint for every player in the match would be a screen that is permanently red, and a
## shake for somebody else's rifle would make a crowded room unplayable. What everybody
## hears is the positional half -- the shot, the impact -- which comes from the world.
func _hear_the_local_player() -> void:
	if presentation == null or player == null:
		return

	presentation.on_spawned()

	if player.health != null and not player.health.damaged.is_connected(_on_local_damaged):
		player.health.damaged.connect(_on_local_damaged)
		player.health.died.connect(_on_local_died)

	if not player.used.is_connected(_on_local_used):
		# The PREDICTED use, on the client that made it. Waiting for the server's
		# confirmation would put the bang a round trip after the click, which is the one
		# piece of feedback a player judges the whole game's responsiveness by -- and it
		# is safe to predict for exactly the reason dot-fx is built the way it is: a sound
		# never changes the simulation, so a shot the server later refuses cost a noise.
		#
		# ArenaPlayer.used rather than arsenal.used, because ArenaPlayer already forwards
		# it and is the one node this client is handed. Going through the arsenal means
		# reaching two levels into somebody else's addon for a signal the player above it
		# re-emits unchanged.
		player.used.connect(_on_local_used)


## Plays a beacon's ping wherever its ripple goes out, for [param body] — every player,
## this client's own included: somebody who has been beaconed should hear it too.
##
## From both [method _on_player_added] and [method _adopt], because a player found by
## `_watch` is adopted without passing through the first, and the connection is guarded so
## the two never make it twice.
func _hear_beacon(body: ArenaPlayer) -> void:
	if body == null or body.beacon_pulsed.is_connected(_on_beacon_pulsed):
		return

	body.beacon_pulsed.connect(_on_beacon_pulsed)


func _on_beacon_pulsed(at: Vector3) -> void:
	if presentation != null:
		var _voice := presentation.on_beacon(at)


## One tick of weapon use, predicted. An outcome rather than a shot, because a use is
## not always one: a rocket produces a spawn and no shot at all, and a burst produces
## several shots that are all one trigger pull.
func _on_local_used(outcome: DotWeaponOutcome) -> void:
	if presentation == null or outcome == null or not outcome.used:
		return

	for shot in outcome.shots:
		var muzzle := Transform3D.IDENTITY
		muzzle.origin = shot.origin
		# The weapon's id rather than a slot number. A slot is where a player put
		# something; an id is what it is, and a sound catalogue keyed on a slot would
		# play the rifle whenever anybody put a shotgun in slot one.
		var weapon_id: StringName = shot.weapon_id if shot.weapon_id != &"" else &"rifle"
		presentation.on_fired(weapon_id, muzzle, true)

		# Where the pellets landed, from the client's own prediction. Impacts are a list
		# because a shotgun is one shot with several of them, and a single impact sound
		# for eight pellets is a shotgun that sounds like a rifle.
		for at in shot.impacts:
			var hit := Transform3D.IDENTITY
			hit.origin = at
			presentation.on_impact(hit, false)

		if not shot.damages.is_empty():
			presentation.on_hit_confirmed()


func _on_local_damaged(damage: DotDamage) -> void:
	if presentation != null:
		presentation.on_hurt(damage.amount)


func _on_local_died(_damage: DotDamage) -> void:
	if presentation == null or player == null:
		return
	var where := Transform3D.IDENTITY
	where.origin = player.global_position
	presentation.on_died(where)


## Adds the frame's camera shake. dot-fx computes it; this is the only thing that applies it.
##
## Same rule as dot-spectate's camera: one implementation then serves the play rig, a
## spectator's and a headless suite, with no second code path to keep in step.
func _apply_shake() -> void:
	if player == null or player.camera == null or presentation == null:
		return
	# Handed to the player rather than written onto the camera. `ArenaPlayer.present` is
	# the one place the camera's transform is set -- it says so in its own comment -- and a
	# second writer would fight it every frame for the same value.
	player.camera_offset = presentation.camera_shake()
	player.camera_roll = presentation.camera_roll()


## The field of view to use: the player's own, under any cap a server has applied.
func _field_of_view() -> float:
	if presentation == null:
		return FIELD_OF_VIEW
	return float(presentation.settings.get_int(&"field_of_view", int(FIELD_OF_VIEW)))


## Where this client thinks it is, as one line. What the console's `where` prints.
func describe_position() -> PackedStringArray:
	if player == null:
		return PackedStringArray(["no local player yet"])
	var st := player.controller.state
	return PackedStringArray([
		"position %s" % st.position,
		"node     %s" % player.global_position,
		"camera   %s" % camera_position(),
		"yaw %.1f  pitch %.1f  grounded %s" % [st.yaw, st.pitch, st.grounded],
	])


## Where the camera actually is, or the origin when there is none.
func camera_position() -> Vector3:
	return player.camera.global_position if player != null and player.camera != null \
		else Vector3.ZERO


## Whether the local player is dot-net's idea of a predicted entity.
##
## Not the same question as "is it ours". `DotNetIdentity.is_predicted` also requires
## the authority to be SHARED and the owner peer id to match this manager's local one —
## and a client whose local peer id does not match what the server addressed it as gets
## an entity that is neither predicted nor interpolated, which nothing then moves.
func _is_predicted() -> bool:
	if bridge == null or player == null:
		return false

	var behaviour := bridge.behaviour_for(player.player_id)

	return behaviour != null \
		and behaviour.identity != null \
		and behaviour.identity.is_predicted()


func describe() -> Dictionary:
	return {
		"offline": _offline,
		"player": player.player_id if player != null else -1,
		"watching": _watch_id,
		"bots": _bots.size(),
		"net": bridge.describe() if bridge != null else "none",
	}
