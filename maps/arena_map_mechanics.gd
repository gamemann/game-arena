extends RefCounted

const ArenaBspMap := preload("arena_bsp_map.gd")

## What an imported combat surf map's brush entities DO to a player: its pushes, gravity
## volumes, conveyors, water, ladders and hurt volumes.
##
## [b]A copy of game-g2gfast's `G2GMapMechanics`, not a dependency.[/b] A game cannot name
## another game's script and a delivered pack cannot resolve a `class_name`, so this is the
## half arena needs, preloaded by path, in metres (the manifest's units through
## [constant ArenaBspMap.METRES_PER_UNIT], as the rest of the loader converts). The
## importer's `tools/bsp_mechanics.py` in g2gfast writes the manifest's `mechanics` block;
## this reads it.
##
## Every volume is an [AABB] in metres and every question a box test against the player's
## own hull, for the reason [DotFpsSwimMode] gives: an [Area3D] answers after the physics
## step on the main loop, and a client replaying ten ticks of prediction cannot ask one
## where it WAS. A box list gives the server and the client's replay the same answer.
##
## What it runs, and where it differs from g2gfast on purpose:
##
## - [b]A push[/b] (`trigger_push`) is the engine's base velocity: while the hull is inside,
##   the player is displaced by the push on top of their own velocity, which gravity and
##   friction never touch; on leaving, the push is added to the velocity, so a booster
##   sends you on at its speed. A "once" push is added on entering. An upward push lifts a
##   player off the ground.
##   [b]Stateless, where g2gfast keeps a per-tick history.[/b] g2gfast remembers which
##   pushes held a player in a dictionary keyed by `DotFpsState.tick`, and that counter
##   does not travel: after a rewind the client's copy keeps counting from its newest tick
##   while the position is the server's, so a history keyed by it reads the wrong tick on
##   every replay. Here "was this player in it" is asked of the hull where the tick
##   STARTED (the state a replay starts from, so both ends ask the same question), and a
##   push whose own displacement carries the player out of its box hands its velocity
##   over on that same tick, because the next tick starts outside and could not know. A
##   teleport forgets a push by itself, too: the next tick starts at the destination.
## - [b]Gravity[/b] (`trigger_gravity`) scales the fall while airborne inside.
## - [b]A conveyor[/b] (`func_conveyor`) carries a player standing on its top.
## - [b]Water[/b] and [b]ladders[/b] are lists handed to the player's [DotFpsSwimMode] and
##   ladder mode (`arena_ladder_mode.gd`).
## - [b]Hurt[/b] (`trigger_hurt`) is REAL damage here, where g2gfast treats 100 or more as a
##   death and ignores the rest because a timer run has no health. The engine these maps
##   come from reads `damage` as per second and deals it in half-second pulses; arena does
##   the same through dot-combat as world damage, on the server, so the kill feed, the
##   scoreboard and the statistics hear it like any other death. A negative amount heals,
##   as it does there. See `ArenaGame._hurt_from_map`. Not predicted: health is the
##   server's and replicates.
## - [b]Sinking blocks[/b] (`blocks`) are not ported. None of the ten combat surf maps has
##   one, and the mechanic is a timer-map's: a per-player delay that ends in a teleport the
##   GAME performs, plus the plate it sends you to — a second event path into the match
##   for a map that does not exist. [method read] counts them so a map that gains one says
##   so in [method describe_lines] instead of silently standing still.

## How far a foot may be off a conveyor's top and still be standing on it, metres.
const STAND_TOLERANCE := 3.0 * ArenaBspMap.METRES_PER_UNIT

## How far below the feet a volume still touches the player, metres.
const TOUCH_BELOW := 2.0 * ArenaBspMap.METRES_PER_UNIT

## The interval a hurt volume deals its damage at, seconds: the engine's own half second.
const HURT_INTERVAL := 0.5

var water: Array[AABB] = []
var ladders: Array[AABB] = []
var pushes: Array[Dictionary] = []      # {box: AABB, push: Vector3 m/s, once: bool}
var gravity: Array[Dictionary] = []     # {box: AABB, scale: float}
var hurt: Array[Dictionary] = []        # {box: AABB, damage: float per second}
var conveyors: Array[Dictionary] = []   # {box: AABB, push: Vector3 m/s}

## Sinking blocks the manifest lists, which this does not run. See the class note.
var blocks_skipped: int = 0


## Reads the manifest's `mechanics` block. A manifest written before there was one reads
## as nothing, which is what such a map has always had.
func read(manifest: Dictionary) -> void:
	var block: Dictionary = manifest.get("mechanics", {})

	for v: Variant in block.get("water", []):
		water.append(_box(v))
	for v: Variant in block.get("ladders", []):
		ladders.append(_box(v))
	for v: Variant in block.get("push", []):
		var d: Dictionary = v
		pushes.append({"box": _box(d), "push": ArenaBspMap.to_metres(d.get("push")),
			"once": bool(d.get("once", false))})
	for v: Variant in block.get("gravity", []):
		var d: Dictionary = v
		gravity.append({"box": _box(d), "scale": float(d.get("scale", 1.0))})
	for v: Variant in block.get("hurt", []):
		var d: Dictionary = v
		hurt.append({"box": _box(d), "damage": float(d.get("damage", 0.0))})
	for v: Variant in block.get("conveyors", []):
		var d: Dictionary = v
		conveyors.append({"box": _box(d), "push": ArenaBspMap.to_metres(d.get("push"))})

	blocks_skipped = (block.get("blocks", []) as Array).size()


func is_empty() -> bool:
	return water.is_empty() and ladders.is_empty() and pushes.is_empty() \
		and gravity.is_empty() and hurt.is_empty() and conveyors.is_empty()


## The volume a player's hull is tested against: the standing (or crouched) hull, and two
## units under the feet as well. A trigger lying ON the floor (surf_fruits' pushes are
## 1-unit sheets) is touched by a player standing on it, and the hull alone only grazes it.
static func hull_at(feet: Vector3, tunables: DotFpsTunables, crouch_fraction: float) -> AABB:
	var r := tunables.radius
	var height := tunables.height_at(crouch_fraction)
	return AABB(feet - Vector3(r, TOUCH_BELOW, r), Vector3(r * 2.0, height + TOUCH_BELOW, r * 2.0))


## One tick of the pushes, gravity and conveyors on [param state], after the motor has
## moved it. [param start] is where the player stood when the tick began.
func simulate(motor: DotFpsMotor, state: DotFpsState, start: Vector3, delta: float) -> void:
	if motor == null or state.mode == DotFpsState.Mode.NOCLIP:
		return

	var tunables := motor.tunables
	var hull := hull_at(state.position, tunables, state.crouch_fraction)

	_pushes(motor, state, hull, hull_at(start, tunables, state.crouch_fraction), delta)

	if not state.is_grounded():
		for g: Dictionary in gravity:
			if (g["box"] as AABB).intersects(hull):
				state.velocity.y += (1.0 - float(g["scale"])) * tunables.gravity * delta
				break
	else:
		for c: Dictionary in conveyors:
			if _standing_on(c["box"], state.position, tunables.radius):
				_displace(motor, state, c["push"], delta)
				break


## The indexes into [member hurt] of every volume the hull touches, so a caller can time
## each one on its own: the engine these maps come from times a hurt trigger per trigger,
## and a player stepping from one into the next takes the second's pulse at once.
func hurts_at(feet: Vector3, tunables: DotFpsTunables, crouch_fraction: float) -> PackedInt32Array:
	var touched := PackedInt32Array()
	if hurt.is_empty():
		return touched

	var hull := hull_at(feet, tunables, crouch_fraction)
	for i in range(hurt.size()):
		if (hurt[i]["box"] as AABB).intersects(hull):
			touched.append(i)

	return touched


func _pushes(motor: DotFpsMotor, state: DotFpsState, hull: AABB, before: AABB, delta: float) -> void:
	if pushes.is_empty():
		return

	var base := Vector3.ZERO
	var was := Vector3.ZERO

	for p: Dictionary in pushes:
		var box: AABB = p["box"]
		var push: Vector3 = p["push"]
		var inside := box.intersects(hull)
		var was_inside := box.intersects(before)

		if p["once"]:
			# Added on entering, once: in it now and not where the tick began.
			if inside and not was_inside:
				state.velocity += push
				if push.y > 0.0 and state.is_grounded():
					motor.set_mode(state, DotFpsState.Mode.AIR)
			continue

		if inside:
			base += push
		if was_inside:
			was += push

	if base != Vector3.ZERO:
		if base.y > 0.0 and state.is_grounded():
			motor.set_mode(state, DotFpsState.Mode.AIR)
		_displace(motor, state, base, delta)

		# Carried out of it by its own push: the base velocity is the player's from here,
		# on this tick, because the next one starts outside and would never know. This is
		# how nearly every booster is left — a floor sheet pushes you off its own end.
		var after := hull_at(state.position, motor.tunables, state.crouch_fraction)
		var still := false
		for p: Dictionary in pushes:
			if not p["once"] and (p["box"] as AABB).intersects(after):
				still = true
				break
		if not still:
			state.velocity += base
	elif was != Vector3.ZERO:
		# Out of it this tick: the base velocity becomes the player's own, which is what
		# makes a booster a booster rather than a moving walkway.
		state.velocity += was


## Moves [param state] by [param velocity] for one tick through the motor's own sweep,
## leaving the player's own velocity as it was: a base velocity is not the player's.
static func _displace(motor: DotFpsMotor, state: DotFpsState, velocity: Vector3, delta: float) -> void:
	var own := state.velocity
	state.velocity = velocity
	motor.move_and_slide(state, delta)
	state.velocity = own


static func _standing_on(box: AABB, feet: Vector3, reach: float) -> bool:
	if absf(feet.y - box.end.y) > STAND_TOLERANCE:
		return false
	return feet.x > box.position.x - reach and feet.x < box.end.x + reach \
		and feet.z > box.position.z - reach and feet.z < box.end.z + reach


## A manifest box in metres. `abs()` for [method ArenaBspMap.bounds_of]'s reason: the
## importer's corners are not min and max on every axis.
static func _box(v: Variant) -> AABB:
	var d: Dictionary = v
	var lo := ArenaBspMap.to_metres(d.get("min"))
	var hi := ArenaBspMap.to_metres(d.get("max"))
	return AABB(lo, hi - lo).abs()


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"water %d, ladders %d, pushes %d, gravity %d, hurt %d, conveyors %d, blocks %d (not run)"
			% [water.size(), ladders.size(), pushes.size(), gravity.size(), hurt.size(),
				conveyors.size(), blocks_skipped],
	])
