extends SceneTree

## Renders a map to a PNG so a person can look at it.
##
## [b]A map is a rendered thing and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every other check on a map is an assertion about a list of
## boxes, and a list of boxes passes just as happily when they are all in the same
## place. This is the only tool here whose output is looked at rather than compared.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map dm_atrium
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

var _shots: Array[Dictionary] = []
var _index := 0
var _camera: Camera3D = null


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
func _process(_delta: float) -> bool:
	if _index >= _shots.size():
		return true

	if _wait > 0:
		_wait -= 1
		return false

	if not _armed:
		var shot: Dictionary = _shots[_index]
		_camera.position = shot["from"]
		_camera.look_at(shot["at"], Vector3.UP)
		_armed = true
		# Three frames before grabbing. The viewport's texture is the last COMPLETED
		# frame, so grabbing in the same frame the camera moved saves the previous
		# shot under the new shot's name — which looks exactly like a camera that did
		# not move.
		_wait = 3
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join("%s.png" % _shots[_index]["name"])
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_index += 1
	_armed = false
	return false
