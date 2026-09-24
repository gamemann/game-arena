extends RefCounted

const ArenaEffects := preload("arena_effects.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaPlayer := preload("arena_player.gd")

## What dot-moderation's live tools mean in a deathmatch.
##
## [b]Every verb here is a few lines, because each is an addon's own seam.[/b] Noclip,
## freeze, speed and gravity are dot-player-controller's `DotFpsAdminModifiers`, which the
## owning client predicts rather than rubber-bands against; god and buddha are two flags on
## dot-combat's `DotHealth`; slay and slap are ordinary `DotDamage` through the combat
## manager, so the kill feed, the scoreboard and the stats hear about them the way they
## hear about a rocket; respawn is the match's own respawn path; burn is dot-effects' own
## burning. Nothing here is a second rule about any of those.
##
## Blind and beacon are the two that are about a SCREEN rather than a body, and each is one
## flag on [ArenaPlayer] that `ArenaPlayerNet` replicates — the blind to its owner alone,
## the beacon to everybody — and that the client draws: `ArenaHud` blacks the owner's
## screen out, `ArenaBeacon` rings the player on every screen and pings. The server decides;
## nothing about either is a client's to choose.
##
## Ids are the session userid as a string, which is `ArenaPlayer.player_id` — the one id
## space this game has. See the project's CLAUDE.md.

## The damage type a slay or a slap carries. Empty is dot-combat's generic type, which
## armour does not absorb and nothing multiplies — an admin's slap for 10 is 10.
const WORLD_DAMAGE := &""

## How hard a slap shoves, in m/s. Enough to take somebody off a ledge, not off the map.
const SLAP_PUSH := 6.0
const SLAP_LIFT := 5.0

## The ceiling `hp` sets. Health travels as an 11-bit integer (DotCombatNetSync), so a
## value above 2047 would arrive on the client as something else entirely.
const MAX_HEALTH := 2000.0


## The handler table, `{ability: Callable}`.
static func handlers(game: ArenaGame) -> Dictionary:
	return {
		DotModTools.ACTION_NOCLIP: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			return DotFpsAdminModifiers.set_noclip(player.controller, bool(args["on"])),

		DotModTools.ACTION_FREEZE: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			var on := bool(args["on"])
			# A frozen player cannot shoot either. Held still with a working rifle is a
			# turret, which is the opposite of what a freeze is for.
			if player.is_alive():
				player.arsenal.disabled = on
			return DotFpsAdminModifiers.set_frozen(player.controller, on),

		DotModTools.ACTION_GOD: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.health.invulnerable = bool(args["on"])
			return DotResult.success(player.health.invulnerable),

		DotModTools.ACTION_BUDDHA: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.health.cannot_die = bool(args["on"])
			return DotResult.success(player.health.cannot_die),

		DotModTools.ACTION_SLAY: func(id: StringName, _args: Dictionary) -> DotResult:
			return slay(game, id),

		DotModTools.ACTION_SLAP: func(id: StringName, args: Dictionary) -> DotResult:
			return slap(game, id, float(args.get("damage", 0.0))),

		DotModTools.ACTION_RESPAWN: func(id: StringName, _args: Dictionary) -> DotResult:
			return game.respawn_player(int(String(id))),

		DotModTools.ACTION_HEALTH: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			if not player.is_alive():
				return DotResult.fail(DotError.CODE_STATE, "They are dead. Respawn them first.")
			player.health.health = minf(float(args["value"]), MAX_HEALTH)
			return DotResult.success(player.health.health),

		DotModTools.ACTION_SPEED: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			return DotFpsAdminModifiers.set_speed(player.controller, float(args["scale"])),

		DotModTools.ACTION_GRAVITY: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			return DotFpsAdminModifiers.set_gravity(player.controller, float(args["scale"])),

		DotModTools.ACTION_GIVE: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			var item := StringName(str(args["item"]).strip_edges().to_lower())
			if not player.arsenal.catalogue.has(item):
				return DotResult.fail(
					DotError.CODE_INVALID, "There is no weapon called %s." % String(item),
					", ".join(item_ids(game))
				)
			return player.arsenal.give(item),

		DotModTools.ACTION_STRIP: func(id: StringName, _args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.arsenal.clear()
			return DotResult.success(null),

		DotModTools.ACTION_RENAME: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			var new_name := str(args["name"]).strip_edges().substr(0, 32)
			player.display_name = new_name
			# The scoreboard keeps its own copy, and a rename that stopped at the body is
			# a player called one thing on the board and another in the kill feed.
			var record := game.match_node.scoreboard.find(str(player.player_id))
			if record != null:
				record.display_name = new_name
			return DotResult.success(new_name),

		DotModTools.ACTION_BURN: func(id: StringName, _args: Dictionary) -> DotResult:
			if _player(game, id) == null:
				return _absent(id)
			if game.effects == null:
				return DotResult.fail(DotError.CODE_UNSUPPORTED, "This server has no status effects.")
			# The map's own fire, for its own duration: an admin's burn is the same
			# afterburn a plasma splash leaves, so it hurts exactly as much as it looks.
			return game.effects.apply(ArenaEffects.BURNING, int(String(id)), 0),

		DotModTools.ACTION_BLIND: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			# The screen and nothing else. A blinded player still moves, shoots and is
			# shot; an admin who wants them to stop as well has freeze, and one verb that
			# did both would be a verb nobody could use for only the first.
			player.blinded = bool(args["on"])
			return DotResult.success(player.blinded),

		DotModTools.ACTION_BEACON: func(id: StringName, args: Dictionary) -> DotResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.beacon = bool(args["on"])
			return DotResult.success(player.beacon),
	}


## Why the rest are refused. Nothing is, now that blind and beacon have a client to draw
## them; kept as a table because a new dot-moderation ability arrives unsupported, and the
## place its reason goes is here.
static func unsupported() -> Dictionary:
	return {}


## Toggles that outlive a respawn here, beyond dot-moderation's own god and buddha.
##
## [b]Blind and beacon are about the person, not the body.[/b] Freeze and noclip end with
## the body because arriving in a spawn room frozen, or falling through its floor, is the
## respawn broken; a player an admin blinded or wanted the room to watch is still that
## player after they die, and a death is exactly what a player being punished would
## otherwise use to end it.
const PERSIST_ON_RESPAWN: Array[String] = ["blind", "beacon"]


## What `give` can hand out, for its completion and its refusal.
static func item_ids(game: ArenaGame) -> PackedStringArray:
	var out := PackedStringArray()

	for player in game.players():
		for id in player.arsenal.catalogue.ids():
			out.append(String(id))
		break

	return out


static func position_of(game: ArenaGame, id: StringName) -> Variant:
	var player := _player(game, id)
	return player.controller.state.position if player != null else null


## A teleport keeps where they are looking, which is what makes a bring readable: the
## player lands facing the way they were, not snapped to north.
static func teleport(game: ArenaGame, id: StringName, to: Variant) -> void:
	var player := _player(game, id)

	if player == null or not (to is Vector3):
		return

	player.controller.teleport(to as Vector3, player.controller.state.yaw, player.controller.state.pitch)


## Kills a player through the combat manager, whatever protects them.
##
## God, buddha and spawn protection are all switched off for the one event and put back,
## because a slay that god mode refused would make god mode a way to be unslayable — and
## the god flag must survive it, since the tools re-apply it on the respawn. Spawn
## protection is three records: `DotHealth`'s window is cleared here, and the effect and
## the spawn ledger let the damage through on [constant ArenaEffects.ADMIN_KILL].
static func slay(game: ArenaGame, id: StringName) -> DotResult:
	var player := _player(game, id)

	if player == null:
		return _absent(id)

	if not player.is_alive():
		return DotResult.fail(DotError.CODE_STATE, "They are already dead.")

	var was_god := player.health.invulnerable
	var was_buddha := player.health.cannot_die
	player.health.invulnerable = false
	player.health.cannot_die = false
	player.health.invulnerable_until_tick = -1

	var damage := DotDamage.make(
		0, player.player_id, player.health.health + player.health.armour * 4.0 + 1000.0,
		game.combat.damage_type(WORLD_DAMAGE)
	)
	damage.weapon_id = &"slay"
	damage.tick = game.current_tick()
	# The other two thirds of spawn protection — the effect and the ledger — are vetoes in
	# `ArenaEffects.adjust_damage`, and this is how that hook knows to let it through.
	damage.context[ArenaEffects.ADMIN_KILL] = true
	game.combat.apply_damage(damage)

	player.health.invulnerable = was_god
	player.health.cannot_die = was_buddha

	if not damage.lethal:
		return DotResult.fail(DotError.CODE_STATE, "The slay was refused: %s" % damage.refusal)

	return DotResult.success(null)


## A shove, and optionally some damage.
##
## The push is written into the SIMULATED velocity, which replicates: the owning client
## reconciles to it on the next snapshot and replays from there, so the slap is felt as a
## shove rather than as a snap. The direction comes from the tick, not from a random
## stream — it only has to be different each time, and a slap that could be replayed
## differently is a slap two machines disagree about.
static func slap(game: ArenaGame, id: StringName, amount: float) -> DotResult:
	var player := _player(game, id)

	if player == null:
		return _absent(id)

	if not player.is_alive():
		return DotResult.fail(DotError.CODE_STATE, "They are dead.")

	var angle := deg_to_rad(float((game.current_tick() * 137) % 360))
	var state := player.controller.state
	state.velocity += Vector3(sin(angle) * SLAP_PUSH, SLAP_LIFT, cos(angle) * SLAP_PUSH)
	state.mode = DotFpsState.Mode.AIR

	if amount > 0.0:
		var damage := DotDamage.make(0, player.player_id, amount, game.combat.damage_type(WORLD_DAMAGE))
		damage.weapon_id = &"slap"
		damage.tick = game.current_tick()
		game.combat.apply_damage(damage)

	return DotResult.success(state.velocity)


static func _player(game: ArenaGame, id: StringName) -> ArenaPlayer:
	if game == null or not String(id).is_valid_int():
		return null

	return game.player_for(String(id).to_int())


static func _absent(id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_STATE, "Player %s is not in the match." % String(id))
