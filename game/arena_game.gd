@tool
class_name ArenaGame
extends Node

## The deathmatch itself: a match, a combat manager, a map, and some players.
##
## [b]This is the seam nothing else runs.[/b] dot-match knows nothing about damage,
## dot-combat knows nothing about scoring, dot-loadout knows nothing about weapons, and
## dot-player-controller knows about none of them. Six addons, each correct alone. This is
## the fifty lines where they meet, and the only place a mistake in the joins between
## them can show up.
##
## It is deliberately independent of dot-server: a listen server, a test and a
## dedicated server all run this, and only the last of them also runs
## [ArenaModule].

const CHANNEL := "arena"
const SERVICE := &"arena_game"

## How far from the origin the netcode quantises positions over, in metres.
##
## [b]Both ends must use the same number, and there is therefore exactly one.[/b] A
## quantised position is an integer over this range, so a server encoding against 128
## and a client decoding against 256 do not produce a rounding error — they produce a
## DIFFERENT POSITION, for every entity, on every snapshot. The symptom is a client
## that connects, adopts its player alive with full health, and then finds itself
## somewhere the world is not: sky in every direction, a HUD reading zero, and not one
## error anywhere.
##
## That is what happened here the first time the two were written separately, in two
## files, a hundred lines apart. This constant exists so there is nothing to keep in
## step. `dm_box` is 48 metres across; 128 leaves room for a player thrown out of it.
const NET_WORLD_EXTENT := 128.0

## Snapshots a second. 32, because it divides 64 and 128 — an uneven send spacing
## arrives as jitter no interpolator can remove. Also one number, for the reason above.
const NET_SNAPSHOT_RATE := 32

## A player was killed. After the scoreboard and the feed have seen it.
signal player_killed(entry: DotKillFeed.Entry)

## A player was put back into the world.
signal player_spawned(player: ArenaPlayer)

## A player exists. Fired by [method add_player], on every machine that has one.
##
## [b]Distinct from [signal player_spawned], and a client needs this one.[/b]
## `player_spawned` fires from `_on_respawn_due`, which is dot-match's, which runs on
## the AUTHORITY — so on a mirroring client it never fires at all. A client that waited
## for it to find its own player waited for ever: the HUD still bound by id and worked,
## the scoreboard worked, and there was no camera and no world, because both hang off
## the local player.
##
## That is this family's commonest shape with the ends swapped — a value consumed by a
## client and produced by nobody on the client's path — and it is the same bug
## game-g2gfast shipped, one signal over.
signal player_added(player: ArenaPlayer)

signal match_state_changed(from: DotMatch.State, to: DotMatch.State)

## A combat entity that is NOT a player was killed.
##
## [b]This exists because the scoreboard used to get a row for one.[/b] dot-combat
## knows only entity ids; anything a game layer registers with it — a monster, a
## breakable, a turret — arrives at `_on_entity_killed` looking exactly like a player.
## The old handler passed the id to `DotMatch.report_kill` regardless, which creates a
## scoreboard record keyed on a number no player has ever had, and it would have shown
## up as a phantom name at the bottom of the board with a death against it.
##
## [ArenaHorde] is the listener. A game with no monsters connects nothing and nothing
## is emitted.
signal non_player_killed(entity_id: int, damage: DotDamage)

## The world was replaced. After everything is rebuilt and every player is back in it.
##
## A client hangs its renderer off this: the meshes it was drawing belonged to the old
## map and the nodes they came from are gone by the time this fires.
signal map_changed(map: ArenaMap)

@export_group("Simulation")

@export_range(1, 240, 1) var tick_rate: int = 64

@export_group("Rules")

## Kills to win. Zero uses the ruleset's own.
@export_range(0, 200, 1) var score_limit: int = 25

@export_range(0.0, 3600.0, 30.0) var time_limit_sec: float = 600.0

@export_group("Mode")

## What is being played. Null means [member mode_id] decides.
##
## [b]Assign before [method setup].[/b] It builds the match rules, the teams and the
## damage rules, and none of them is re-read afterwards.
@export var mode: ArenaMode = null

## Which mode to use when [member mode] is null. See [ArenaModes].
@export var mode_id: StringName = &"ffa"

## Whether this instance decides who dies.
##
## A client runs the same [ArenaGame] with this off: it simulates, it traces for
## effects, and it applies nothing.
@export var is_authority: bool = true

## Analytic geometry, or Godot physics. See [enum ArenaPlayer.Mode].
@export var headless: bool = true

@export_group("Progression")

## Count statistics, award achievements and keep leaderboards.
##
## [b]Authority only, and the guard is not a saving.[/b] A mirroring client runs the
## same [ArenaGame], sees the same kills replicated to it, and counting them there
## would credit every player on the server a second time in a place the server never
## reads — and, worse, would let a modified client award itself achievements. The
## numbers belong to whoever decides who died.
@export var track_progress: bool = true

@export_group("Service")

@export var register_service: bool = true

@export var service_scope: StringName = &""

var map: ArenaMap = null
var match_node: DotMatch = null
var combat: DotCombatManager = null
var loadouts: DotLoadoutManager = null

## Rockets in flight. Built alongside the combat manager, because it traces against
## the same world and resolves through the same rules.
var projectiles: ArenaProjectiles = null

## Statistics, achievements and boards. Null when [member track_progress] is off or
## this instance is not the authority.
var progress: ArenaProgress = null

## Monsters. Null unless the mode asks for them and this instance is the authority.
##
## [b]Authority only, and unpredicted.[/b] A brain runs a behaviour tree against a
## blackboard with lifetimes on it, which is not something two machines reproduce from
## the same inputs — dot-npc says so and dot-props says the same thing about rigid
## bodies. A client sees monsters because they are replicated, never because it
## simulated them.
var horde: ArenaHorde = null

## Physics props. Null unless the mode asks for them and this instance is the authority.
var props: ArenaProps = null

## Status effects: burning, empowered, haste, spawn protection, slowed.
##
## Built in every mode, because spawn protection is one of them and every mode has
## that. dot-effects' whole integration is one line — `resolver.adjust` — which
## dot-combat has offered since it was written and nothing here had ever filled.
var effects: ArenaEffects = null

## What the round is about, in a mode that is about something. Null in a deathmatch.
var objectives: ArenaObjectives = null

## Where a dead player looks. Built in every mode, because every mode kills people.
var spectate: ArenaSpectate = null

## Who is in the session, which side, what class, where they enter, and the physics.
##
## [b]Built last and binds to everything else.[/b] It adds no authority: dot-match still
## decides the round and dot-combat still decides damage. What it does is keep one set
## of records in step with them, so a scoreboard, a spectator camera, a class screen and
## a spawn selector read the same thing rather than four dictionaries that agree until
## somebody reconnects. See [ArenaPlayerStack].
var player_stack: ArenaPlayerStack = null

## player id -> [ArenaPlayer].
var _players: Dictionary = {}

## The spawn points built from the map, so a map change can take them away again.
##
## Held rather than found by walking the children: this node's children are the match,
## the combat manager, the loadouts, the progress node, every player AND every spawn
## point, and a teardown that filtered them by type would free a spawn point a host
## project had added itself.
var _spawn_points: Array[DotSpawnPoint] = []

var _tick: int = 0
var _registered_name: StringName = &""


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


## Builds everything. Call after adding to the tree.
func setup(p_map: ArenaMap = null) -> DotResult:
	# The mode first: the map default, the damage rules and the match rules all come
	# out of it, so resolving it after any of them would build them from the old one.
	if mode == null:
		mode = ArenaModes.by_id_or_default(mode_id)

	var mode_res := mode.validate()

	if not mode_res.ok:
		return mode_res

	map = (
		p_map if p_map != null
		else (
			ArenaMap.by_id(mode.preferred_map) if mode.preferred_map != &""
			else null
		)
	)

	if map == null:
		map = ArenaMap.dm_box()

	if mode.is_team_mode() and Array(map.spawn_tags).count("") == map.spawns.size():
		# Not fatal: dot-match falls back to the shared pool and everyone still spawns.
		# It is worth a line anyway, because the symptom of playing a team mode on an
		# untagged map is "the sides keep spawning in each other's base", which reads
		# as a spawn-selection bug rather than as a map that was never tagged.
		DotLog.warn(
			CHANNEL,
			"a team mode on a map with no tagged spawns; both sides share one pool",
			{"mode": str(mode.id), "map": map.display_name}
		)

	var combat_result := _build_combat()

	if not combat_result.ok:
		return combat_result

	var match_result := _build_match()

	if not match_result.ok:
		return match_result

	var loadout_result := _build_loadouts()

	if not loadout_result.ok:
		return loadout_result

	var progress_result := _build_progress()

	if not progress_result.ok:
		return progress_result

	# Last, and after the combat manager: a monster is a combat entity and a prop is a
	# rigid body that has to land on the map. Both read `mode`, which is why neither is
	# an export on this class — see `ArenaMode.horde`.
	_reconcile_world_layers()

	var stack_result := _build_player_stack()

	if not stack_result.ok:
		return stack_result

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	return DotResult.success(null)


func _build_combat() -> DotResult:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = is_authority
	combat.register_service = false
	combat.trace = map.to_trace()

	var rules := DotDamageRules.new()
	# Both from the mode. friendly_fire is meaningless without teams and harmless to
	# set either way; self damage is on in every mode this ships, because rocket
	# jumping is a movement option and taking it away removes the only reason the
	# rocket launcher is interesting to hold.
	rules.friendly_fire = mode.friendly_fire
	rules.self_damage = mode.self_damage
	rules.hit_groups = true
	rules.falloff = true
	rules.maximum = 400.0
	combat.rules = rules

	var config := DotCombatConfig.new()
	config.tick_rate = tick_rate
	config.lag_compensation = true
	config.max_origin_error = 2.5
	combat.config = config

	add_child(combat)

	# AFTER add_child: `DotCombatManager.setup` runs from `_ready` and that is what
	# builds the resolver, so assigning this beforehand writes to nothing.
	#
	# This is the entire friendly-fire seam. dot-combat has no idea what a team is; it
	# asks this callable for two entity ids and compares the answers, and treats team 0
	# as "no team" so two unassigned players in a free-for-all can always hurt each
	# other. Without it `rules.friendly_fire = false` protects nobody, because every
	# pair looks like strangers.
	combat.resolver.team_of = func(entity_id: int) -> int:
		var player := player_for(entity_id)
		return player.team if player != null else 0

	for type in ArenaContent.damage_types():
		combat.register_damage_type(type)

	combat.entity_killed.connect(_on_entity_killed)
	combat.damage_applied.connect(_on_damage_applied)


	projectiles = ArenaProjectiles.new()
	# The same gravity the players fall under, so a grenade arc and a jump arc agree.
	# ArenaPlayer sets this on its tunables; the two must not drift apart.
	projectiles.setup(combat, 22.0)

	return DotResult.success(null)


func _build_match() -> DotResult:
	# DUPLICATED, not used directly. A Resource is a reference in GDScript, so handing
	# dot-match the catalogue's own rules would mean a server that raised a score limit
	# at runtime had edited the mode every later match reads.
	var rules: DotMatchRules = mode.rules.duplicate()

	# The exports override the mode when they are set, so a server can keep the mode
	# and change the numbers. Zero means "whatever the mode said".
	if score_limit > 0:
		rules.score_limit = score_limit

	if time_limit_sec > 0.0:
		rules.time_limit_sec = time_limit_sec

	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.rules = rules
	match_node.register_service = false

	# Built here rather than left to dot-match, which would otherwise make an untagged
	# `DotTeam.standard_pair()`. The tags are the whole point — see `ArenaMode.teams`.
	#
	# It has to be assigned AND parented before `add_child(match_node)`, because that
	# is what runs `DotMatch._ready` and therefore `setup`, and setup only creates a
	# manager when it finds none.
	if mode.is_team_mode():
		var manager := DotTeamManager.new()
		manager.name = "Teams"
		manager.teams = mode.teams()
		match_node.teams = manager
		match_node.add_child(manager)

	var config := DotMatchConfig.new()
	config.tick_rate = tick_rate
	config.auto_start = false
	config.balance_between_rounds = false
	match_node.config = config

	# **Collect spawn points from THIS game and nowhere else.**
	#
	# `DotMatch.setup` calls `refresh_spawns`, which with no `spawns_ref` walks
	# `get_tree().current_scene` — the whole tree. That is right for a game that is the
	# scene and wrong for every other arrangement, and this project has two of them:
	# a suite that builds several `ArenaGame`s in one process, and a `changelevel`,
	# where the outgoing map's points are still children for the rest of the frame
	# because `queue_free` is deferred.
	#
	# Measured: a second game in the tree contributed ten spawn points to this one's
	# match, so players spawned in a map they were not in. Nothing errored — a spawn
	# point is a spawn point, and dot-match had been handed exactly what it asked for.
	# PARENT rather than SELF: `DotMatch` resolves the ref against ITSELF, so SELF is
	# the match node, whose only child is the team manager. The spawn points are
	# children of the game, which is the match node's parent.
	var mine := DotNodeRef.new()
	mine.mode = DotNodeRef.Mode.PARENT
	match_node.spawns_ref = mine

	add_child(match_node)

	# Spawn points come from the map, not from the scene: a headless server never
	# instantiates the level's nodes, and a match with no spawn points is a match
	# nobody ever appears in.
	for index in range(map.spawns.size()):
		var point := DotSpawnPoint.new()
		point.name = "Spawn%02d" % match_node.spawn_points().size()
		point.transform = map.spawns[index]
		point.cooldown_ticks = int(2.0 * float(tick_rate))

		# The map's tag, which is what a team's `spawn_tag` matches against. An
		# untagged point stays available to everybody.
		var tag := map.spawn_tag(index)

		if tag != &"":
			point.tags.append(tag)

		add_child(point)
		match_node.add_spawn_point(point)
		_spawn_points.append(point)

	# Where everyone is, so the spawn selector can put a player away from the fight.
	# Without this it falls back to cooldowns alone and will happily spawn someone in
	# front of the player who just killed them.
	match_node.position_fn = func(key: String) -> Vector3:
		var player := player_for(int(key))
		return player.controller.state.position if player != null else Vector3.ZERO

	match_node.respawn_due.connect(_on_respawn_due)
	match_node.state_changed.connect(_on_match_state_changed)

	return DotResult.success(null)


func _build_loadouts() -> DotResult:
	loadouts = DotLoadoutManager.new()
	loadouts.name = "Loadouts"
	loadouts.schema = ArenaContent.loadout_schema()
	loadouts.register_service = false

	var config := DotLoadoutConfig.new()
	config.backend = "memory"
	config.allow_default_loadout = true
	config.conform_on_load = true
	loadouts.config = config
	loadouts.store = DotLoadoutStoreMemory.new()

	# Everything in this game is free except the rocket launcher, and there is no
	# entitlement service to ask. A game with unlocks binds a real source here; leaving
	# it unset means only `free` items, which is dot-loadout's loud default.
	loadouts.entitlement_source = func(_key: String) -> DotLoadoutEntitlements:
		return DotLoadoutEntitlements.of([&"rocket"])

	add_child(loadouts)
	return DotResult.success(null)


## Statistics, achievements and boards, if this instance keeps any.
##
## [b]Built last, and after the match node exists.[/b] [method ArenaProgress.attach]
## connects to the combat manager's shot and damage signals and to dot-match's round
## and match signals; every one of those is created by the three builders above, and
## attaching before them would connect to null with no error until the first kill.
## Stands up the player-facing addons and binds them to this game.
##
## After everything else, because it reads the match's team manager, the match's spawn
## points and this node's tick rate, and a stack built before any of those exists binds
## to nothing and reports success.
func _build_player_stack() -> DotResult:
	if player_stack != null:
		player_stack.queue_free()

	player_stack = ArenaPlayerStack.new()
	player_stack.name = "PlayerStack"
	# A client mirrors what the server decided; re-applying a physics profile there
	# would have it simulate at a rate the server does not.
	player_stack.apply_physics = is_authority
	player_stack.register_service = register_service
	add_child(player_stack)

	return player_stack.setup(self).wrap("The arena's player stack")


func _build_progress() -> DotResult:
	if not track_progress or not is_authority:
		return DotResult.success(null)

	progress = ArenaProgress.new()
	progress.name = "Progress"
	add_child(progress)

	var attached := progress.attach(self)

	if not attached.ok:
		# A game with no statistics is a game. A game that refuses to start because a
		# leaderboard definition was rejected is not, and this is the same call
		# `apply_loadout` makes about an unreachable store.
		DotLog.warn(CHANNEL, "progression is off", {"why": attached.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null

	return DotResult.success(null)


## The monsters and the props the mode asks for.
##
## [b]Neither is fatal and neither logs at warning level when it is simply off.[/b] A
## mode with no monsters is the ordinary case; a mode that wanted them and could not
## have them is worth a line, because the symptom is an empty arena in a game called
## Siege and nothing to say why.
## Build the layers a mode asks for, and take away the ones it does not.
##
## [b]Called from `change_map` as well as from `setup`, and that is the whole point.[/b]
## Before it was, the layers were built once and never reconsidered — so switching from
## free-for-all to `koth` produced a game whose mode said it had objectives and whose
## `objectives` was null, and switching to `siege` produced one with no monsters in it.
## Nothing errored: a null layer is a legitimate thing for a mode with no layer to have,
## and the only symptom was a mode that did not do what it says.
func _reconcile_world_layers() -> void:
	if not is_authority or mode == null:
		return

	_build_world_layers()

	# And the other direction. A mode with no objectives must not keep the last one's,
	# because a HUD reads the layer rather than the mode and would draw a hill nobody
	# can capture.
	if objectives != null and mode.objective_layout == &"":
		remove_child(objectives)
		objectives.queue_free()
		objectives = null

	if horde != null and not mode.horde:
		remove_child(horde)
		horde.queue_free()
		horde = null

	if props != null and not mode.player_props and mode.scatter_props <= 0:
		remove_child(props)
		props.queue_free()
		props = null


## Build whatever is missing. Idempotent, because [method _reconcile_world_layers]
## calls it on every map change as well as at setup.
##
## Each layer is built once and then left alone: a rebuilt layer is a layer whose signal
## connections have to be remade, and a connection to a freed object is an error at the
## next emit rather than at the disconnect that was skipped. What a MODE change needs is
## the layer to exist or not exist, which the reconcile above does by taking it away.
func _build_world_layers() -> void:
	if not is_authority or mode == null:
		return

	# Effects first, and the order matters: ArenaObjectives asks the effects layer
	# whether a player may capture, and a layer that is not there yet answers "no
	# layer", which is a legitimate answer and would silently let an invulnerable
	# player take a point.
	if effects == null:
		effects = ArenaEffects.new()
		effects.name = "Effects"
		effects.game = self
		add_child(effects)

		var effects_ready := effects.setup()

		if not effects_ready.ok:
			DotLog.warn(CHANNEL, "effects are off", {"why": effects_ready.error.message})
			remove_child(effects)
			effects.queue_free()
			effects = null

	if spectate == null:
		spectate = ArenaSpectate.new()
		spectate.name = "Spectate"
		spectate.game = self
		add_child(spectate)

		var spectate_ready := spectate.setup()

		if not spectate_ready.ok:
			DotLog.warn(
				CHANNEL, "spectating is off", {"why": spectate_ready.error.message}
			)
			remove_child(spectate)
			spectate.queue_free()
			spectate = null

	if mode.objective_layout != &"" and objectives == null:
		objectives = ArenaObjectives.new()
		objectives.name = "Objectives"
		objectives.game = self
		add_child(objectives)

		var objectives_ready := objectives.setup()

		if not objectives_ready.ok:
			DotLog.warn(
				CHANNEL, "objectives are off", {"why": objectives_ready.error.message}
			)
			remove_child(objectives)
			objectives.queue_free()
			objectives = null

	if (mode.player_props or mode.scatter_props > 0) and props == null:
		props = ArenaProps.new()
		props.name = "Props"
		props.game = self
		props.players_may_spawn = mode.player_props
		props.scatter_count = mode.scatter_props
		add_child(props)

		var props_ready := props.setup()

		if not props_ready.ok:
			DotLog.warn(CHANNEL, "props are off", {"why": props_ready.error.message})
			remove_child(props)
			props.queue_free()
			props = null

	if not mode.horde or horde != null:
		return

	horde = ArenaHorde.new()
	horde.name = "Horde"
	horde.game = self
	add_child(horde)

	var horde_ready := horde.setup()

	if not horde_ready.ok:
		DotLog.warn(CHANNEL, "the horde is off", {"why": horde_ready.error.message})
		remove_child(horde)
		horde.queue_free()
		horde = null
		return

	horde.enabled = true


func start(tick: int = 0) -> void:
	_tick = tick
	match_node.start(tick)


# --- Changing the map ------------------------------------------------------

## Replaces the world under the players who are standing in it.
##
## [b]This is what `ArenaGame.setup` could never be asked to do twice.[/b] setup builds
## the combat trace, the match node and every spawn point as children in one pass and
## is not re-entrant: calling it again leaves two matches, two combat managers and two
## sets of spawns in one tree, all of them connected to the same signals, and the
## second of each quietly wins. So the teardown is the feature, and it is the half that
## has to be right — every one of the joins this game exists to test is a signal
## connection, and a connection to a freed object is an error at the next emit rather
## than at the disconnect that was skipped.
##
## What survives a change and what does not:
##
## - [b]The players do.[/b] Their nodes, their statistics and their loadouts are about
##   a person on this server, not about a room. They are re-bodied against the new
##   geometry and put back into the new match.
## - [b]The match does not.[/b] A new map is a new match; scores from the last one
##   belong to the last one. dot-stats' session totals are deliberately not reset,
##   because a session is a visit to the server.
## - [b]The combat manager does not[/b], because its trace is the map.
##
## [param new_mode] is optional; null keeps the mode that is running. A mode change is
## the one thing that must happen HERE rather than afterwards — the match rules, the
## team manager and the damage rules are all built from it, and assigning it after the
## rebuild would leave every one of them describing the previous mode.
func change_map(new_map: ArenaMap, new_mode: ArenaMode = null) -> DotResult:
	if new_map == null:
		return DotResult.fail(DotError.CODE_INVALID, "There is no map to change to.")

	if map == null or match_node == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The game has not been set up, so there is nothing to change."
		)

	if new_mode != null:
		var mode_res := new_mode.validate()

		if not mode_res.ok:
			return mode_res.wrap("The mode that map wanted is not usable")

	# Read before the teardown: `_players` survives it, but the team a player was on
	# belongs to the match that is about to be freed.
	var roster: Array = []

	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		roster.append({"id": id, "name": player.display_name})

	_teardown_world()

	map = new_map

	if new_mode != null:
		mode = new_mode

	var combat_result := _build_combat()

	if not combat_result.ok:
		return combat_result.wrap("The new map's combat could not be built")

	var match_result := _build_match()

	if not match_result.ok:
		return match_result.wrap("The new map's match could not be built")

	for row in roster:
		var id := int(row["id"])
		var player := player_for(id)

		if player == null:
			continue

		# The body first. A player whose collision is still the old map's geometry is
		# one standing inside a wall that no longer exists, and the first tick after
		# the change would push them out of a room they are not in.
		player.rebind_map(map)
		player.join_combat(combat)

		var added := match_node.add_player(str(id), String(row["name"]), _tick, 0)

		if not added.ok:
			DotLog.warn(CHANNEL, "a player could not rejoin after the map change", {
				"player": id, "why": added.error.message
			})
			continue

		player.team = team_of(id)

	if progress != null:
		progress.rebind_world()

	# The layers the NEW mode asks for, and only them. Before this existed a mode
	# change built nothing and took nothing away, so `changegame`-ing from a deathmatch
	# to `koth` produced a game whose mode said it had objectives and whose objectives
	# were null — and to `siege` produced one with no monsters in it.
	#
	# Before the announcement, because a HUD and a net bridge both read these off the
	# game inside their `map_changed` handlers.
	_reconcile_world_layers()

	# Whatever state the last match ended in, the new one starts from the beginning.
	match_node.start(_tick)

	DotLog.info(CHANNEL, "map changed", {
		"map": map.display_name, "mode": String(mode.id), "players": _players.size()
	})

	map_changed.emit(map)

	return DotResult.success(map)


## Frees everything that belongs to the map, in the order the connections require.
##
## [b]Disconnect before free, and disconnect from the object that holds the
## connection.[/b] Godot cleans up connections when a node is freed, so most of this
## is belt and braces — but [ArenaProgress] outlives the teardown and is connected to
## both the combat manager and the match node, and a node that is still connected to a
## freed object when its own handler runs is the error that has no line number.
func _teardown_world() -> void:
	if progress != null:
		progress.unbind_world()

	for id in player_ids():
		(_players[id] as ArenaPlayer).leave_combat()

	if match_node != null and is_instance_valid(match_node):
		if match_node.respawn_due.is_connected(_on_respawn_due):
			match_node.respawn_due.disconnect(_on_respawn_due)

		if match_node.state_changed.is_connected(_on_match_state_changed):
			match_node.state_changed.disconnect(_on_match_state_changed)

		# The position callable closes over this node and is read on every spawn
		# selection. Cleared rather than left to the free, because a Callable held by
		# a node being freed is exactly the sort of thing that runs once more.
		match_node.position_fn = Callable()

		remove_child(match_node)
		match_node.queue_free()

	match_node = null

	if combat != null and is_instance_valid(combat):
		if combat.entity_killed.is_connected(_on_entity_killed):
			combat.entity_killed.disconnect(_on_entity_killed)

		if combat.damage_applied.is_connected(_on_damage_applied):
			combat.damage_applied.disconnect(_on_damage_applied)

		remove_child(combat)
		combat.queue_free()

	combat = null
	projectiles = null

	for point in _spawn_points:
		if is_instance_valid(point):
			remove_child(point)
			point.queue_free()

	_spawn_points.clear()


# --- Players ---------------------------------------------------------------

## Adds a player, builds their body, and puts them in the match.
func add_player(
	id: int, display_name: String, wanted_team: int = 0
) -> DotResult:
	if _players.has(id):
		return DotResult.fail(DotError.CODE_STATE, "Player %d is already here." % id)

	var player := ArenaPlayer.new()
	player.setup(
		ArenaPlayer.Mode.HEADLESS if headless else ArenaPlayer.Mode.PHYSICS,
		map,
		id,
		display_name
	)
	add_child(player)

	# The layout's player mask, rather than `DotFpsTunables`' default of 1. See
	# `ArenaPlayer.use_collision_mask` — with props on their own layer, 1 is a player
	# who walks through crates.
	if player_stack != null:
		player.use_collision_mask(player_stack.player_collision_mask())

	player.join_combat(combat)
	_players[id] = player

	var added := match_node.add_player(str(id), display_name, _tick, wanted_team)

	if not added.ok:
		remove_player(id)
		return added

	# The side dot-match actually put them on, which is not necessarily the one they
	# asked for: `DotTeamManager.assign` refuses a full team and balances an uneven one.
	# Reading it back rather than assuming is the difference between a scoreboard that
	# matches the game and one that matches the request.
	#
	# It is set on the player because that is what dot-combat's friendly-fire check and
	# the renderer's colour both read, and `ArenaPlayer.team` had been declared and
	# assigned by nothing since the class was written.
	player.team = team_of(id)

	if progress != null:
		# Not awaited. An achievement store may be remote and a join may not wait on
		# it; readings that arrive during the load are still counted, because
		# `DotAchievementStatsLink` holds its baseline until the tracker has the
		# player. See `ArenaProgress.begin`.
		progress.begin(id, display_name)

	# Last, and only once the player is fully in: a handler runs synchronously inside
	# this and the first thing a client's does is hang a camera off them.
	player_added.emit(player)

	return DotResult.success(player)


func remove_player(id: int) -> void:
	var player := player_for(id)

	if player == null:
		return

	if props != null:
		# Before anything else: it drops whatever they were carrying, and a physics
		# gun still holding a crate for a player who no longer exists holds it for
		# ever — the prop is frozen mid-air and nothing owns it.
		props.release_player(id)

	if progress != null:
		# Before the player leaves the match: `leave` files the session onto the
		# boards and reads the display name off the player to do it.
		progress.leave(id)

	if player_stack != null:
		# Before dot-match forgets them: the stack reads the scoreboard and the match's
		# team for the records it files, and after `match_node.remove_player` there is
		# nothing there to read. A method rather than a signal, because there is no
		# signal here and adding one for a single subscriber is worse than a call.
		player_stack.drop_player(id)

	player.leave_combat()
	match_node.remove_player(str(id))

	_players.erase(id)
	remove_child(player)
	player.queue_free()


## Which side a player is on, or 0 in a free-for-all.
func team_of(id: int) -> int:
	if match_node == null or match_node.teams == null:
		return 0

	return match_node.teams.team_of(str(id))


## The sides in play, empty in a free-for-all.
func teams() -> Array[DotTeam]:
	if match_node == null or match_node.teams == null:
		return []

	return match_node.teams.teams


func player_for(id: int) -> ArenaPlayer:
	return _players.get(id)


func players() -> Array[ArenaPlayer]:
	var out: Array[ArenaPlayer] = []
	for key in _players.keys():
		out.append(_players[key])
	return out


func player_ids() -> Array[int]:
	var out: Array[int] = []
	for key in _players.keys():
		out.append(int(key))
	out.sort()
	return out


## Applies a player's saved loadout. Falls back to the default on any failure.
##
## A failure here must never stop a player spawning: an unreachable loadout store is a
## reason to give them a rifle, not a reason to leave them watching.
func apply_loadout(id: int) -> void:
	var player := player_for(id)

	if player == null:
		return

	var res: DotResult = await loadouts.active_for(_loadout_key(id))

	if not res.ok:
		DotLog.debug(CHANNEL, "loadout unavailable, using the default", {
			"player": id, "error": str(res.error)
		})
		player.give_default_loadout()
		return

	player.give_loadout(loadouts.resolve(res.value))


## A storage key that is usable as a filename.
##
## `DotLoadoutKey.is_usable` has a minimum length, so a bare session id of "7" is
## refused before any store sees it. Padding here rather than loosening the check: the
## check exists so a malformed key can never reach a filesystem path.
##
## [b]One key for every store, and that is deliberate.[/b] Loadouts, achievement
## progress and dot-stats' sessions are three subsystems that each want a durable
## per-player id, and three formats would be three chances for one of them to file
## under a name the others cannot find. It also refuses to be an account id: dot-stats'
## reporter rejects anything with a `backbone:` prefix before it leaves the server, and
## a key built from the session id can never carry one.
static func storage_key(id: int) -> String:
	return "arena-player-%08d" % id


func _loadout_key(id: int) -> String:
	return storage_key(id)


# --- Simulation ------------------------------------------------------------

## Advances the whole game one tick.
##
## [b]The order is the point of this method.[/b] Players simulate and produce shots;
## the shots are resolved against the world as it is *after* everyone has moved; the
## match's clock and win check run last, so a kill scored on this tick can end the
## round on this tick rather than the next one.
##
## [param commands] is `{player id: [DotFpsCommand, DotWeaponCommand]}`. A player with
## no entry repeats their last command, which is what a dropped input packet should
## look like.
func tick(commands: Dictionary = {}) -> void:
	_tick += 1

	var shots: Array[DotShot] = []
	var delta := 1.0 / float(tick_rate)

	for id in player_ids():
		var player: ArenaPlayer = _players[id]

		if not player.is_alive():
			continue

		var pair: Array = commands.get(id, [])
		var move: DotFpsCommand = pair[0] if pair.size() > 0 else DotFpsCommand.new()
		var fire: DotWeaponCommand = pair[1] if pair.size() > 1 else DotWeaponCommand.new()

		if move != null and fire != null:
			match_node.note_activity(str(id), _tick)
			var outcome := player.simulate_tick(_tick, delta, move, fire)
			shots.append_array(outcome.shots)
			# A rocket is not a shot and is not resolved here; it is launched and
			# flown. See ArenaProjectiles for why that is a new file.
			if projectiles != null:
				projectiles.accept(outcome)

	if is_authority:
		for shot in shots:
			# No view tick: these are shots the server itself produced from commands it
			# has already received, so there is nothing to rewind to. A real dedicated
			# server passes the client's acknowledged tick here and lag compensation
			# turns on with no other change.
			combat.resolve_shot(shot)

	# After the shots and before the match, and the position in the order is the
	# reason this is not two lines somewhere else. A monster has to perceive where the
	# players ended the tick, and a monster killed by a shot resolved above has to be
	# reported dead before the match's win check runs — otherwise its death is counted
	# on the following tick, which at a score limit is one round decided late.
	# Before the props and after the shots: a rocket that arrives this tick has to kill
	# before the match's win check runs, for the same reason everything below is
	# ordered the way it is.
	if projectiles != null:
		projectiles.tick(delta)

	if props != null:
		props.tick(delta)

	if horde != null:
		horde.tick(delta)

	# After the shots and before the match, for the same reason the two above are:
	# a burn that kills somebody has to be reported dead before the win check runs, and
	# an objective completed this tick has to be scored before it. An objective layer
	# ticked after the match is one round decided late, every time.
	if effects != null:
		effects.tick(delta)

	if objectives != null:
		objectives.tick(delta)

	if spectate != null:
		spectate.tick(delta)

	# Before the match, like everything above it, and for a different reason: the stack
	# expires spawn protection, and a player whose protection ran out on this tick has
	# to be killable by a shot the match is about to count.
	if player_stack != null:
		player_stack.tick(_tick)

	match_node.tick(_tick)


func current_tick() -> int:
	return _tick


# --- Events ----------------------------------------------------------------

func _on_entity_killed(entity_id: int, damage: DotDamage) -> void:
	var victim := player_for(entity_id)

	if victim == null:
		# Not a player. Something else registered with the combat manager, and the
		# match must not hear about it — see `non_player_killed`.
		non_player_killed.emit(entity_id, damage)
		return

	victim.make_dead()

	# An attacker of 0 is world damage — a fall, the void — and dot-match reads an
	# empty killer key as exactly that. Passing "0" instead would create a scoreboard
	# record for a player who does not exist.
	var killer_key := "" if damage.attacker == 0 else str(damage.attacker)

	var entry := match_node.report_kill(
		killer_key,
		str(entity_id),
		damage.weapon_id if damage.weapon_id != &"" else damage.type.id,
		_tick,
		damage.is_headshot()
	)

	player_killed.emit(entry)


func _on_damage_applied(damage: DotDamage) -> void:
	# Only players are on the scoreboard. Damage to or from anything else a game
	# layer registered with dot-combat — a monster, a breakable — would otherwise
	# create a record keyed on an id no player has, for the same reason
	# `non_player_killed` exists.
	if player_for(damage.victim) == null:
		return

	var attacker := (
		str(damage.attacker) if player_for(damage.attacker) != null else ""
	)

	match_node.report_damage(attacker, str(damage.victim), damage.health_lost)


func _on_respawn_due(key: String, spawn: DotSpawnPoint, tick: int) -> void:
	var id := int(key)
	var player := player_for(id)

	if player == null:
		return

	# [b]The director chooses; dot-match's point is the fallback.[/b] Both read the same
	# markers — `ArenaPlayerStack.refresh_spawns` copies dot-match's own `DotSpawnPoint`s
	# into the director — so this is not a second set of spawns, it is a better choice
	# among one set: enemy distance, line of sight, occupancy and a per-site cooldown,
	# none of which dot-match models.
	#
	# It is also where spawn protection is granted, which is the half that has to go
	# through here. `DotSpawnProtection.grant` is called inside `choose` and nowhere
	# else, so a game that took dot-match's point and skipped this has an empty ledger
	# and a `protection.advance()` that does nothing — which is what this one had.
	var at := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))

	if spawn != null:
		at = spawn.spawn_transform()

	if player_stack != null:
		var chosen := player_stack.choose_spawn(id)

		if chosen.ok:
			at = (chosen.value as DotSpawnChoice).transform
		elif spawn == null:
			# No point from either. Worth a line: the fallback below is the origin, and
			# a player standing at (0, 1, 0) on every respawn is a map with no usable
			# spawns rather than a player who found a strange corner.
			DotLog.warn(CHANNEL, "nothing chose a spawn", {
				"key": key, "why": chosen.error.message
			})

	player.hitboxes.enabled = true
	player.spawn(at, tick, match_node.spawn_protection_ticks())

	# [b]`ArenaEffects.on_spawn` was written, documented, and called by nothing.[/b] It
	# clears what survived the last life, stands the player up, and applies `PROTECTED` —
	# so until this line the arena's own spawn-protection effect had never been applied
	# to anybody, and a player who died burning respawned still burning. The family's
	# "a value produced correctly and consumed by nothing", for the third time in this
	# one respawn path.
	if effects != null:
		effects.on_spawn(id)

	_apply_loadout_deferred(id)

	player_spawned.emit(player)


## Loadouts come from a store, which may be slow. A respawn may not be.
##
## The player is already in the world with whatever they had; the loadout arrives a
## frame or two later. Awaiting it inside the respawn handler would make every spawn
## wait on a disk or a network round trip.
func _apply_loadout_deferred(id: int) -> void:
	var player := player_for(id)

	if player == null:
		return

	if player.arsenal.slots().is_empty():
		# The class's loadout first: `DotPlayerClassDef.loadout_id` is the field a mode
		# changes to change what everybody spawns holding, and it reached nothing until
		# this line. The hardcoded pair below is the fallback for a game with no
		# catalogue, which is what `give_default_loadout` always was.
		var from_class := (
			player_stack != null and player_stack.give_class_loadout(player)
		)

		if from_class:
			player.arsenal.select(2, player.controller.state.tick)
		else:
			player.give_default_loadout()

	apply_loadout(id)


func _on_match_state_changed(from: DotMatch.State, to: DotMatch.State) -> void:
	match_state_changed.emit(from, to)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"tick": _tick,
		"map": map.describe() if map != null else {},
		"players": _players.size(),
		"match": match_node.describe() if match_node != null else {},
		"combat": combat.describe() if combat != null else {},
		"progress": progress.describe() if progress != null else {},
		"horde": horde.describe() if horde != null else {},
		"props": props.describe() if props != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("arena    %s  tick %d" % [map.display_name if map != null else "?", _tick])
	out.append_array(match_node.describe_lines())
	out.append_array(combat.describe_lines())

	if progress != null:
		out.append_array(progress.describe_lines())

	if horde != null:
		out.append_array(horde.describe_lines())

	if props != null:
		out.append_array(props.describe_lines())

	return out
