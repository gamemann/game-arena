extends "res://addons/dot_npc_ai/runtime/dot_npc_ai_brain.gd"

## How an arena monster decides: a behaviour tree, a character, and one attack.
##
## [b]Extended by PATH rather than by name, and that is not a style choice.[/b] A
## script inside a mounted dot-cloud pack cannot resolve a `class_name` — the project's
## script cache was built long before the pack arrived — so `extends DotNpcAiBrain`
## fails to compile in exactly the deployment dot-npc was shaped for. This one ships in
## the build and is written the delivered way anyway, because a rule you only follow
## where it is needed is a rule nobody notices you have broken.
##
## [b]Every node is there for a reason a state machine would have got wrong.[/b]
##
## [codeblock]
## selector
##   action                  dodge a rocket
##   sequence (reactive)     has a target?
##     selector
##       sequence (reactive)   one of the squad's attack slots? -> close on it -> hit it
##       action                surround: wait on a ring, working round to its back
##   action                  search where it probably went
##   action                  wander
## [/codeblock]
##
## The sequence is [method DotNpcAiSequence.reactive_with] rather than a plain
## sequence, and dot-npc-ai's own notes say why: a plain sequence resumes at the child
## that returned RUNNING and never re-asks the condition, so a monster chases a target
## it no longer has — for ever, because the thing that would clear the chase is the
## condition it stopped asking.
##
## [b]The character is the difficulty, and the server only moves it.[/b]
## [DotNpcAiCharacter] carries reaction time, aggression and self-preservation per NPC,
## seeded from the instance id, so twenty monsters do not all lunge on the same tick.
## That is the arena shooters' characteristics table and it is the reason dot-npc-ai
## exists. `npc_skill` and `npc_reaction_scale` ([member ArenaGame.npc_skill]) shift every
## kind toward easy or nightmare without flattening them: a brute on a hard server is
## still slower to notice than a stalker on the same one.

## What the tree writes and the machine reads. StringNames, so a typo is a parse-time
## identifier rather than a string that silently never matches.
const KEY_LAST_HIT := &"arena.last_hit"
const KEY_HURT_BY := &"arena.hurt_by"

## Where a brain reaches the game. See [ArenaHorde].
const HORDE_SERVICE := &"arena_horde"

## Simulated seconds when this monster last landed a blow.
var _last_attack: float = -999.0

## A drifting heading, so an idle monster patrols rather than standing still.
var _wander_angle: float = 0.0

## The game layer that owns damage. Duck-typed through [DotRegistry], never named.
##
## [b]Looked up rather than handed in, and never cached across a null.[/b] A brain is
## constructed by [method DotNpcSpawner.attach_brain] from a path, so nothing can pass
## it a reference; the registry is this family's answer to exactly that, and it is why
## `DotRegistry` exists instead of an autoload.
var _horde: Object = null


## Assigns the character BEFORE the base class looks at it.
##
## [b]`_build` is too late, and the failure is silent.[/b]
## [method DotNpcAiBrain._npc_ready] seeds the character from the instance id and puts
## it on the context, and it does both [i]before[/i] calling `_build`. A brain that
## assigns `character` inside `_build` therefore gets neither: every monster of a kind
## shares its preset's seed, so all of them roll the same aim error at the same moment
## — the "firing squad" dot-npc-ai's own notes warn about — and `ctx.character` stays
## null for every node in the tree.
##
## Nothing errors. A null on the context reads as "this NPC has no character", which is
## a legitimate configuration, and identical seeds look like a coincidence until there
## are twenty of them.
func _npc_ready() -> void:
	character = _character_for(npc.def.id if npc != null and npc.def != null else &"")
	super()


func _build() -> void:
	_wander_angle = DotNpcAiNode.deterministic_unit(
		npc.instance_id if npc != null else 0, 7717
	) * TAU

	var has_target := DotNpcAiLeaf.Condition.new(
		&"has a target", _has_target
	)

	# Only the squad's attackers close in. A slot is asked for every tick (the reactive
	# sequence re-runs its guard) and kept once had, so an attacker stays one until its
	# target changes or it dies — and then the next monster on the ring steps in.
	var attack_children: Array[DotNpcAiNode] = [
		DotNpcAiLeaf.Condition.new(&"has an attack slot", _has_slot),
		DotNpcAiLeaf.Action.new(&"close in", _close_in),
		DotNpcAiLeaf.Action.new(&"strike", _strike),
	]

	var engage_children: Array[DotNpcAiNode] = [
		DotNpcAiSequence.reactive_with(&"attack", attack_children),
		DotNpcAiLeaf.Action.new(&"surround", _surround),
	]

	# A gunner fights from range: its own branch, chosen by its definition carrying a
	# `range_damage`, so one brain serves every kind and the catalogue decides which fights.
	var engage: DotNpcAiNode = DotNpcAiSelector.new(&"engage", engage_children)

	if tune(&"range_damage", 0.0) > 0.0:
		engage = _ranged_engage()

	var fight_children: Array[DotNpcAiNode] = [
		has_target,
		engage,
	]

	var root_children: Array[DotNpcAiNode] = [
		# First, and above the fight: nothing a monster is doing is worth standing under a
		# rocket for. dot-npc-ai's leaf; the horde turns every rocket in the air into a
		# danger with the splash as its reach.
		DotNpcAiLeaf.Action.new(&"dodge", _dodge),
		DotNpcAiSequence.reactive_with(&"fight", fight_children),
		# Between the fight and the wander. Without it a monster that lost you behind a
		# pillar turned round and drifted off the moment dot-npc's grace ran out, and every
		# kind's `memory_time` below — the brute's twenty seconds most of all — was set and
		# read by nothing.
		DotNpcAiLeaf.Action.new(&"search", _search),
		# Where players actually go on this map, learned by the horde — for the monsters
		# with the tactics to use it. The rest wander, which is what they always did.
		DotNpcAiLeaf.Action.new(&"patrol", _patrol),
		DotNpcAiLeaf.Action.new(&"wander", _wander),
	]

	tree = DotNpcAiSelector.new(&"root", root_children)


## The sequence's guard. A named method rather than an inline lambda because a
## reactive sequence re-runs it every tick, and a lambda that captured `self` in a
## RefCounted brain is a reference cycle that outlives the NPC.
func _has_target(_ctx: DotNpcAiContext) -> bool:
	return npc != null and npc.has_target()


# --- Branches --------------------------------------------------------------

## Walks at the target until it is within reach.
##
## Returns SUCCESS at reach so the sequence moves on to the strike, and RUNNING
## otherwise — which is what keeps the sequence in this child rather than restarting
## the whole tree every tick.
func _close_in(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	if npc == null or not npc.is_alive():
		return DotNpcAiNode.Status.FAILURE

	var to := target_position(npc.position())
	var reach := tune(&"reach", 2.0)

	var flat := to - npc.position()
	flat.y = 0.0

	if flat.length() <= reach:
		halt()
		return DotNpcAiNode.Status.SUCCESS

	# Not until it has reacted. A monster that begins closing on the tick it first
	# sees you is a monster with no reaction time at all, and reaction time is the
	# single most legible difference between an easy opponent and a hard one.
	if not has_reacted():
		halt()
		return DotNpcAiNode.Status.RUNNING

	# `steer_with_spacing` rather than `steer_along_path` on purpose. Twelve monsters
	# converging on one player climb each other without it: the one on top has a
	# horizontal offset of nothing from the one below, so it chases perfectly at a
	# dead stop with every number about it reading correctly.
	var speed := npc.def.move_speed if npc.def != null else 3.0
	steer_with_spacing(to, speed * _urgency(), ctx.delta, _spacing())

	return DotNpcAiNode.Status.RUNNING


## Hits the target, if the interval has elapsed.
func _strike(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	if npc == null or not npc.is_alive() or not npc.has_target():
		return DotNpcAiNode.Status.FAILURE

	var interval := tune(&"attack_interval", 1.0)

	if ctx.now - _last_attack < interval:
		# RUNNING, not FAILURE. Failing here would drop the sequence and send the
		# selector to `wander`, so a monster standing over you between swings would
		# turn round and walk off — which looks exactly like it lost interest.
		halt()
		face(target_position(npc.position()) - npc.position())
		return DotNpcAiNode.Status.RUNNING

	# The reach is re-tested here rather than trusted from `_close_in`. A reactive
	# sequence re-runs its condition, not its earlier children, so a target that
	# stepped away while the interval ran would otherwise be hit from anywhere.
	var to := target_position(npc.position())
	var flat := to - npc.position()
	flat.y = 0.0

	if flat.length() > tune(&"reach", 2.0) * 1.15:
		return DotNpcAiNode.Status.FAILURE

	_last_attack = ctx.now

	if blackboard != null:
		blackboard.put(KEY_LAST_HIT, ctx.now)

	_deal_damage(npc.target_id, tune(&"damage", 10.0))

	return DotNpcAiNode.Status.SUCCESS


# --- At range ----------------------------------------------------------------

## The gunner's fight, in priority order:
##
## [codeblock]
## selector
##   sequence (reactive)  badly hurt?        -> into cover for a moment, still shooting
##   sequence (reactive)  the flank role?    -> round the side, shooting
##   action               suppress: hold the range band, strafing, shooting
## [/codeblock]
##
## One flanker per player, and only a gunner with the tactics for it asks: the rest hold
## the front and keep the player's head down, so the one going round is not shot on the
## way. Nobody gives an order — every gunner asks the squad the same questions in the same
## order, and the answers split the work.
func _ranged_engage() -> DotNpcAiNode:
	return DotNpcAiSelector.new(&"ranged", [
		DotNpcAiSequence.reactive_with(&"break off", [
			DotNpcAiLeaf.Condition.new(&"badly hurt", _should_break_off),
			DotNpcAiLeaf.Action.new(&"to cover", _to_cover),
		] as Array[DotNpcAiNode]),
		DotNpcAiSequence.reactive_with(&"flank", [
			DotNpcAiLeaf.Condition.new(&"the flank role", _may_flank),
			DotNpcAiLeaf.Action.new(&"go round", _flank),
		] as Array[DotNpcAiNode]),
		DotNpcAiLeaf.Action.new(&"suppress", _suppress),
	] as Array[DotNpcAiNode])


## Seconds a gunner that broke off stays in cover before it comes out again.
const COVER_SECONDS := 3.0

const KEY_COVER_UNTIL := &"arena.cover_until"
const KEY_LAST_SHOT := &"arena.last_shot"


## Heavy damage sends it to cover — if it has the self-preservation to care — and it stays
## there for [constant COVER_SECONDS]. Low health does too, for the ones that care a lot.
func _should_break_off(ctx: DotNpcAiContext) -> bool:
	var careful := character.self_preservation if character != null else 0.5

	if ctx.has_condition(DotNpcAiConditions.HEAVY_DAMAGE) and careful >= 0.3:
		blackboard.put(KEY_COVER_UNTIL, ctx.now + COVER_SECONDS, ctx.now)
	elif ctx.has_condition(DotNpcAiConditions.LOW_HEALTH) and careful >= 0.6:
		blackboard.put(KEY_COVER_UNTIL, ctx.now + COVER_SECONDS, ctx.now)

	return ctx.now < blackboard.get_float(KEY_COVER_UNTIL, ctx.now, -INF)


func _to_cover(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var status := take_cover(ctx, npc.def.move_speed if npc.def != null else 3.5)
	_fire(ctx)

	# No cover on this map, or none near: the branch fails and the gunner fights on from
	# the open rather than standing still being hurt.
	return DotNpcAiNode.Status.RUNNING if status != DotNpcAiNode.Status.FAILURE else status


func _may_flank(_ctx: DotNpcAiContext) -> bool:
	return tactics() >= 0.5 and claim_role(ROLE_FLANK, 1)


## Round to the side the player is not facing, at the middle of its range band, shooting.
func _flank(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var center := target_position(Vector3.INF)

	if center == Vector3.INF:
		return DotNpcAiNode.Status.FAILURE

	var here := npc.position()
	var radius := (tune(&"near", 9.0) + tune(&"far", 18.0)) * 0.5
	var point := DotNpcAiTactics.ring_point(center, here, radius, _enemy_facing(center), flank_lead)
	var flat := point - here
	flat.y = 0.0

	if flat.length() > 1.0:
		steer_with_spacing(point, npc.def.move_speed if npc.def != null else 3.5, ctx.delta, _spacing())
	else:
		halt()

	face(center - here)
	_fire(ctx)
	return DotNpcAiNode.Status.RUNNING


## The front: hold the band, strafe, keep the player's head down.
func _suppress(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var speed := npc.def.move_speed if npc != null and npc.def != null else 3.5
	var status := hold_range(ctx, speed, tune(&"near", 9.0), tune(&"far", 18.0), _spacing())
	_fire(ctx)
	return status


## Shoots, if every gate is open and the interval has passed. Hitscan, so no travel speed.
func _fire(ctx: DotNpcAiContext) -> void:
	if ctx.now - blackboard.get_float(KEY_LAST_SHOT, ctx.now, -INF) < tune(&"fire_interval", 0.35):
		return

	var muzzle := npc.position() + Vector3(0.0, 1.4, 0.0)

	if not ready_to_fire(muzzle):
		return

	blackboard.put(KEY_LAST_SHOT, ctx.now, ctx.now)

	if _horde == null:
		_horde = DotRegistry.get_service(HORDE_SERVICE)

	if _horde == null or not _horde.has_method("npc_shoot"):
		return

	_horde.call("npc_shoot", npc, muzzle, aim_solution(muzzle), tune(&"range_damage", 6.0))


func _patrol(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var speed := npc.def.move_speed if npc != null and npc.def != null else 3.0
	return patrol_hot(ctx, speed * 0.45)


func _has_slot(_ctx: DotNpcAiContext) -> bool:
	return claim_attack_slot()


## Waits its turn on a ring just out of reach, working round to the player's back.
##
## Behind the reaction gate like the close-in, or a monster that has only just seen you
## would be circling you before it had noticed you.
func _surround(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	if npc == null or not npc.is_alive():
		return DotNpcAiNode.Status.FAILURE

	if not has_reacted():
		halt()
		return DotNpcAiNode.Status.RUNNING

	var speed := npc.def.move_speed if npc.def != null else 3.0
	return surround(ctx, speed * 0.8, tune(&"reach", 2.0) + 2.5, _spacing())


func _dodge(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var speed := npc.def.move_speed if npc != null and npc.def != null else 3.0
	return flee_danger(ctx, speed)


## Goes to where it last knew somebody was, and looks round. dot-npc-ai's search, at the
## pace of a monster that has lost you rather than one that can see you.
##
## FAILURE when there is nothing remembered, which hands the selector on to `wander`.
func _search(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var speed := npc.def.move_speed if npc != null and npc.def != null else 3.0
	return search(ctx, speed * 0.7, _spacing())


## Drifts about the arena when there is nothing to chase.
##
## Always RUNNING. It is the selector's last child and a monster with nothing to do
## still has to be somewhere, so there is no state in which this "fails".
func _wander(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	if npc == null or not npc.is_alive():
		return DotNpcAiNode.Status.FAILURE

	_wander_angle = DotNpcAiSteering.wander(
		_wander_angle, 0.6 * ctx.delta, npc.instance_id + int(ctx.now)
	)

	var direction := DotNpcAiSteering.angle_to_direction(_wander_angle)
	var speed := (npc.def.move_speed if npc.def != null else 3.0) * 0.35

	steer_with_spacing(
		npc.position() + direction * 6.0, speed, ctx.delta, _spacing()
	)

	return DotNpcAiNode.Status.RUNNING


# --- Reactions -------------------------------------------------------------

## Being shot is information, and a monster that ignores it is one you can farm.
##
## [b]`_npc_damaged` was declared, documented and called by nothing when dot-npc was
## written[/b] — this family's most repeated shape, in a brand new addon, on its first
## pass. It is wired now, and this override is what proves it from the game's side.
func _npc_damaged(amount: float, by: StringName) -> void:
	if blackboard != null and by != &"":
		# A memory with a lifetime rather than a field. The blackboard forgets, which
		# is what stops a monster bearing a grudge against somebody who left.
		blackboard.put(KEY_HURT_BY, by, 6.0)

	var _unused := amount


## Where the damage actually happens.
##
## [b]dot-npc has no idea what damage is and must not learn.[/b] It ships a `damage`
## method for a game with no combat addon and hands the job to the game when there is
## one; this brain is the game's half, and it reaches it through [DotRegistry] because
## a brain loaded from a path cannot be handed anything.
func _deal_damage(victim: StringName, amount: float) -> void:
	if _horde == null:
		_horde = DotRegistry.get_service(HORDE_SERVICE)

	if _horde == null or not _horde.has_method("npc_attack"):
		return

	_horde.call("npc_attack", npc, victim, amount)


# --- Character -------------------------------------------------------------

## Who this monster is, by kind.
##
## Three presets rather than one with a difficulty multiplier, because a difficulty
## multiplier makes every monster the same monster at a different speed — and the
## whole point of the characteristics table is that a brute and a stalker should be
## wrong to fight the same way.
static func _character_for(kind: StringName) -> DotNpcAiCharacter:
	match kind:
		&"arena_brute":
			var brute := DotNpcAiCharacter.hard()
			brute.id = &"arena.brute"
			# Slow to notice and impossible to shake. That is the trade a heavy is:
			# you get a free second, and then it is your problem for a long time.
			brute.reaction_time = 0.85
			brute.memory_time = 20.0
			brute.aggression = 0.9
			brute.self_preservation = 0.05
			return brute

		&"arena_stalker":
			var stalker := DotNpcAiCharacter.hard()
			stalker.id = &"arena.stalker"
			stalker.reaction_time = 0.12
			stalker.memory_time = 12.0
			stalker.aggression = 0.75
			# It runs when hurt. A fast, fragile thing that stood and traded would
			# simply be a worse grunt.
			stalker.self_preservation = 0.8
			return stalker

		&"arena_gunner":
			var gunner := DotNpcAiCharacter.hard()
			gunner.id = &"arena.gunner"
			# A gun makes accuracy matter for the first time in this arena, and a hard
			# preset's 0.85 at three shots a second is a gunner nobody can cross the room
			# against. It hits about half of what it aims at, and it reacts like a person.
			gunner.reaction_time = 0.45
			gunner.aim_accuracy = 0.55
			gunner.aim_skill = 0.6
			gunner.memory_time = 10.0
			gunner.aggression = 0.4
			gunner.self_preservation = 0.65
			gunner.camper = 0.6
			gunner.tactics = 0.85
			return gunner

		_:
			var grunt := DotNpcAiCharacter.normal()
			grunt.id = &"arena.grunt"
			grunt.reaction_time = 0.4
			grunt.memory_time = 6.0
			return grunt


## How hard it presses, from its character and its health.
##
## A hurt monster with high self-preservation slows down; one with none does not
## notice. This is the whole of "fleeing" in an arena — there is nowhere to flee to in
## a forty-metre room, and a monster that ran away would just be one you cannot finish.
func _urgency() -> float:
	if character == null or npc == null:
		return 1.0

	var hurt := 1.0 - npc.health_fraction()
	return clampf(1.0 - hurt * character.self_preservation * 0.6, 0.35, 1.0)


## How far apart to keep from the other monsters, by body size.
##
## From the definition rather than a constant: a brute is twice a stalker's width and
## one spacing for both is either brutes overlapping or stalkers strung out.
func _spacing() -> float:
	if npc == null or npc.def == null:
		return 1.6

	return 1.2 if npc.def.weight == DotNpcDef.Weight.LIGHT else (
		2.4 if npc.def.weight == DotNpcDef.Weight.HEAVY else 1.6
	)
