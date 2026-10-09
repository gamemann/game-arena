extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaDrops := preload("../game/arena_drops.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## Renders a map to a PNG so a person can look at it.
##
## [b]A map is a rendered thing and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every other check on a map is an assertion about a list of
## boxes, and a list of boxes passes just as happily when they are all in the same
## place. This is the only tool here whose output is looked at rather than compared.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map dm_atrium
##   tools/screenshot.sh dm_box --admin      # an administrator's beacon and blind
##   tools/screenshot.sh dm_atrium --view keep -30,3,-28 -15,2,-12   # one more frame
##   tools/screenshot.sh dm_box --fx 0,1.7,10 30,1.5,12   # shots from the first point at the second
##   tools/screenshot.sh surf_10x_reloaded_fixed          # an imported map, played for a while
##
## [b]`--admin` puts players in the map and renders what the two screen-shaped mod tools
## look like[/b]: a beaconed player on open floor beside one who is not, the same beacon
## behind a pillar (its column is drawn through walls, which is the half no check can see),
## and a first-person view through the real HUD before and after a blind. The players are
## real `ArenaPlayer`s drawn by their own `present`, and the darkness is the real HUD's.
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

var _shots: Array[Dictionary] = []
var _index := 0
var _camera: Camera3D = null

## `--admin`'s cast: drawn every frame by their own `present`, as a client draws them.
var _players: Array[ArenaPlayer] = []
var _local: ArenaPlayer = null
var _hud: ArenaHud = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var map_index := args.find("--map")
	var id := StringName(args[map_index + 1]) if map_index >= 0 and map_index + 1 < args.size() else &"dm_box"
	var map := ArenaMap.by_id(id)

	if map == null:
		push_error("no such map: %s. Known: %s" % [String(id), ArenaMap.ids()])
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	root.add_child(map.to_scene())

	# Sun and sky, because an unlit grey box tells you nothing about a grey-box map —
	# the whole job of the dev texture is to communicate scale and it cannot do that
	# with no light falling across it.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -37.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	root.add_child(sun)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = Sky.new()
	environment.sky.sky_material = ProceduralSkyMaterial.new()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.55
	env.environment = environment
	root.add_child(env)

	_camera = Camera3D.new()
	_camera.fov = 70.0
	root.add_child(_camera)

	if args.has("--admin"):
		_stage_admin(map, id)
		return

	if args.has("--feel"):
		_stage_feel(map, id)
		return

	if map.is_imported():
		_stage_imported(map, id)
		return

	var fx_at := args.find("--fx")
	if fx_at >= 0:
		var eye: Variant = _vector(args[fx_at + 1]) if fx_at + 2 < args.size() else null
		var aim_at: Variant = _vector(args[fx_at + 2]) if fx_at + 2 < args.size() else null
		if eye == null or aim_at == null:
			push_error("--fx wants <eye x,y,z> <aim at x,y,z>")
			quit(1)
			return
		_stage_fx(map, id, eye, aim_at)
		return

	var far := map.extent * 1.5

	# Three frames, because one camera angle is one thing you did not get wrong. An
	# overview says whether there is a map; eye level says whether it is a space a
	# person could be inside of.
	_shots = [
		{
			"name": "%s_overview" % String(id),
			"from": Vector3(-far, map.extent * 1.15, -far),
			"at": Vector3.ZERO,
		},
		{
			"name": "%s_eye" % String(id),
			"from": Vector3(-map.extent * 0.72, 1.7, -map.extent * 0.55),
			"at": Vector3(0.0, 3.0, 0.0),
		},
		{
			"name": "%s_roof" % String(id),
			"from": Vector3(map.extent * 0.62, 12.0, map.extent * 0.62),
			"at": Vector3(0.0, 3.0, 0.0),
		},
	]

	# `--view <name> <x,y,z> <x,y,z>`, repeatable: one more frame, from the first point
	# looking at the second. The three above are fixed so two renders of a map are
	# comparable across nights; a new piece of a map is usually somewhere none of them
	# points, and the keep on dm_atrium was a blank wall in the eye frame and a lid in
	# the overview -- neither says whether its doorways read as doorways.
	var at := 0

	while true:
		at = args.find("--view", at)
		if at < 0 or at + 3 >= args.size():
			break

		var from: Variant = _vector(args[at + 2])
		var target: Variant = _vector(args[at + 3])

		if from == null or target == null:
			push_error("--view wants <name> <x,y,z> <x,y,z>, got %s" % str(args.slice(at, at + 4)))
		else:
			_shots.append({
				"name": "%s_%s" % [String(id), args[at + 1]],
				"from": from,
				"at": target,
			})

		at += 4


## `"x,y,z"` as a Vector3, or null when it is not three numbers.
static func _vector(text: String) -> Variant:
	var parts := text.split(",")

	if parts.size() != 3:
		return null

	for part in parts:
		if not part.strip_edges().is_valid_float():
			return null

	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


var _wait := 0
var _armed := false


## [b]Frame-counted rather than awaited.[/b] `SceneTree._process` is expected to return
## a bool synchronously; making it a coroutine returns a signal object instead, which is
## truthy, so the tree quits on the first frame and writes nothing. That is what the
## first version of this file did, and its symptom was a clean exit with an empty
## `screenshots/`.
func _process(delta: float) -> bool:
	if _imported_game != null and _shots.is_empty():
		_play_imported()
		return false

	for body in _players:
		body.present(delta)

	if _index >= _shots.size():
		return true

	if _wait > 0:
		_wait -= 1
		return false

	if not _armed:
		var shot: Dictionary = _shots[_index]
		if shot.has("arm"):
			(shot["arm"] as Callable).call()
		if shot.get("local", false):
			_local.camera.current = true
		else:
			_camera.current = true
			_camera.position = shot["from"]
			_camera.look_at(shot["at"], Vector3.UP)
		_armed = true
		# Three frames before grabbing. The viewport's texture is the last COMPLETED
		# frame, so grabbing in the same frame the camera moved saves the previous
		# shot under the new shot's name — which looks exactly like a camera that did
		# not move. More for a shot that has something fading in.
		_wait = int(shot.get("wait", 3))
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join("%s.png" % _shots[_index]["name"])
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_index += 1
	_armed = false
	return false


# --- An imported map --------------------------------------------------------

## An imported combat surf map, with a deathmatch played on it for a few seconds first.
##
## [b]Played rather than posed, because what can be wrong is where people END UP[/b]: a
## spawn inside a brush, a floor nobody lands on, a map at the wrong scale under a 1.8 m
## player, textures that never loaded, a lightmap drawn black. So a real [ArenaGame] —
## authority, the map's solid in the tree, bots shooting at each other — runs
## [constant IMPORTED_TICKS] ticks, and the frames are taken of where its players are:
## behind one at head height looking at the others, one player's own eye, the spawn area
## from above, and the map's biggest surf ramp from beside it.
const IMPORTED_TICKS := 160
var _imported_game: ArenaGame = null


func _stage_imported(map: ArenaMap, id: StringName) -> void:
	_imported_game = ArenaGame.new()
	_imported_game.name = "Game"
	_imported_game.headless = true
	_imported_game.is_authority = true
	_imported_game.register_service = false
	root.add_child(_imported_game)
	_staged_map = map
	_staged_id = id


var _staged_map: ArenaMap = null
var _staged_id: StringName = &""


## Run on the first frame, once the game is in the tree (its children ready there).
func _play_imported() -> void:
	var game := _imported_game
	var res := game.setup(_staged_map)

	if not res.ok:
		push_error("the imported map did not set up: %s" % res.error.message)
		quit(1)
		return

	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0

	for i in range(5):
		var _added := game.add_player(201 + i, "Bot %d" % (i + 1))

	game.start(0)

	for tick in range(IMPORTED_TICKS):
		var commands := {}

		for player in game.players():
			var move := DotFpsCommand.new()
			# Each bot walks its own way, turning slowly, so they spread out of the
			# spawn room the way players do, without a fight ending it in a second.
			move.yaw = fmod(float(player.player_id) * 77.0 + float(tick) * 0.6, 360.0)
			# Three stand where they spawned and two walk off into the map, so the
			# frames have both somebody on a spawn's floor and somebody on a ramp.
			move.move = Vector2(0.0, 1.0) if tick > 40 and player.player_id > 203 else Vector2.ZERO
			move.sanitise()
			commands[player.player_id] = [move, DotWeaponCommand.new()]

		game.tick(commands)

	var mechanics_shots := _stage_mechanics(game)
	var players := game.players()

	for player in players:
		player.attach_body_mesh(
			Color.from_hsv(fmod(float(player.player_id) * 0.37, 1.0), 0.55, 0.85),
			ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(player.player_id)))
		)
		_players.append(player)
		print("  %s at %s, %s" % [
			player.display_name, player.controller.state.position,
			"standing" if player.controller.state.is_grounded() else "in the air"
		])

	# Over the shoulder of somebody STANDING, at whoever is nearest them: a frame whose
	# subject is in mid-air on a ramp says nothing about the floor.
	var first: ArenaPlayer = players[0]

	for player in players:
		if player.controller.state.is_grounded():
			first = player
			break

	var feet := first.controller.state.position
	var facing := Basis(Vector3.UP, deg_to_rad(first.controller.state.yaw)) * Vector3.FORWARD
	var centre := Vector3.ZERO
	var nearest := INF

	for player in players:
		var d := player.controller.state.position.distance_to(feet)

		if player != first and player.controller.state.is_grounded() and d < nearest:
			nearest = d
			centre = player.controller.state.position

	if nearest == INF:
		centre = feet + facing * 6.0
	else:
		facing = Vector3(centre.x - feet.x, 0.0, centre.z - feet.z).normalized()

	# Below the horizon is sky too: these maps float in their skybox, and the procedural
	# sky's brown "ground" reads as a floor a long way down that is not there.
	for node in root.get_children():
		if node is WorldEnvironment:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			material.ground_bottom_color = material.sky_horizon_color
			material.ground_horizon_color = material.sky_horizon_color

	_shots = [
		{
			# Behind the first player, over their shoulder, at the others.
			"name": "%s_players" % String(_staged_id),
			"from": feet - facing * 3.0 + Vector3.UP * 2.2,
			"at": centre + Vector3.UP * 0.9,
		},
		{
			# Their own body hidden, as a first-person view draws it: a camera at the eye of
			# a body that is drawn has that body's arm across the frame.
			"name": "%s_eye" % String(_staged_id),
			"from": feet + Vector3.UP * 1.6,
			"at": feet + Vector3.UP * 1.6 + facing * 10.0,
			"arm": func() -> void:
				if first.body_mesh != null:
					first.body_mesh.visible = false,
		},
		{
			"name": "%s_spawns" % String(_staged_id),
			"arm": func() -> void:
				if first.body_mesh != null:
					first.body_mesh.visible = true,
			"from": feet + Vector3(-14.0, 18.0, -14.0),
			"at": feet,
		},
		{
			"name": "%s_overview" % String(_staged_id),
			"from": _staged_map.bounds.get_center() + Vector3(-1.0, 0.6, -1.0) * _staged_map.extent,
			"at": _staged_map.bounds.get_center(),
		},
	]

	_shots.append_array(mechanics_shots)
	var ramp := _biggest_ramp(_staged_map)

	if not ramp.is_empty():
		var normal: Vector3 = ramp["normal"]
		var across := normal.cross(Vector3.UP).normalized()
		_shots.append({
			"name": "%s_ramp" % String(_staged_id),
			"from": (ramp["centre"] as Vector3) + normal * 6.0 + across * 10.0 + Vector3.UP * 3.0,
			"at": ramp["centre"],
		})

	_camera.far = 2000.0


## Two of the walking bots handed to the map's own mechanics, and a frame of each: one put
## in its deepest pool to the chest and left to sink (`<id>_water`), one put on its
## strongest floor booster and ticked until it has been thrown off the end
## (`<id>_booster`). A map with neither gets neither frame. The players are moved by the
## game's own tick, so what is drawn is where the mechanics put them.
func _stage_mechanics(game: ArenaGame) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var mech := _staged_map.mechanics
	var swimmer := game.player_for(205)
	var rider := game.player_for(204)

	if mech == null or swimmer == null or rider == null:
		return out

	var probe := DotFpsPhysicsBody.for_node(_staged_map.collision_root)
	var tunables := swimmer.controller.tunables
	var depth := swimmer.swim.waist + 0.3
	var pool := AABB()
	var in_water := Vector3.ZERO

	for w in mech.water:
		if w.size.x < 3.0 or w.size.z < 3.0 or w.size.y < 1.5 or w.size.y <= pool.size.y:
			continue
		for i in range(1, 8):
			for j in range(1, 8):
				var at := Vector3(w.position.x + w.size.x * i / 8.0, w.end.y - depth,
					w.position.z + w.size.z * j / 8.0)
				var height := tunables.stand_height - 0.2
				if not probe.overlaps(at + Vector3.UP * (0.1 + height * 0.5), height, tunables.radius - 0.05):
					pool = w
					in_water = at
					break
			if pool == w:
				break

	var booster := {}
	for p: Dictionary in mech.pushes:
		var push: Vector3 = p["push"]
		if not p["once"] and (p["box"] as AABB).size.y < 0.5 and Vector2(push.x, push.z).length() \
				> Vector2(booster.get("push", Vector3.ZERO).x, booster.get("push", Vector3.ZERO).z).length():
			booster = p

	if pool.size != Vector3.ZERO:
		swimmer.controller.teleport(in_water, 0.0, 0.0)
	if not booster.is_empty():
		var pad: AABB = booster["box"]
		rider.controller.teleport(Vector3(pad.get_center().x, pad.end.y + 0.02, pad.get_center().z), 0.0, 0.0)

	# Long enough for the rider to be carried off the end of a booster most of a
	# hundred metres long, and the swimmer to sink a little.
	var start := rider.controller.state.position
	for _i in range(18):
		var idle := {}
		for player in game.players():
			idle[player.player_id] = [DotFpsCommand.new(), DotWeaponCommand.new()]
		game.tick(idle)

	if pool.size != Vector3.ZERO:
		var at := swimmer.controller.state.position
		print("  swimmer at %s, mode %s, %.2f m under the surface" % [
			at, swimmer.controller.motor.mode_name(swimmer.controller.state.mode), pool.end.y - at.y])
		out.append({
			"name": "%s_water" % String(_staged_id),
			"from": Vector3(at.x, pool.end.y + 1.2, at.z) + Vector3(3.0, 0.0, 3.0),
			"at": at + Vector3.UP * 0.9,
		})

	if not booster.is_empty():
		var at := rider.controller.state.position
		var push: Vector3 = booster["push"]
		var along := Vector3(push.x, 0.0, push.z).normalized()
		print("  booster rider carried %.1f m to %s, %.1f m/s" % [
			start.distance_to(at), at, rider.controller.state.horizontal_speed()])
		out.append({
			"name": "%s_booster" % String(_staged_id),
			"from": at - along * 7.0 + along.cross(Vector3.UP) * 3.0 + Vector3.UP * 2.5,
			"at": at + Vector3.UP * 0.9,
		})

	return out


## The biggest triangle the map draws as a surf ramp, `{centre, normal}`.
static func _biggest_ramp(map: ArenaMap) -> Dictionary:
	var manifest: Dictionary = ArenaMap.ArenaImportedMaps.manifest(map.id)
	var dir := map.manifest_path.get_base_dir()
	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % String(map.id)))
	var stride := ArenaMap.ArenaBspMap.VERTEX_FLOATS
	var scale := ArenaMap.ArenaBspMap.METRES_PER_UNIT
	var best := {}
	var best_area := 0.0

	for entry: Variant in manifest.get("surfaces", []):
		var surface: Dictionary = entry

		if str(surface.get("role", "")) != "RAMP":
			continue

		var vcount := int(surface["vertex_count"])
		var icount := int(surface["index_count"])
		var floats := blob.slice(int(surface["vertex_offset"]),
			int(surface["vertex_offset"]) + vcount * stride * 4).to_float32_array()
		var indices := blob.slice(int(surface["index_offset"]),
			int(surface["index_offset"]) + icount * 4).to_int32_array()

		for t in range(0, icount - 2, 3):
			var p: Array[Vector3] = []

			for k in range(3):
				var o := int(indices[t + k]) * stride
				p.append(Vector3(floats[o], floats[o + 1], floats[o + 2]) * scale)

			var cross := (p[1] - p[0]).cross(p[2] - p[0])

			if cross.length() * 0.5 > best_area:
				best_area = cross.length() * 0.5
				var normal := cross.normalized()
				best = {"centre": (p[0] + p[1] + p[2]) / 3.0, "normal": normal if normal.y >= 0.0 else -normal}

	return best


# --- --admin ----------------------------------------------------------------

## Players in the map, and the frames that show an administrator's beacon and blind.
##
## Written against `dm_box`'s layout — open floor at the south end, a five-metre pillar
## at (-12, -4) — and still renders on another map, where the pillar frame may simply not
## have a pillar in it.
func _stage_admin(map: ArenaMap, id: StringName) -> void:
	# Beaconed, on open floor, with a player who is not beside them for contrast.
	var marked := _cast(map, 101, "Marked", Vector3(1.0, 0.05, 11.0), 200.0)
	var plain := _cast(map, 102, "Plain", Vector3(4.2, 0.05, 12.5), 160.0)
	marked.beacon = true
	# Behind the pillar from where the second frame stands.
	var hidden := _cast(map, 103, "Hidden", Vector3(-12.0, 0.05, -9.0), 0.0)
	hidden.beacon = true

	# Whose eyes the last two frames are behind, looking north at the other two.
	_local = ArenaPlayer.new()
	_local.name = "Local"
	_local.setup(ArenaPlayer.Mode.HEADLESS, map, 104, "You")
	root.add_child(_local)
	_local.spawn(Transform3D(Basis(), Vector3(-1.0, 0.05, 20.0)), 0)
	_local.attach_camera(100.0)
	_local.camera.current = false
	_players.append(_local)

	_hud = ArenaHud.new()
	_hud.name = "Hud"
	_hud.config = DotUiConfig.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hud)
	_hud.build(null)
	_hud.follow(_local)
	_hud.visible = false

	var _unused := plain

	_shots = [
		{
			"name": "%s_beacon" % String(id),
			"from": Vector3(-4.5, 3.4, 18.5),
			"at": Vector3(2.0, 0.6, 11.5),
		},
		{
			# Eye level, the pillar between the camera and the player: the body is hidden
			# and the column is not, which is the reason it is drawn through walls.
			"name": "%s_beacon_wall" % String(id),
			"from": Vector3(-11.0, 1.7, 9.0),
			"at": Vector3(-12.0, 4.0, -9.0),
		},
		{
			"name": "%s_eye_hud" % String(id),
			"local": true,
			"arm": func() -> void: _hud.visible = true,
		},
		{
			"name": "%s_blind" % String(id),
			"local": true,
			"arm": func() -> void: _local.blinded = true,
			# The HUD fades a blind in over a quarter of a second; software rendering is
			# slow enough that three frames can be less than that.
			"wait": 12,
		},
	]


# --- --feel -----------------------------------------------------------------

## What the arena's 2026-10-06 additions look like, which no suite can say: the sniper's
## scope, the HUD (hurt, the launch counting down, the slide prompt), a body exploding on a
## lethal critical, and your own body when you look down.
var _feel_tick: int = 1


func _stage_feel(map: ArenaMap, id: StringName) -> void:
	var victim := _cast(map, 111, "Victim", Vector3(1.0, 0.05, 12.0), 180.0)
	var hurt := _cast(map, 113, "Hurt", Vector3(4.0, 0.05, 13.0), 200.0)

	_local = ArenaPlayer.new()
	_local.name = "Local"
	_local.setup(ArenaPlayer.Mode.HEADLESS, map, 112, "You")
	root.add_child(_local)
	_local.spawn(Transform3D(Basis(), Vector3(-1.0, 0.05, 20.0)), 0)
	_local.attach_camera(100.0)
	_local.camera.current = false
	# Where the arena's vendored weapon art is; the client says so at boot, and without it
	# the hands are drawn holding nothing.
	ZeeModelCache.set_asset_root("res://")
	_players.append(_local)

	# The hands are armed on the first frame, not here: this runs in the script's _init,
	# before anything is in the tree, so the rig's `get_path()` of the hands failed ("Cannot
	# get path of node") and every frame showed empty hands.
	var arm_hands := func() -> void:
		if _local.get_node_or_null(^"Camera/Hands") != null or _local.weapons == null:
			pass
		var hands := ZeeViewModel.new()
		hands.name = "Hands"
		_local.camera.add_child(hands)
		_local.arm_first_person(hands, true)
		var _given := _local.weapons.give_everything()

	_hud = ArenaHud.new()
	_hud.name = "Hud"
	_hud.config = DotUiConfig.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hud)
	_hud.build(null)
	_hud.follow(_local)
	_hud.visible = false

	var hold := func(slot: int) -> void:
		# Asked for through the command, as the client does, and ticked the way the game
		# ticks a player: the rig equips the view model on a tick and nothing else here
		# ticks it.
		var ask := DotWeaponCommand.new()
		ask.slot = slot
		for tick in range(_feel_tick, _feel_tick + 80):
			var _o := _local.simulate_tick(tick, 1.0 / 64.0, DotFpsCommand.new(), ask)
			ask = DotWeaponCommand.new()
		_feel_tick += 80

	_shots = [
		{
			"name": "%s_feel_scope" % String(id),
			"local": true,
			"arm": func() -> void:
				arm_hands.call()
				# The sniper itself: give_everything leaves the heavy slot holding the last
				# heavy it gave, which is not the sniper.
				var _g := _local.arsenal.give(ZeeWeaponIds.SNIPER)
				hold.call(ZeeWeaponIds.SLOT_HEAVY)
				_local.aim_held = true
				_hud.visible = true,
			"wait": 30,
		},
		{
			"name": "%s_feel_hud" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.aim_held = false
				hold.call(ZeeWeaponIds.SLOT_PRIMARY)
				_local.health.health = _local.health.max_health * 0.12
				_local.controller.state.launch_cooldown_left = 5.5
				_local.controller.state.slide_time = 0.3
				for v in [201, 202, 203]:
					_hud.note_kill({"killer_id": 112, "victim_id": v, "headshot": v == 203, "weapon": "rifle"}, 112, "You")
				_hud.notice("Victim is on a 3 kill streak: heal")
				_local.challenge = 1
				_local.challenge_value = 11,
			"wait": 30,
		},
		{
			"name": "%s_feel_break" % String(id),
			# From the east: the west side of this floor is the stair block, which hid
			# all but a flying head in the first two renders.
			"from": Vector3(6.5, 2.6, 16.5),
			"at": Vector3(1.0, 0.9, 12.0),
			"arm": func() -> void:
				_hud.visible = false
				var rules := DotPlayerBreakRules.new()
				rules.mode = DotPlayerBreakRules.Mode.EXPLODE
				rules.criticals_only = false
				# Slowed, so the frame is mid-burst rather than after it.
				rules.force = 2.5
				rules.lift = 2.0
				victim.make_dead()
				var _b := victim.break_body(rules, Vector3(0.0, 0.0, -1.0), 7, true),
			"wait": 8,
		},
		{
			"name": "%s_feel_health" % String(id),
			"from": Vector3(4.0, 2.4, 18.5),
			"at": Vector3(4.0, 1.6, 13.0),
			"arm": func() -> void:
				hurt.health.health = 40.0,
			"wait": 6,
		},
		{
			"name": "%s_feel_drops" % String(id),
			"from": Vector3(3.5, 2.4, 19.0),
			"at": Vector3(0.0, 0.3, 14.5),
			"arm": func() -> void:
				var drops := ArenaDrops.new()
				drops.is_authority = false
				drops.draws = true
				root.add_child(drops)
				var from := Vector3(0.0, 0.05, 14.5)
				for i in range(5):
					var a := TAU * float(i) / 5.0
					drops.mirror_drop(i + 1, ArenaDrops.Kind.COIN, from + Vector3(cos(a) * 1.6, 0.0, sin(a) * 1.6), from, 1)
				drops.mirror_drop(9, ArenaDrops.Kind.HEALTH, from + Vector3(0.0, 0.0, 0.3), from, 25),
			"wait": 40,
		},
		{
			"name": "%s_feel_body" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.controller.state.slide_time = -1.0
				# Through teleport, which sets the drawn state too: the camera draws from the
				# controller's interpolated render state, and a pitch written into `state`
				# alone never reached it (the first two body frames looked at the horizon).
				_local.controller.teleport(_local.controller.state.position, _local.controller.state.yaw, -62.0)
				# And the sampler, which owns a local player's look and writes it every tick.
				if _local.get("sampler") != null:
					_local.sampler.look_at_angles(_local.controller.state.yaw, -62.0)
				_local.health.health = _local.health.max_health
				# A real avatar: a player with none is drawn as a capsule, which has no legs to keep.
				_local.avatar = load("res://game/arena_avatars.gd").stock_avatar(&"you")
				# Current first: present_own_body draws nothing for a camera nobody looks through.
				_local.camera.current = true
				_local.present_own_body(true, _local.controller.state.yaw)
				_hud.visible = true,
			"wait": 12,
		},
	]


# --- --fx -------------------------------------------------------------------

## A burst of rifle shots at a wall, drawn by the real presentation layer the way a client
## draws its own: [method ArenaPresentation.on_used] with a [DotWeaponOutcome] whose
## impacts are where the map's own trace says each shot stopped.
##
## [b]The particles are slowed to a twentieth of real speed and restarted once spawned.[/b]
## A muzzle flash lives 80 ms and a software renderer under xvfb takes longer than that per
## frame, so at full speed the frame this saves is the one after it went out. The holes are
## decals and are not affected.
func _stage_fx(map: ArenaMap, id: StringName, eye: Vector3, aim_at: Vector3) -> void:
	var presentation := ArenaPresentation.new()
	presentation.name = "Presentation"
	root.add_child(presentation)
	var built := presentation.setup()
	if not built.ok:
		push_error("the presentation layer: %s" % built.error.message)

	var trace := map.to_trace()
	var aim := (aim_at - eye).normalized()
	var side := aim.cross(Vector3.UP).normalized()
	var refused := {}
	presentation.fx.spawned.connect(func(fx_id: StringName, node: Node, why: StringName) -> void:
		if node == null:
			refused["%s: %s" % [fx_id, why]] = true
	)
	var fire := func() -> void:
		# A small group, the last one freshest: holes from the earlier shots, the spark
		# and the flash from the last. One shot per frame's budget, as a client fires one
		# a tick: six in one frame is over dot-fx's budget and the last are refused.
		for i in range(6):
			presentation.present(0.016, eye, aim)
			var angle := float(i) * 1.1
			var spread := side * sin(angle) * 0.012 * i + Vector3.UP * cos(angle) * 0.012 * i
			var dir := (aim + spread).normalized()
			var hit := trace.ray(eye, dir, 500.0)
			var shot := DotShot.new()
			shot.weapon_id = &"rifle"
			shot.origin = eye
			shot.direction = dir
			if hit.ok():
				shot.impacts = [hit.point]
				if i == 0:
					print("fx: the first shot stopped at %s, %.1f m away" % [hit.point, hit.distance])
			var outcome := DotWeaponOutcome.new()
			outcome.used = true
			outcome.add_shot(shot)
			presentation.on_used(outcome)
		for particles in presentation.fx.find_children("*", "CPUParticles3D", true, false):
			(particles as CPUParticles3D).speed_scale = 0.05
			# And started again at the slowed speed. A one-shot's first update ages it by
			# the whole frame's delta, and a software frame is longer than a flash lives,
			# so without this the flash has already finished when the slowing lands.
			(particles as CPUParticles3D).restart()
		if not refused.is_empty():
			print("fx: refused %s" % ", ".join(PackedStringArray(refused.keys())))
			refused.clear()

	var hit0 := trace.ray(eye, aim, 500.0)
	var wall := hit0.point if hit0.ok() else aim_at

	_shots = [
		{
			# Through the shooter's own eye: the flash low and right, the spark on the wall.
			"name": "%s_fx_eye" % String(id),
			"from": eye,
			"at": eye + aim,
			"arm": fire,
			"wait": 4,
		},
		{
			# Beside the wall, looking at the holes, re-fired so the spark is fresh again.
			"name": "%s_fx_wall" % String(id),
			"from": wall - aim * 2.2 + side * 1.2 + Vector3.UP * 0.3,
			"at": wall,
			"arm": fire,
			"wait": 4,
		},
		{
			# A death two metres short of the wall, seen from where the shots came from.
			"name": "%s_fx_death" % String(id),
			"from": eye + side * 1.5,
			"at": wall - aim * 2.0 + Vector3.UP * 0.5,
			"arm": func() -> void:
				var where := Transform3D(Basis.IDENTITY, Vector3(wall.x, map.floor_y, wall.z) - aim * 2.0)
				presentation.present(0.016, eye, aim)
				presentation.on_died(where)
				for particles in presentation.fx.find_children("Gibs", "CPUParticles3D", true, false):
					(particles as CPUParticles3D).speed_scale = 0.2
					(particles as CPUParticles3D).restart(),
			"wait": 4,
		},
	]


func _cast(map: ArenaMap, pid: int, name_text: String, at: Vector3, yaw: float) -> ArenaPlayer:
	var body := ArenaPlayer.new()
	body.name = name_text
	body.setup(ArenaPlayer.Mode.HEADLESS, map, pid, name_text)
	root.add_child(body)
	body.spawn(Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), at), 0)
	body.attach_body_mesh(
		Color.from_hsv(fmod(float(pid) * 0.37, 1.0), 0.55, 0.85),
		ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(pid)))
	)
	_players.append(body)
	return body
