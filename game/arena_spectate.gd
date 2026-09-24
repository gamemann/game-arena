extends Node

const ArenaGame := preload("arena_game.gd")
const ArenaPlayer := preload("arena_player.gd")

## Where a dead player looks.
##
## [b]The arena has killed people since the day it was written and had nowhere for them
## to look.[/b] A dead player's camera stayed where their body fell, which is the one
## thing a first-person game must not do: the corpse is on the floor, so the view is on
## the floor, and the two seconds before respawn are spent looking at a wall from ankle
## height.
##
## The camera part is four lines. The part that matters is that the **server** decides
## who may watch whom: this game defaults to own-team-only, so a dead player cannot
## call out the other side's positions, and the delay is available for a server that
## wants one.
##
## [codeblock]
## var spectate := ArenaSpectate.new()
## spectate.game = game
## add_child(spectate)
## spectate.setup()
## # on the client, once a frame:
## camera.global_transform = spectate.camera_for(my_id)
## [/codeblock]

const CHANNEL := "arena.spectate"

var game: ArenaGame = null

var manager: DotSpectatorManager = null


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "ArenaSpectate needs a game.")

	manager = DotSpectatorManager.new()
	manager.name = "SpectatorManager"
	manager.authoritative = game.is_authority
	manager.rules = _rules()
	manager.participants_fn = _participants
	manager.team_fn = func(key: String) -> int: return game.team_of(int(key))
	manager.alive_fn = func(key: String) -> bool:
		var player := game.player_for(int(key))
		return player != null and player.is_alive()
	manager.pose_fn = _pose_of
	add_child(manager)

	var res := manager.setup()
	if not res.ok:
		return res.wrap("arena spectate")

	# Once per game, and INFO because it is the policy an admin is asked about: "why
	# can I only watch my own team" has its answer in this line.
	DotLog.info(CHANNEL, "spectating is set up", {
		"own_team_only": manager.rules.force_camera == 1,
		"roaming": manager.rules.allow_roaming,
		"death_cam_ticks": manager.rules.death_cam_ticks,
		"authoritative": manager.authoritative,
	})

	if not game.player_killed.is_connected(_on_killed):
		game.player_killed.connect(_on_killed)
	if not game.player_spawned.is_connected(_on_spawned):
		game.player_spawned.connect(_on_spawned)

	return DotResult.success(null)


func _rules() -> DotSpectatorRules:
	var rules := DotSpectatorRules.new()

	# Free-for-all has no sides to restrict to, and a restriction that means nothing is
	# a restriction that confuses an operator reading the log. A team mode gets the
	# restriction, which is what it is for.
	rules.force_camera = 1 if (game.mode != null and game.mode.is_team_mode()) else 0
	rules.allow_roaming = rules.force_camera == 0
	rules.death_cam_ticks = int(1.0 * float(game.tick_rate))
	rules.freeze_cam_ticks = int(1.5 * float(game.tick_rate))
	rules.chase_distance = 3.5
	rules.chase_height = 0.9
	rules.history_ticks = 4 * game.tick_rate
	return rules


func _participants() -> PackedStringArray:
	var out := PackedStringArray()
	for id in game.player_ids():
		out.append(str(id))
	return out


## Where a player's eyes are.
##
## Eyes rather than the body's origin, and it is not a nicety: a chase camera derived
## from a capsule origin sits in the floor and a first-person one is at the knees.
## `ArenaPlayer.muzzle_position` is the same 1.6 metres and is deliberately not reused —
## a muzzle is where a shot leaves and an eye is where a view starts, and the day one of
## them moves is the day sharing them is a bug.
func _pose_of(key: String) -> Transform3D:
	var player := game.player_for(int(key))
	if player == null or player.controller == null:
		return Transform3D.IDENTITY

	var state := player.controller.state
	var basis := Basis.from_euler(
		Vector3(deg_to_rad(state.pitch), deg_to_rad(state.yaw), 0.0)
	)
	return Transform3D(basis, state.position + Vector3(0.0, 1.6, 0.0))


func tick(_delta: float) -> void:
	if manager != null:
		manager.advance(game.current_tick())


## The camera a viewer should be drawn from. Identity when they are playing.
func camera_for(id: int) -> Transform3D:
	return manager.camera_of(str(id)) if manager != null else Transform3D.IDENTITY


func is_spectating(id: int) -> bool:
	return manager != null and manager.is_spectating(str(id))


func next_target(id: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return manager.next_target(str(id))


func previous_target(id: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return manager.previous_target(str(id))


## Cycle first person, chase, roaming — whatever the server's policy allows.
func cycle_mode(id: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	var view := manager.view(str(id))
	var next := DotSpectatorView.Mode.CHASE
	if view.mode == DotSpectatorView.Mode.CHASE:
		next = DotSpectatorView.Mode.ROAMING
	elif view.mode == DotSpectatorView.Mode.ROAMING:
		next = DotSpectatorView.Mode.FIRST_PERSON
	return manager.set_mode(str(id), next)


func _on_killed(entry: DotKillFeed.Entry) -> void:
	if manager == null:
		return
	var player := game.player_for(int(entry.victim_key))
	var at := Vector3.ZERO
	if player != null and player.controller != null:
		at = player.controller.state.position
	else:
		# A kill for somebody the game no longer holds: their death cam starts at the
		# world origin, which is a camera in the floor of the middle of the map.
		DotLog.warn(CHANNEL, "a death for a player the game does not hold; the death cam starts at the origin", {
			"victim": entry.victim_key,
		})
	manager.on_death(entry.victim_key, at, entry.killer_key, game.current_tick())


func _on_spawned(player: ArenaPlayer) -> void:
	if manager != null:
		manager.on_spawn(str(player.player_id))


func on_leave(id: int) -> void:
	if manager != null:
		manager.on_leave(str(id))


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["spectate: not set up"])
	return manager.describe_lines()
