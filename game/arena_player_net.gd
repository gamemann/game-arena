extends DotNetBehaviour

const ArenaContent := preload("arena_content.gd")
const ArenaNetBridge := preload("arena_net_bridge.gd")
const ArenaNetCommand := preload("arena_net_command.gd")
const ArenaPlayer := preload("arena_player.gd")

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

# --- zee-dot-weapons' four, from ZeeWeaponNet.specs() ---
var net_fire_seq: int = 0
var net_fire_kind: int = 0
var net_reloading: bool = false
var net_switching: bool = false

# --- Which weapon, and what is carried ---

## The weapon in hand, as `ArenaContent.weapon_index`. Everybody's.
##
## [b]`net_slot` cannot say this, and could while there were four weapons.[/b] A slot is
## where a weapon is carried, and the pack puts nine primaries in slot 3; a watcher told
## "slot 3" knows somebody is holding a rifle-shaped thing and not which one to draw. Five
## bits, and nothing on a tick it did not change.
var net_weapon: int = 0

## Everything carried, one bit per weapon (`ArenaContent.carry_mask`). OWNER ONLY.
##
## What fills a connected client's own arsenal, which nothing did. Owner-only for the
## ammunition's reason: what somebody else is carrying in the slots they are not holding
## is information an opponent should not have.
var net_carry: int = 0

# --- An administrator's marks, from ArenaModTools ---

## `ArenaPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## The challenge bar's achievement (+1, so 0 is none) and progress. The owner's alone: what a
## player is working towards is nobody else's business.
var net_challenge: int = 0
var net_challenge_value: int = 0

## `ArenaPlayer.beacon`. Everybody's.
var net_beacon: bool = false

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

## The newest tick this client has simulated, so a replayed one can be told from it.
var _newest_simulated: int = -1


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

	# The pack's `all_specs()` is dot-weapon's three plus its own four, and is the one call
	# its README asks a game to make: concatenating the halves by hand is how a game forgets
	# the second one and has weapons that are silent for everybody but their owner.
	for spec in DotCombatNetSync.specs() + ZeeWeaponNet.all_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		# Never true for any of these today, and read rather than assumed: a counter
		# interpolated is a shot that half happened.
		if bool(spec.get("interpolated", false)):
			declaration.interpolated()

		if bool(spec["owner_only"]):
			# Not a bandwidth optimisation: exact ammunition is information an
			# opponent should not have, and a modified client that had it would know
			# when to push. Data never sent cannot be read out of a client.
			declaration.to_owner_only()

	# [b]Per-player state rather than an event, and that is what makes both of these
	# survive what an event does not.[/b] A client that joins after the admin typed
	# `beacon`, a snapshot lost on the way, a map change: each is a baseline the next
	# snapshot corrects, where an event sent once is simply missed. Two bits, and nothing
	# at all on a tick where neither changed.
	#
	# The blind goes to its owner alone. Nobody else's screen changes, and an opponent who
	# received it would know the moment somebody could not see them — the same reason the
	# ammunition above is the owner's.
	replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_challenge", DotNetVar.Type.UINT).bits(7).to_owner_only()
	replicate(&"net_challenge_value", DotNetVar.Type.UINT).bits(16).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)

	replicate(&"net_weapon", DotNetVar.Type.UINT).bits(ArenaContent.WEAPON_INDEX_BITS)
	replicate(&"net_carry", DotNetVar.Type.UINT).bits(ArenaContent.carry_bits()).to_owner_only()


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
		_predict(tick, delta)

	pull()


## One predicted tick, which may be a replay.
##
## [b]A replay is marked, and it never was.[/b] dot-net's predictor reconciles by calling
## [method _net_simulate] again for every unacknowledged tick, exactly as it called it the
## first time; nothing in the call says which is which. Unmarked, every use inside the
## replayed window emitted `used` again — so the client heard its own shot, saw its flash
## and kicked its view once per snapshot that covered it, which at 64 ticks and a tenth of
## a second of latency is several times per shot. `ZeeWeaponRig.begin_replay` is the
## pack's switch for exactly this: the simulation re-runs and the drawing does not.
func _predict(tick: int, delta: float) -> void:
	var replaying := tick <= _newest_simulated and player.weapons != null

	if replaying:
		player.weapons.begin_replay()

	var _outcome := player.simulate_tick(tick, delta, last_move, last_fire)

	if replaying:
		player.weapons.end_replay()

	_newest_simulated = maxi(_newest_simulated, tick)


## Whether a tick would be simulated as a replay. For a suite.
func is_replay(tick: int) -> bool:
	return tick <= _newest_simulated


## Copies the simulation into the replicated properties.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)
	DotCombatNetSync.pull(player.health, self)

	# The rig's pull is dot-weapon's three and the pack's four.
	if player.weapons != null:
		ZeeWeaponNet.pull(player.weapons, self)
	else:
		DotWeaponNetSync.pull(player.arsenal, self)

	var def := player.arsenal.current_def() if player.arsenal != null else null
	net_weapon = ArenaContent.weapon_index(def.id if def != null else &"")
	net_carry = ArenaContent.carry_mask(player.arsenal)

	net_blind = player.blinded
	net_challenge = clampi(player.challenge + 1, 0, 127)
	net_challenge_value = clampi(player.challenge_value, 0, 65535)
	net_beacon = player.beacon

	# A beaconed player is relevant to everybody, wherever they are. The beacon's whole
	# job is that the room can find this player, and a client whose interest set had cut
	# them for distance would receive neither the flag nor the position to draw it at —
	# a beacon that works everywhere except across a big map. On the authority only:
	# relevance is the server's decision, and a client's copy of the flag decides nothing.
	if identity != null and identity.is_authoritative:
		identity.always_relevant = player.beacon


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
	_push_weapons()

	player.blinded = net_blind
	player.challenge = net_challenge - 1
	player.challenge_value = net_challenge_value
	player.beacon = net_beacon

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


## The weapon half of a snapshot, on whichever end is not the authority.
##
## [b]The owner's arsenal is made to carry what the server says it carries, and its
## ammunition corrected[/b] — before the predictor replays on top, because this hook runs
## first. Then the slot, through dot-weapon's own push. Anybody else's is drawn, not
## simulated: what they hold and how often they have used it go to the player's mirror
## fields, and `ArenaPlayer` hangs the gun in their hand from those.
func _push_weapons() -> void:
	if identity != null and identity.is_authoritative:
		return

	var owned := identity != null and identity.is_predicted()

	if owned:
		var _changed := ArenaContent.apply_carry(player.arsenal, net_carry)

	DotWeaponNetSync.push(self, player.arsenal)

	if owned:
		DotWeaponNetSync.correct_ammo(self, player.arsenal)
		player.mirrored = false
		return

	player.mirrored = true
	player.mirror_weapon = ArenaContent.weapon_at(net_weapon)
	player.mirror_fire_seq = net_fire_seq
	player.mirror_fire_kind = net_fire_kind
	player.mirror_switching = net_switching


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
		"weapon": String(ArenaContent.weapon_at(net_weapon)),
		"fire_seq": net_fire_seq,
		"blind": net_blind,
		"beacon": net_beacon,
		"state_tick": last_state_tick,
	}
