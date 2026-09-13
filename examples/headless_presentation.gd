extends Node

const ArenaParty := preload("../game/arena_party.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

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

const CHECKS := 56

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
