extends DotFpsMoveMode

const ArenaBspMap := preload("arena_bsp_map.gd")

## Climbing a ladder the way the competitive shooters these maps were built for climb one,
## on the ladder volumes an imported map carries (world brushes with ladder contents).
##
## [b]A copy of game-g2gfast's `G2GLadderMode`, in metres[/b], for the reason
## `arena_map_mechanics.gd` gives: a game cannot name another game's script, and a
## delivered pack cannot resolve a `class_name`. Not in dot-player-controller either,
## deliberately: a ladder the way this genre climbs one is the genre's.
##
## [b]What a ladder is in those games:[/b] a thin invisible brush against a wall. A player
## whose hull touches it, and who is pushing into it or is off the ground, is ON it: no
## gravity, forward climbs toward where they are looking (look up and press forward to go
## up, look down to go down), strafe moves along the wall, jump lets go and pushes off it.
## Speed is the climb speed, 200 units a second, whatever the run speed is.
##
## Data, not an area, for [DotFpsSwimMode]'s reason: a box list gives a client replaying
## prediction the same answer the server had. [method update] is the game's once-a-tick
## call that puts a player on; [method _simulate] takes them off.
##
## [b]One difference from g2gfast:[/b] the jump-off grace is counted on [member now], the
## game's tick, which `ArenaPlayer` writes before every simulated tick, rather than on
## `DotFpsState.tick`. That counter is not replicated, so after a rewind a client's copy
## keeps counting from its newest tick and a replayed tick would read a different gap from
## the one the server read. The game's tick is the same number on a replay as the first
## time round.

## The ladder boxes, world space, metres.
var volumes: Array[AABB] = []

var climb_speed: float = 200.0 * ArenaBspMap.METRES_PER_UNIT

## Speed a jump pushes a climber off the ladder, away from it.
var jump_off_speed: float = 270.0 * ArenaBspMap.METRES_PER_UNIT

## How far past the hull a ladder still counts as touched.
var reach: float = 2.0 * ArenaBspMap.METRES_PER_UNIT

## Ticks after a jump off during which the ladder does not take the player back.
const JUMP_OFF_GRACE_TICKS := 32

## The game's tick, written by the player before each simulated tick. See the class note.
var now: int = 0

## The tick a climber last jumped off. One per player: every player has their own mode.
var _jumped_off_tick: int = -1000


func _name() -> StringName:
	return &"ladder"


func _uses_crouch() -> bool:
	return false


## The ladder the hull at [param feet] touches, or AABB() for none.
func touching(feet: Vector3, radius: float, height: float) -> AABB:
	var hull := AABB(feet - Vector3(radius + reach, 0.0, radius + reach),
		Vector3((radius + reach) * 2.0, height, (radius + reach) * 2.0))
	for box in volumes:
		if box.intersects(hull):
			return box
	return AABB()


## Once a tick, after the move: a player touching a ladder who is falling, or walking into
## it, is put on it. Read from the state rather than the command, so it needs nothing a
## replayed tick does not have. Noclip, and somebody already on, are left.
func update(motor: DotFpsMotor, state: DotFpsState) -> void:
	if mode_id < 0 or volumes.is_empty() or state.mode == mode_id or state.mode == DotFpsState.Mode.NOCLIP:
		return
	var t := motor.tunables
	var box := touching(state.position, t.radius, t.height_at(state.crouch_fraction))
	if box.size == Vector3.ZERO:
		return
	# A jump-off AFTER this tick is one a replay has not reached yet: a client corrected
	# back past its own jump-off replays the ticks before it, and counted as a negative gap
	# those ticks refused the grab the server had made. Only a gap of 0..grace holds it off.
	var since := now - _jumped_off_tick
	if state.time_since_jump < 0.15 or (since >= 0 and since < JUMP_OFF_GRACE_TICKS):
		return    # a jump at the foot of a ladder, or off it, is a jump
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var into := -flat.dot(_away(box, state.position))
	if (not state.is_grounded() and state.velocity.y < 0.0) or into > 10.0 * ArenaBspMap.METRES_PER_UNIT:
		motor.set_mode(state, mode_id)
		state.velocity = Vector3.ZERO


func _simulate(state: DotFpsState, command: DotFpsCommand, delta: float, motor: DotFpsMotor) -> void:
	var t := motor.tunables
	var box := touching(state.position, t.radius, t.height_at(state.crouch_fraction))
	if box.size == Vector3.ZERO:
		motor.set_mode(state, DotFpsState.Mode.AIR)
		motor.move_and_slide(state, delta)
		return

	var away := _away(box, state.position)
	if command.is_pressed(DotFpsCommand.BUTTON_JUMP):
		state.velocity = away * jump_off_speed
		_jumped_off_tick = now
		motor.set_mode(state, DotFpsState.Mode.AIR)
		motor.move_and_slide(state, delta)
		return

	# The engine's own ladder move: the wish along the view, split into what goes INTO the
	# ladder's face and what does not; the part into the face is turned into motion UP it
	# (out of it, down), and the rest is kept. So forward while facing the ladder climbs,
	# looking up climbs faster, looking down far enough descends, and strafe slides across.
	var basis := DotFpsMotor._view_basis(state.yaw, state.pitch)
	var wish := (basis.forward * clampf(command.move.y, -1.0, 1.0)
		+ basis.right * clampf(command.move.x, -1.0, 1.0)) * climb_speed
	var into := wish.dot(away)
	var lateral := wish - away * into
	var perp := Vector3.UP.cross(away).normalized()
	var up_face := away.cross(perp)
	var v := lateral - up_face * into
	state.velocity = v.limit_length(climb_speed * 1.5)
	motor.move_and_slide(state, delta)

	# Down onto the floor at the foot: back to walking. Asked only while going down, and
	# the mode put back if there is no floor: the motor's ground check writes AIR for
	# anybody rising who was not on the ground, which is every climber, and g2gfast found
	# that dropping them off the ladder on every tick of a climb bounced them up it at a
	# quarter of the climb speed.
	if v.y <= 0.0:
		motor.categorise_ground(state)
		if not state.is_grounded():
			state.mode = mode_id


## Horizontal unit vector from the ladder's face out toward the player.
static func _away(box: AABB, feet: Vector3) -> Vector3:
	var c := box.get_center()
	var d := Vector3(feet.x - c.x, 0.0, feet.z - c.z)
	# A ladder is thin: its normal is the short horizontal axis.
	if box.size.x < box.size.z:
		d = Vector3(signf(d.x) if d.x != 0.0 else 1.0, 0.0, 0.0)
	else:
		d = Vector3(0.0, 0.0, signf(d.z) if d.z != 0.0 else 1.0)
	return d


func describe() -> Dictionary:
	var out := super.describe()
	out["volumes"] = volumes.size()
	return out
