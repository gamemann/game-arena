extends Node

## A whole deathmatch, played out headlessly, with nothing called by hand.
##
## [codeblock]
## godot --headless --path . res://examples/headless_match.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## [b]This is the only place the six addons meet.[/b] dot-fps-controller, dot-combat,
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

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _game: ArenaGame = null

## Observations gathered while the match runs.
##
## Arrays rather than counters: a GDScript lambda captures locals by value, so an int
## incremented inside a signal handler stays zero outside it — and the assertion then
## reports a failure for a signal that fired perfectly.
var _kills: Array[DotKillFeed.Entry] = []
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
	await _test_atrium()
	_test_modes()
	await _test_team_deathmatch()

	await _build()
	_test_players_exist()
	await _play()
	_test_outcome()
	_test_geometry_held()
	_test_interface()

	if _game != null:
		_game.queue_free()
		remove_child(_game)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Modes -----------------------------------------------------------------

## The catalogue, and the one disagreement a mode can have with itself.
func _test_modes() -> void:
	print("modes")

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


## Two sides, tagged spawns, and a friendly-fire rule that protects somebody.
func _test_team_deathmatch() -> void:
	print("")
	print("team deathmatch")

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


## Another id on the same side as [param id], or 0.
func _first_team_mate(game: ArenaGame, id: int) -> int:
	var side := game.team_of(id)

	for index in range(6):
		var other := 200 + index

		if other != id and game.team_of(other) == side:
			return other

	return 0


# --- Assertions ------------------------------------------------------------

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
	_group("content")

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

	# The budget has to permit something interesting and refuse the obvious abuse.
	var greedy := DotLoadout.empty(&"arena")
	greedy.set_item(&"primary", &"rocket")
	greedy.set_item(&"secondary", &"shotgun")
	_check(
		not DotLoadoutValidator.validate(greedy, schema, everything).ok,
		"the points budget refuses the two heaviest weapons together"
	)

	var sensible := DotLoadout.empty(&"arena")
	sensible.set_item(&"primary", &"rifle")
	sensible.set_item(&"secondary", &"pistol")
	_check(
		DotLoadoutValidator.validate(sensible, schema, everything).ok,
		"and permits a normal one"
	)

	# The rocket launcher is the one paid item, so an unentitled player must not get
	# it — which is dot-loadout's default and is worth checking here because this
	# game's entitlement source is the thing that grants it.
	var unowned := DotLoadout.empty(&"arena")
	unowned.set_item(&"primary", &"rocket")
	unowned.set_item(&"secondary", &"pistol")
	_check(
		not DotLoadoutValidator.validate(
			unowned, schema, DotLoadoutEntitlements.none()
		).ok,
		"and refuses a rocket launcher to a player who has not unlocked it"
	)


func _test_map() -> void:
	_group("map")

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


# --- Building --------------------------------------------------------------

func _build() -> void:
	_group("bringing up the match")

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


func _test_players_exist() -> void:
	_group("players")

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
		var fire := DotCombatCommand.new()

		if target != null:
			var to_target := (
				target.muzzle_position() - player.muzzle_position()
			).normalized()

			# The inverse of DotCombatCommand.aim_direction(), which is Godot's
			# -Z-forward convention. Getting the sign wrong here makes every bot shoot
			# backwards, which reads as a broken hit registration rather than a broken
			# test.
			move.yaw = rad_to_deg(atan2(-to_target.x, -to_target.z))
			move.pitch = rad_to_deg(asin(clampf(to_target.y, -1.0, 1.0)))

			fire.set_button(DotCombatCommand.BUTTON_ATTACK, true)

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
	_group("playing")

	var ticks := 0

	while ticks < MAX_TICKS:
		if _game.match_node.state == DotMatch.State.MATCH_END:
			break

		_game.tick(_commands_for_tick(ticks))
		ticks += 1

		for player in _game.players():
			var at := player.controller.state.position
			_lowest_y = minf(_lowest_y, at.y)
			_furthest = maxf(_furthest, maxf(absf(at.x), absf(at.z)))

			if player.controller.state.is_grounded():
				_grounded_ticks += 1

		# Loadouts are applied through an awaited store call, so the frame has to be
		# allowed to turn over or the deferred half never runs.
		if ticks % 64 == 0:
			await get_tree().process_frame

	_check(
		ticks < MAX_TICKS,
		"the match reached an end on its own",
		"ran %d ticks" % ticks
	)
	print("       %d ticks, %d kills" % [ticks, _kills.size()])


func _test_outcome() -> void:
	_group("what happened")

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


## The HUD and the menus, built and driven headlessly.
##
## Nothing is rendered — there is no display — and nothing here needs to be. What is
## checked is the wiring: that a widget bound to a game value reads the right one, that
## the scoreboard screen fills from the match that just finished, and that the screen
## stack keeps its four invariants straight when a scoreboard is held down over a pause
## menu.
func _test_interface() -> void:
	_group("the interface")

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
	subject.arsenal.movement = 0.0
	hud.refresh_all()
	var still := hud.crosshair.gap_pixels()

	subject.arsenal.movement = 1.0
	hud.refresh_all()
	_check(
		hud.crosshair.gap_pixels() > still,
		"and the crosshair opens when the player moves",
		"%.1f -> %.1f" % [still, hud.crosshair.gap_pixels()]
	)

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

	stack.push(&"scoreboard")
	var scoreboard := stack.screen(&"scoreboard") as ArenaMenus.ScoreboardScreen
	_check(
		scoreboard.table.row_count() == BOTS,
		"the scoreboard fills from the match that just ended",
		"%d rows" % scoreboard.table.row_count()
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

	stack.push(&"settings")
	_check(stack.top_id() == &"settings", "settings opens over the pause menu")
	var settings := stack.screen(&"settings") as ArenaMenus.SettingsScreen
	_check(
		settings.panel.editor_for("scale") != null,
		"and generated a control for the UI scale"
	)

	stack.pop()
	_check(stack.top_id() == &"pause", "closing it reveals the pause menu")

	stack.clear()
	_check(hud.visible, "and clearing everything brings the HUD back")

	hud.queue_free()
	remove_child(hud)
	stack.queue_free()
	remove_child(stack)


func _test_geometry_held() -> void:
	_group("the world held")

	# The failure dot-fps-controller documents at length: a player who ends a tick
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


## [b]The second map, walked rather than asserted.[/b]
##
## A map is a rendered, playable thing and this family has shipped a 0 x 0 Control twice
## and a black screen once — so the check that matters is not "the list has 40 boxes in
## it" but "a body starting on the yard floor ends up on the roof by using the stair".
## Box counts pass on a pile of boxes in the same place.
func _test_atrium() -> void:
	_group("dm_atrium")

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

	walker.queue_free()
	remove_child(walker)

	await get_tree().process_frame
