extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")

## The combat surf maps game-g2gfast imported, played as an arena deathmatch.
##
## [codeblock]
## godot --headless --path . res://examples/headless_imported.tscn
## [/codeblock]
##
## [b]Every other suite here plays a list of boxes, and an imported map is not one.[/b] Its
## movement and its shots are physics queries against a few thousand convex brushes that
## the game puts in the tree on every machine, its spawns are the mapper's, its pits are
## teleports, and its air control is the genre's. Not one of those is reachable from
## `headless_match`, which is why this file exists: a map that loads and that nobody can
## stand on passes every check written for the built-ins.
##
## What it asserts, on [constant MAP] (the first map in the default rotation):
##
## - the map is found by its manifest's kind and catalogued, in or out of the rotation;
## - the game loads it with its solid in the tree and the physics backends bound to it;
## - every player appears on one of the map's OWN spawn points, standing on its floor;
## - a deathmatch is played on it for [constant PLAY_SECONDS] seconds and nobody falls
##   through, leaves the map or ends up inside a brush, and kills are scored until the
##   score limit ends the round;
## - the surf air control is on there, back off on a built-in map, and back on again;
## - a pit sends a player where it aims, and the floor under the map catches anybody past it;
## - and, as a sweep, every combat surf map found builds and puts its spawns on a floor.
##
## [b]Skips, loudly, when the maps are not linked[/b] — a checkout without g2gfast-maps
## plays the built-ins only, which is a supported state (dot-ci has no link). It is allowed
## to skip; it is not allowed to pass: the exit code is 0 and the line says why.

const TICK_RATE := 64
const BOTS := 6

## The map the deathmatch is played on: the first of Christian's two.
const MAP := &"surf_10x_reloaded_fixed"

const PLAY_SECONDS := 40.0

## A score limit small enough that six bots reach it inside [constant PLAY_SECONDS].
const SCORE_LIMIT := 4

const SECTIONS := 9
const CHECKS := 41

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0

var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	_line("arena — imported combat surf maps")
	_line("")

	if ArenaMap.imported_ids().is_empty():
		_line("no imported maps under %s — nothing to check" % ArenaImportedMaps.roots()[0])
		_line("  link g2gfast-maps: dot-bootstrap/bootstrap.sh --links game-arena")
		get_tree().quit(0)
		return

	_test_catalogue()

	if not await _test_loads():
		_finish()
		return

	await _test_spawns_on_the_floor()
	await _test_deathmatch()
	_test_surf_movement()
	_test_ramp()
	_test_pits()
	_test_shots()
	await _test_every_map()

	_finish()


func _finish() -> void:
	_line("")
	_line("%d sections, %d passed, %d failed" % [_completed, _passed, _failed])

	if _entered != SECTIONS or _completed != SECTIONS:
		_line("ERROR: %d sections entered and %d completed, %d expected." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- The catalogue ---------------------------------------------------------

func _test_catalogue() -> void:
	_section("found by its manifest, catalogued, and in the rotation by name")

	var ids := ArenaMap.imported_ids()
	_check(ids.has(MAP), "%s is found (%d combat surf maps: %s)" % [MAP, ids.size(), ids])

	var not_arena: Array[String] = []

	for id in ids:
		if str(ArenaImportedMaps.manifest(id).get("kind", "")) != "arena":
			not_arena.append(String(id))

	_check(not_arena.is_empty(),
		"and every map found says \"kind\": \"arena\" itself (%s do not)" % [not_arena])

	_check(ArenaMap.by_id(MAP) != null and ArenaMap.by_id(MAP).is_imported(),
		"ArenaMap.by_id builds it, as an imported map")

	ArenaMaps.imported_rotation = ArenaMaps.IMPORTED_ROTATION_DEFAULT
	var catalogue := ArenaMaps.catalogue()
	var def := catalogue.get_map(MAP)
	_check(def != null and bool(def.meta.get("imported", false)),
		"the catalogue carries it, marked imported")
	_check(def != null and def.version.begins_with("0.0.0-") and def.version.length() == 18,
		"at a version hashed from its manifest (%s)" % (def.version if def != null else "?"))

	var on: Array[String] = []

	for map in catalogue.maps:
		if bool(map.meta.get("imported", false)) and map.enabled:
			on.append(String(map.id))

	on.sort()
	_check(on == ["surf_10x_reloaded_fixed", "surf_110b_austinpowers"],
		"the default rotation offers Christian's two and no other import (%s)" % [on])

	ArenaMaps.imported_rotation = "all"
	ArenaMaps.apply_rotation(catalogue)
	var all_on := catalogue.maps.filter(
		func(m: DotMapDef) -> bool: return bool(m.meta.get("imported", false)) and m.enabled
	).size()
	ArenaMaps.imported_rotation = "none"
	ArenaMaps.apply_rotation(catalogue)
	var none_on := catalogue.maps.filter(
		func(m: DotMapDef) -> bool: return bool(m.meta.get("imported", false)) and m.enabled
	).size()
	ArenaMaps.imported_rotation = ArenaMaps.IMPORTED_ROTATION_DEFAULT
	_check(all_on == ids.size() and none_on == 0,
		"and `all` / `none` change it on a running catalogue (%d / %d)" % [all_on, none_on])

	_check(
		ArenaMaps.supports_mode(def, ArenaModes.by_id(&"ffa"))
		and ArenaMaps.supports_mode(def, ArenaModes.by_id(&"gungame"))
		and not ArenaMaps.supports_mode(def, ArenaModes.by_id(&"siege"))
		and not ArenaMaps.supports_mode(def, ArenaModes.by_id(&"koth")),
		"it hosts the deathmatch modes and refuses the ones built out of boxes"
	)

	_done()


# --- Loading ---------------------------------------------------------------

func _test_loads() -> bool:
	_section("the game loads it, with its solid in the tree")

	_game = ArenaGame.new()
	_game.tick_rate = TICK_RATE
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	_game.mode = ArenaMode.free_for_all(SCORE_LIMIT)
	# The game's own export, which outranks the mode's when it is set (and is, by default).
	_game.score_limit = SCORE_LIMIT
	add_child(_game)

	var map := ArenaMap.by_id(MAP)
	var res := _game.setup(map)
	_check(res.ok, "setup succeeds%s" % ("" if res.ok else ": " + res.error.message))

	if not res.ok:
		_done()
		return false

	var manifest := ArenaImportedMaps.manifest(MAP)
	var info: Dictionary = manifest.get("collision", {})
	var expected := int(info.get("hull_count", 0)) + (
		1 if int(info.get("displacement_index_count", 0)) > 0 else 0
	)
	var solid := _game.map.collision_root
	_check(solid != null and solid.is_inside_tree() and solid.get_child_count() == expected,
		"one shape per brush is in the tree (%d of %d)" % [
			solid.get_child_count() if solid != null else -1, expected
		])
	_check(_game.combat.trace is DotTracePhysics,
		"the shots trace the physics space, not a box list")
	_check(_game.match_node.spawn_points().size() == _game.map.spawns.size()
		and _game.map.spawns.size() == (manifest.get("spawns", []) as Array).size(),
		"every spawn the mapper placed is a spawn point (%d)" % _game.map.spawns.size())

	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0

	for i in range(BOTS):
		var added := _game.add_player(i + 1, "bot%d" % (i + 1))

		if not added.ok:
			_check(false, "bot %d joined: %s" % [i + 1, added.error.message])
			_done()
			return false

	var first := _game.player_for(1)
	_check(first.controller.flat_body is DotFpsPhysicsBody
		and (first.controller.flat_body as DotFpsPhysicsBody).is_bound(),
		"a player moves against the physics space, bound before the first tick")

	_game.start(0)
	_done()
	return true


# --- Spawns ----------------------------------------------------------------

func _test_spawns_on_the_floor() -> void:
	_section("players appear on the map's own spawns, standing on its floor")

	await _ticks(TICK_RATE)

	var alive := 0
	var on_spawn := 0
	var grounded := 0
	var floored := 0
	var worst := 0.0

	for player in _game.players():
		if not player.is_alive():
			continue

		alive += 1
		var feet := player.controller.state.position
		var nearest := INF

		for at in _game.map.spawns:
			var flat := Vector2(at.origin.x - feet.x, at.origin.z - feet.z)
			nearest = minf(nearest, flat.length())

		worst = maxf(worst, nearest)

		if nearest < 0.5:
			on_spawn += 1

		if player.controller.state.is_grounded():
			grounded += 1

		var down := _game.combat.trace.ray(feet + Vector3.UP * 0.5, Vector3.DOWN, 1.0)

		if down.blocked:
			floored += 1

	_check(alive == BOTS, "every bot is alive a second in (%d of %d)" % [alive, BOTS])
	_check(on_spawn == alive,
		"each on one of the mapper's spawns (furthest %.2f m from one)" % worst)
	_check(grounded == alive, "grounded (%d of %d)" % [grounded, alive])
	_check(floored == alive, "with the map's floor under their feet (%d of %d)" % [floored, alive])

	_done()


# --- The deathmatch ----------------------------------------------------------

var _lowest := INF
var _out_of_bounds := 0
var _inside := 0
var _kills := 0
var _ended := false


func _test_deathmatch() -> void:
	_section("a deathmatch is played on it")

	# Into containers: a lambda captures a scalar by value, and a counter incremented in
	# one stays zero outside it (docs/gdscript-hazards.md).
	var kills: Array[int] = [0]
	var leader_at_end: Array[int] = [-1]
	_game.player_killed.connect(func(_entry: DotKillFeed.Entry) -> void: kills[0] += 1)
	_game.match_node.state_changed.connect(
		func(_from: Variant, to: Variant) -> void:
			# Read now, at the transition: the next match zeroes the scoreboard.
			if int(to) == DotMatch.State.MATCH_END and leader_at_end[0] < 0:
				var best := 0
				for record in _game.match_node.scoreboard.players():
					best = maxi(best, record.kills)
				leader_at_end[0] = best
	)

	var ticks := int(PLAY_SECONDS * TICK_RATE)
	var started := Time.get_ticks_msec()
	var grounded_samples := 0
	var samples := 0
	var bounds := _game.map.bounds.grow(1.0)
	var probe := DotFpsPhysicsBody.for_node(_game.map.collision_root)
	var tunables := ArenaPlayer.arena_tunables()

	for tick in range(ticks):
		_game.tick(_commands_for_tick(tick))

		if tick % 8 != 0:
			if tick % 64 == 0:
				await get_tree().physics_frame
			continue

		for player in _game.players():
			if not player.is_alive():
				continue

			var feet := player.controller.state.position
			samples += 1
			_lowest = minf(_lowest, feet.y)

			if not bounds.has_point(feet):
				_out_of_bounds += 1

			if player.controller.state.is_grounded():
				grounded_samples += 1

			# Inside a brush: the hull, a few centimetres up off the floor it rests on,
			# overlaps solid. Up, because a hull resting on a floor touches it.
			if _in_solid(probe, feet, tunables):
				_inside += 1
				_line("     DEBUG inside at %s v %s grounded %s tick %d" % [feet, player.controller.state.velocity, player.controller.state.is_grounded(), tick])

		if leader_at_end[0] >= 0:
			break

	_kills = kills[0]
	_ended = leader_at_end[0] >= 0
	var took := Time.get_ticks_msec() - started
	_line("     %d samples, %d grounded, lowest feet %.1f m (the map's floor is %.1f), %d kills, %.1f s for %.0f s of play" % [
		samples, grounded_samples, _lowest, _game.map.bounds.position.y, _kills,
		took / 1000.0, PLAY_SECONDS
	])

	_check(samples > 0 and grounded_samples > samples / 4,
		"players stand on the map most of the time (%d of %d samples grounded)" % [grounded_samples, samples])
	_check(_out_of_bounds == 0, "nobody leaves the map's bounds (%d samples outside)" % _out_of_bounds)
	_check(_lowest > _game.map.bounds.position.y - 1.0,
		"nobody falls through the floor (lowest %.1f m)" % _lowest)
	_check(_inside == 0, "nobody ends up inside a brush (%d samples)" % _inside)
	_check(_kills > 0, "players kill each other (%d)" % _kills)
	_check(_ended, "and the score limit (%d) ends the round" % SCORE_LIMIT)

	_check(leader_at_end[0] >= SCORE_LIMIT,
		"won on frags: the leader had %d at the end" % leader_at_end[0])

	_done()


## The bots: walk at the nearest opponent's bearing, aim at them and hold the trigger.
## `headless_match`'s fixture, with a strafe so they move.
func _commands_for_tick(tick: int) -> Dictionary:
	var commands := {}

	for player in _game.players():
		if not player.is_alive():
			continue

		var target: ArenaPlayer = null
		var best := INF

		for other in _game.players():
			if other == player or not other.is_alive():
				continue

			var d := player.muzzle_position().distance_to(other.muzzle_position())

			if d < best:
				best = d
				target = other

		var move := DotFpsCommand.new()
		var fire := DotWeaponCommand.new()

		if target != null:
			var to_target := (target.muzzle_position() - player.muzzle_position()).normalized()
			move.yaw = rad_to_deg(atan2(-to_target.x, -to_target.z))
			move.pitch = rad_to_deg(asin(clampf(to_target.y, -1.0, 1.0)))
			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
			move.move = Vector2(sin(float(tick) * 0.05 + float(player.player_id)), 0.6)

		move.sanitise()
		fire.sanitise()
		commands[player.player_id] = [move, fire]

	return commands


# --- Surf movement -------------------------------------------------------------

func _test_surf_movement() -> void:
	_section("the surf air control is on here, off on a built-in map, and on again")

	var player := _game.player_for(1)
	var surf := ArenaPlayer.SURF_TUNABLES
	var arena := ArenaPlayer.arena_tunables()
	_check(_matches(player, surf, 150.0),
		"on %s: air_accelerate %.0f, air cap %.3f m/s, gravity %.2f" % [
			MAP, player.controller.tunables.air_accelerate,
			player.controller.tunables.max_air_wish_speed, player.controller.tunables.gravity
		])

	var to_box := _game.change_map(ArenaMap.dm_box())
	_check(to_box.ok and is_equal_approx(player.controller.tunables.air_accelerate, arena.air_accelerate)
		and is_equal_approx(player.controller.tunables.max_air_wish_speed, arena.max_air_wish_speed)
		and is_equal_approx(player.controller.tunables.gravity, arena.gravity),
		"on dm_box: back to the arena's own (%.0f, %.2f, %.0f)" % [
			player.controller.tunables.air_accelerate,
			player.controller.tunables.max_air_wish_speed, player.controller.tunables.gravity
		])
	_check(_game.map.collision_root == null and _game._world_collision == null,
		"and the imported solid went with the map")

	var back := _game.change_map(ArenaMap.by_id(MAP))
	_check(back.ok and _matches(player, surf, 150.0), "back on %s: on again" % MAP)

	_game.set_movement_rules({"surf_air_accelerate": 400.0})
	_check(is_equal_approx(player.controller.tunables.air_accelerate, 400.0),
		"arena_surf_airaccelerate reaches a player on the map (%.0f)" % player.controller.tunables.air_accelerate)

	_game.set_movement_rules({"surf": 0.0})
	_check(is_equal_approx(player.controller.tunables.air_accelerate, arena.air_accelerate)
		and is_equal_approx(player.controller.tunables.gravity, arena.gravity),
		"and arena_surf 0 plays it with the arena's own")

	_game.set_movement_rules({"surf": 1.0, "surf_air_accelerate": 150.0})
	_check(_matches(player, surf, 150.0), "and 1 puts the genre's back")

	_done()


func _matches(player: ArenaPlayer, surf: Dictionary, air: float) -> bool:
	var t := player.controller.tunables
	return (
		is_equal_approx(t.air_accelerate, air)
		and is_equal_approx(t.max_air_wish_speed, float(surf["max_air_wish_speed"]))
		and is_equal_approx(t.gravity, float(surf["gravity"]))
		and is_equal_approx(t.jump_height, float(surf["jump_height"]))
	)


# --- A ramp ------------------------------------------------------------------------

func _test_ramp() -> void:
	_section("a ramp is ridden, not stood on")

	var face := _steepest_big_ramp()
	_check(not face.is_empty(), "the map has a surf ramp (a face between %.0f and 75 degrees, %.0f m² of it)" % [
		ArenaPlayer.arena_tunables().max_slope_angle, float(face.get("area", 0.0))
	])

	if face.is_empty():
		_check(false, "so nothing could ride it")
		_check(false, "or slide down it")
		_done()
		return

	var normal: Vector3 = face["normal"]
	var player := _game.player_for(3)

	if not player.is_alive():
		_game.respawn_player(3)

	# Half a metre off the face, along its normal, and dropped: the hull lands ON the ramp.
	var start: Vector3 = face["centre"] + normal * 0.5
	player.controller.teleport(start, 0.0, 0.0)

	var grounded := 0
	var touching := 0
	var top_speed := 0.0
	var no_input := {3: [DotFpsCommand.new(), DotWeaponCommand.new()]}

	for i in range(TICK_RATE):
		_game.tick(no_input)
		var state := player.controller.state

		if state.is_grounded():
			grounded += 1

		# On the face: within a hand of its plane, above it.
		var height_over := normal.dot(state.position - (face["centre"] as Vector3))
		if height_over < 0.6 and height_over > -0.2:
			touching += 1

		top_speed = maxf(top_speed, state.velocity.length())

	var dropped := start.y - player.controller.state.position.y
	_line("     %d ticks on the face, %d grounded, top speed %.1f m/s, %.1f m down" % [
		touching, grounded, top_speed, dropped
	])
	_check(touching > TICK_RATE / 4 and grounded == 0,
		"the player rides it: %d ticks against the face and not one standing on it" % touching)
	_check(top_speed > 8.0 and dropped > 3.0,
		"and slides down it, picking up speed (%.1f m/s, %.1f m)" % [top_speed, dropped])

	_done()


## The biggest triangle of the map's own drawn RAMP surfaces whose slope is one the
## movement cannot stand on: `{centre, normal, area}`, or empty.
func _steepest_big_ramp() -> Dictionary:
	var manifest := ArenaImportedMaps.manifest(MAP)
	var dir := ArenaImportedMaps.manifest_path(MAP).get_base_dir()
	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % MAP))
	var limit := cos(deg_to_rad(ArenaPlayer.arena_tunables().max_slope_angle + 3.0))
	var best := {}
	var best_area := 0.0

	for entry: Variant in manifest.get("surfaces", []):
		var surface: Dictionary = entry

		if str(surface.get("role", "")) != "RAMP":
			continue

		var vcount := int(surface.get("vertex_count", 0))
		var icount := int(surface.get("index_count", 0))
		var floats := blob.slice(int(surface["vertex_offset"]),
			int(surface["vertex_offset"]) + vcount * ArenaBspMap.VERTEX_FLOATS * 4).to_float32_array()
		var indices := blob.slice(int(surface["index_offset"]),
			int(surface["index_offset"]) + icount * 4).to_int32_array()

		for t in range(0, icount - 2, 3):
			var p: Array[Vector3] = []

			for k in range(3):
				var o := int(indices[t + k]) * ArenaBspMap.VERTEX_FLOATS
				p.append(Vector3(floats[o], floats[o + 1], floats[o + 2]) * ArenaBspMap.METRES_PER_UNIT)

			var cross := (p[1] - p[0]).cross(p[2] - p[0])
			var area := cross.length() * 0.5

			if area <= best_area:
				continue

			# Either winding: the face a player lands on points up.
			var normal := cross.normalized()
			if normal.y < 0.0:
				normal = -normal

			if normal.y >= limit or normal.y < 0.26:
				continue

			best_area = area
			best = {"centre": (p[0] + p[1] + p[2]) / 3.0, "normal": normal, "area": area}

	return best


# --- Pits ----------------------------------------------------------------------

func _test_pits() -> void:
	_section("a pit sends a player where it aims, and the floor under the map catches")

	var pits := _game.map.pits
	_check(not pits.is_empty(), "the map has teleport volumes (%d)" % pits.size())

	var player := _game.player_for(2)

	if not player.is_alive():
		_game.respawn_player(2)

	var pit: Dictionary = pits[0]
	var box: AABB = pit["box"]
	player.controller.teleport(box.get_center(), 0.0, 0.0)
	_game.tick({})
	var at := player.controller.state.position
	_check(at.distance_to(pit["to"]) < 0.5,
		"stepped into one, the player is at its destination (%.2f m off)" % at.distance_to(pit["to"]))

	var under := _game.map.bounds.position - Vector3(-1.0, ArenaPlayer.FALL_OUT_DEPTH + 5.0, -1.0)
	player.controller.teleport(under, 0.0, 0.0)
	_game.tick({})
	var spawn: Transform3D = _game.map.spawns[0]
	_check(player.controller.state.position.distance_to(spawn.origin) < 0.5,
		"fallen out of the bottom of the map, back at a spawn")

	_done()


# --- Shots ---------------------------------------------------------------------

func _test_shots() -> void:
	_section("shots stop at the map's walls")

	var trace := _game.combat.trace
	var spawn: Transform3D = _game.map.spawns[0]
	var eye := spawn.origin + Vector3.UP * 1.6
	var blocked := 0
	var nearest := INF

	# Eight directions out of a spawn room: a room has walls, and a trace that hit none of
	# them would be one passing through the map.
	for i in range(8):
		var angle := TAU * float(i) / 8.0
		var hit := trace.ray(eye, Vector3(sin(angle), 0.0, cos(angle)), 200.0)

		if hit.blocked:
			blocked += 1
			nearest = minf(nearest, hit.distance)

	_check(blocked >= 6, "a shot out of the spawn room hits a wall in %d of 8 directions" % blocked)
	_check(trace.ray(eye, Vector3.DOWN, 5.0).blocked, "and the floor under the spawn")

	_done()


# --- Every map -------------------------------------------------------------------

func _test_every_map() -> void:
	_section("every combat surf map builds and puts its spawns on a floor")

	var built := 0
	var bad: Array[String] = []
	var report: Array[String] = []

	for id in ArenaMap.imported_ids():
		var map := ArenaMap.by_id(id)
		var solid := map.to_collision()
		add_child(solid)
		map.collision_root = solid
		await get_tree().physics_frame

		if solid.get_child_count() > 0:
			built += 1

		var body := map.movement_body() as DotFpsPhysicsBody
		var trace := map.shot_trace()
		var tunables := ArenaPlayer.arena_tunables()
		var floored := 0
		var stuck := 0
		# What the game does at load, so what is checked is what a player is put on.
		var lifted := map.settle_spawns(body, tunables)

		for at in map.spawns:
			if trace.ray(at.origin + Vector3.UP * 0.5, Vector3.DOWN, 3.0).blocked:
				floored += 1

			if _in_solid(body, at.origin, tunables):
				stuck += 1

		report.append("%s %d/%d spawns floored, %d spawns and destinations lifted out of solid, %d still in it" % [
			id, floored, map.spawns.size(), lifted, stuck
		])

		# Most, not all: a mapper's spawn can be a few units off the floor or in a wall, and
		# dot-spawn's director only ever needs enough good ones. Half bad is a broken import.
		if map.spawns.size() < 8 or floored * 4 < map.spawns.size() * 3 or stuck * 4 > map.spawns.size():
			bad.append(String(id))

		remove_child(solid)
		solid.free()

	for line in report:
		_line("     " + line)

	_check(built == ArenaMap.imported_ids().size(),
		"every one builds a solid (%d of %d)" % [built, ArenaMap.imported_ids().size()])
	_check(bad.is_empty(), "and three in four of its spawns stand on a floor, clear of solid (%s fail)" % [bad])

	_done()


# --- Plumbing ------------------------------------------------------------------

## Whether a standing hull with its feet at [param feet] is inside solid.
##
## The query's capsule is placed by its CENTRE, so it is lifted half a height; and it is
## a little shorter and thinner than the player's, because a hull resting on a floor or
## against a wall touches it, and "touching" is not "inside".
static func _in_solid(body: DotFpsPhysicsBody, feet: Vector3, tunables: DotFpsTunables) -> bool:
	var height := tunables.stand_height - 0.2
	return body.overlaps(feet + Vector3.UP * (0.1 + height * 0.5), height, tunables.radius - 0.05)


func _ticks(count: int) -> void:
	for i in range(count):
		_game.tick({})

		if i % 16 == 0:
			await get_tree().physics_frame


func _section(title: String) -> void:
	_entered += 1
	_line("")
	_line("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
