extends DotFpsFlatBody

## [DotFpsFlatBody] with one answer corrected: which way out of a box a player is pushed.
##
## [b]`DotFpsFlatBody.rest_contact` pushes a player out of a box along the axis it is
## DEEPEST in, where its own comment says the smallest.[/b] It compares each axis's
## separating depth against the running `deepest` across every box, so within one box the
## largest axis wins. A player six millimetres into the north wall of `dm_atrium` — a
## 64 m slab — is "deepest" along x, by tens of metres, and is moved along the wall a
## step (0.4 m) a tick, every tick, instead of six millimetres out of it.
##
## Nothing in a server's own simulation reaches it, because a swept motor never ends a
## tick inside a box. A CLIENT does: reconciling puts its player on the server's position
## as the wire carries it, quantised to the network's step, and a player standing flush
## against a wall can be quantised a few millimetres into it. Found by widening
## `ArenaGame.NET_WORLD_EXTENT` for the imported maps: the step moved, one flush position
## in `headless_net` rounded inward instead of outward, and the client's predicted player
## slid 2.8 m along the wall during a launch the server made straight up. Under the old
## extent the same thing was a coin toss at any other wall.
##
## Fixed here rather than only in the addon because the addon is in the client SHELL and a
## fix there reaches a browser only with a shell rebuild, while this travels in the game's
## own pack. The addon wants the same fix (reported on the queue); when the shell carries
## it, this file can go and `ArenaMap.to_fps_body` goes back to `DotFpsFlatBody`.


## The smallest push out of each box, and the deepest of those over everything touched.
func rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	var best := Hit.miss()
	var deepest := 0.0

	if floor_y > -INF:
		var depth := floor_y - (at.y - height * 0.5)

		if depth > deepest:
			deepest = depth
			best = _rest_hit(Vector3.UP, depth, FLOOR_ID)

	for i in range(planes.size()):
		var plane := planes[i]
		var support := DotFpsBody.capsule_support(plane.normal, height, radius)
		var depth := support - (plane.normal.dot(at) - plane.d)

		if depth > deepest:
			deepest = depth
			best = _rest_hit(plane.normal, depth, plane_id(i))

	var bounds := _bounds(at, height, radius)

	for i in range(boxes.size()):
		var box := boxes[i]

		if not bounds.intersects(box):
			continue

		# Within ONE box, the axis that separates them soonest: anything larger moves the
		# player further than the overlap, and through whatever is on the far side.
		var least := INF
		var normal := Vector3.ZERO

		for axis in range(3):
			var out_positive := box.position[axis] + box.size[axis] - bounds.position[axis]
			var out_negative := bounds.position[axis] + bounds.size[axis] - box.position[axis]
			var depth := minf(out_positive, out_negative)

			if depth > 0.0 and depth < least:
				least = depth
				normal = Vector3.ZERO
				normal[axis] = 1.0 if out_positive < out_negative else -1.0

		# Across boxes, the deepest of those: the one that most needs resolving first.
		if least < INF and least > deepest:
			deepest = least
			best = _rest_hit(normal, least, box_id(i))

	return best
