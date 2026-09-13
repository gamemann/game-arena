extends Node

const ArenaGame := preload("arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## Status effects in the arena, and the one line that makes them count.
##
## [b]The whole of the integration is `resolver.adjust`.[/b] dot-combat has had that
## seam since it was written — "the extension point for a game mode's own arithmetic: a
## damage boost pickup, a round-start immunity, a mode where the leader takes double" —
## and until now nothing in this game filled it. So an attacker's crit and a victim's
## resistance meet the damage at the one point every hit already goes through: after the
## friendly-fire, falloff and hit-group rules, and before the clamp. A layer that
## scaled damage anywhere else would have to be applied at every damage site, and the
## site somebody forgets is the bug.
##
## [b]Nothing here owns a health value.[/b] dot-effects reports an amount and this
## applies it through [DotHealth], which is what puts an afterburn tick through the same
## armour, the same rules and the same kill feed as a rifle round.
##
## [codeblock]
## var effects := ArenaEffects.new()
## effects.game = game
## add_child(effects)
## effects.setup()
## effects.apply(&"arena_burning", victim_id, attacker_id)
## [/codeblock]

const CHANNEL := "arena.effects"

## What the map's fire, the plasma splash and a burning barrel all leave behind.
const BURNING := &"arena_burning"

## A damage boost. The arena's quad, in everything but the name.
const EMPOWERED := &"arena_empowered"

## Faster on your feet, and it is the pickup that changes a fight most.
const HASTE := &"arena_haste"

## Briefly untouchable after a respawn, so a spawn camp is a waste of ammunition.
const PROTECTED := &"arena_protected"

## Slower, from a monster's swipe. The horde's only lasting effect.
const SLOWED := &"arena_slowed"

var game: ArenaGame = null

var manager: DotEffectManager = null


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "ArenaEffects needs a game.")

	manager = DotEffectManager.new()
	manager.name = "EffectManager"
	manager.authoritative = game.is_authority
	manager.rules = _rules()
	add_child(manager)

	var res := manager.setup(table(game.tick_rate, _protection_ticks()))
	if not res.ok:
		return res.wrap("arena effects")

	manager.damaged.connect(_on_damaged)
	manager.healed.connect(_on_healed)

	_bind_combat()

	# **A map change builds a NEW combat manager and a new resolver**, so the hook
	# above is on an object that is about to be freed. Without this the effects layer
	# keeps running, keeps expiring, keeps reporting burn damage — and stops scaling a
	# single hit, silently, from the first changelevel onwards. That is this family's
	# most repeated shape exactly: a value produced correctly and consumed by nothing.
	if not game.map_changed.is_connected(_on_map_changed):
		game.map_changed.connect(_on_map_changed)

	return DotResult.success(null)


## Put the per-hit hook back on whatever resolver is current.
func _bind_combat() -> void:
	if game.combat == null or game.combat.resolver == null:
		return
	game.combat.resolver.adjust = adjust_damage


func _on_map_changed(_map: ArenaMap) -> void:
	_bind_combat()


func _rules() -> DotEffectRules:
	var rules := DotEffectRules.new()
	# No incapacitation in a deathmatch: a player at zero health respawns in two
	# seconds and being down instead would be a different game. game-playground's
	# co-operative wave mode is where that belongs.
	rules.downed_enabled = false
	rules.temp_decay_per_tick = 0.15
	rules.temp_grace_ticks = game.tick_rate
	return rules


## Every effect the arena has, at one tick rate.
##
## [b]Built from the rate rather than exported at one.[/b] A server runs at
## `sv_tickrate` and a client at whatever it exported; an effect table with 640 written
## into it is ten seconds on one and five on the other, which is g2gfast's
## 128-against-60 bug in a different subsystem.
## How long `PROTECTED` lasts, from the mode rather than from a constant.
##
## The table used to carry two seconds. A free-for-all's `spawn_protection_sec` is 1.5
## and the horde's is 2.5, so the effect disagreed with [DotHealth] and with dot-spawn in
## every mode — in one direction in some and the other in the rest. Falls back to the old
## two seconds when there is no match to ask, which is what a self-test that builds the
## table alone gets.
func _protection_ticks() -> int:
	if game == null or game.match_node == null:
		return 2 * game.tick_rate if game != null else 0

	return game.match_node.spawn_protection_ticks()


static func table(rate: int, protection_ticks: int = 0) -> Array[DotEffectDef]:
	var burning := DotEffectDef.burning(BURNING, 4.0, 6 * rate)
	burning.tick_interval = rate / 2
	burning.damage_type = &"fire"
	burning.display_name = "Burning"
	burning.label = "FIRE"

	var empowered := DotEffectDef.damage_buff(EMPOWERED, 2.5, 20 * rate)
	empowered.display_name = "Empowered"
	empowered.label = "DMG"

	var haste := DotEffectDef.speed(HASTE, 1.35, 20 * rate)
	haste.display_name = "Haste"
	haste.label = "SPD"

	# Spawn protection as an effect rather than as DotHealth's own flag, because this
	# one has to stop the player CAPTURING as well: standing on a point, untouchable,
	# is not a fight anybody can have. dot-objective's may_capture_fn is why.
	var protected := DotEffectDef.invulnerability(
		PROTECTED, protection_ticks if protection_ticks > 0 else 2 * rate
	)
	protected.display_name = "Protected"
	protected.label = "INV"

	var slowed := DotEffectDef.speed(SLOWED, 0.7, 3 * rate)
	slowed.display_name = "Slowed"
	slowed.label = "SLOW"
	slowed.tags = PackedStringArray(["debuff"])

	return [burning, empowered, haste, protected, slowed]


# --- The seam ---------------------------------------------------------------

## dot-combat's per-hit hook. Mutates the damage in place, or refuses it.
func adjust_damage(damage: DotDamage) -> void:
	if manager == null or damage == null:
		return

	if manager.is_invulnerable(damage.victim):
		damage.refuse("invulnerable")
		return

	# [b]dot-spawn's ledger, asked here because this is the one hook there is.[/b]
	# `DotDamageResolver.adjust` is a single callable and this class owns it, so a second
	# subsystem that wants a veto is a line in this function rather than a second hook —
	# and a veto applied anywhere else is one applied at some damage sites and not
	# others, which is the bug this class's own documentation opens with.
	#
	# It agrees with the two gates above it by construction rather than by luck:
	# `ArenaPlayerStack.refresh_spawn_rules` takes the same `spawn_protection_sec` the
	# `PROTECTED` effect below is built from and [DotHealth] is given.
	if game.player_stack != null and game.player_stack.blocks_damage(
		str(damage.attacker), str(damage.victim), damage.tick, damage.is_world_damage()
	):
		damage.refuse("spawn protection")
		return

	var dealt := manager.damage_dealt_scale(damage.attacker)
	var taken := manager.damage_taken_scale(damage.victim)
	var scale := dealt * taken

	if is_equal_approx(scale, 1.0):
		return

	damage.scale_by(scale, "effects")


## Whether an entity may capture an objective. Handed to [DotObjectivePresence].
func may_capture(entity: int) -> bool:
	return manager == null or manager.may_capture(entity)


func move_scale(entity: int) -> float:
	return manager.move_speed_scale(entity) if manager != null else 1.0


# --- Applying ----------------------------------------------------------------

func apply(id: StringName, entity: int, source: int = 0) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Effects are not set up.")
	return manager.apply(id, entity, source)


func remove(id: StringName, entity: int) -> void:
	if manager == null:
		return
	var _res := manager.remove(id, entity)


func has(id: StringName, entity: int) -> bool:
	return manager != null and manager.has(entity, id)


func tick(_delta: float) -> void:
	if manager == null:
		return
	manager.advance(game.current_tick())
	_apply_movement()


## Movement effects reach the controller through its tunables.
##
## [b]Re-applied every tick from a base rather than multiplied in place.[/b] Scaling the
## live value each tick compounds — a 0.7 slow becomes 0.49 after two ticks and 0.0000
## after fifty — and the player then stops dead with every number about the effect
## correct. The base is the map's own tunables and the scale is re-derived from
## scratch, which is the only arrangement that survives an effect expiring.
func _apply_movement() -> void:
	for id in game.player_ids():
		var player := game.player_for(id)
		if player == null or player.controller == null:
			continue
		var tunables := player.controller.tunables
		if tunables == null:
			continue
		var scale := manager.move_speed_scale(id)
		# has_meta first: Object.get_meta's default parameter IS null, so passing null
		# explicitly is indistinguishable from passing nothing — and the engine pushes
		# "the object does not have any 'meta' values with the key" once per player per
		# tick. Four errors a tick on a four-player server buries every other line in
		# the log, which is the file docs/testing.md says to read.
		var base: Variant = (
			tunables.get_meta("arena_base_speed")
			if tunables.has_meta("arena_base_speed") else null
		)
		if base == null:
			base = tunables.max_speed
			tunables.set_meta("arena_base_speed", base)
		tunables.max_speed = float(base) * scale


func _on_damaged(entity: int, amount: float, type: StringName, source: int) -> void:
	if game.combat == null:
		return
	var health := game.combat.health_of(entity)
	if health == null:
		return

	var damage_type := game.combat.damage_type(type)
	if damage_type == null:
		damage_type = DotDamageType.new()
		damage_type.id = type

	# `damage.tick` is set explicitly, and it is not decoration: DotHealth refuses
	# anything at or before invulnerable_until_tick, and a DotDamage starts at tick 0 —
	# so an unstamped event is refused on every player for ever, silently. This family
	# found that one in game-playground's arena on its very first hit.
	var damage := DotDamage.make(source, entity, amount, damage_type)
	damage.tick = game.current_tick()
	var applied := health.apply(damage)

	if applied != null and applied.lethal:
		game.combat.entity_killed.emit(entity, applied)


func _on_healed(entity: int, amount: float, overheal: bool, _source: int) -> void:
	if game.combat == null:
		return
	var health := game.combat.health_of(entity)
	if health == null:
		return
	var _got := health.heal(amount)
	if overheal:
		var _temp := manager.grant_temp(entity, amount)


# --- What the game reports ----------------------------------------------------

func on_death(entity: int) -> void:
	if manager != null:
		manager.on_death(entity)


func on_spawn(entity: int) -> void:
	if manager == null:
		return
	manager.on_death(entity)  # clears whatever survived the round
	manager.stand_up(entity, true)
	var _res := manager.apply(PROTECTED, entity, entity)


func on_round_reset() -> void:
	if manager != null:
		manager.on_round_reset()


func forget(entity: int) -> void:
	if manager != null:
		manager.forget(entity)


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["effects: not set up"])
	return manager.describe_lines()
