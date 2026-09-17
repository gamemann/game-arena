extends Node

const ArenaPaths := preload("arena_paths.gd")

## Settings, audio, effects and a console, on the client.
##
## [b]This is the game where audio was the sharpest gap in the family, and the reason is
## worth writing down:[/b] arena has a camera rig, input sampling, a renderer, a HUD and
## menus, and firing a weapon produced no sound and drew nothing for the gun in your own
## hands. The only feedback was the crosshair and the ammunition counter. What was missing
## was never the files — it was the decision about what is audible, how many at once, how
## loud, and how far away it stops mattering, which is a document.
##
## [b]dot-effects and dot-fx are not the same thing and this game has both.[/b]
## `ArenaEffects` is burning, slows, invulnerability and being down: things that happen
## **over time to an entity** and change the simulation. `ArenaPresentation` is what any
## of that looks like, and **an effect here never changes the simulation** — which is the
## property that lets a frame budget drop one, a quality tier refuse one, and a client
## still downloading its content never see one, with two machines still agreeing about
## everything that matters.

const CHANNEL := "arena.presentation"

const SCHEMA_VERSION := 1

const SOUND_DIR := "res://audio"
static var FX_DIR := ArenaPaths.rebase(ArenaPaths.rebase("res://scenes/fx"))

var settings: DotSettingsManager = null
var audio: DotAudioManager = null
var fx: DotFxManager = null
var console: DotConsoleController = null
var console_panel: DotConsolePanel = null

## The in-game chat box. See [method _build_chat].
var chat_window: DotChatWindow = null

## The client, for the commands that ask it questions.
var client: Node = null

var _layer: CanvasLayer = null
var _chat_layer: CanvasLayer = null

## Whether the server said something else is carrying chat. See [method set_chat_relayed].
var _chat_relayed: bool = false


func setup() -> DotResult:
	var settled := _build_settings()
	if not settled.ok:
		return settled
	var heard := _build_audio()
	if not heard.ok:
		return heard
	var drawn := _build_fx()
	if not drawn.ok:
		return drawn
	var consoled := _build_console()
	if not consoled.ok:
		return consoled
	_build_chat()

	# Every value pushed once, after everything exists. See the same call in the lobby
	# and hungario: the builders read what they need today, and the arrangement rots the
	# moment something reacts to `changed` alone -- because a value loaded from disk has
	# not changed, and the player's saved setting then does nothing until they touch it.
	apply_all()
	return DotResult.success(null)


## Pushes every current setting at whatever reads it.
func apply_all() -> void:
	for key in settings.schema.keys():
		_on_setting_changed(key, settings.get_value(key), &"applied")


# --- Settings ---------------------------------------------------------------

static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"sfx_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"voice_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.boolean(&"push_to_talk", true, &"audio"))

	# ACCOUNT scope: sensitivity is about the person's hand, not about this machine and
	# not about this game. A player who has found their number should never type it twice.
	s.add(DotSettingsDef.number(&"sensitivity", 2.5, 0.05, 20.0, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"invert_pitch", false, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.choice(
		&"crosshair",
		&"cross",
		[&"dot", &"cross", &"circle", &"none"] as Array[StringName],
		&"controls"
	).with_scope(DotSettingsDef.Scope.ACCOUNT))

	# SERVER_CLAMPED, and this is the whole reason that scope exists. A wide field of view
	# is a competitive advantage, so a server capping it is a legitimate rule -- and a
	# server *reading* it, or the bindings, or the audio device, would be assembling a
	# fingerprint that survives a new account and every ban a moderator issues.
	s.add(DotSettingsDef.integer(&"field_of_view", 100, 70, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.boolean(&"view_model", true, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))

	s.add(DotSettingsDef.integer(&"fx_quality", 3, 0, 3, &"video").with_description(
		"A lower tier is missing the most expensive effects, not running all of them badly."
	))

	# Chat. ACCOUNT scope for all three: which key opens chat and whether a player wants
	# the box at all is about the person, not about this machine and not about this game.
	s.add(DotSettingsDef.choice(
		&"chat_window",
		&"auto",
		[&"auto", &"on", &"off"] as Array[StringName],
		&"chat"
	).with_scope(DotSettingsDef.Scope.ACCOUNT).with_description(
		"auto hides the box on a server that is already carrying chat somewhere the "
		+ "player can see it; on always draws it; off never does."
	))
	s.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.binding(&"chat_team_key", "U", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	s.add(DotSettingsDef.number(&"shake_scale", 1.0, 0.0, 2.0, &"accessibility")
		.with_description("Zero turns camera shake off entirely."))
	s.add(DotSettingsDef.boolean(&"allow_flashes", true, &"accessibility")
		.with_description("Off draws no full-screen flashes at all."))
	return s


func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	settings.schema = schema()
	settings.local_store = DotSettingsStoreFile.new("user://arena_settings")
	settings.app_namespace = &"game_arena"
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("the arena's settings")
	settings.changed.connect(_on_setting_changed)
	return DotResult.success(null)


func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	match key:
		&"master_volume":
			audio.mixer.master = float(value)
			audio.mixer.apply_to_buses()
		&"sfx_volume":
			audio.mixer.sfx = float(value)
			audio.mixer.apply_to_buses()
		&"voice_volume":
			audio.mixer.voice = float(value)
			audio.mixer.apply_to_buses()
		&"shake_scale":
			fx.config.shake_scale = float(value)
		&"allow_flashes":
			fx.config.allow_flashes = bool(value)
		&"fx_quality":
			fx.config.quality = int(value)
		&"chat_window":
			_apply_chat_visibility()
		&"chat_open_key":
			_bind_chat(chat_window.open_action if chat_window != null else &"", str(value))
		&"chat_team_key":
			_bind_chat(chat_window.team_action if chat_window != null else &"", str(value))
		_:
			pass


# --- Audio ------------------------------------------------------------------

## What a deathmatch makes a noise about.
##
## Every weapon sound is `POSITIONAL_3D` with a real cull distance, because **a shot you
## cannot hear the direction of is a shot you cannot answer.** That is the one thing audio
## contributes to this game that the HUD cannot, and it is why the listener's position is
## fed every frame rather than the sounds being played flat.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	for id in [&"rifle", &"shotgun", &"rail"]:
		var fire := DotAudioDef.new()
		fire.id = StringName("fire_%s" % id)
		fire.path = "%s/fire_%s.ogg" % [SOUND_DIR, id]
		fire.kind = DotAudioDef.Kind.POSITIONAL_3D
		fire.bus = &"SFX"
		fire.unit_size = 14.0
		# Past this it is not a shot you can act on, and a sound accepted for distance
		# costs a stream, a voice and a position update every frame for as long as it
		# lasts. A sixty-four-player server would otherwise spend the whole pool on
		# gunfire nobody can locate.
		fire.max_distance = 90.0
		# Twelve rifles in one tick is not twelve gunshots -- it is one, twelve times as
		# loud, with comb filtering. Three sounds like a firefight.
		fire.max_concurrent = 3
		fire.priority = 80
		fire.pitch_min = 0.96
		fire.pitch_max = 1.04
		fire.tags = [&"weapon"]
		c.add(fire)

	var impact := DotAudioDef.new()
	impact.id = &"impact"
	impact.path = "%s/impact.ogg" % SOUND_DIR
	impact.kind = DotAudioDef.Kind.POSITIONAL_3D
	impact.bus = &"SFX"
	impact.max_distance = 40.0
	impact.max_concurrent = 4
	impact.priority = 40
	impact.pitch_min = 0.9
	impact.pitch_max = 1.1
	c.add(impact)

	# Flat, not positional, and louder than anything else. A hit marker is information
	# about *your own* shot; putting it in the world would make it quieter the further
	# away you hit somebody, which is exactly backwards.
	var hit := DotAudioDef.new()
	hit.id = &"hit_marker"
	hit.path = "%s/hit.ogg" % SOUND_DIR
	hit.bus = &"UI"
	hit.cooldown_ms = 60
	hit.max_concurrent = 2
	hit.priority = 95
	c.add(hit)

	var hurt := DotAudioDef.new()
	hurt.id = &"hurt"
	hurt.path = "%s/hurt.ogg" % SOUND_DIR
	hurt.bus = &"SFX"
	hurt.cooldown_ms = 180
	hurt.max_concurrent = 1
	hurt.priority = 90
	c.add(hurt)

	var died := DotAudioDef.new()
	died.id = &"died"
	died.path = "%s/died.ogg" % SOUND_DIR
	died.bus = &"SFX"
	died.priority = 100
	c.add(died)

	var spawn := DotAudioDef.new()
	spawn.id = &"spawned"
	spawn.path = "%s/spawn.ogg" % SOUND_DIR
	spawn.bus = &"UI"
	spawn.priority = 60
	c.add(spawn)

	var pickup := DotAudioDef.new()
	pickup.id = &"pickup"
	pickup.path = "%s/pickup.ogg" % SOUND_DIR
	pickup.kind = DotAudioDef.Kind.POSITIONAL_3D
	pickup.bus = &"SFX"
	pickup.max_distance = 30.0
	pickup.max_concurrent = 3
	pickup.priority = 50
	c.add(pickup)

	return c


## Which synthesised voice stands in for each id until real audio is dropped into
## [constant SOUND_DIR].
##
## [b]This game made every audio decision months ago and has been silent anyway.[/b] The
## catalogue above says what a shot is worth, how far away it stops mattering, how many may
## overlap and what loses to what — and every one of its paths names an `.ogg` that nobody
## has produced, so firing has had no sound at all. The crosshair and the ammunition
## counter were the only feedback in a game whose whole argument for positional audio is
## that a shot you cannot hear the direction of is a shot you cannot answer.
##
## [b]A table rather than a guess inside dot-audio.[/b] Which noise belongs to which id is
## this game's decision, the same way the distances above are — an addon that inferred
## "rail sounds tonal" from an id called `fire_rail` would be an addon guessing at
## vocabulary it does not own.
##
## The three weapons deliberately get three DIFFERENT voices. A rail that is a quieter
## rifle is the one thing weapon audio must not be: the point of hearing somebody else's
## shot is knowing what they are holding before you come round the corner.
static func sound_recipes() -> Dictionary:
	return {
		&"fire_rifle": DotAudioSynth.Voice.SHOT,
		&"fire_shotgun": DotAudioSynth.Voice.SHOT_HEAVY,
		&"fire_rail": DotAudioSynth.Voice.SHOT_TIGHT,
		&"impact": DotAudioSynth.Voice.IMPACT,
		&"hit_marker": DotAudioSynth.Voice.BLIP,
		&"hurt": DotAudioSynth.Voice.HURT,
		&"died": DotAudioSynth.Voice.DIE,
		&"spawned": DotAudioSynth.Voice.SPAWN,
		&"pickup": DotAudioSynth.Voice.PICKUP,
	}


func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	audio.mixer.sfx = settings.get_float(&"sfx_volume", 1.0)
	audio.mixer.voice = settings.get_float(&"voice_volume", 1.0)
	# A firefight is the busiest this game gets and thirty-two is what it needs; past
	# that the pool is holding sounds nobody can pick out of the mix.
	audio.voices = 32
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("the arena's audio")

	# Only on a real sink, and only after setup: the manager decides whether there is a
	# device, and on a headless server there is nothing to bake for. Building the bank
	# anyway would be a few hundred milliseconds of arithmetic per dedicated server
	# startup for streams no process on that machine can play.
	var godot_sink := audio.sink as DotAudioSinkGodot
	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(audio.catalogue, sound_recipes())
		DotLog.info(
			CHANNEL,
			"no audio files; synthesised stand-ins are in use",
			{"ids": sound_recipes().size(), "dir": SOUND_DIR}
		)

	return DotResult.success(null)


# --- Effects ----------------------------------------------------------------

static func fx_catalogue() -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var muzzle := DotFxDef.new()
	muzzle.id = &"muzzle_flash"
	muzzle.scene_path = "%s/muzzle_flash.tscn" % FX_DIR
	muzzle.lifetime_ms = 90
	muzzle.cost = 1
	muzzle.priority = 85
	muzzle.max_distance = 90.0
	muzzle.max_concurrent = 8
	c.add(muzzle)

	var spark := DotFxDef.new()
	spark.id = &"impact_spark"
	spark.scene_path = "%s/impact_spark.tscn" % FX_DIR
	spark.lifetime_ms = 500
	spark.cost = 2
	spark.priority = 45
	spark.max_distance = 60.0
	# The expensive half of a firefight, and the first thing a low tier should not have.
	spark.min_quality = 1
	c.add(spark)

	var hole := DotFxDef.new()
	hole.id = &"bullet_hole"
	hole.kind = DotFxDef.Kind.DECAL
	hole.scene_path = "%s/bullet_hole.tscn" % FX_DIR
	# Ten minutes, and the ring is what actually bounds it. A decal list that grows with
	# the *round* rather than with the players is invisible in testing and fatal at
	# minute forty.
	hole.lifetime_ms = 600000
	hole.cost = 1
	hole.priority = 20
	hole.max_distance = 50.0
	hole.min_quality = 1
	c.add(hole)

	var gib := DotFxDef.new()
	gib.id = &"death_burst"
	gib.scene_path = "%s/death_burst.tscn" % FX_DIR
	gib.lifetime_ms = 1500
	gib.cost = 12
	gib.priority = 70
	gib.max_distance = 80.0
	gib.min_quality = 2
	c.add(gib)

	var hurt := DotFxDef.new()
	hurt.id = &"hurt_flash"
	hurt.kind = DotFxDef.Kind.SCREEN
	# Low, and it still goes through the player's own off switch and the three-a-second
	# rate limit. A damage tint is the effect everybody sets to full strength because it
	# is "only a tint", and a full-screen flash at high frequency is a hazard.
	hurt.flash_peak = 0.28
	hurt.flash_colour = Color(0.85, 0.12, 0.12)
	hurt.flash_decay_ms = 260
	c.add(hurt)

	var shake := DotFxDef.new()
	shake.id = &"hurt_shake"
	shake.kind = DotFxDef.Kind.SHAKE
	shake.shake_trauma = 0.35
	c.add(shake)

	var big_shake := DotFxDef.new()
	big_shake.id = &"death_shake"
	big_shake.kind = DotFxDef.Kind.SHAKE
	big_shake.shake_trauma = 0.7
	c.add(big_shake)

	return c


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.quality = settings.get_int(&"fx_quality", 3)
	fx.config.shake_scale = settings.get_float(&"shake_scale", 1.0)
	fx.config.allow_flashes = settings.get_bool(&"allow_flashes", true)
	fx.config.max_decals = 192
	add_child(fx)

	var res := fx.setup()
	if not res.ok:
		return res.wrap("the arena's effects")
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

func _build_console() -> DotResult:
	console = DotConsoleController.new()
	console.name = "Console"
	console.config = DotConsoleConfig.new()
	console.config.mirror_log = true
	console.config.mirror_from = DotLog.Level.INFO
	add_child(console)

	var res := console.setup()
	if not res.ok:
		return res.wrap("the arena's console")

	console.add_source(_local_commands())

	var server: Object = DotRegistry.get_service(&"dot_server")
	if server != null and server.get("console") != null:
		console.add_source(DotConsoleBridge.wrap(server.get("console"), "server"))

	_layer = CanvasLayer.new()
	_layer.name = "ConsoleLayer"
	_layer.layer = 128
	add_child(_layer)

	console_panel = DotConsolePanel.new()
	console_panel.name = "ConsolePanel"
	console_panel.controller = console
	_layer.add_child(console_panel)
	return DotResult.success(null)


# --- Chat -------------------------------------------------------------------

## The box a player types in, and the three settings that decide it.
##
## [b]Why this game had none.[/b] arena could receive a chat line and could not send one:
## [code]DotChatClient[/code] held the history, the HUD drew the notice, and there was no
## key anywhere that opened anything to type in. The note this replaces called that "a
## level of ambition rather than an oversight" on the grounds that a scrolling window with
## an input field is a screen — but it is not a screen. A screen is modal and takes the
## whole display; a chat box is eight lines in a corner that has to leave the game
## visible behind it, which is why it is a HUD widget and why it lives here beside the
## console rather than in [DotScreenStack].
##
## [b]Below the console, above everything else.[/b] Both can be open; the console is the
## one that must be on top, because it is what an operator opens when the rest of the
## screen is misbehaving.
func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 100
	add_child(_chat_layer)

	chat_window = DotChatWindow.new()
	chat_window.name = "ChatWindow"
	chat_window.open_action = &"arena_chat"
	chat_window.team_action = &"arena_chat_team"
	# Flush with the left edge the health and armour bars use, and lifted clear of them.
	# `ArenaHud` puts health at 96 pixels off the bottom and armour at 56; a box at the
	# default inset draws its log straight through both, which is the kind of thing only a
	# rendered frame says.
	chat_window.margin_left = 24.0
	chat_window.margin_bottom = 110.0
	chat_window.channels = [
		{"id": &"all", "label": "Say", "colour": Color(0.88, 0.90, 0.94)},
		{"id": &"team", "label": "Say (TEAM)", "colour": Color(0.55, 0.85, 0.60), "team": true},
	]
	_chat_layer.add_child(chat_window)


## Puts one binding from the settings document onto its action.
##
## Empty is left alone rather than applied: a settings file somebody cleared the field in
## would otherwise unbind chat with no way to get it back from inside the game.
func _bind_chat(action: StringName, text: String) -> void:
	if action == &"" or text.strip_edges() == "":
		return

	var bound := DotInputBinding.apply(action, text)

	if bound == "":
		DotLog.warn(CHANNEL, "a chat key was not understood", {
			"action": String(action), "binding": text
		})


## The server said whether anything else is carrying this conversation.
##
## Called by [ArenaClient] when the state payload arrives, and again if a relay comes up
## or goes down mid-match.
func set_chat_relayed(relayed: bool) -> void:
	if _chat_relayed == relayed:
		return

	_chat_relayed = relayed
	_apply_chat_visibility()


## Resolves the three-way setting against what the server said.
##
## [b]`auto` is the only interesting value.[/b] `on` is a player who wants the box wherever
## they are, which is also how both halves run at once — a relayed server AND a chat box in
## front of the game. `off` is a player who chats somewhere else entirely. `auto` says: draw
## it unless this server is already putting these lines somewhere this player can see, which
## is the web client embedded in a page whose room is the other end of the relay.
##
## In every case the log keeps drawing what other people said. Turning the box off is
## "you type somewhere else", never "you are out of the conversation".
func _apply_chat_visibility() -> void:
	if chat_window == null or settings == null:
		return

	match StringName(str(settings.get_value(&"chat_window"))):
		&"on":
			chat_window.enabled = true
		&"off":
			chat_window.enabled = false
		_:
			chat_window.enabled = not _chat_relayed


func _local_commands() -> DotConsoleLocal:
	var local := DotConsoleLocal.new()

	local.add_command(&"help", "List what this client can do", func(_a: PackedStringArray) -> Variant:
		var lines := PackedStringArray(["Client commands:"])
		for n in console.all_names():
			lines.append("  %-20s %s" % [n, console.help_for(n)])
		return lines
	)
	local.add_command(&"quit", "Leave the match", func(_a: PackedStringArray) -> Variant:
		get_tree().quit()
		return null
	)
	local.add_command(&"settings", "Show every setting", func(_a: PackedStringArray) -> Variant:
		return settings.describe_lines()
	)
	local.add_command(&"audio", "Show the audio system", func(_a: PackedStringArray) -> Variant:
		return audio.describe_lines()
	)
	local.add_command(&"fx", "Show the effects system", func(_a: PackedStringArray) -> Variant:
		return fx.describe_lines()
	)
	local.add_command(&"clear", "Empty the scrollback", func(_a: PackedStringArray) -> Variant:
		console.buffer.clear()
		return null
	)
	local.add_command(&"where", "Where this client thinks it is", func(_a: PackedStringArray) -> Variant:
		# The one thing no assertion and no screenshot can give you, and the reason
		# ArenaClient already logs a position once a second: when a browser client draws
		# sky in every direction, "the player is somewhere wrong" and "the world is
		# somewhere wrong" look identical and have completely different fixes.
		if client == null or not client.has_method("describe_position"):
			return "no client"
		return client.call("describe_position")
	)

	for key in settings.schema.keys():
		var def := settings.schema.find(key)
		local.bind_setting(key, settings, def.description if def != null else "")

	return local


# --- What the game asks for -------------------------------------------------

## Once a frame, with where the camera is and which way it is looking.
func present(delta: float, eye: Vector3, forward: Vector3) -> void:
	audio.listener_position = eye
	fx.viewer_position = eye
	fx.viewer_forward = forward
	fx.advance(delta)


## The camera offset to add this frame, which the rig applies and this does not.
##
## dot-spectate's rule: it computes a transform and touches no camera. One implementation
## then serves the play rig, a spectator's, and a headless suite with no camera at all.
func camera_shake() -> Vector3:
	return fx.shake.offset()


func camera_roll() -> float:
	return fx.shake.roll()


## Whether something on screen owns the keyboard right now.
##
## [b]The chat box belongs here for the reason the console does.[/b] A client that keeps
## reading movement while somebody types walks them across the map, and "typing `noclip`
## walks the player forward" is the single most reported bug in every game that ships a
## console and forgets this line. Chat is the same bug with a much wider audience: the
## console is a thing a few people open, and chat is a thing everybody uses.
func swallows_input() -> bool:
	if console_panel != null and console_panel.has_keyboard_focus():
		return true

	return chat_window != null and chat_window.is_open()


# --- The events a deathmatch has -------------------------------------------

func on_fired(weapon_id: StringName, muzzle: Transform3D, mine: bool) -> void:
	audio.play_at(StringName("fire_%s" % weapon_id), muzzle.origin)
	fx.spawn(&"muzzle_flash", muzzle)
	if mine:
		# Only your own weapon kicks the camera. Somebody else's rifle going off beside
		# you is a sound and a flash; shaking for it would make a crowded room unplayable.
		fx.shake.add(0.08)


func on_impact(at: Transform3D, on_player: bool) -> void:
	audio.play_at(&"impact", at.origin)
	fx.spawn(&"impact_spark", at)
	if not on_player:
		# Decals go on the world and not on people. A decal parented to something that
		# moves is a hole that walks away, and a decal on a body that is about to be
		# freed is a decal freed with it -- which reads as decals that flicker.
		fx.spawn_decal(&"bullet_hole", at)


func on_hit_confirmed() -> void:
	audio.play(&"hit_marker")


func on_hurt(_amount: float) -> void:
	audio.play(&"hurt")
	fx.flash(&"hurt_flash")
	fx.spawn(&"hurt_shake", Transform3D.IDENTITY)


func on_died(where: Transform3D) -> void:
	audio.play(&"died")
	fx.spawn(&"death_burst", where)
	fx.spawn(&"death_shake", Transform3D.IDENTITY)


func on_spawned() -> void:
	audio.play(&"spawned")
	# Everything from the previous life goes. A decal ring that survives a death is one
	# that survives a map change, which is a hole in a wall that no longer exists.
	fx.shake.reset()


func on_pickup(at: Vector3) -> void:
	audio.play_at(&"pickup", at)


## A map changed. Everything drawn for the old one is meaningless now.
func on_map_changed() -> void:
	fx.clear()


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("the arena's presentation layer")
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	out.append_array(fx.describe_lines())
	out.append_array(console.describe_lines())

	if chat_window != null:
		out.append("chat box: %s" % str(chat_window.describe()))

	return out
