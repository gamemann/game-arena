extends RefCounted

const ArenaPaths := preload("arena_paths.gd")

const ArenaMap := preload("../maps/arena_map.gd")

## The monsters this game can spawn, and the navigation graph they walk on.
##
## [b]Both are derived from the map, and that is the same invariant the rest of the
## project is arranged around.[/b] [ArenaMap] holds a list of boxes; the meshes, the
## movement collision and the shot tracing are all generated from that one list so
## none of them can disagree. Navigation is the fourth: a graph built by hand against a
## map somebody later widened is a graph whose NPCs walk into a wall, and nothing
## reports it — an NPC that walks into a wall is what an NPC with no path does too.
##
## dot-npc's own notes on the generator make the case for feeding it the map's own
## constants rather than a scene: "a runtime handed a graph cannot raycast the map it
## came from". [method nav_for] hands it the boxes.
##
## The three monsters are three different answers to "how do I reach you", which is the
## same reason [ArenaContent] ships four weapons rather than one:
##
## [codeblock]
## grunt    cheap, slow, short sight.  The population.
## brute    expensive, tough, slow.    The thing you have to deal with.
## stalker  fast, fragile, far sight.  The thing that finds you.
## [/codeblock]

const CHANNEL := "arena.npcs"

const GRUNT := &"arena_grunt"
const BRUTE := &"arena_brute"
const STALKER := &"arena_stalker"

const FACTION := &"monster"

## Where the brain every one of them uses lives. A PATH, because a brain in a mounted
## dot-cloud pack cannot resolve a `class_name` — measured, in this family, as "every
## cross-file type reference inside a pack fails to compile".
static var BRAIN_PATH := ArenaPaths.rebase("res://game/arena_npc_brain.gd")


static func catalogue() -> DotNpcCatalogue:
	var out := DotNpcCatalogue.new()
	out.meta = {"game": "arena"}

	for def in [_grunt(), _brute(), _stalker()]:
		var added := out.add(def)

		if not added.ok:
			DotLog.warn(CHANNEL, "an NPC could not be catalogued", {
				"npc": String(def.id), "why": added.error.message
			})

	return out


## The population budget and pacing a horde runs under.
static func limits() -> DotNpcLimits:
	var out := DotNpcLimits.new()

	# Well under dot-npc's default of 96. An arena is a room, not a campaign level,
	# and forty monsters in a forty-metre square is already a wall of them.
	out.world_budget = 40
	out.per_kind_cap = 24
	out.spawn_interval = 0.25
	out.burst_cap = 6

	# Reclaimed generously: an arena is small, so a monster ninety metres away is one
	# that has fallen out of the world rather than one that wandered off.
	out.reclaim_distance = 80.0
	out.reclaim_grace = 6.0
	out.clean_up_on_leave = true

	# Every fourth tick. Perception is the single most expensive thing an NPC layer
	# does — a line-of-sight test per candidate per NPC — and a monster that notices
	# you 30 ms late is a monster nobody can tell from one that noticed you at once.
	out.sense_period_ticks = 4
	out.sense_candidate_cap = 24

	out.require_navigable_spawn = true
	out.spawn_snap_radius = 3.0

	return out


static func _grunt() -> DotNpcDef:
	var def := DotNpcDef.make(GRUNT, ArenaPaths.rebase("res://npcs/arena_grunt.tscn"))
	def.display_name = "Grunt"
	def.category = &"monster"
	def.faction = FACTION
	def.brain_script_path = BRAIN_PATH
	def.weight = DotNpcDef.Weight.NORMAL
	def.cost = 1
	def.max_health = 60.0
	def.move_speed = 4.2
	def.sight_range = 26.0
	def.sight_half_angle_deg = 70.0
	def.hearing_range = 14.0
	def.require_line_of_sight = true
	def.meta = {"damage": 12.0, "reach": 1.9, "attack_interval": 1.0}
	return def


static func _brute() -> DotNpcDef:
	var def := DotNpcDef.make(BRUTE, ArenaPaths.rebase("res://npcs/arena_brute.tscn"))
	def.display_name = "Brute"
	def.category = &"monster"
	def.faction = FACTION
	def.brain_script_path = BRAIN_PATH
	def.weight = DotNpcDef.Weight.HEAVY
	# Five, so the world budget of 40 is eight brutes rather than forty. `cost` is
	# what makes a population budget mean "how much" rather than "how many", and a
	# heavy that cost 1 would let a director fill the arena with them.
	def.cost = 5
	def.max_health = 320.0
	def.move_speed = 2.8
	def.sight_range = 22.0
	def.sight_half_angle_deg = 60.0
	def.hearing_range = 18.0
	def.require_line_of_sight = true
	def.meta = {"damage": 34.0, "reach": 2.6, "attack_interval": 1.6}
	return def


static func _stalker() -> DotNpcDef:
	var def := DotNpcDef.make(STALKER, ArenaPaths.rebase("res://npcs/arena_stalker.tscn"))
	def.display_name = "Stalker"
	def.category = &"monster"
	def.faction = FACTION
	def.brain_script_path = BRAIN_PATH
	def.weight = DotNpcDef.Weight.LIGHT
	def.cost = 2
	def.max_health = 40.0
	def.move_speed = 7.5
	def.sight_range = 48.0
	def.sight_half_angle_deg = 100.0
	def.hearing_range = 26.0
	# Off, deliberately. A stalker that only knows where you are while it can see you
	# is a stalker that gives up at the first pillar, which is the one thing it is not
	# supposed to do.
	def.require_line_of_sight = false
	def.meta = {"damage": 9.0, "reach": 1.7, "attack_interval": 0.55}
	return def


# --- Navigation ------------------------------------------------------------

## Builds a navigation graph over one map's geometry.
##
## [b]The floor is one rectangle and the boxes are obstacles, which is the whole of
## it.[/b] An arena map is a floor plus solids; there is no second storey to link and
## no ramp to mark, so the grid the builder lays down over the floor with the solids
## punched out of it is exactly the walkable set.
##
## [b]The digest is not decoration.[/b] [method DotNpcNavData.matches] is how a runtime
## tells "this graph was built for this map" from "this graph was built for a map with
## the same name", and the second one is a graph whose NPCs walk through the walls
## somebody added since. It is computed from the geometry rather than from the id for
## that reason.
static func nav_for(map: ArenaMap, spacing: float = 2.0) -> DotNpcNavData:
	var builder := DotNpcNavBuilder.new()
	builder.spacing = spacing
	builder.point_radius = spacing
	# Half a body width past the geometry, so a monster standing on the last legal
	# point is beside the wall rather than inside it.
	builder.clearance = 0.7
	builder.generate_cover = true

	var floor_area := AABB(
		Vector3(-map.extent, map.floor_y, -map.extent),
		Vector3(map.extent * 2.0, 0.1, map.extent * 2.0)
	)
	builder.add_floor(floor_area, map.floor_y)

	for box in map.boxes:
		builder.add_obstacle(box)

	return builder.build(map.id, digest_of(map))


## A fingerprint of a map's geometry, for [method DotNpcNavData.matches].
##
## Every box, the extent and the floor height. A map whose id is unchanged and whose
## geometry moved produces a different digest, which is the case the check exists for.
static func digest_of(map: ArenaMap) -> String:
	var parts: Array = [String(map.id), map.extent, map.floor_y]

	for box in map.boxes:
		parts.append(box.position)
		parts.append(box.size)

	return DotNpcNavData.digest_of(parts)
