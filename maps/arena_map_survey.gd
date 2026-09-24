extends RefCounted

const ArenaMap := preload("arena_map.gd")

## The two questions every map here has to answer, asked of its box list as a RULE.
##
## [b]Can a player pass every gap that looks like a way through, and is there floor a
## player cannot reach at all?[/b] Both are `[gate-sweep-1]`, and both have been asked
## of this game's maps one gap at a time — dm_pit's shelf is flush with the ring
## because somebody thought about that one slot. This asks it of every pair of boxes
## and every square metre of every map, so the next slot nobody thought about is found
## by the rule rather than by a person.
##
## [b]Content, not a check.[/b] It measures and returns numbers; `headless_match` is
## where they are asserted, because a map is content and content does not assert —
## the same division [member ArenaMap.climbs] keeps.
##
## - [method slots] is analytic: two boxes whose facing sides are closer than a player
##   is wide, beside the same floor, with nothing filling the space between.
## - [method reach] is a flood fill on a grid: every surface a player can stand on
##   (floor or box top, with a player's hull of clear air above it), joined by what the
##   movement does — walking up anything under [constant ArenaMap.STEP_HEIGHT], falling
##   off anything, and jumping onto anything under [method ArenaMap.climb_limit] within
##   [method ArenaMap.jump_reach] along an arc that does not pass through a box.

# No `CHANNEL`: this measures and returns, and says nothing to an operator. The suite
# that asserts on it is the one with something to say.

## Metres. The width this family sizes gaps against: `headless_match`'s spawn column,
## and the "0.8 m a player is" dm_pit's shelf comment is written in. The motor's own
## hull is narrower — `DotFpsTunables.radius` 0.35, a 0.7 m box — so a slot between
## the two numbers is one the motor passes and a player cannot see is passable; the
## survey calls those slots too, which is the conservative side to be wrong on.
const PLAYER_WIDTH := 0.8

## Metres. `DotFpsTunables.crouch_height`. The lowest a player can be, so the lowest
## headroom a surface needs before somebody can be ON it at all.
const CROUCH_HEIGHT := 0.9

## Metres. Grid spacing for the flood fill. A corridor is found passable whenever it
## is at least [constant PLAYER_WIDTH] plus one cell wide, so this is also the width
## band [method slots] reports as tight rather than closed.
const CELL := 0.25

## Just under half a player, so a slot exactly [constant PLAYER_WIDTH] wide is passable,
## as the motor's own strict overlap test makes it.
const _HALF := 0.395

const _EPS := 0.001


## Every gap between two boxes narrower than a player that looks like a way through.
##
## Returns an Array of Dictionaries: `a`, `b` (box indices), `axis` ("x" or "z"),
## `gap`, `length` (how long the two faces run side by side), `floor` (the height the
## slot is walked at), and `closed` (true under [constant PLAYER_WIDTH], false for the
## tight-but-passable band up to one grid cell wider).
##
## [b]"Looks like a way through" is three conditions, and each removes a real false
## alarm.[/b] The two faces must run side by side for at least a player's width — two
## boxes meeting at a corner are not a corridor. Both must stand at least a step above
## the floor between them and reach down to within a crouch of it — a gantry passing
## three metres over a pillar's shoulder is not a slot anybody walks. And the space
## between must be empty — dm_pit's shelf is flush with the ring precisely so that it
## is, and a box filling the gap is the fix rather than the fault.
static func slots(map: ArenaMap) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var boxes := map.boxes

	for i in range(boxes.size()):
		for j in range(i + 1, boxes.size()):
			var a: AABB = boxes[i]
			var b: AABB = boxes[j]

			for axis in [0, 2]:
				var other := 2 if axis == 0 else 0
				var gap := _clear_between(a.position[axis], a.end[axis], b.position[axis], b.end[axis])

				if gap <= _EPS or gap >= PLAYER_WIDTH + CELL:
					continue

				var lo := maxf(a.position[other], b.position[other])
				var hi := minf(a.end[other], b.end[other])

				if hi - lo < PLAYER_WIDTH:
					continue

				# The slot's own footprint, and the floor inside it: the highest top
				# face under both boxes' tops that covers its middle.
				var near_a := a.end[axis] if a.end[axis] <= b.position[axis] + _EPS else a.position[axis]
				var near_b := b.position[axis] if a.end[axis] <= b.position[axis] + _EPS else b.end[axis]
				var mid_axis := (near_a + near_b) * 0.5
				var mid_other := (lo + hi) * 0.5
				var ceiling := minf(a.end.y, b.end.y)
				var floor_y := _surface_under(map, axis, mid_axis, mid_other, ceiling)

				# Both sides have to be walls at that floor: rising more than a step
				# above it, and coming down to within a crouch of it.
				if a.end.y - floor_y <= ArenaMap.STEP_HEIGHT or b.end.y - floor_y <= ArenaMap.STEP_HEIGHT:
					continue

				if a.position.y >= floor_y + CROUCH_HEIGHT or b.position.y >= floor_y + CROUCH_HEIGHT:
					continue

				if _filled(map, axis, near_a, near_b, lo, hi, floor_y):
					continue

				# A gap the map declares as a jump is not a corridor, however much it
				# looks like one from the floor between the two crates.
				if _is_climb(map, a, b):
					continue

				found.append({
					"a": i,
					"b": j,
					"axis": "x" if axis == 0 else "z",
					"gap": gap,
					"length": hi - lo,
					"floor": floor_y,
					"closed": gap < PLAYER_WIDTH,
				})

	return found


## Where on a map a player can stand, and which of it they can get to.
##
## Returns a Dictionary:
## - `standable`: m² of floor and box top a crouching player fits on, inside the room;
## - `reached`: m² of that reachable from the spawns;
## - `unreached`: m² of it that is not, and `unreached_regions`, an Array of
##   `{height, area, from, to}` per connected patch of it, largest first;
## - `trapped`: m² reachable from a spawn with no way back to one — a pit you can fall
##   into and not climb out of — and `trapped_regions` in the same shape;
## - `spawns_reached`: how many spawns are on reached ground (all of them, or the
##   flood fill started somewhere it should not have).
static func reach(map: ArenaMap) -> Dictionary:
	var fill := _Fill.new(map)
	return fill.run()


## The unreached regions of a [method reach] result that no declared
## [member ArenaMap.out_of_reach] box accounts for: the ones nobody decided.
static func unexplained(map: ArenaMap, surveyed: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for region: Dictionary in surveyed["unreached_regions"]:
		var covered := false

		for box in map.out_of_reach:
			var from: Vector2 = region["from"]
			var to: Vector2 = region["to"]

			if (
				is_equal_approx(float(region["height"]), box.end.y)
				and from.x >= box.position.x and to.x <= box.end.x
				and from.y >= box.position.z and to.y <= box.end.z
			):
				covered = true
				break

		if not covered:
			out.append(region)

	return out


static func _is_climb(map: ArenaMap, a: AABB, b: AABB) -> bool:
	for climb in map.climbs:
		if (
			(climb.from_box.is_equal_approx(a) and climb.to_box.is_equal_approx(b))
			or (climb.from_box.is_equal_approx(b) and climb.to_box.is_equal_approx(a))
		):
			return true

	return false


static func _clear_between(a_min: float, a_max: float, b_min: float, b_max: float) -> float:
	if b_min >= a_max:
		return b_min - a_max

	if a_min >= b_max:
		return a_min - b_max

	return 0.0


## The highest top face at or under [param ceiling] covering one point, or the floor.
static func _surface_under(map: ArenaMap, axis: int, at_axis: float, at_other: float, ceiling: float) -> float:
	var x := at_axis if axis == 0 else at_other
	var z := at_other if axis == 0 else at_axis
	var best := map.floor_y

	for box in map.boxes:
		if x < box.position.x or x > box.end.x or z < box.position.z or z > box.end.z:
			continue

		if box.end.y <= ceiling - ArenaMap.STEP_HEIGHT and box.end.y > best:
			best = box.end.y

	return best


## Whether some box occupies the slot between two faces at the height it is walked.
static func _filled(
	map: ArenaMap, axis: int, near_a: float, near_b: float, lo: float, hi: float, floor_y: float
) -> bool:
	var a_min := minf(near_a, near_b)
	var a_max := maxf(near_a, near_b)
	var probe := AABB()

	if axis == 0:
		probe = AABB(
			Vector3(a_min + _EPS, floor_y + ArenaMap.STEP_HEIGHT, lo + _EPS),
			Vector3(a_max - a_min - 2.0 * _EPS, CROUCH_HEIGHT - ArenaMap.STEP_HEIGHT, hi - lo - 2.0 * _EPS)
		)
	else:
		probe = AABB(
			Vector3(lo + _EPS, floor_y + ArenaMap.STEP_HEIGHT, a_min + _EPS),
			Vector3(hi - lo - 2.0 * _EPS, CROUCH_HEIGHT - ArenaMap.STEP_HEIGHT, a_max - a_min - 2.0 * _EPS)
		)

	for box in map.boxes:
		if box.intersects(probe):
			return true

	return false


## The flood fill, as an object because it carries a dozen arrays between its steps.
class _Fill:
	extends RefCounted

	var map: ArenaMap
	var n := 0
	var origin := 0.0

	## Per cell: indices of the boxes whose footprint covers its centre, and of the
	## boxes within half a player of it.
	var cover: Array = []
	var near: Array = []

	## Per node: its cell and its height. Per cell: its nodes, lowest first.
	var node_cell := PackedInt32Array()
	var node_h := PackedFloat32Array()
	var cell_nodes: Array = []

	## Union-find over nodes a player walks between in both directions.
	var parent := PackedInt32Array()

	func _init(of_map: ArenaMap) -> void:
		map = of_map
		n = int(ceil(map.extent * 2.0 / CELL))
		origin = -map.extent

	func _centre(cell: int) -> Vector2:
		var c := CELL
		return Vector2(origin + (float(cell % n) + 0.5) * c, origin + (float(cell / n) + 0.5) * c)

	func run() -> Dictionary:
		_rasterise()
		_nodes()
		_walk()

		var comp := PackedInt32Array()
		comp.resize(node_h.size())

		for index in range(node_h.size()):
			comp[index] = _find(index)

		var edges := {}
		_drops(comp, edges)
		_jumps(comp, edges)

		# Spawn nodes: the standable surface under each spawn.
		var starts: Array[int] = []
		var spawns_on := 0

		for at in map.spawns:
			var node := _node_under(at.origin)

			if node >= 0:
				starts.append(comp[node])
				spawns_on += 1

		var forward := {}
		var backward := {}

		for key: int in edges:
			var from: int = key >> 20
			var to: int = key & 0xFFFFF
			if not forward.has(from):
				forward[from] = []
			if not backward.has(to):
				backward[to] = []
			forward[from].append(to)
			backward[to].append(from)

		var reached := _bfs(starts, forward)
		var returns := _bfs(starts, backward)

		var area := CELL * CELL
		var standable := 0
		var got := 0
		var lost := {}
		var trapped := {}

		for index in range(node_h.size()):
			standable += 1
			var c := comp[index]

			if reached.has(c):
				got += 1

				if not returns.has(c):
					_grow(trapped, c, index)
			else:
				_grow(lost, c, index)

		return {
			"standable": float(standable) * area,
			"reached": float(got) * area,
			"unreached": float(standable - got) * area,
			"unreached_regions": _regions(lost, area),
			"trapped": _sum(trapped) * area,
			"trapped_regions": _regions(trapped, area),
			"spawns_reached": _count_reached(starts, reached),
			"spawns": map.spawns.size(),
			"spawns_on_ground": spawns_on,
			"cells": n * n,
		}

	# --- Building the grid ---------------------------------------------------

	func _rasterise() -> void:
		cover.resize(n * n)
		near.resize(n * n)

		for cell in range(n * n):
			cover[cell] = []
			near[cell] = []

		var half := _HALF

		for index in range(map.boxes.size()):
			var box: AABB = map.boxes[index]
			_mark(cover, index, box.position.x, box.end.x, box.position.z, box.end.z)
			_mark(
				near, index,
				box.position.x - half, box.end.x + half,
				box.position.z - half, box.end.z + half
			)

	func _mark(into: Array, index: int, x0: float, x1: float, z0: float, z1: float) -> void:
		var c := CELL
		var i0 := maxi(0, int(ceil((x0 - origin) / c - 0.5 - 0.0001)))
		var i1 := mini(n - 1, int(floor((x1 - origin) / c - 0.5 + 0.0001)))
		var k0 := maxi(0, int(ceil((z0 - origin) / c - 0.5 - 0.0001)))
		var k1 := mini(n - 1, int(floor((z1 - origin) / c - 0.5 + 0.0001)))

		for k in range(k0, k1 + 1):
			for i in range(i0, i1 + 1):
				into[k * n + i].append(index)

	func _nodes() -> void:
		cell_nodes.resize(n * n)

		for cell in range(n * n):
			var heights: Array[float] = [map.floor_y]

			for index: int in cover[cell]:
				var top: float = map.boxes[index].end.y
				if top > map.floor_y + _EPS and not heights.has(top):
					heights.append(top)

			heights.sort()
			var mine: Array[int] = []

			for h in heights:
				if _clear(cell, h):
					mine.append(node_h.size())
					node_cell.append(cell)
					node_h.append(h)

			cell_nodes[cell] = mine

		parent.resize(node_h.size())

		for index in range(node_h.size()):
			parent[index] = index

	## Whether a crouching player fits at [param h] over this cell. Anything that
	## tops out within a step of the feet is walked onto rather than into, so only
	## solid between a step and a crouch above them is in the way.
	func _clear(cell: int, h: float) -> bool:
		for index: int in near[cell]:
			var box: AABB = map.boxes[index]

			if box.position.y < h + CROUCH_HEIGHT - _EPS and box.end.y > h + ArenaMap.STEP_HEIGHT + _EPS:
				return false

		return true

	# --- Joining it up -------------------------------------------------------

	func _find(x: int) -> int:
		while parent[x] != x:
			parent[x] = parent[parent[x]]
			x = parent[x]
		return x

	func _walk() -> void:
		for cell in range(n * n):
			var i := cell % n
			var k := cell / n

			for other in [cell + 1 if i + 1 < n else -1, cell + n if k + 1 < n else -1]:
				if other < 0:
					continue

				for a: int in cell_nodes[cell]:
					for b: int in cell_nodes[other]:
						if absf(node_h[a] - node_h[b]) <= ArenaMap.STEP_HEIGHT + _EPS:
							var ra := _find(a)
							var rb := _find(b)
							if ra != rb:
								parent[ra] = rb

	## Walking off an edge: from a node into the neighbouring column at the same
	## height, landing on the highest surface there that is more than a step lower.
	func _drops(comp: PackedInt32Array, edges: Dictionary) -> void:
		for cell in range(n * n):
			var i := cell % n
			var k := cell / n
			var around := []

			if i > 0: around.append(cell - 1)
			if i + 1 < n: around.append(cell + 1)
			if k > 0: around.append(cell - n)
			if k + 1 < n: around.append(cell + n)

			for a: int in cell_nodes[cell]:
				var ha := node_h[a]

				for other: int in around:
					if not _clear(other, ha):
						continue

					var landing := -1

					for b: int in cell_nodes[other]:
						if node_h[b] < ha - ArenaMap.STEP_HEIGHT - _EPS:
							landing = b

					if landing >= 0 and comp[a] != comp[landing]:
						edges[(comp[a] << 20) | comp[landing]] = true

	## Jumps, from and to nodes on the edge of their walk component.
	##
	## [b]Edges only, and that is what makes this affordable.[/b] A jump from the
	## middle of a platform is a walk to its edge and a jump from there, and the
	## landing is reached at its near edge first — so the interior of every component
	## is a question already answered.
	func _jumps(comp: PackedInt32Array, edges: Dictionary) -> void:
		var edge_nodes: Array[int] = []

		for cell in range(n * n):
			var i := cell % n
			var k := cell / n

			for a: int in cell_nodes[cell]:
				var inner := true

				for other in [cell - 1 if i > 0 else -1, cell + 1 if i + 1 < n else -1,
						cell - n if k > 0 else -1, cell + n if k + 1 < n else -1]:
					if other < 0:
						inner = false
						break

					var joined := false
					for b: int in cell_nodes[other]:
						if comp[b] == comp[a]:
							joined = true
							break

					if not joined:
						inner = false
						break

				if not inner:
					edge_nodes.append(a)

		# Buckets of 1 m, so a jump looks only at what is near it.
		var bucket := {}
		var c := CELL
		var per := int(round(1.0 / c))

		for a in edge_nodes:
			var cell := node_cell[a]
			var key := Vector2i((cell % n) / per, (cell / n) / per)
			if not bucket.has(key):
				bucket[key] = []
			bucket[key].append(a)

		var reach_cap := ArenaMap.jump_reach(-2.0)
		var span := int(ceil(reach_cap))
		var limit := ArenaMap.climb_limit()

		for a in edge_nodes:
			var cell_a := node_cell[a]
			var ha := node_h[a]
			var pa := _centre(cell_a)
			var ca := comp[a]
			var ka := Vector2i((cell_a % n) / per, (cell_a / n) / per)

			for dz in range(-span, span + 1):
				for dx in range(-span, span + 1):
					var key := Vector2i(ka.x + dx, ka.y + dz)
					if not bucket.has(key):
						continue

					for b: int in bucket[key]:
						var cb := comp[b]
						if cb == ca:
							continue

						var rise := node_h[b] - ha
						if rise > limit:
							continue

						var edge_key := (ca << 20) | cb
						if edges.has(edge_key):
							continue

						var pb := _centre(node_cell[b])
						var d := pa.distance_to(pb)

						if d > ArenaMap.jump_reach(maxf(rise, -2.0)):
							continue

						if _arc_clear(pa, ha, pb, node_h[b], d):
							edges[edge_key] = true

	## Whether a jump from one surface to another passes through nothing.
	##
	## Drawn at the horizontal speed that lands exactly on the far point, capped at
	## [constant ArenaMap.MOVE_SPEED] — a short hop is a slow one, and drawing it at
	## full speed would put its apex past the landing and call a crate against a wall
	## unreachable because the arc went through the wall.
	func _arc_clear(pa: Vector2, ha: float, pb: Vector2, hb: float, d: float) -> bool:
		var g := ArenaMap.MOVE_GRAVITY
		var v0 := sqrt(2.0 * g * ArenaMap.JUMP_HEIGHT)
		var under := v0 * v0 - 2.0 * g * (hb - ha)
		if under < 0.0:
			return false

		var t_land := (v0 + sqrt(under)) / g
		var speed := minf(ArenaMap.MOVE_SPEED, d / maxf(t_land, 0.001))
		var steps := maxi(2, int(ceil(d / 0.2)))

		for s in range(1, steps):
			var f := float(s) / float(steps)
			var p := pa.lerp(pb, f)
			var t := (d * f) / maxf(speed, 0.001)
			var y := ha + v0 * t - 0.5 * g * t * t

			for box in map.boxes:
				if p.x <= box.position.x or p.x >= box.end.x or p.y <= box.position.z or p.y >= box.end.z:
					continue

				if box.position.y < y + CROUCH_HEIGHT and box.end.y > y + _EPS:
					return false

		return true

	# --- Reading it back ------------------------------------------------------

	func _node_under(at: Vector3) -> int:
		var c := CELL
		var i := clampi(int(floor((at.x - origin) / c)), 0, n - 1)
		var k := clampi(int(floor((at.z - origin) / c)), 0, n - 1)
		var best := -1

		for node: int in cell_nodes[k * n + i]:
			if node_h[node] <= at.y + 0.2:
				best = node

		return best

	func _bfs(starts: Array[int], graph: Dictionary) -> Dictionary:
		var seen := {}
		var queue: Array[int] = []

		for s in starts:
			if not seen.has(s):
				seen[s] = true
				queue.append(s)

		var head := 0

		while head < queue.size():
			var at := queue[head]
			head += 1

			for to: int in graph.get(at, []):
				if not seen.has(to):
					seen[to] = true
					queue.append(to)

		return seen

	func _grow(into: Dictionary, c: int, node: int) -> void:
		var p := _centre(node_cell[node])
		var h := node_h[node]

		if not into.has(c):
			into[c] = {"height": h, "count": 0, "from": p, "to": p}

		var r: Dictionary = into[c]
		r["count"] += 1
		r["from"] = Vector2(minf(r["from"].x, p.x), minf(r["from"].y, p.y))
		r["to"] = Vector2(maxf(r["to"].x, p.x), maxf(r["to"].y, p.y))

	func _sum(regions: Dictionary) -> float:
		var total := 0.0
		for c: int in regions:
			total += float(regions[c]["count"])
		return total

	func _regions(regions: Dictionary, area: float) -> Array[Dictionary]:
		var out: Array[Dictionary] = []

		for c: int in regions:
			var r: Dictionary = regions[c]
			out.append({
				"height": r["height"],
				"area": float(r["count"]) * area,
				"from": r["from"],
				"to": r["to"],
			})

		out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["area"] > y["area"])
		return out

	func _count_reached(starts: Array[int], reached: Dictionary) -> int:
		var count := 0
		for s in starts:
			if reached.has(s):
				count += 1
		return count
