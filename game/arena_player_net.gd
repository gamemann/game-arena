extends DotNetBehaviour

const ArenaNetBridge := preload("res://game/arena_net_bridge.gd")
const ArenaNetCommand := preload("res://game/arena_net_command.gd")
const ArenaPlayer := preload("res://game/arena_player.gd")

## The thirty lines dot-player-controller and dot-combat each say belong in the game.
##
## [b]Neither addon may name a dot-net class.[/b] A script that so much as mentions a
## missing [code]class_name[/code] fails to parse and takes every script that
## references it down with it, so dot-player-controller has to compile with dot-core
## alone. What each addon ships instead is a [code]*NetSync[/code] class describing
## what to replicate as data — property names, and type names as strings. Resolving
## those strings against [code]DotNetVar.Type[/code] is this file's job, and it is the
## only place in game-arena where the two halves meet.
##
## One behaviour rather than two, because one entity is one player: a second behaviour
## would mean a second set of per-peer baselines and a second declaration block on the
## wire for state that always changes together.

## The player this replicates. Set by [ArenaNetBridge] before registration.
var player: ArenaPlayer = null

## The bridge, so the authority can drive the whole game exactly once per tick.
var bridge: ArenaNetBridge = null

# --- Movement, from DotFpsNetSync.state_specs() ---
var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

# --- Health from DotCombatNetSync, weapons from DotWeaponNetSync ---
var net_health: int = 0
var net_armour: int = 0
var net_alive: bool = false
var net_slot: int = 0
var net_magazine: int = 0
var net_reserve: int = 0

## The last command received, retained.
##
## [b]Retained rather than cleared, and that is the documented behaviour of a starved
## tick.[/b] A player whose input packet was lost should keep moving in a straight
## line rather than stopping dead and jerking forward when the next one arrives.
## [DotFpsController.simulate_tick] says the same thing about its own
## [code]current_command[/code]; holding it here means a netted player gets that
## behaviour through [method ArenaGame.tick], which substitutes a zeroed command for a
## player with no entry.
var last_move: DotFpsCommand = DotFpsCommand.new()
var last_fire: DotWeaponCommand = DotWeaponCommand.new()

## Newest tick whose state this behaviour has adopted. Client side, for reconciliation.
var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if spec["property"] == &"net_crouch":
			# DotNetVar's default quantisation range is -1..1 and the crouch fraction
			# is 0..1, so half the codes would encode a value the property cannot
			# hold. Six bits over the real range is the ~1.5% the spec's comment
			# claims; over the default range it would be 3%.
			declaration.range_of(0.0, 1.0)

	for spec in DotCombatNetSync.specs() + DotWeaponNetSync.specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["owner_only"]):
			# Not a bandwidth optimisation: exact ammunition is information an
			# opponent should not have, and a modified client that had it would know
			# when to push. Data never sent cannot be read out of a client.
			declaration.to_owner_only()


# --- Input -----------------------------------------------------------------

## Takes one tick of a peer's intent. Server side, and the replay half of
## reconciliation.
##
## Already sanitised: [method DotNetManager._apply_input] calls
## [method DotNetInput.sanitise] before this runs, on the server, because everything
## in it came from a client.
func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as ArenaNetCommand

	if command == null:
		return

	last_move = command.move
	last_fire = command.fire


# --- Simulation ------------------------------------------------------------

## Advances this player by one tick, on whichever machine is entitled to.
##
## [b]The two sides do not take the same route, and they must not.[/b]
##
## On the authority the whole game has to tick as one: [method ArenaGame.tick] moves
## everybody, then resolves every shot against the world as it is after everyone has
## moved, then ticks the match. Simulating one player here and resolving their shot
## before the next player has moved would put half a tick of movement — fifteen
## centimetres at arena speeds — between the shot and its target. So the first
## behaviour to reach this on a given tick drives the entire game, and the rest find
## it already done and only copy their own state out.
##
## On a predicting client there is exactly one predicted player — this one — so
## calling [method ArenaPlayer.simulate_tick] directly is not a shortcut, it is the
## whole of what a client is entitled to compute. Its shots are discarded: the server
## resolves hits, and a client that resolved its own would be a client that decides
## whether it hit.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		player.simulate_tick(tick, delta, last_move, last_fire)

	pull()


## Copies the simulation into the replicated properties.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)
	DotCombatNetSync.pull(player.health, self)
	DotWeaponNetSync.pull(player.arsenal, self)


## Copies received state back into the simulation. Receiving side.
##
## Runs for a remote player, where it is the only thing that moves them, and for the
## owning client, where it is the rewind half of reconciliation — the server's answer
## is adopted wholesale and [DotNetPredictor] replays every unacknowledged command on
## top of it. Everything the simulation reads has to be restored, which is why
## [DotFpsNetSync.push] takes the whole [DotFpsState] rather than a position.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return

	last_state_tick = tick

	DotFpsNetSync.push(self, player.controller.state)
	DotCombatNetSync.push(self, player.health)
	DotWeaponNetSync.push(self, player.arsenal)

	# The controller writes its state out to the body node during simulation, and a
	# receiving client does not simulate this player. Without this the state moves and
	# the node — and so the view, the muzzle and the hitboxes hanging off it — stays
	# where it spawned.
	#
	# [b]But NOT on a predicted entity, which is the local player.[/b]
	# `DotNetManager.receive_snapshot` calls `read_state` — and therefore this — BEFORE
	# `DotNetPredictor.reconcile`, and the first thing reconcile does is read the node
	# as "what the client is showing" so it can measure the correction. Writing the
	# server's position here first makes that measurement the entire replay distance:
	# every reconciliation logs a snap, `correction_rate()` reads near 1.0, and the
	# simulation is right the whole time. game-hungario had this exact line and the
	# family's notes have named it as unfixed here ever since; nothing in this
	# repository could see it, because `headless_net` drives the bridge directly and
	# there has never been a client to feel it.
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position

	if not player.health.alive and player.hitboxes.enabled:
		# The server's word that this player is dead. `make_dead` is what takes them
		# out of play locally; leaving the hitboxes on would let a client draw hits on
		# a corpse the server has already removed.
		player.make_dead()
	elif player.health.alive and not player.hitboxes.enabled:
		player.hitboxes.enabled = true
		player.arsenal.disabled = false


## Copies the interpolated state onto the player, every frame, on a remote one.
##
## [b]Without this the interpolator's work is thrown away.[/b]
## [method _net_state_applied] runs when a snapshot arrives — 20 times a second — and it is
## the only other place these properties are read. A remote player driven only by that
## moves in 50 ms steps, with the smoothed value sitting in a property nothing reads, and
## the symptom is an interpolator that appears not to work.
##
## Deliberately not the bookkeeping half. [member last_state_tick] is what reconciliation
## rewinds to and the tick here is a *render* tick, behind the server's. dot-net does not
## call this on a predicted entity, which is why the predictor is not fought.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


func describe() -> Dictionary:
	return {
		"player": player.player_id if player != null else 0,
		"position": net_position,
		"health": net_health,
		"alive": net_alive,
		"slot": net_slot,
		"state_tick": last_state_tick,
	}
