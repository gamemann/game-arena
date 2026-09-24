extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Renders a map to a PNG so a person can look at it.
##
## [b]A map is a rendered thing and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every other check on a map is an assertion about a list of
## boxes, and a list of boxes passes just as happily when they are all in the same
## place. This is the only tool here whose output is looked at rather than compared.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map dm_atrium
##   tools/screenshot.sh dm_box --admin      # an administrator's beacon and blind
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
