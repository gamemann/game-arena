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


## The shipped arena: a square room, a raised centre, four pillars, two ledges.
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
	for corner in [Vector2(-12.0, -4.0), Vector2(12.0, 4.0), Vector2(-4.0, 12.0), Vector2(4.0, -12.0)]:
		map.add_box(AABB(
			Vector3(corner.x - 1.5, 0.0, corner.y - 1.5), Vector3(3.0, 5.0, 3.0)
		))

	# Two ledges along opposite walls, reachable from the pillars.
	map.add_box(AABB(Vector3(-map.extent, 3.0, -18.0), Vector3(6.0, 0.6, 36.0)))
	map.add_box(AABB(Vector3(map.extent - 6.0, 3.0, -18.0), Vector3(6.0, 0.6, 36.0)))

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
## - [b]the south-east crates[/b], three jumps, faster, and it leaves you on the far
##   side from the stair;
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
	map.add_box(AABB(Vector3(-10.0, WALL_H, -10.0), Vector3(20.0, 0.6, 4.0)))
	map.add_box(AABB(Vector3(-10.0, WALL_H, 6.0), Vector3(20.0, 0.6, 4.0)))
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
	for index in range(13):
		map.add_box(AABB(
			Vector3(-20.5 + float(index) * 0.75, 0.0, -4.0),
			Vector3(0.75, 0.36 * float(index + 1), 4.0)
		))

	# --- South-east crates -------------------------------------------------
	#
	# 1.5, 3.0, 4.6 — the last flush with the roof ring's top face. Three jumps instead
	# of eight steps, and it puts you on the opposite corner from whoever took the
	# stair.
	map.add_box(AABB(Vector3(14.0, 0.0, 12.0), Vector3(3.5, 1.5, 3.5)))
	map.add_box(AABB(Vector3(13.0, 0.0, 7.0), Vector3(3.5, 3.0, 3.5)))
	map.add_box(AABB(Vector3(10.0, 0.0, 4.0), Vector3(3.5, 4.6, 3.5)))

	# --- North-east perch --------------------------------------------------
	#
	# Only from the roof, and only by jumping: 4.6 -> 5.3 -> 6.0 -> 6.7. Nothing on the
	# ground reaches it, which is what stops it being the place everyone stands.
	map.add_box(AABB(Vector3(11.0, 0.0, -9.0), Vector3(2.5, 5.3, 3.0)))
	map.add_box(AABB(Vector3(13.5, 0.0, -9.0), Vector3(2.5, 6.0, 3.0)))
	map.add_box(AABB(Vector3(16.0, 0.0, -12.0), Vector3(5.0, 6.7, 8.0)))

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
	# - [b]the east end[/b], a step across and down onto the second south-east crate,
	#   which joins the arcade to the existing three-jump route to the ring;
	# - [b]down[/b], anywhere, which is what stops the roof being a place to camp.
	const ARC_X := -13.2
	const ARC_W := 25.2
	const ARC_Z := 13.0
	const ARC_D := 5.0
	const ARC_Y := 3.0
	const ARC_T := 0.6
	const PIER := 1.5

	map.add_box(AABB(Vector3(ARC_X, ARC_Y, ARC_Z), Vector3(ARC_W, ARC_T, ARC_D)))

	# Five piers on each long edge. 3.9 m of daylight between them, which is wider than
	# the building's doorways -- the arcade is meant to be shot into, and a colonnade
	# you cannot see through is the tunnel this is not.
	for index in range(5):
		var pier_x := -11.0 + float(index) * 5.375

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
## - [b]the north-east crates[/b], two jumps and a third onto the ring, which is the
##   fast way and the only one that does not announce itself.
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
	# 1.4, then 2.6, then the ring at 3.6. Two jumps and a hop, none of them over
	# 1.2 m, and the last one crosses a 0.5 m gap onto the north arm.
	map.add_box(AABB(Vector3(6.0, 0.0, -6.5), Vector3(2.5, 1.4, 2.5)))
	map.add_box(AABB(Vector3(8.0, 0.0, -10.5), Vector3(2.5, 2.6, 2.5)))

	# --- Cover in the pit --------------------------------------------------
	#
	# A low island in the middle, under the bridge with 2.2 m of headroom, and three
	# waist-high pillars. Three and not four: the fourth corner is where the crates
	# are, and a pillar there would grow through the first of them.
	map.add_box(AABB(Vector3(-2.5, 0.0, -2.5), Vector3(5.0, 0.8, 5.0)))

	for corner in [Vector2(-6.0, -6.0), Vector2(-6.0, 6.0), Vector2(6.0, 6.0)]:
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

	map.add_box(AABB(Vector3(-11.0, 0.0, 7.0), Vector3(4.0, SHELF_TOP, 4.0)))
	map.add_box(AABB(
		Vector3(-11.0, SHELF_TOP, 9.0), Vector3(2.0, PERCH_TOP - SHELF_TOP, 2.0)
	))

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
