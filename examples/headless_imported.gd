extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaContent := preload("../game/arena_content.gd")

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
## - the map's own mechanics run: a booster throws a player at its speed, water is swum in
##   (and sunk in, and climbed out of), a ladder is climbed;
## - a hurt volume on [constant HURT_MAP] hurts through dot-combat, every half second, and
##   kills as the world, and a negative one heals;
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

## The map whose hurt volumes are checked: MAP has none.
const HURT_MAP := &"surf_xiv_v2a"

const SECTIONS := 11
const CHECKS := 53

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
	_test_mechanics()
	await _test_hurt()
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


# --- The map's mechanics ------------------------------------------------------------

func _test_mechanics() -> void:
	_section("the map's own mechanics run: a booster, water, a ladder")

	var mech := _game.map.mechanics
	_check(mech != null and not mech.pushes.is_empty() and not mech.water.is_empty()
		and not mech.ladders.is_empty(),
		"the manifest's mechanics are read (%s)" % (mech.describe_lines()[0] if mech != null else "none"))

	if mech == null:
		for _i in range(5):
			_check(false, "so nothing could run")
		_done()
		return

	var player := _fresh(4)
	var probe := DotFpsPhysicsBody.for_node(_game.map.collision_root)
	var tunables := player.controller.tunables
	var idle := {4: [DotFpsCommand.new(), DotWeaponCommand.new()]}

	# A booster: the strongest sideways push lying on a floor. Stood on, it carries the
	# player along it and, on leaving, throws them on at its speed.
	var booster := {}
	for p: Dictionary in mech.pushes:
		var push: Vector3 = p["push"]
		var flat := Vector2(push.x, push.z).length()
		if not p["once"] and (p["box"] as AABB).size.y < 0.5 \
				and flat > Vector2(booster.get("push", Vector3.ZERO).x, booster.get("push", Vector3.ZERO).z).length():
			booster = p
	var box: AABB = booster["box"]
	var speed := (booster["push"] as Vector3).length()
	player.controller.teleport(Vector3(box.get_center().x, box.end.y + 0.02, box.get_center().z), 0.0, 0.0)
	var fastest := 0.0
	for _i in range(TICK_RATE):
		_game.tick(idle)
		fastest = maxf(fastest, player.controller.state.horizontal_speed())
	_line("     booster %.1f m/s at %s: fastest %.1f m/s" % [speed, box.get_center(), fastest])
	_check(fastest > speed * 0.9 and fastest < speed * 1.3,
		"a booster throws a player at its speed (%.1f m/s against %.1f)" % [fastest, speed])

	# Water: the deepest pool with clear water at its middle. A player put in it to the
	# chest swims; pressing nothing they sink, slowly; holding jump they come out of it.
	var pool := AABB()
	var feet := Vector3.ZERO
	var depth := player.swim.waist + 0.3
	# Most of these maps' water is a sheet a few centimetres deep over a pit; the pool is
	# the deepest one a player can be in to the waist, at a spot in it clear of solid.
	for w in mech.water:
		if w.size.x < 3.0 or w.size.z < 3.0 or w.size.y < 1.5 or w.size.y <= pool.size.y:
			continue
		for i in range(1, 8):
			for j in range(1, 8):
				var at := Vector3(w.position.x + w.size.x * i / 8.0, w.end.y - depth,
					w.position.z + w.size.z * j / 8.0)
				if not _in_solid(probe, at, tunables):
					pool = w
					feet = at
					break
			if pool == w:
				break
	player.controller.teleport(feet, 0.0, 0.0)
	_game.tick(idle)
	var swimming := player.controller.state.mode == player.swim.mode_id
	var top := player.controller.state.position.y
	for _i in range(TICK_RATE / 2):
		_game.tick(idle)
	var sunk := top - player.controller.state.position.y
	var sink_speed := -player.controller.state.velocity.y
	_check(swimming and player.controller.state.mode == player.swim.mode_id,
		"put in water to the chest, the player swims (mode %s)" % player.controller.motor.mode_name(player.controller.state.mode))
	_check(sunk > 0.2 and sunk < 0.9 and sink_speed < 2.0,
		"and pressing nothing sinks, slowly: %.2f m in half a second, %.2f m/s" % [sunk, sink_speed])
	var jump := DotFpsCommand.new()
	jump.set_button(DotFpsCommand.BUTTON_JUMP, true)
	var held := {4: [jump, DotWeaponCommand.new()]}
	var out_at := -1
	for i in range(TICK_RATE * 2):
		_game.tick(held)
		var s := player.controller.state
		if s.mode != player.swim.mode_id and s.position.y + player.swim.waist > pool.end.y:
			out_at = i
			break
	_check(out_at >= 0, "and holding jump comes up out of it (%s)" % (
		"%.2f s" % (float(out_at) / TICK_RATE) if out_at >= 0 else "still in after 2 s"))

	# A ladder: walked into from whichever side is clear, facing it, looking up.
	var climbed := 0.0
	var on_ladder := 0
	var tried := 0
	for rung in mech.ladders:
		if rung.size.y < 2.5:
			continue
		var thin_x := rung.size.x < rung.size.z
		for side: float in [1.0, -1.0]:
			var away := Vector3(side, 0.0, 0.0) if thin_x else Vector3(0.0, 0.0, side)
			var face := rung.get_center() + away * ((rung.size.x if thin_x else rung.size.z) * 0.5)
			var at := Vector3(face.x, rung.position.y + 0.3, face.z) + away * (tunables.radius + 0.05)
			if _in_solid(probe, at, tunables):
				continue
			tried += 1
			player.controller.teleport(at, rad_to_deg(atan2(away.x, away.z)), 0.0)
			var climb := DotFpsCommand.new()
			climb.move = Vector2(0.0, 1.0)
			climb.yaw = rad_to_deg(atan2(away.x, away.z))
			climb.pitch = 40.0
			var up := {4: [climb, DotWeaponCommand.new()]}
			var from := at.y
			var on := 0
			var high := from
			for _i in range(TICK_RATE):
				_game.tick(up)
				if player.controller.state.mode == player.ladder.mode_id:
					on += 1
				high = maxf(high, player.controller.state.position.y)
			if high - from > climbed:
				climbed = high - from
				on_ladder = on
		if climbed > 2.0:
			break
	_line("     ladders tried from %d sides: climbed %.2f m, %d ticks on" % [tried, climbed, on_ladder])
	_check(on_ladder > TICK_RATE / 2 and climbed > 2.0,
		"a ladder is climbed: %.2f m up it in a second, %d ticks on it" % [climbed, on_ladder])

	_done()


## A player alive and out of their spawn protection, standing still.
func _fresh(id: int) -> ArenaPlayer:
	var player := _game.player_for(id)
	if not player.is_alive():
		_game.respawn_player(id)
	return player


# --- Hurt ----------------------------------------------------------------------------

func _test_hurt() -> void:
	_section("a hurt volume hurts through dot-combat, kills as the world, and heals")

	var changed := _game.change_map(ArenaMap.by_id(HURT_MAP))
	var mech := _game.map.mechanics if changed.ok else null

	# Volumes clear of the map's teleports, because a hurt sheet over a pit (most of them,
	# on most of these maps) sends the player away before a second pulse can land.
	var hurts: Dictionary = {}
	var heals: Dictionary = {}
	if mech != null:
		for h: Dictionary in mech.hurt:
			var box: AABB = h["box"]
			var amount := float(h["damage"])
			var over_pit := false
			for pit in _game.map.pits:
				if (pit["box"] as AABB).intersects(box):
					over_pit = true
			if over_pit:
				continue
			var area := box.size.x * box.size.z
			if amount > 0.0 and amount <= 200.0 and (hurts.is_empty() or area > float(hurts["area"])):
				h["area"] = area
				hurts = h
			if amount < 0.0:
				heals = h

	_check(not hurts.is_empty() and not heals.is_empty(),
		"on %s, a hurt volume and a healing one clear of its teleports (%d volumes)" % [
			HURT_MAP, mech.hurt.size() if mech != null else 0])

	if hurts.is_empty() or heals.is_empty():
		for _i in range(5):
			_check(false, "so nothing could hurt")
		_done()
		return

	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var player := _fresh(5)
	var idle := {5: [DotFpsCommand.new(), DotWeaponCommand.new()]}
	# Past the spawn protection the map change gave everybody: this is about the hurt.
	await _ticks(_game.match_node.spawn_protection_ticks() + 2)

	var dealt: Array[DotDamage] = []
	var on_damage := func(d: DotDamage) -> void:
		if d.victim == 5:
			dealt.append(d)
	_game.combat.damage_applied.connect(on_damage)
	var feed: Array[DotKillFeed.Entry] = []
	var on_kill := func(e: DotKillFeed.Entry) -> void:
		if e.victim_key == "5":
			feed.append(e)
	_game.player_killed.connect(on_kill)

	var per_second := float(hurts["damage"])
	var pulse := per_second * ArenaMap.ArenaMapMechanics.HURT_INTERVAL
	var before := player.health.health
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	var first := before - player.health.health
	_check(player.is_alive() and is_equal_approx(first, pulse),
		"stepping into a %.0f-a-second volume takes %.0f at once (%.1f, %.0f left)" % [
			per_second, pulse, first, player.health.health])
	_check(dealt.size() == 1 and dealt[0].attacker == 0 and dealt[0].type != null
		and dealt[0].type.id == ArenaContent.DAMAGE_WORLD,
		"through dot-combat, as world damage (%d events, attacker %d, type %s)" % [
			dealt.size(), dealt[0].attacker if not dealt.is_empty() else -1,
			dealt[0].type.id if not dealt.is_empty() and dealt[0].type != null else &"?"])

	# The next pulse is half a second on, and not a tick sooner: then a second one, which
	# from a full 100 at 50 a pulse is the death.
	var interval := roundi(ArenaMap.ArenaMapMechanics.HURT_INTERVAL * TICK_RATE)
	for _i in range(interval - 1):
		_game.tick(idle)
	var held := player.health.health
	_game.tick(idle)
	_line("     %.0f/s: %.0f off at once, %.0f left half a second less a tick later, then %s" % [
		per_second, first, held, "dead" if not player.is_alive() else "%.0f" % player.health.health])
	_check(is_equal_approx(held, before - pulse) and (
			not player.is_alive() or is_equal_approx(player.health.health, before - pulse * 2.0)),
		"the next pulse lands half a second later and not a tick sooner (%.0f, then %.0f)" % [
			held, player.health.health])
	_check(feed.size() == (0 if player.is_alive() else 1) and (feed.is_empty() or feed[0].killer_key == ""),
		"and a death in it is the world's in the kill feed (%d entries, killer \"%s\")" % [
			feed.size(), feed[0].killer_key if not feed.is_empty() else "-"])

	# A negative amount heals: hurt once, out of it for a tick, into the healing volume.
	_game.respawn_player(5)
	await _ticks(_game.match_node.spawn_protection_ticks() + 2)
	player = _fresh(5)
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	var hurt_to := player.health.health
	player.controller.teleport(_game.map.spawns[0].origin, 0.0, 0.0)
	_game.tick(idle)
	_stand_in(player, heals["box"])
	_game.tick(idle)
	var healed := player.health.health - hurt_to
	_check(is_equal_approx(healed, -float(heals["damage"]) * ArenaMap.ArenaMapMechanics.HURT_INTERVAL),
		"a volume of %.0f a second heals %.1f a pulse (%.1f)" % [
			float(heals["damage"]), -float(heals["damage"]) * 0.5, healed])

	_game.combat.damage_applied.disconnect(on_damage)
	_game.player_killed.disconnect(on_kill)
	_done()


## Puts [param player] standing on the top of [param box], in the middle of it.
func _stand_in(player: ArenaPlayer, box: AABB) -> void:
	player.controller.teleport(Vector3(box.get_center().x, box.end.y + 0.02, box.get_center().z), 0.0, 0.0)


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
