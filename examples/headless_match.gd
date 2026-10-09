extends Node

const ArenaBoards := preload("../game/arena_boards.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaEffects := preload("../game/arena_effects.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaHorde := preload("../game/arena_horde.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMapSurvey := preload("../maps/arena_map_survey.gd")
const ArenaMenus := preload("../game/arena_menus.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaNpcs := preload("../game/arena_npcs.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaProjectiles := preload("../game/arena_projectiles.gd")
const ArenaProps := preload("../game/arena_props.gd")
const ArenaStats := preload("../game/arena_stats.gd")
const ArenaVote := preload("../game/arena_vote.gd")

## A whole deathmatch, played out headlessly, with nothing called by hand.
##
## [codeblock]
## godot --headless --path . res://examples/headless_match.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## [b]This is the only place the six addons meet.[/b] dot-player-controller, dot-combat,
## dot-loadout, dot-match, dot-core and the map all pass their own suites in isolation;
## every one of those suites runs one addon with the others absent. What this runs is
## the joins: a movement state feeding a spread cone, a combat kill becoming a match
## score, a match respawn becoming a loadout, an item id becoming a weapon.
##
## dot-platform's own notes make the case better than this comment can: **a code path
## only one deployment shape reaches is a code path nothing has run**, and every bug
## found in this family so far was found by running something rather than by reading
## it.
##
## Four bots, no netcode, no rendering. They aim at whoever is nearest and hold the
## trigger, which is enough to produce kills, deaths, respawns, blocked shots and a
## match that ends on its score limit.

const TICK_RATE := 64
const BOTS := 4
const SCORE_LIMIT := 6

## Enough ticks for six kills at arena pace. Bounded rather than "until it ends", so a
## match that never ends fails the test instead of hanging the run.
const MAX_TICKS := 64 * 90

const CHECKS := 513

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 33

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _game: ArenaGame = null

## Observations gathered while the match runs.
##
## Arrays rather than counters: a GDScript lambda captures locals by value, so an int
## incremented inside a signal handler stays zero outside it — and the assertion then
## reports a failure for a signal that fired perfectly.
var _kills: Array[DotKillFeed.Entry] = []

## The map vote riding along on the real match: what state the match was in, and what the
## leader had, each time a ballot opened. See [method _build_vote].
var _vote: ArenaVote = null
var _vote_seen: Array = []
var _spawns: Array[int] = []
var _states: Array[String] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena headless match")
	print("")

	_test_content()
	_test_map()
	_test_pit()
	await _test_atrium()
	_test_bot_ground_speed()
	_test_reach()
	_test_survey()
	await _test_crate_climb()
	await _test_box_upper()
	_test_modes()
	await _test_team_deathmatch()
	await _test_zee_weapons()

	await _build()
	_build_vote()
	_test_players_exist()
	await _play()
	_test_outcome()
	_test_score_vote()
	await _test_progression()
	_test_geometry_held()
	_test_interface()

	await _test_horde()
	await _test_siege()

	await _test_effects()
	await _test_spectating()
	await _test_ffa_spawn_sides()
	await _test_king_of_the_hill()
	await _test_capture_the_flag()
	await _test_drops()
	await _test_weapon_modes()
	await _test_lag_compensation()
	await _test_streaks()

	# Last, and it has to be. It replaces the combat manager, the match node and the
	# map, so everything above that reads any of them — the kill feed a HUD catches
	# up on, the geometry the shot-blocking check traces against — must already have
	# run. Putting it earlier failed exactly one assertion, four sections later, about
	# a HUD that was working perfectly.
	await _test_map_change()

	if _game != null:
		_game.queue_free()
		remove_child(_game)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
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


# --- Modes -----------------------------------------------------------------

## The catalogue, and the one disagreement a mode can have with itself.
func _test_modes() -> void:
	_section("modes")

	var ids := ArenaModes.ids()
	_check(ids.size() >= 2, "the catalogue has modes", str(ids))

	for mode in ArenaModes.all():
		_check(mode.validate().ok, "%s validates" % mode.id, str(mode.validate().error))

	# Every call must build a fresh resource. If the catalogue handed out one shared
	# object, a server that raised a score limit would have edited the mode every later
	# match reads -- the Resource-is-a-reference aliasing this tree has shipped four
	# times, and the reason ArenaGame duplicates the rules as well.
	var first := ArenaModes.by_id(&"ffa")
	var second := ArenaModes.by_id(&"ffa")
	first.rules.score_limit = 999
	_check(
		second.rules.score_limit != 999,
		"two lookups are not the same object",
		"second read %d" % second.rules.score_limit
	)

	_check(ArenaModes.by_id(&"nonsense") == null, "an unknown id is null")
	_check(
		ArenaModes.by_id_or_default(&"nonsense").id == &"ffa",
		"and falls back rather than failing to boot"
	)

	# team_count and rules.team_based are two statements of one fact, and validate()
	# exists to catch them disagreeing. A mode claiming two sides over free-for-all
	# rules puts nobody on a team and scores everyone individually while calling itself
	# Team Deathmatch -- correct at every point inside dot-match, and wrong.
	var broken := ArenaMode.team_deathmatch()
	broken.rules.team_based = false
	_check(not broken.validate().ok, "a mode that disagrees with its rules is refused")
	_done()


## Two sides, tagged spawns, and a friendly-fire rule that protects somebody.
func _test_team_deathmatch() -> void:
	print("")
	_section("team deathmatch")

	var game := ArenaGame.new()
	game.name = "TeamGame"
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	_check(ready.ok, "a team game sets up", str(ready.error))

	if not ready.ok:
		game.queue_free()
		remove_child(game)
		return

	game.start(0)

	_check(game.teams().size() == 2, "with two sides", str(game.teams().size()))

	# The tags are what send a side to its own end. Without them dot-match falls back
	# to the shared pool and both sides spawn out of one -- which on a symmetric map
	# means spawning in the enemy base about half the time, and reads as a
	# spawn-selection bug rather than as a map nobody tagged.
	var tagged := 0

	for point in game.match_node.spawn_points():
		if point.tags.size() > 0:
			tagged += 1

	_check(tagged > 0, "the map's spawns carry team tags", "%d tagged" % tagged)

	# Six players, and dot-match decides the sides. Asserting the COUNTS rather than
	# any one assignment: `DotTeamManager.assign` balances, so which side a given
	# player lands on is its business and not a thing to pin.
	var counts := {}

	for index in range(6):
		var added := game.add_player(200 + index, "Team %d" % index)
		_check(added.ok, "player %d joins" % index, str(added.error))

		var side := game.team_of(200 + index)
		counts[side] = int(counts.get(side, 0)) + 1

	_check(not counts.has(0), "everybody got a side", str(counts))
	_check(counts.size() == 2, "spread across both", str(counts))

	var sizes: Array[int] = []

	for side in counts:
		sizes.append(int(counts[side]))

	_check(
		abs(sizes[0] - sizes[1]) <= 1,
		"and the sides are balanced",
		"%d vs %d" % [sizes[0], sizes[1]]
	)

	# ArenaPlayer.team was declared and assigned by NOTHING since the class was
	# written, so the scoreboard, the renderer and the friendly-fire check all read a
	# zero. This is the check that says it is wired.
	var mirrored := 0

	for index in range(6):
		var player := game.player_for(200 + index)

		if player != null and player.team == game.team_of(200 + index):
			mirrored += 1

	_check(mirrored == 6, "the player carries the side it was given", "%d of 6" % mirrored)

	# And the reason any of that matters: dot-combat asks a callable for two entity
	# ids and compares the answers. Unwired, every pair looks like strangers and
	# friendly_fire = false protects nobody.
	var resolver := game.combat.resolver
	_check(resolver.team_of.is_valid(), "combat can ask who is on whose side")

	if resolver.team_of.is_valid():
		var a := 200
		var b := _first_team_mate(game, a)
		_check(b > 0, "two players share a side", "%d and %d" % [a, b])

		if b > 0:
			_check(
				int(resolver.team_of.call(a)) == int(resolver.team_of.call(b)),
				"and combat agrees they do"
			)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()


## Another id on the same side as [param id], or 0.
func _first_team_mate(game: ArenaGame, id: int) -> int:
	var side := game.team_of(id)

	for index in range(6):
		var other := 200 + index

		if other != id and game.team_of(other) == side:
			return other

	return 0


# --- Effects ---------------------------------------------------------------

## dot-effects, and the one line that makes it count.
##
## [b]The check that matters is the damage one.[/b] Everything else here — that a burn
## expires, that a slow slows — is dot-effects' own suite over again. What only this
## project can test is whether `DotDamageResolver.adjust` is actually wired: dot-combat
## has offered that seam since it was written, and a layer that computes multipliers
## nothing multiplies by is this family's most repeated bug.
func _test_effects() -> void:
	_section("effects")

	var game := ArenaGame.new()
	game.name = "EffectGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "an effects game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	_check(game.effects != null, "every mode gets an effects layer")

	var _a := game.add_player(700, "Att")
	var _b := game.add_player(701, "Vic")
	_go_live(game)

	_check(
		game.combat.resolver.adjust.is_valid(),
		"dot-combat's per-hit hook is filled, which nothing in this game had ever done"
	)

	# [b]Out of the spawn window first, and it is not a nicety.[/b] Both players were
	# respawned by the round going live, and a freshly spawned player is protected —
	# `DotHealth`'s window, the `PROTECTED` effect and dot-spawn's ledger all say so, and
	# all three now run off the mode's one `spawn_protection_sec`. Hitting inside it
	# measures the protection rather than the scaling this section is about.
	#
	# It passed before because none of that was reachable from here: the effect was
	# never applied to anybody, dot-spawn's ledger was never granted, and `_hit` asks the
	# resolver rather than `DotHealth`. A check that was right about its subject for the
	# wrong reason.
	for _protect in range(game.match_node.spawn_protection_ticks() + 2):
		game.tick({})

	# The hit, with nothing on either end.
	var plain := _hit(game, 700, 701, 40.0)
	_check(
		is_equal_approx(plain, 40.0),
		"a plain hit lands unscaled", "%.1f" % plain
	)

	# The attacker empowered.
	var _e := game.effects.apply(ArenaEffects.EMPOWERED, 700, 700)
	var boosted := _hit(game, 700, 701, 40.0)
	_check(
		boosted > plain * 2.0,
		"an empowered attacker hits harder", "%.1f against %.1f" % [boosted, plain]
	)

	# The victim untouchable.
	var _p := game.effects.apply(ArenaEffects.PROTECTED, 701, 701)
	var refused := _hit(game, 700, 701, 40.0)
	_check(
		refused == 0.0,
		"and an invulnerable victim takes nothing at all", "%.1f" % refused
	)
	game.effects.remove(ArenaEffects.PROTECTED, 701)

	# A burn reports damage and the game applies it, which is the whole seam.
	var before: float = game.combat.health_of(701).health
	var _burn := game.effects.apply(ArenaEffects.BURNING, 701, 700)
	for t in range(TICK_RATE * 2):
		game.tick({})
	var after: float = game.combat.health_of(701).health
	_check(
		after < before,
		"a burn takes health through DotHealth rather than by touching a number",
		"%.1f -> %.1f" % [before, after]
	)

	# Movement, and the compounding trap.
	var player := game.player_for(701)
	var base := player.controller.tunables.max_speed
	var _slow := game.effects.apply(ArenaEffects.SLOWED, 701, 700)
	game.tick({})
	var slowed := player.controller.tunables.max_speed
	_check(slowed < base, "a slow slows", "%.2f from %.2f" % [slowed, base])

	for t in range(30):
		game.tick({})
	_check(
		is_equal_approx(player.controller.tunables.max_speed, slowed),
		"and stays at ONE slow rather than compounding — scaling the live value each "
		+ "tick reaches zero in a second and the player stops dead",
		"%.4f" % player.controller.tunables.max_speed
	)

	game.effects.remove(ArenaEffects.SLOWED, 701)
	game.tick({})
	_check(
		is_equal_approx(player.controller.tunables.max_speed, base),
		"and goes back to the map's own speed when it ends",
		"%.2f" % player.controller.tunables.max_speed
	)

	# Spawn protection, which is why PROTECTED exists as an effect rather than as
	# DotHealth's own flag: it has to stop a capture as well.
	game.effects.on_spawn(701)
	_check(
		game.effects.has(ArenaEffects.PROTECTED, 701),
		"respawning grants spawn protection"
	)
	_check(
		not game.effects.may_capture(701),
		"and an untouchable player captures nothing, which is the whole reason "
		+ "dot-objective asks a callable"
	)

	# And the seam a changelevel breaks.
	var changed := game.change_map(ArenaMap.dm_box())
	_check(changed.ok, "the map changes", str(changed.error))
	_check(
		game.combat.resolver.adjust.is_valid(),
		"and the per-hit hook is back on the NEW resolver — a map change builds a new "
		+ "combat manager, and without the rebind the effects layer keeps running and "
		+ "stops scaling a single hit"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()


## One resolved hit, returning what actually landed.
func _hit(game: ArenaGame, attacker: int, victim: int, amount: float) -> float:
	var type := game.combat.damage_type(&"bullet")
	if type == null:
		type = DotDamageType.new()
		type.id = &"bullet"
	var damage := DotDamage.make(attacker, victim, amount, type)
	damage.tick = game.current_tick()
	var out := game.combat.resolver.resolve(damage)
	return 0.0 if out.refused else out.amount


# --- zee-dot-weapons ---------------------------------------------------------

## The weapons pack in a real game: the rig drives the player's own arsenal, a spawn holds
## the right thing, a shot leaves the eye, the bash works, and the projectiles behave the
## way the pack's definitions say — a frag bounces and goes off on its fuse, a sticky
## stops where it lands, and a grenade cooked past its fuse goes off in the hand.
func _test_zee_weapons() -> void:
	_section("zee-dot-weapons in the arena")

	var game := ArenaGame.new()
	game.name = "ZeeGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "a weapons game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	var _a := game.add_player(900, "Zee")
	var _b := game.add_player(901, "Far")
	_go_live(game)

	for _protect in range(game.match_node.spawn_protection_ticks() + 2):
		game.tick({})

	var p := game.player_for(900)

	_check(
		p.weapons is ZeeWeaponRig and p.weapons.arsenal == p.arsenal,
		"the rig drives the player's own arsenal, so every reader of it keeps working"
	)
	_check(p.arsenal.max_slots == ZeeWeaponIds.SLOT_THROWN, "with the pack's five slots")

	# The default: something in every slot that matters, and the GUN in hand.
	p.give_default_loadout()
	var carried := PackedStringArray()
	for id in ArenaContent.DEFAULT_LOADOUT:
		if p.arsenal.carries(id):
			carried.append(String(id))
	_check(
		carried.size() == ArenaContent.DEFAULT_LOADOUT.size(),
		"the default loadout is carried", ", ".join(carried)
	)
	_settle(game, 900, TICK_RATE)
	_check(
		p.arsenal.current_def() != null and p.arsenal.current_def().id == ZeeWeaponIds.RIFLE,
		"and a spawn holds the rifle, not the grenade in the highest slot",
		str(p.arsenal.current_def().id if p.arsenal.current_def() != null else &"")
	)

	# A loadout saved before the melee slot existed still gives something under 1.
	var old := DotLoadout.empty(&"arena")
	old.set_item(&"primary", ZeeWeaponIds.SMG)
	old.set_item(&"secondary", ZeeWeaponIds.REVOLVER)
	p.give_loadout(game.loadouts.resolve(old))
	_check(
		p.arsenal.carries(ZeeWeaponIds.KNIFE) and p.arsenal.carries(ZeeWeaponIds.SMG),
		"a primary-and-sidearm loadout from before the melee slot still gets a knife"
	)
	_check(
		p.arsenal.current_slot() == ZeeWeaponIds.SLOT_PRIMARY,
		"and spawns holding its primary", str(p.arsenal.current_slot())
	)
	_settle(game, 900, TICK_RATE)

	# A shot, from the eye along the aim. The rig builds its own context when handed
	# none, from the player bridge; this game hands it one, and this is what says the
	# shot it gets still leaves where the player is looking.
	var used: Array[DotWeaponOutcome] = []
	p.used.connect(func(o: DotWeaponOutcome) -> void: used.append(o))

	for i in range(TICK_RATE / 2):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK, 0, -5.0)

	var shots: Array[DotShot] = []
	for o in used:
		shots.append_array(o.shots)
	_check(shots.size() > 3, "held fire shoots the SMG", str(shots.size()))

	if not shots.is_empty():
		var eye := p.muzzle_position()
		_check(
			shots[-1].origin.distance_to(eye) < 0.05,
			"from the eye", "%.3f m away" % shots[-1].origin.distance_to(eye)
		)
		_check(
			shots[-1].direction.dot(p.aim_direction()) > 0.98,
			"along the aim", "dot %.3f" % shots[-1].direction.dot(p.aim_direction())
		)

	# The bash on the alt-fire: the pack's own second state machine, through the rig.
	var bashes: Array[DotWeaponOutcome] = []
	p.weapons.bashed.connect(func(o: DotWeaponOutcome) -> void: bashes.append(o))
	_settle(game, 900, TICK_RATE / 2)
	_hold(game, 900, DotWeaponCommand.BUTTON_ALT)
	_settle(game, 900, 4)
	_check(bashes.size() == 1, "the alt-fire bashes, once per press", str(bashes.size()))

	# A frag: thrown, bounced, and gone off on its fuse rather than on the first wall.
	var gone: Array = []
	game.projectiles.detonated.connect(func(at: Vector3, s: DotWeaponSpawn) -> void:
		gone.append([at, s, game.current_tick()])
	)

	p.arsenal.give(ZeeWeaponIds.FRAG)
	_switch_to(game, 900, ZeeWeaponIds.SLOT_THROWN)
	_check(
		p.arsenal.current_def().id == ZeeWeaponIds.FRAG,
		"the 5 key's slot holds the frag", str(p.arsenal.current_def().id)
	)

	for i in range(6):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK, 0, -25.0)
	var thrown_at := game.current_tick()
	_settle(game, 900, 1)

	var flying := game.projectiles.flying()
	_check(flying.size() == 1, "letting go throws it", str(flying.size()))

	var frag: ArenaProjectiles.Flying = flying[0] if flying.size() == 1 else null
	var fuse := frag.spawn.fuse_ticks if frag != null else 0
	_check(fuse > TICK_RATE, "with most of its fuse left", "%d ticks" % fuse)

	var most_bounces := 0
	for i in range(TICK_RATE * 4):
		if frag != null:
			most_bounces = maxi(most_bounces, frag.bounces)
		if not gone.is_empty():
			break
		game.tick({})

	_check(most_bounces > 0, "it bounced", str(most_bounces))
	_check(gone.size() == 1, "and went off", str(gone.size()))

	if gone.size() == 1:
		var after := int(gone[0][2]) - thrown_at
		_check(
			absi(after - fuse) <= 2,
			"on its fuse, not on the first thing it touched",
			"%d ticks after the throw, fuse %d" % [after, fuse]
		)

	# A sticky stops on what it lands on.
	gone.clear()
	p.arsenal.give(ZeeWeaponIds.STICKY)
	p.arsenal.add_ammo(ZeeWeaponIds.AMMO_GRENADE, 4)
	_settle(game, 900, TICK_RATE)
	# Down at the floor a few metres out: at the thrower's own feet its splash would kill
	# them, the respawn would hand back a rifle, and the cook-off below would be a rifle.
	for i in range(4):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK, 0, -20.0)
	_settle(game, 900, TICK_RATE / 2)

	var sticky: ArenaProjectiles.Flying = (
		game.projectiles.flying()[0] if game.projectiles.live_count() == 1 else null
	)
	_check(
		sticky != null and sticky.sticks and sticky.resting and sticky.bounces == 0,
		"a sticky stops dead where it lands",
		str(game.projectiles.describe())
	)
	var stuck_at := sticky.position if sticky != null else Vector3.ZERO
	_settle(game, 900, TICK_RATE / 4)
	_check(
		sticky != null and sticky.position.distance_to(stuck_at) < 0.001,
		"and stays there"
	)
	for i in range(TICK_RATE * 3):
		if not gone.is_empty():
			break
		game.tick({})
	_check(gone.size() == 1, "then goes off", str(gone.size()))

	# Cooked past its fuse: in the hand, at once, and it hurts.
	_check(p.is_alive(), "the thrower survived their own sticky at range")
	gone.clear()
	p.arsenal.give(ZeeWeaponIds.FRAG)
	p.arsenal.add_ammo(ZeeWeaponIds.AMMO_GRENADE, 4)
	p.health.invulnerable = false
	p.health.spawn_protection_ticks = 0
	var before := p.health.health + p.health.armour
	_settle(game, 900, TICK_RATE)
	for i in range(TICK_RATE * 3 + 16):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK)
	var released := game.current_tick()
	_settle(game, 900, 3)
	_check(gone.size() == 1, "a grenade cooked past its fuse goes off", str(gone.size()))

	if gone.size() == 1:
		_check(
			int(gone[0][2]) - released <= 2,
			"at once, not twelve seconds later",
			"%d ticks after letting go" % (int(gone[0][2]) - released)
		)
		_check(
			(gone[0][0] as Vector3).distance_to(p.muzzle_position()) < 1.0,
			"in the hand"
		)
	_check(
		p.health.health + p.health.armour < before or not p.is_alive(),
		"and the thrower pays for it"
	)

	# The counter on a weapon with no magazine reads its pool, not zero.
	if not p.is_alive():
		var _again := game.respawn_player(900)
	p.arsenal.give(ZeeWeaponIds.BEAMER)
	_switch_to(game, 900, ZeeWeaponIds.SLOT_HEAVY)
	var cells := p.arsenal.ammo().count(ZeeWeaponIds.AMMO_CELL)
	_check(
		ArenaHud.rounds_in_hand(p) == cells and cells > 0,
		"the HUD counts a beamer's cells, where a magazine count read 0",
		"%d against %d" % [ArenaHud.rounds_in_hand(p), cells]
	)
	_check(
		ArenaHud.weapon_line(p) == "Beamer",
		"and names it", ArenaHud.weapon_line(p)
	)
	_check(
		ArenaHud.cause_label(ZeeWeaponIds.MACHINE_PISTOL) == "Machine Pistol",
		"the kill feed says Machine Pistol, not machine_pistol"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()


## One tick of [param id] holding [param buttons], looking along [param pitch].
func _hold(game: ArenaGame, id: int, buttons: int, slot: int = 0, pitch: float = 0.0) -> void:
	var move := DotFpsCommand.new()
	move.pitch = pitch
	move.yaw = game.player_for(id).controller.state.yaw
	var fire := DotWeaponCommand.new()
	fire.buttons = buttons
	fire.slot = slot
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	game.tick({id: [move, fire]})


## [param ticks] of [param id] doing nothing, so a deploy or a cooldown runs out.
func _settle(game: ArenaGame, id: int, ticks: int) -> void:
	for i in range(ticks):
		_hold(game, id, 0)


## Asks for [param slot] the way the number keys do, and waits for the switch.
func _switch_to(game: ArenaGame, id: int, slot: int) -> void:
	_hold(game, id, 0, slot)
	_settle(game, id, TICK_RATE)


# --- Drops -------------------------------------------------------------------

## Coins and a health pack out of a critical kill, taken by walking through them.
func _test_drops() -> void:
	_section("a critical kill drops coins and a health pack")

	var game := ArenaGame.new()
	game.name = "DropsGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "a drops game sets up", str(ready.error)):
		remove_child(game)
		game.queue_free()
		return

	game.start(0)
	for id in [900, 901, 902]:
		var _added := game.add_player(id, "Dropper %d" % id)
	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)

	var kill := func(killer: int, victim: int, critical: bool) -> void:
		var health := game.combat.health_of(victim)
		health.invulnerable_until_tick = -1
		var damage := DotDamage.make(killer, victim, 500.0, game.combat.damage_type(&"bullet"))
		damage.tick = game.current_tick()
		damage.critical = critical
		var applied := health.apply(damage)
		if applied != null and applied.lethal:
			applied.critical = critical
			game.combat.entity_killed.emit(victim, applied)

	kill.call(900, 902, false)
	_check(game.drops.live_count() == 0, "an ordinary kill drops nothing by default")

	_stand(game, 901, Vector3(0.0, 0.05, 18.0))
	kill.call(900, 901, true)
	var dropped := game.drops.live_count()
	_check(dropped == int(game.drop_rules["coins"]) + 1,
		"a lethal critical drops %d coins and a pack (%d)" % [game.drop_rules["coins"], dropped])

	# Walk the killer over every coin, and the pack, at full health.
	var killer := game.player_for(900)
	var coins_at: Array[Vector3] = []
	var pack_at := Vector3.ZERO
	for pickup in game.drops.field.pickups():
		if pickup.item_id == &"coin":
			coins_at.append(pickup.global_position)
		else:
			pack_at = pickup.global_position
	for at in coins_at:
		_stand(game, 900, at)
		game.tick({})
	_check(int(game.drops.coins.get(900, 0)) == coins_at.size(),
		"walking through the coins collects every one (%d)" % int(game.drops.coins.get(900, 0)))

	_stand(game, 900, pack_at)
	game.tick({})
	_check(game.drops.live_count() == 1, "the pack is left for somebody who needs it at full health")

	killer.health.health = 40.0
	game.tick({})
	_check(game.drops.live_count() == 0 and killer.health.health > 60.0,
		"and taken by a hurt player, who is healed (%.0f)" % killer.health.health)

	# Drops that nobody takes go after their life.
	game.drop_rules["any_kill"] = true
	game.apply_drop_rules()
	game.player_for(902).health.alive = true
	game.player_for(902).hitboxes.enabled = true
	_stand(game, 902, Vector3(10.0, 0.05, -18.0))
	game.combat.health_of(902).health = 100.0
	kill.call(901 if game.player_for(901).is_alive() else 900, 902, false)
	_check(game.drops.live_count() > 0, "with any_kill on, an ordinary kill drops too")
	for _i in range(int(float(game.drop_rules["life"]) * TICK_RATE) + 2):
		game.tick({})
	_check(game.drops.live_count() == 0, "and what nobody takes is gone after its life")

	# The wire: a drop and a take round-trip.
	var wire := ArenaEvents.read_drop(DotNetReader.new(
		ArenaEvents.write_drop(7, 1, 25, Vector3(1, 2, 3), Vector3(4, 0, 6))
	))
	_check(bool(wire["ok"]) and int(wire["id"]) == 7 and int(wire["kind"]) == 1
		and int(wire["value"]) == 25 and (wire["at"] as Vector3).is_equal_approx(Vector3(4, 0, 6)),
		"DROP round-trips")

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()


# --- Streaks -----------------------------------------------------------------

func _test_streaks() -> void:
	_section("kill streaks and their rewards")

	_check(
		ArenaGame.parse_streak_rewards("3:heal, 5:haste,x:y,0:armour") == {3: "heal", 5: "haste"},
		"arena_streak_rewards parses streak:reward pairs and skips the rest"
	)
	_check(ArenaGame.parse_streak_rewards("").is_empty(), "and empty gives nothing")

	var game := _weapon_mode_game(ArenaMode.free_for_all(50), [940, 941, 942])
	if game == null:
		_check(false, "a streak game sets up")
		return
	var rewards: Array[String] = []
	game.streak_reward.connect(func(_p: int, s: int, r: String) -> void: rewards.append("%d:%s" % [s, r]))

	var killer := game.player_for(940)
	for i in range(3):
		killer.health.health = 30.0
		var victim := 941 if i % 2 == 0 else 942
		game.player_for(victim).health.alive = true
		game.player_for(victim).hitboxes.enabled = true
		game.combat.health_of(victim).health = 100.0
		_kill_through_combat(game, 940, victim)
	_check(int(game.streaks.get(940, 0)) == 3 and rewards == ["3:heal"],
		"the third kill without dying is a streak of three and heals (%s)" % ", ".join(rewards))
	_check(killer.health.health >= killer.health.max_health - 0.01, "to full (%.0f)" % killer.health.health)

	game.player_for(941).health.alive = true
	game.player_for(941).hitboxes.enabled = true
	_kill_through_combat(game, 941, 940)
	_check(int(game.streaks.get(940, -1)) == 0, "and dying ends it")

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()


# --- Weapon modes ------------------------------------------------------------

func _weapon_mode_game(mode: ArenaMode, ids: Array) -> ArenaGame:
	var game := ArenaGame.new()
	game.name = "WeaponModeGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = mode
	add_child(game)
	var ready := game.setup(ArenaMap.dm_box())
	if not ready.ok:
		return null
	game.start(0)
	for id in ids:
		var _added := game.add_player(id, "Armed %d" % id)
	game.match_node.rules.respawn_delay_sec = 0.2
	_go_live(game)
	return game


func _carried(game: ArenaGame, id: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for slot in game.player_for(id).arsenal.slots():
		var def: DotWeaponDef = game.player_for(id).arsenal.slot_at(slot).def
		out.append(def.id)
	return out


## Lag compensation: a shot is traced against the other players where the shooter saw
## them, as far back as `arena_max_unlag_ms` allows (2026-10-09; before, never).
func _test_lag_compensation() -> void:
	_section("lag compensation")
	var game := _weapon_mode_game(ArenaMode.free_for_all(25), [940, 941])
	if not _check(game != null, "a two-player game sets up"):
		return
	for _i in range(6):
		await get_tree().process_frame
	var shooter := game.player_for(940)
	var target := game.player_for(941)
	var floor_y := shooter.controller.state.position.y
	for id in [940, 941]:
		game.combat.health_of(id).invulnerable_until_tick = -1

	# B walks sideways a quarter of a metre a tick, eight metres in front of A, for twenty
	# ticks; the history is what the server records as it ticks.
	var a_at := Vector3(0.0, floor_y, 0.0)
	for k in range(20):
		_stand(game, 940, a_at)
		_stand(game, 941, Vector3(-2.5 + 0.25 * k, floor_y, -8.0))
		game.tick({})
	var now := game.current_tick()
	var back := 12
	var then: Variant = game.unlag_position_at(941, float(now - back))
	_check(then is Vector3 and (then as Vector3).distance_to(target.global_position) > 2.5,
		"the server remembers where B was %d ticks ago (%s, now %s)" % [back, then, target.global_position])

	# A fires at where B WAS, as a client drawing B that far behind would.
	var fire_at := func(view_tick: float) -> bool:
		var shot := DotShot.make(&"rifle", 940, now, 0)
		shot.origin = shooter.global_position + Vector3.UP * 1.5
		var aim: Vector3 = ((then as Vector3) + Vector3.UP * 1.0) - shot.origin
		shot.pellets = [aim.normalized()] as Array[Vector3]
		shot.direction = aim.normalized()
		shot.damage = 5.0
		shot.damage_type = game.combat.damage_type(&"bullet")
		shot.max_range = 100.0
		game._unlag_shooter = 940
		var _r := game.combat.resolve_shot(shot, view_tick)
		# The hit, not the health: what lag compensation decides is whether the trace met
		# B. What the damage then does (armour, protection) is the rules' business.
		for d: DotDamage in shot.damages:
			if d.victim == 941:
				return true
		return false

	_check(fire_at.call(float(now - back)), "a shot aimed where A saw B, %d ticks back, hits B" % back)
	_check(target.global_position.distance_to(Vector3(-2.5 + 0.25 * 19, floor_y, -8.0)) < 0.3,
		"and B is put back where the server has him (%s)" % target.global_position)
	_check(not fire_at.call(-1.0), "the same shot judged against the present misses")
	game.max_unlag_ms = 0.0
	_check(not fire_at.call(float(now - back)), "and with arena_max_unlag_ms 0 nothing is rewound")
	game.max_unlag_ms = 50.0
	_check(not fire_at.call(float(now - back)),
		"nor past the limit: 50 ms is 3 ticks, and %d were asked for" % back)
	game.max_unlag_ms = 500.0
	remove_child(game)
	game.queue_free()
	_done()


## Gun game and a weapon pool: the mode decides what a player carries.
func _test_weapon_modes() -> void:
	_section("gun game and a weapon pool")

	_check(ArenaModes.ids().has(&"gungame") and ArenaModes.ids().has(&"snipers"),
		"gun game and only snipers are modes a server or a vote can name")

	var broken := ArenaMode.gun_game_mode()
	broken.rules.score_limit = 3
	_check(not broken.validate().ok, "a gun game whose score limit is not its list's length is refused")

	var gun := ArenaMode.gun_game_mode()
	var game := _weapon_mode_game(gun, [920, 921])
	if not _check(game != null, "a gun game sets up"):
		return
	for _i in range(6):
		await get_tree().process_frame
	var first := StringName(gun.gun_game[0])
	var held := game.player_for(920).arsenal.current_def()
	_check(held != null and held.id == first, "a gun game player spawns holding the first gun (%s)" % (held.id if held else &"none"))
	_check(_carried(game, 920).size() <= 2, "and nothing else but the knife (%s)" % ", ".join(_carried(game, 920)))

	_kill_through_combat(game, 920, 921)
	held = game.player_for(920).arsenal.current_def()
	_check(held != null and held.id == StringName(gun.gun_game[1]),
		"a kill moves the killer to the next gun (%s)" % (held.id if held else &"none"))

	# A knife kill sets the victim back a gun. 920 is on level 1, 921 on 0. Each victim
	# is revived first: a dead one refuses the hit and the check would pass on nothing.
	var knifed := game.match_node.scoreboard.find("920")
	var knifer := game.match_node.scoreboard.find("921")
	_revive(game, 921)
	_kill_through_combat(game, 920, 921, ZeeWeaponIds.KNIFE)
	_check(knifer != null and knifer.score == 0 and knifer.deaths == 2,
		"a knife kill on the first gun leaves the victim there (921 at %d, %d deaths)" % [knifer.score if knifer else -1, knifer.deaths if knifer else -1])
	_revive(game, 920)
	_kill_through_combat(game, 921, 920, ZeeWeaponIds.KNIFE)
	_check(knifed != null and knifed.score == 1,
		"a knife kill sets the victim back one gun (920 from 2 to %d)" % (knifed.score if knifed else -1))
	_check(knifer.score == 1, "and moves the knifer on (921 at %d)" % knifer.score)
	gun.gun_game_melee_demotes = false
	_revive(game, 920)
	_kill_through_combat(game, 921, 920, ZeeWeaponIds.KNIFE)
	_check(knifed.score == 1 and knifer.score == 2,
		"with gun_game_melee_demotes off, a knife kill is only a kill (920 %d, 921 %d)" % [knifed.score, knifer.score])
	gun.gun_game_melee_demotes = true
	remove_child(game)
	game.queue_free()

	var snipers := ArenaMode.only_snipers()
	var sniping := _weapon_mode_game(snipers, [930, 931])
	if not _check(sniping != null, "an only-snipers game sets up"):
		return
	for _i in range(6):
		await get_tree().process_frame
	var allowed := snipers.pool_ids(sniping.player_for(930).arsenal.catalogue)
	var carried := _carried(sniping, 930)
	var stray: Array[StringName] = []
	for id in carried:
		if not allowed.has(id) and id != ZeeWeaponIds.KNIFE:
			stray.append(id)
	_check(stray.is_empty() and carried.size() >= 1,
		"only snipers carries scoped guns and the knife (%s)" % ", ".join(carried))
	remove_child(sniping)
	sniping.queue_free()
	await get_tree().process_frame
	_done()


# --- Spectating ------------------------------------------------------------

func _test_spectating() -> void:
	_section("spectating")

	var game := ArenaGame.new()
	game.name = "SpectateGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a spectating game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	_check(game.spectate != null, "every mode gets a spectate layer")

	for index in range(4):
		var _added := game.add_player(800 + index, "Watcher %d" % index)

	# Nobody respawns during this section. A dead player who comes back is a dead
	# player who correctly stops spectating, and the whole chain being tested here
	# happens in the seconds before that — so a short respawn delay makes every check
	# below measure "they respawned" rather than what it says it measures.
	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)

	var victim := 800
	var killer := _first_other_team(game, victim)
	_check(killer > 0, "somebody is on the other side", str(killer))

	_kill_through_combat(game, killer, victim)

	_check(
		game.spectate.is_spectating(victim),
		"a dead player is watching something rather than lying on the floor"
	)

	var view := game.spectate.manager.view(str(victim))
	_check(
		view.mode == DotSpectatorView.Mode.DEATH_CAM,
		"starting with the death camera", DotSpectatorView.Mode.keys()[view.mode]
	)

	# The whole chain, and the hand-over at the end of it.
	for t in range(TICK_RATE * 5):
		game.tick({})

	_check(
		view.mode == DotSpectatorView.Mode.FIRST_PERSON
		or view.mode == DotSpectatorView.Mode.CHASE,
		"and ending on somebody alive rather than on their killer",
		DotSpectatorView.Mode.keys()[view.mode]
	)
	_check(view.target != "", "with a target", view.target)
	_check(
		game.team_of(int(view.target)) == game.team_of(victim),
		"on their own side, because this is a team mode and the server decides",
		"%d watching %s" % [victim, view.target]
	)

	var where := game.spectate.camera_for(victim)
	_check(
		where.origin.y > game.map.floor_y + 0.5,
		"and the camera is off the floor rather than where the body fell",
		"%.2f" % where.origin.y
	)

	var cycled := game.spectate.next_target(victim)
	_check(cycled.ok, "the view can be cycled", str(cycled.error))

	game.player_for(victim).spawn(game.map.spawns[0], game.current_tick())
	game.spectate.manager.on_spawn(str(victim))
	_check(
		not game.spectate.is_spectating(victim),
		"and respawning stops it"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()


func _first_other_team(game: ArenaGame, id: int) -> int:
	var side := game.team_of(id)
	for index in range(4):
		var other := 800 + index
		if other != id and game.team_of(other) != side:
			return other
	return 0


# --- Spawning in a free-for-all ---------------------------------------------

## In a free-for-all, every other player is an enemy to the spawn director.
##
## [b]The roster hands out sides even when the mode has none.[/b] `DotTeamRoster` is
## built with a standard blue/red pair and auto-assigns whenever dot-match has no teams,
## so in a free-for-all half the players carry the respawning player's roster side. The
## director asks [code]enemies_fn(team)[/code] and [code]friends_fn(team)[/code] with that
## side, and a side-aware answer there would make a free-for-all spawn treat half the
## lobby as friends ([code][arena-ffa-sides-1][/code]).
##
## The arena's own rules pick at random among the sites, which never reads a distance,
## so the last check switches the director to its furthest-from-enemies mode for one
## choice: that is the selector the positions exist for, and the only way to watch a
## roster "friend" being avoided the way an enemy is.
func _test_ffa_spawn_sides() -> void:
	_section("free-for-all: nobody is a friend at a spawn")

	var game := ArenaGame.new()
	game.name = "FfaSpawnGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a free-for-all game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)

	for index in range(4):
		var _added := game.add_player(900 + index, "Loner %d" % index)

	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)
	_ffa_spawn_scenario(game, "from the start")

	# [b]The case the queue item was written about.[/b] A team mode's sides stay in the
	# roster across a change into a free-for-all: `_adopt_match_sides` only forces a side
	# dot-match gave, and a free-for-all gives none, so the four keep red and blue.
	var team := _first_team_mode()
	var to_team := game.change_map(ArenaMap.dm_atrium(), team)
	var to_ffa := game.change_map(ArenaMap.dm_atrium(), ArenaMode.free_for_all(50))
	_check(
		to_team.ok and to_ffa.ok,
		"the game goes into a team mode and back into a free-for-all",
		"%s / %s" % [str(to_team.error), str(to_ffa.error)]
	)
	_ffa_spawn_scenario(game, "after a team mode")

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()


## Three checks: what the director is told about players 901..903 when 900 respawns in
## [param game]'s free-for-all, and which of two sites it then picks. One of the three
## shares 900's roster side where anybody does, and stands two metres from one site; the
## other two stand twelve metres from the other.
func _ffa_spawn_scenario(game: ArenaGame, when: String) -> void:
	var stack := game.player_stack
	var respawner := 900
	var side := stack.teams.team_of(str(respawner))
	var sides := PackedStringArray()

	for index in range(4):
		sides.append("%d %s" % [900 + index, String(stack.teams.team_of(str(900 + index)))])

	var friend := 0
	for index in range(1, 4):
		if stack.teams.team_of(str(900 + index)) == side:
			friend = 900 + index
			break
	if friend == 0:
		friend = 901

	var enemies: Array[int] = []
	for index in range(1, 4):
		if 900 + index != friend:
			enemies.append(900 + index)

	var site_a := Vector3(-20.0, 0.0, 0.0)
	var site_b := Vector3(20.0, 0.0, 0.0)
	var friend_at := site_a + Vector3(2.0, 0.0, 0.0)
	_stand(game, respawner, Vector3(0.0, 0.0, 60.0))
	_stand(game, friend, friend_at)
	_stand(game, enemies[0], site_b + Vector3(0.0, 0.0, 12.0))
	_stand(game, enemies[1], site_b + Vector3(0.0, 0.0, -12.0))

	var told_enemies: Array = stack.spawns.enemies_fn.call(side)
	var told_friends: Array = stack.spawns.friends_fn.call(side)
	var missing := PackedStringArray()

	for id in [friend, enemies[0], enemies[1]]:
		if not told_enemies.has(game.player_for(id).controller.state.position):
			missing.append(str(id))

	_check(
		missing.is_empty(),
		"%s, every other player is an enemy to the director (%s)" % [when, ", ".join(sides)],
		"not enemies: %s" % ", ".join(missing)
	)

	_check(
		not told_friends.has(friend_at),
		"and nobody is a friend, %d on 900's roster side included" % friend,
		"friends: %s" % str(told_friends)
	)

	var saved_mode := stack.spawns.rules.mode
	stack.spawns.rules.mode = DotSpawnRules.Mode.FURTHEST
	stack.spawns.clear_sites()
	stack.spawns.add_site(DotSpawnSite.point(&"beside_the_friend", site_a))
	stack.spawns.add_site(DotSpawnSite.point(&"twelve_from_enemies", site_b))

	var chosen := stack.choose_spawn(respawner)
	var picked := ""
	if chosen.ok:
		picked = String((chosen.value as DotSpawnChoice).site.id)

	stack.spawns.rules.mode = saved_mode
	stack.refresh_spawns()

	_check(
		picked == "twelve_from_enemies",
		"and furthest-from-enemies avoids the spawn 2 m from %d for one 12 m from two "
			% friend + "enemies",
		"picked '%s' %s" % [picked, "" if chosen.ok else str(chosen.error)]
	)


# --- Objectives ------------------------------------------------------------

func _test_king_of_the_hill() -> void:
	_section("king of the hill")

	var game := ArenaGame.new()
	game.name = "KothGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.king_of_the_hill()
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a king-of-the-hill game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	_check(game.objectives != null, "and has objectives")
	_check(game.objectives.layout == &"koth", "the koth layout")

	var hill := game.objectives.manager.objective(&"hill") as DotObjectiveCapture
	var clock := game.objectives.manager.objective(&"koth_clock") as DotObjectiveHoldout
	_check(hill != null and clock != null, "a point and a clock")
	_check(clock.linked == hill, "and the clock reads the point's owner")

	var _a := game.add_player(900, "Red")
	var _b := game.add_player(901, "Blue")
	var red_side := game.team_of(900)

	# On the point, and not live: warmup is when everybody stands on everything.
	_stand(game, 900, hill.def.area.centre)
	for t in range(TICK_RATE):
		game.tick({})
	_check(
		hill.owner_team == 0,
		"nothing is captured during warmup", str(hill.owner_team)
	)

	_go_live(game)
	_stand(game, 901, Vector3(1000.0, 0.0, 0.0))

	var ticks := 0
	while hill.owner_team == 0 and ticks < TICK_RATE * 30:
		_stand(game, 900, hill.def.area.centre)
		game.tick({})
		ticks += 1

	_check(
		hill.owner_team == red_side,
		"and a player standing on it takes it once the match is live",
		"%d after %d ticks" % [hill.owner_team, ticks]
	)

	var left := clock.remaining_for(red_side)
	for t in range(TICK_RATE):
		_stand(game, 900, hill.def.area.centre)
		game.tick({})
	_check(
		clock.remaining_for(red_side) < left,
		"holding it runs their clock down",
		"%d from %d" % [clock.remaining_for(red_side), left]
	)

	# The freeze, which is the whole tension of the mode.
	#
	# Sampled on the tick the point actually changes hands, not before it: red's clock
	# legitimately keeps running for the seconds blue spends capturing, and a sample
	# taken early measures that instead of the freeze.
	_stand(game, 900, Vector3(1000.0, 0.0, 0.0))
	var blue_side := game.team_of(901)
	var frozen := -1
	var flipped := 0
	while hill.owner_team != blue_side and flipped < TICK_RATE * 30:
		_stand(game, 901, hill.def.area.centre)
		game.tick({})
		flipped += 1
		if hill.owner_team == blue_side:
			frozen = clock.remaining_for(red_side)

	_check(
		hill.owner_team == blue_side,
		"the other side can take it back", str(hill.owner_team)
	)
	for t in range(TICK_RATE):
		_stand(game, 901, hill.def.area.centre)
		game.tick({})
	_check(
		clock.remaining_for(red_side) == frozen,
		"and the first side's clock is FROZEN where it stopped rather than reset",
		"%d against %d" % [clock.remaining_for(red_side), frozen]
	)
	_check(
		clock.remaining_for(blue_side) < clock.def.holdout_ticks,
		"while the new owner's runs"
	)

	# **A mode change has to build and unbuild the layers the mode asks for.**
	# Before it did, `changegame`-ing from a deathmatch to koth produced a game whose
	# mode said it had objectives and whose `objectives` was null — and nothing errored,
	# because a null layer is a legitimate thing for a mode with no layer to have.
	var to_ffa := game.change_map(ArenaMap.dm_box(), ArenaMode.free_for_all())
	_check(to_ffa.ok, "the mode changes to one with no objectives", str(to_ffa.error))
	_check(
		game.objectives == null,
		"and the objective layer is taken away, so a HUD does not draw a hill nobody "
		+ "can capture"
	)

	var to_ctf := game.change_map(ArenaMap.dm_atrium(), ArenaMode.capture_the_flag())
	_check(to_ctf.ok, "and to one that has them", str(to_ctf.error))
	_check(
		game.objectives != null and game.objectives.layout == &"ctf",
		"which builds the layer the new mode asks for",
		String(game.objectives.layout) if game.objectives != null else "<none>"
	)
	_check(
		game.effects != null and game.spectate != null,
		"while the layers every mode has survive the change rather than being rebuilt"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()


func _test_capture_the_flag() -> void:
	_section("capture the flag")

	var game := ArenaGame.new()
	game.name = "CtfGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.capture_the_flag(3)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a capture-the-flag game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	var red_flag := game.objectives.manager.objective(&"red_flag") as DotObjectiveFlag
	var blue_flag := game.objectives.manager.objective(&"blue_flag") as DotObjectiveFlag
	_check(red_flag != null and blue_flag != null, "there are two flags")
	_check(
		red_flag.home_team() != blue_flag.home_team(),
		"one for each side"
	)

	var _a := game.add_player(910, "One")
	var _b := game.add_player(911, "Two")
	_go_live(game)

	# Whoever is NOT on red's side is the one who can take red's flag.
	var thief := 910 if game.team_of(910) != red_flag.home_team() else 911
	var defender := 911 if thief == 910 else 910

	_stand(game, defender, Vector3(1000.0, 0.0, 0.0))
	_stand(game, thief, red_flag.at)
	game.tick({})

	_check(
		red_flag.carrier == str(thief),
		"standing on the enemy flag takes it",
		"carrier=%s" % red_flag.carrier
	)

	# The carrier's own flag is at home, so a capture is allowed.
	var target := red_flag.capture_area().centre
	for t in range(20):
		_stand(game, thief, target)
		game.tick({})

	_check(
		red_flag.captures == 1,
		"carrying it to the other end scores it", str(red_flag.captures)
	)
	_check(red_flag.is_home(), "and the flag goes home")
	_check(
		game.match_node.scoreboard.team_score(game.team_of(thief)) > 0,
		"and dot-match has the point, through report_objective rather than a bare "
		+ "team score, so the win check ran with it",
		str(game.match_node.scoreboard.team_score(game.team_of(thief)))
	)

	# A carrier who dies drops it.
	_stand(game, thief, red_flag.at)
	game.tick({})
	_check(red_flag.carrier == str(thief), "it is taken again")
	_kill_through_combat(game, defender, thief)
	game.tick({})
	_check(
		red_flag.state == DotObjectiveFlag.State.DROPPED,
		"and a carrier who dies drops it",
		DotObjectiveFlag.State.keys()[red_flag.state]
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()


## Zero the warmup and tick until the match is actually being played.
##
## Through the real state machine rather than by setting the state: warmup exists, the
## objective layer keys off it, and a test that jumped the machine would be testing a
## state the game never reaches this way.
func _go_live(game: ArenaGame) -> void:
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.min_players = 1
	var guard := 0
	while not game.match_node.is_live() and guard < TICK_RATE * 20:
		game.tick({})
		guard += 1


## Kill somebody the way the game does it, through dot-combat.
##
## Not `DotMatch.report_kill`: that scores a death and emits nothing the game listens
## to, so every layer hanging off `ArenaGame.player_killed` — the spectator camera, the
## flag drop — never hears about it. A test that kills the scoreboard's way is a test
## that never exercises the path a real death takes.
func _kill_through_combat(game: ArenaGame, killer: int, victim: int, weapon: StringName = &"") -> void:
	var health := game.combat.health_of(victim)
	if health == null:
		return
	var type := game.combat.damage_type(&"bullet")
	if type == null:
		type = DotDamageType.new()
		type.id = &"bullet"
	# Spawn protection off first. A player who has just spawned is invulnerable for a
	# second or two and `DotHealth.apply` refuses everything until then — silently,
	# because a refused hit is a legitimate outcome — so a test that kills somebody
	# immediately after a spawn kills nobody and every check after it fails for a
	# reason that is nothing to do with what it is testing.
	health.invulnerable_until_tick = -1
	var damage := DotDamage.make(killer, victim, health.health + health.armour + 50.0, type)
	damage.tick = game.current_tick()
	damage.weapon_id = weapon
	var applied := health.apply(damage)
	if applied != null and applied.lethal:
		game.combat.entity_killed.emit(victim, applied)


func _revive(game: ArenaGame, id: int) -> void:
	var health := game.combat.health_of(id)
	if health != null and not health.alive:
		health.revive()


## Put a player somewhere, without simulating a walk there.
func _stand(game: ArenaGame, id: int, at: Vector3) -> void:
	var player := game.player_for(id)
	if player == null or player.controller == null:
		return
	player.controller.state.position = at


# --- Assertions ------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	_group(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


func _group(title: String) -> void:
	print("")
	print("%s" % title)


# --- Content ---------------------------------------------------------------

func _test_content() -> void:
	_section("content")

	for weapon in ArenaContent.weapons():
		_check(
			weapon.validate().ok,
			"%s is a valid weapon" % weapon.id,
			str(weapon.validate().error)
		)

	var catalogue := ArenaContent.catalogue()
	_check(catalogue.validate().ok, "the item catalogue validates")

	var schema := ArenaContent.loadout_schema()
	_check(schema.validate().ok, "the loadout schema validates",
		str(schema.validate().error))

	# Every weapon must be reachable from a loadout. A content set where a weapon
	# exists and no loadout can name it is a weapon nobody will ever hold, and nothing
	# reports it.
	var everything := DotLoadoutEntitlements.everything()
	var reachable := {}

	for slot in schema.slot_ids():
		for item in schema.choices_for(slot, everything):
			reachable[item.id] = true

	for weapon in ArenaContent.weapons():
		_check(
			reachable.has(weapon.id),
			"%s can be put in a loadout" % weapon.id
		)

	# The budget has to permit something interesting and refuse the obvious abuse: a
	# heavy with armour and a grenade on top is the combination nobody can answer.
	var greedy := DotLoadout.empty(&"arena")
	greedy.set_item(&"melee", ZeeWeaponIds.KNIFE)
	greedy.set_item(&"primary", ZeeWeaponIds.LAUNCHER)
	greedy.set_item(&"secondary", ZeeWeaponIds.REVOLVER)
	greedy.set_item(&"thrown", ZeeWeaponIds.FRAG)
	greedy.set_item(&"gear", &"armour")
	_check(
		not DotLoadoutValidator.validate(greedy, schema, everything).ok,
		"the points budget refuses a heavy with armour and a grenade"
	)

	var sensible := DotLoadout.empty(&"arena")
	sensible.set_item(&"melee", ZeeWeaponIds.KNIFE)
	sensible.set_item(&"primary", ZeeWeaponIds.RIFLE)
	sensible.set_item(&"secondary", ZeeWeaponIds.PISTOL)
	sensible.set_item(&"thrown", ZeeWeaponIds.FRAG)
	sensible.set_item(&"gear", &"armour")
	_check(
		DotLoadoutValidator.validate(sensible, schema, everything).ok,
		"and permits a normal one"
	)

	# A melee weapon in the primary slot is a player who spawns with nothing to shoot.
	# A loadout saved before the melee and throwable slots existed is conformed, not
	# refused: what loading one does, and what puts a grenade under 5 for its owner.
	var saved := DotLoadout.empty(&"arena")
	saved.set_item(&"primary", ZeeWeaponIds.RIFLE)
	saved.set_item(&"secondary", ZeeWeaponIds.PISTOL)
	var _changes := DotLoadoutValidator.conform(saved, schema, everything)
	_check(
		saved.item_in(&"melee") == ZeeWeaponIds.KNIFE
		and saved.item_in(&"thrown") == ZeeWeaponIds.FRAG
		and saved.item_in(&"primary") == ZeeWeaponIds.RIFLE
		and DotLoadoutValidator.validate(saved, schema, everything).ok,
		"an old primary-and-sidearm loadout gains a knife and a frag and keeps its choices"
	)
	_check(
		schema.default_loadout().item_in(&"thrown") == ZeeWeaponIds.FRAG,
		"and the default loadout has a grenade in it, which an optional slot never put there"
	)

	var knives := DotLoadout.empty(&"arena")
	knives.set_item(&"primary", ZeeWeaponIds.KNIFE)
	knives.set_item(&"secondary", ZeeWeaponIds.PISTOL)
	_check(
		not DotLoadoutValidator.validate(knives, schema, everything).ok,
		"and refuses a knife as a primary"
	)

	# The launcher is the one paid item, so an unentitled player must not get it —
	# which is dot-loadout's default and is worth checking here because this game's
	# entitlement source is the thing that grants it.
	var unowned := DotLoadout.empty(&"arena")
	unowned.set_item(&"primary", ZeeWeaponIds.LAUNCHER)
	unowned.set_item(&"secondary", ZeeWeaponIds.PISTOL)
	_check(
		not DotLoadoutValidator.validate(
			unowned, schema, DotLoadoutEntitlements.none()
		).ok,
		"and refuses the launcher to a player who has not unlocked it"
	)
	_done()


func _test_map() -> void:
	_section("map")

	var map := ArenaMap.dm_box()

	_check(map.boxes.size() > 8, "the map has geometry", str(map.boxes.size()))
	_check(map.spawns.size() >= 4, "and spawn points", str(map.spawns.size()))

	# The whole point of ArenaMap: one description, three representations, and they
	# cannot disagree because they are generated from the same list.
	var body := map.to_fps_body()
	var trace := map.to_trace()

	_check(
		body.boxes.size() == map.boxes.size(),
		"the movement backend has every box",
		"%d vs %d" % [body.boxes.size(), map.boxes.size()]
	)
	_check(
		trace.boxes.size() == map.boxes.size(),
		"and so does the shot-tracing one"
	)

	# Both must agree that the perimeter is solid. A wall the shots pass through but
	# the players do not is exactly the drift the single description prevents.
	var outward := trace.ray(Vector3(0.0, 2.0, 0.0), Vector3.RIGHT, 100.0)
	_check(
		outward.ok() and outward.blocked,
		"a shot at the outer wall is stopped"
	)
	_check(
		outward.distance < map.extent + 3.0,
		"at the wall rather than beyond it",
		"%.1f m" % outward.distance
	)

	# Every spawn must be inside the room and above the floor. A spawn outside the
	# perimeter is a player who appears in the void.
	var outside := 0
	for at in map.spawns:
		if absf(at.origin.x) > map.extent or absf(at.origin.z) > map.extent:
			outside += 1
		if at.origin.y < map.floor_y:
			outside += 1
	_check(outside == 0, "every spawn is inside the room", "%d outside" % outside)

	# The generated dev texture, so the "no art assets" claim is checked rather than
	# asserted in a comment.
	var texture := ArenaMap.dev_texture(64, 16)
	_check(texture != null and texture.get_width() == 64, "the dev texture generates")
	_done()


## `dm_pit`: the geometry, the bot that has to get out of the pit, and the mode gate.
##
## [b]Three separate things, and the third is why the map exists.[/b] The geometry and
## the bot are what every new map here owes. The mode gate is what this one adds:
## `dm_pit` is the first map in the game whose spawns carry no team tags, so it is the
## first map for which [method ArenaMaps.supports_mode] can answer no — and every place
## that asks it had, until now, only ever been told yes.
func _test_pit() -> void:
	_section("dm_pit")

	var map := ArenaMap.dm_pit()

	_check(map.boxes.size() > 24, "the map has geometry", str(map.boxes.size()))
	_check(map.spawns.size() == 9, "and nine spawns", str(map.spawns.size()))

	# The invariant every map here is built around, restated for this one.
	_check(
		map.to_fps_body().boxes.size() == map.boxes.size()
			and map.to_trace().boxes.size() == map.boxes.size(),
		"all three representations hold the same boxes"
	)

	# --- Nobody spawns inside a wall --------------------------------------
	#
	# A 0.8 x 1.8 column at each spawn against every solid. `_test_map` checks the
	# weaker version of this -- inside the room, above the floor -- which a spawn
	# buried in a stair tread passes. This map has thirty-five boxes in a
	# twenty-eight metre room and three of them are staircases, so the weaker check
	# is not enough: the first draft of `pg_lobby`'s spiral put its start pad inside
	# its own pillar and nothing caught it until a screenshot.
	var buried := PackedStringArray()

	for index in range(map.spawns.size()):
		var at: Vector3 = map.spawns[index].origin
		var column := AABB(at + Vector3(-0.4, -0.05, -0.4), Vector3(0.8, 1.8, 0.8))

		for box in map.boxes:
			if box.intersects(column):
				buried.append("#%d at %s" % [index, str(at)])
				break

	_check(buried.is_empty(), "and no spawn is inside a solid", ", ".join(buried))

	# --- The property the map is for --------------------------------------

	var tagged := 0

	for index in range(map.spawns.size()):
		if map.spawn_tag(index) != &"":
			tagged += 1

	_check(tagged == 0, "every spawn is untagged, on purpose", "%d tagged" % tagged)

	# --- The lookout, climbed, and what it is for ---------------------------
	#
	# A bot on the east arm facing east (yaw 270) holding forward and jump, grounded
	# on the lookout's top as the arrival. Then the reason it exists: an eye on the
	# lookout sees an eye on the perch, with no box in between.
	var lookout_climber := ArenaPlayer.new()
	lookout_climber.name = "LookoutClimber"
	add_child(lookout_climber)
	lookout_climber.setup(ArenaPlayer.Mode.HEADLESS, map, 9004, "lookout climber")
	lookout_climber.controller.teleport(Vector3(11.6, 3.7, 4.0), 270.0, 0.0)

	var looking := false
	var look_tick := 0

	for step in range(64 * 4):
		var command := DotFpsCommand.new()
		command.yaw = 270.0
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		lookout_climber.controller.apply_command(command)
		lookout_climber.controller.simulate_tick(look_tick, 1.0 / 64.0)
		look_tick += 1

		var on: Vector3 = lookout_climber.controller.state.position

		if lookout_climber.controller.state.is_grounded() and on.y > 4.45 and on.x > 12.5:
			looking = true
			break

	var stood: Vector3 = lookout_climber.controller.state.position
	_check(
		looking,
		"a bot climbs off the east arm onto the lookout",
		"ended at (%.1f, %.2f, %.1f)" % [stood.x, stood.y, stood.z]
	)

	lookout_climber.queue_free()
	remove_child(lookout_climber)

	var from_lookout := Vector3(13.25, 4.5 + 1.6, 4.0)
	var from_perch := Vector3(-10.0, 5.4 + 1.6, 10.0)
	var in_the_way := PackedStringArray()

	for box in map.boxes:
		if box.intersects_segment(from_lookout, from_perch):
			in_the_way.append(str(box))

	_check(
		in_the_way.is_empty(),
		"and from it a player sees the perch, and the perch sees them",
		", ".join(in_the_way)
	)

	var catalogue := ArenaMaps.catalogue()
	var def := catalogue.get_map(&"dm_pit")

	if not _check(def != null, "and it is in the catalogue"):
		return

	_check(
		not bool(def.meta.get("teams", true)),
		"whose entry records that it has no team spawns"
	)

	var ffa := ArenaMode.free_for_all()
	var team := _first_team_mode()

	_check(ArenaMaps.supports_mode(def, ffa), "a free-for-all can be played on it")

	if _check(team != null, "this game has a team mode to test the refusal with"):
		_check(
			not ArenaMaps.supports_mode(def, team),
			"and a team mode cannot -- the first map here that says so",
			String(team.id)
		)

		# The other two maps must still say yes, or the filter below is passing for
		# the wrong reason.
		_check(
			ArenaMaps.supports_mode(catalogue.get_map(&"dm_box"), team)
				and ArenaMaps.supports_mode(catalogue.get_map(&"dm_atrium"), team),
			"while the other two maps still can"
		)

	# --- A bot has to be able to get out of the pit -----------------------
	#
	# The one thing an assertion about boxes cannot tell you. The route under test is
	# the north-west stair: ten treads of 0.36, which the movement should WALK. If a
	# tread is too tall the bot stops dead against the first one -- measured on
	# `dm_atrium`, where the first draft used 0.6 -- and the map has a route on it
	# that no player can take.
	var holder := Node3D.new()
	holder.name = "PitBot"
	add_child(holder)

	var bot := ArenaPlayer.HeadlessController.new()
	bot.name = "Movement"
	bot.flat_body = map.to_fps_body()
	bot.drive = DotFpsController.Drive.EXTERNAL
	bot.tick_rate = TICK_RATE
	bot.tunables = ArenaPlayer.arena_tunables()
	bot.register_service = false
	bot.register_default_actions = false
	bot.body_ref = DotNodeRef.of_path(NodePath(".."))
	holder.add_child(bot)

	# At the bottom of the stair, facing west along it. Yaw 90 is -X in Godot's
	# -Z-forward convention, which is the direction the treads climb.
	bot.teleport(Vector3(-1.0, 0.2, -9.0), 90.0, 0.0)

	var delta := 1.0 / float(TICK_RATE)
	var highest := bot.state.position.y

	for tick in range(int(TICK_RATE * 4)):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.pitch = 0.0
		command.move = Vector2(0.0, 1.0)
		bot.apply_command(command)
		bot.simulate_tick(tick, delta)
		highest = maxf(highest, bot.state.position.y)

	# The ring's top face is 3.6. Anything at or above it means the bot walked the
	# whole stair; the failure this catches is a bot at 0.36 four seconds later.
	_check(
		highest >= 3.5,
		"a bot walks the north-west stair onto the catwalk",
		"reached %.2f m, ring is at 3.60" % highest
	)

	var on_ring := bot.state.position
	_check(
		on_ring.y >= 3.5 and on_ring.x <= -10.0,
		"and is standing on it at the end",
		"at %s" % str(on_ring)
	)

	# And across the bridge. It is 2 m wide over 22 m of open air, so a bot that walks
	# it is a bot the geometry lines up for; a bot that falls is a bridge that does not
	# meet the ring it is drawn as meeting.
	bot.teleport(Vector3(0.0, 3.9, -10.0), 180.0, 0.0)

	var crossed := false

	for tick in range(int(TICK_RATE * 4)):
		var command := DotFpsCommand.new()
		command.yaw = 180.0
		command.pitch = 0.0
		command.move = Vector2(0.0, 1.0)
		bot.apply_command(command)
		bot.simulate_tick(int(TICK_RATE * 4) + tick, delta)

		if bot.state.position.z > 9.0 and bot.state.position.y > 3.0:
			crossed = true
			break

	_check(
		crossed,
		"and crosses the bridge without falling into the pit",
		"ended at %s" % str(bot.state.position)
	)

	# --- The crossing, added 2026-09-18 ------------------------------------
	#
	# The east-west gantry, driven the same way and for the same reason. Asked
	# SEPARATELY rather than assumed from the north-south one passing: the two are
	# different boxes meeting different arms of the ring, and `[gate-sweep-1]` is the
	# whole file of times this family checked one instance of a shape and believed
	# the answer about the others.
	bot.teleport(Vector3(-10.0, 3.9, 0.0), -90.0, 0.0)

	var gantried := false

	for tick in range(int(TICK_RATE * 4)):
		var command := DotFpsCommand.new()
		# -90 is +X in Godot's -Z-forward convention, which is the way this one runs.
		command.yaw = -90.0
		command.pitch = 0.0
		command.move = Vector2(0.0, 1.0)
		bot.apply_command(command)
		bot.simulate_tick(int(TICK_RATE * 8) + tick, delta)

		if bot.state.position.x > 9.0 and bot.state.position.y > 3.0:
			gantried = true
			break

	_check(
		gantried,
		"and crosses the new east-west gantry the same way",
		"ended at %s" % str(bot.state.position)
	)

	holder.queue_free()
	remove_child(holder)

	# --- The shelf and the perch -------------------------------------------
	#
	# Two questions about the third tier, and neither is "is the box there".
	#
	# First: both rises have to be hops. A ledge 1.3 m up is drawn exactly like one
	# 0.9 m up and is a tier no player reaches, which is `[gate-sweep-1]`'s second
	# question — somewhere on the map the thing that plays it cannot get to.
	var jump: float = ArenaPlayer.arena_tunables().jump_height

	# Both boxes found by their footprint rather than by an index into the list:
	# `add_box` order is an implementation detail and an index is a check that
	# silently starts measuring a different box the day somebody inserts one.
	var shelf := AABB()
	var perch := AABB()
	var found_shelf := false
	var found_perch := false

	for box in map.boxes:
		if is_equal_approx(box.size.x, 4.0) and is_equal_approx(box.size.y, 4.5):
			shelf = box
			found_shelf = true
		elif is_equal_approx(box.size.x, 2.0) and is_equal_approx(box.size.y, 0.9):
			perch = box
			found_perch = true

	if _check(
		found_shelf and found_perch, "the shelf and the perch are in the box list"
	):
		# Rises read off the geometry, not written down a second time here — the
		# failure being caught is exactly a number changed there and not here.
		var ring_top := 3.6
		var shelf_top: float = shelf.position.y + shelf.size.y
		var perch_top: float = perch.position.y + perch.size.y
		var onto_shelf: float = shelf_top - ring_top
		var onto_perch: float = perch_top - shelf_top

		_check(
			onto_shelf < jump and onto_perch < jump,
			"both rises onto the third tier are hops rather than walls",
			"%.2f m then %.2f m against a %.2f m jump"
				% [onto_shelf, onto_perch, jump]
		)
		_check(
			perch.position.y <= shelf_top + 0.001,
			"and the perch stands ON the shelf rather than above a gap",
			"perch starts at %.2f, shelf ends at %.2f"
				% [perch.position.y, shelf_top]
		)

	if found_shelf:
		var west_slot: float = absf(shelf.position.x - (-11.0))
		var south_slot: float = absf(
			(shelf.position.z + shelf.size.z) - 11.0
		)

		_check(
			west_slot < 0.01 and south_slot < 0.01,
			"and is flush with both arms of the ring rather than slotted off them",
			"%.2f m west, %.2f m south" % [west_slot, south_slot]
		)

	if found_shelf and found_perch:
		_test_pit_shelf_stair(map, shelf, perch)

	_done()


## `dm_pit`'s shelf stair (2026-09-30, 1.5.0): the pit floor to the third tier, walked.
##
## [b]Driven, not described.[/b] The treads are read back off the box list and their
## shape asserted (eleven, each rise under `step_height`, the top one under the shelf,
## the foot meeting the south-east stair's), and then three bots: one steps off the pit
## floor into the valley and walks up; one runs the whole valley from the east arm,
## down one stair and up the other, holding west and never jump, with its pace from the
## foot to the shelf PRINTED and asserted within 1.5 of `max_speed` (`[bot-drive-1]`: a
## crawling bot also arrives); and the run ends against the perch still on the shelf,
## one hop under it. Then the trade: an eye on the perch sees a chest on every tread.
func _test_pit_shelf_stair(map: ArenaMap, shelf: AABB, perch: AABB) -> void:
	var tunables := ArenaPlayer.arena_tunables()
	var shelf_top: float = shelf.position.y + shelf.size.y
	var shelf_east: float = shelf.position.x + shelf.size.x
	var treads: Array[AABB] = []
	var south_east_foot := AABB()

	for box in map.boxes:
		if is_equal_approx(box.position.z, 7.5) and is_equal_approx(box.size.z, 3.0) \
				and box.position.x < 2.0 - 0.001:
			treads.append(box)
		elif is_equal_approx(box.position.x, 2.0) and is_equal_approx(box.position.z, 7.5):
			south_east_foot = box

	treads.sort_custom(func(a: AABB, b: AABB) -> bool: return a.size.y < b.size.y)

	if not _check(treads.size() == 11, "dm_pit: the shelf stair has eleven boxes, the landing under the bridge one of them", str(treads.size())):
		return

	var steep := PackedStringArray()
	var below: float = south_east_foot.size.y

	for tread in treads:
		var rise: float = tread.size.y - below

		if rise >= tunables.step_height:
			steep.append("%.2f at x %.2f" % [rise, tread.position.x])

		below = tread.size.y

	var lip: float = shelf_top - treads[-1].size.y
	steep.append_array(PackedStringArray() if lip < tunables.step_height else PackedStringArray(["shelf lip %.2f" % lip]))

	_check(
		steep.is_empty(),
		"and every rise on it, the shelf's lip included, is under step_height",
		", ".join(steep)
	)
	_check(
		absf(treads[-1].position.x - shelf_east) < 0.001
			and absf(treads[0].end.x - south_east_foot.position.x) < 0.001
			and treads[0].size.y > south_east_foot.size.y,
		"and it runs flush from the shelf to the south-east stair's first tread",
		"top tread at x %.2f against the shelf at %.2f; foot ends at %.2f, the other stair starts at %.2f"
			% [treads[-1].position.x, shelf_east, treads[0].end.x, south_east_foot.position.x]
	)

	# Headroom: the north-south bridge crosses the lane. Every tread with a box over
	# it keeps `stand_height` clear, or the stair is a wall at the height of a head.
	var low := PackedStringArray()

	for tread in treads:
		for box in map.boxes:
			if box.position.y >= tread.end.y - 0.001 and box.position.x < tread.end.x \
					and box.end.x > tread.position.x and box.position.z < tread.end.z \
					and box.end.z > tread.position.z:
				var clear: float = box.position.y - tread.end.y

				if clear < tunables.stand_height:
					low.append("%.2f over the tread at x %.2f" % [clear, tread.position.x])

	_check(
		low.is_empty(),
		"and a player stands upright on every tread, under the bridge included",
		", ".join(low)
	)

	var walker := ArenaPlayer.new()
	walker.name = "ShelfStairWalker"
	add_child(walker)
	walker.setup(ArenaPlayer.Mode.HEADLESS, map, 9005, "shelf stair walker")

	var delta := 1.0 / 64.0
	var tick := 0

	# --- From the pit floor --------------------------------------------------
	#
	# Standing on the floor north of the valley, step south onto its lowest tread (the
	# south-east stair's first, at 0.36), stop, then turn west and walk up. Arrival is grounded above 4.45 west of the shelf's
	# east face. No jump anywhere.
	walker.controller.teleport(Vector3(2.45, 0.1, 6.0), 180.0, 0.0)

	for step in range(20):
		var command := DotFpsCommand.new()
		command.yaw = 180.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

	for step in range(24):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

	var in_valley: Vector3 = walker.controller.state.position
	var from_floor := false

	for step in range(64 * 3):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and at.y > shelf_top - 0.05 and at.x < shelf_east:
			from_floor = true
			break

	var ended: Vector3 = walker.controller.state.position

	_check(
		from_floor and in_valley.y > 0.3,
		"a bot steps off the pit floor into the valley and walks up onto the shelf",
		"valley at (%.1f, %.2f, %.1f), ended at (%.1f, %.2f, %.1f)"
			% [in_valley.x, in_valley.y, in_valley.z, ended.x, ended.y, ended.z]
	)

	# --- The valley, end to end ---------------------------------------------
	#
	# From the east arm, facing west (yaw 90), holding forward only: down the
	# south-east stair, through the dip, up the shelf stair. The time from the foot of
	# the shelf stair (x = 2) to standing on the shelf is the pace.
	walker.controller.teleport(Vector3(12.5, 3.7, 9.0), 90.0, 0.0)

	var left_arm := -1
	var foot := -1
	var top := -1
	var top_x := 0.0
	var lowest := 99.0

	for step in range(64 * 5):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = walker.controller.state.position
		lowest = minf(lowest, at.y)

		if left_arm < 0 and at.x < 11.0:
			left_arm = step

		if foot < 0 and at.x <= 2.0:
			foot = step

		if walker.controller.state.is_grounded() and at.y > shelf_top - 0.05 and at.x < shelf_east:
			top = step
			top_x = at.x
			break

	var climb_time := float(top - foot) * delta
	var pace := (2.0 - top_x) / climb_time if top > foot and foot >= 0 else 0.0
	var route_time := float(top - left_arm) * delta if top > left_arm and left_arm >= 0 else 0.0
	var arrived: Vector3 = walker.controller.state.position

	print("  ..    dm_pit shelf stair: east arm to shelf %.1f m in %.2f s, down to %.2f; "
		% [11.0 - top_x, route_time, lowest]
		+ "stair %.1f m in %.2f s, %.2f m/s against max_speed %.2f"
		% [2.0 - top_x, climb_time, pace, tunables.max_speed])

	_check(
		top >= 0 and lowest < 0.5,
		"a bot runs the valley from the east arm down and up onto the shelf, jump never pressed",
		"ended at (%.1f, %.2f, %.1f), lowest %.2f" % [arrived.x, arrived.y, arrived.z, lowest]
	)
	_check(
		pace >= tunables.max_speed - 1.5,
		"and climbs the shelf stair at running pace",
		"%.2f m/s against max_speed %.2f" % [pace, tunables.max_speed]
	)

	# Held on for another half second the run ends against the perch, still on the
	# shelf; and one hop from there is the perch.
	for step in range(32):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

	var held: Vector3 = walker.controller.state.position

	_check(
		walker.controller.state.is_grounded() and held.y > shelf_top - 0.05
			and held.x > perch.end.x,
		"and the run ends against the perch, standing on the shelf",
		"ended at (%.1f, %.2f, %.1f)" % [held.x, held.y, held.z]
	)

	var perched := false

	for step in range(64 * 2):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and at.y > perch.end.y - 0.05:
			perched = true
			break

	var hopped: Vector3 = walker.controller.state.position

	_check(
		perched,
		"and one hop from there is the perch, so the floor's stair leads to the top tier",
		"ended at (%.1f, %.2f, %.1f)" % [hopped.x, hopped.y, hopped.z]
	)

	walker.queue_free()
	remove_child(walker)

	# --- The trade, traced ----------------------------------------------------
	var trace := map.to_trace()
	var eye := Vector3(perch.get_center().x, perch.end.y + 1.6, perch.get_center().z)
	var hidden := PackedStringArray()

	# The one tread east of the north-south bridge is behind it from the perch, and
	# that is the valley's only cover: the stair proper is everything west of it.
	for index in range(treads.size()):
		if treads[index].position.x >= 1.0 - 0.001:
			continue

		var chest := Vector3(treads[index].get_center().x, treads[index].end.y + 1.2, 9.0)
		var line := chest - eye
		var hit := trace.ray(eye, line.normalized(), line.length() - 0.05)

		if hit.ok() and hit.blocked:
			hidden.append("tread %d" % (index + 1))

	_check(
		hidden.is_empty(),
		"and the perch sees down every tread of the shelf stair west of the bridge",
		", ".join(hidden)
	)


## What a bot driven the way every bot in this family is driven actually MOVES at.
##
## [b]This is a measurement rather than a feature, and it is here because every "the bot
## hopped" check in this family has been passing for the wrong reason.[/b] Every bot in
## every game here is driven with `move = Vector2(0, 1)`, and several of them hold
## [constant DotFpsCommand.BUTTON_JUMP] as well. Those two commands produce speeds that
## differ by a factor of seven, and nothing anywhere had ever printed either number — so
## a map check that says "a bot crossed the level" and a map check that says "a bot
## crawled four metres and the assertion was loose enough not to care" are the same
## check until somebody measures it.
##
## The mechanism is not a bug and must not be "fixed". With `auto_hop` on and jump HELD,
## the player leaves the ground on the tick it lands, so [code]accelerate[/code] never
## gets a grounded tick to work in; and air acceleration cannot make up the difference
## because [member DotFpsTunables.max_air_wish_speed] is 1.2, which is precisely the cap
## that makes air-strafing a skill. A bot holding one direction cannot strafe, so it
## bleeds to the cap. That pair is deliberate — `arena_tunables()` documents it as the
## classic formula — and what is wrong is only ever the ASSERTION written on top of it.
##
## [b]So the rule for this project, written down here because this is where it is
## proved: an arena bot that has to cover ground does not hold jump.[/b] Every map check
## above drives a walking bot for exactly this reason, and this is the number that says
## why.
func _test_bot_ground_speed() -> void:
	_section("what a bot actually travels at")

	var map := ArenaMap.dm_atrium()
	var tunables := ArenaPlayer.arena_tunables()

	var holder := Node3D.new()
	holder.name = "SpeedBot"
	add_child(holder)

	var bot := ArenaPlayer.HeadlessController.new()
	bot.name = "Movement"
	bot.flat_body = map.to_fps_body()
	bot.drive = DotFpsController.Drive.EXTERNAL
	bot.tick_rate = TICK_RATE
	bot.tunables = tunables
	bot.register_service = false
	bot.register_default_actions = false
	bot.body_ref = DotNodeRef.of_path(NodePath(".."))
	holder.add_child(bot)

	var delta := 1.0 / float(TICK_RATE)
	var walked := _top_speed(bot, false, delta, 0)
	var hopped := _top_speed(bot, true, delta, TICK_RATE * 4)

	# Printed rather than only asserted. This group exists BECAUSE nobody had ever seen
	# these two numbers side by side, and a check's detail line is only shown when it
	# fails — so an assertion alone would hide the measurement again the moment it
	# started passing, which is how this got missed in the first place.
	print("  ..    walking %.2f m/s, hopping %.2f m/s, max_speed %.2f, air cap %.2f"
		% [walked, hopped, tunables.max_speed, tunables.max_air_wish_speed])

	_check(
		walked >= tunables.max_speed - 0.5,
		"a bot holding forward on open ground reaches the speed the tunables promise",
		"%.2f m/s against max_speed %.2f" % [walked, tunables.max_speed]
	)
	_check(
		hopped < walked * 0.5,
		"and the same bot holding jump does not, which is why no map check here holds it",
		"%.2f m/s, bled to max_air_wish_speed %.2f" % [hopped, tunables.max_air_wish_speed]
	)

	holder.queue_free()
	remove_child(holder)
	_done()


## The highest horizontal speed [param bot] reaches in two seconds of holding forward.
##
## Started on the flat empty south of `dm_atrium`'s yard and driven east, which is 30 m
## of nothing — long enough to reach a steady state and short enough not to reach the
## perimeter. The first half second is discarded, because every run starts at rest and
## the question is what the command is worth once it is going.
##
## [b]The best speed rather than the last one, deliberately.[/b] The claim being made
## about the hopping bot is that it CANNOT go fast, and the strongest form of that is
## its own best moment over two seconds rather than wherever it happened to be on the
## final tick.
func _top_speed(
	bot: DotFpsController, jumping: bool, delta: float, tick_base: int
) -> float:
	bot.teleport(Vector3(0.0, 0.2, 24.0), 0.0, 0.0)

	var speed := 0.0

	for tick in range(TICK_RATE * 2):
		var command := DotFpsCommand.new()
		command.yaw = 0.0
		command.pitch = 0.0
		command.move = Vector2(1.0, 0.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, jumping)
		bot.apply_command(command)
		bot.simulate_tick(tick_base + tick, delta)

		if tick >= TICK_RATE / 2:
			var v: Vector3 = bot.state.velocity
			speed = maxf(speed, Vector2(v.x, v.z).length())

	return speed


## Every climb on every map, against what the movement can actually do.
##
## [b]This is the check three maps in this game shipped without, and all three were
## wrong.[/b] `dm_atrium`'s south-east crates rose 1.5 m a step, `dm_pit`'s first crate
## was 1.4, and `dm_box`'s two ledges sat at 3.6 with a 1.0 m plinth as the highest
## thing a player could stand on. A jump here PEAKS at 1.25 m. Not one of those routes
## had ever been climbed, by a player or by a check, and every other assertion in this
## file passed the whole time — a box count cannot tell a platform from a ceiling, the
## three-representations check only says the three agree about a wall nobody can get
## over, and "no spawn is inside a solid" is true of a map made entirely of walls.
##
## [b]The sweep is over `ArenaMap.climbs`, which is derived from the boxes.[/b] A climb
## says only WHICH two boxes are a route; its rise and its gap are read off them, so
## moving a crate moves the climb and this re-decides it. That is the difference
## between this and a table of expected numbers, which is a fourth description of the
## geometry and would go stale the first time somebody nudged a box.
##
## It does not attempt to FIND routes. A map is a heap of boxes and any two of them are
## a climb if you are willing to call them one; which pairs a player is meant to use is
## a design decision and the only part of this a human has to write down.
func _test_reach() -> void:
	_section("what a player can climb")

	var tunables := ArenaPlayer.arena_tunables()

	# The deliberate copy, and the check that the copies agree. A map is content —
	# `by_id` is called from a catalogue listing with no player in the tree — so the
	# numbers it sizes itself against cannot be read off the player class. The family's
	# answer to that is this assertion rather than a shared constant.
	_check(
		is_equal_approx(ArenaMap.MOVE_SPEED, tunables.max_speed)
		and is_equal_approx(ArenaMap.JUMP_HEIGHT, tunables.jump_height)
		and is_equal_approx(ArenaMap.MOVE_GRAVITY, tunables.gravity)
		and is_equal_approx(ArenaMap.STEP_HEIGHT, tunables.step_height),
		"the numbers the maps are sized against are the ones the server applies",
		"map %.2f/%.2f/%.2f/%.2f vs tunables %.2f/%.2f/%.2f/%.2f" % [
			ArenaMap.MOVE_SPEED, ArenaMap.JUMP_HEIGHT, ArenaMap.MOVE_GRAVITY,
			ArenaMap.STEP_HEIGHT, tunables.max_speed, tunables.jump_height,
			tunables.gravity, tunables.step_height
		]
	)

	# Printed rather than only asserted, for the reason `_test_bot_ground_speed` gives:
	# a detail line is shown only when a check fails, so an assertion on its own hides
	# the measurement again the moment it starts passing. These four numbers are the
	# whole of what a map here may ask for.
	print("  ..    a jump peaks at %.2f m; climb limit %.2f m; reach %.2f m flat, "
		% [ArenaMap.JUMP_HEIGHT, ArenaMap.climb_limit(), ArenaMap.jump_reach(0.0)]
		+ "%.2f m onto the limit" % ArenaMap.jump_reach(ArenaMap.climb_limit()))

	var too_high := PackedStringArray()
	var too_far := PackedStringArray()
	var total := 0

	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)

		if map == null:
			continue

		for climb in map.climbs:
			total += 1

			# A rise at or under `step_height` is walked rather than jumped, and a
			# walked rise has no airborne phase to spend on a gap — so it is only
			# legal when the two boxes touch. Splitting the two cases matters: the
			# route onto dm_atrium's ring is a 0.1 m step with no gap, and judging it
			# by `jump_reach(0.1)` would call a stair a jump.
			var walked: bool = climb.rise <= ArenaMap.STEP_HEIGHT and climb.gap <= 0.001

			if walked:
				continue

			if climb.rise > ArenaMap.climb_limit():
				too_high.append("%s rises %.2f m" % [climb.name, climb.rise])
				continue

			var reach := ArenaMap.jump_reach(climb.rise)

			if climb.gap > reach:
				too_far.append(
					"%s crosses %.2f m with %.2f m of reach" % [climb.name, climb.gap, reach]
				)

	_check(total >= 20, "every map declares the climbs it expects", "%d climbs" % total)
	_check(
		too_high.is_empty(),
		"and no climb on any map asks for more height than a jump has",
		"; ".join(too_high)
	)
	_check(
		too_far.is_empty(),
		"and none asks a player to cross more air than they can carry",
		"; ".join(too_far)
	)
	_done()


## `[gate-sweep-1]`, asked of every map as a rule over its box list.
##
## [b]The two questions, and neither is "is the box there".[/b] Can a player pass every
## gap that looks like a way through — two faces closer than 0.8 m, beside the same
## floor, nothing between them, and not a jump the map declares — and is there any
## surface a player cannot get to at all, or can get to and never leave? Both have
## been asked of this game's maps one slot at a time, and the first time they were
## asked of every pair of boxes they found five slots on two maps that nobody had
## thought about: two 0.5 m gaps between dm_atrium's last piers and its crates, a
## 0.75 m one beside its north-west stair, and two 0.75 m pinches between dm_pit's
## stairs and pillars.
##
## [b]The numbers are printed, not only asserted,[/b] for the reason every other
## measurement in this file gives: a detail line appears only on failure, and the areas
## are the part worth reading when the map next changes.
##
## Armed by construction below: a map with a 0.5 m slot, a tower nothing climbs, and a
## courtyard you can drop into and not climb out of — each has to be found, or the
## per-map checks above it pass for a survey that sees nothing.
func _test_survey() -> void:
	_section("every map: slots and reach, as a rule")

	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)

		if map == null:
			continue

		var slots := ArenaMapSurvey.slots(map)
		var closed := PackedStringArray()
		var tight := 0

		for slot in slots:
			if slot["closed"]:
				closed.append("%.2f m on %s between %s and %s" % [
					slot["gap"], slot["axis"], map.boxes[slot["a"]], map.boxes[slot["b"]]
				])
			else:
				tight += 1

		var surveyed := ArenaMapSurvey.reach(map)
		var unexplained := ArenaMapSurvey.unexplained(map, surveyed)
		var lost := PackedStringArray()

		for region in unexplained:
			lost.append("%.1f m² at y %.2f, %s..%s" % [
				region["area"], region["height"], region["from"], region["to"]
			])

		print("  ..    %s: %.0f m² standable, %.0f reached, %.1f unreached (%d declared "
			% [id, surveyed["standable"], surveyed["reached"], surveyed["unreached"],
				map.out_of_reach.size()]
			+ "out of reach), %.1f trapped; %d closed slots, %d tight (0.8-1.05 m)"
			% [surveyed["trapped"], closed.size(), tight])

		_check(
			closed.is_empty(),
			"%s: no gap that looks like a way through is narrower than a player" % id,
			"; ".join(closed)
		)
		_check(
			surveyed["spawns_reached"] == map.spawns.size(),
			"%s: every spawn stands on ground the flood fill reaches" % id,
			"%d of %d" % [surveyed["spawns_reached"], map.spawns.size()]
		)
		_check(
			unexplained.is_empty(),
			"%s: every surface nobody can reach is one the map says is out of reach" % id,
			"; ".join(lost)
		)
		_check(
			float(surveyed["trapped"]) < 0.01,
			"%s: and nowhere a player can reach is somewhere they cannot leave" % id,
			"%.2f m²: %s" % [surveyed["trapped"], str(surveyed["trapped_regions"])]
		)

	# --- The survey itself, shown the three things it is for ---------------

	var bad := ArenaMap.new()
	bad.id = &"survey_fixture"
	bad.extent = 8.0
	bad.wall_height = 6.0
	# Two walls 0.5 m apart, the slot dm_pit's shelf would have made.
	bad.add_box(AABB(Vector3(-7.0, 0.0, 4.0), Vector3(4.0, 2.0, 1.0)))
	bad.add_box(AABB(Vector3(-7.0, 0.0, 5.5), Vector3(4.0, 2.0, 1.0)))
	# A tower 4 m high with nothing to climb it by — 2 m over the courtyard's wall
	# tops too, which a 3 m tower was not: the survey jumped onto it from the wall,
	# correctly, and the fixture was what was wrong.
	var tower := AABB(Vector3(4.0, 0.0, 4.0), Vector3(2.0, 4.0, 2.0))
	bad.add_box(tower)
	# A courtyard walled at 2 m, reached over its west wall from a 1 m crate and left
	# by nothing: 2 m is over the climb limit from inside.
	bad.add_box(AABB(Vector3(0.0, 0.0, -4.0), Vector3(0.5, 2.0, 4.0)))
	bad.add_box(AABB(Vector3(3.5, 0.0, -4.0), Vector3(0.5, 2.0, 4.0)))
	bad.add_box(AABB(Vector3(0.0, 0.0, -4.5), Vector3(4.0, 2.0, 0.5)))
	bad.add_box(AABB(Vector3(0.0, 0.0, 0.0), Vector3(4.0, 2.0, 0.5)))
	bad.add_box(AABB(Vector3(-1.5, 0.0, -3.0), Vector3(1.5, 1.0, 2.0)))
	bad.add_perimeter()
	bad.add_spawn(Transform3D(Basis(), Vector3(-5.0, 0.1, -5.0)))

	var found := false

	for slot in ArenaMapSurvey.slots(bad):
		if slot["closed"] and absf(float(slot["gap"]) - 0.5) < 0.01:
			found = true

	_check(found, "the survey finds a 0.5 m slot when there is one")

	var fixture := ArenaMapSurvey.reach(bad)
	var tower_lost := false

	for region in ArenaMapSurvey.unexplained(bad, fixture):
		if is_equal_approx(float(region["height"]), 4.0):
			tower_lost = true

	_check(tower_lost, "and a tower nothing climbs, as floor nobody reaches")

	bad.add_out_of_reach(tower)
	var still := 0

	for region in ArenaMapSurvey.unexplained(bad, fixture):
		if is_equal_approx(float(region["height"]), 4.0):
			still += 1

	_check(still == 0, "and stops calling it a fault once the map declares it")
	_check(
		float(fixture["trapped"]) > 2.0,
		"and a walled courtyard you can drop into and not leave, as a trap",
		"%.2f m² trapped" % fixture["trapped"]
	)
	_done()


## `dm_box`'s upper level, climbed and walked by a bot rather than believed.
##
## [b]The crates to the ledges were declared on 2026-09-22 and swept as arithmetic, and
## nothing had ever climbed them.[/b] The gantries and nests added on 2026-09-24 are
## the same kind of claim, so all of it is driven here: a bot from the floor up the
## west crates onto the ledge, one across each gantry, and one up the north nest.
##
## Each leg holds ONE direction, for the reason `_test_crate_climb` gives; the gantry
## and nest legs start from a teleport rather than from the end of the climb, because
## turning a bot at 9 m/s on a 2.5 m walkway measures its friction, not the map.
func _test_box_upper() -> void:
	_section("dm_box: the upper level, climbed")

	var map := ArenaMap.dm_box()

	# [b]The property dm_box exists for, asked of the whole list.[/b] Every box has a
	# twin turned half a circle about the origin, so every spawn scores identically —
	# the gantries and nests had to keep that or not be added.
	var unpaired := PackedStringArray()

	for box in map.boxes:
		var turned := AABB(
			Vector3(-box.end.x, box.position.y, -box.end.z), box.size
		)
		var twin := false

		for other in map.boxes:
			if other.is_equal_approx(turned):
				twin = true
				break

		if not twin:
			unpaired.append(str(box))

	_check(
		unpaired.is_empty(),
		"every box on dm_box has its twin turned half a circle about the middle",
		", ".join(unpaired)
	)

	var climber := ArenaPlayer.new()
	climber.name = "BoxClimber"
	add_child(climber)
	climber.setup(ArenaPlayer.Mode.HEADLESS, map, 9003, "box climber")

	var delta := 1.0 / 64.0
	var tick := 0

	# --- Floor, three crates, the west ledge --------------------------------
	#
	# +Z (yaw 180) with jump up the crates, a quarter of a second standing still on
	# the top one, then -X (yaw 90) with jump onto the ledge. [b]The pause is the
	# honest part.[/b] Air control only adds speed along the wish direction, so a bot
	# that turns west in mid-hop keeps every bit of its +Z speed and drifts off the
	# far end of a 2.5 m crate before it has hopped the metre and a half west — which
	# is a bot that never stopped to turn, not a map that cannot be climbed.
	var start := Vector3(-15.75, 0.1, -7.8)
	climber.controller.teleport(start, 180.0, 0.0)

	var on_top_crate := false
	var on_ledge := false
	var settle := 16

	for step in range(64 * 20):
		var command := DotFpsCommand.new()
		command.yaw = 90.0 if on_top_crate else 180.0

		if on_top_crate and settle > 0:
			settle -= 1
		else:
			command.move = Vector2(0.0, 1.0)
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		climber.controller.apply_command(command)
		climber.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = climber.controller.state.position
		var grounded := climber.controller.state.is_grounded()

		if not on_top_crate and grounded and at.y > 2.65:
			on_top_crate = true

		if on_top_crate and grounded and at.y > 3.55 and at.x < -18.0:
			on_ledge = true
			break

	var ended: Vector3 = climber.controller.state.position

	_check(
		on_top_crate and on_ledge,
		"a bot climbs the west crates from the floor onto the west ledge",
		"top crate %s, ended at (%.1f, %.2f, %.1f)"
			% [on_top_crate, ended.x, ended.y, ended.z]
	)

	# --- Each gantry, ledge to ledge -----------------------------------------
	#
	# Clear of the nest step, which fills the gantry's outer metre beside its pillar:
	# the walkway past it is the 1.5 m this leg walks.
	for leg in [
		{"name": "north", "from": Vector3(-20.0, 3.7, -8.9), "yaw": -90.0, "sign": 1.0},
		{"name": "south", "from": Vector3(20.0, 3.7, 8.9), "yaw": 90.0, "sign": -1.0},
	]:
		climber.controller.teleport(leg["from"], leg["yaw"], 0.0)
		var crossed := false

		for step in range(64 * 8):
			var command := DotFpsCommand.new()
			command.yaw = leg["yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position

			if (
				climber.controller.state.is_grounded()
				and at.y > 3.55
				and at.x * float(leg["sign"]) > 18.5
			):
				crossed = true
				break

		var there: Vector3 = climber.controller.state.position

		_check(
			crossed,
			"and walks the %s gantry from one ledge to the other" % leg["name"],
			"ended at (%.1f, %.2f, %.1f)" % [there.x, there.y, there.z]
		)

	# --- The north nest --------------------------------------------------------
	#
	# North (yaw 0) with jump from the gantry: 0.9 onto the step, 0.5 onto the pillar.
	# Grounded on the pillar's top is the arrival, for the reason `_test_crate_climb`
	# gives about heights a jump only passes through.
	climber.controller.teleport(Vector3(4.0, 3.7, -8.4), 0.0, 0.0)
	var nested := false

	for step in range(64 * 6):
		var command := DotFpsCommand.new()
		command.yaw = 0.0
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		climber.controller.apply_command(command)
		climber.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = climber.controller.state.position

		if climber.controller.state.is_grounded() and at.y > 4.95 and at.z < -10.5:
			nested = true
			break

	var perched: Vector3 = climber.controller.state.position

	_check(
		nested,
		"and climbs off the north gantry, up its step, onto the nest",
		"ended at (%.1f, %.2f, %.1f)" % [perched.x, perched.y, perched.z]
	)

	# --- The two nest stairs (2026-09-29) --------------------------------------
	#
	# [b]Walked, and each one separately.[/b] The south stair is the north one's
	# half-turn by construction, but a turned box list is still a different list of
	# boxes meeting a different gantry, and `[gate-sweep-1]` is a file of shapes checked
	# once and believed twice. Held along the stair toward the pillar with NO jump —
	# a stair is the walked way up, and a bot that hopped it would bleed to the 1.2 m/s
	# air cap (`_test_bot_ground_speed`) and prove nothing about pace. The time from the
	# first tread to standing on the last is PRINTED against max_speed and asserted
	# within 1.5 of it, because a bot that crawls up also arrives (`[bot-drive-1]`).
	# Then turned toward the gantry, which is the step the stair exists to lead to.
	var tunables := ArenaPlayer.arena_tunables()
	var trace := map.to_trace()

	for flight in [
		{"name": "north", "sign": 1.0, "up_yaw": -90.0, "across_yaw": 180.0},
		{"name": "south", "sign": -1.0, "up_yaw": 90.0, "across_yaw": 0.0},
	]:
		var s: float = flight["sign"]
		# In the stair's own frame (the north one's): the foot of the first tread is at
		# x -6.5 and the last tread ends against the pillar at x 2.5, z -13.5..-10.5.
		climber.controller.teleport(Vector3(s * -9.0, 0.1, s * -12.0), flight["up_yaw"], 0.0)

		var foot_tick := -1
		var top_tick := -1
		var top_x := 0.0

		for step in range(64 * 4):
			var command := DotFpsCommand.new()
			command.yaw = flight["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position
			var local_x := at.x * s

			if foot_tick < 0 and local_x >= -6.5:
				foot_tick = step

			if climber.controller.state.is_grounded() and at.y > 3.55:
				top_tick = step
				top_x = local_x
				break

		var climb_time := float(top_tick - foot_tick) * delta
		var climb_pace := (top_x + 6.5) / climb_time if top_tick > foot_tick and foot_tick >= 0 else 0.0
		var topped: Vector3 = climber.controller.state.position

		print("  ..    %s nest stair: %.1f m of stair in %.2f s, %.2f m/s against max_speed %.2f"
			% [flight["name"], top_x + 6.5, climb_time, climb_pace, tunables.max_speed])

		_check(
			top_tick >= 0,
			"a bot walks up the %s nest stair from the floor, jump never pressed" % flight["name"],
			"ended at (%.1f, %.2f, %.1f)" % [topped.x, topped.y, topped.z]
		)
		_check(
			climb_pace >= tunables.max_speed - 1.5,
			"and climbs it at running pace",
			"%.2f m/s against max_speed %.2f" % [climb_pace, tunables.max_speed]
		)

		# The run ends against the pillar rather than off the end of the stair: held on
		# for another half second, the bot is still standing on the top tread.
		for step in range(32):
			var command := DotFpsCommand.new()
			command.yaw = flight["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

		var held: Vector3 = climber.controller.state.position

		_check(
			climber.controller.state.is_grounded() and held.y > 3.55 and held.x * s < 2.5,
			"and a run up it ends against the nest pillar, still on the top tread",
			"ended at (%.1f, %.2f, %.1f)" % [held.x, held.y, held.z]
		)

		var onto_gantry := false

		for step in range(64 * 2):
			var command := DotFpsCommand.new()
			command.yaw = flight["across_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position

			if climber.controller.state.is_grounded() and at.y > 3.55 and at.z * s > -9.5:
				onto_gantry = true
				break

		var across: Vector3 = climber.controller.state.position

		_check(
			onto_gantry,
			"and steps off its top tread onto the %s gantry" % flight["name"],
			"ended at (%.1f, %.2f, %.1f)" % [across.x, across.y, across.z]
		)

		# [b]The trade, traced.[/b] The stair climbs straight at the nest, so an eye on
		# the nest sees a player's chest on every tread of it. A stair the nest could not
		# see down would be a free way to the third tier.
		var eye := Vector3(s * 4.0, 5.0 + 1.6, s * -12.0)
		var hidden := PackedStringArray()

		for index in range(10):
			var chest := Vector3(s * (-6.05 + 0.9 * float(index)), 0.36 * float(index + 1) + 1.2, s * -12.0)
			var line := chest - eye
			var hit := trace.ray(eye, line.normalized(), line.length() - 0.05)

			if hit.ok() and hit.blocked:
				hidden.append("tread %d" % (index + 1))

		_check(
			hidden.is_empty(),
			"and the %s nest sees down every tread of its stair" % flight["name"],
			", ".join(hidden)
		)

	# --- The two corner stairs (2026-10-02) -------------------------------------
	#
	# Read back off the box list first, in the north-west stair's frame: ten treads
	# against the north wall between x -17.5 and -8.5, every rise under step_height,
	# and the top one flush with a landing that is flush with the west ledge. Then
	# walked, each corner separately, for the reason the nest stairs give: west up the
	# stair with no jump, paced; held on across the landing to the wall; south onto
	# the ledge's old stub. The south-east one is the same in its own frame.
	var corner_treads: Array[AABB] = []
	var corner_landing := AABB()

	for box in map.boxes:
		if (
			is_equal_approx(box.position.z, -24.0)
			and is_equal_approx(box.size.z, 3.0)
			and box.position.y == 0.0
			and box.position.x >= -17.51
			and box.end.x <= -8.49
		):
			corner_treads.append(box)

		if (
			is_equal_approx(box.position.x, -24.0)
			and is_equal_approx(box.position.z, -24.0)
			and is_equal_approx(box.end.y, 3.6)
		):
			corner_landing = box

	corner_treads.sort_custom(func(a: AABB, b: AABB) -> bool: return a.end.y < b.end.y)
	var corner_steep := PackedStringArray()
	var corner_floor := 0.0

	for tread in corner_treads:
		if tread.end.y - corner_floor >= tunables.step_height:
			corner_steep.append("%.2f -> %.2f" % [corner_floor, tread.end.y])

		corner_floor = tread.end.y

	_check(
		corner_treads.size() == 10 and corner_steep.is_empty(),
		"dm_box's north-west corner stair is ten treads, every rise under step_height",
		"%d treads; %s" % [corner_treads.size(), ", ".join(corner_steep)]
	)
	_check(
		corner_landing.has_volume()
			and not corner_treads.is_empty()
			and is_equal_approx(corner_treads[-1].position.x, corner_landing.end.x)
			and is_equal_approx(corner_treads[-1].end.y, corner_landing.end.y)
			and is_equal_approx(corner_landing.end.z, -18.0),
		"and its top tread is flush with a landing that is flush with the west ledge",
		"landing %s, top tread %s" % [corner_landing, corner_treads[-1] if not corner_treads.is_empty() else AABB()]
	)

	for corner in [
		{"name": "north-west", "sign": 1.0, "up_yaw": 90.0, "ledge_yaw": 180.0},
		{"name": "south-east", "sign": -1.0, "up_yaw": -90.0, "ledge_yaw": 0.0},
	]:
		var s: float = corner["sign"]
		climber.controller.teleport(Vector3(s * -6.0, 0.1, s * -22.5), corner["up_yaw"], 0.0)

		var foot_tick := -1
		var top_tick := -1
		var top_x := 0.0

		for step in range(64 * 4):
			var command := DotFpsCommand.new()
			command.yaw = corner["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position
			var local_x := at.x * s

			if foot_tick < 0 and local_x <= -8.5:
				foot_tick = step

			if climber.controller.state.is_grounded() and at.y > 3.55:
				top_tick = step
				top_x = local_x
				break

		var corner_time := float(top_tick - foot_tick) * delta
		var corner_pace := (-8.5 - top_x) / corner_time if top_tick > foot_tick and foot_tick >= 0 else 0.0
		var corner_top: Vector3 = climber.controller.state.position

		print("  ..    %s corner stair: %.1f m of stair in %.2f s, %.2f m/s against max_speed %.2f"
			% [corner["name"], -8.5 - top_x, corner_time, corner_pace, tunables.max_speed])

		_check(
			top_tick >= 0,
			"a bot walks up the %s corner stair from the floor, jump never pressed" % corner["name"],
			"ended at (%.1f, %.2f, %.1f)" % [corner_top.x, corner_top.y, corner_top.z]
		)
		_check(
			corner_pace >= tunables.max_speed - 1.5,
			"and climbs it at running pace",
			"%.2f m/s against max_speed %.2f" % [corner_pace, tunables.max_speed]
		)

		# Held on for a second — more than the 6.5 m of landing takes — the run ends
		# against the side wall, still at ledge height, not in the corner below.
		for step in range(64):
			var command := DotFpsCommand.new()
			command.yaw = corner["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

		var corner_held: Vector3 = climber.controller.state.position

		_check(
			climber.controller.state.is_grounded()
				and corner_held.y > 3.55
				and corner_held.x * s < -23.0,
			"and a run up it carries on across the landing to the wall, still at ledge height",
			"ended at (%.1f, %.2f, %.1f)" % [corner_held.x, corner_held.y, corner_held.z]
		)

		var onto_ledge := false

		for step in range(64 * 2):
			var command := DotFpsCommand.new()
			command.yaw = corner["ledge_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position

			if climber.controller.state.is_grounded() and at.y > 3.55 and at.z * s > -16.0:
				onto_ledge = true
				break

		var on_stub: Vector3 = climber.controller.state.position

		_check(
			onto_ledge,
			"and turns off the landing onto the %s ledge's end" % ("west" if s > 0.0 else "east"),
			"ended at (%.1f, %.2f, %.1f)" % [on_stub.x, on_stub.y, on_stub.z]
		)

		# The trade: the nest on this side of the room sees a chest on every tread.
		var corner_eye := Vector3(s * 4.0, 5.0 + 1.6, s * -12.0)
		var corner_hidden := PackedStringArray()

		for index in range(10):
			var chest := Vector3(
				s * (-17.05 + 0.9 * float(9 - index)), 0.36 * float(index + 1) + 1.2, s * -22.5
			)
			var line := chest - corner_eye
			var hit := trace.ray(corner_eye, line.normalized(), line.length() - 0.05)

			if hit.ok() and hit.blocked:
				corner_hidden.append("tread %d" % (index + 1))

		_check(
			corner_hidden.is_empty(),
			"and the nest on its side of the room sees every tread of it",
			", ".join(corner_hidden)
		)

	climber.queue_free()
	remove_child(climber)
	_done()


## A bot driven up `dm_atrium`'s crates, start to roof.
##
## [b]The sweep above is arithmetic and this is the thing itself.[/b] Both are needed
## and they fail differently: the sweep says a route is impossible without anybody
## having to guess where the bot got stuck, and this says the route is actually
## connected — that the crates overlap enough to land on, that nothing on the way up is
## a slot narrower than a player, and that a bot holding one direction ends up on the
## roof rather than in the corner beside it.
##
## [b]It holds jump, and this is the one check in the file that may.[/b] The rule
## `_test_bot_ground_speed` writes down is that a bot which has to COVER GROUND does not
## hold jump, because `max_air_wish_speed` is 1.2 and a bot cannot strafe. This bot has
## to gain height rather than ground, `auto_hop` is on, and eighteen metres is short
## enough that bleeding to the air cap does not stop it arriving.
func _test_crate_climb() -> void:
	_section("dm_atrium: the crates, climbed")

	var map := ArenaMap.dm_atrium()

	var climber := ArenaPlayer.new()
	climber.name = "Climber"
	add_child(climber)
	climber.setup(ArenaPlayer.Mode.HEADLESS, map, 9002, "climber")

	# On the yard floor south of the first crate. The column runs north up x 12.5..16,
	# so the bot starts in the middle of it and holds north.
	var start := Vector3(14.2, 0.5, 29.0)
	climber.controller.teleport(start)

	var tick_rate := 64
	var delta := 1.0 / float(tick_rate)
	var peak := start.y
	var top_of_stack := false
	var on_the_ring := false

	# [b]Two held directions, and the switch is the honest part.[/b] The column climbs
	# north and the ring is west of the top of it, so a single held key cannot finish
	# this route — and re-aiming a bot continuously would make its arrival a statement
	# about the steering rather than about the map. So: north and jump until it is up,
	# then west and no jump. Each leg is one key, held, exactly as every other map
	# check in this file drives one.
	# Twenty-four seconds. The climbing leg holds jump, and a bot holding jump travels
	# at a fraction of walking pace — `_test_bot_ground_speed` measures exactly that —
	# so eighteen metres of stack costs most of the budget and the walk along the roof
	# gets what is left. At sixteen seconds it arrived on the ring with two ticks to
	# spare and the check read like a failure of the map.
	for tick in range(tick_rate * 24):
		var command := DotFpsCommand.new()
		command.yaw = 0.0
		command.pitch = 0.0

		if top_of_stack:
			# [b]North-west, not west.[/b] The bot arrives at the landing's south-east
			# corner, and the 4 m of roof ring adjacent to the landing is its northern
			# half — so a bot that turns due west crosses x 10 a metre and a half south
			# of anything and falls into the yard. One held direction still, just a
			# diagonal one.
			command.move = Vector2(-1.0, 1.0).normalized()
		else:
			command.move = Vector2(0.0, 1.0)
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		climber.controller.apply_command(command)
		climber.controller.simulate_tick(tick, delta)

		var at: Vector3 = climber.controller.state.position
		peak = maxf(peak, at.y)

		# [b]Standing on the top of the stack, which is `is_grounded` and not a height
		# band.[/b] The first version of this asked for y above 4.45 below z 12 and
		# passed on the JUMP from the fourth crate: that crate's top is 3.6 and an apex
		# is 1.25 above wherever it left, so a bot that never reached the fifth crate
		# at all crosses 4.45 twice on its way past. A height a player is briefly at is
		# not a height a player got to — this is `[bonus-run-2]`'s "the check read the
		# pad the respawn had put it back on" in a different costume.
		if (
			not top_of_stack
			and climber.controller.state.is_grounded()
			and at.y > 4.45
			and at.z < 12.0
		):
			top_of_stack = true

		# And then on the roof ring itself. The landing's top is 4.5 and the ring's is
		# 4.6, so height alone is a tenth of a metre of daylight and not worth resting
		# a check on; x is decisive, because the landing's west face IS the ring's east
		# edge at x 10. Grounded, above the landing, west of it.
		if (
			top_of_stack
			and climber.controller.state.is_grounded()
			and at.y > 4.55
			and at.x < 9.9
		):
			on_the_ring = true
			break

	var at: Vector3 = climber.controller.state.position

	print("  ..    the climber reached y %.2f, ended at (%.1f, %.2f, %.1f)"
		% [peak, at.x, at.y, at.z])

	_check(
		top_of_stack,
		"a bot holding north and jump at the south-east crates climbs all five",
		"peak y %.2f, ended at (%.1f, %.2f, %.1f)" % [peak, at.x, at.y, at.z]
	)
	_check(
		on_the_ring,
		"and walking west off the landing puts it on the roof ring",
		"ended at (%.1f, %.2f, %.1f)" % [at.x, at.y, at.z]
	)

	climber.queue_free()
	remove_child(climber)
	_done()


## The first mode in this game that needs tagged spawns, or null if there is none.
func _first_team_mode() -> ArenaMode:
	for id in ArenaModes.ids():
		var mode := ArenaModes.by_id(id)

		if mode != null and mode.is_team_mode():
			return mode

	return null


# --- Building --------------------------------------------------------------

func _build() -> void:
	_section("bringing up the match")

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = SCORE_LIMIT
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	add_child(_game)

	var ready := _game.setup(ArenaMap.dm_box())
	_check(ready.ok, "the game sets up", str(ready.error))

	# Warmup and countdown out of the way: this test is about the match, and waiting
	# out thirteen real seconds of clock at 64 Hz is 832 ticks of nothing.
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	_game.match_node.rules.respawn_delay_sec = 1.0
	_game.match_node.rules.intermission_sec = 0.5
	_game.match_node.rules.match_end_sec = 0.5

	_game.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
		_kills.append(entry)
	)
	_game.player_spawned.connect(func(player: ArenaPlayer) -> void:
		_spawns.append(player.player_id)
	)
	_game.match_state_changed.connect(
		func(_from: DotMatch.State, to: DotMatch.State) -> void:
			_states.append(DotMatch.State.keys()[to])
	)

	for index in range(BOTS):
		var added := _game.add_player(index + 1, "Bot %d" % (index + 1))
		_check(added.ok, "bot %d joins" % (index + 1), str(added.error))

	_game.start(0)
	_check(_game.match_node.state != DotMatch.State.IDLE, "the match starts")

	# Let the first tick run so the round goes live and everyone is spawned in.
	_game.tick({})
	await get_tree().process_frame
	_done()


func _test_players_exist() -> void:
	_section("players")

	_check(_game.players().size() == BOTS, "every bot has a body")

	for player in _game.players():
		_check(
			player.controller != null and player.arsenal != null and player.health != null,
			"bot %d has movement, an arsenal and health" % player.player_id
		)
		_check(
			_game.combat.hitboxes_of(player.player_id) != null,
			"and is registered as shootable"
		)
		_check(
			_game.combat.health_of(player.player_id) == player.health,
			"and as damageable"
		)
	_done()


# --- Playing ---------------------------------------------------------------

## Aims at the nearest living opponent and holds the trigger.
##
## Deliberately simple. The point is not the bot; it is that four of them produce
## kills, deaths, respawns and blocked shots without anything being called by hand.
func _commands_for_tick(tick: int) -> Dictionary:
	var commands := {}

	for player in _game.players():
		if not player.is_alive():
			continue

		var target := _nearest_target(player)
		var move := DotFpsCommand.new()
		var fire := DotWeaponCommand.new()

		if target != null:
			var to_target := (
				target.muzzle_position() - player.muzzle_position()
			).normalized()

			# The inverse of DotWeaponCommand.aim_direction(), which is Godot's
			# -Z-forward convention. Getting the sign wrong here makes every bot shoot
			# backwards, which reads as a broken hit registration rather than a broken
			# test.
			move.yaw = rad_to_deg(atan2(-to_target.x, -to_target.z))
			move.pitch = rad_to_deg(asin(clampf(to_target.y, -1.0, 1.0)))

			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

			# Strafe, so they are not four statues: it exercises the movement-based
			# spread and the ground friction, and it means the shots are not all
			# fired from a standstill.
			move.move = Vector2(sin(float(tick) * 0.05 + float(player.player_id)), 0.2)

		move.sanitise()
		fire.sanitise()
		commands[player.player_id] = [move, fire]

	return commands


func _nearest_target(from: ArenaPlayer) -> ArenaPlayer:
	var best: ArenaPlayer = null
	var best_distance := INF

	for other in _game.players():
		if other == from or not other.is_alive():
			continue

		var distance := from.muzzle_position().distance_to(other.muzzle_position())

		if distance < best_distance:
			best_distance = distance
			best = other

	return best


var _lowest_y := INF
var _furthest := 0.0
var _grounded_ticks := 0


func _play() -> void:
	_section("playing")

	var ticks := 0

	while ticks < MAX_TICKS:
		if _game.match_node.state == DotMatch.State.MATCH_END:
			break

		_game.tick(_commands_for_tick(ticks))
		ticks += 1

		if _vote != null:
			_vote.advance(1.0 / float(TICK_RATE))

		for player in _game.players():
			var at := player.controller.state.position
			_lowest_y = minf(_lowest_y, at.y)
			_furthest = maxf(_furthest, maxf(absf(at.x), absf(at.z)))

			if player.controller.state.is_grounded():
				_grounded_ticks += 1

		# Loadouts are applied through an awaited store call, so the frame has to be
		# allowed to turn over or the deferred half never runs. Every 4 ticks, not 64: a
		# respawned bot is unarmed until its loadout lands, and at 64 ticks a frame a slow
		# runner left bots unarmed long enough that a match which ends in 2,500-3,300
		# ticks here ran past 5,760 on CI (2026-10-09). A real server runs one or two
		# ticks a frame.
		if ticks % 4 == 0:
			await get_tree().process_frame

	_check(
		ticks < MAX_TICKS,
		"the match reached an end on its own",
		"ran %d ticks" % ticks
	)
	print("       %d ticks, %d kills" % [ticks, _kills.size()])
	_done()


## A map vote over the match `_play` is about to run, with a score limit and nothing else.
##
## [b]Real frags, not a reported number.[/b] dot-vote's own suite calls `note_score` by
## hand; what it cannot reach is whether a game ever calls it — and until this, none did,
## so `trigger: score_limit` on any game here was a setting that validated and did nothing.
func _build_vote() -> void:
	_section("a map vote over the match")

	var maps := ArenaMapDirector.new()
	maps.name = "VoteMaps"
	maps.game = _game
	maps.map_seconds = 0.0
	add_child(maps)
	_check(maps.setup().ok, "a map director for the vote sets up")

	_vote = ArenaVote.new()
	_vote.name = "Vote"
	_vote.game = _game
	_vote.maps = maps
	# Counts and never applies: a winner would change the map under every section after
	# this one. `auto_apply` follows it, and so does the registry.
	_vote.authoritative = false
	_vote.config_path = ""
	add_child(_vote)

	var ready := _vote.setup()
	if not _check(ready.ok, "and the vote sets up", str(ready.error)):
		_vote = null
		return

	# A score limit ABOVE the match's own, so the clock is still running when the round
	# ends and the round end can be seen arriving. Due at four frags: two short of the
	# match's limit of six, which is where a frag-limit chooser opens its ballot.
	var rules := _vote.director.rules
	rules.trigger = DotVoteRules.Trigger.SCORE_LIMIT
	rules.duration_sec = 0.0
	rules.score_limit = SCORE_LIMIT + 10
	rules.vote_lead_score = SCORE_LIMIT + 6
	rules.vote_warning_sec = 0.0
	# Open for the whole match, so a ballot closing unanswered does not restart the clock
	# and open a second one.
	rules.vote_duration_sec = 600.0
	_check(rules.validate().ok, "a score-limited vote validates", str(rules.validate().error))

	# The clock reads its limits when it starts.
	_vote.director.begin(_vote.source.current_id())

	_vote.director.vote_opened.connect(func(_options: Array, _seconds: float) -> void:
		_vote_seen.append([
			DotMatch.State.keys()[_game.match_node.state], _vote.leading_score()
		])
	)
	_done()


func _test_score_vote() -> void:
	_section("the map vote heard the match")

	if not _check(_vote != null, "there is a vote"):
		return

	_check(
		_vote_seen.size() == 1,
		"a ballot opened, once, off the bots' own frags (%d)" % _vote_seen.size(),
		"nothing called note_score, and trigger: score_limit decided nothing"
	)

	if not _vote_seen.is_empty():
		var first: Array = _vote_seen[0]
		_check(
			String(first[0]) == "LIVE" and int(first[1]) >= SCORE_LIMIT - 2
				and int(first[1]) < SCORE_LIMIT,
			"while the round was live, two short of the limit (%s at %d)" % [first[0], first[1]]
		)

	_check(
		_vote.director.clock.top_score == _game.match_node.scoreboard.best_score()
			and _vote.director.clock.top_score >= SCORE_LIMIT,
		"and followed the leader to the match's own limit (%d)" % _vote.director.clock.top_score
	)
	_check(
		_vote.director.clock.rounds_played == 1,
		"and dot-match's round end reached it (%d)" % _vote.director.clock.rounds_played,
		"ArenaVote.note_round_end existed and was called by nothing"
	)

	# [b]A new match is followed without a map change.[/b] `arena_mode` calls
	# `game.change_map` directly, which builds a new match and never fires
	# `maps.map_changed` — and a vote bound only there held the freed match: no score, no
	# round end. A stand-in match node here rather than a real mode change, which would
	# replace the match every section after this one reads.
	var real_match: DotMatch = _game.match_node
	var stand_in := DotMatch.new()
	_game.match_node = stand_in
	_vote.advance(1.0 / float(TICK_RATE))
	var followed: bool = _vote.get("_match") == stand_in \
		and stand_in.round_ended.is_connected(_vote._on_round_ended)
	_game.match_node = real_match
	_vote.advance(1.0 / float(TICK_RATE))
	_check(
		followed and _vote.get("_match") == real_match
			and not stand_in.round_ended.is_connected(_vote._on_round_ended),
		"and it follows a new match the moment the game has one, and lets the old one go",
		"a mode change builds a match without map_changed, and the vote kept the freed one"
	)
	stand_in.free()

	_vote.director.close_vote()
	_vote.queue_free()
	_vote.maps.queue_free()
	_vote = null
	_done()


func _test_outcome() -> void:
	_section("what happened")

	_check(_kills.size() > 0, "bots killed each other", "%d kills" % _kills.size())

	# Every kill must have a killer and a victim the scoreboard knows about. A kill
	# credited to nobody is the "the attacker disconnected" path, and at four bots that
	# never leave it should not happen.
	var orphans := 0
	for entry in _kills:
		if entry.suicide:
			continue
		if entry.killer_key == "" or entry.victim_key == "":
			orphans += 1
	_check(orphans == 0, "and every kill is attributed", "%d orphaned" % orphans)

	var board := _game.match_node.scoreboard
	var total_kills := 0
	var total_deaths := 0

	for record in board.players():
		total_kills += record.kills
		total_deaths += record.deaths

	_check(total_kills > 0, "the scoreboard recorded them", str(total_kills))
	_check(
		total_deaths >= total_kills,
		"and a death for each, plus any suicides",
		"%d deaths, %d kills" % [total_deaths, total_kills]
	)

	# Respawning is what makes it a deathmatch rather than one round of elimination.
	_check(
		_spawns.size() > BOTS,
		"players respawned after dying",
		"%d spawns for %d bots" % [_spawns.size(), BOTS]
	)

	var leader := board.leader()
	_check(leader != null, "there is a leader")
	_check(
		leader.score >= SCORE_LIMIT,
		"who reached the score limit",
		"%d of %d" % [leader.score, SCORE_LIMIT]
	)

	_check(
		_game.match_node.last_outcome() == DotMatchRules.Outcome.SCORE,
		"and the match ended because of it",
		DotMatchRules.Outcome.keys()[_game.match_node.last_outcome()]
	)

	_check(_states.has("MATCH_END"), "the match reached MATCH_END", str(_states))

	# Damage was actually tracked, not merely inferred from kills.
	var dealt := 0.0
	for record in board.players():
		dealt += record.damage_dealt
	_check(dealt > 0.0, "damage was recorded", "%.0f" % dealt)

	# Loadouts reached the arsenals. A player holding nothing is a player whose
	# loadout never arrived, and they would still be able to kill with the default.
	var armed := 0
	for player in _game.players():
		if player.arsenal.slots().size() >= 2:
			armed += 1
	_check(armed == BOTS, "every bot is holding its loadout", "%d of %d" % [armed, BOTS])

	# The combat manager saw real work, including refusals — a shot fired while dead
	# or during a respawn is normal and must be refused rather than resolved.
	var stats := _game.combat.describe()
	_check(
		int(stats["resolved"]) > 0,
		"shots were resolved",
		str(stats["resolved"])
	)
	_done()


## The HUD and the menus, built and driven headlessly.
##
## Nothing is rendered — there is no display — and nothing here needs to be. What is
## checked is the wiring: that a widget bound to a game value reads the right one, that
## the scoreboard screen fills from the match that just finished, and that the screen
## stack keeps its four invariants straight when a scoreboard is held down over a pause
## menu.
func _test_interface() -> void:
	_section("the interface")

	var ui_config := DotUiConfig.new()
	ui_config.allow_pause = false

	var stack := DotScreenStack.new()
	stack.name = "Screens"
	stack.register_service = false
	# Nothing owns a cursor in a headless run, and fighting over Input.mouse_mode in a
	# test is a way to make it depend on the environment.
	stack.manage_mouse = false
	stack.config = ui_config
	add_child(stack)

	var hud := ArenaHud.new()
	hud.name = "Hud"
	hud.config = ui_config
	add_child(hud)
	hud.build(_game)
	hud.bind_stack(stack)

	var subject := _game.players()[0]
	hud.follow(subject)
	hud.refresh_all()

	_check(hud.crosshair != null and hud.health_bar != null, "the HUD builds")
	_check(
		absf(float(hud.health_bar.value) - subject.health.health) < 0.01,
		"and its health bar reads the player it follows",
		"%s vs %.1f" % [hud.health_bar.value, subject.health.health]
	)

	subject.health.health = 33.0
	hud.refresh_all()
	_check(
		absf(float(hud.health_bar.value) - 33.0) < 0.01,
		"and follows it when it changes"
	)

	# The crosshair opens by the real projection. A fixed gap here would mean the
	# binding is not reaching the weapon at all.
	#
	# [b]Both readings are taken AFTER a refresh, and the first version of this was
	# not.[/b] `gap_pixels()` reports whatever spread the last `refresh_all()` put
	# into the crosshair, so measuring `still` without refreshing first measured the
	# subject's spread as it happened to be when the match ended — and this subject
	# is a bot picked out of a finished deathmatch, so on the runs where it stopped
	# while moving, `still` was already the wide gap and the comparison against
	# movement = 1.0 could not beat it. One run in twelve, on a check about the
	# binding rather than about the bot.
	# The spread is read off the simulated movement state rather than a field on the
	# arsenal now: dot-weapon hands a behaviour a context per tick instead of keeping
	# posture on the arsenal, so the thing to move is the player.
	# [b]And holding something that HAS spread.[/b] `spread_degrees()` reads the
	# CURRENT slot's tuning and returns a flat zero unless it is
	# [DotWeaponBallistics] -- so a subject that finished the match on a weapon
	# without ballistics reported no spread standing still and no spread sprinting,
	# and `gap_pixels()` came back as `base_gap` twice. The check then failed saying
	# "4.6 -> 4.6", which is indistinguishable from the binding being broken and is
	# the one thing it is supposed to detect.
	#
	# Whether that happened depended on what a bot happened to be holding when a
	# simulated deathmatch ended, so it surfaced as roughly one run in five once
	# DotSpread's mixer changed which shots landed. Selecting the weapon makes the
	# check about the binding again.
	for slot_index in subject.arsenal.slots():
		var slot := subject.arsenal.slot_at(slot_index)

		if slot != null and slot.def.tuning is DotWeaponBallistics:
			subject.arsenal.select(slot_index, _game.current_tick())
			break

	# [b]And standing on the ground, uncrouched.[/b] `DotWeaponBallistics.spread_for`
	# returns the airborne spread whatever the speed, so a subject that the finished
	# match left in mid-air -- a bot mid-hop off a crate -- read "4.6 -> 4.6" holding a
	# rifle: one run in eight on 2026-09-27, with every weapon fix above already in.
	# Only the posture is set; the position is wherever the match left it.
	var posture_was := subject.controller.state.mode
	var crouch_was := subject.controller.state.crouch_fraction
	subject.controller.state.mode = DotFpsState.Mode.GROUND
	subject.controller.state.crouch_fraction = 0.0

	subject.controller.state.velocity = Vector3.ZERO
	hud.refresh_all()
	var still := hud.crosshair.gap_pixels()

	subject.controller.state.velocity = Vector3(8.0, 0.0, 0.0)
	hud.refresh_all()
	_check(
		hud.crosshair.gap_pixels() > still,
		"and the crosshair opens when the player moves",
		"%.1f -> %.1f, holding %s" % [
			still,
			hud.crosshair.gap_pixels(),
			subject.arsenal.current_def().id if subject.arsenal.current_def() != null
				else "nothing"
		]
	)
	subject.controller.state.mode = posture_was
	subject.controller.state.crouch_fraction = crouch_was

	# [b]And it turns spread into pixels through the field of view the camera is really
	# drawing with.[/b] It was a constant 75 while the camera was the player's setting
	# converted from horizontal-at-4:3 — 83.6 vertical at the default of 100 — so every
	# gap was drawn 17% too wide, and 69% at 120. Two settings, because one could agree
	# with a stale copy by coincidence; the second is a slider moved mid-game.
	var had_camera := subject.camera != null
	subject.attach_camera(100.0)
	hud.match_view()
	_check(
		is_equal_approx(hud.crosshair.fov_degrees, subject.camera.fov)
		and not is_equal_approx(subject.camera.fov, 75.0),
		"the crosshair measures with the camera's field of view",
		"crosshair %.2f, camera %.2f" % [hud.crosshair.fov_degrees, subject.camera.fov]
	)
	subject.attach_camera(120.0)
	hud.match_view()
	_check(
		is_equal_approx(hud.crosshair.fov_degrees, subject.camera.fov),
		"and follows it when the player changes it",
		"crosshair %.2f, camera %.2f" % [hud.crosshair.fov_degrees, subject.camera.fov]
	)
	if not had_camera:
		subject.camera.queue_free()
		subject.camera = null

	# This HUD was built after the match ended, which is exactly what a client joining
	# a match in progress looks like: the kills already happened and the signal has
	# already fired. catch_up() is what fills it, and a HUD without it is empty until
	# the next person dies.
	_check(hud.feed.line_count() == 0, "a fresh HUD starts with an empty feed")
	var caught := hud.catch_up()
	_check(caught > 0, "and catches up on the kills it missed", "%d entries" % caught)
	_check(
		hud.feed.line_count() == caught,
		"which is what it then shows"
	)

	var pause := ArenaMenus.install(stack, _game, ui_config)
	_check(pause != null, "the menus install")
	_check(stack.registered_ids().size() == 4, "all four screens register",
		str(stack.registered_ids()))
	# [b]The browser screen was registered and nothing ever pushed it.[/b] A whole server
	# list — sources, a filter, favourites and a join — built on every launch of the client
	# and unreachable from anywhere. There is a Servers button now, and it is greyed here
	# because this fixture has no browser, which is the same rule the Settings button
	# follows. `ArenaClient` calls `note_screens` once its list has come up.
	var servers_button := pause.button(&"servers")
	_check(servers_button != null, "the pause menu has a Servers button")
	_check(
		servers_button != null and servers_button.disabled,
		"greyed where there is no browser, rather than opening nothing"
	)

	stack.push(&"scoreboard")
	var scoreboard := stack.screen(&"scoreboard") as ArenaMenus.ScoreboardScreen
	_check(
		scoreboard.board.is_open() and scoreboard.board.rows().size() == BOTS,
		"the scoreboard fills from the match that just ended",
		"%d rows" % scoreboard.board.rows().size()
	)

	# The distinction dot-ui exists to keep straight: a scoreboard held down during a
	# live game must not stop the player moving, and must not hide the game.
	_check(hud.visible, "a scoreboard does not take the HUD down")
	_check(
		not scoreboard.blocks_input,
		"and does not block input"
	)

	stack.push(&"pause")
	_check(not hud.visible, "an opaque pause menu does take it down")
	_check(stack.depth() == 2, "and stacks over the scoreboard")

	# `interface`, not `settings`. The screen built from `DotUiConfig` offers the scale,
	# the safe area and how many chat lines the HUD keeps -- real settings, and not one of
	# them is what a player means by the word. `settings` is the player's own document now,
	# and a player who opened this menu to turn the game down used to find a slider for the
	# interface scale.
	stack.push(&"interface")
	_check(stack.top_id() == &"interface", "the interface screen opens over the pause menu")
	var settings := stack.screen(&"interface") as DotSettingsScreen
	_check(
		settings != null and settings.panel.editor_for("scale") != null,
		"and generated a control for the UI scale"
	)
	_check(
		stack.screen(&"settings") == null,
		"while `settings` is the player's own, which this fixture has no manager for"
	)
	var settings_button := pause.button(&"settings")
	_check(
		settings_button != null and settings_button.disabled,
		"so its button is greyed out rather than opening nothing"
	)

	# dot-ui's screens rather than copies of them. This game carried its own pause menu and
	# its own settings screen for as long as `DotPauseScreen` and `DotSettingsScreen` have
	# existed, which is the duplication that addon was written to end -- and it is also the
	# only client in the family with TWO settings screens in one stack, which is exactly the
	# case `id_override` exists for.
	_check(pause is DotPauseScreen, "the pause screen is the shared one")
	_check(
		pause.ids() == ([&"resume", &"settings", &"interface", &"controls", &"servers",
			ArenaMenus.LEAVE] as Array[StringName]),
		"and its ids come from its labels (%s)" % [pause.ids()]
	)
	_check(
		settings != null and settings.title_text == "Interface",
		"the interface screen says Interface on it, not Settings"
	)

	stack.pop()
	_check(stack.top_id() == &"pause", "closing it reveals the pause menu")

	stack.clear()
	_check(hud.visible, "and clearing everything brings the HUD back")

	hud.queue_free()
	remove_child(hud)
	stack.queue_free()
	remove_child(stack)
	_done()


# --- Progression -----------------------------------------------------------

## dot-stats, dot-achievements and dot-leaderboard, over the match that just ran.
##
## [b]Every check here is against a number the match PRODUCED, not one this test
## filed.[/b] That is the whole point: a progression suite that records its own
## readings and then reads them back is testing dot-stats, which dot-stats already
## does. What is untested anywhere else is whether a kill in this game reaches those
## three addons at all, and the family's own list is full of values produced correctly
## and consumed by nobody.
func _test_progression() -> void:
	_section("progression")

	var progress := _game.progress

	if not _check(progress != null, "the game keeps progress"):
		return

	_check(
		progress.stats != null and progress.achievements != null
			and progress.boards != null,
		"stats, achievements and boards are all up"
	)

	# The catalogue's own validator is what refuses one stat read with two merge
	# rules — a running total and a personal best cannot be one number — and it is
	# checked here rather than trusted because the symptom otherwise is one
	# achievement that never unlocks, for one player, with nothing erroring.
	var catalogue_ok := progress.achievements.catalogue.validate()
	_check(catalogue_ok.ok, "the achievement catalogue validates", str(catalogue_ok.error))

	var schema_ok := progress.stats.schema.validate()
	_check(schema_ok.ok, "the stats schema validates", str(schema_ok.error))

	# Every stat an achievement reads must be a stat the schema declares. Nothing in
	# either addon can check this: dot-achievements does not know the schema exists,
	# and dot-stats does not know the catalogue does. It is exactly the "two ends of
	# one serialisation that never met" shape, and it is one loop.
	var undeclared := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not progress.stats.schema.has(stat):
			undeclared.append(String(stat))

	_check(
		undeclared.is_empty(),
		"every stat an achievement watches is one the schema declares",
		", ".join(undeclared)
	)

	# --- What the match actually filed -----------------------------------

	var total_kills := 0.0
	var total_fired := 0.0
	var total_hit := 0.0
	var any_deaths := false
	var best_streak := 0.0

	for player in _game.players():
		var values := progress.session_values(player.player_id)
		total_kills += values.get_value(ArenaStats.KILLS, 0.0)
		total_fired += values.get_value(ArenaStats.SHOTS_FIRED, 0.0)
		total_hit += values.get_value(ArenaStats.SHOTS_HIT, 0.0)
		best_streak = maxf(best_streak, values.get_value(ArenaStats.BEST_STREAK, 0.0))

		if values.get_value(ArenaStats.DEATHS, 0.0) > 0.0:
			any_deaths = true

	# The kill feed is the independent witness. Suicides carry no killer, so the
	# stat total is the feed's count minus those — asserting equality against the
	# raw feed size would fail the moment a bot rocket-jumped into a wall.
	var credited := 0

	for entry in _kills:
		if entry.killer_key != "" and not entry.suicide:
			credited += 1

	_check(
		total_kills == float(credited),
		"every credited kill reached dot-stats",
		"feed %d, stats %d" % [credited, int(total_kills)]
	)

	_check(any_deaths, "deaths were counted too")

	_check(
		total_fired > 0.0,
		"shots fired were counted",
		"%d" % int(total_fired)
	)

	# One shot is one shot whatever it fired. If this counted damage events instead,
	# a shotgun's nine pellets would make hits exceed shots and a shotgun player nine
	# times as accurate as a rifle player.
	_check(
		total_hit <= total_fired,
		"shots landed never exceed shots fired",
		"%d hit of %d fired" % [int(total_hit), int(total_fired)]
	)

	_check(
		best_streak >= 1.0,
		"a best streak was filed as a best rather than a sum",
		"%d" % int(best_streak)
	)

	# --- Achievements ----------------------------------------------------
	#
	# First Blood is one kill, and the match above produced six. If the link between
	# dot-stats and dot-achievements were wired straight through — the bug
	# DotAchievementStatsLink exists to prevent — this would still pass; what it
	# proves is that the two are connected at all.
	var unlocked_any := false

	for player in _game.players():
		if progress.achievements.is_unlocked(
			ArenaGame.storage_key(player.player_id), &"arena.first_blood"
		):
			unlocked_any = true

	_check(unlocked_any, "somebody unlocked First Blood")

	# The differencing itself. A player with N session kills must hold N lifetime
	# kills, not the running sum 1+2+...+N that a direct signal connection produces —
	# which for six kills is twenty-one and for a hundred is five thousand.
	var mismatched := PackedStringArray()

	for player in _game.players():
		var key := ArenaGame.storage_key(player.player_id)
		var held := progress.achievements.progress_of(key)

		if held == null:
			continue

		var session := progress.session_values(player.player_id).get_value(
			ArenaStats.KILLS, 0.0
		)

		if absf(held.value_of(ArenaStats.KILLS) - session) > 0.001:
			mismatched.append("%s: lifetime %.0f, session %.0f" % [
				key, held.value_of(ArenaStats.KILLS), session
			])

	_check(
		mismatched.is_empty(),
		"lifetime kills equal session kills, so the link differences rather than sums",
		", ".join(mismatched)
	)

	# --- Boards ----------------------------------------------------------
	#
	# Filed when a player leaves, so this removes one. It is also the only place
	# `leave` is exercised, and it is a coroutine — the achievement store may be
	# remote — so it is awaited here where a disconnect handler would not.
	var leaver := _game.players()[0]
	var leaver_key := StringName(ArenaGame.storage_key(leaver.player_id))
	var leaver_kills := progress.session_values(leaver.player_id).get_value(
		ArenaStats.KILLS, 0.0
	)

	await progress.leave(leaver.player_id)

	var scope := ArenaBoards.scope_for(_game.mode.id)
	var entry := progress.boards.entry_for(ArenaBoards.KILLS, scope, leaver_key)

	if leaver_kills > 0.0:
		_check(
			entry.ok and entry.value is DotLeaderboardEntry,
			"a player who leaves lands on the kills board"
		)

		if entry.ok and entry.value is DotLeaderboardEntry:
			_check(
				absf((entry.value as DotLeaderboardEntry).value - leaver_kills) < 0.001,
				"with the number they actually scored",
				"board %s, session %d" % [
					str((entry.value as DotLeaderboardEntry).value), int(leaver_kills)
				]
			)
	else:
		# A zero is deliberately NOT filed: a SCORE board of zeroes is noise and a
		# zero on the PENALTY board would hold first place for ever.
		_check(
			not (entry.ok and entry.value is DotLeaderboardEntry),
			"a player who scored nothing is not put on a board"
		)

	# Every board this game defines has to be one the manager will accept. A
	# definition rejected at boot is a board that silently holds nothing.
	var defined := progress.boards.definitions().size()
	_check(
		defined == ArenaBoards.definitions().size(),
		"every board definition was accepted",
		"%d of %d" % [defined, ArenaBoards.definitions().size()]
	)
	_done()


# --- Changing the map ------------------------------------------------------

## dot-map, over the game that is already running, with players standing in it.
##
## [b]This is the deployment shape that did not exist.[/b] Every check in dot-map's own
## suite runs a [DotMapSession] whose maps are scenes, and every check in this one used
## to run a game whose map was chosen at boot. What is untested anywhere else is the
## join: a catalogue built from code-made maps, a session that builds rather than loads,
## and an [ArenaGame] that has to tear down a combat manager and a match node it did not
## expect to lose.
func _test_map_change() -> void:
	_section("changing the map")

	var catalogue := ArenaMaps.catalogue()

	# The built-ins and every imported combat surf map the link holds (none without it).
	var buildable := ArenaMap.ids().size() + ArenaMap.imported_ids().size()
	_check(
		catalogue.size() == buildable,
		"every map ArenaMap can build is in the catalogue",
		"%d of %d" % [catalogue.size(), buildable]
	)

	var problems := catalogue.problems()
	_check(problems.is_empty(), "and every entry validates", ", ".join(problems))

	# A map def whose scene path does not exist is a def that fails at the change
	# rather than at the boot, which is the whole reason the path is a real file
	# rather than a `code://` sentinel.
	var missing := PackedStringArray()

	for def in catalogue.maps:
		if not ResourceLoader.exists(def.scene_path) and not FileAccess.file_exists(def.scene_path):
			missing.append("%s -> %s" % [String(def.id), def.scene_path])

	_check(
		missing.is_empty(),
		"and every one points at a file that exists",
		", ".join(missing)
	)

	var director := ArenaMapDirector.new()
	director.name = "Maps"
	director.game = _game
	director.map_seconds = 0.0
	director.rotation_cooldown = 8
	add_child(director)

	var ready := director.setup()

	if not _check(ready.ok, "the map director sets up", str(ready.error)):
		return

	# Eight was asked for over a two-map catalogue, which would be a rotation that can
	# never offer anything. dot-map's `on_cooldown` takes a pool size for this reason
	# and the director clamps rather than letting the value silently mean "never".
	_check(
		director.session.rotation.cooldown <= maxi(catalogue.size() - 1, 0),
		"a cooldown larger than the catalogue is reduced to fit",
		"%d over %d maps" % [director.session.rotation.cooldown, catalogue.size()]
	)

	_check(
		director.current != null and director.current.id == _game.map.id,
		"it adopts the map already running rather than changing to it"
	)

	# --- The change itself ------------------------------------------------

	var before_id := _game.map.id
	var before_players := _game.players().size()
	var target: StringName = &"dm_atrium" if before_id == &"dm_box" else &"dm_box"

	var kills_before := 0.0

	for player in _game.players():
		kills_before += _game.progress.session_values(player.player_id).get_value(
			ArenaStats.KILLS, 0.0
		)

	var changed_to: Array[StringName] = []
	_game.map_changed.connect(func(m: ArenaMap) -> void: changed_to.append(m.id))

	var changed: DotResult = await director.change_to(target)

	_check(changed.ok, "the map changes under the players", str(changed.error))
	_check(_game.map.id == target, "and the game is on the new one")
	_check(changed_to.has(target), "and map_changed fired for it")

	_check(
		_game.players().size() == before_players,
		"every player survived the change",
		"%d of %d" % [_game.players().size(), before_players]
	)

	# --- What has to have been rebuilt ------------------------------------

	_check(
		_game.combat != null and _game.match_node != null,
		"the combat manager and the match node were rebuilt"
	)

	var registered := 0

	for player in _game.players():
		if _game.combat.hitboxes_of(player.player_id) != null:
			registered += 1

	_check(
		registered == _game.players().size(),
		"and every player is shootable in the new one",
		"%d of %d" % [registered, _game.players().size()]
	)

	var expected_spawns := ArenaMap.by_id(target).spawns.size()
	_check(
		_game.match_node.spawn_points().size() == expected_spawns,
		"the spawn points are the new map's",
		"%d, expected %d" % [_game.match_node.spawn_points().size(), expected_spawns]
	)

	# The trace is the map. Rebuilding the manager and forgetting the trace would
	# leave every shot resolving against the geometry of a room nobody is in — and
	# nothing would error, because a trace that hits nothing is a legitimate answer.
	var new_map := ArenaMap.by_id(target)
	var outward := _game.combat.trace.ray(
		Vector3(0.0, 2.0, 0.0), Vector3.RIGHT, new_map.extent * 4.0
	)
	_check(
		outward.ok() and outward.blocked
			and outward.distance < new_map.extent + 3.0,
		"and a shot at the new perimeter stops at it",
		"%.1f m, extent %.1f" % [outward.distance, new_map.extent]
	)

	_check(
		_game.combat.trace is DotTraceFlat
			and (_game.combat.trace as DotTraceFlat).boxes.size() == new_map.boxes.size(),
		"the trace holds the new map's boxes and not the old one's",
		"%d, expected %d" % [
			(_game.combat.trace as DotTraceFlat).boxes.size(), new_map.boxes.size()
		]
	)

	# --- Progression across a change --------------------------------------
	#
	# `ArenaProgress` is connected to the combat manager and the match node, both of
	# which were just freed. If `rebind_world` had not run it would still be listening
	# to two dead objects and counting nothing — silently, because a signal that is
	# never emitted looks exactly like a quiet game.
	var alive := _game.players()

	if alive.size() >= 2:
		var shooter := alive[0]

		# [b]An ENEMY, not simply the next player in the list.[/b] Belt and braces
		# rather than the fix: the resolver refuses a shot at a team-mate outright
		# when friendly fire is off, and by this point in the run a team mode has
		# assigned everybody, so taking `alive[1]` was one more emergent property
		# this check did not mean to sample. Team 0 is "no team" and the resolver
		# does not treat two unassigned players as allies, so the fallback is right
		# in a free-for-all rather than merely tolerable.
		var victim: ArenaPlayer = alive[1]

		for candidate in alive.slice(1):
			if _game.team_of(candidate.player_id) \
					!= _game.team_of(shooter.player_id):
				victim = candidate
				break

		# Put the victim back in the world first. The match that just ended left
		# everybody dead, and damage to a dead entity is correctly refused — so a
		# probe that skipped this would report "nothing was counted" for a reason that
		# has nothing to do with what it is testing.
		victim.hitboxes.enabled = true
		victim.spawn(
			Transform3D(Basis.IDENTITY, Vector3(0.0, new_map.floor_y + 1.0, 0.0)),
			_game.current_tick(),
			0
		)

		# [b]And out of dot-spawn's ledger, which `victim.spawn(..., 0)` does not
		# clear.[/b] The zero above is `DotHealth`'s window; the map change respawned
		# everybody through `_on_respawn_due` and that is what grants the session-scoped
		# protection the resolver now asks about. Two records of one idea, and hand-
		# spawning somebody only clears the one it was handed.
		if _game.player_stack != null and _game.player_stack.spawns.protection != null:
			_game.player_stack.spawns.protection.revoke(
				str(victim.player_id), _game.current_tick()
			)

		# [b]And THREE records, not two.[/b] `ArenaPlayerStack.refresh_spawn_rules`
		# says it outright -- spawn protection is enforced by [DotHealth]'s window,
		# by dot-spawn's ledger, and by the `arena_protected` effect -- and this
		# cleared the first two. `ArenaEffects.adjust_damage` asks the effect manager
		# first of all three, so on any run where the respawn above happened recently
		# enough for the effect to still be up, `apply_damage` came back refused and
		# the check read as a rebind that had not happened.
		#
		# It went unnoticed because whether the effect was still up depended on the
		# emergent end state of a simulated deathmatch. Changing DotSpread's mixer --
		# which changed no behaviour, only which numbers came out -- moved it to
		# roughly one run in ten. A check about `rebind_world` should not be sampling
		# a match, and the failure message now carries `damage.refusal` so the next
		# one of these says which gate refused instead of only "0.0".
		if _game.effects != null and _game.effects.manager != null:
			_game.effects.manager.remove(
				ArenaEffects.PROTECTED, victim.player_id
			)

		var before := _game.progress.session_values(shooter.player_id).get_value(
			ArenaStats.DAMAGE_DEALT, 0.0
		)

		# Stamped, because an unstamped `DotDamage` is tick 0 and every gate that
		# compares a tick against a window refuses it for ever. `ArenaEffects` carries
		# the same warning and names where this family found it the first time.
		var event := DotDamage.make(
			shooter.player_id, victim.player_id, 10.0,
			_game.combat.damage_type(ArenaContent.DAMAGE_BULLET)
		)
		event.tick = _game.current_tick()

		var damage := _game.combat.apply_damage(event)

		var after := _game.progress.session_values(shooter.player_id).get_value(
			ArenaStats.DAMAGE_DEALT, 0.0
		)

		# The refusal reason is in the message because without it this check says
		# only "0.0", and every reason the resolver has for refusing looks
		# identical from here.
		_check(
			damage.health_lost > 0.0,
			"a rebuilt combat manager still applies damage",
			"lost %.1f%s" % [
				damage.health_lost,
				", refused: %s" % damage.refusal if damage.refused else ""
			]
		)
		_check(
			after > before,
			"progress is still counting after the world was replaced",
			"%.0f -> %.0f, damage %.1f" % [before, after, damage.health_lost]
		)

	var kills_after := 0.0

	for player in _game.players():
		kills_after += _game.progress.session_values(player.player_id).get_value(
			ArenaStats.KILLS, 0.0
		)

	# A session is a visit to the server, not a visit to a room. Resetting here would
	# mean a player's numbers restart every time the map does.
	_check(
		kills_after >= kills_before,
		"and session totals survived the change",
		"%d before, %d after" % [int(kills_before), int(kills_after)]
	)

	# --- Players can still move -------------------------------------------
	#
	# The motor holds a reference to the body it was built with, so a player handed
	# new geometry without a rebuilt motor keeps colliding against the level they are
	# no longer in. The symptom is a player wedged in mid-air with every property
	# reading correctly, which no assertion about a property can see.
	for tick in range(32):
		_game.tick(_commands_for_tick(1000 + tick))

	var below := 0

	for player in _game.players():
		if player.controller.state.position.y < new_map.floor_y - 1.0:
			below += 1

	_check(
		below == 0,
		"nobody fell through the new floor",
		"%d below it" % below
	)

	# --- A box where somebody was standing -------------------------------
	#
	# [b]The check above passes on the shipped maps by luck of layout.[/b] A map change
	# used to keep every player's position and swap the geometry under them, so a
	# player standing where the next map has a box was inside it, and the flat body
	# resolved that downwards: building `dm_atrium`'s keep, a box across its south door
	# landed on a position carried over from `dm_box` and one player ended the section
	# under the floor. Here the coincidence is made on purpose: a player is put on a
	# known patch of open floor, and the map changed to is this one plus a box on
	# exactly that patch.
	var trap_map := ArenaMap.by_id(_game.map.id)
	var standing: Variant = _open_floor_away_from_spawns(trap_map)

	if _check(
		standing != null,
		"there is open floor away from every spawn to build a box on",
		String(trap_map.id)
	):
		var carried: ArenaPlayer = _game.players()[0]
		carried.controller.teleport(standing as Vector3, 0.0, 0.0)
		trap_map.add_box(_trap_at(standing as Vector3))

		var trapped := _game.change_map(trap_map)

		_check(
			trapped.ok,
			"the map changes to one with a box where player %d is standing"
				% carried.player_id,
			str(trapped.error)
		)

		var inside := _players_inside_boxes(trap_map)
		_check(
			inside.is_empty(),
			"and nobody is inside a box of the new map once it has",
			"inside: %s" % str(inside)
		)

		var astray := PackedStringArray()

		for player in _game.players():
			var nearest := _nearest_spawn(trap_map, player.controller.state.position)

			if float(nearest[1]) > 0.5:
				astray.append("%d %.1f m from a spawn" % [player.player_id, float(nearest[1])])

		_check(
			astray.is_empty(),
			"every player is at a spawn point of the new map, respawned rather than "
			+ "carried over",
			", ".join(astray)
		)

		for tick in range(32):
			_game.tick(_commands_for_tick(1100 + tick))

		var under := 0

		for player in _game.players():
			if player.controller.state.position.y < trap_map.floor_y - 1.0:
				under += 1

		inside = _players_inside_boxes(trap_map)
		_check(
			under == 0 and inside.is_empty(),
			"and after half a second of play nobody is inside a box or under the floor",
			"%d under it, inside: %s" % [under, str(inside)]
		)

	# --- The mode gate, over a live rotation -------------------------------
	#
	# [b]Last, because it moves the game into a team mode and back.[/b] Nothing below
	# depends on the state this leaves, and nothing above should have to care.
	#
	# What is being checked is the hole `dm_pit` opened. dot-map's rotation filters on
	# player count and cooldown and knows nothing about modes, and until this map every
	# map here could host every mode -- so an unfiltered rotation and a filtered one
	# were the same rotation. The first map that answers no is the first map a team game
	# could have been dropped into with nothing said about it.
	var team := _first_team_mode()

	if team != null:
		var to_team := _game.change_map(ArenaMap.by_id(_game.map.id), team)

		if _check(to_team.ok, "the game moves into a team mode", str(to_team.error)):
			# The respawn a map change now does is the round start's, so it has to
			# honour the sides the new mode just assigned: a side's spawn tag, or an
			# untagged point both may use.
			var wrong_side := PackedStringArray()

			for player in _game.players():
				var nearest := _nearest_spawn(_game.map, player.controller.state.position)
				var tag := _game.map.spawn_tag(int(nearest[0]))
				var wanted := _spawn_tag_of_team(_game.team_of(player.player_id))

				if float(nearest[1]) > 0.5 or (tag != &"" and tag != wanted):
					wrong_side.append("%d (%s) at a %s spawn, %.1f m" % [
						player.player_id, String(wanted), String(tag), float(nearest[1])
					])

			_check(
				wrong_side.is_empty(),
				"and the change puts each side at its own spawns",
				", ".join(wrong_side)
			)

			director.restrict_rotation()

			_check(
				not director.session.rotation.order.has(&"dm_pit"),
				"the rotation stops offering dm_pit while a team mode is played",
				str(director.session.rotation.order)
			)
			_check(
				director.session.rotation.order.has(&"dm_box")
					and director.session.rotation.order.has(&"dm_atrium"),
				"and still offers the two that can host it"
			)

			# Asked for by name, which is what an admin typing `changelevel` does and
			# what a rotation cannot be made to stop doing. This is the backstop: even
			# reached directly, the change has to be refused rather than quietly produce
			# a team game with one shared spawn pool.
			var refused: DotResult = await director.change_to(&"dm_pit")

			_check(
				not refused.ok,
				"and changing to it by name is refused outright"
			)
			_check(
				_game.map.id != &"dm_pit",
				"with the game left on the map it was on",
				String(_game.map.id)
			)

			var back := _game.change_map(
				ArenaMap.by_id(_game.map.id), ArenaMode.free_for_all()
			)

			if _check(back.ok, "the game goes back to a free-for-all", str(back.error)):
				director.restrict_rotation()

				_check(
					director.session.rotation.order.has(&"dm_pit"),
					"and dm_pit is offered again",
					str(director.session.rotation.order)
				)

	director.queue_free()
	remove_child(director)
	_done()


## The two-metre box [method _test_map_change] builds on top of a player.
func _trap_at(standing: Vector3) -> AABB:
	return AABB(standing + Vector3(-1.0, -0.05, -1.0), Vector3(2.0, 2.4, 2.0))


## The first patch of bare floor, scanning in a fixed order, where a trap box would
## touch no other box and would sit at least four metres from every spawn — so the only
## way a player ends up inside it is by having been left there.
func _open_floor_away_from_spawns(map: ArenaMap) -> Variant:
	var reach := int(map.extent) - 3

	for x in range(-reach, reach + 1, 2):
		for z in range(-reach, reach + 1, 2):
			var at := Vector3(float(x), map.floor_y + 0.05, float(z))
			var trap := _trap_at(at)
			var clear := true

			for box in map.boxes:
				# The floor itself is the one box a trap stands on rather than in.
				if box.end.y <= map.floor_y + 0.01:
					continue

				if box.intersects(trap.grow(0.5)):
					clear = false
					break

			if not clear:
				continue

			if float(_nearest_spawn(map, at)[1]) < 4.0:
				continue

			return at

	return null


## Which spawn of [param map] is nearest [param at], and how far: [index, metres].
func _nearest_spawn(map: ArenaMap, at: Vector3) -> Array:
	var best := -1
	var best_distance := INF

	for index in range(map.spawns.size()):
		var distance := map.spawns[index].origin.distance_to(at)

		if distance < best_distance:
			best = index
			best_distance = distance

	return [best, best_distance]


## The spawn tag of match team [param team_id], or empty outside a team mode.
func _spawn_tag_of_team(team_id: int) -> StringName:
	for team in _game.teams():
		if team.id == team_id:
			return team.spawn_tag

	return &""


## Every player whose body is inside a box of [param map], by id. Two points up the
## body rather than the feet, because a player standing ON a box has their feet on its
## top face and is exactly where they should be.
func _players_inside_boxes(map: ArenaMap) -> Array[int]:
	var out: Array[int] = []

	for player in _game.players():
		var feet := player.controller.state.position

		for box in map.boxes:
			var solid := box.grow(-0.05)

			if solid.has_point(feet + Vector3.UP * 0.3) or solid.has_point(feet + Vector3.UP * 1.2):
				out.append(player.player_id)
				break

	return out


# --- Monsters --------------------------------------------------------------

## dot-npc, dot-npc-ai and dot-npc-ai-director, over this game's own geometry.
##
## [b]Every one of the three passes its own suite with the other two absent, and with
## no combat layer at all.[/b] What is untested anywhere else is the joins: navigation
## generated from a map that is a list of boxes rather than a scene, a brain reaching
## the game through the registry because it was loaded from a path and could not be
## handed anything, and a monster registered with dot-combat in an id space it must
## never share with a player.
func _test_horde() -> void:
	_section("monsters")

	var catalogue := ArenaNpcs.catalogue()
	_check(catalogue.size() == 4, "four monsters are catalogued: three that close and one that shoots")

	var bad := PackedStringArray()

	for def in catalogue.npcs:
		var valid := def.validate()

		if not valid.ok:
			bad.append("%s: %s" % [String(def.id), valid.error.message])
		elif not ResourceLoader.exists(def.scene_path):
			bad.append("%s has no scene" % String(def.id))
		elif not ResourceLoader.exists(def.brain_script_path):
			bad.append("%s has no brain" % String(def.id))

	_check(bad.is_empty(), "and every one has a scene and a brain that exist", ", ".join(bad))

	# --- Navigation -------------------------------------------------------

	var nav := ArenaNpcs.nav_for(_game.map)
	var nav_ok := nav.validate()
	_check(nav_ok.ok, "navigation generates from the map's boxes", str(nav_ok.error))
	_check(nav.point_count() > 32, "with a usable number of points", "%d" % nav.point_count())
	_check(nav.edge_count() > 0, "and edges between them", "%d" % nav.edge_count())

	# The digest is what tells "a graph for this map" from "a graph for a map with the
	# same name". A graph that matched a map whose geometry moved is a graph whose
	# monsters walk through the walls somebody added since.
	_check(
		nav.matches(ArenaNpcs.digest_of(_game.map)),
		"and it matches the geometry it was built from"
	)

	var other := ArenaMap.by_id(&"dm_atrium" if _game.map.id == &"dm_box" else &"dm_box")
	_check(
		not nav.matches(ArenaNpcs.digest_of(other)),
		"and does not match a different map's"
	)

	# No graph point may have a monster standing in a solid. A generator that put them
	# there would produce paths straight through the pillars, and an NPC walking into
	# a wall is indistinguishable from an NPC with no path at all.
	#
	# [b]Measured half a metre above the point, not at the box's mid-height.[/b] The
	# first version of this check flattened every point to the middle of each box and
	# reported 108 failures — every one of them a perfectly good floor point UNDER one
	# of dm_box's two ledges, which sit at y = 3. Walking beneath a ledge is not
	# walking through it, and a test that cannot tell the difference fails the
	# generator for being right.
	var inside := 0

	for index in nav.point_count():
		var shins := nav.points[index] + Vector3(0.0, 0.5, 0.0)

		for box in _game.map.boxes:
			if box.has_point(shins):
				inside += 1
				break

	_check(inside == 0, "no navigation point stands inside the level", "%d do" % inside)

	# --- The horde itself -------------------------------------------------

	var horde := ArenaHorde.new()
	horde.name = "Horde"
	horde.game = _game
	# Not to disk: a suite's players must not train the next run's monsters.
	horde.persist_heat = false
	add_child(horde)

	var built := horde.setup()

	if not _check(built.ok, "the horde sets up", str(built.error)):
		horde.queue_free()
		remove_child(horde)
		return

	# Off by default. A deathmatch is a deathmatch; monsters are a mode.
	_check(not horde.enabled, "and spawns nothing until it is turned on")

	horde.tick(1.0 / float(TICK_RATE))
	_check(horde.count() == 0, "which is exactly what a tick with it off does")

	# --- Spawning by hand -------------------------------------------------

	var somewhere := nav.points[nav.point_count() / 2]
	var monster := horde.spawn_one(ArenaNpcs.GRUNT, somewhere)

	if not _check(monster != null, "a monster can be placed"):
		horde.queue_free()
		remove_child(horde)
		return

	_check(monster.brain != null, "and it got its brain from a path")
	_check(
		monster.brain is DotNpcAiBrain and (monster.brain as DotNpcAiBrain).tree != null,
		"which built a behaviour tree"
	)

	# The character is per NPC, seeded from the instance. Twenty monsters sharing one
	# preset's seed all take the same shot with the same error at the same moment,
	# which reads as a firing squad rather than as a fight.
	var brain := monster.brain as DotNpcAiBrain
	_check(
		brain.character != null and brain.character.seed_value == monster.instance_id,
		"and a character seeded from its own instance"
	)
	_check(
		brain.squad != null and brain.squad.squad_name == &"horde",
		"and it joins the horde's squad, so only three go at one player at a time"
	)

	# A shot is heard. Every player's fire becomes a COMBAT sound on the horde's board,
	# owned by the shooter, and a monster in earshot notices it on its next think.
	var shooter: ArenaPlayer = null
	for candidate in _game.players():
		if candidate.is_alive():
			shooter = candidate
			break

	if shooter != null:
		horde.note_fire(shooter.player_id, monster.position() + Vector3(6.0, 0.0, 0.0))
		horde.tick(1.0 / float(TICK_RATE))
		_check(
			brain.context.has_condition(DotNpcAiConditions.HEAR_COMBAT),
			"and it hears a player fire"
		)
	else:
		_check(false, "and it hears a player fire", "no living player to shoot")

	# The gunner: same brain, its ranged branch chosen by its definition, and a shot that
	# dot-combat resolves against a real player's hitboxes.
	# A breath first, and a different spot: the horde's limits space spawns a quarter of a
	# second apart, and the grunt is standing on the first one.
	for step in range(TICK_RATE / 2):
		horde.tick(1.0 / float(TICK_RATE))
	var gunner := horde.spawn_one(ArenaNpcs.GUNNER, nav.points[nav.point_count() / 3])
	var gunner_brain := gunner.brain as DotNpcAiBrain if gunner != null else null
	_check(
		gunner_brain != null and "\n".join(gunner_brain.tree.describe_lines()).contains("ranged"),
		"a gunner builds the ranged branch from its definition"
	)

	# Spawn protection off the target. The match above is over and cycling, so whoever is
	# alive was most likely respawned a moment ago, and a shot at a protected player is
	# refused "invulnerable" whatever it hit — which made this check pass or fail on where
	# the deathmatch happened to end. Ticking past the window does not help: a cycling
	# match respawns everybody again. This is about the gunner, not the protection.
	if shooter != null and _game.effects != null:
		_game.effects.remove(ArenaEffects.PROTECTED, shooter.player_id)
		shooter.health.invulnerable_until_tick = -1
		# And the third record of it, dot-spawn's ledger.
		if _game.player_stack != null and _game.player_stack.spawns != null \
				and _game.player_stack.spawns.protection != null:
			_game.player_stack.spawns.protection.revoke(
				str(shooter.player_id), _game.current_tick()
			)

	if shooter != null and gunner != null:
		# From the gunner's own muzzle, four metres from the player toward the middle of the
		# room. A shot from anywhere else is relocated by dot-combat to where the horde says
		# the gunner stands — the anti-cheat that stops a client shooting from somewhere it
		# is not — and the first version of this check fired from a made-up point and hit
		# the floor at the gunner's feet.
		var body := shooter.controller.state.position
		var inward := Vector3(-body.x, 0.0, -body.z)
		inward = inward.normalized() if inward.length() > 0.1 else Vector3.RIGHT
		# Toward the middle first, then round the player until nothing is in between:
		# where the match left the player is wherever the bots' fight ended, and on
		# dm_box "four metres toward the middle" is sometimes the far side of a box —
		# which made this check pass or fail on how the deathmatch above happened to go.
		var placed := inward
		for turn in range(12):
			var way := inward.rotated(Vector3.UP, TAU * float(turn) / 12.0)
			if _game.combat.trace.line_of_sight(
				body + way * 4.0 + Vector3(0.0, 1.4, 0.0), body + Vector3(0.0, 1.0, 0.0)
			):
				placed = way
				break
		(gunner.node as Node3D).global_position = body + placed * 4.0
		var muzzle := gunner.position() + Vector3(0.0, 1.4, 0.0)
		_game.combat.set_authoritative_origin(horde.entity_id_for(gunner), muzzle)
		var shot: DotShot = horde.npc_shoot(gunner, muzzle, body + Vector3(0.0, 1.0, 0.0), 6.0)
		_check(shot != null and shot.hit_anyone(), "and its shot hits a player through dot-combat",
			("impact %s, player state %s, hitboxes %s, damages %s" % [
				str(shot.impacts), str(body), str(shooter.hitboxes.global_position),
				str(shot.damages.map(func(d: DotDamage) -> String: return d.refusal if d.refused else "landed"))
			]) if shot != null else "no shot")
	else:
		_check(false, "and its shot hits a player through dot-combat", "no gunner or no player")

	# --- The id space -----------------------------------------------------

	# A lookup now, not a static formula: the id comes out of the game's table, which
	# is what stopped two monsters a million instance ids apart from sharing one.
	var entity := horde.entity_id_for(monster)
	_check(
		ArenaHorde.is_npc_entity(entity),
		"a monster's combat entity id says it names a monster",
		DotEntity.describe_id(entity)
	)
	_check(
		DotEntity.is_kind(entity, DotEntity.KIND_NPC),
		"which is a kind carried in the id, not a range it falls in"
	)

	var clashes := PackedStringArray()

	for player in _game.players():
		if ArenaHorde.is_npc_entity(player.player_id):
			clashes.append(str(player.player_id))

	_check(
		clashes.is_empty(),
		"and no player id is in it",
		", ".join(clashes)
	)

	# The property the old scheme did not have. It was
	# `ENTITY_BASE + (instance_id % ENTITY_BASE)`, so two monsters whose engine
	# instance ids differ by exactly a million shared an id -- and the second
	# `register_health` overwrote the first, leaving one of them unkillable with no
	# error anywhere. Assert uniqueness over every monster alive rather than trusting
	# the arithmetic, because trusting the arithmetic is what shipped the bug.
	var ids := {}
	var duplicated := PackedStringArray()

	for alive_npc in horde.spawner.all_npcs():
		var other_entity := horde.entity_id_for(alive_npc)

		if other_entity == 0:
			continue

		if ids.has(other_entity):
			duplicated.append(DotEntity.describe_id(other_entity))

		ids[other_entity] = true

	_check(
		duplicated.is_empty(),
		"and every monster alive has an id of its own (%d)" % ids.size(),
		", ".join(duplicated)
	)

	_check(
		_game.combat.hitboxes_of(entity) != null
			and _game.combat.health_of(entity) != null,
		"a monster is both shootable and damageable"
	)

	# --- Killing one ------------------------------------------------------
	#
	# Through dot-combat, which is the only way a monster is supposed to die here: the
	# resolver owns armour, the damage type and spawn protection, and a hit that went
	# straight to DotHealth would skip all three.
	var killed: Array[int] = []
	horde.npc_killed.connect(
		func(_npc: DotNpcInstance, killer: int) -> void: killed.append(killer)
	)

	var shooter_id := _game.players()[0].player_id if not _game.players().is_empty() else 0
	var before_npc_kills := (
		_game.progress.session_values(shooter_id).get_value(ArenaStats.NPC_KILLS, 0.0)
		if shooter_id > 0 else 0.0
	)

	# Twice the grunt's health, so one blow is fatal whatever the falloff does.
	_game.combat.apply_damage(DotDamage.make(
		shooter_id, entity, 500.0,
		_game.combat.damage_type(ArenaContent.DAMAGE_BULLET)
	))

	_check(killed.size() == 1, "shooting a monster kills it", "%d deaths" % killed.size())

	if not killed.is_empty():
		_check(killed[0] == shooter_id, "and credits whoever shot it")

	# The scoreboard must NOT have heard about it. A monster is not a player, and the
	# handler used to hand its entity id straight to `DotMatch.report_kill` — which
	# creates a record keyed on a number no player has ever had.
	_check(
		not _game.match_node.scoreboard.has(str(entity)),
		"and the scoreboard has no row for a monster"
	)

	if shooter_id > 0:
		var after_npc_kills := _game.progress.session_values(shooter_id).get_value(
			ArenaStats.NPC_KILLS, 0.0
		)
		_check(
			after_npc_kills == before_npc_kills + 1.0,
			"and the kill is counted as a monster kill rather than a player kill",
			"%d -> %d" % [int(before_npc_kills), int(after_npc_kills)]
		)

	# A tick, so the spawner actually frees what it reported dead.
	horde.tick(1.0 / float(TICK_RATE))
	await get_tree().process_frame

	_check(
		_game.combat.hitboxes_of(entity) == null,
		"and dot-combat forgot it when it went"
	)

	# --- The director -----------------------------------------------------

	horde.enabled = true

	var waves: Array[int] = []
	horde.wave_spawned.connect(
		func(_at: Vector3, count: int) -> void: waves.append(count)
	)

	# Two seconds of simulated time. The director's build-up phase spawns per player
	# and there are four bots reporting positions, so this is comfortably enough.
	for step in range(TICK_RATE * 2):
		horde.tick(1.0 / float(TICK_RATE))

	_check(
		horde.count() > 0,
		"the director populates the arena when it is on",
		"%d monsters, %d waves" % [horde.count(), waves.size()]
	)

	_check(
		horde.heat.heatmap.cell_count(DotNpcAiHeatmap.TRAFFIC) > 0,
		"and it learns where the players go while it runs"
	)

	_check(
		horde.count() <= ArenaNpcs.limits().world_budget,
		"and never past the world budget",
		"%d of %d" % [horde.count(), ArenaNpcs.limits().world_budget]
	)

	# Every monster must be somewhere a monster can be. `place()` snaps to the graph
	# and refuses a spawn it cannot snap, so a monster outside the room means the
	# refusal is not working — and dot-npc's own notes name that exact bug: `snap()`
	# returns the point it was handed when nothing is near it, so a spawn two hundred
	# metres off the graph measures as perfect.
	var stray := 0

	for npc in horde.spawner.all_npcs():
		var at := npc.position()

		if absf(at.x) > _game.map.extent + 2.0 or absf(at.z) > _game.map.extent + 2.0:
			stray += 1

	_check(stray == 0, "and every one of them is inside the map", "%d outside" % stray)

	horde.clear()
	_check(horde.count() == 0, "and the whole horde can be cleared")

	horde.queue_free()
	remove_child(horde)
	_done()


# --- Siege -----------------------------------------------------------------

## The mode where every addon in this game is live at once.
##
## [b]This is the deployment shape the project exists for, one level up.[/b]
## `headless_match` above runs dot-player-controller, dot-combat, dot-loadout, dot-match
## and dot-core together; this adds dot-npc, dot-npc-ai, dot-npc-ai-director,
## dot-props, dot-stats, dot-achievements and dot-leaderboard on top and plays it. Every
## one of those passes its own suite with the others absent.
##
## A second [ArenaGame] rather than reconfiguring the first: `setup` builds the mode's
## match rules, teams, damage rules, monsters and props in one pass, and the mode is
## what decides all five.
func _test_siege() -> void:
	_section("siege")

	var mode := ArenaModes.by_id(&"siege")

	if not _check(mode != null, "there is a siege mode"):
		return

	var valid := mode.validate()
	_check(valid.ok, "and it validates", str(valid.error))
	_check(mode.horde and mode.player_props, "and it asks for monsters and props")

	var game := ArenaGame.new()
	game.name = "Siege"
	game.tick_rate = TICK_RATE
	game.score_limit = 3
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode_id = &"siege"
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())

	if not _check(ready.ok, "a siege game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0

	_check(game.horde != null and game.horde.enabled, "the horde is live")
	_check(game.props != null, "and so are the props")

	# The map's own furniture, owned by nobody. It is placed at setup, so it is there
	# before a single player joins — which is the point of the distinction between it
	# and what a player spawns.
	if game.props != null:
		_check(
			game.props.count() == mode.scatter_props,
			"the map scattered its cover",
			"%d of %d" % [game.props.count(), mode.scatter_props]
		)

	for index in range(2):
		var added := game.add_player(index + 1, "Siege %d" % (index + 1))
		_check(added.ok, "siege player %d joins" % (index + 1), str(added.error))

	game.start(0)
	game.tick({})
	await get_tree().process_frame

	# --- Playing it ------------------------------------------------------

	var monsters_seen := 0

	for tick in range(TICK_RATE * 6):
		game.tick(_commands_for(game, tick))
		monsters_seen = maxi(monsters_seen, game.horde.count())

		if tick % 64 == 0:
			await get_tree().process_frame

	_check(
		monsters_seen > 0,
		"monsters arrive while the match is played",
		"%d at most" % monsters_seen
	)

	# The one thing a mode with both halves can get wrong that neither half can: a
	# monster is a combat entity, and if it were on the scoreboard the score limit
	# would be reached by something nobody killed.
	var rows := game.match_node.scoreboard.players().size()
	_check(
		rows <= 2,
		"and none of them is on the scoreboard",
		"%d rows for 2 players" % rows
	)

	# --- Props a player spawns -------------------------------------------

	var before := game.props.count()
	var made := game.props.spawn_for(
		1, ArenaProps.CRATE, Vector3(0.0, game.map.floor_y + 2.0, 4.0)
	)

	_check(made != null, "a player can spawn a prop in this mode")
	_check(game.props.count() == before + 1, "and it is in the world")

	if made != null:
		# The catalogue's mass, on the body. dot-props puts it there at spawn rather
		# than leaving it to whatever the scene was saved with — the bug being that
		# `mass` is otherwise read in exactly one place, against the grab limit, so a
		# prop is refused for being heavy and then thrown like a beach ball.
		var body := made.body()
		_check(
			body != null and absf(body.mass - ArenaProps.catalogue().get_prop(
				ArenaProps.CRATE
			).mass) < 0.01,
			"with the catalogue's mass rather than the scene's",
			"%.1f kg" % (body.mass if body != null else -1.0)
		)

	# The budget. Twelve is the per-player limit and the interval is three quarters of
	# a second, so this asks for far more than either allows and checks that neither
	# gave way — a budget nothing enforces is the shape this family's own sweep for
	# "settings nothing reads" was built to find.
	for attempt in range(40):
		game.props.tick(1.0)
		game.props.spawn_for(1, ArenaProps.CRATE, Vector3(2.0, 3.0, 2.0))

	var mine := game.props.spawner.player_count(&"1")
	_check(
		mine <= 12,
		"and the per-player budget holds",
		"%d props for one player" % mine
	)

	_check(game.props.undo(1), "undo takes one back")

	# --- The tools, which is what makes dot-props reachable ---------------
	#
	# [b]A physics gun nothing can call is a physics gun that does not exist.[/b]
	# `phys_gun()` and `grav_gun()` were built, documented and called by nobody until
	# the family's own detector — a public method whose name occurs once in its
	# repository — found them. `ArenaProps.act` is the one door, and it is reached
	# from the wire by `ArenaEvents.Ask.PROP_TOOL`.
	# [b]Two and a half metres up, not one.[/b] `dm_box`'s raised centre is a box from
	# y = 0 to y = 1 spanning the middle twelve metres, and `ArenaProps` puts the whole
	# map into the physics space so a prop has something to land on — so a ray cast at
	# exactly y = 1 grazes the platform's top face, hits a StaticBody3D, and
	# `prop_for_node` answers null. "Nothing there" for a crate three metres in front
	# of you, which is the geometry being right and the probe being wrong.
	var eye := game.map.floor_y + 2.5

	var target := game.props.spawn_for(1, ArenaProps.CRATE, Vector3(0.0, eye, -3.0))

	if target != null:
		# A frame, so the body is in the physics space and can be raycast at.
		await get_tree().physics_frame

		var space: Variant = game.props._space()
		_check(space != null, "the props layer has a physics space to trace in")

		var aimed := game.props.phys_gun(1).grab(
			space, Vector3(0.0, eye, 0.0), Vector3(0.0, 0.0, -1.0), Basis.IDENTITY
		)

		var reaching := aimed.ok
		_check(reaching, "a player can grab a prop they are looking at", str(aimed.error))

		if reaching:
			_check(
				game.props.phys_gun(1).held != null,
				"and the gun is holding it"
			)

			# Held props move every tick, and a layer that only called `grab` would
			# give a player a prop that stayed exactly where it was picked up — which
			# reads as the physics gun not working rather than as a missing call.
			var was_at := target.position()

			for _step in range(8):
				game.props.tick(1.0 / float(TICK_RATE))
				await get_tree().physics_frame

			_check(
				target.position().distance_to(was_at) > 0.0,
				"and carrying it moves it",
				"%.3f m" % target.position().distance_to(was_at)
			)

			_check(
				game.props.act(1, ArenaEvents.PropAct.RELEASE, Vector3.ZERO, Vector3.FORWARD),
				"and it can be let go"
			)
			_check(game.props.phys_gun(1).held == null, "leaving nothing held")

	# A grab needs somewhere to trace. A client mirroring this layer has no physics
	# space, and a tool with nothing to trace against would act on whatever was last
	# returned — so `act` refuses rather than guessing.
	_check(
		not game.props.act(
			99, ArenaEvents.PropAct.GRAB, Vector3.ZERO, Vector3.FORWARD
		),
		"and a player with nothing in front of them grabs nothing"
	)

	# --- Leaving ---------------------------------------------------------

	game.remove_player(1)
	_check(
		game.props.spawner.player_count(&"1") == 0,
		"and a player who leaves takes their props with them"
	)

	game.queue_free()
	remove_child(game)
	_done()


## Bot commands for an arbitrary game. The same aim-and-hold as `_commands_for_tick`,
## which is bound to `_game`.
func _commands_for(game: ArenaGame, tick: int) -> Dictionary:
	var commands := {}

	for player in game.players():
		if not player.is_alive():
			continue

		var move := DotFpsCommand.new()
		move.move = Vector2(
			sin(float(tick) * 0.07 + float(player.player_id)),
			cos(float(tick) * 0.05)
		)
		move.yaw = fmod(float(tick) * 1.7 + float(player.player_id) * 90.0, 360.0)
		move.pitch = 0.0

		var fire := DotWeaponCommand.new()
		fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
		fire.yaw = move.yaw
		fire.pitch = move.pitch

		move.sanitise()
		fire.sanitise()
		commands[player.player_id] = [move, fire]

	return commands


func _test_geometry_held() -> void:
	_section("the world held")

	# The failure dot-player-controller documents at length: a player who ends a tick
	# exactly touching the floor is never grounded again and sinks through the world.
	# Four bots for ninety seconds is enough for it to happen if it can.
	_check(
		_lowest_y > -1.0,
		"nobody fell through the floor",
		"lowest y was %.3f" % _lowest_y
	)

	_check(
		_furthest <= _game.map.extent + 1.0,
		"and nobody left the room",
		"furthest was %.1f of %.1f" % [_furthest, _game.map.extent]
	)

	_check(
		_grounded_ticks > 0,
		"and they were on the ground rather than falling for ever",
		"%d grounded ticks" % _grounded_ticks
	)

	# The map is actually in the shot path. If the trace ignored the geometry, every
	# shot would reach its target and this would be zero — which would make the whole
	# suite pass while proving nothing about the map.
	var blocked := 0
	var origin := Vector3(0.0, 1.6, -20.0)

	for step in range(64):
		var angle := TAU * float(step) / 64.0
		var hit := _game.combat.trace.ray(
			origin, Vector3(cos(angle), 0.0, sin(angle)).normalized(), 100.0
		)
		if hit.ok() and hit.blocked:
			blocked += 1

	_check(
		blocked > 0,
		"and the level geometry blocks shots",
		"%d of 64 directions" % blocked
	)
	_done()


## [b]The second map, walked rather than asserted.[/b]
##
## A map is a rendered, playable thing and this family has shipped a 0 x 0 Control twice
## and a black screen once — so the check that matters is not "the list has 40 boxes in
## it" but "a body starting on the yard floor ends up on the roof by using the stair".
## Box counts pass on a pile of boxes in the same place.
func _test_atrium() -> void:
	_section("dm_atrium")

	var map := ArenaMap.dm_atrium()

	_check(map.boxes.size() > 30, "the map has geometry", str(map.boxes.size()))
	_check(map.spawns.size() == 10, "and ten spawns", str(map.spawns.size()))

	# The catalogue duplication, which is the point of checking it: `ids()` lists names
	# and `by_id()` builds geometry, and a map added to one and not the other either
	# cannot be listed or cannot be loaded.
	var missing: Array[String] = []

	for id in ArenaMap.ids():
		if ArenaMap.by_id(id) == null:
			missing.append(String(id))

	_check(missing.is_empty(), "every listed map id builds", ", ".join(missing))
	_check(ArenaMap.by_id(&"dm_nosuchmap") == null, "and an unknown one does not")

	# One description, three representations — the same invariant `_test_map` checks
	# for dm_box, re-checked here because a second map is a second chance to write the
	# geometry twice.
	_check(
		map.to_fps_body().boxes.size() == map.boxes.size()
		and map.to_trace().boxes.size() == map.boxes.size(),
		"the movement and tracing backends have every box"
	)

	# [b]The shaft is open.[/b] The roof is a ring and the middle of it is the map: a
	# ray straight up from the plinth must reach the sky, and one from under the ring
	# must not. If the ring were solid this map would be a closed box with a plinth in
	# it and every check above would still pass.
	var trace := map.to_trace()
	var up_shaft := trace.ray(Vector3(0.0, 2.0, 0.0), Vector3.UP, 40.0)
	var up_ring := trace.ray(Vector3(-8.0, 2.0, 0.0), Vector3.UP, 40.0)

	_check(not (up_shaft.ok() and up_shaft.blocked), "the atrium shaft is open to the sky")
	_check(up_ring.ok() and up_ring.blocked, "and the ring above the walkway is not")

	# [b]The walk.[/b] A controller on the yard floor at the foot of the north-west
	# stair, told to hold forward for four seconds. It has to end up on the roof, which
	# it can only do by climbing the eight steps.
	var walker := ArenaPlayer.new()
	walker.name = "Walker"
	add_child(walker)
	walker.setup(ArenaPlayer.Mode.HEADLESS, map, 9001, "walker")

	var start := Vector3(-22.0, 0.5, -2.0)
	walker.controller.teleport(start)

	var command := DotFpsCommand.new()
	# +X, which is up the stair. Held rather than re-aimed: a bot that steers is a bot
	# whose failure to arrive tells you nothing about the geometry.
	command.yaw = 0.0
	command.move = Vector2(1.0, 0.0)

	var tick_rate := 64
	var delta := 1.0 / float(tick_rate)
	var peak := start.y

	for tick in range(tick_rate * 4):
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		peak = maxf(peak, walker.controller.state.position.y)

	var landed := walker.controller.state.position

	_check(
		peak > 4.0,
		"a bot holding forward at the north-west stair reaches the roof",
		"y %.2f -> peak %.2f, ended at (%.1f, %.2f, %.1f)"
			% [start.y, peak, landed.x, landed.y, landed.z]
	)
	_check(
		landed.x > start.x + 4.0,
		"and it got there by moving along the stair rather than up a wall",
		"x %.1f -> %.1f" % [start.x, landed.x]
	)

	# --- The south arcade ---------------------------------------------------
	#
	# [b]The arcade is a piece of COVER, and cover is the one thing a box count cannot
	# check.[/b] Thirty-eight boxes in the right places and thirty-eight in a heap read
	# identically to every assertion above; what makes this one an arcade is that the
	# sky is not visible from under it and is visible from beside it. Both halves
	# matter — a roof that covered the whole south yard would pass the first check and
	# would be a different, worse map.
	var under_arcade := trace.ray(Vector3(0.0, 1.0, 15.5), Vector3.UP, 40.0)
	var beside_arcade := trace.ray(Vector3(0.0, 1.0, 11.0), Vector3.UP, 40.0)
	var above_arcade := trace.ray(Vector3(0.0, 4.0, 15.5), Vector3.UP, 40.0)

	_check(
		under_arcade.ok() and under_arcade.blocked,
		"the south arcade is roofed against the ring above it"
	)
	_check(
		not (beside_arcade.ok() and beside_arcade.blocked),
		"and the yard two metres north of it is open sky"
	)
	_check(
		not (above_arcade.ok() and above_arcade.blocked),
		"and its own roof is a firing position rather than a crawlspace"
	)

	# The doorway cut in the bunker's east wall, checked from both sides of the cut. A
	# doorway is a hole in a list of boxes and a hole is invisible: a wall built as one
	# box from z 8 to 20.2 -- which is what was there before -- passes every other check
	# on this map and makes the arcade unreachable from the bunker it exists to serve.
	var through_door := trace.ray(Vector3(-18.0, 1.0, 15.5), Vector3.RIGHT, 8.0)
	var into_wall := trace.ray(Vector3(-18.0, 1.0, 10.5), Vector3.RIGHT, 8.0)

	_check(
		not (through_door.ok() and through_door.blocked),
		"the bunker's east wall is open where the arcade meets it"
	)
	_check(
		into_wall.ok() and into_wall.blocked,
		"and is still a wall either side of the doorway"
	)

	# [b]No spawn is inside a solid.[/b] The weaker version of this -- inside the room,
	# above the floor -- is what `_test_map` checks, and a spawn buried in a stair tread
	# passes it. This map has grown two stairs, ten piers and a roof slab since its
	# spawns were placed, which is exactly the way a spawn ends up inside something: not
	# by being put there, but by geometry arriving on top of it.
	var buried := PackedStringArray()

	for index in range(map.spawns.size()):
		var at: Vector3 = map.spawns[index].origin
		var column := AABB(at + Vector3(-0.4, -0.05, -0.4), Vector3(0.8, 1.8, 0.8))

		for box in map.boxes:
			if box.intersects(column):
				buried.append("#%d at %s" % [index, str(at)])
				break

	_check(buried.is_empty(), "and no spawn is inside a solid", ", ".join(buried))

	# [b]The map moved, so the map's version moved, and only this map's.[/b] A record
	# and a rotation cooldown are both about a map AT a version. The failure this
	# catches is the one a single shared constant makes unavoidable: bumping it for the
	# arcade would declare `dm_box` and `dm_pit` to be new maps too, invalidating two
	# sets of records to describe a change neither of them had.
	var versions := ArenaMaps.catalogue()

	# [b]All three moved on 2026-09-22, which is the first time that has happened and
	# does not weaken the check.[/b] They moved for one cause — every climb on every
	# map was above the jump apex — but they are still three separate changes to three
	# separate maps. dm_box reached 1.4.0 by its own four steps — the crates on
	# 2026-09-22, the gantries and nests on 2026-09-24, the nest stairs on 2026-09-29,
	# the corner stairs on 2026-10-02.
	var expected := {&"dm_atrium": "1.6.0", &"dm_pit": "1.5.0", &"dm_box": "1.4.0"}
	var wrong := PackedStringArray()

	for id: StringName in expected:
		var def := versions.get_map(id)

		if def == null or def.version != expected[id]:
			wrong.append("%s at %s, wanted %s" % [
				id, "absent" if def == null else def.version, expected[id]
			])

	_check(
		wrong.is_empty(),
		"the catalogue carries every map at the version its geometry is at",
		"; ".join(wrong)
	)
	# [b]Was "two maps that moved by different amounts do not share a version", which
	# is not a rule versions keep.[/b] Two minor bumps on two maps land on the same
	# string whenever they happen to — dm_box went 1.1.0 -> 1.2.0 on 2026-09-24, where
	# dm_atrium had been two days — and a check that fails on a coincidence is one
	# people learn to edit. What it was for is that a map that moved takes its version
	# from the per-map table rather than the catalogue-wide default; asked directly.
	_check(
		versions.get_map(&"dm_box").version != ArenaMaps.MAP_VERSION,
		"and a map that moved is not at the catalogue-wide default"
	)

	# [b]The stair onto the arcade roof, walked.[/b] Same shape as the north-west stair
	# above and for the same reason: ten treads of 0.36 is a number that only means
	# anything once something has climbed it. Driven north (-Z at yaw 0) from the back
	# of the yard.
	#
	# The arrival is recorded DURING the run rather than read at the end, because the
	# roof is only 5 m deep and a bot at 9 m/s crosses it in half a second — it reaches
	# the roof and then walks off the far edge of it, which is correct behaviour for a
	# bot holding one direction and would read as never having got there.
	walker.controller.teleport(Vector3(-8.0, 0.5, 28.0))

	var north := DotFpsCommand.new()
	north.yaw = 0.0
	north.move = Vector2(0.0, 1.0)

	var roof_peak := 0.5
	var on_roof := false

	for tick in range(tick_rate * 4):
		walker.controller.apply_command(north)
		walker.controller.simulate_tick(tick_rate * 4 + tick, delta)

		var at: Vector3 = walker.controller.state.position
		roof_peak = maxf(roof_peak, at.y)

		if at.y >= 3.5 and at.z >= 12.9 and at.z <= 18.1 and at.x >= -13.2 and at.x <= 12.0:
			on_roof = true

	_check(
		on_roof,
		"a bot walks the south stair onto the arcade roof",
		"peaked at %.2f, roof is at 3.60" % roof_peak
	)
	_check(
		roof_peak < 4.5,
		"and the roof is a tier of its own below the ring rather than part of it",
		"peaked at %.2f, ring is at 4.60" % roof_peak
	)

	# [b]The covered route, walked end to end.[/b] The arcade's whole reason is that a
	# player can get from the bunker to the foot of the crates without the ring seeing
	# them, so the check is a bot that starts inside the bunker, holds east, and comes
	# out the far end — through the doorway, between two rows of piers, under 25 m of
	# roof. Anything in the way of that lane is a corridor that is drawn and cannot be
	# used, which no assertion about boxes can tell from one that can.
	walker.controller.teleport(Vector3(-18.0, 0.5, 15.5))

	var east := DotFpsCommand.new()
	east.yaw = 0.0
	east.move = Vector2(1.0, 0.0)

	for tick in range(tick_rate * 6):
		walker.controller.apply_command(east)
		walker.controller.simulate_tick(tick_rate * 8 + tick, delta)

	var emerged: Vector3 = walker.controller.state.position

	_check(
		emerged.x > 8.0,
		"a bot crosses the arcade from the bunker to the crates without stopping",
		"x -18.0 -> %.1f" % emerged.x
	)
	_check(
		emerged.y < 1.0 and absf(emerged.z - 15.5) < 1.5,
		"and does it on the ground, in the lane, rather than over the top",
		"ended at %s" % str(emerged)
	)

	# --- The north-west keep ------------------------------------------------
	#
	# [b]Cover, asked the way the arcade's is: of the sky and of the ring.[/b] A room is
	# the one shape a box count reads identically whether it is a room or a solid
	# block, and a solid block would pass every assertion on this map except these.
	var in_keep := Vector3(-15.25, 1.0, -12.0)
	var under_keep := trace.ray(in_keep, Vector3.UP, 40.0)
	var ring_eye := Vector3(-8.0, 4.6 + 1.6, -8.0)
	var ring_to_keep := false

	for box in map.boxes:
		if box.intersects_segment(ring_eye, in_keep + Vector3(0.0, 0.6, 0.0)):
			ring_to_keep = true

	_check(
		under_keep.ok() and under_keep.blocked and ring_to_keep,
		"the north-west keep is roofed, and the ring cannot see into it"
	)

	var over_keep := trace.ray(Vector3(-15.25, 5.6, -12.0), Vector3.UP, 40.0)

	_check(
		not (over_keep.ok() and over_keep.blocked),
		"and its roof is open sky, a firing position rather than a ceiling"
	)

	# The west slit: open at eye height, wall at the knee and over the head. A slit
	# that reached the floor would be a third doorway, and one that closed would put
	# back the blank wall the first render of the keep showed.
	var slit_eye := trace.ray(Vector3(-16.0, 1.6, -12.0), Vector3.LEFT, 4.0)
	var slit_knee := trace.ray(Vector3(-16.0, 0.6, -12.0), Vector3.LEFT, 4.0)
	var slit_head := trace.ray(Vector3(-16.0, 2.6, -12.0), Vector3.LEFT, 4.0)

	_check(
		not (slit_eye.ok() and slit_eye.blocked)
			and slit_knee.ok() and slit_knee.blocked
			and slit_head.ok() and slit_head.blocked,
		"and its west wall is a firing slit at eye height, wall above and below"
	)

	# [b]In at the north door and out at the south, walked.[/b] A doorway is a hole in a
	# list of boxes and a hole is invisible, so the only thing that says the room is a
	# room is something passing through it. Held south (+Z) from the north yard; the
	# lane south of the keep ends against the side of the north-west stair, so the bot
	# stops there. Distance and speed are PRINTED against the route and max_speed,
	# because a crawling bot also gets through a doorway eventually and a check that it
	# passes as well is not a check (`[bot-drive-1]`).
	var tunables := ArenaPlayer.arena_tunables()
	var keep_start := Vector3(-15.25, 0.2, -23.0)
	# Where the lane south of the keep ends for a bot holding south: the stair's side
	# at z -4, less the motor's 0.35 m radius.
	var keep_end_z := -4.35
	walker.controller.teleport(keep_start)

	var south := DotFpsCommand.new()
	south.yaw = 0.0
	south.move = Vector2(0.0, -1.0)

	var went_in := false
	var door_north_tick := -1
	var door_south_tick := -1

	for tick in range(tick_rate * 4):
		walker.controller.apply_command(south)
		walker.controller.simulate_tick(tick_rate * 16 + tick, delta)

		var at: Vector3 = walker.controller.state.position

		if at.z > -17.0 and at.z < -7.0 and at.x > -17.5 and at.x < -13.0 and at.y < 1.0:
			went_in = true

		if door_north_tick < 0 and at.z >= -18.0:
			door_north_tick = tick

		if door_south_tick < 0 and at.z >= -6.0:
			door_south_tick = tick

	var out_at: Vector3 = walker.controller.state.position
	var through := float(door_south_tick - door_north_tick) * delta
	var keep_speed := 12.0 / through if door_south_tick > door_north_tick and door_north_tick >= 0 else 0.0

	print("  ..    keep: covered %.1f of the %.1f m route; %.2f m/s door to door against max_speed %.2f"
		% [out_at.z - keep_start.z, keep_end_z - keep_start.z, keep_speed, tunables.max_speed])

	_check(
		went_in and out_at.z > -6.0 and out_at.y < 0.5,
		"a bot walks into the keep at its north door and out at its south",
		"inside %s, ended at %s" % [went_in, str(out_at)]
	)
	_check(
		keep_speed >= tunables.max_speed - 1.0,
		"and does it at running speed, not squeezing through",
		"%.2f m/s against max_speed %.2f" % [keep_speed, tunables.max_speed]
	)

	# [b]The roof, reached the only way it is reached: off the ring's north arm.[/b]
	# Held west along the arm and jump pressed at its west edge, which is what a player
	# does -- holding jump the whole way would bleed the run to the air cap, see
	# `_test_bot_ground_speed`. Grounded on the roof at 5.5, west of the alley, is the
	# arrival.
	var arm_start := Vector3(-2.0, 4.7, -8.0)
	walker.controller.teleport(arm_start)

	var west := DotFpsCommand.new()
	west.yaw = 0.0
	west.move = Vector2(-1.0, 0.0)

	var on_keep := false
	var takeoff_speed := 0.0
	var takeoff_x := 0.0

	for tick in range(tick_rate * 3):
		var at: Vector3 = walker.controller.state.position
		var jumping := at.x <= -9.4

		if jumping and takeoff_speed == 0.0:
			var v: Vector3 = walker.controller.state.velocity
			takeoff_speed = Vector2(v.x, v.z).length()
			takeoff_x = at.x

		west.set_button(DotFpsCommand.BUTTON_JUMP, jumping)
		walker.controller.apply_command(west)
		walker.controller.simulate_tick(tick_rate * 24 + tick, delta)

		var now: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and now.y > 5.45 and now.x < -12.0:
			on_keep = true
			break

	var roof_at: Vector3 = walker.controller.state.position

	print("  ..    keep roof: covered %.1f m against the %.1f m to the roof's edge; took off at x %.2f doing %.2f m/s against max_speed %.2f"
		% [arm_start.x - roof_at.x, arm_start.x - (-12.0), takeoff_x, takeoff_speed,
			tunables.max_speed])

	_check(
		on_keep,
		"a bot runs the ring's north arm and jumps the alley onto the keep's roof",
		"ended at (%.1f, %.2f, %.1f), took off at %.2f m/s"
			% [roof_at.x, roof_at.y, roof_at.z, takeoff_speed]
	)

	# --- The east stair (1.5.0) ---------------------------------------------
	#
	# Read back off the box list: twelve treads at x 13..16, every rise and the step
	# onto the landing under `step_height`, the top tread flush with the landing.
	var east_treads: Array[AABB] = []
	var landing_box := AABB()

	for box in map.boxes:
		if is_equal_approx(box.position.x, 13.0) and is_equal_approx(box.size.x, 3.0) \
				and box.position.y < 0.001:
			east_treads.append(box)
		elif is_equal_approx(box.position.x, 10.0) and is_equal_approx(box.position.z, 6.0) \
				and is_equal_approx(box.size.y, 4.5):
			landing_box = box

	east_treads.sort_custom(func(a: AABB, b: AABB) -> bool: return a.position.z < b.position.z)

	var east_steep := PackedStringArray()
	var east_below := 0.0

	for tread in east_treads:
		if tread.size.y - east_below >= tunables.step_height:
			east_steep.append("%.2f at z %.2f" % [tread.size.y - east_below, tread.position.z])

		east_below = tread.size.y

	if not east_treads.is_empty() and landing_box.size.y - east_treads[-1].size.y >= tunables.step_height:
		east_steep.append("landing lip %.2f" % (landing_box.size.y - east_treads[-1].size.y))

	_check(
		east_treads.size() == 12 and east_steep.is_empty() and landing_box.size.y > 0.0
			and absf(east_treads[-1].end.z - landing_box.position.z) < 0.001,
		"the east stair is twelve walked treads, its top flush with the landing",
		"%d treads, steep: %s, top ends at z %.2f against the landing at %.2f" % [
			east_treads.size(), ", ".join(east_steep),
			east_treads[-1].end.z if not east_treads.is_empty() else 0.0,
			landing_box.position.z
		]
	)

	# Driven: from the yard north of the foot, facing south (yaw 180), forward held and
	# jump never pressed. The pace is foot (z = -4) to grounded on the landing.
	walker.controller.teleport(Vector3(14.5, 0.1, -5.0), 180.0, 0.0)

	var east_foot := -1
	var east_top := -1
	var east_top_z := 0.0
	var east_peak := 0.0

	for tick in range(tick_rate * 3):
		var step := DotFpsCommand.new()
		step.yaw = 180.0
		step.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(step)
		walker.controller.simulate_tick(tick_rate * 40 + tick, delta)

		var at: Vector3 = walker.controller.state.position
		east_peak = maxf(east_peak, at.y)

		if east_foot < 0 and at.z >= -4.0:
			east_foot = tick

		if walker.controller.state.is_grounded() and at.y > 4.45 and at.z > 6.0:
			east_top = tick
			east_top_z = at.z
			break

	var east_time := float(east_top - east_foot) * delta
	var east_pace := (east_top_z + 4.0) / east_time if east_top > east_foot and east_foot >= 0 else 0.0
	var east_end: Vector3 = walker.controller.state.position

	print("  ..    east stair: foot to landing %.1f m in %.2f s, %.2f m/s against max_speed %.2f"
		% [east_top_z + 4.0, east_time, east_pace, tunables.max_speed])

	_check(
		east_top >= 0,
		"a bot walks up the east stair from the yard onto the landing, jump never pressed",
		"ended at (%.1f, %.2f, %.1f), peak %.2f" % [east_end.x, east_end.y, east_end.z, east_peak]
	)
	_check(
		east_pace >= tunables.max_speed - 1.5,
		"and climbs it at running pace",
		"%.2f m/s against max_speed %.2f" % [east_pace, tunables.max_speed]
	)

	# The trade: the perch looks down every tread. From its south-west corner, where
	# somebody watching the east yard stands -- from the middle of it the perch's own
	# edge hides the lower eight treads, which is the edge doing its job.
	var perch_eye := Vector3(16.4, 6.7 + 1.6, -4.4)
	var east_hidden := PackedStringArray()

	for index in range(east_treads.size()):
		var chest := Vector3(14.5, east_treads[index].end.y + 1.2, east_treads[index].get_center().z)
		var line := chest - perch_eye
		var hit := trace.ray(perch_eye, line.normalized(), line.length() - 0.05)

		if hit.ok() and hit.blocked:
			east_hidden.append("tread %d" % (index + 1))

	_check(
		east_hidden.is_empty(),
		"and the perch sees down every tread of it",
		", ".join(east_hidden)
	)

	# --- The rampart (1.6.0) ------------------------------------------------
	#
	# Read back off the box list: the walkway, the keep roof it leaves, the perch it
	# reaches and the ring's north arm it runs beside. A walked step off the roof, a hop
	# onto the perch, flush at both ends, and out of a jump's reach from the ring, so it
	# is joined at its ends only.
	var rampart := AABB()
	var keep_top := AABB()
	var perch_top := AABB()
	var north_arm := AABB()

	for box in map.boxes:
		if is_equal_approx(box.position.z, -15.0) and is_equal_approx(box.size.y, 0.6):
			rampart = box
		elif is_equal_approx(box.position.x, -18.5) and is_equal_approx(box.position.y, 4.9):
			keep_top = box
		elif is_equal_approx(box.position.x, 16.0) and is_equal_approx(box.size.y, 6.7):
			perch_top = box
		elif is_equal_approx(box.position.z, -10.0) and is_equal_approx(box.position.y, 4.0) \
				and is_equal_approx(box.size.x, 20.0):
			north_arm = box

	var off_roof := rampart.end.y - keep_top.end.y
	var onto_perch := perch_top.end.y - rampart.end.y
	var from_ring := rampart.end.y - north_arm.end.y

	_check(
		rampart.size.y > 0.0 and keep_top.size.y > 0.0 and perch_top.size.y > 0.0
			and is_equal_approx(rampart.position.x, keep_top.end.x)
			and is_equal_approx(rampart.end.z, perch_top.position.z)
			and rampart.end.x >= perch_top.position.x + 1.0
			and off_roof > 0.0 and off_roof < tunables.step_height,
		"the rampart is a walked step off the keep roof and runs flush to the perch's face",
		"x %.2f..%.2f z %.2f..%.2f top %.2f; keep roof ends x %.2f top %.2f; perch face z %.2f"
			% [rampart.position.x, rampart.end.x, rampart.position.z, rampart.end.z,
				rampart.end.y, keep_top.end.x, keep_top.end.y, perch_top.position.z]
	)
	_check(
		onto_perch >= tunables.step_height and onto_perch < ArenaMap.climb_limit()
			and from_ring > ArenaMap.climb_limit(),
		"the perch is a hop off it, and the ring is not",
		"%.2f onto the perch, %.2f up from the ring, climb limit %.2f"
			% [onto_perch, from_ring, ArenaMap.climb_limit()]
	)

	# Driven: on the keep roof, held east, jump never pressed. Pace is the roof's east
	# edge (x = -12) to x = 18, near the far end, and the bot must never drop under
	# the walkway's top on the way.
	walker.controller.teleport(Vector3(-15.25, 5.6, -13.5))

	var along := DotFpsCommand.new()
	along.yaw = 0.0
	along.move = Vector2(1.0, 0.0)

	var ramp_on := -1
	var ramp_end := -1
	var ramp_low := 99.0
	var ramp_end_x := 0.0

	for tick in range(tick_rate * 8):
		walker.controller.apply_command(along)
		walker.controller.simulate_tick(tick_rate * 44 + tick, delta)

		var at: Vector3 = walker.controller.state.position

		if ramp_on < 0 and at.x >= -12.0:
			ramp_on = tick

		if ramp_on >= 0:
			ramp_low = minf(ramp_low, at.y)

		if at.x >= 18.0:
			ramp_end = tick
			ramp_end_x = at.x
			break

	var ramp_time := float(ramp_end - ramp_on) * delta
	var ramp_pace := (ramp_end_x + 12.0) / ramp_time if ramp_end > ramp_on and ramp_on >= 0 else 0.0

	print("  ..    rampart: keep roof edge to x 18, %.1f m in %.2f s, %.2f m/s against max_speed %.2f, lowest %.2f"
		% [ramp_end_x + 12.0, ramp_time, ramp_pace, tunables.max_speed, ramp_low])

	_check(
		ramp_end >= 0 and ramp_low > rampart.end.y - 0.1,
		"a bot walks off the keep roof and along the rampart, jump never pressed",
		"reached x %.2f, lowest %.2f against the top at %.2f"
			% [walker.controller.state.position.x, ramp_low, rampart.end.y]
	)
	_check(
		ramp_pace >= tunables.max_speed - 1.5,
		"and crosses red's half on it at running pace",
		"%.2f m/s against max_speed %.2f" % [ramp_pace, tunables.max_speed]
	)

	# And the hop at the far end: from the walkway's north edge, held south, jump
	# pressed once it is within a stride of the perch's face. Grounded on the perch.
	walker.controller.teleport(Vector3(18.5, rampart.end.y + 0.1, -14.7))

	var hop := DotFpsCommand.new()
	hop.yaw = 0.0
	hop.move = Vector2(0.0, -1.0)

	var on_perch := false

	for tick in range(tick_rate * 2):
		var at: Vector3 = walker.controller.state.position
		hop.set_button(DotFpsCommand.BUTTON_JUMP, at.z >= -12.8)
		walker.controller.apply_command(hop)
		walker.controller.simulate_tick(tick_rate * 48 + tick, delta)

		var now: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and now.y > perch_top.end.y - 0.05 and now.z > -12.0:
			on_perch = true
			break

	var hop_at: Vector3 = walker.controller.state.position

	_check(
		on_perch,
		"and hops off its east end onto the perch",
		"ended at (%.1f, %.2f, %.1f)" % [hop_at.x, hop_at.y, hop_at.z]
	)

	# The trade: the perch sees every metre of it. From the perch's north-west corner,
	# a chest every 3 m from the keep-roof end to the perch.
	var rampart_eye := Vector3(16.4, perch_top.end.y + 1.6, -11.6)
	var rampart_hidden := PackedStringArray()
	var rampart_x := -11.5

	while rampart_x < 16.0:
		var chest := Vector3(rampart_x, rampart.end.y + 1.2, -13.5)
		var line := chest - rampart_eye
		var hit := trace.ray(rampart_eye, line.normalized(), line.length() - 0.05)

		if hit.ok() and hit.blocked:
			rampart_hidden.append("x %.1f" % rampart_x)

		rampart_x += 3.0

	_check(
		rampart_hidden.is_empty(),
		"and the perch sees the whole length of it",
		", ".join(rampart_hidden)
	)

	walker.queue_free()
	remove_child(walker)

	await get_tree().process_frame
	_done()
