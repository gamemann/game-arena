extends Node

const ArenaGame := preload("res://game/arena_game.gd")
const ArenaMap := preload("res://maps/arena_map.gd")

## What the round is about, when the mode says it is about something.
##
## [b]The arena's first mode that is not "kill people".[/b] Free-for-all, team
## deathmatch and siege are all scored on kills, which means [DotMatch] alone has always
## been enough. Capture the flag and king of the hill are not, and every hand-written
## version of either gets the same things wrong — see dot-objective's notes.
##
## [b]The layout comes from the map's own numbers.[/b] `ArenaMap` is built from
## constants — an extent, a floor height, a list of boxes — which is what lets a
## dedicated server that has never drawn the level still know where everything is. So
## the flags sit at the ends of its longest axis and the hill sits at its centre,
## derived rather than authored: a map added later gets a working layout without
## anybody remembering to place two more things in it.
##
## [codeblock]
## var objectives := ArenaObjectives.new()
## objectives.game = game
## add_child(objectives)
## objectives.setup()
## [/codeblock]

const CHANNEL := "arena.objectives"

## Anything a kind wants to say: a flag taken, a point contested. A HUD connects here.
signal objective_event(id: StringName, what: StringName, data: Dictionary)

## Layout ids a mode names.
const CTF := &"ctf"
const KOTH := &"koth"

const RED := 1
const BLUE := 2

var game: ArenaGame = null

var manager: DotObjectiveManager = null

## Which layout is running. Empty when the mode has none.
var layout: StringName = &""


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "ArenaObjectives needs a game.")
	if game.mode == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no mode.")

	layout = game.mode.objective_layout
	if layout == &"":
		return DotResult.fail(
			DotError.CODE_STATE, "This mode has no objectives."
		)

	var defs := build(layout, game.map, game.tick_rate)
	if defs.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown objective layout '%s'." % layout
		)

	manager = DotObjectiveManager.new()
	manager.name = "ObjectiveManager"
	manager.authoritative = game.is_authority
	manager.rules = _rules()
	manager.presence = _presence()
	add_child(manager)

	var res := manager.setup(defs)
	if not res.ok:
		return res.wrap("arena objectives")

	manager.score_fn = _score
	manager.objective_completed.connect(_on_completed)
	manager.objective_event.connect(_on_event)
	manager.round_objective_met.connect(_on_round_met)

	# A flag carrier who dies drops it. Connected rather than left to the kill handler,
	# because there are three ways to stop being alive here — shot, fell, disconnected —
	# and a carrier who dies still carrying is a flag nobody can take and that never
	# comes home. dot-objective re-tests it every tick as a second lock on the door.
	if not game.player_killed.is_connected(_on_player_killed):
		game.player_killed.connect(_on_player_killed)

	# The layout is derived from the map's own extent, so a new map is a new layout.
	# Without this a flag stays where the previous map's wall was and a hill sits
	# outside the room — with every objective still ticking, still capturable and
	# still scoring, which is the version of this bug nothing errors on.
	if not game.map_changed.is_connected(_on_map_changed):
		game.map_changed.connect(_on_map_changed)

	DotLog.info(CHANNEL, "layout ready", {"layout": str(layout), "count": defs.size()})
	return DotResult.success(null)


func _rules() -> DotObjectiveRules:
	var rules := DotObjectiveRules.new()
	rules.live = false  # Warmup. The match turns it on.
	rules.block_style = 1
	rules.deteriorate_ticks = 60 * game.tick_rate
	return rules


func _presence() -> DotObjectivePresence:
	var presence := DotObjectivePresence.of(
		func() -> PackedStringArray:
			var out := PackedStringArray()
			for id in game.player_ids():
				out.append(str(id))
			return out,
		func(key: String) -> Vector3:
			var player := game.player_for(int(key))
			if player == null or player.controller == null:
				return Vector3(1e9, 1e9, 1e9)
			return player.controller.state.position,
		func(key: String) -> int:
			return game.team_of(int(key)),
		func(key: String) -> bool:
			var player := game.player_for(int(key))
			return player != null and player.is_alive()
	)
	# An invulnerable player may not capture and may still block, which is the whole
	# reason dot-objective asks those two questions separately.
	presence.may_capture_fn = func(key: String) -> bool:
		if game.effects == null:
			return true
		return game.effects.may_capture(int(key))
	return presence


## A layout, from a map's own geometry.
##
## Static and public so a suite can build one without a game, and so
## `ArenaModes.describe_lines` could one day say how many points a mode has.
static func build(
	which: StringName, map: ArenaMap, rate: int
) -> Array[DotObjectiveDef]:
	if map == null:
		return []

	var reach := maxf(map.extent - 4.0, 4.0)
	var floor_y := map.floor_y

	match which:
		KOTH:
			var hill := DotObjectiveDef.capture(
				&"hill",
				DotObjectiveArea.cylinder(
					Vector3(0.0, floor_y + 1.5, 0.0), reach * 0.3, 3.0
				),
				8 * rate
			)
			hill.display_name = "The Hill"
			hill.label = "H"
			hill.capture_required = 1
			hill.score_points = 0

			var clock := DotObjectiveDef.holdout(&"koth_clock", 90 * rate)
			clock.display_name = "Hold"
			clock.holdout_owner_of = &"hill"
			clock.area = hill.area
			clock.wins_round = true
			clock.score_points = 1
			clock.player_points = 1
			return [hill, clock]

		CTF:
			var red_home := Vector3(-reach * 0.8, floor_y + 1.0, 0.0)
			var blue_home := Vector3(reach * 0.8, floor_y + 1.0, 0.0)

			var red := DotObjectiveDef.flag(
				&"red_flag", DotObjectiveArea.sphere(red_home, 2.0), RED
			)
			red.display_name = "Red Flag"
			red.label = "R"
			red.flag_capture_area = DotObjectiveArea.sphere(blue_home, 3.0)
			red.flag_return_ticks = 30 * rate
			red.flag_requires_own_at_home = true
			red.score_points = 1
			red.player_points = 1

			var blue := DotObjectiveDef.flag(
				&"blue_flag", DotObjectiveArea.sphere(blue_home, 2.0), BLUE
			)
			blue.display_name = "Blue Flag"
			blue.label = "B"
			blue.flag_capture_area = DotObjectiveArea.sphere(red_home, 3.0)
			blue.flag_return_ticks = 30 * rate
			blue.flag_requires_own_at_home = true
			blue.score_points = 1
			blue.player_points = 1
			return [red, blue]

	return []


# --- The tick -----------------------------------------------------------------

func tick(_delta: float) -> void:
	if manager == null:
		return

	# Live exactly while the match is being played. A capture made during warmup is one
	# nobody was allowed to make, and warmup is when everybody is standing on
	# everything.
	if game.match_node != null:
		manager.set_live(game.match_node.is_live())

	manager.advance(game.current_tick())
	_touch_flags()


## A player standing on a flag takes it, or sends it home.
##
## Polled rather than driven by a trigger, because this game has no triggers: every
## other test in it is analytic geometry against `ArenaMap`, for the reason the map is
## constants in the first place — a dedicated server has never drawn the level.
func _touch_flags() -> void:
	if manager.objectives == null:
		return
	for flag in manager.objectives.flags():
		for id in game.player_ids():
			var player := game.player_for(id)
			if player == null or not player.is_alive():
				continue
			var at := player.controller.state.position
			if at.distance_to(flag.at) > flag.def.flag_touch_radius:
				continue
			var res := flag.touch(str(id), manager.presence)
			if res.ok:
				break


# --- Events -------------------------------------------------------------------

## Where a completion becomes a score.
##
## [b]Through `report_objective` and not through `add_team_score`, whenever there is a
## player to name.[/b] dot-match's scoreboard credits the player's team from their own
## record, and `report_objective` runs the win check afterwards — which in a mode scored
## by objectives is what ends the round. Adding to the team directly skips both, so the
## capture that wins the game does not end it until somebody happens to get a kill.
##
## The fallback exists for the one completion with nobody to credit — a holdout clock
## running out with the whole team dead — and deliberately does NOT invent a key for it.
## Inventing one is this family's own "report_kill was handed any entity id" bug: a
## scoreboard row keyed on a number no player has ever had.
func _score(
	id: StringName, team: int, by: String, points: int, player_points: int
) -> void:
	if game.match_node == null:
		return
	if by != "" and player_points > 0:
		game.match_node.report_objective(by, id, game.current_tick(), player_points)
		return
	if team > 0 and points > 0:
		game.match_node.scoreboard.add_team_score(team, points)


func _on_completed(id: StringName, team: int, by: String) -> void:
	DotLog.info(
		CHANNEL, "objective completed",
		{"id": str(id), "team": team, "by": by}
	)


func _on_event(id: StringName, what: StringName, data: Dictionary) -> void:
	DotLog.debug(CHANNEL, "objective event", {"id": str(id), "what": str(what)})
	objective_event.emit(id, what, data)


## dot-objective announces and never ends a round. This is where the announcement
## becomes a decision, and it is in the game rather than in the addon.
##
## The scoring already happened in [method _score], which ran the win check with it —
## so this only has to say so. Adding a point here as well would score a capture twice,
## which is the "announce exactly once" bug this family found in dot-vote's play
## history and again in dot-objective's own sweep.
func _on_round_met(id: StringName, team: int, by: String) -> void:
	DotLog.info(
		CHANNEL, "the round objective was met",
		{"id": str(id), "team": team, "by": by}
	)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	if manager == null or manager.objectives == null:
		return
	var key := entry.victim_key
	for flag in manager.objectives.flags():
		if flag.carrier != key:
			continue
		var _res := flag.drop(flag.at)


## Rebuild the layout for a new map, keeping the manager and its connections.
func _on_map_changed(new_map: ArenaMap) -> void:
	if manager == null:
		return

	var wanted: StringName = game.mode.objective_layout if game.mode != null else &""
	if wanted == &"":
		# The new mode has no objectives. Emptying the set is right and freeing the
		# layer is not: `ArenaGame.objectives` is read by the HUD and by the net
		# bridge, and a freed node behind a live reference is an error at the next
		# access rather than at the free.
		layout = &""
		var _cleared := manager.setup([] as Array[DotObjectiveDef])
		return

	layout = wanted
	var defs := build(layout, new_map, game.tick_rate)
	var res := manager.setup(defs)
	if not res.ok:
		DotLog.warn(
			CHANNEL, "the new map has no objective layout",
			{"why": res.error.message}
		)


func on_round_reset() -> void:
	if manager != null:
		manager.reset_round()


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["objectives: none"])
	return manager.describe_lines()
