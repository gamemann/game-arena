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
	var hands := ZeeViewModel.new()
	hands.name = "Hands"
	_local.camera.add_child(hands)
	_local.arm_first_person(hands, true)
	var _given := _local.weapons.give_everything()
	_players.append(_local)

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
		ask.slot = slot + 1
		for tick in range(_feel_tick, _feel_tick + 80):
			var _o := _local.simulate_tick(tick, 1.0 / 64.0, DotFpsCommand.new(), ask)
			ask = DotWeaponCommand.new()
		_feel_tick += 80

	_shots = [
		{
			"name": "%s_feel_scope" % String(id),
			"local": true,
			"arm": func() -> void:
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
				_hud.notice("Victim is on a 3 kill streak: heal"),
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
				_local.controller.state.pitch = -62.0
				_local.health.health = _local.health.max_health
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
