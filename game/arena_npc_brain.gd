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
## [b]The tree is four nodes and every one of them is there for a reason a state
## machine would have got wrong.[/b]
##
## [codeblock]
## selector
##   sequence (reactive)     has a target?  -> close on it -> hit it
##   action                  wander
## [/codeblock]
##
## The sequence is [method DotNpcAiSequence.reactive_with] rather than a plain
## sequence, and dot-npc-ai's own notes say why: a plain sequence resumes at the child
## that returned RUNNING and never re-asks the condition, so a monster chases a target
## it no longer has — for ever, because the thing that would clear the chase is the
## condition it stopped asking.
##
## [b]There is no difficulty setting; the character is the difficulty.[/b]
## [DotNpcAiCharacter] carries reaction time, aggression and self-preservation per NPC,
## seeded from the instance id, so twenty monsters do not all lunge on the same tick.
## That is Quake III's characteristics table and it is the reason dot-npc-ai exists.

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

	var fight_children: Array[DotNpcAiNode] = [
		has_target,
		DotNpcAiLeaf.Action.new(&"close in", _close_in),
		DotNpcAiLeaf.Action.new(&"strike", _strike),
	]

	var root_children: Array[DotNpcAiNode] = [
		DotNpcAiSequence.reactive_with(&"fight", fight_children),
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
