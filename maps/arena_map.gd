extends RefCounted

const ArenaMap := preload("arena_map.gd")

## A level as a list of boxes, and the three things that list becomes.
##
## [b]This is the idea the whole project is arranged around.[/b] A dev-textured arena
## is a floor and some boxes. Those boxes have to exist in three places:
##
## - as [MeshInstance3D]s, so a player can see them,
## - as [StaticBody3D]s, so Godot's physics can collide with them,
## - as analytic [AABB]s, so [DotFpsFlatBody] and [DotTraceFlat] can — on a headless
##   server and in a test, where there is no physics space and no renderer.
##
## Building them independently means three descriptions that drift, and the drift is
## invisible: the server's idea of a wall moves a metre and shots start passing through
## something clients can see. So the boxes are declared once, here, and everything else
## is generated from them.
##
## The same reason a game like this ships with dev textures in the first place. A
## grey-box level whose geometry is its gameplay is a level you can reason about.

const CHANNEL := "arena.map"

## Solid boxes, in world space.
var boxes: Array[AABB] = []

## Ground plane height. Boxes sit on it.
var floor_y: float = 0.0

## Half-extent of the playable area on X and Z. Walls are generated at the edges.
var extent: float = 24.0

## Wall height.
var wall_height: float = 8.0

## Where players appear. Fed into [DotMatch]'s spawn points.
var spawns: Array[Transform3D] = []

## What each spawn belongs to, parallel to [member spawns].
##
## Empty means every spawn is untagged and any player may use any of them, which is
## what a free-for-all wants. Otherwise it is EXACTLY as long as [member spawns] and
## `spawn_tags[i]` is the tag of `spawns[i]` — `DotTeam.spawn_tag` matches against it,
## which is what sends a side to its own end of the map.
##
## [b]Always append through [method add_spawn].[/b] Two parallel arrays that can be
## written independently are two lists that will disagree, which is this tree's most
## repeated bug; the helper is the only reason they cannot.
var spawn_tags: PackedStringArray = PackedStringArray()

## What [method by_id] answers to, and what a [DotMapDef] is keyed on.
##
## [b]Separate from [member display_name] even though the two happen to match.[/b] An
## id is an address — a rotation entry, a leaderboard scope, a vote choice and a record
## all name a map by it — and a display name is text somebody may want to change.
## [ArenaMapDirector] used to read `display_name` as the id, which worked exactly until
## the first map that wanted a nicer name than its filename.
var id: StringName = &"dm_box"

var display_name: String = "dm_box"


## Every climb this map asks a player to make, derived from the boxes themselves.
##
## [b]Always append through [method add_climb], and never write this by hand.[/b] See
## [method jump_reach] for why this list exists at all.
var climbs: Array[Climb] = []


## Top faces a player is deliberately never meant to stand on.
##
## `[gate-sweep-1]`'s second question is whether a map has floor nobody can reach, and
## the honest answer for most maps is "yes, on purpose": a pillar's top is a surface,
## and a pillar you could climb would be a different map. The survey in `headless_match`
## flood-fills every map and fails on any unreached surface that is not one of these,
## so an unreachable top is a decision somebody wrote down rather than a thing nobody
## noticed. Append through [method add_out_of_reach].
var out_of_reach: Array[AABB] = []


## One step up a map expects a player to make, measured off the geometry it is made of.
##
## [b]Constructed from the two boxes rather than from two numbers.[/b] A climb written
## as `add_climb("the crates", 1.5, 3.0, 0.5)` is a fourth description of geometry that
## is already described three times, and it goes stale the first time somebody moves a
## crate — which is the failure this whole class exists to catch, reintroduced one level
## up. Reading the boxes means the declaration cannot disagree with the map: what is
## declared is only WHICH two boxes are a route, and that is the one thing the geometry
## genuinely does not say.
class Climb:
	extends RefCounted

	## What to call it when the check fails.
	var name: String = ""

	## Metres gained, top face to top face.
	var rise: float = 0.0

	## Clear horizontal air between the two footprints. Zero when they touch or overlap,
	## which is a step across rather than a jump.
	var gap: float = 0.0

	## The two boxes, kept so that the gap between them is known to be a JUMP. The
	## survey's slot rule reads them: 0.5 m of air between two crates is a slot nobody
	## can walk through and is not meant to be walked through, and the only thing that
	## says which of the two it is is this declaration.
	var from_box: AABB = AABB()
	var to_box: AABB = AABB()

	static func between(of_name: String, from_box: AABB, to_box: AABB) -> Climb:
		var climb := Climb.new()
		climb.name = of_name
		climb.from_box = from_box
		climb.to_box = to_box
		climb.rise = to_box.end.y - from_box.end.y
		climb.gap = maxf(
			_clear_between(from_box.position.x, from_box.end.x, to_box.position.x, to_box.end.x),
			_clear_between(from_box.position.z, from_box.end.z, to_box.position.z, to_box.end.z)
		)
		return climb

	## The clear air between two intervals, or 0 when they overlap.
	##
	## [b]The larger of the two axes is the gap, not the diagonal.[/b] Two boxes offset
	## on both axes are crossed by jumping along whichever axis separates them; the
	## diagonal between their nearest corners is a distance no player travels, and using
	## it would refuse routes that are comfortably crossable.
	static func _clear_between(a_min: float, a_max: float, b_min: float, b_max: float) -> float:
		if b_min >= a_max:
			return b_min - a_max

		if a_min >= b_max:
			return a_min - b_max

		return 0.0


# --- What the movement can actually do -------------------------------------
#
# [b]The three numbers every gap on every map here is sized against, copied from
# `ArenaPlayer.arena_tunables()` deliberately.[/b] A map is content: `by_id` is called
# from a tool and from a catalogue listing with no player anywhere in the tree, and
# reaching into the game's player class from a map would make content depend on the
# game rather than the other way round. The family's answer to a deliberate copy is a
# check that the copies agree, and `headless_match` asserts these three against the
# tunables the server actually applies.

## Ground speed, m/s. `DotFpsTunables.max_speed`.
const MOVE_SPEED := 9.0

## Metres. `DotFpsTunables.jump_height`, which is the PEAK of a standing jump and not
## the height of something a player can climb onto by walking at it.
const JUMP_HEIGHT := 1.25

## m/s². `DotFpsTunables.gravity`. Not Godot's project default, which is 9.8.
const MOVE_GRAVITY := 22.0

## Metres. `DotFpsTunables.step_height`: a rise under this is WALKED, not jumped.
const STEP_HEIGHT := 0.4

## How much of the jump has to be left over at the top.
##
## A player landing at exactly [constant JUMP_HEIGHT] arrives with zero vertical speed
## at the one instant of the arc where a tick either side of it is short — which is a
## step that works when the tick lands right and does not when it does not. A map whose
## routes are 90% of the apex is a map that works every time.
const CLIMB_MARGIN := 0.9


## The highest top face a player standing on flat ground can reach, in metres.
##
## [b]This is the number three maps in this game were built without.[/b] `jump_height`
## reads like the height of a thing you can get onto and it is the apex of the arc, so
## a crate at 1.5 with `jump_height` 1.25 looks like a 0.25 m stretch and is in fact a
## wall. `dm_atrium`'s south-east crates were 1.5, 3.0 and 4.6 from the day the map was
## written: a route the map's own documentation called "the fast way up" that nothing
## has ever climbed, because nothing had ever been asked to.
static func climb_limit() -> float:
	return JUMP_HEIGHT * CLIMB_MARGIN


## The clear air a player running at [constant MOVE_SPEED] crosses in one jump, landing
## [param rise] metres higher than they left.
##
## [b]The landing height is the whole point of this function.[/b] The airtime everybody
## writes down is the time to fall back to the height you jumped FROM, and it is the
## wrong number for any route that climbs: at this game's numbers a player is airborne
## for 0.67 s flat and 0.40 s onto a step 1.2 m up, which is 6.1 m of reach against
## 3.6. `game-playground` sized a jump course with the first number, was 30% out, and
## was unfinishable past platform three from the day it was built — see `[reach-1]` in
## `nightly-todo.md`. This is that arithmetic for this game's movement.
##
## Returns 0.0 for a rise no jump reaches at all, which is the honest answer: there is
## no gap you can cross onto something you cannot get on top of.
static func jump_reach(rise: float) -> float:
	var launch := sqrt(2.0 * MOVE_GRAVITY * JUMP_HEIGHT)
	var remaining := launch * launch - 2.0 * MOVE_GRAVITY * rise

	if remaining < 0.0:
		return 0.0

	# The DESCENDING root. The ascending one is the same height on the way up, which is
	# a shorter jump that lands on the near lip rather than the far one.
	return MOVE_SPEED * (launch + sqrt(remaining)) / MOVE_GRAVITY


## Declares that [param to_box] is meant to be reached from [param from_box].
##
## [b]The only hand-written part is which two boxes are a route.[/b] Everything
## measured about the climb comes off the boxes, so moving a crate moves the climb with
## it and `headless_match`'s sweep re-decides it. A climb is not checked against
## anything here — a map is content and content does not assert — it is checked in the
## suite, where failing is useful.
func add_climb(of_name: String, from_box: AABB, to_box: AABB) -> ArenaMap:
	climbs.append(Climb.between(of_name, from_box.abs(), to_box.abs()))
	return self


## Declares that nobody is meant to stand on [param box]'s top. See [member out_of_reach].
func add_out_of_reach(box: AABB) -> ArenaMap:
	out_of_reach.append(box.abs())
	return self


## The ground plane as a box, so that "off the floor" is an ordinary climb.
##
## Wide enough that its footprint contains every map, which is what makes the gap of a
## climb out of it zero — a player standing on the ground is already underneath whatever
## they are about to jump onto, and the only thing that decides the jump is the rise.
static func _floor_at(y: float) -> AABB:
	return AABB(Vector3(-1000.0, y - 1.0, -1000.0), Vector3(2000.0, 1.0, 2000.0))


## The shipped arena: a square room, a raised centre, four pillars, two ledges, and
## since 2026-09-24 two gantries joining the ledges and a nest on two of the pillars.
##
## Symmetric on purpose. A symmetric map makes every spawn point score identically for
## the spawn selector, which is exactly the tie its name-based tie-break exists for —
## so the map that ships is also the map that exercises it.
static func dm_box() -> ArenaMap:
	var map := ArenaMap.new()
	map.id = &"dm_box"
	map.display_name = "dm_box"
	map.extent = 24.0
	map.wall_height = 8.0

	# The raised middle. Two steps up, so stair stepping is exercised by walking at it.
	map.add_box(AABB(Vector3(-6.0, 0.0, -6.0), Vector3(12.0, 1.0, 12.0)))
	map.add_box(AABB(Vector3(-7.0, 0.0, -7.0), Vector3(14.0, 0.5, 14.0)))

	# Four pillars, off the diagonals so they break sightlines rather than framing them.
	# The two at x ±12 stand beside the crate stacks and nobody stands on them — see
	# the nests below for why those two and not the others.
	for corner in [Vector2(-12.0, -4.0), Vector2(12.0, 4.0), Vector2(-4.0, 12.0), Vector2(4.0, -12.0)]:
		var pillar := AABB(
			Vector3(corner.x - 1.5, 0.0, corner.y - 1.5), Vector3(3.0, 5.0, 3.0)
		)
		map.add_box(pillar)

		if absf(corner.x) > 10.0:
			map.add_out_of_reach(pillar)

	# Two ledges along opposite walls, top face at 3.6.
	#
	# [b]6.5 m deep, and the last half metre is for the crates.[/b] They were 6, which
	# left a metre of air between the top crate and the ledge — too far for a player
	# hopping up with jump held (see the crates below). The crates cannot move toward
	# the wall instead: the spawns on the x axis stand at ±18, and a crate there is a
	# player spawning with their nose against a 2.7 m box. So the ledge reaches out to
	# meet them, and the axis spawns stand under its lip, which is cover.
	var west_ledge := AABB(Vector3(-map.extent, 3.0, -18.0), Vector3(6.5, 0.6, 36.0))
	var east_ledge := AABB(Vector3(map.extent - 6.5, 3.0, -18.0), Vector3(6.5, 0.6, 36.0))

	map.add_box(west_ledge)
	map.add_box(east_ledge)

	# --- Getting onto them -------------------------------------------------
	#
	# [b]This comment used to read "reachable from the pillars" and they were not
	# reachable from anywhere.[/b] The pillars are 5 m tall against a 1.25 m jump
	# APEX, so nothing has ever stood on one; the ledges are at 3.6 with the raised
	# middle at 1.0 as the next highest thing on the map. Both ledges have been
	# geometry a player can be shot from and cannot get to since the day dm_box was
	# written, and every check over this map passed the whole time, because a box
	# count cannot tell a platform from a ceiling. See [method jump_reach].
	#
	# Three crates to each ledge, 0.9 at a time to 2.7 and a fourth 0.9 onto the
	# ledge itself — 72% of the apex per step, so each is a jump and none is a
	# stretch. Each crate is 0.5 m of clear air on from the last, the number the other
	# two maps use.
	#
	# [b]It was 1.0 m until 2026-09-24, and no bot could climb it.[/b] A metre is a
	# fifth of what a RUNNING jump crosses at this rise, and it is too far for a
	# player hopping up with jump held: auto-hop leaves the ground on the tick it
	# lands, air speed caps at 1.2 m/s, and a hop that happens to start in the middle
	# of a 2.5 m crate carries 0.6 m — so the bot fell into the gap between the first
	# two crates and stood at the foot of a 1.8 m wall. `headless_match` drives the
	# whole climb now; the route has to work for the way a player climbs a stack, not
	# only for the way they cross a gap.
	#
	# [b]Mirrored, and that is not decoration.[/b] This map is symmetric so that every
	# spawn scores identically for the spawn selector, which is the tie its name-based
	# tie-break exists to break — it is the property dm_box ships FOR, and the reason
	# the arcade went on dm_atrium instead. A route added to one wall and not the
	# other would take that away for the sake of a shortcut.
	for side in [-1.0, 1.0]:
		var previous := AABB()

		for step in range(3):
			var top := 0.9 * float(step + 1)
			var crate := AABB(
				Vector3(
					-17.0 if side < 0.0 else 14.5,
					0.0,
					# Mirrored about z 0 through the CENTRE, not the corner: signing a
					# corner reflects the box onto the wrong side of itself and the two
					# walls stop being each other's mirror, which is the one thing this
					# map may not lose.
					side * (6.25 - float(step) * 3.0) - 1.25
				),
				Vector3(2.5, top, 2.5)
			)
			map.add_box(crate)

			if step == 0:
				map.add_climb("dm_box: the floor onto the first crate", _floor_at(0.0), crate)
			else:
				map.add_climb("dm_box: crate %d onto crate %d" % [step, step + 1], previous, crate)

			previous = crate

		map.add_climb(
			"dm_box: the top crate onto the %s ledge" % ["west" if side < 0.0 else "east"],
			previous,
			west_ledge if side < 0.0 else east_ledge
		)

	# --- The gantries and the two nests (2026-09-24) -----------------------
	#
	# [b]The ledges were two dead ends.[/b] Once the crates made them reachable, each
	# was 36 m of high ground with one way on and every way off being down: a player
	# who climbed one had nowhere to go but back into the room. Two gantries now cross
	# the room between them at ledge height, north and south of the raised middle, so
	# the upper level is a LOOP — ledge, gantry, ledge, gantry — and holding it is a
	# matter of moving along it rather than standing at the top of a stair.
	#
	# Each gantry passes one of the two pillars that stand north and south of the
	# middle, and carries a single 0.9 m step against it. The pillar's top is 5.0,
	# 1.4 over the gantry and so out of reach from it; the step makes it 0.9 then 0.5,
	# and the two pillar tops become the map's third tier — a 3 m nest over the middle
	# that sees both ledges, both gantries and the whole floor, and that every one of
	# those sees back. The other two pillars stay out of reach on purpose: they stand
	# beside the crate stacks, and a nest there would be a nest at the top of the
	# route up, which is the one place on this map a nest should not be.
	#
	# [b]Point-symmetric, like everything else on this map.[/b] The north gantry and
	# its nest are the south gantry and its nest turned half a circle about the
	# origin, so every spawn still scores identically for the spawn selector — the
	# property dm_box exists for. `headless_match` asserts the whole box list is its
	# own half-turn rather than trusting this paragraph.
	#
	# The gantry is 2.5 m wide and flush with the pillar's face, so the step can sit on
	# it against the pillar and still leave 1.5 m of walkway beside it; set 0.5 m off
	# the pillar instead, the step would have had to hang over that half metre of air
	# or leave a slot between gantry and pillar that looks, from the floor, like a way
	# up. Its far edge is 0.5 m clear of the nearest crate stack, which is what stops a
	# player jumping up the first crate from striking their head on it.
	const GANTRY_Y := 3.0
	const GANTRY_T := 0.6
	const GANTRY_W := 2.5
	const NEST_STEP := 0.9

	for side in [-1.0, 1.0]:
		# side -1 is the north gantry (z -10.5..-8), side +1 its turn about the origin.
		var gantry := AABB(
			Vector3(west_ledge.end.x, GANTRY_Y, 8.0 if side > 0.0 else -8.0 - GANTRY_W),
			Vector3(east_ledge.position.x - west_ledge.end.x, GANTRY_T, GANTRY_W)
		)
		# The pillar this gantry passes: (4, -12) for the north one, (-4, 12) for the
		# south. Its face toward the middle is the gantry's outer edge.
		var pillar := AABB(
			Vector3(side * -4.0 - 1.5, 0.0, side * 12.0 - 1.5), Vector3(3.0, 5.0, 3.0)
		)
		var step := AABB(
			Vector3(pillar.position.x, GANTRY_Y, 9.5 if side > 0.0 else -10.5),
			Vector3(3.0, GANTRY_T + NEST_STEP, 1.0)
		)

		map.add_box(gantry)
		map.add_box(step)

		var which := "south" if side > 0.0 else "north"

		map.add_climb("dm_box: the west ledge onto the %s gantry" % which, west_ledge, gantry)
		map.add_climb("dm_box: the %s gantry onto the east ledge" % which, gantry, east_ledge)
		map.add_climb("dm_box: the east ledge onto the %s gantry" % which, east_ledge, gantry)
		map.add_climb("dm_box: the %s gantry onto the west ledge" % which, gantry, west_ledge)
		map.add_climb("dm_box: the %s gantry onto its nest step" % which, gantry, step)
		map.add_climb("dm_box: the %s nest step onto the pillar" % which, step, pillar)

	map.add_perimeter()

	# Eight spawns around the outside, facing the middle. Enough that a full server is
	# not spawning two people on one point, and far enough apart that the
	# furthest-from-danger rule has something to choose between.
	# Tagged by hemisphere rather than alternately, so a team mode starts the two
	# sides at opposite ends rather than interleaved around one circle.
	for index in range(8):
		var angle := TAU * float(index) / 8.0
		var at := Vector3(cos(angle) * 18.0, 0.1, sin(angle) * 18.0)
		map.add_spawn(
			Transform3D(Basis.looking_at(-at.normalized(), Vector3.UP), at),
			&"red" if index < 4 else &"blue"
		)

	return map


## The second arena: an open-roofed building in a yard, and three ways onto its roof.
##
## [b]Deliberately not a variation on `dm_box`, and `dm_box` was deliberately not
## extended.[/b] That map is symmetric on purpose — every spawn scores identically for
## the spawn selector, which is the tie its name-based tie-break exists for — so growing
## a wing onto it would take away the one property it is there to hold. This is the
## other half of that: asymmetric, vertical, and with routes that are not each other's
## mirror.
##
## The shape is one central building whose roof is a ring around an open shaft. Standing
## on the ring you can shoot down into the middle; standing in the middle you can be
## shot from four sides, and the two doorways are the only way out at floor level. That
## is the whole map — everything else is a way of getting up there:
##
## - [b]the north-west stair[/b], eight steps, walkable, the route that costs nothing
##   and is the one everybody can see you take;
## - [b]the south-east crates[/b], five jumps, faster, and it leaves you on the far
##   side from the stair. [b]Three jumps until 2026-09-22, and unclimbable for every
##   one of those days[/b] — the steps were 1.5 m against a 1.25 m jump apex;
## - [b]the north-east perch[/b], reached only from the roof by three 0.7 m hops. It
##   looks over the shaft from above the ring, and it is the only place on the map with
##   no cover at all — the trade the height is paid for.
##
## The south-west bunker is the ground-level answer to all of it: three walls at chest
## height, open to the west, the one place a player can break line of sight from the
## roof without leaving the yard — and since the arcade was added, the one place that
## leads somewhere.
##
## [b]The south arcade[/b] is the map's second layer and the reason the bunker is worth
## walking to. A colonnade 25 m long and 5 m deep runs east from a doorway cut in the
## bunker's east wall to the foot of the south-east crates, roofed at 3.6 and carried on
## piers that stand only at its two long edges. It is cover from the ring and from
## nothing else. Its roof is a firing position 0.4 m below the ring, reached by a ten
## tread stair at the back of the yard or by stepping across from the crates.
static func dm_atrium() -> ArenaMap:
	var map := ArenaMap.new()
	map.id = &"dm_atrium"
	map.display_name = "dm_atrium"
	map.extent = 30.0
	map.wall_height = 12.0

	# --- The building ------------------------------------------------------
	#
	# A square ring of wall, 20 m across the outside, 1.5 m thick, 4 m tall, with one
	# 6 m doorway in the middle of each side. Built as eight segments rather than four
	# walls with holes in them, because a hole is not a box and everything downstream
	# of this list understands only boxes.
	const WALL_H := 4.0
	const WALL_T := 1.5

	# North and south, split around a doorway from x -3 to 3.
	for z in [-10.0, 8.5]:
		map.add_box(AABB(Vector3(-10.0, 0.0, z), Vector3(7.0, WALL_H, WALL_T)))
		map.add_box(AABB(Vector3(3.0, 0.0, z), Vector3(7.0, WALL_H, WALL_T)))

	# West and east, split around a doorway from z -3 to 3.
	for x in [-10.0, 8.5]:
		map.add_box(AABB(Vector3(x, 0.0, -8.5), Vector3(WALL_T, WALL_H, 5.5)))
		map.add_box(AABB(Vector3(x, 0.0, 3.0), Vector3(WALL_T, WALL_H, 5.5)))

	# The roof, as a ring 4 m wide with a 12 x 12 shaft open in the middle. Overhangs
	# the wall inward by 2.5 m, so a player on the ring is standing over the room and
	# a player in the room has to step out from under it to shoot back.
	var ring_south := AABB(Vector3(-10.0, WALL_H, 6.0), Vector3(20.0, 0.6, 4.0))

	map.add_box(AABB(Vector3(-10.0, WALL_H, -10.0), Vector3(20.0, 0.6, 4.0)))
	map.add_box(ring_south)
	map.add_box(AABB(Vector3(-10.0, WALL_H, -6.0), Vector3(4.0, 0.6, 12.0)))
	map.add_box(AABB(Vector3(6.0, WALL_H, -6.0), Vector3(4.0, 0.6, 12.0)))

	# A plinth under the shaft. Something to land on from the ring, and the only cover
	# inside a room with four doorways pointed at it.
	map.add_box(AABB(Vector3(-3.0, 0.0, -3.0), Vector3(6.0, 1.2, 6.0)))

	# --- North-west stair --------------------------------------------------
	#
	# Thirteen steps of 0.36, which is under `DotFpsTunables.step_height` (0.4) and so
	# is walked rather than jumped — the point of this route being the one that costs
	# nothing. [b]Measured, not assumed:[/b] the first draft used 0.6 and a bot holding
	# forward stopped dead against the first tread, four seconds of walking for 0.8 m of
	# travel, which is what `headless_match` now catches.
	#
	# Each step is a full-height box rather than a tread, because a tread with air under
	# it is two boxes and the analytic body would let a player stand in the gap.
	#
	# [b]The top tread is flush with the building's west face, x = -10.[/b] It stopped
	# 0.75 m short until 2026-09-24, which left a 0.75 m slot between the stair's end
	# and the wall's north segment — narrower than the 0.8 m a player is, and running
	# from the yard straight to the west doorway, so from the ground it read as a way
	# in. `[gate-sweep-1]`'s slot rule found it. Flush, the walk onto the ring is a
	# step across with no air under it as well.
	for index in range(13):
		map.add_box(AABB(
			Vector3(-19.75 + float(index) * 0.75, 0.0, -4.0),
			Vector3(0.75, 0.36 * float(index + 1), 4.0)
		))

	# --- South-east crates -------------------------------------------------
	#
	# [b]Rebuilt 2026-09-22, because the route this map advertises as its fast way up
	# has never once been climbed.[/b] It was three crates at 1.5, 3.0 and 4.6, and
	# every one of those steps is a 1.5 m rise against a jump whose APEX is 1.25 — so
	# a player could not get onto the first crate, let alone the roof. Nothing caught
	# it in the year it stood there: the box count was right, the three
	# representations agreed, no spawn was buried in it, and not one check in the
	# suite had ever asked a bot to climb it. See [method jump_reach] and `[reach-1]`.
	#
	# Five crates now, 0.9 m apart, each 0.5 m of clear air north of the last. That is
	# 72% of [method climb_limit] per step and a tenth of the reach per gap, so the
	# route is a rhythm rather than a series of stretches — which is what "the fast way
	# up" was always supposed to mean. It costs two more crates and it is the first
	# version of this route a player can use.
	#
	# The stack climbs NORTH up the east side rather than north-west across the corner,
	# for the join below: the fourth crate's top is 3.6, the arcade roof's top is 3.6,
	# and they stand 0.5 m apart. The arcade's east end is a step across at the same
	# height in both directions, which is what that route was always documented to be
	# and what a stack of the wrong heights had quietly made one-way.
	# [b]A straight column rather than a diagonal across the corner, and that was a
	# bot's doing.[/b] The first rebuild stepped 1 m west as well as 4 m north per
	# crate, which is a 14° diagonal, and a bot aimed down it reached the third crate
	# and walked off the west edge of the fourth — 2.5 m of shared face is plenty to
	# land on and not enough to keep walking along when the surface under you keeps
	# moving sideways. A column is a route a player can hold one key down and climb,
	# which is what "the fast way up" has to mean before it can mean anything else.
	var crates: Array[AABB] = []

	for step in range(4):
		crates.append(AABB(
			Vector3(12.5, 0.0, 24.0 - float(step) * 4.0),
			Vector3(3.5, 0.9 * float(step + 1), 3.5)
		))
		map.add_box(crates[step])

	# [b]The landing: the fifth step up, and a platform rather than a fifth crate.[/b]
	# It is 6 m by 5.5 at 4.5, filling the outside of the building's south-east corner
	# and touching the roof ring along the whole 4 m of its south arm that reaches x
	# 10. A crate the size of the other four would have been the same height and still
	# useless: a bot that climbed it stood at z 11.4 — a metre and a half south of the
	# band of the ring that is actually adjacent — and walked west off it into the
	# yard, which is exactly what happened on the first attempt at this. A route's last
	# step has to overlap what it joins, not merely reach its height near it.
	#
	# It must not be wider still: the column has to stand clear of the arcade's east
	# end, and a box reaching further south would bury the last pier and grow through
	# the arcade roof.
	var landing := AABB(Vector3(10.0, 0.0, 6.0), Vector3(6.0, 4.5, 5.5))

	map.add_box(landing)

	map.add_climb("dm_atrium: the yard onto the first crate", _floor_at(0.0), crates[0])

	for step in range(1, 4):
		map.add_climb(
			"dm_atrium: crate %d onto crate %d" % [step, step + 1],
			crates[step - 1],
			crates[step]
		)

	map.add_climb("dm_atrium: the top crate onto the landing", crates[3], landing)

	# --- North-east perch --------------------------------------------------
	#
	# Only from the roof, and only by jumping: 4.6 -> 5.3 -> 6.0 -> 6.7. Nothing on the
	# ground reaches it, which is what stops it being the place everyone stands.
	var perch_boxes: Array[AABB] = [
		AABB(Vector3(11.0, 0.0, -9.0), Vector3(2.5, 5.3, 3.0)),
		AABB(Vector3(13.5, 0.0, -9.0), Vector3(2.5, 6.0, 3.0)),
		AABB(Vector3(16.0, 0.0, -12.0), Vector3(5.0, 6.7, 8.0)),
	]

	for box in perch_boxes:
		map.add_box(box)

	# 4.6 -> 5.3 -> 6.0 -> 6.7, all off the ring's east arm. These three were the only
	# climbs on this map that were ever inside what the movement can do, which is why
	# the sweep in `headless_match` has to cover the routes that LOOK fine as well as
	# the ones somebody is suspicious of.
	map.add_climb(
		"dm_atrium: the ring onto the first perch step",
		AABB(Vector3(6.0, WALL_H, -6.0), Vector3(4.0, 0.6, 12.0)),
		perch_boxes[0]
	)
	map.add_climb("dm_atrium: the perch's second step", perch_boxes[0], perch_boxes[1])
	map.add_climb("dm_atrium: the perch itself", perch_boxes[1], perch_boxes[2])

	# The top of the crates onto the roof ring's south-east corner. 0.1 m, which is
	# under `step_height` and is therefore walked — a route that ends in a jump you
	# might miss is a route that ends at the bottom of it.
	map.add_climb("dm_atrium: the landing onto the roof ring", landing, ring_south)

	# --- South-west bunker -------------------------------------------------
	#
	# Three walls at 2.5, open to the west. Was the only ground-level cover from the
	# ring; since the arcade below it is the west end of a covered route rather than a
	# dead end, and its east wall is split around a 4 m doorway at z 14..18 to let that
	# route through. The doorway is exactly the arcade's clear span between piers, so a
	# player leaving the bunker is under cover the moment they are through it.
	map.add_box(AABB(Vector3(-24.0, 0.0, 8.0), Vector3(12.0, 2.5, 1.2)))
	map.add_box(AABB(Vector3(-24.0, 0.0, 19.0), Vector3(12.0, 2.5, 1.2)))
	map.add_box(AABB(Vector3(-13.2, 0.0, 8.0), Vector3(1.2, 2.5, 6.0)))
	map.add_box(AABB(Vector3(-13.2, 0.0, 18.0), Vector3(1.2, 2.5, 2.2)))

	# --- The south arcade --------------------------------------------------
	#
	# [b]Added because the map had one answer to the roof and it was "do not be in the
	# yard".[/b] Everything above is a way UP; the ring overhangs, sees the whole yard,
	# and the bunker was the only square of ground it cannot see -- a corner to hide in
	# with nowhere to go from it. The arcade is the missing half: 25 m of roofed ground
	# running east from that bunker to the foot of the south-east crates, so the route
	# from the map's safest corner to its fastest way up is under cover for all of it.
	#
	# [b]A colonnade rather than a tunnel, and that is the whole balance of it.[/b] The
	# piers stand at the two long edges only, so the arcade is opaque from ABOVE and
	# open from the SIDES: it beats the ring and it does not beat a player standing in
	# the yard beside it. A solid box here would have been a safe corridor across the
	# middle of the map, which is a worse map than no corridor at all.
	#
	# Its roof is the second thing it is for. The top face is 3.6 -- deliberately 0.4
	# UNDER the building's ring at 4.0 -- so the arcade roof is a firing position that
	# overlooks the south yard and is itself overlooked. Whoever holds the ring still
	# holds the map; they now have somewhere to be shot at from.
	#
	# Three ways on and off it, and none of them is the same as another:
	#
	# - [b]the south stair[/b], ten treads of 0.36, walked rather than jumped, out in
	#   the open at the back of the yard and the slowest thing on the map;
	# - [b]the east end[/b], a step across onto the fourth south-east crate, level with
	#   it, which joins the arcade to the five-jump route to the ring;
	# - [b]down[/b], anywhere, which is what stops the roof being a place to camp.
	const ARC_X := -13.2
	const ARC_W := 25.2
	const ARC_Z := 13.0
	const ARC_D := 5.0
	const ARC_Y := 3.0
	const ARC_T := 0.6
	const PIER := 1.5

	var arcade_roof := AABB(Vector3(ARC_X, ARC_Y, ARC_Z), Vector3(ARC_W, ARC_T, ARC_D))

	map.add_box(arcade_roof)

	# [b]The east end, in both directions.[/b] The arcade roof's top is 3.6 and so is
	# the fourth crate's, and they stand 0.5 m apart — declared as two climbs rather
	# than one because a route is not symmetric just because its geometry is: a step
	# ACROSS is a rise of zero each way here, and the day either top face moves this
	# says so twice. Before the crates were rebuilt this join went down 0.6 onto a
	# crate at 3.0 and could not be climbed back, which made the arcade a one-way
	# street that the map's own notes described as a connection.
	map.add_climb("dm_atrium: the arcade roof onto the crates", arcade_roof, crates[3])
	map.add_climb("dm_atrium: the crates onto the arcade roof", crates[3], arcade_roof)

	# Five piers on each long edge. 4 m of daylight between them, which is wider than
	# the building's doorways -- the arcade is meant to be shot into, and a colonnade
	# you cannot see through is the tunnel this is not.
	#
	# [b]The last pair is flush with the crate column, x 11 to 12.5.[/b] It stood at
	# 10.5 to 12 until 2026-09-24, half a metre short of the crates, which left two 0.5
	# m slots between pier and crate that looked from inside the arcade like its east
	# way out and that no player fits through. `[gate-sweep-1]`'s slot rule found both.
	# The half metre of pier past the roof's end sits in the gap the step across to the
	# crates jumps, 0.6 m under it, where nothing can stand.
	for index in range(5):
		var pier_x := -11.0 + float(index) * 5.5

		map.add_box(AABB(Vector3(pier_x, 0.0, ARC_Z), Vector3(PIER, ARC_Y, PIER)))
		map.add_box(AABB(
			Vector3(pier_x, 0.0, ARC_Z + ARC_D - PIER), Vector3(PIER, ARC_Y, PIER)
		))

	# The south stair. Ten treads of 0.36 climbing north, the last one's north face
	# flush with the arcade roof's south edge at z 18 -- a stair that stops half a metre
	# short is a stair with a hole at the top of it, which reads as falling through the
	# map. 0.36 rather than anything larger for the reason the north-west stair gives:
	# it is under `DotFpsTunables.step_height`, so it is WALKED, and a bot holding
	# forward climbs it instead of stopping dead against the first tread.
	for index in range(10):
		map.add_box(AABB(
			Vector3(-10.0, 0.0, 26.1 - float(index) * 0.9),
			Vector3(4.0, 0.36 * float(index + 1), 0.9)
		))

	map.add_perimeter()

	# --- Spawns ------------------------------------------------------------
	#
	# Ten, and deliberately NOT on a circle. `dm_box` puts eight on one, which makes
	# every spawn score the same and is the point of that map; here they are scattered
	# around the yard at real distances from each other so the furthest-from-danger rule
	# has something to actually pick. Two are on the roof ring, because a map with three
	# routes up should not make every fight start at the bottom of them.
	var points: Array[Vector3] = [
		Vector3(-25.0, 0.1, -22.0),
		Vector3(-4.0, 0.1, -24.0),
		Vector3(22.0, 0.1, -25.0),
		Vector3(26.0, 0.1, -4.0),
		Vector3(25.0, 0.1, 21.0),
		Vector3(2.0, 0.1, 25.0),
		Vector3(-20.0, 0.1, 23.0),
		Vector3(-26.0, 0.1, 2.0),
		Vector3(-8.0, WALL_H + 0.7, -8.0),
		Vector3(8.0, WALL_H + 0.7, 8.0),
	]

	for at in points:
		# Facing the building, which is where the fight is. Flattened to the horizontal
		# because a spawn looking down at its own feet is a spawn you have to correct
		# before you can play, and the two roof spawns would otherwise do exactly that.
		var to_centre := Vector3(-at.x, 0.0, -at.z)

		if to_centre.length_squared() < 0.001:
			to_centre = Vector3.FORWARD

		# By the sign of z, which on this map is the long axis: the two sides start at
		# opposite ends of the atrium with the building between them. A point sitting on
		# the axis is untagged, so it stays a shared fallback rather than being given
		# arbitrarily to one side.
		var tag := &""

		if at.z < -0.5:
			tag = &"red"
		elif at.z > 0.5:
			tag = &"blue"

		map.add_spawn(
			Transform3D(Basis.looking_at(to_centre.normalized(), Vector3.UP), at), tag
		)

	return map


## The third arena: a sunken floor, a catwalk around it, and one bridge across.
##
## [b]Free-for-all only, and that is the point rather than an omission.[/b] Every spawn
## here is untagged, so [method ArenaMaps.supports_mode] answers no for a team mode and
## this is the first map in the game that ever does. `dm_box` and `dm_atrium` both tag
## their spawns, which means the three places that ask the question -- the ballot, the
## mode half of the ballot, and the refusal in [ArenaMapSession] -- had never once been
## told no by a real map. A filter with nothing to filter is a filter nobody has run.
##
## It is also the small map this game did not have. `dm_box` is 48 m across and
## `dm_atrium` 60; this is 28, and a map you can cross in four seconds is a different
## game rather than a smaller one -- which is the reason a shooter ships one.
##
## [b]The shape.[/b] The floor is the pit. A 3 m catwalk runs around all four walls at
## 3.6 m, with 3 m of headroom under it, so the ring is both the high ground and a
## covered gallery for whoever is beneath it. A 2 m bridge crosses north to south
## through the middle at catwalk height, over open air.
##
## Three ways up, and they are deliberately not equivalent:
##
## - [b]the north-west stair[/b], ten treads of 0.36, walkable, slow, and in the open;
## - [b]the south-east stair[/b], its mirror, so the two long diagonals are symmetric
##   and nothing else on the map is;
## - [b]the north-east crates[/b], three jumps and a fourth onto the ring, which is
##   the fast way and the only one that does not announce itself. [b]Two jumps until
##   2026-09-22, the first of them onto a 1.4 m crate, and a jump here peaks at
##   1.25[/b] — so it was the fast way up for nobody.
##
## Down is free everywhere, which is what keeps the pit from being a trap: the ring is
## worth holding for as long as nobody has decided to drop on you.
##
## [b]Extended 2026-09-18.[/b] A second bridge east to west makes the middle a
## crossing rather than a chord, and a shelf in the south-west corner carries a perch
## at 5.4 — the map's third tier, two 0.9 m hops up from the ring. Nine spawns now,
## and still none of them tagged.
static func dm_pit() -> ArenaMap:
	var map := ArenaMap.new()
	map.id = &"dm_pit"
	map.display_name = "dm_pit"
	map.extent = 14.0
	map.wall_height = 7.0

	# --- The catwalk -------------------------------------------------------
	#
	# A ring 3 m wide against all four walls, top face at 3.6. Four boxes rather than
	# a frame with a hole, for the reason every other map here gives: a hole is not a
	# box and everything downstream of this list understands only boxes.
	const RING_Y := 3.0
	const RING_T := 0.6
	const RING_IN := 11.0

	map.add_box(AABB(Vector3(-14.0, RING_Y, -14.0), Vector3(28.0, RING_T, 3.0)))
	map.add_box(AABB(Vector3(-14.0, RING_Y, RING_IN), Vector3(28.0, RING_T, 3.0)))
	map.add_box(AABB(Vector3(-14.0, RING_Y, -RING_IN), Vector3(3.0, RING_T, 22.0)))
	map.add_box(AABB(Vector3(RING_IN, RING_Y, -RING_IN), Vector3(3.0, RING_T, 22.0)))

	# The bridge, north to south through the middle at ring height. Flush with both
	# ends of the ring, so crossing it is a decision rather than a jump.
	map.add_box(AABB(Vector3(-1.0, RING_Y, -RING_IN), Vector3(2.0, RING_T, 22.0)))

	# And its east-west twin, added 2026-09-18, which turns the ring's one shortcut
	# into a crossing. With a single bridge the ring is a loop with a chord and the
	# whole of the high ground is one decision wide; with two, the middle of the map
	# is a junction four ways lead to and the island underneath is the only place on
	# it out of everybody's sight. The two overlap in the middle by construction —
	# overlapping boxes are fine here, and a hole cut between them would not be a box.
	map.add_box(AABB(Vector3(-RING_IN, RING_Y, -1.0), Vector3(22.0, RING_T, 2.0)))

	# --- The two stairs ----------------------------------------------------
	#
	# Ten treads of 0.36, which is under `DotFpsTunables.step_height` (0.4) and so is
	# walked rather than jumped. The number is `dm_atrium`'s, and it is 0.36 there
	# because 0.6 was measured and a bot holding forward stopped dead against the
	# first tread.
	#
	# The last tread's far face lands exactly on `RING_IN`. A stair that stops half a
	# metre short is a stair with a hole at the top of it, which reads as the player
	# falling through the map.
	for index in range(10):
		var rise := 0.36 * float(index + 1)

		# North-west, climbing west onto the west arm.
		map.add_box(AABB(
			Vector3(-2.0 - float(index + 1) * 0.9, 0.0, -10.5),
			Vector3(0.9, rise, 3.0)
		))

		# South-east, climbing east onto the east arm.
		map.add_box(AABB(
			Vector3(2.0 + float(index) * 0.9, 0.0, 7.5),
			Vector3(0.9, rise, 3.0)
		))

	# --- The north-east crates ---------------------------------------------
	#
	# [b]Rebuilt 2026-09-22 alongside dm_atrium's, and for the same reason.[/b] It was
	# 1.4 then 2.6 then the ring at 3.6, described in this file as "none of them over
	# 1.2 m" — which was true of the second and third step and not of the first, and
	# 1.2 would not have been climbable either. A jump's APEX here is 1.25, so the
	# first crate was 0.15 m above everything a player on the pit floor can reach and
	# the whole route started with a wall. The one route on this map that does not
	# announce itself was the one route nobody could take.
	#
	# Three crates at 0.9 now, and the ring is a fourth 0.9 off the top one. Every gap
	# is 0.5 m of clear air, and the last crate's north face is flush with the north
	# arm's inner edge so the step onto the ring has no gap at all.
	var pit_crates: Array[AABB] = [
		AABB(Vector3(5.0, 0.0, -5.0), Vector3(2.5, 0.9, 2.5)),
		AABB(Vector3(5.5, 0.0, -8.0), Vector3(2.5, 1.8, 2.5)),
		AABB(Vector3(6.0, 0.0, -11.0), Vector3(2.5, 2.7, 2.5)),
	]

	for box in pit_crates:
		map.add_box(box)

	map.add_climb("dm_pit: the pit floor onto the first crate", _floor_at(0.0), pit_crates[0])
	map.add_climb("dm_pit: crate 1 onto crate 2", pit_crates[0], pit_crates[1])
	map.add_climb("dm_pit: crate 2 onto crate 3", pit_crates[1], pit_crates[2])
	map.add_climb(
		"dm_pit: the top crate onto the north arm",
		pit_crates[2],
		AABB(Vector3(-14.0, RING_Y, -14.0), Vector3(28.0, RING_T, 3.0))
	)

	# --- Cover in the pit --------------------------------------------------
	#
	# A low island in the middle, under the bridge with 2.2 m of headroom, and three
	# waist-high pillars. Three and not four: the fourth corner is where the crates
	# are, and a pillar there would grow through the first of them.
	#
	# [b]At ±5.75, not ±6.[/b] At 6 the pillars beside the two stairs stood 0.75 m off
	# the stairs' sides — a pinch 0.9 m long and narrower than a player, between two
	# things a player runs along. `[gate-sweep-1]`'s slot rule found both (2026-09-24);
	# a quarter of a metre toward the middle makes each a metre.
	map.add_box(AABB(Vector3(-2.5, 0.0, -2.5), Vector3(5.0, 0.8, 5.0)))

	for corner in [Vector2(-5.75, -5.75), Vector2(-5.75, 5.75), Vector2(5.75, 5.75)]:
		map.add_box(AABB(
			Vector3(corner.x - 0.75, 0.0, corner.y - 0.75), Vector3(1.5, 2.2, 1.5)
		))

	# --- The south-west shelf and the perch --------------------------------
	#
	# A third tier, and the map's only one. The shelf is a 4 m block standing on the
	# pit floor, FLUSH with the inner edges of the west and south arms — x = -11 and
	# z = 11 — and that is the part worth stating rather than the height: set half a
	# metre clear of them instead, it would leave a 0.5 m slot between the block and
	# the catwalk, which is narrower than the 0.8 m a player is and is therefore a
	# gap nothing that plays this map can pass. See `[gate-sweep-1]`: the second
	# question a map has to answer is whether it contains a place its player cannot
	# get to, and a slot is how one appears without anybody drawing it.
	#
	# Two rises of 0.9 — ring 3.6 to shelf 4.5 to perch 5.4 — both under the 1.25 m
	# `arena_tunables()` jumps, so each is a hop rather than a route that needs the
	# crates. The perch sees the whole pit and every metre of the ring sees the
	# perch, which is the trade: it is the best view on the map and the worst place
	# to be found standing still.
	const SHELF_TOP := 4.5
	const PERCH_TOP := 5.4

	var shelf := AABB(Vector3(-11.0, 0.0, 7.0), Vector3(4.0, SHELF_TOP, 4.0))
	var perch := AABB(
		Vector3(-11.0, SHELF_TOP, 9.0), Vector3(2.0, PERCH_TOP - SHELF_TOP, 2.0)
	)

	map.add_box(shelf)
	map.add_box(perch)

	map.add_climb(
		"dm_pit: the west arm onto the shelf",
		AABB(Vector3(-14.0, RING_Y, -RING_IN), Vector3(3.0, RING_T, 22.0)),
		shelf
	)
	map.add_climb("dm_pit: the shelf onto the perch", shelf, perch)

	map.add_perimeter()

	# --- Spawns ------------------------------------------------------------
	#
	# Eight, five in the pit and three on the ring, and [b]every one of them
	# untagged[/b]. This is the property the map exists for: `_has_team_spawns` says
	# no, the catalogue records `teams: false`, and a team mode cannot be played here.
	# Do not tag them.
	var points: Array[Vector3] = [
		Vector3(-8.0, 0.1, 0.0),
		Vector3(8.0, 0.1, 2.0),
		Vector3(0.0, 0.1, 8.5),
		Vector3(-4.0, 0.1, -4.0),
		Vector3(4.5, 0.1, -2.0),
		Vector3(-12.5, 3.7, -6.0),
		Vector3(12.5, 3.7, 6.0),
		Vector3(0.0, 3.7, -12.5),
		# On the shelf. Nine now, and still not one of them tagged — the property
		# this map exists for survives anything added to it or it is not a property.
		Vector3(-8.5, 4.6, 8.5),
	]

	for at in points:
		var to_centre := Vector3(-at.x, 0.0, -at.z)

		if to_centre.length_squared() < 0.001:
			to_centre = Vector3.FORWARD

		map.add_spawn(
			Transform3D(Basis.looking_at(to_centre.normalized(), Vector3.UP), at)
		)

	return map


## Every map this game ships, by id.
##
## [b]A function rather than a constant array, because a map is 40-odd boxes and an
## array of them is 40-odd boxes built at load time for the one the server is not
## running.[/b] `ids()` is the cheap half — a menu, a `arena_maps` listing and a
## validity check all want the names and none of them want the geometry.
static func by_id(id: StringName) -> ArenaMap:
	match id:
		&"dm_box":
			return dm_box()
		&"dm_atrium":
			return dm_atrium()
		&"dm_pit":
			return dm_pit()

	return null


## The ids [method by_id] answers to, in rotation order.
##
## Kept beside `by_id` and not derived from it, which is the one duplication here worth
## having: a map added to one and not the other is a map that either cannot be listed or
## cannot be loaded, and `headless_match` checks the two agree.
static func ids() -> Array[StringName]:
	return [&"dm_box", &"dm_atrium", &"dm_pit"]


## Adds a spawn and its tag together, which is the only way to add one.
##
## An empty tag means "any team". Tagging SOME spawns and not others is legal and
## useful: the untagged ones are a shared pool both sides can fall back to when their
## own are all on cooldown, which `DotSpawnSelector._fallback` will do rather than
## refuse to spawn anybody.
func add_spawn(at: Transform3D, tag: StringName = &"") -> ArenaMap:
	spawns.append(at)
	spawn_tags.append(String(tag))
	return self


## The tag of spawn [param index], or empty.
func spawn_tag(index: int) -> StringName:
	if index < 0 or index >= spawn_tags.size():
		return &""

	return StringName(spawn_tags[index])


func add_box(box: AABB) -> ArenaMap:
	boxes.append(box.abs())
	return self


## Adds the four outer walls.
##
## Solid boxes rather than planes, because everything downstream understands a box and
## only some of it understands a plane — and a map that is boxes all the way down is a
## map whose three representations cannot disagree.
func add_perimeter(thickness: float = 2.0) -> ArenaMap:
	var span := extent * 2.0 + thickness * 2.0

	add_box(AABB(
		Vector3(-extent - thickness, floor_y, -extent - thickness),
		Vector3(thickness, wall_height, span)
	))
	add_box(AABB(
		Vector3(extent, floor_y, -extent - thickness),
		Vector3(thickness, wall_height, span)
	))
	add_box(AABB(
		Vector3(-extent - thickness, floor_y, -extent - thickness),
		Vector3(span, wall_height, thickness)
	))
	add_box(AABB(
		Vector3(-extent - thickness, floor_y, extent),
		Vector3(span, wall_height, thickness)
	))

	return self


# --- The three representations ---------------------------------------------

## The movement backend for a headless server or a test.
func to_fps_body() -> DotFpsFlatBody:
	var body := DotFpsFlatBody.with_floor(floor_y)

	for box in boxes:
		body.add_box(box)

	return body


## The shot-tracing backend for a headless server or a test.
func to_trace() -> DotTraceFlat:
	var trace := DotTraceFlat.with_floor(floor_y)

	for box in boxes:
		trace.add_box(box)

	return trace


## The visible and collidable level, for a client or a listen server.
##
## Returns a [Node3D] holding one [StaticBody3D] per box plus a floor. Built rather
## than loaded from a scene so that the geometry cannot drift from
## [method to_fps_body] and [method to_trace] — which is the whole point of the class.
func to_scene() -> Node3D:
	var root := Node3D.new()
	root.name = "Level"

	var material := dev_material()

	root.add_child(_make_box(
		AABB(
			Vector3(-extent - 2.0, floor_y - 1.0, -extent - 2.0),
			Vector3(extent * 2.0 + 4.0, 1.0, extent * 2.0 + 4.0)
		),
		material,
		"Floor"
	))

	for index in range(boxes.size()):
		root.add_child(_make_box(boxes[index], material, "Box%02d" % index))

	return root


## The level as collision only: static bodies, no meshes, no material.
##
## [b]This exists for one reason, and it is dot-props.[/b] Everything else in this game
## is analytic — the player's movement, the shot tracing, the navigation — precisely so
## a headless server needs no physics space. A physics prop is the exception: a rigid
## body has to have something to land on, and on a dedicated server nothing has ever
## instantiated the level, because there is nothing to draw it to.
##
## So this is [method to_scene] with the meshes left out. Same boxes, same list, same
## invariant — a fourth representation generated from the one description rather than a
## fifth one written by hand.
##
## [b]A client should NOT add this as well as [method to_scene].[/b] Two sets of static
## bodies in one space is every prop resting on whichever the solver reached first, and
## a shot that stops at a wall the player can walk through. [ArenaProps] builds one or
## the other, never both.
func to_collision() -> Node3D:
	var root := Node3D.new()
	root.name = "Collision"

	root.add_child(_make_box(
		AABB(
			Vector3(-extent - 2.0, floor_y - 1.0, -extent - 2.0),
			Vector3(extent * 2.0 + 4.0, 1.0, extent * 2.0 + 4.0)
		),
		null,
		"Floor"
	))

	for index in range(boxes.size()):
		root.add_child(_make_box(boxes[index], null, "Box%02d" % index))

	return root


## One box as a static body, with a mesh when there is a material to draw it with.
##
## A null material means collision only. Not a separate function, because two functions
## that each build a box out of one [AABB] is two descriptions of a box — which is the
## exact drift this class exists to prevent, one level down.
static func _make_box(box: AABB, material: Material, node_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = box.position + box.size * 0.5

	if material != null:
		var mesh := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = box.size
		mesh.mesh = box_mesh
		mesh.material_override = material
		body.add_child(mesh)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	body.add_child(shape)

	return body


# --- Dev texture -----------------------------------------------------------

## A grid texture, generated rather than shipped.
##
## No art assets anywhere in this repository. A generated grid is what a dev-textured
## game wants anyway: it makes distance and scale readable, which is the entire
## function a dev texture performs.
static func dev_texture(
	size: int = 128,
	line_every: int = 32,
	base: Color = Color(0.32, 0.34, 0.38),
	line: Color = Color(0.20, 0.21, 0.24)
) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	image.fill(base)

	for x in range(size):
		for y in range(size):
			if x % line_every == 0 or y % line_every == 0:
				image.set_pixel(x, y, line)
			elif (x % line_every == 1) or (y % line_every == 1):
				image.set_pixel(x, y, line.lerp(base, 0.5))

	return ImageTexture.create_from_image(image)


## A material that tiles the grid by world size rather than by UV.
##
## Triplanar, because a [BoxMesh] UV-maps every face to the same 0..1 square: without
## it a two-metre box and a forty-metre wall show the same number of grid squares, and
## the texture stops telling you anything about scale — which is the only job it has.
static func dev_material(tint: Color = Color.WHITE) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = dev_texture()
	material.albedo_color = tint
	material.uv1_triplanar = true
	material.uv1_scale = Vector3(0.5, 0.5, 0.5)
	material.roughness = 0.9
	material.metallic = 0.0
	return material


func describe() -> Dictionary:
	return {
		"name": display_name,
		"boxes": boxes.size(),
		"spawns": spawns.size(),
		"tagged_spawns": spawn_tags.size() - Array(spawn_tags).count(""),
		"extent": extent,
	}
