class_name ArenaClient
extends Node

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
var _fire := DotCombatCommand.new()

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
	# client is the last clause of dot-fps-controller's own note on it: *it gives the
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
	add_child(_level)
	_light()

	_sampler = DotFpsSampler.new(ArenaPlayer.arena_tunables())
	DotFpsSampler.register_default_actions(_sampler)

	_build_interface()

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
	var pause := ArenaMenus.install(menus, game, _ui_config)

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

		var _unused := pause


# --- Offline ---------------------------------------------------------------

func _start_offline() -> void:
	game.start(0)

	var added := game.add_player(1, "Player")

	if added.ok:
		_adopt(added.value as ArenaPlayer)

	for i in range(offline_bots):
		var bot := game.add_player(100 + i, "Bot %d" % (i + 1))

		if bot.ok:
			var body := bot.value as ArenaPlayer
			body.attach_body_mesh(Color.from_hsv(float(i) / 6.0, 0.55, 0.85))
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
	extras.map_changing.connect(_on_map_changing)
	extras.map_changed.connect(_on_map_changed)

	bridge.hello_received.connect(_on_hello)
	bridge.notice_received.connect(_on_notice)
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
	if _level != null and is_instance_valid(_level):
		remove_child(_level)
		# free(), not queue_free(): the new one goes in on this line and a deferred
		# free would leave two levels drawn over each other for a frame.
		_level.free()

	_level = game.map.to_scene()
	add_child(_level)

	if hud != null:
		hud.notice("Now playing %s." % map.name_or_id())


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

	hud._on_kill(entry)


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

	if player == null and added.player_id == _watch_id:
		_adopt(added)
		return

	if added != player and added.body_mesh == null:
		added.attach_body_mesh(
			Color.from_hsv(fmod(float(added.player_id) * 0.37, 1.0), 0.55, 0.85)
		)


func _adopt(candidate: ArenaPlayer) -> void:
	if candidate == null or player != null:
		return

	player = candidate
	player.attach_camera(FIELD_OF_VIEW)

	if hud != null:
		hud.follow(player)

	if _sampler != null:
		_sampler.tunables = player.controller.tunables

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
		out[int(id)] = [bot.get_meta("bot_move", DotFpsCommand.new()), bot.get_meta("bot_fire", DotCombatCommand.new())]

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
		var fire := DotCombatCommand.new()

		if nearest != null:
			var to := nearest.global_position - bot.global_position
			move.yaw = rad_to_deg(atan2(-to.x, -to.z))
			move.pitch = 0.0
			move.move = Vector2(0.0, 1.0)
			fire.yaw = move.yaw
			fire.pitch = move.pitch
			fire.set_button(DotCombatCommand.BUTTON_ATTACK, best < 40.0)

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


## The fire command, from the keyboard and the mouse.
##
## [b]`DotCombatCommand` is a button BITMASK, not a set of booleans.[/b] `set_button`
## is the accessor; assigning `.attack` creates nothing and errors at runtime with
## "Invalid assignment of property or key 'attack'". Also the aim, which is read from
## the movement command's angles rather than sampled again — sampling the mouse twice
## gives a shot that leaves at a different angle than the player was looking along.
func _read_fire(move: DotFpsCommand) -> void:
	var firing := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

	_fire.set_button(DotCombatCommand.BUTTON_ATTACK, firing)
	_fire.set_button(DotCombatCommand.BUTTON_RELOAD, Input.is_key_pressed(KEY_R))
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


func _unhandled_input(event: InputEvent) -> void:
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
