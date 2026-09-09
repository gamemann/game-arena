class_name ArenaMap
extends RefCounted

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

var display_name: String = "dm_box"


## The shipped arena: a square room, a raised centre, four pillars, two ledges.
##
## Symmetric on purpose. A symmetric map makes every spawn point score identically for
## the spawn selector, which is exactly the tie its name-based tie-break exists for —
## so the map that ships is also the map that exercises it.
static func dm_box() -> ArenaMap:
	var map := ArenaMap.new()
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
	for index in range(8):
		var angle := TAU * float(index) / 8.0
		var at := Vector3(cos(angle) * 18.0, 0.1, sin(angle) * 18.0)
		map.spawns.append(
			Transform3D(Basis.looking_at(-at.normalized(), Vector3.UP), at)
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
## roof without leaving the yard.
static func dm_atrium() -> ArenaMap:
	var map := ArenaMap.new()
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
	# Three walls at 2.5, open to the west. The only ground-level cover from the ring.
	map.add_box(AABB(Vector3(-24.0, 0.0, 8.0), Vector3(12.0, 2.5, 1.2)))
	map.add_box(AABB(Vector3(-24.0, 0.0, 19.0), Vector3(12.0, 2.5, 1.2)))
	map.add_box(AABB(Vector3(-13.2, 0.0, 8.0), Vector3(1.2, 2.5, 12.2)))

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

		map.spawns.append(
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

	return null


## The ids [method by_id] answers to, in rotation order.
##
## Kept beside `by_id` and not derived from it, which is the one duplication here worth
## having: a map added to one and not the other is a map that either cannot be listed or
## cannot be loaded, and `headless_match` checks the two agree.
static func ids() -> Array[StringName]:
	return [&"dm_box", &"dm_atrium"]


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


static func _make_box(box: AABB, material: Material, node_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = box.position + box.size * 0.5

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
		"extent": extent,
	}
