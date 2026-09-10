class_name ArenaProps
extends Node

## Physics props in the arena, and the two tools that move them.
##
## [b]This is the one part of the game that runs on Godot's physics, and everything
## else is arranged so it does not have to.[/b] The player's collision, the shot
## tracing and the navigation are all analytic geometry from [ArenaMap], because
## analytic gives the same answer on a client replaying a tick and a server that ran
## it. A rigid body does not — a contact solver is not reproducible across machines —
## which is why dot-props is server-authoritative and unpredicted, and why nothing here
## is ever handed to the netcode's prediction path.
##
## The cost of that exception is one method: [method ArenaMap.to_collision]. A prop has
## to have something to land on, and a dedicated server has never instantiated the
## level because it has nothing to draw it to.
##
## [codeblock]
## var props := ArenaProps.new()
## props.game = game
## add_child(props)
## props.setup()
## props.spawn_for(session_id, ArenaProps.CRATE, in_front_of_player)
## [/codeblock]
##
## [b]Why an arena has props at all.[/b] Not as a sandbox — game-playground is the
## sandbox and this is not trying to be one. A crate you can shoot into a doorway is
## cover you made, a barrel you punt is a weapon you improvised, and both are things
## the geometry cannot give you because the geometry does not move. It is also the only
## place in this game where a player changes the map.

const CHANNEL := "arena.props"

const CRATE := &"arena_crate"
const BARREL := &"arena_barrel"
const BALL := &"arena_ball"
const PALLET := &"arena_pallet"

## A prop was spawned by somebody. Carries the player id, for a stat.
signal prop_spawned(player_id: int, prop: DotPropInstance)

@export_group("Rules")

## Whether players may spawn props at all.
##
## Off by default. An arena is a deathmatch and a player who can wall themselves in is
## a player nobody can fight; a server that wants it turns it on, and a mode can.
@export var players_may_spawn: bool = false

## Props the map itself places, spawned at boot and owned by nobody.
##
## Distinct from what players spawn: these are level furniture and do not count against
## anybody's budget, so `arena_props_clear` taking them away is a decision rather than
## an accident. [method clear_players] is what an admin actually wants.
@export var scatter_count: int = 0

var game: ArenaGame = null

var spawner: DotPropSpawner = null

## Grab, hold, rotate, freeze. One per player, because it holds what that player has.
##
## [b]Per player and not per server.[/b] A single tool object is a single held prop,
## so the second player to press the button takes the first player's crate out of
## their hands — silently, because a tool that changed what it was holding is exactly
## what grabbing something else looks like.
var _phys_guns: Dictionary = {}

## Punt and pull. Same reason.
var _grav_guns: Dictionary = {}

## Where the props live, and what they land on.
var _world: Node3D = null
var _collision: Node3D = null

var _limits: DotPropLimits = null


## Builds the spawner and puts the level into a physics space.
func setup() -> DotResult:
	if game == null or game.map == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The props layer needs a game with a map."
		)

	_world = Node3D.new()
	_world.name = "Props"
	add_child(_world)

	_rebuild_collision()

	_limits = _make_limits()

	spawner = DotPropSpawner.new()
	spawner.name = "PropSpawner"
	spawner.catalogue = catalogue()
	spawner.limits = _limits
	spawner.authoritative = game.is_authority
	spawner.world_ref = DotNodeRef.of_path(NodePath("../Props"))
	add_child(spawner)

	spawner.spawned.connect(_on_spawned)

	game.map_changed.connect(_on_map_changed)

	if scatter_count > 0:
		scatter(scatter_count)

	return DotResult.success(self)


## Puts the level's static geometry into the physics space, or replaces what is there.
##
## [b]Only where nothing else has.[/b] A client has already added [method
## ArenaMap.to_scene], which carries the same static bodies with meshes on them; adding
## these as well is two sets of colliders in one space — every prop resting on whichever
## the solver reached first, and no way to tell from looking.
func _rebuild_collision() -> void:
	if _collision != null and is_instance_valid(_collision):
		remove_child(_collision)
		_collision.free()
		_collision = null

	if not game.headless:
		# A client or a listen server draws the level, and drawing it is what puts it
		# in the physics space. See the note above.
		return

	_collision = game.map.to_collision()
	add_child(_collision)


func _make_limits() -> DotPropLimits:
	var limits := DotPropLimits.new()

	# An arena, not a sandbox. Twelve props is enough to build cover and far too few
	# to wall a doorway shut, which is the failure mode of a budget set generously.
	limits.per_player_budget = 12
	limits.per_player_frozen = 6
	limits.spawn_interval = 0.75
	limits.world_budget = 96
	limits.clean_up_on_leave = true
	limits.undo_depth = 12
	limits.max_size = DotPropDef.Size.LARGE

	# Reach and mass, in this game's numbers. The map is 48 m across, so a 20 m grab
	# range is "anything you can see down a lane" rather than "anything at all".
	limits.grab_range = 20.0
	limits.grab_mass_limit = 220.0
	limits.hold_distance_min = 2.0
	limits.hold_distance_max = 8.0

	return limits


## What can be spawned. Four props, which is four different weights.
##
## [b]The mass is the interesting field and it is the one the catalogue owns.[/b]
## dot-props puts it on the body at spawn rather than leaving it to whatever the scene
## was saved with, which is what makes one scene serve several entries — and this
## catalogue does exactly that: a crate and a pallet are the same script at different
## sizes, and the physics gun's mass limit is what tells them apart.
static func catalogue() -> DotPropCatalogue:
	var out := DotPropCatalogue.new()
	out.meta = {"game": "arena"}

	for def in [_crate(), _barrel(), _ball(), _pallet()]:
		var added := out.add(def)

		if not added.ok:
			DotLog.warn(CHANNEL, "a prop could not be catalogued", {
				"prop": String(def.id), "why": added.error.message
			})

	return out


static func _crate() -> DotPropDef:
	var def := DotPropDef.make(CRATE, "res://props/arena_crate.tscn")
	def.display_name = "Crate"
	def.category = &"cover"
	def.size = DotPropDef.Size.SMALL
	def.mass = 35.0
	def.cost = 1
	return def


static func _barrel() -> DotPropDef:
	var def := DotPropDef.make(BARREL, "res://props/arena_barrel.tscn")
	def.display_name = "Barrel"
	def.category = &"cover"
	def.size = DotPropDef.Size.MEDIUM
	def.mass = 90.0
	def.cost = 2
	return def


static func _ball() -> DotPropDef:
	var def := DotPropDef.make(BALL, "res://props/arena_ball.tscn")
	def.display_name = "Ball"
	def.category = &"toy"
	def.size = DotPropDef.Size.SMALL
	# Light and round, so it is the one a gravity gun actually throws across the map.
	def.mass = 12.0
	def.cost = 1
	# Nothing to hide behind. Freezing it in mid-air would make it a step, which is a
	# movement exploit rather than a toy.
	def.can_freeze = false
	return def


static func _pallet() -> DotPropDef:
	var def := DotPropDef.make(PALLET, "res://props/arena_pallet.tscn")
	def.display_name = "Pallet"
	def.category = &"cover"
	def.size = DotPropDef.Size.LARGE
	# Above `grab_mass_limit`, deliberately. A physics gun refuses it and a player has
	# to shoot it or push it — which is what makes the mass limit a rule somebody can
	# feel rather than a number in a config.
	def.mass = 260.0
	def.cost = 3
	return def


# --- The tick --------------------------------------------------------------

## Advances the spawner's rate limits and every held prop. Once per game tick.
func tick(delta: float) -> void:
	if spawner != null:
		spawner.advance(delta)

	_carry(delta)


# --- Spawning --------------------------------------------------------------

## Spawns a prop for a player, subject to the budget and the interval.
func spawn_for(player_id: int, prop_id: StringName, at: Vector3) -> DotPropInstance:
	if spawner == null:
		return null

	if not players_may_spawn:
		return null

	return spawner.spawn(prop_id, StringName(str(player_id)), at)


## Places props around the map, owned by nobody. Level furniture.
##
## Deterministic: a ring at a fixed radius, indexed. Random placement would mean a
## server and a client that both scattered got different levels, and a suite that
## passed differently the second time it was run.
##
## [b]The map's furniture shares a player's budget, and that is dot-props' rule rather
## than a bug here.[/b] [method DotPropSpawner.may_spawn] checks
## [member DotPropLimits.per_player_budget] against the owner it is given, and the
## empty owner is an owner like any other — so eight props are eight props' worth of
## cost against twelve, not eight free ones. The first version of this scattered
## crates, barrels and pallets in rotation, which is 14 points for 8 props, and it
## placed seven and refused the eighth [i]silently[/i]: a refusal is a legitimate
## answer and nothing anywhere errors.
##
## Two things follow. The rotation avoids the pallet, so eight props cost ten. And a
## short scatter is reported rather than shrugged at, because "the map has less cover
## than it was asked for" is not something anybody would otherwise notice.
func scatter(count: int) -> int:
	if spawner == null or game == null or game.map == null:
		return 0

	var kinds := [CRATE, BARREL, CRATE, CRATE]
	var placed := 0
	var radius := game.map.extent * 0.55

	for index in range(count):
		var angle := TAU * float(index) / float(maxi(count, 1))
		var at := Vector3(
			cos(angle) * radius, game.map.floor_y + 1.2, sin(angle) * radius
		)

		# The spawn interval is a rate limit on PLAYERS, and the map is not one.
		# dot-props keeps one "last spawn" per owner and the map's furniture all
		# shares the empty owner, so eight placements in one call would place one and
		# refuse seven — which is what happened the first time this ran, and it looked
		# exactly like a scatter that had been configured for one prop.
		#
		# Advancing the spawner's own clock is the honest way past it rather than
		# zeroing the interval: it is the same clock the limit is measured against,
		# and the only cost is that a player who happened to be mid-cooldown when the
		# map changed gets it back. That is a fraction of a second, once a map.
		if _limits != null and index > 0:
			spawner.advance(_limits.spawn_interval + 0.01)

		var made := spawner.spawn(kinds[index % kinds.size()], &"", at)

		if made != null:
			placed += 1

	if placed < count:
		DotLog.warn(CHANNEL, "the map placed less cover than it asked for", {
			"asked": count,
			"placed": placed,
			"budget": _limits.per_player_budget if _limits != null else 0,
		})

	return placed


# --- Tools -----------------------------------------------------------------

## This player's physics gun, made on first use.
func phys_gun(player_id: int) -> DotPhysGun:
	if not _phys_guns.has(player_id):
		var gun := DotPhysGun.new()
		gun.spawner = spawner
		gun.wielder = StringName(str(player_id))
		_phys_guns[player_id] = gun

	return _phys_guns[player_id]


## This player's gravity gun, made on first use.
func grav_gun(player_id: int) -> DotGravGun:
	if not _grav_guns.has(player_id):
		var gun := DotGravGun.new()
		gun.spawner = spawner
		gun.wielder = StringName(str(player_id))
		_grav_guns[player_id] = gun

	return _grav_guns[player_id]


## Does what a player asked with their tools. The one door for a prop intent.
##
## [b]Server side only, and every check is here rather than at the caller.[/b] A prop
## is server-authoritative and unpredicted because a contact solver is not reproducible
## across machines; the client sends what it wanted and this decides whether it
## happened. `DotPropTool.may_act_on` is what enforces the range, the mass limit and
## whose prop it is — none of which a client is asked about.
func act(player_id: int, action: int, origin: Vector3, direction: Vector3) -> bool:
	if spawner == null or not spawner.authoritative:
		return false

	# Typed, not inferred. `_space()` returns Variant — the tools take one so they
	# compile outside a 3D scene — and `var x := f()` on a Variant is a parse ERROR
	# under these projects' warning settings, not a warning.
	var space: Variant = _space()

	if space == null:
		# No physics space to query. A dedicated server has one — `_rebuild_collision`
		# put the level in it — but a client mirroring this layer does not, and a tool
		# with nothing to trace against would grab whatever was last returned.
		return false

	# The player's view as a Basis, which `DotPhysGun` needs and the wire does not
	# carry: it is derivable from the two angles it does carry, and a third
	# representation of the same aim on the wire is a third thing that can disagree.
	var view := Basis.looking_at(direction, Vector3.UP)

	match action:
		ArenaEvents.PropAct.GRAB:
			return phys_gun(player_id).grab(space, origin, direction, view).ok
		ArenaEvents.PropAct.RELEASE:
			return phys_gun(player_id).release() != null
		ArenaEvents.PropAct.FREEZE:
			return phys_gun(player_id).freeze_held().ok
		ArenaEvents.PropAct.PUNT:
			return grav_gun(player_id).punt(space, origin, direction) != null
		ArenaEvents.PropAct.PULL:
			return grav_gun(player_id).pull(space, origin, direction).ok

	return false


## Keeps every held prop where its holder is looking. Once per tick.
##
## [b]Held props move every tick and a grab happens once.[/b] `DotPhysGun.hold` is what
## carries one, and a layer that only called `grab` would give a player a prop that
## stayed exactly where it was picked up — which reads as the physics gun not working
## rather than as a missing call.
##
## `held` is checked rather than an `is_holding()`: `DotPhysGun` exposes the instance
## and not a predicate, and a prop can be freed while it is held — an admin clearing
## the world, a map change — so the aliveness test is the one that matters.
func _carry(delta: float) -> void:
	if game == null:
		return

	for id in _phys_guns.keys():
		var gun: DotPhysGun = _phys_guns[id]

		if gun.held == null or not gun.held.is_alive():
			continue

		var player := game.player_for(int(id))

		if player == null or not player.is_alive():
			gun.release()
			continue

		var aim := player.aim_direction()
		gun.hold(
			player.muzzle_position(),
			aim,
			Basis.looking_at(aim, Vector3.UP),
			delta
		)

	for id in _grav_guns.keys():
		var gun: DotGravGun = _grav_guns[id]

		if not gun.is_carrying():
			continue

		var player := game.player_for(int(id))

		if player == null or not player.is_alive():
			gun.drop()
			continue

		gun.carry(player.muzzle_position(), player.aim_direction(), delta)


## The physics space the tools trace in, or null when there is none.
##
## Typed [Variant] because `DotPropTool.target` takes one: the tools are written so
## they compile in a project that is not in a 3D scene at all, which is how they are
## tested headlessly.
##
## [b]Taken off the world node rather than off this one.[/b] `ArenaProps` is a plain
## [Node] and `get_world_3d()` does not exist on one — dot-npc's own notes record the
## same mistake, where a duck-typed `has_method` branch around it would not even
## compile because GDScript cannot infer what such a branch returns.
func _space() -> Variant:
	if _world == null or not _world.is_inside_tree():
		return null

	# Typed explicitly. `var x := f()` where f returns Variant is a parse ERROR under
	# these projects' warning settings, and `_world.get_world_3d()` on a Node3D
	# reached through an untyped path is exactly that case.
	var world: World3D = _world.get_world_3d()
	return world.direct_space_state if world != null else null


## Drops whatever a player was holding and forgets their tools.
##
## Called when they leave. Without it the tool objects outlive the session, and the
## next player to be given the same id inherits whatever the last one was carrying.
func release_player(player_id: int) -> void:
	if _phys_guns.has(player_id):
		(_phys_guns[player_id] as DotPhysGun).release()
		_phys_guns.erase(player_id)

	if _grav_guns.has(player_id):
		(_grav_guns[player_id] as DotGravGun).drop()
		_grav_guns.erase(player_id)

	if spawner != null:
		spawner.player_left(StringName(str(player_id)))


# --- Admin -----------------------------------------------------------------

func undo(player_id: int) -> bool:
	return spawner.undo(StringName(str(player_id))) if spawner != null else false


## Removes only what players spawned, leaving the map's own furniture.
func clear_players() -> int:
	if spawner == null or game == null:
		return 0

	var removed := 0

	for player in game.players():
		removed += spawner.clear_player(StringName(str(player.player_id)))

	return removed


func clear_all() -> int:
	return spawner.clear_all(DotPropSpawner.REASON_ADMIN) if spawner != null else 0


func count() -> int:
	return spawner.world_count() if spawner != null else 0


# --- Events ----------------------------------------------------------------

func _on_spawned(prop: DotPropInstance) -> void:
	var owner_id := String(prop.owner_id).to_int()

	prop_spawned.emit(owner_id, prop)

	if owner_id > 0 and game != null and game.progress != null:
		game.progress.record(owner_id, ArenaStats.PROPS_SPAWNED)


func _on_map_changed(_map: ArenaMap) -> void:
	# Every prop belonged to the world that was just replaced, and its nodes are
	# children of this node rather than of the map — so nothing freed them, and a
	# crate left floating where a wall now is has no floor under it and falls for
	# ever. The static geometry has to be replaced too, for the same reason.
	if spawner != null:
		spawner.clear_all(DotPropSpawner.REASON_CLEANUP)

	for id in _phys_guns.keys():
		(_phys_guns[id] as DotPhysGun).release()

	for id in _grav_guns.keys():
		(_grav_guns[id] as DotGravGun).drop()

	_rebuild_collision()

	if scatter_count > 0:
		scatter(scatter_count)


func describe() -> Dictionary:
	return {
		"props": count(),
		"players_may_spawn": players_may_spawn,
		"spawner": spawner.describe() if spawner != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("props     %d in the world" % count())

	if spawner != null:
		out.append_array(spawner.describe_lines())

	return out
