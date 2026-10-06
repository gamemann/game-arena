extends SceneTree

## Plays the offline client and photographs the weapons doing what no suite can see.
##
## Waits out warmup, turns to face the nearest bot (so a world model is in frame), holds
## the trigger with the clock slowed (so a tracer and a flash outlive a software frame),
## switches to the throwable with the 5 key, throws, follows the grenade with the camera,
## and photographs it going off. Every step goes through the client's own input path —
## its sampler and real mouse and key events — so what is drawn is what a player gets.
##
##     tools/screenshot_weapons.sh            # into screenshots/weapons_*.png
##
## Each frame logs where the player is and what the projectile layer holds, because a
## picture of an empty floor cannot tell "nothing was thrown" from "it is off screen".

const OUT_DIR := "res://screenshots"

var client: Node = null
var _aiming := false
var _follow_grenade := false


func _initialize() -> void:
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	process_frame.connect(_aim)
	_run.call_deferred()


func _aim() -> void:
	var me = client.get("player")
	if me == null:
		return

	var target := Vector3.INF

	if _follow_grenade:
		var flying: Array = client.get("game").projectiles.flying()
		if not flying.is_empty():
			target = flying[0].position
	elif _aiming:
		var best := INF
		for p in client.get("game").players():
			if p != me and p.is_alive() and me.global_position.distance_to(p.global_position) < best:
				best = me.global_position.distance_to(p.global_position)
				target = p.global_position + Vector3(0.0, 1.0, 0.0)

	if target == Vector3.INF:
		return

	var to: Vector3 = target - me.muzzle_position()
	client.get("_sampler").look_at_angles(
		rad_to_deg(atan2(-to.x, -to.z)), rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
	)


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	var path := ProjectSettings.globalize_path("%s/weapons_%s.png" % [OUT_DIR, name])
	root.get_texture().get_image().save_png(path)
	var flying := []
	for f in client.get("game").projectiles.flying():
		flying.append("%s bounces %d%s" % [f.position, f.bounces, " resting" if f.resting else ""])
	print("%s  player %s  projectiles %s" % [path, client.get("player").controller.state.position, flying])


func _mouse(down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	Input.parse_input_event(e)


func _key(code: Key) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = code
		e.keycode = code
		e.pressed = down
		Input.parse_input_event(e)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Warmup, countdown, and the respawn queue placing everybody: about 13 s at 64 ticks.
	await _wait(32.0)
	_aiming = true
	await _wait(1.0)
	await _shot("1_facing_a_bot")

	Engine.time_scale = 0.1
	_mouse(true)
	await _wait(0.05)
	await _shot("2_firing")
	await _wait(0.04)
	await _shot("3_firing")
	_mouse(false)
	Engine.time_scale = 1.0

	await _wait(1.0)
	_aiming = false
	_key(KEY_5)
	await _wait(1.5)
	await _shot("4_grenade_in_hand")

	client.get("_sampler").look_at_angles(client.get("player").controller.state.yaw, 12.0)
	await _wait(0.3)
	_mouse(true)
	await _wait(0.3)
	_mouse(false)
	_follow_grenade = true
	await _wait(0.25)
	await _shot("5_grenade_flying")
	await _wait(0.5)
	await _shot("6_grenade_bouncing")
	await _wait(1.75)
	for i in range(3):
		await _shot("7_explosion_%d" % i)
		await _wait(0.15)

	quit()
