extends Node

const ArenaContent := preload("arena_content.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaNpcs := preload("arena_npcs.gd")
const ArenaStats := preload("arena_stats.gd")

## Monsters in the arena: dot-npc, dot-npc-ai and dot-npc-ai-director, joined to
## dot-combat.
##
## [b]The three NPC addons deliberately know nothing about damage, and this is the file
## that pays for it.[/b] dot-npc ships a `damage` method for a game with no combat
## layer and hands the job to the game when there is one; dot-combat has never heard of
## an NPC and only knows entity ids, hitboxes and health. Twenty lines join them, and
## they are these — plus one rule about id spaces that is the whole reason this works
## at all.
##
## [b]An NPC's combat entity id comes from [DotEntityTable] and carries its kind.[/b]
## [ArenaPlayer] still uses the dot-server session id as its entity id, which is a
## small integer; a monster used to use its own engine instance id modulo a million,
## which collides with another monster rather than with a player -- and the symptom of
## that is a monster that stops taking damage, not a shot that kills somebody else.
## Table serials cannot collide and [method is_npc_entity] asks the id what it is
## instead of comparing it against a constant.
##
## [codeblock]
## var horde := ArenaHorde.new()
## horde.game = game
## add_child(horde)
## horde.setup()
## horde.enabled = true
## [/codeblock]
##
## [b]Server-authoritative and unpredicted[/b], for dot-props' reason twice over: a
## brain runs a behaviour tree against a blackboard with lifetimes on it, which is not
## something two machines reproduce from the same inputs.

const CHANNEL := "arena.horde"

## The registry name a brain reaches this through. See `arena_npc_brain.gd`.
const SERVICE := &"arena_horde"

## Where a monster's combat entity id comes from. See [DotEntityTable].
##
## [b]This replaces a scheme that could collide, silently, and lose a monster its
## health.[/b] It was `ENTITY_BASE + (npc.instance_id % ENTITY_BASE)` with
## `ENTITY_BASE = 1_000_000` -- and the engine's instance ids are neither small nor
## dense, so two monsters whose ids differ by a multiple of a million produce one
## entity id. The second `register_health` then overwrites the first and the loser
## simply stops taking damage. Nothing errors, and nothing could: a health record
## registered twice under one key is a legitimate thing for a dictionary to hold.
##
## Serials from a table cannot do that, and they carry their kind, so
## [method is_npc_entity] is a real question rather than a range check.
##
## [b]The old comment's constraint still holds and is worth keeping.[/b] An entity id
## travels through a [DotDamage] and a scoreboard key as text and back, so it has to
## stay below the point where a float stops counting integers exactly. A monster id is
## `2 * 10^12 + serial`; the limit is 2^53, about 9 * 10^15, which leaves three orders
## of magnitude. It is also a million times further above any plausible session id than
## the old constant was, which is what keeps the player half of this game -- where an
## entity id IS a session id -- unable to collide with it.
##
## [b]The player half is deliberately NOT converted, and that is a measured decision
## rather than an oversight.[/b] In this game an entity id and a session id are the
## same integer, and seven things depend on it: dot-match scoreboard keys, dot-effects'
## per-entity scales, dot-stats rows, dot-spectate, the player-stack roster, the kill
## feed on the wire, and the client that rebuilds one from two ints it was sent.
## Moving players onto the table means translating at every one of those boundaries in
## the same pass -- and dot-effects is keyed from BOTH spaces today
## (`damage_taken_scale(damage.victim)` against `move_speed_scale(session_id)`), so a
## half-done conversion is an effect layer that silently stops applying to damage.
## Monsters were the half that was broken; they are the half that moved.

## A monster died. Carries the killer's player id, or 0 for the world.
signal npc_killed(npc: DotNpcInstance, killer_id: int)

## A wave was placed. For a HUD, and for a test that needs to know it happened.
signal wave_spawned(at: Vector3, count: int)

@export_group("Pacing")

## Whether the director spawns anything at all.
##
## Off by default. A deathmatch is a deathmatch; monsters are a mode, and
## [member ArenaMode.id] is what turns them on.
@export var enabled: bool = false

## Metres between the spawn points taken from the navigation graph.
##
## [b]Not a nicety.[/b] [method DotNpcDirector.choose_spawn_point] walks every
## candidate and raycasts from each player to the ones inside the distance band, so an
## unthinned two-metre grid over a forty-metre arena is a few thousand raycasts per
## wave, several times a minute, on the server.
@export_range(2.0, 40.0, 1.0) var spawn_spacing: float = 7.0

var game: ArenaGame = null

var spawner: DotNpcSpawner = null
var director: DotNpcDirector = null
var senses: DotNpcSenses = null

## The graph the monsters walk on, rebuilt on every map change.
var nav: DotNpcNavData = null

## Where the monsters' nodes go. A child of this, so a map change frees one node.
var _world: Node3D = null

## entity id -> [DotNpcInstance]. The combat side of the id space.
var _by_entity: Dictionary = {}

## entity id -> [DotHitboxSet], so a monster can be shot.
var _hitboxes: Dictionary = {}

## The players as perception candidates, rebuilt once per tick.
##
## Once per tick and not once per monster: forty monsters each building their own list
## of sixteen players is six hundred allocations a tick to answer one question.
var _candidates: Array = []

var _registered: bool = false


func _exit_tree() -> void:
	if _registered:
		DotRegistry.unregister_instance(SERVICE, self)
		_registered = false


## Builds the spawner, the director and the navigation over the game's current map.
func setup() -> DotResult:
	if game == null or game.combat == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The horde needs a game that has been set up."
		)

	_world = Node3D.new()
	_world.name = "Monsters"
	add_child(_world)

	senses = DotNpcSenses.new()
	senses.switch_ratio = 0.55
	senses.commitment_grace = 3.0
	# Off. This game's collision is analytic — there is no physics space on a
	# dedicated server for a raycast to travel through — so a line-of-sight test would
	# answer "clear" for every pair and cost a query per candidate per monster to do
	# it. The definitions still carry `require_line_of_sight`, because a listen server
	# with a physics space is a different deployment and this is one assignment.
	senses.line_of_sight_enabled = false

	spawner = DotNpcSpawner.new()
	spawner.name = "Npcs"
	spawner.catalogue = ArenaNpcs.catalogue()
	spawner.limits = ArenaNpcs.limits()
	spawner.authoritative = game.is_authority
	spawner.world_ref = DotNodeRef.of_path(NodePath("../Monsters"))
	spawner.smooth_paths = true
	spawner.allow_partial_paths = true
	# Before add_child, and it has to be: DotNpcSpawner._ready makes its own senses
	# when it finds none, so assigning afterwards leaves this one built, configured
	# and read by nobody — with the spawner running on defaults that look identical
	# until a monster refuses to give up on somebody behind a pillar.
	spawner.senses = senses
	add_child(spawner)

	spawner.spawned.connect(_on_spawned)
	spawner.removed.connect(_on_removed)
	spawner.died.connect(_on_died)

	director = DotNpcDirector.new()
	director.name = "Director"
	director.spawner = spawner
	director.rules = _rules()
	director.population = [ArenaNpcs.GRUNT, ArenaNpcs.STALKER, ArenaNpcs.BRUTE]
	director.enabled = enabled
	add_child(director)

	director.wave_spawned.connect(
		func(at: Vector3, count: int) -> void: wave_spawned.emit(at, count)
	)

	var built := rebuild_navigation()

	if not built.ok:
		return built

	# The game's kills come through here, not through dot-match. A monster is not on
	# the scoreboard and must never be given a row on it.
	game.non_player_killed.connect(_on_entity_killed)
	game.map_changed.connect(_on_map_changed)

	DotRegistry.register(SERVICE, self)
	_registered = true

	return DotResult.success(self)


## Regenerates the graph and the spawn points for the game's current map.
##
## [b]Called on every map change, and the digest is why it can be trusted.[/b]
## [method DotNpcNavData.matches] distinguishes "a graph for this map" from "a graph
## for a map with the same name" — the second being a graph whose monsters walk
## through the walls somebody added since.
func rebuild_navigation() -> DotResult:
	if game == null or game.map == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no map to navigate.")

	nav = ArenaNpcs.nav_for(game.map)

	var valid := nav.validate()

	if not valid.ok:
		return valid.wrap("The arena navigation graph is not usable")

	var applied := spawner.set_nav_data(nav)

	if not applied.ok:
		return applied

	# Walking only, so a horde does not try to stand on a ledge the generator marked
	# as somewhere to avoid.
	var kept := director.set_spawn_points_from_nav(
		nav, spawn_spacing, DotNpcNavFilter.walking_only()
	)

	if kept <= 0:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The map produced no navigable spawn points.",
			String(game.map.id)
		)

	DotLog.info(CHANNEL, "navigation built", {
		"map": String(game.map.id),
		"points": nav.point_count(),
		"edges": nav.edge_count(),
		"spawns": kept,
	})

	return DotResult.success(kept)


## What a horde's pacing looks like in a room rather than in a campaign.
func _rules() -> DotNpcDirectorRules:
	var rules := DotNpcDirectorRules.new()

	rules.peak_per_player = 8.0
	rules.build_up_per_player = 3.5
	rules.relax_per_player = 1.0
	rules.absolute_cap = 36

	rules.peak_stress = 0.7
	rules.sustain_seconds = 5.0
	rules.fade_seconds = 7.0
	rules.relax_seconds = 20.0

	# An arena is forty metres across, so the co-operative survival shooters' "spawn
	# seventy metres ahead along the critical path" is off the map. These are one room's distances, and
	# there is no route to spawn ahead along — a deathmatch has no direction of
	# travel, which is why `spawn_ahead` is small rather than absent: the director
	# still prefers to put a wave where the fight is going rather than behind it.
	rules.spawn_min_distance = 12.0
	rules.spawn_max_distance = 34.0
	rules.spawn_ahead = 8.0
	rules.behind_fraction = 0.35
	rules.spawn_out_of_sight = false

	rules.spawn_burst = 3
	rules.spawn_interval = 0.6
	rules.reclaim_interval = 3.0

	rules.stress_per_damage = 1.1
	rules.stress_threat_radius = 7.0

	return rules


# --- The tick --------------------------------------------------------------

## Advances the whole horde one tick. Called from the game's tick, never a frame clock.
##
## [b]The order matters the same way the game's does.[/b] The candidate list is rebuilt
## first so every monster perceives where the players are AFTER they moved this tick;
## the spawner ticks next, which is what runs perception and every brain; the director
## last, because what it decides to spawn depends on the stress the tick just produced.
func tick(delta: float) -> void:
	if spawner == null or game == null:
		return

	_rebuild_candidates()
	spawner.set_candidates(_candidates)
	spawner.tick(delta)

	if director == null:
		return

	director.enabled = enabled

	for player in game.players():
		if not player.is_alive():
			continue

		director.report_player(
			StringName(str(player.player_id)),
			player.controller.state.position,
			player.health.health / maxf(player.health.max_health, 1.0)
		)

	director.tick(delta)


func _rebuild_candidates() -> void:
	_candidates.clear()

	for player in game.players():
		if not player.is_alive():
			continue

		var state := player.controller.state

		# Loudness as a radius, which is the number this game already has: a running
		# player is heard further than a still one, and a crouching one barely at all.
		var speed := state.horizontal_speed()
		var loudness := 0.0 if speed < 0.5 else lerpf(4.0, 18.0, clampf(speed / 9.0, 0.0, 1.0))

		if state.is_crouched():
			loudness *= 0.4

		_candidates.append(DotNpcSenses.Candidate.new(
			StringName(str(player.player_id)),
			state.position + Vector3(0.0, 0.9, 0.0),
			&"player",
			loudness
		))


# --- Combat ----------------------------------------------------------------

## The combat entity id for a monster, or 0 when it has none.
##
## [b]A lookup now, not a formula.[/b] It was derived from the node's engine instance
## id, which is what made two monsters able to share an id; the table holds the
## node -> id direction so nothing has to derive anything.
func entity_id_for(npc: DotNpcInstance) -> int:
	if npc == null or game == null:
		return 0

	return game.entities.id_for_node(npc.node)


## Whether an entity id belongs to a monster rather than to a player.
##
## [b]A kind test rather than a range check.[/b] The id says what it names; this used
## to be `entity_id >= ENTITY_BASE`, which is a promise about a constant rather than a
## fact about the id, and it was the only thing standing between the two id spaces.
static func is_npc_entity(entity_id: int) -> bool:
	return DotEntity.is_kind(entity_id, DotEntity.KIND_NPC)


## A monster hitting a player. Called by the brain, through [DotRegistry].
##
## [b]It goes through dot-combat rather than through [DotHealth] directly.[/b] The
## resolver is what applies armour, the damage type's rules, spawn protection and the
## friendly-fire check, and a hit that skipped it would ignore all four — including
## spawn protection, which is the one whose absence a player notices immediately.
func npc_attack(npc: DotNpcInstance, victim_key: StringName, amount: float) -> void:
	if game == null or game.combat == null or npc == null or not npc.is_alive():
		return

	var victim := String(victim_key).to_int()
	var player := game.player_for(victim)

	if player == null or not player.is_alive():
		return

	var type := game.combat.damage_type(ArenaContent.DAMAGE_WORLD)

	if type == null:
		return

	var damage := DotDamage.make(entity_id_for(npc), victim, amount, type)
	damage.weapon_id = npc.def.id if npc.def != null else &"monster"
	game.combat.apply_damage(damage)


## Registers a monster as shootable and damageable.
##
## Both halves, and they are separate calls in dot-combat: hitboxes make it hittable,
## health makes it damageable. One without the other is a monster shots pass through,
## or one that takes hits and never dies.
##
## [b]The health is dot-combat's and the health dot-npc holds is a mirror.[/b] Two
## authorities over one number is how a monster ends up dying twice — once to the
## resolver and once to the spawner — so [method _on_health_changed] is the only writer
## on the dot-npc side.
func _register_combat(npc: DotNpcInstance) -> void:
	var opened := game.entities.open(
		DotEntity.KIND_NPC,
		npc.node,
		&"",
		&"",
		float(game.current_tick()) / float(maxi(game.tick_rate, 1))
	)

	if not opened.ok:
		# The table refuses a node that is already an entity, which is the collision
		# the old scheme produced in silence. Refusing to register a second time is
		# the whole point; registering anyway is what used to cost a monster its
		# health.
		DotLog.error(CHANNEL, "could not open an entity for a monster", {
			"npc": String(npc.def.id) if npc.def != null else "?",
			"why": opened.error.message,
		})
		return

	var entity: int = (opened.value as DotEntityHandle).id
	var def := npc.def

	var set_node := DotHitboxSet.new()
	set_node.name = "Hitboxes"
	set_node.bounds_offset = Vector3(0.0, 0.9, 0.0)
	set_node.bounds_radius = 2.4

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.22
	head.position = Vector3(0.0, 1.5, 0.0)
	# Higher than the body's, so the shared surface between the two resolves to the
	# head every time rather than about half the time. Same reason ArenaPlayer does it.
	head.precedence = 10
	set_node.add_child(head)

	var body := DotHitbox.new()
	body.name = "Body"
	body.group = DotHitGroup.CHEST
	body.shape = DotHitbox.Shape.CAPSULE
	body.radius = 0.5
	body.height = 1.4
	body.position = Vector3(0.0, 0.8, 0.0)
	set_node.add_child(body)

	npc.node.add_child(set_node)

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = def.max_health if def != null else 100.0
	health.max_armour = 0.0
	health.regen_per_second = 0.0
	health.set_tick_rate(game.tick_rate)
	npc.node.add_child(health)
	health.reset(game.current_tick())

	set_node.register_with(game.combat, entity)
	game.combat.register_health(entity, health)
	game.combat.set_authoritative_origin(entity, npc.position())

	_by_entity[entity] = npc
	_hitboxes[entity] = set_node


func _forget_combat(npc: DotNpcInstance) -> void:
	var entity := entity_id_for(npc)

	if entity == 0:
		return

	if game != null and game.combat != null and is_instance_valid(game.combat):
		game.combat.forget(entity)

	# After the two erases read it, and after dot-combat has been told. The lookup
	# above goes through the table, so closing first would make `entity` unreachable
	# for everything below -- which is the ordering dot-entity's own notes warn about
	# and the reason `close()` never frees a node itself.
	if game != null:
		game.entities.close(entity, DotEntityTable.REASON_KILLED)

	_by_entity.erase(entity)
	_hitboxes.erase(entity)


# --- Events ----------------------------------------------------------------

func _on_spawned(npc: DotNpcInstance) -> void:
	_register_combat(npc)


func _on_removed(npc: DotNpcInstance, _reason: StringName) -> void:
	_forget_combat(npc)


func _on_died(npc: DotNpcInstance, by: StringName) -> void:
	var killer := String(by).to_int()
	npc_killed.emit(npc, killer)

	# The kill counts for the player who made it, and only for a player. A monster
	# that killed another monster — splash damage does this — must not be credited to
	# anybody, and `to_int()` on a monster's entity id gives a number whose KIND is
	# NPC, which is what the test is for.
	if game != null and game.progress != null and killer > 0 and not is_npc_entity(killer):
		if game.player_for(killer) != null:
			game.progress.record(killer, ArenaStats.NPC_KILLS)


## A combat entity that is not a player was killed.
##
## dot-combat owns the health and decided the death; the spawner has to be told so it
## frees the node, runs the brain's `died` hook and gives the budget back. Reporting
## it rather than calling [method DotNpcSpawner.remove] is what makes the brain's last
## chance to act actually happen.
func _on_entity_killed(entity_id: int, damage: DotDamage) -> void:
	if not is_npc_entity(entity_id):
		return

	var npc: DotNpcInstance = _by_entity.get(entity_id)

	if npc == null:
		return

	spawner.report_death(npc.instance_id, StringName(str(damage.attacker)))


func _on_map_changed(_map: ArenaMap) -> void:
	# Every monster belonged to the world that was just replaced. Their nodes are
	# children of this node rather than of the map, so nothing freed them — and a
	# monster left standing where a wall now is, on a graph built for the old
	# geometry, is worse than no monsters at all.
	if spawner != null:
		spawner.clear_all(DotNpcSpawner.REASON_CLEANUP)

	var rebuilt := rebuild_navigation()

	if not rebuilt.ok:
		DotLog.warn(CHANNEL, "the horde has no navigation for the new map", {
			"why": rebuilt.error.message
		})
		enabled = false


# --- Admin -----------------------------------------------------------------

## Places one monster by hand. What an admin command calls.
func spawn_one(npc_id: StringName, at: Vector3) -> DotNpcInstance:
	return spawner.spawn(npc_id, at) if spawner != null else null


func clear() -> int:
	return spawner.clear_all(DotNpcSpawner.REASON_ADMIN) if spawner != null else 0


func count() -> int:
	return spawner.world_count() if spawner != null else 0


func describe() -> Dictionary:
	return {
		"enabled": enabled,
		"monsters": count(),
		"nav": nav.describe() if nav != null else {},
		"spawner": spawner.describe() if spawner != null else {},
		"director": director.describe() if director != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("horde     %s  %d monster(s)" % ["on" if enabled else "off", count()])

	if spawner != null:
		out.append_array(spawner.describe_lines())

	if director != null:
		out.append_array(director.describe_lines())

	return out
