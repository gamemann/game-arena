@tool
class_name ArenaPlayer
extends Node3D

## One player: movement, weapons, health and hitboxes, assembled.
##
## [b]This is the piece every one of the addons says belongs in the game.[/b]
## dot-player-controller does not know about dot-combat; dot-combat does not know about
## dot-match; none of them knows about the others' node layout. Something has to own
## the wiring, and it is deliberately here rather than in an addon — an addon that did
## it would be an addon that dictates a scene shape.
##
## Built in code rather than as a `.tscn` for the same reason [ArenaMap] is: the
## headless test and the played game must get the same player, and a scene that is
## instantiated in one and hand-built in the other is two players that drift.
##
## [codeblock]
## var player := ArenaPlayer.new()
## player.setup(ArenaPlayer.Mode.HEADLESS, map, session_id)
## add_child(player)
## player.give_loadout(loadout_entries)
## [/codeblock]

const CHANNEL := "arena.player"

## Died. Carries the damage, so a caller has the killer and the weapon.
signal died(damage: DotDamage)

## Fired a shot. Before it is resolved, so a client can draw a tracer immediately.
signal used(outcome: DotWeaponOutcome)

## Spawned or respawned.
signal spawned(at: Transform3D)

## How the collision and tracing backends are chosen.
enum Mode {
	## Analytic geometry from [ArenaMap]. A dedicated server, and every test.
	##
	## Not a degraded mode: it is exact, it needs no physics space, and — the part
	## that matters — it gives the same answer on a client replaying a tick and a
	## server that ran it. See dot-player-controller's `DotFpsFlatBody`.
	HEADLESS,
	## Godot physics. A client, and a listen server.
	PHYSICS,
}

@export_group("Identity")

## Stable id. A dot-server session id in a real deployment; an index in a test.
##
## The same value is the scoreboard key, the combat entity id and the damage
## attribution, which is what stops three id spaces having to be mapped onto each
## other at every seam.
@export var player_id: int = 0

@export var display_name: String = "Player"

@export var team: int = 0

var mode: Mode = Mode.HEADLESS

var controller: DotFpsController = null
var arsenal: DotWeaponArsenal = null
var health: DotHealth = null
var hitboxes: DotHitboxSet = null

## Where the eyes are, and where shots start.
var view: Node3D = null

## The local player's camera. Null on a server, on a remote player, and headless.
var camera: Camera3D = null

## A displacement added to the camera this frame, and a roll. Written by the client.
##
## [b]The shake is added here rather than applied to the camera by whoever computed
## it[/b], because this is the one place the camera's transform is written — the comment
## in [method present] below says why, and a second writer would fight it every frame for
## the same value. dot-fx computes a displacement and touches no camera, which is
## dot-spectate's rule and is what lets one implementation serve this rig, a spectator's
## and a headless suite.
var camera_offset: Vector3 = Vector3.ZERO
var camera_roll: float = 0.0

## What a remote player is drawn as. Null on the local player, who sees their own eyes.
var body_mesh: Node3D = null

## The movement this player was built with, before any class scaled it.
##
## See [method apply_class_movement]. Captured on the first application rather than at
## build time, so a game that never uses classes never duplicates a tunables object.
var _class_base: DotFpsTunables = null

var _map: ArenaMap = null
var _combat: DotCombatManager = null
var _command := DotWeaponCommand.new()
var _tick_rate: int = 64


## A [DotFpsController] that collides against analytic geometry rather than physics.
##
## `_make_body` is dot-player-controller's documented seam for exactly this, and using it
## is what lets the same [ArenaPlayer] run on a dedicated server with no physics space
## and in a client with one.
class HeadlessController extends DotFpsController:
	var flat_body: DotFpsBody = null

	func _make_body() -> DotFpsBody:
		return flat_body


## Builds the whole player. Call before adding to the tree.
func setup(p_mode: Mode, map: ArenaMap, id: int, name_text: String = "") -> void:
	mode = p_mode
	_map = map
	player_id = id

	if name_text != "":
		display_name = name_text

	name = "Player%d" % id

	_build_view()
	_build_controller()
	_build_health()
	_build_arsenal()
	_build_hitboxes()


func _build_view() -> void:
	view = Node3D.new()
	view.name = "View"
	# Eye height for a 1.8 m capsule, which is what the tunables below describe.
	view.position = Vector3(0.0, 1.6, 0.0)
	add_child(view)


func _build_controller() -> void:
	var tunables := arena_tunables()

	if mode == Mode.HEADLESS:
		var headless := HeadlessController.new()
		headless.flat_body = _map.to_fps_body()
		controller = headless
	else:
		controller = DotFpsController.new()

	controller.name = "Movement"
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tick_rate = _tick_rate
	controller.tunables = tunables
	controller.register_service = false
	controller.register_default_actions = false
	controller.body_ref = DotNodeRef.of_path(NodePath(".."))
	add_child(controller)


## The collision layers this player's movement sweeps against.
##
## [b]Not left at `DotFpsTunables`' default of 1.[/b] One means bit 0, which is right
## only while every body in the game is on bit 0 — the state the layout exists to end.
## Once props moved to the prop layer a mask of 1 was a player who walks through every
## crate on the map, and nothing would have said so: a sweep that hits nothing is a
## sweep, not an error.
##
## Called by `ArenaGame` once the stack is up, because the layout is the stack's.
func use_collision_mask(mask: int) -> void:
	if controller == null or controller.tunables == null:
		return

	controller.tunables.collision_mask = mask


## Scales this player's movement by their class.
##
## [b]Against a kept base, not against whatever the tunables currently say.[/b] A class's
## `move_speed_scale` is a multiplier, so applying it to an object that already carries it
## compounds — four respawns as a 0.8-speed class is 0.41, arrived at silently. The base
## is the tunables this player was built with, captured once.
func apply_class_movement(def: DotPlayerClassDef) -> void:
	if controller == null or controller.tunables == null or def == null:
		return

	if _class_base == null:
		_class_base = controller.tunables.duplicate()

	var _n := DotPlayerClassApply.to_movement(def, controller.tunables, _class_base)


## Movement that feels like an arena shooter rather than a modern one.
##
## Fast, floaty, high air control, and no sprint — the speed is the speed, and the way
## to go faster is to move well. Every number here is a game's choice; none of it is
## dot-player-controller's default.
static func arena_tunables() -> DotFpsTunables:
	var tunables := DotFpsTunables.new()
	tunables.max_speed = 9.0
	tunables.accelerate = 12.0
	tunables.friction = 5.5
	tunables.stop_speed = 3.0
	# High air acceleration with a low wish-speed cap is the classic formula: it does
	# nothing when you hold forward and everything when you turn while strafing.
	tunables.air_accelerate = 140.0
	tunables.max_air_wish_speed = 1.2
	tunables.gravity = 22.0
	tunables.jump_height = 1.25
	tunables.auto_hop = true
	tunables.coyote_time = 0.08
	tunables.jump_buffer_time = 0.12
	tunables.sprint_speed_scale = 1.0
	tunables.crouch_speed_scale = 0.45
	return tunables


func _build_health() -> void:
	health = DotHealth.new()
	health.name = "Health"
	health.max_health = 100.0
	health.max_armour = 100.0
	# No regeneration. An arena shooter's health is a resource you pick up, and
	# regeneration turns every fight into a question of who disengages first.
	health.regen_per_second = 0.0
	health.set_tick_rate(_tick_rate)
	add_child(health)

	health.died.connect(_on_died)


func _build_arsenal() -> void:
	arsenal = DotWeaponArsenal.new()
	arsenal.name = "Arsenal"
	arsenal.tick_rate = _tick_rate
	arsenal.max_slots = 4
	# Every player shares one catalogue: definitions are read-only and a per-player
	# copy would be four resources per player for nothing. Behaviour instances are
	# per-player, which is the half that actually holds state.
	arsenal.catalogue = _catalogue()
	add_child(arsenal)

	var res := arsenal.setup()
	if not res.ok:
		push_error(res.error.message)

	arsenal.used.connect(_on_used)


## The shared weapon table, built once for the whole process.
##
## Validated on first use rather than per player, and loudly: a catalogue with a
## duplicate id hands somebody the wrong weapon and nothing reports it.
static var _shared_catalogue: DotWeaponCatalogue = null


static func _catalogue() -> DotWeaponCatalogue:
	if _shared_catalogue == null:
		_shared_catalogue = ArenaContent.weapon_catalogue()
		var res := _shared_catalogue.validate()
		if not res.ok:
			push_error(res.error.message)
	return _shared_catalogue


func _build_hitboxes() -> void:
	hitboxes = DotHitboxSet.new()
	hitboxes.name = "Hitboxes"
	hitboxes.bounds_offset = Vector3(0.0, 0.9, 0.0)
	hitboxes.bounds_radius = 1.6

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.15
	head.position = Vector3(0.0, 1.62, 0.0)
	# Higher than the torso's, so the shared surface between a head sphere and a chest
	# capsule resolves to the head every time rather than about half the time.
	head.precedence = 10
	hitboxes.add_child(head)

	var chest := DotHitbox.new()
	chest.name = "Chest"
	chest.group = DotHitGroup.CHEST
	chest.shape = DotHitbox.Shape.CAPSULE
	chest.radius = 0.30
	chest.height = 1.05
	chest.position = Vector3(0.0, 0.98, 0.0)
	hitboxes.add_child(chest)

	var legs := DotHitbox.new()
	legs.name = "Legs"
	legs.group = DotHitGroup.LEG
	legs.shape = DotHitbox.Shape.CAPSULE
	legs.radius = 0.24
	legs.height = 0.9
	legs.position = Vector3(0.0, 0.45, 0.0)
	hitboxes.add_child(legs)

	add_child(hitboxes)
	hitboxes.refresh()


## Rebuilds this player's collision against a different map.
##
## [b]Assigning the body is not enough, and that is the whole reason this is a
## method.[/b] `DotFpsMotor` holds a reference to the body it was built with — the same
## trap `DotFpsController.set_style` documents for the tunables — so a player handed
## new geometry without a rebuilt motor keeps colliding against the level they are no
## longer standing in. The symptom is a player wedged in mid-air where a wall used to
## be, with every property reading correctly.
##
## Only the analytic backend is rebuilt. Under [constant Mode.PHYSICS] the collision
## comes from Godot's physics space, which the host project has already repopulated by
## the time this runs, and there is nothing here that knows about it.
func rebind_map(new_map: ArenaMap) -> void:
	_map = new_map

	if new_map == null or controller == null:
		return

	if controller is HeadlessController:
		(controller as HeadlessController).flat_body = new_map.to_fps_body()

	# `setup()` is what builds the body and the motor, and it is the documented way to
	# rebuild both. Re-running it also re-resolves the node references, which is
	# harmless: they name this player's own children and have not moved.
	var rebuilt := controller.setup()

	if not rebuilt.ok:
		DotLog.warn(CHANNEL, "a player could not be re-bodied for the new map", {
			"player": player_id, "why": rebuilt.error.message
		})


# --- Registration ----------------------------------------------------------

## Registers with the combat manager so this player can shoot and be shot.
##
## Both halves matter and they are separate calls in dot-combat: hitboxes make you
## hittable, health makes you damageable. A player with one and not the other is a
## player shots pass through, or one who takes hits and never dies.
func join_combat(combat: DotCombatManager) -> void:
	_combat = combat
	hitboxes.register_with(combat, player_id)
	combat.register_health(player_id, health)
	combat.set_authoritative_origin(player_id, muzzle_position())


func leave_combat() -> void:
	if _combat != null and is_instance_valid(_combat):
		_combat.forget(player_id)
	_combat = null


# --- Loadout ---------------------------------------------------------------

## Gives the weapons a resolved loadout names.
##
## [param entries] is what [method DotLoadoutManager.resolve] returns: dictionaries of
## `slot`, `arsenal_slot`, `item` and `count`.
##
## [b]Not [DotWeaponLoadoutBridge], deliberately.[/b] The bridge does the weapon half
## and would do it correctly, but this game's loadout also carries armour, which is not
## a weapon and which the bridge is right to skip. Doing both here keeps the one place
## that knows about both id spaces down to one loop.
func give_loadout(entries: Array[Dictionary]) -> void:
	arsenal.clear()

	var catalogue := arsenal.catalogue
	var lowest := 0

	for entry in entries:
		var item: DotItem = entry["item"]

		if not catalogue.has(item.id):
			# An equipment item with no weapon behind it. Armour goes through here.
			if item.id == &"armour":
				health.add_armour(100.0)
			continue

		var res := arsenal.give(item.id)

		if not res.ok:
			push_warning(res.error.message)
			continue

		var slot := catalogue.get_def(item.id).slot

		if lowest == 0 or slot > lowest:
			lowest = slot

	if lowest > 0:
		arsenal.select(lowest, controller.state.tick)


## The default loadout, for a player who has not chosen one.
func give_default_loadout() -> void:
	arsenal.clear()
	arsenal.give(&"pistol")
	arsenal.give(&"rifle")
	arsenal.select(2, controller.state.tick)


# --- Lifecycle -------------------------------------------------------------

## Puts the player into the world alive and whole.
func spawn(at: Transform3D, tick: int, protection_ticks: int = 0) -> void:
	# teleport() takes the look angles, not a velocity: it zeroes the velocity itself
	# and setting yaw afterwards would miss the sampler and the view, which it also
	# snaps.
	controller.teleport(at.origin, rad_to_deg(at.basis.get_euler().y), 0.0)

	health.spawn_protection_ticks = protection_ticks
	health.reset(tick)

	arsenal.disabled = false
	global_transform = at

	if _combat != null:
		_combat.set_authoritative_origin(player_id, muzzle_position())

	spawned.emit(at)


## Takes the player out of play without removing them.
func make_dead() -> void:
	arsenal.disabled = true
	health.alive = false
	hitboxes.enabled = false


func is_alive() -> bool:
	return health.alive


# --- Simulation ------------------------------------------------------------

## Advances the player one tick.
##
## [b]The order is not arbitrary.[/b] Movement runs first so the shot leaves from
## where the player ends the tick rather than where they started it — half a tick of
## movement at arena speeds is fifteen centimetres, which at range is a miss. The
## arsenal's spread inputs are taken from the movement state afterwards, and the shots
## come out last.
##
## Returns the shots produced, unresolved. The caller decides whether it is
## authoritative enough to resolve them.
func simulate_tick(
	tick: int,
	delta: float,
	movement_command: DotFpsCommand,
	combat_command: DotWeaponCommand
) -> DotWeaponOutcome:
	if not health.alive:
		return DotWeaponOutcome.nothing("Dead.")

	controller.apply_command(movement_command)
	controller.simulate_tick(tick, delta)

	var state := controller.state

	# The aim comes from the movement command, not from a second sample. Sampling the
	# mouse twice gives a shot that leaves at a different angle than the one the
	# player was looking along.
	var previous := _command
	_command = combat_command.duplicate_command()
	_command.yaw = state.yaw
	_command.pitch = state.pitch

	health.tick(tick, delta)

	if _combat != null:
		_combat.set_authoritative_origin(player_id, muzzle_position())

	# Pushed in from the simulated state, never read out of a rendered one: an
	# interpolated position differs between client and server by design, and feeding it
	# to the spread makes the spread differ too.
	var ctx := DotWeaponContext.make(
		player_id, tick, muzzle_position(), _command.aim_direction()
	)
	ctx.speed = state.horizontal_speed()
	ctx.airborne = not state.is_grounded()
	ctx.crouched = state.is_crouched()
	ctx.authority = arsenal.authority

	return arsenal.simulate_tick(_command, ctx, previous)


## Draws this player at where they are BETWEEN ticks. Called once per rendered frame.
##
## [b]Nothing in this family rendered between ticks until it was measured.[/b]
## `DotFpsController.render_state` has interpolated between the last two ticks since the
## controller was written and is documented as the cure for exactly this stutter; its
## guard was `if drive != Drive.LOCAL: return state`, and `LOCAL` is the drive no
## networked game uses. Measured at 60 frames against a 128-tick server, drawing at the
## last tick instead: the camera advanced 74 mm on six frames out of seven and 112 mm on
## the seventh — **a 47% change in apparent speed, eight times a second**.
##
## The other half is that the engine must run at the SERVER's tick rate. The fraction a
## renderer interpolates at is a fraction through a physics frame, which is a fraction
## through a tick only while the two rates agree, so either fix alone measures as no
## better than doing nothing. `ArenaNetBridge._adopt_tick_rate` is the other half.
##
## View angles are deliberately NOT interpolated, and they never juddered: mouse motion
## is delivered once per frame and the sampler consumes everything pending, so whichever
## tick runs next absorbs exactly that frame's motion. Blending it would add a tick of
## latency to aiming to fix nothing.
func present(delta: float) -> void:
	if controller == null:
		return

	var drawn := controller.render_state() if camera != null else controller.state

	if camera != null:
		# Written globally rather than by moving this node: this node is the
		# controller's body, and the tick writes it. Moving it here would fight the
		# simulation and, on the predicted local player, would be read back by
		# reconciliation as "what the client is showing".
		if view != null:
			view.global_position = (
				controller.motor.eye_position(drawn)
				if controller.motor != null
				else drawn.position + Vector3(0.0, 1.6, 0.0)
			)

		camera.global_position = view.global_position + camera_offset
		camera.global_rotation = Vector3(
			deg_to_rad(drawn.pitch), deg_to_rad(drawn.yaw), camera_roll
		)
	elif body_mesh != null:
		# A remote player. Its node is moved by `_net_interpolated`, so all that is
		# left is to face it the way its yaw says.
		body_mesh.global_rotation = Vector3(0.0, deg_to_rad(drawn.yaw), 0.0)

	var _unused := delta


## Gives this player a camera and something to look at it with. Client side, local
## player only.
##
## [b]The field of view is horizontal-at-4:3, converted.[/b] Godot's `Camera3D.fov` is
## vertical and fixed; an arena shooter's 100 is horizontal on a 4:3 frame and widens
## on a wider screen. Handing 100 straight to Godot gives about 133 at 16:9 and a
## player who cannot aim and cannot say why.
func attach_camera(horizontal_fov_at_4_3: float = 100.0) -> Camera3D:
	if camera != null:
		# Already attached, so the only thing that can have changed is the field of view --
		# and a player who moves that slider and sees nothing happen has a setting that is
		# stored and read by nobody, which is this family's most repeated bug.
		set_field_of_view(horizontal_fov_at_4_3)
		return camera

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.current = true
	camera.near = 0.05
	camera.far = 512.0

	set_field_of_view(horizontal_fov_at_4_3)

	# Parented to the game rather than to this player, and positioned globally every
	# frame. A camera hanging off the body inherits the body's per-tick position, which
	# is the stepping `present` exists to remove.
	add_child(camera)

	return camera


## Sets the horizontal field of view, converting to the vertical one Godot wants.
##
## The conversion is against 4:3 rather than against the window, which is the convention
## every game in this genre uses: a player who types 100 gets the same horizontal view on
## a 16:9 monitor and on an ultrawide, rather than a number that means something different
## on every screen.
func set_field_of_view(horizontal_fov_at_4_3: float) -> void:
	if camera == null:
		return
	var half := deg_to_rad(clampf(horizontal_fov_at_4_3, 40.0, 160.0) * 0.5)
	camera.fov = rad_to_deg(2.0 * atan(tan(half) * 3.0 / 4.0))


## Something to see a remote player as.
##
## [b]An avatar when one is given, a capsule and a nose when one is not.[/b] The
## fallback is not a lesser case: a server with no dot-platform hands out nothing, a
## client that has not been told yet has nothing, and a player has to be visible in
## both. [ArenaAvatars.stock_avatar] closes most of that gap — it is a real document
## over the same schema, deterministic in the player id — so the capsule is what is
## left when even the schema is absent.
##
## [b]The avatar is what makes dot-user-avatar do anything here.[/b] Before this,
## `ArenaAvatars` built documents, `ArenaIdentity` resolved them and
## `ArenaPlayer` drew a coloured capsule — a value produced correctly and consumed by
## nobody, which is this family's most repeated shape and which the "a method whose
## name occurs once" detector is what caught.
func attach_body_mesh(colour: Color, avatar: DotAvatar = null) -> void:
	if body_mesh != null:
		return

	body_mesh = Node3D.new()
	body_mesh.name = "Body"
	add_child(body_mesh)

	if avatar != null and _wear(avatar):
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.85

	var trunk := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	trunk.mesh = capsule
	trunk.material_override = material
	trunk.position = Vector3(0.0, 0.9, 0.0)
	body_mesh.add_child(trunk)

	# A nose, so which way somebody is facing is visible from across the arena. Two
	# overlapping shapes need the smaller one OUTSIDE the larger or the silhouette is
	# one blob — game-playground drew every NPC icon as a coloured bar that way.
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.16, 0.16, 0.35)
	nose.mesh = box
	nose.material_override = material
	nose.position = Vector3(0.0, 1.5, -0.45)
	body_mesh.add_child(nose)


## Builds the avatar's rig under [member body_mesh]. Returns whether anything drew.
##
## [b]A failure here falls back to the capsule rather than leaving nothing.[/b] A
## player who is invisible because their crest is from a newer build is worse than one
## drawn as a capsule — and `conform` already drops a part it does not have, so
## reaching this at all means the schema itself would not build.
func _wear(avatar: DotAvatar) -> bool:
	var rig := ArenaAvatars.make_rig()
	body_mesh.add_child(rig)

	var built := ArenaAvatars.apply(
		avatar, rig, ArenaAvatars.schema(), ArenaAvatars.catalogue()
	)

	if not built.ok:
		DotLog.debug(CHANNEL, "an avatar could not be drawn; using the capsule", {
			"player": player_id, "why": built.error.message
		})
		body_mesh.remove_child(rig)
		rig.queue_free()
		return false

	return true


## Where shots start: the eyes, not the feet.
##
## Read off the View node when there is one, because that is what the arsenal is handed to
## place a shot — computing it a second way here would let the server's idea of the
## muzzle drift from the one the shots actually came out of, and `_correct_origin`
## would then relocate every legitimate shot.
func muzzle_position() -> Vector3:
	if view != null and view.is_inside_tree():
		return view.global_position

	return controller.state.position + Vector3(0.0, 1.6, 0.0)


func aim_direction() -> Vector3:
	return _command.aim_direction()


## The current cone half-angle, for a crosshair.
##
## Asks the tuning rather than the behaviour, because a crosshair is drawn every frame
## and a behaviour is only stepped on a tick. A weapon whose tuning is not ballistic
## has no cone to draw and gets zero.
func spread_degrees() -> float:
	var slot := arsenal.current()

	if slot == null or not (slot.def.tuning is DotWeaponBallistics):
		return 0.0

	var state := controller.state
	var b: DotWeaponBallistics = slot.def.tuning

	return b.spread_for(
		state.horizontal_speed(), not state.is_grounded(), state.is_crouched()
	)


func _on_died(damage: DotDamage) -> void:
	make_dead()
	died.emit(damage)


func _on_used(outcome: DotWeaponOutcome) -> void:
	used.emit(outcome)


func describe() -> Dictionary:
	return {
		"id": player_id,
		"name": display_name,
		"team": team,
		"mode": Mode.keys()[mode],
		"position": controller.state.position,
		"health": health.describe(),
		"arsenal": arsenal.describe(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%s (%d)  %s" % [display_name, player_id, "alive" if is_alive() else "dead"])
	out.append_array(health.describe_lines())
	out.append_array(arsenal.describe_lines())
	return out
