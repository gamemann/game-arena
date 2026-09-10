@tool
class_name ArenaGame
extends Node

## The deathmatch itself: a match, a combat manager, a map, and some players.
##
## [b]This is the seam nothing else runs.[/b] dot-match knows nothing about damage,
## dot-combat knows nothing about scoring, dot-loadout knows nothing about weapons, and
## dot-fps-controller knows about none of them. Six addons, each correct alone. This is
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

@export_group("Service")

@export var register_service: bool = true

@export var service_scope: StringName = &""

var map: ArenaMap = null
var match_node: DotMatch = null
var combat: DotCombatManager = null
var loadouts: DotLoadoutManager = null

## player id -> [ArenaPlayer].
var _players: Dictionary = {}

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


func start(tick: int = 0) -> void:
	_tick = tick
	match_node.start(tick)


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

	# Last, and only once the player is fully in: a handler runs synchronously inside
	# this and the first thing a client's does is hang a camera off them.
	player_added.emit(player)

	return DotResult.success(player)


func remove_player(id: int) -> void:
	var player := player_for(id)

	if player == null:
		return

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
func _loadout_key(id: int) -> String:
	return "arena-player-%08d" % id


# --- Simulation ------------------------------------------------------------

## Advances the whole game one tick.
##
## [b]The order is the point of this method.[/b] Players simulate and produce shots;
## the shots are resolved against the world as it is *after* everyone has moved; the
## match's clock and win check run last, so a kill scored on this tick can end the
## round on this tick rather than the next one.
##
## [param commands] is `{player id: [DotFpsCommand, DotCombatCommand]}`. A player with
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
		var fire: DotCombatCommand = pair[1] if pair.size() > 1 else DotCombatCommand.new()

		if move != null and fire != null:
			match_node.note_activity(str(id), _tick)
			shots.append_array(player.simulate_tick(_tick, delta, move, fire))

	if is_authority:
		for shot in shots:
			# No view tick: these are shots the server itself produced from commands it
			# has already received, so there is nothing to rewind to. A real dedicated
			# server passes the client's acknowledged tick here and lag compensation
			# turns on with no other change.
			combat.resolve_shot(shot)

	match_node.tick(_tick)


func current_tick() -> int:
	return _tick


# --- Events ----------------------------------------------------------------

func _on_entity_killed(entity_id: int, damage: DotDamage) -> void:
	var victim := player_for(entity_id)

	if victim != null:
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
	match_node.report_damage(
		"" if damage.attacker == 0 else str(damage.attacker),
		str(damage.victim),
		damage.health_lost
	)


func _on_respawn_due(key: String, spawn: DotSpawnPoint, tick: int) -> void:
	var id := int(key)
	var player := player_for(id)

	if player == null:
		return

	var at := (
		spawn.spawn_transform() if spawn != null
		else Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	)

	player.hitboxes.enabled = true
	player.spawn(at, tick, match_node.spawn_protection_ticks())

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
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("arena    %s  tick %d" % [map.display_name if map != null else "?", _tick])
	out.append_array(match_node.describe_lines())
	out.append_array(combat.describe_lines())
	return out
