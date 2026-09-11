extends Node

## The player stack, run against a real arena rather than against a stub.
##
## [codeblock]
## godot --headless --path . res://examples/headless_stack.tscn
## [/codeblock]
##
## [b]Every addon under here passes its own suite with the others absent, and this is
## the only place the joins run.[/b] That is `headless_match.tscn`'s argument and it
## applies one layer up: a roster that stays in step with a match nobody is running is
## a roster nothing has tested, and the failures in a join are never in either half.
##
## What it checks is the six things that can only be wrong at the seam: that joining a
## game files a roster row, that the side dot-match chose is the side dot-team holds,
## that a kill marks somebody dead in both, that a spawn honours a pending class, that
## leaving holds a seat rather than dropping it, and that the physics profile is the
## game's tick rate rather than the preset's.

const TICK_RATE := 64
const BOTS := 4

const SECTIONS := 6
const CHECKS := 54

var _passed := 0
var _failed := 0
var _section_count := 0

var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("arena player stack")
	_line("")

	if not _build():
		get_tree().quit(1)
		return

	_test_physics()
	_test_joining()
	_test_sides()
	_test_life_and_death()
	_test_classes_and_spawns()
	_test_leaving()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _build() -> bool:
	_game = ArenaGame.new()
	_game.tick_rate = TICK_RATE
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	_game.mode_id = &"tdm"
	add_child(_game)

	var res := _game.setup()

	if not res.ok:
		_line("  FAIL  the game did not set up: %s" % res.error.message)
		return false

	if _game.player_stack == null:
		_line("  FAIL  the game set up without a player stack")
		return false

	# Players before start, and the warm-up shortened: dot-match queues a respawn for
	# anybody present when the round goes live, and a player added afterwards waits for
	# the next round. headless_match.gd does the same in the same order.
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0

	for i in range(BOTS):
		var added := _game.add_player(i + 1, "bot%d" % (i + 1))
		if not added.ok:
			_line("  FAIL  bot %d did not join: %s" % [i, added.error.message])
			return false

	_game.start(0)
	return true


func _stack() -> ArenaPlayerStack:
	return _game.player_stack


## A living player on a different side from [param id], or 0.
func _enemy_of(id: int) -> int:
	var teams := _stack().teams

	for other in _game.player_ids():
		if other != id and teams.are_enemies(str(id), str(other)):
			return other

	return 0


# --- Physics ----------------------------------------------------------------

func _test_physics() -> void:
	_section("physics")

	var physics := _stack().physics
	_check(physics != null, "the stack applied a physics profile")
	_check(physics.is_applied(), "and it took")
	_check(
		physics.profile.tick_rate == TICK_RATE,
		"at the GAME's tick rate (%d), not the preset's — two numbers meaning 'how "
		% physics.profile.tick_rate
		+ "often the world advances' is a physics world running at twice the rate of "
		+ "every player"
	)
	_check(
		Engine.physics_ticks_per_second == TICK_RATE,
		"and Engine agrees, which is the one the running process reads"
	)
	_check(physics.layout != null, "there is a collision layout")
	_check(
		physics.layout.has_layer(&"hitbox") and physics.layout.layer(&"hitbox").query_only,
		"with a query-only hitbox layer, which is what lets a rewound trace hit shapes "
		+ "nothing rests on"
	)
	_check(physics.surfaces != null, "and a surface table")
	_check(physics.query().layout == physics.layout, "and it hands out a bound query")


# --- Joining ----------------------------------------------------------------

func _test_joining() -> void:
	_section("joining")

	var roster := _stack().roster
	_check(roster.count() == BOTS, "every bot that joined the game is in the roster")
	_check(roster.connected_count() == BOTS, "and connected")
	_check(roster.has_player("1"), "by the key the game uses")
	_check(
		roster.get_record("1").display_name == "bot1",
		"carrying the name the game gave them"
	)
	_check(
		roster.get_record("1").peer_id == 1,
		"and the peer, so a packet can be traced back to a row"
	)
	_check(not roster.is_full(), "and the session is not full")
	_check(
		roster.alive_count() == 0,
		"and nobody is in the world before the match has ticked once"
	)

	var classes := _stack().classes
	_check(classes.keys().size() == BOTS, "and each of them has a class")
	_check(
		classes.class_of("1") == &"default",
		"the arena's single class — a catalogue with one entry is how 'no classes' is "
		+ "said without every consumer branching on whether classes exist"
	)


func _test_sides() -> void:
	_section("sides")

	var teams := _stack().teams
	_check(teams.keys().size() == BOTS, "everybody is on a side")

	var mismatched := 0

	for id in _game.player_ids():
		var key := str(id)
		var side := _stack()._side_of_id(_game.team_of(id))

		if side != &"" and teams.team_of(key) != side:
			mismatched += 1

	_check(
		mismatched == 0,
		"and it is the side dot-match assigned, not one dot-team picked — the arena's "
		+ "sides come from a balance dot-match does and a map's per-side spawn tags, "
		+ "and driving that from outside would mean reimplementing both"
	)

	_check(
		teams.are_enemies("1", "2") or teams.are_allies("1", "2"),
		"two players are either enemies or allies, never neither"
	)
	_check(not teams.are_enemies("1", "1"), "and nobody is their own enemy")
	_check(
		teams.teams.has_team(DotTeamSet.SPECTATOR),
		"a spectator side exists, which dot-match has no notion of at all"
	)

	var spectate := _stack().spectate
	_check(spectate != null, "and the spectate bridge is up")
	_check(spectate.team_index(&"blue") == 1, "with the named sides mapped to numbers")
	_check(
		spectate.team_index(DotTeamSet.SPECTATOR) == 0,
		"and the spectator side to zero, which is what dot-spectate means by no team"
	)
	_check(not spectate.is_spectating("1"), "and nobody is watching while alive")


# --- Life and death ---------------------------------------------------------

func _test_life_and_death() -> void:
	_section("life and death")

	var roster := _stack().roster

	# Run until the match has put everybody in the world.
	for i in range(TICK_RATE * 8):
		_game.tick({})
		if roster.alive_count() >= BOTS:
			break

	_check(
		roster.alive_count() == BOTS,
		"and the roster follows the match into the world (%d of %d)"
		% [roster.alive_count(), BOTS]
	)
	_check(
		roster.get_record("1").spawn_count >= 1,
		"counting the spawn, so nothing else has to keep its own counter"
	)
	_check(roster.alive_keys().size() == BOTS, "with the living listed")

	var victim := _game.player_for(1)
	_check(victim != null and victim.is_alive(), "a bot is alive to be killed")

	# Past the spawn protection the match grants. Killing inside it is refused, and the
	# refusal would read as the roster not hearing about a death rather than as a kill
	# that never happened.
	for i in range(_game.match_node.spawn_protection_ticks() + 2):
		_game.tick({})

	# An attacker on the OTHER side. This is a team mode, so a team-mate's damage is
	# filtered by dot-combat's friendly-fire rules and the victim would survive — which
	# would look like the roster not hearing about a death rather than like a kill that
	# never happened.
	var attacker := _enemy_of(1)
	_check(attacker > 0, "with somebody on the other side to do it")

	var damage := DotDamage.make(attacker, 1, 1000.0, DotDamageType.make(&"generic"))
	damage.tick = _game.current_tick()
	var _applied := _game.combat.apply_damage(damage)
	_game.tick({})

	_check(not victim.is_alive(), "and enough damage kills them")

	_check(
		not roster.get_record("1").alive,
		"the roster hears about it — one row, rather than the four dictionaries that "
		+ "agree until somebody reconnects"
	)
	_check(roster.get_record("1").death_count >= 1, "and counts the death")
	_check(
		_stack().spawns.respawn_pending("1"),
		"and dot-spawn has a respawn queued for them"
	)


func _test_classes_and_spawns() -> void:
	_section("classes and spawns")

	var classes := _stack().classes
	var landed: Array = []
	_stack().class_applied.connect(func(id: int, class_id: StringName) -> void:
		landed.append([id, String(class_id)])
	)

	_check(classes.options_for("1").size() == 1, "a class screen has one option here")
	_check(bool(classes.options_for("1")[0]["available"]), "and it is available")

	# Wait for the respawn dot-match queued.
	for i in range(TICK_RATE * 8):
		_game.tick({})
		if _stack().roster.get_record("1").alive:
			break

	_check(_stack().roster.get_record("1").alive, "the dead bot comes back")
	_check(
		landed.size() >= 1,
		"and the spawn ran the class through the stack, so a pending change would have "
		+ "landed on it rather than mid-fight"
	)

	var spawns := _stack().spawns
	_check(spawns.sites().size() > 0, "the spawn director read the map's points")
	_check(
		spawns.sites().size() == _game.match_node.spawn_points().size(),
		"all of them — two systems reading one set of markers is fine, two systems "
		+ "owning two sets is a map that spawns people differently depending on which "
		+ "was asked"
	)

	var choice := _stack().choose_spawn(1)
	_check(choice.ok, "and the richer selector can be asked for a place")
	_check(
		(choice.value as DotSpawnChoice).site != null,
		"and answers with a site"
	)
	_check(
		not (choice.value as DotSpawnChoice).fell_back,
		"without having to compromise, which would mean the map's conditions and the "
		+ "mode's rules disagree"
	)

	_check(
		_stack().describe_lines().size() > 10,
		"and the whole stack describes itself for a console command or a bug report"
	)
	_check(int(_stack().describe().get("players", 0)) == BOTS, "briefly, too")


func _test_leaving() -> void:
	_section("leaving")

	var roster := _stack().roster
	var teams := _stack().teams

	_game.remove_player(4)

	_check(
		roster.has_player("4"),
		"a player who leaves keeps their seat — an arena player who drops mid-match "
		+ "and comes back inside the window keeps their score, and the roster is the "
		+ "only thing here that can offer that"
	)
	_check(not roster.get_record("4").connected(), "marked as disconnected")
	_check(roster.connected_count() == BOTS - 1, "and out of the connected count")
	_check(not roster.get_record("4").alive, "and out of the world")
	_check(not teams.has_player("4"), "their side is given up immediately")
	_check(
		not _stack().spawns.respawn_pending("4"),
		"and their respawn is cancelled, so nothing tries to put a departed player back"
	)

	# The window expiring.
	var window := roster.config.reconnect_window_ticks()
	for i in range(4):
		_stack().tick(_game.current_tick() + window + i)

	_check(
		not roster.has_player("4"),
		"and the seat is freed once the window is up — a window only checked when "
		+ "somebody tries to rejoin is a window that never expires"
	)
	_check(roster.count() == BOTS - 1, "leaving the roster the right size")

	_game.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
