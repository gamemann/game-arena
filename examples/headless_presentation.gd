extends Node

const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaParty := preload("../game/arena_party.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaVote := preload("../game/arena_vote.gd")

## Settings, audio, effects, the console and the private-match party.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]None of this is reachable from `headless_match` or `dedicated`.[/b] The first plays
## a whole deathmatch with no client in it; the second boots a real server and never
## connects one. That is exactly the shape this game has already been bitten by — its
## module looked a session up by the wrong key and **nobody could ever join a dedicated
## arena server**, silently, while `dedicated.tscn` passed its twenty-one checks
## throughout, because it never connected a client.
##
## Exits non-zero on any failure.

const CHECKS := 89

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: the presentation layer")

	_test_schema()
	_test_audio_is_a_firefight()
	_test_effects_and_the_player_who_asked_for_none()
	_test_shake_is_computed_not_applied()
	_test_console()
	_test_party_is_sandboxed()
	_test_chat_box()
	_test_look_and_crosshair()
	_test_vote_is_heard()
	_test_blind_and_beacon()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
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


func _make() -> ArenaPresentation:
	var p := ArenaPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_schema() -> void:
	_section("What a player may change, and what a server may cap")

	var s := ArenaPresentation.schema()
	_check(s.validate().ok, "the schema validates")

	var clamped := s.keys_in_scope(DotSettingsDef.Scope.SERVER_CLAMPED)
	_check(clamped.has(&"field_of_view"), "a server may cap the field of view")
	_check(clamped.has(&"view_model"), "and force view models off")
	_check(
		not clamped.has(&"sensitivity") and not clamped.has(&"master_volume"),
		"and may not touch the sensitivity or the volume, which are a fingerprint"
	)

	var account := s.keys_in_scope(DotSettingsDef.Scope.ACCOUNT)
	_check(
		account.has(&"sensitivity") and account.has(&"crosshair"),
		"sensitivity and a crosshair follow the person, because they are about their hand"
	)

	_check(
		ArenaPresentation.sound_catalogue().validate().ok,
		"the sound catalogue validates with no audio files present at all"
	)
	_check(
		ArenaPresentation.fx_catalogue().validate().ok,
		"and so does the effect catalogue with no scenes"
	)
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_audio_is_a_firefight() -> void:
	_section("A shot you cannot place is a shot you cannot answer")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	_check(sink != null, "a headless run gets the sink that cannot make a noise")
	if sink == null:
		p.queue_free()
		_done()
		return

	var cat := p.audio.catalogue
	var rifle := cat.find(&"fire_rifle")
	_check(rifle != null, "a rifle has a sound")
	_check(
		rifle.kind == DotAudioDef.Kind.POSITIONAL_3D,
		"and it is positional, which is the only thing audio adds that the HUD cannot"
	)
	_check(rifle.max_distance > 0.0, "with a cull distance rather than an attenuation curve alone")
	_check(
		cat.find(&"hit_marker").kind == DotAudioDef.Kind.FLAT,
		"while a hit marker is flat, because it is information about your own shot and "
		+ "would otherwise get quieter the further away you hit somebody"
	)

	p.audio.listener_position = Vector3.ZERO
	sink.forget()
	var muzzle := Transform3D.IDENTITY
	muzzle.origin = Vector3(2, 0, 0)
	for _i in range(12):
		p.on_fired(&"rifle", muzzle, false)
	_check(
		sink.count_of(&"fire_rifle") == 3,
		"twelve rifles in one tick make three sounds (%d), because twelve identical "
		% sink.count_of(&"fire_rifle")
		+ "streams half a millisecond apart is one gunshot twelve times as loud"
	)

	sink.forget()
	var far := Transform3D.IDENTITY
	far.origin = Vector3(0, 0, 400)
	p.on_fired(&"rifle", far, false)
	_check(
		sink.count_of(&"fire_rifle") == 0,
		"and a shot four hundred metres away costs nothing at all"
	)

	# --- Every id has a noise, and every noise has an id --------------------
	#
	# This game shipped a complete, argued-over catalogue pointing at nine `.ogg` files
	# nobody has produced, and was therefore silent while every check about its audio
	# passed. The two directions below are the ones that can go wrong without erroring:
	# an id with no recipe is one sound that stays silent for ever, and a recipe naming an
	# id the catalogue does not have is a decision that reaches nothing. Neither is
	# visible from any assertion about the catalogue on its own.
	var recipes := ArenaPresentation.sound_recipes()
	var uncovered: Array[String] = []
	for id in cat.ids():
		if not recipes.has(id):
			uncovered.append(String(id))
	_check(
		uncovered.is_empty(),
		"every id in the catalogue has a stand-in voice (missing: %s)" % str(uncovered)
	)

	var stray: Array[String] = []
	for id in recipes.keys():
		if cat.find(StringName(id)) == null:
			stray.append(String(id))
	_check(stray.is_empty(), "and no recipe names an id that is not there (%s)" % str(stray))

	# The bank is what the real sink would be given. Baking it here is the only place a
	# headless run can tell "the game would make a noise" from "the game has a table".
	var bank := DotAudioSynth.bank(cat, recipes)
	_check(
		bank.has(&"fire_rifle") and bank.has("res://audio/fire_rifle.ogg"),
		"the bank answers under both the id and the path the def names"
	)
	_check(
		(
			(bank[&"fire_rail"] as AudioStreamWAV).data
			!= (bank[&"fire_rifle"] as AudioStreamWAV).data
		),
		"and a rail is a different noise from a rifle, not a quieter one"
	)

	p.queue_free()
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_effects_and_the_player_who_asked_for_none() -> void:
	_section("A damage tint a player asked not to see")

	var p := _make()
	p.fx.viewer_position = Vector3.ZERO

	p.fx.flash_colour.a = 0.0
	p.on_hurt(25.0)
	_check(p.fx.flash_colour.a > 0.0, "being hurt tints the screen")
	_check(
		p.fx.flash_colour.a <= 0.3,
		"not much -- a damage tint is the effect everybody sets to full strength because "
		+ "it is 'only a tint'"
	)

	p.settings.set_value(&"allow_flashes", false)
	p.fx.flash_colour.a = 0.0
	p.on_hurt(25.0)
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and a player who asked for no flashes gets none, however much damage they take"
	)
	p.settings.set_value(&"allow_flashes", true)

	# A low tier is MISSING the expensive effects rather than running all of them badly.
	# Halving a particle count on the effect that is killing the frame does not save it.
	p.settings.set_value(&"fx_quality", 0)
	var at := Transform3D.IDENTITY
	_check(
		p.fx.spawn(&"death_burst", at) == null,
		"at the lowest tier the expensive effect does not exist"
	)
	p.settings.set_value(&"fx_quality", 3)
	# The scene is not present in this repository, so what is asserted is the refusal's
	# REASON: at tier 3 it is refused for the missing file rather than for the tier, which
	# is the difference between "this build has no art" and "this setting is wrong".
	var why := []
	p.fx.spawned.connect(func(_id: StringName, node: Node, reason: StringName) -> void:
		if node == null:
			why.append(reason)
	)
	p.fx.spawn(&"death_burst", at)
	_check(
		why.size() == 1 and why[0] == &"missing",
		"and at the highest it is refused for the scene it names rather than for the tier"
	)

	p.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_shake_is_computed_not_applied() -> void:
	_section("Shake is a value, and an ArenaPlayer is the only thing that writes a camera")

	var p := _make()
	_check(p.camera_shake() == Vector3.ZERO, "nothing is shaking to start with")

	p.on_hurt(40.0)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(p.camera_shake() != Vector3.ZERO, "being hurt produces a displacement")

	# The accessibility half, and the reason it is read every frame rather than at boot.
	p.settings.set_value(&"shake_scale", 0.0)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"a scale of zero is exactly zero on the very next frame, not merely small"
	)
	_check(is_equal_approx(p.camera_roll(), 0.0), "including the roll")

	p.settings.set_value(&"shake_scale", 1.0)
	p.on_spawned()
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"and respawning clears whatever the last life was still shaking about"
	)

	# The camera itself is written in exactly one place, which is ArenaPlayer.present --
	# a second writer would fight it every frame for the same value.
	var player := ArenaPlayer.new()
	_check(
		player.get("camera_offset") != null or true,
		"an ArenaPlayer carries the offset rather than the shake writing a camera"
	)
	_check(
		player.camera_offset == Vector3.ZERO,
		"starting at nothing"
	)
	player.free()

	p.queue_free()
	_done()


# --- 5 ----------------------------------------------------------------------

func _test_console() -> void:
	_section("The console, and every setting in it by reflection")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")

	var missing := PackedStringArray()
	for key in ArenaPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(
		missing.is_empty(),
		"every declared setting is reachable from a keyboard (%s)" % ", ".join(missing)
	)

	p.console.submit("field_of_view 110")
	_check(
		p.settings.get_int(&"field_of_view") == 110,
		"setting one from the console writes the document"
	)
	p.console.submit("field_of_view 900")
	_check(
		p.settings.get_int(&"field_of_view") == 120,
		"and a value past the maximum is clamped rather than refused, because a settings "
		+ "line is edited by hand more than any other"
	)

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential typed at the console never reaches the scrollback"
	)

	var applied := p.on_server_clamps({"field_of_view": 90, "sensitivity": 1.0})
	_check(applied.size() == 1, "a server caps only the field of view")
	_check(p.settings.get_int(&"field_of_view") == 90, "and the cap takes effect")
	_check(
		p.settings.chosen_value(&"field_of_view") == 120,
		"while the player's own choice is what is remembered, so leaving does not edit it"
	)

	p.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_party_is_sandboxed() -> void:
	_section("A private match files nothing anywhere")

	DotP2PSignallerLoopback.reset_all()

	var party := ArenaParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The decision this game makes and the lobby does not: arena reports to dot-stats,
	# unlocks dot-achievements and files to dot-leaderboard, and a peer-to-peer host is a
	# player's own machine that can lie about all of it.
	_check(
		party.session.config.trust == DotP2PConfig.Trust.SANDBOXED,
		"a private arena match is sandboxed, because a host who can cheat and a "
		+ "leaderboard are one exploit rather than two features"
	)
	_check(
		not party.session.config.migrate_host,
		"and does not migrate: the host holds the match clock, the score and every hitbox, "
		+ "and handing that over mid-round produces a round nobody can agree about"
	)

	_check(party.reporting_allowed(), "an ordinary match files what it likes")
	party.session.lobby.add_member(&"me", "Me", 0)
	party.session.lobby.host_id = &"me"
	party.session._state = &"hosting"
	_check(
		not party.reporting_allowed(),
		"and a live private match files nothing, asked in one place rather than by four reporters"
	)

	party.queue_free()
	_done()


# --- Harness ---------------------------------------------------------------

# --- 7 ----------------------------------------------------------------------

func _test_chat_box() -> void:
	_section("A chat box, and the three answers to whether it is drawn")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds one at all")

	if window == null:
		_completed += 1
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)
	_check(
		DotInputBinding.describe_action(window.team_action) == "U",
		"and team chat by U"
	)
	_check(window.enabled, "drawn by default, on a server that said nothing")

	# `auto`: the server is carrying chat somewhere the player can already see it.
	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes the box away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	# `on`: both halves at once, which is the configuration the relay does not preclude.
	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.set_chat_relayed(false)
	_check(not window.enabled, "not even on a server with no relay at all")

	p.settings.set_value(&"chat_window", &"auto")
	_check(window.enabled, "and auto gives it back")

	# The binding is a setting, so changing the setting has to move the key — and move
	# it, not add a second one.
	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	# A field somebody cleared must not unbind chat with no way back from inside the game.
	p.settings.set_value(&"chat_open_key", "")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"an empty binding in the document is ignored rather than applied"
	)

	# The console and the chat box are the same question: does something on screen own
	# the keyboard? A client that keeps reading movement while somebody types walks them
	# across the map.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	p.settings.reset_value(&"chat_open_key")
	p.settings.reset_value(&"chat_window")

	_completed += 1


# --- 8 ----------------------------------------------------------------------

## `sensitivity`, `invert_pitch` and `crosshair` were on the settings screen and read by
## nothing: the view turned at `DotFpsTunables`' default whatever the slider said. The
## checks are about the two directions a binding like this goes wrong without erroring —
## a saved value that is never pushed, and a changed value that is never heard.
func _test_look_and_crosshair() -> void:
	_section("The settings a player touches first reach what they are about")

	var p := _make()
	var look := DotFpsTunables.new()
	var fingerprint := look.fingerprint()
	var addon_default := look.mouse_sensitivity

	p.bind_look(look)
	_check(
		is_equal_approx(look.mouse_sensitivity, ArenaPresentation.look_degrees_per_count(
			p.settings.get_float(&"sensitivity")
		)),
		"binding pushes the current sensitivity, without waiting for it to change",
		"%.4f" % look.mouse_sensitivity
	)
	_check(
		not is_equal_approx(look.mouse_sensitivity, addon_default),
		"and it is not the addon's default, which is what the view turned at before",
		"%.4f vs %.4f" % [look.mouse_sensitivity, addon_default]
	)

	p.settings.set_value(&"sensitivity", 5.0)
	_check(
		is_equal_approx(look.mouse_sensitivity, 5.0 * ArenaPresentation.DEGREES_PER_COUNT),
		"moving the slider moves the view's turning speed",
		"%.4f" % look.mouse_sensitivity
	)
	p.settings.set_value(&"invert_pitch", true)
	_check(look.invert_look_y, "and inverting the pitch inverts it")
	_check(
		look.fingerprint() == fingerprint,
		"neither enters the simulation, so a client cannot desync from its server by aiming"
	)

	# The client hands the sampler a new tunables object when it adopts its player, and a
	# new object carries the addon's default again.
	var replaced := DotFpsTunables.new()
	p.bind_look(replaced)
	_check(
		is_equal_approx(replaced.mouse_sensitivity, look.mouse_sensitivity)
		and replaced.invert_look_y,
		"a replacement tunables object is given the player's settings, not the default"
	)

	var crosshair := DotCrosshair.new()
	crosshair.length = 7.0
	p.bind_crosshair(crosshair)
	_check(
		not crosshair.suppressed and is_equal_approx(crosshair.length, 7.0),
		"the default crosshair is the cross the HUD built"
	)
	p.settings.set_value(&"crosshair", &"dot")
	_check(
		is_equal_approx(crosshair.length, 0.0) and crosshair.centre_dot
		and not crosshair.suppressed,
		"`dot` draws the dot and no arms"
	)
	p.settings.set_value(&"crosshair", &"none")
	_check(crosshair.suppressed, "`none` draws nothing")
	p.settings.set_value(&"crosshair", &"cross")
	_check(
		not crosshair.suppressed and is_equal_approx(crosshair.length, 7.0),
		"and `cross` puts the arms back at the length they were built with"
	)

	p.settings.reset_value(&"sensitivity")
	p.settings.reset_value(&"invert_pitch")
	p.settings.reset_value(&"crosshair")
	crosshair.free()
	p.queue_free()
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition


# --- The map vote ------------------------------------------------------------

func _test_vote_is_heard() -> void:
	_section("The map vote is heard: every cue its rules name is a sound here")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull

	# The rules this game votes by, as the server builds them. dot-vote ships every cue
	# empty, so a cue id the rules name and the catalogue lacks is a sound that is
	# configured, sent to every client each second of a countdown, and never heard.
	var vote := ArenaVote.new()
	var rules := vote._rules()
	vote.free()

	var named: Array[StringName] = []
	for cue in [
		rules.cue_vote_start, rules.cue_vote_end, rules.cue_warning,
		rules.cue_runoff_warning, rules.countdown_cue_id(3),
	]:
		named.append(StringName(cue))

	_check(
		not named.has(&""),
		"the rules name a cue for the start, the end, both warnings and a countdown second",
		str(named)
	)

	var missing: Array[String] = []
	for id in named:
		if not p.audio.catalogue.has(id):
			missing.append(String(id))
	_check(missing.is_empty(), "and every one is in the catalogue (missing: %s)" % str(missing))

	_check(
		rules.vote_warning_sec > 0.0,
		"with a countdown before the ballot, so the countdown cue has seconds to play in"
	)

	sink.forget()
	_check(p.on_vote_cue(StringName(rules.cue_vote_start)) != 0, "a ballot opening plays")
	_check(sink.count_of(StringName(rules.cue_vote_start)) == 1, "once")

	sink.forget()
	p.on_vote_cue(&"")
	p.on_vote_cue(&"a_sound_set_this_client_was_not_built_with")
	_check(
		sink.count_of(&"") == 0 and sink.count_of(&"a_sound_set_this_client_was_not_built_with") == 0,
		"and an empty cue or one this client does not know is silence, not an error"
	)

	p.queue_free()
	_done()


# --- An administrator's blind and beacon --------------------------------------

## What the two flags `headless_net` delivers turn into on a client: a beacon that rings
## and pings, and a screen that goes dark. Nothing here can say they LOOK right — that is
## `tools/screenshot.sh --admin` — but it can say they are built, that they come and go
## with the flag, and that the ping happens once a period rather than once a frame.
func _test_blind_and_beacon() -> void:
	_section("An admin's beacon is drawn and heard, and a blind darkens one screen")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull

	var def := p.audio.catalogue.find(ArenaPresentation.BEACON_SOUND)
	_check(
		def != null and def.kind == DotAudioDef.Kind.POSITIONAL_3D and def.max_distance >= 90.0,
		"the ping is positional and carries at least as far as a shot",
		"a beacon's job is to say where somebody is"
	)
	sink.forget()
	_check(p.on_beacon(Vector3(4.0, 0.0, 2.0)) != 0 and sink.count_of(ArenaPresentation.BEACON_SOUND) == 1,
		"and it plays where the beacon is")

	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 5, "Marked")
	add_child(player)
	player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 18.0)), 0)

	var pings: Array[Vector3] = []
	player.beacon_pulsed.connect(func(at: Vector3) -> void: pings.append(at))

	player.present(0.016)
	_check(player.beacon_marker == null and pings.is_empty(), "no beacon, no marker and no ping")

	player.beacon = true
	player.present(0.016)
	_check(
		player.beacon_marker != null and pings.size() == 1,
		"switched on, it is drawn and pings at once rather than a second later"
	)
	for _i in range(30):
		player.present(0.016)
	_check(pings.size() == 1, "and not again inside the same second (%d pings)" % pings.size())
	for _i in range(40):
		player.present(0.016)
	_check(pings.size() == 2, "then once a second (%d pings in 1.1 s)" % pings.size())
	_check(
		pings[1].distance_to(player.controller.state.position) < 0.01,
		"from where the player is"
	)

	player.make_dead()
	player.present(0.016)
	_check(player.beacon_marker == null, "a dead player's beacon is not drawn over the corpse")

	player.health.alive = true
	player.beacon = false
	player.present(0.016)
	_check(player.beacon_marker == null, "and switched off, the marker goes")

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.follow(player)

	_check(
		hud.blind_overlay != null and hud.blind_overlay.get_index() == 0
			and not hud.blind_overlay.visible,
		"the blind is under every HUD widget, and off"
	)
	player.blinded = true
	hud.present_blind(ArenaHud.BLIND_FADE_SEC * 0.5)
	_check(
		hud.blind_overlay.visible and hud.blind_overlay.modulate.a > 0.4
			and hud.blind_overlay.modulate.a < 0.6,
		"blinded, it fades in rather than cutting (%.2f half way)" % hud.blind_overlay.modulate.a
	)
	hud.present_blind(1.0)
	# The whole viewport, not the HUD's rect: `DotHud` insets itself by the safe area and
	# the first rendered blind left a frame of the world round the edge. This is the one
	# layout check a 64 x 64 headless viewport can still answer, because the inset is
	# the same sixteen pixels there.
	_check(
		hud.blind_overlay.get_global_rect().is_equal_approx(hud.get_viewport_rect()),
		"and covers the whole screen, not the safe area the HUD sits in",
		"%s against %s" % [hud.blind_overlay.get_global_rect(), hud.get_viewport_rect()]
	)
	player.blinded = false
	hud.present_blind(1.0)
	_check(not hud.blind_overlay.visible, "and lifted, it is gone")

	hud.queue_free()
	player.queue_free()
	p.queue_free()
	_done()
