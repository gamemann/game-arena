extends RefCounted

## Rockets in flight, and what happens where they land.
##
## [b]This is new, and the reason it is new is a bug.[/b] The rocket launcher used to be
## a `DotWeapon` with `delivery = PROJECTILE`, and dot-combat resolved one by recording
## an impact at `origin + direction * max_range` and applying the splash there. Max
## range was 220 metres, so every rocket in this game has detonated 220 metres away in
## the sky, through walls, hitting nobody. Nothing errored, no check failed, and the
## weapon simply did nothing for its whole life.
##
## dot-weapon returns a [DotWeaponSpawn] instead of pretending a rocket is a shot,
## which is what forced this file into existence. A spawn is an entity with a lifetime;
## somebody has to fly it.
##
## [b]It flies on the simulation tick, not on a frame.[/b] Everything here is a pure
## function of the tick count, so a server and a client reach the same impact, and a
## headless suite can fly a rocket into a wall with no rendering at all.
##
## [b]Lag compensation deliberately does not apply.[/b] A rocket takes a third of a
## second to cross a room, and by the time it arrives everybody already agrees where
## everybody is — rewinding the world for it would let a rocket hit somebody where they
## used to be, which is the one thing players notice immediately.

## One rocket, mid-air.
class Flying extends RefCounted:
	var spawn: DotWeaponSpawn = null
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var age_ticks: int = 0


var _live: Array[Flying] = []
var _combat: DotCombatManager = null
var _gravity: float = 20.0

## Emitted where a rocket went off, for an effect and a sound.
signal detonated(at: Vector3, spawn: DotWeaponSpawn)


func setup(combat: DotCombatManager, gravity: float = 20.0) -> void:
	_combat = combat
	_gravity = gravity


## Takes everything a tick of weapon use produced.
func accept(outcome: DotWeaponOutcome) -> void:
	for spawn in outcome.spawns:
		launch(spawn)


func launch(spawn: DotWeaponSpawn) -> void:
	var f := Flying.new()
	f.spawn = spawn
	f.position = spawn.origin
	f.velocity = spawn.velocity
	_live.append(f)


func live_count() -> int:
	return _live.size()


func clear() -> void:
	_live.clear()


## Advances every rocket one tick and detonates the ones that arrived.
##
## Iterated backwards so a detonation can remove its own entry without the loop
## skipping the next one, which is the classic way this kind of list loses an element.
func tick(delta: float) -> void:
	for i in range(_live.size() - 1, -1, -1):
		var f: Flying = _live[i]
		f.age_ticks += 1

		if f.spawn.gravity_scale > 0.0:
			f.velocity.y -= _gravity * f.spawn.gravity_scale * delta

		var step := f.velocity * delta
		var hit := _sweep(f, step)

		if hit != Vector3.INF:
			_detonate(f, hit)
			_live.remove_at(i)
			continue

		f.position += step

		if f.age_ticks >= f.spawn.life_ticks:
			_detonate(f, f.position)
			_live.remove_at(i)


## Traces one tick of flight. Returns the impact point, or [constant Vector3.INF].
##
## [b]A swept segment rather than a point test.[/b] A rocket at 42 m/s moves 66 cm in a
## tick at 64 Hz, and a wall is thinner than that: testing only the end point lets a
## rocket pass through geometry roughly one time in three, which presents as the weapon
## being unreliable rather than as a bug in a trace.
func _sweep(f: Flying, step: Vector3) -> Vector3:
	if _combat == null or _combat.trace == null:
		return Vector3.INF

	var distance := step.length()

	if distance <= 0.0:
		return Vector3.INF

	var shooter := _combat.hitboxes_of(f.spawn.owner_entity)
	# A rocket must not collide with the person who fired it on the tick they fired
	# it, or every rocket detonates in the shooter's face. After that it may.
	_combat.trace.exclude = [shooter] if shooter != null and f.age_ticks <= 1 else []

	var hit := _combat.trace.ray(
		f.position, step / distance, distance, _combat.hitbox_sets()
	)

	_combat.trace.exclude = []

	return hit.point if hit.ok() else Vector3.INF


## Turns an arrival into an ordinary [DotShot] with a splash, and lets dot-combat do
## the rest — the same falloff, friendly fire and armour rules as every other hit.
func _detonate(f: Flying, at: Vector3) -> void:
	if _combat != null and _combat.is_authority:
		var shot := DotShot.make(f.spawn.id, f.spawn.owner_entity, f.spawn.tick, 0)
		shot.origin = at
		shot.direction = f.velocity.normalized()
		shot.damage = 0.0
		shot.damage_type = f.spawn.damage_type
		shot.splash_type = f.spawn.damage_type
		shot.splash_radius = f.spawn.splash_radius
		shot.splash_damage = f.spawn.splash_damage
		shot.splash_hurts_owner = true
		shot.max_range = 0.0
		# The impact is where it landed. Set by hand rather than traced, because the
		# trace already happened: this is the answer, not the question.
		shot.impacts = [at]
		shot.pellets = [shot.direction]

		_combat.resolve_shot(shot)

	detonated.emit(at, f.spawn)


func describe() -> Dictionary:
	return {"live": _live.size()}
