extends RefCounted

## Rockets and grenades in flight, and what happens where they land.
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
##
## [b]A client flies its own copies, and they decide nothing.[/b] The server tells every
## client about a launch (`ArenaEvents.Kind.LAUNCH`) and the client flies the same spawn
## through the same code against the same analytic map, so it sees the grenade arc and
## bounce where the server's does. Its combat manager is not the authority, so
## [method _detonate] resolves nothing there and only says where it went off.

## One projectile, mid-air, rolling, or stuck to something.
class Flying extends RefCounted:
	var spawn: DotWeaponSpawn = null
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var age_ticks: int = 0
	## Bounces on a fuse, and stops on whatever it touches with `sticks`.
	var sticks: bool = false
	## Stopped: on the floor, or stuck. A stopped projectile is not swept.
	var resting: bool = false
	## What a sticky stuck to, if it was a body that moves, and where on it.
	var stuck_to: Node3D = null
	var stuck_offset: Vector3 = Vector3.ZERO
	var bounces: int = 0


## How much speed a fused grenade keeps off a bounce, into the surface and along it.
##
## Low into it, because a grenade that comes back off a wall at the speed it went in reads
## as rubber; higher along it, so it still rolls into a room rather than dropping dead at
## the door it was thrown through.
const RESTITUTION := 0.35
const SURFACE_KEEP := 0.7

## Below this it stops on a floor rather than hopping on the spot. Metres per second.
const REST_SPEED := 1.2

## Bounces before it simply stops. A grenade wedged in a corner otherwise bounces between
## two walls for its whole fuse, and a sweep per bounce is a sweep per tick.
const MAX_BOUNCES := 12

## Ticks a thrown grenade ignores its thrower, against one tick for a rocket.
##
## Longer, because a grenade lobbed while running forward is overtaken by its thrower's
## own hull on the second or third tick, and then bounces off their face.
const THROWER_GRACE_TICKS := 8


var _live: Array[Flying] = []
var _combat: DotCombatManager = null
var _gravity: float = 20.0

## What the [code]sticks[/code] param is read from: a spawn carries the weapon's id and
## the definition carries the rule. Null leaves every fused spawn a bouncer.
var catalogue: DotWeaponCatalogue = null

## Where an entity's shots really start, or null: the game's answer, for
## [method _detonate]. See there for why a projectile layer has to ask.
var origin_of: Callable = Callable()

## Emitted where a projectile went off, for an effect and a sound.
signal detonated(at: Vector3, spawn: DotWeaponSpawn)

## Emitted when one is launched, for whoever tells clients about it.
signal launched(spawn: DotWeaponSpawn)


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
	f.sticks = _sticks(spawn)
	_live.append(f)
	launched.emit(spawn)


func _sticks(spawn: DotWeaponSpawn) -> bool:
	if spawn.meta.has(&"sticks"):
		return bool(spawn.meta[&"sticks"])

	if catalogue == null:
		return false

	var def := catalogue.get_def(spawn.id)
	return def != null and bool(def.params.get(&"sticks", false))


func live_count() -> int:
	return _live.size()


## Everything in the air or on the ground, for a client to draw.
func flying() -> Array[Flying]:
	return _live


## Every rocket in the air, as `[position, splash_radius]`. What the horde turns into a
## danger its monsters can hear and get out from under.
func in_flight() -> Array:
	var out: Array = []

	for f in _live:
		out.append([f.position, f.spawn.splash_radius])

	return out


func clear() -> void:
	_live.clear()


## Advances every projectile one tick and detonates the ones that are due.
##
## Iterated backwards so a detonation can remove its own entry without the loop
## skipping the next one, which is the classic way this kind of list loses an element.
##
## [b]Two kinds of spawn, told apart by the fuse.[/b] A spawn with no fuse — the
## launcher's — goes off on contact. A spawn with one — a grenade — goes off when the fuse
## runs out, wherever it has got to, and contact only changes where that is: a frag
## bounces and rolls, a sticky stops dead on the first thing it touches. This file used to
## know only the first kind, so a thrown grenade would have gone off on the first wall it
## met, and one cooked in the hand floated where it was for twelve seconds.
func tick(delta: float) -> void:
	for i in range(_live.size() - 1, -1, -1):
		var f: Flying = _live[i]
		f.age_ticks += 1

		if _due(f):
			_detonate(f, f.position)
			_live.remove_at(i)
			continue

		if f.resting:
			_follow(f)
		else:
			if f.spawn.gravity_scale > 0.0:
				f.velocity.y -= _gravity * f.spawn.gravity_scale * delta

			var step := f.velocity * delta
			var hit := _sweep(f, step)

			if hit == null:
				f.position += step
			elif f.spawn.fuse_ticks <= 0:
				_detonate(f, hit.point)
				_live.remove_at(i)
				continue
			else:
				_touch(f, hit)

		if f.age_ticks >= f.spawn.life_ticks:
			_detonate(f, f.position)
			_live.remove_at(i)


## Whether [param f] goes off this tick without touching anything.
##
## A fused spawn whose fuse has run out, and one with no fuse AND no speed: the shape
## dot-weapon gives a grenade cooked past its fuse — "no velocity, no fuse, at the
## carrier's own position" — which means now.
func _due(f: Flying) -> bool:
	if f.spawn.fuse_ticks > 0:
		return f.age_ticks >= f.spawn.fuse_ticks

	return f.age_ticks <= 1 and f.velocity == Vector3.ZERO


## A fused projectile met something: stick to it or bounce off it.
func _touch(f: Flying, hit: DotHitbox.Hit) -> void:
	var normal := hit.normal

	if normal.length_squared() < 0.0001:
		normal = -f.velocity.normalized()

	# Just off the surface, so the next sweep does not start inside it.
	f.position = hit.point + normal * maxf(f.spawn.radius, 0.02)

	if f.sticks:
		f.velocity = Vector3.ZERO
		f.resting = true

		# A body that moves takes it with them: thrown at a person, it is on the person.
		var body := _body_of(hit)
		if body != null:
			f.stuck_to = body
			f.stuck_offset = f.position - body.global_position
		return

	var into := f.velocity.dot(normal)
	var along := f.velocity - normal * into
	f.velocity = along * SURFACE_KEEP - normal * into * RESTITUTION
	f.bounces += 1

	# Stops on a floor once it is slow, or anywhere once it has bounced enough.
	if (normal.y > 0.7 and f.velocity.length() < REST_SPEED) or f.bounces >= MAX_BOUNCES:
		f.velocity = Vector3.ZERO
		f.resting = true


## Keeps a stuck projectile on the body it stuck to.
func _follow(f: Flying) -> void:
	if f.stuck_to == null:
		return

	if not is_instance_valid(f.stuck_to) or not f.stuck_to.is_inside_tree():
		f.stuck_to = null
		return

	f.position = f.stuck_to.global_position + f.stuck_offset


## The node a hit belongs to, if it was a hitbox rather than the world.
func _body_of(hit: DotHitbox.Hit) -> Node3D:
	if hit.blocked or hit.hitbox == null:
		return null

	var set_node := hit.hitbox.get_parent()
	return set_node as Node3D if set_node is Node3D else null


## Traces one tick of flight. Returns what it hit, or null.
##
## [b]A swept segment rather than a point test.[/b] A rocket at 44 m/s moves 69 cm in a
## tick at 64 Hz, and a wall is thinner than that: testing only the end point lets a
## rocket pass through geometry roughly one time in three, which presents as the weapon
## being unreliable rather than as a bug in a trace.
func _sweep(f: Flying, step: Vector3) -> DotHitbox.Hit:
	if _combat == null or _combat.trace == null:
		return null

	var distance := step.length()

	if distance <= 0.0:
		return null

	var shooter := _combat.hitboxes_of(f.spawn.owner_entity)
	# Not the person who fired it, at first, or every rocket detonates in the shooter's
	# face. After that it may.
	var grace := 1 if f.spawn.fuse_ticks <= 0 else THROWER_GRACE_TICKS
	_combat.trace.exclude = [shooter] if shooter != null and f.age_ticks <= grace else []

	var hit := _combat.trace.ray(
		f.position, step / distance, distance, _combat.hitbox_sets()
	)

	_combat.trace.exclude = []

	return hit if hit.ok() else null


## Turns an arrival into an ordinary [DotShot] with a splash, and lets dot-combat do
## the rest — the same falloff, friendly fire and armour rules as every other hit.
func _detonate(f: Flying, at: Vector3) -> void:
	if _combat != null and _combat.is_authority:
		var shot := DotShot.make(f.spawn.id, f.spawn.owner_entity, f.spawn.tick, 0)
		shot.origin = at
		shot.direction = f.velocity.normalized() if f.velocity != Vector3.ZERO else Vector3.DOWN
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

		# [b]The blast is where it landed, and dot-combat had to be stopped moving it.[/b]
		# `resolve_shot` corrects a shot's origin to where it believes the attacker is
		# whenever the two are more than `max_origin_error` apart — right for a gun, whose
		# shot must leave the shooter — and then re-traces, clearing the impacts set
		# above. With `max_range` 0 the trace ends where it starts, so every rocket and
		# grenade that went off more than 2.5 m from its owner exploded in the OWNER'S
		# FACE: the launcher hurt nobody but the person firing it, for as long as it had
		# existed, and a frag thrown fifteen metres took half its damage off the thrower.
		# Found by the first check here that asked the thrower's health. The believed
		# origin is pinned to the blast for this one resolution and put back after.
		var eye: Variant = origin_of.call(f.spawn.owner_entity) if origin_of.is_valid() else null

		if eye is Vector3:
			_combat.set_authoritative_origin(f.spawn.owner_entity, at)

		_combat.resolve_shot(shot)

		if eye is Vector3:
			_combat.set_authoritative_origin(f.spawn.owner_entity, eye)

	detonated.emit(at, f.spawn)


func describe() -> Dictionary:
	var resting := 0
	for f in _live:
		if f.resting:
			resting += 1
	return {"live": _live.size(), "resting": resting}
