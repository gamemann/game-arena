class_name ArenaPlayerStack
extends Node

## The player-facing addons, stood up once and bound to the game.
##
## [b]Seven addons that each know nothing about the arena, and this is the file where
## they meet it.[/b] The same job [ArenaGame] does for dot-match, dot-combat and
## dot-loadout, for the layer that arrived later: who is in the session, which side they
## are on, what class they are, where they enter the world, and what the physics is set
## to while they are in it.
##
## [codeblock]
## dot-physics   the collision layout and the engine numbers, applied and restorable
## dot-player    the one row per participant everything else reads
## dot-team      sides that outlive the match, DRIVING dot-match's manager
## dot-player-class  what a player is, with the change landing on the next spawn
## dot-spawn     where they enter, with areas, conditions and protection
## dot-team the side policy over dot-spectate
## [/codeblock]
##
## [b]It adds no authority and takes none away.[/b] dot-match still decides the round,
## dot-combat still decides damage, and `ArenaGame` still owns the tick. What this does
## is keep one set of records in step with them, so that a scoreboard, a spectator
## camera, a class screen and a spawn selector are all reading the same thing rather
## than four dictionaries that agree until somebody reconnects.
##
## [b]Why dot-team drives dot-match rather than replacing it.[/b] `ArenaGame` assigns a
## side through `DotTeamManager`, which balances and refuses a full team — behaviour
## worth keeping. So the assignment is made here, in the session-scoped roster that
## survives a map change, and pushed down into dot-match through its duck-typed
## `assign`. One decision, in one place, visible to both.

const CHANNEL := "arena.stack"

const SERVICE := &"arena_player_stack"

## Somebody's class changed, after a spawn honoured a pending choice.
signal class_applied(id: int, class_id: StringName)

## The physics profile was applied or switched.
signal physics_applied(profile: DotPhysicsProfile)

@export var register_service: bool = true

## Whether to apply a physics profile at all.
##
## Off for a client joined to a server: the server's tick rate is what matters and a
## client that re-applied a different one would simulate at a rate the server does not.
@export var apply_physics: bool = true

## Which physics preset. The arena is an arcade shooter.
@export var physics_preset: StringName = &"arcade_shooter"

var game: ArenaGame = null

var physics: DotPhysicsWorld = null
var roster: DotPlayerRoster = null
var teams: DotTeamRoster = null
var classes: DotPlayerClassManager = null
var spawns: DotSpawnDirector = null
var spectate: DotTeamSpectate = null

var _registered: bool = false


## Builds everything and binds it to [param p_game].
##
## Returns a failure without having built anything when the game is not set up, because
## half a stack is worse than none: the roster would exist, nothing would feed it, and
## every consumer would read an empty scoreboard on a running server.
func setup(p_game: ArenaGame) -> DotResult:
	if p_game == null:
		return DotResult.fail(DotError.CODE_INVALID, "No game to bind to.")

	if p_game.match_node == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"ArenaGame is not set up yet.",
			"Call ArenaGame.setup() first; this reads its match, its spawn points and "
			+ "its tick rate."
		)

	game = p_game

	var built := _build_physics()

	if not built.ok:
		return built

	_build_roster()
	_build_teams()
	_build_classes()
	_build_spawns()
	_build_spectate()
	_connect_game()

	if register_service:
		DotRegistry.register(SERVICE, self)
		_registered = true

	DotLog.info(CHANNEL, "player stack up", {
		"tick_rate": game.tick_rate,
		"classes": classes.catalogue.ids().size(),
		"sites": spawns.sites().size(),
	})

	return DotResult.success(null)


func _exit_tree() -> void:
	if _registered:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

func _build_physics() -> DotResult:
	if not apply_physics:
		return DotResult.success(null)

	physics = DotPhysicsWorld.new()
	physics.name = "Physics"
	physics.profile = DotPhysicsProfile.preset(physics_preset)

	if physics.profile == null:
		physics.profile = DotPhysicsProfile.arcade_shooter()

	# The game's tick rate wins over the preset's. Two numbers meaning "how often the
	# world advances" is exactly the disagreement NET_WORLD_EXTENT's comment is about,
	# one layer down: dot-match, dot-net and the movement all count in ArenaGame's
	# ticks, and a physics profile quietly running at 128 while they run at 64 makes
	# every rigid body move at twice the rate of every player.
	physics.profile.tick_rate = game.tick_rate

	physics.layout = DotPhysicsLayout.shooter_3d()
	physics.surfaces = DotPhysicsSurfaceSet.standard()
	physics.register_service = false
	# A dedicated server has no inspector to read layer names in, and the write is
	# pure cost there.
	physics.write_layer_names = not game.headless
	add_child(physics)

	var res := physics.setup()

	if res.ok:
		physics_applied.emit(physics.profile)

	return res.wrap("The arena's physics profile")


func _build_roster() -> void:
	roster = DotPlayerRoster.new()
	roster.name = "Roster"
	roster.authoritative = game.is_authority
	roster.register_service = false

	var config := DotPlayerConfig.new()
	config.tick_rate = game.tick_rate
	config.max_players = 32
	# Long enough to survive a map change, which is what a player reconnecting into an
	# arena is most often doing.
	config.reconnect_window_sec = 90.0
	roster.config = config

	add_child(roster)


func _build_teams() -> void:
	teams = DotTeamRoster.new()
	teams.name = "Teams"
	teams.authoritative = game.is_authority
	teams.register_service = false
	teams.teams = DotTeamSet.standard_pair(&"blue", &"red")
	teams.policy = DotTeamPolicy.competitive()
	teams.policy.tick_rate = game.tick_rate
	teams.alive_fn = _alive_of_key
	teams.joined_fn = _joined_tick_of_key
	teams.score_fn = _score_of_key
	teams.live_fn = func() -> bool: return game.match_node.is_live()
	add_child(teams)

	var res := teams.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team roster", {"why": res.error.message})
		return

	# [b]dot-match is the authority here, and dot-team mirrors it. That is the opposite
	# direction from dot-team's usual one, and the reason is the arena's.[/b]
	#
	# dot-team can drive a match manager — `bind_match` exists and is the right shape
	# for a lobby or a server whose sides outlive four map changes. The arena is not
	# that: its sides are decided by `DotTeamManager.assign`, which reads a requested
	# team, balances an uneven pair and refuses a full one, and its spawns are chosen
	# from spawn points the MAP tagged per side. Driving that from outside would mean
	# reimplementing the balance and the map tags, badly.
	#
	# So `bind_match` is deliberately NOT called, and `_on_player_added` adopts the side
	# dot-match assigned instead. What the session roster still buys is the part
	# dot-match cannot offer: an assignment that survives a map change, a spectator
	# side, and one place for dot-combat, dot-chat and dot-spectate to ask "are these
	# two enemies".
	teams.policy.auto_assign = game.match_node.teams == null


func _build_classes() -> void:
	classes = DotPlayerClassManager.new()
	classes.name = "Classes"
	classes.authoritative = game.is_authority
	classes.register_service = false

	# One class. The arena is a deathmatch and everybody is the same, and a catalogue
	# with one entry is how that is said without every consumer branching on whether
	# classes exist at all. A mode that wants more replaces the catalogue.
	classes.catalogue = DotPlayerClassCatalogue.single(100.0)
	classes.rules = DotPlayerClassRules.instant()
	classes.team_fn = func(key: String) -> StringName: return teams.team_of(key)
	classes.alive_fn = _alive_of_key
	classes.live_fn = func() -> bool: return game.match_node.is_live()
	add_child(classes)

	var res := classes.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "class manager", {"why": res.error.message})


func _build_spawns() -> void:
	spawns = DotSpawnDirector.new()
	spawns.name = "Spawns"
	spawns.tick_rate = game.tick_rate
	spawns.register_service = false
	spawns.rules = DotSpawnRules.deathmatch()
	spawns.rules.seed_value = 0x4A5E4
	spawns.enemies_fn = _enemy_positions
	spawns.friends_fn = _friend_positions
	add_child(spawns)

	refresh_spawns()


## Re-reads the game's spawn points into the director. Call after a map change.
##
## [b]dot-match's spawn points are the source, and are not replaced.[/b] A mapper
## places a `DotSpawnPoint`, dot-match picks one for a respawn, and this reads the same
## nodes into `DotSpawnSite` values so that the richer selector — conditions, occupancy,
## visibility, protection — can be asked as well. Two systems reading one set of markers
## is fine; two systems owning two sets of markers is a map that spawns people in
## different places depending on which asked.
func refresh_spawns() -> void:
	if spawns == null or game == null:
		return

	spawns.clear_sites()

	for point in game.match_node.spawn_points():
		var at := point.spawn_transform()
		var site := DotSpawnSite.point(
			StringName(point.name), at.origin, at.basis.get_euler().y
		)
		# dot-match calls it `weight` and means the same thing: which point is preferred
		# when nothing else separates two. Rounded because dot-spawn's is an integer,
		# and a weight of 1.0 — the default — has to come out as a priority of 1 rather
		# than as a floor to zero that makes every point equal.
		site.priority = int(round(point.weight))
		site.cooldown_ticks = point.cooldown_ticks
		site.enabled = point.enabled
		spawns.add_site(site)

	DotLog.debug(CHANNEL, "spawn sites", {"count": spawns.sites().size()})


func _build_spectate() -> void:
	spectate = DotTeamSpectate.new()
	spectate.name = "Spectate"
	spectate.teams = teams
	spectate.register_service = false
	spectate.rules = DotTeamSpectateRules.competitive()
	spectate.alive_fn = _alive_of_key
	spectate.pose_fn = _pose_of_key
	spectate.round_live_fn = func() -> bool: return game.match_node.is_live()

	var sr := DotSpectatorRules.new()
	# The arena is a free-for-all, so there is no "own side" to be restricted to and a
	# restriction would forbid everything.
	sr.force_camera = 0
	sr.delay_ticks = 0
	spectate.spectator_rules = sr

	add_child(spectate)

	var res := spectate.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team spectate", {"why": res.error.message})


func _connect_game() -> void:
	game.player_added.connect(_on_player_added)
	game.player_spawned.connect(_on_player_spawned)
	game.player_killed.connect(_on_player_killed)
	game.map_changed.connect(_on_map_changed)


# --- Keeping in step --------------------------------------------------------

func _on_player_added(player: ArenaPlayer) -> void:
	if not game.is_authority:
		return

	var key := str(player.player_id)
	var res := roster.join(key, player.display_name, player.player_id, game.current_tick())

	if not res.ok:
		DotLog.warn(CHANNEL, "player not added to the roster", {
			"key": key, "why": res.error.message
		})
		return

	var _team := teams.add(key, game.current_tick())

	# Adopt the side dot-match actually gave them, which is not necessarily the one
	# anybody asked for. Reading it back rather than assuming is the same rule
	# `ArenaGame.add_player` already follows one line above the signal that got us here.
	var side := _side_of_id(game.team_of(player.player_id))

	if side != &"":
		var _forced := teams.force_team(key, side, &"match")

	var _class := classes.add(key)


func _on_player_spawned(player: ArenaPlayer) -> void:
	if not game.is_authority:
		return

	var key := str(player.player_id)

	# Before the alive flag: a pending class change lands on the spawn, and anything
	# reading the class in an `alive_changed` handler should read the new one.
	var landed := classes.apply_pending(key)
	class_applied.emit(player.player_id, landed)

	var _alive := roster.set_alive(key, true)
	spawns.cancel_respawn(key)

	if spectate.is_spectating(key):
		spectate.end(key)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	if not game.is_authority:
		return

	var _dead := roster.set_alive(entry.victim_key, false)
	var _queued := spawns.queue_respawn(entry.victim_key, game.current_tick())


func _on_map_changed(_map: ArenaMap) -> void:
	refresh_spawns()


## Drops a player from every record. Call from `ArenaGame.remove_player`.
##
## [b]Not connected to a signal, because there is not one.[/b] `ArenaGame.remove_player`
## is a method, and adding a signal to it for this would be adding a signal for one
## subscriber. The call site is one line in that method and is easier to find than a
## connection made here.
func drop_player(id: int) -> void:
	var key := str(id)

	if not roster.authoritative:
		return

	spectate.end(key)
	spawns.cancel_respawn(key)
	classes.remove(key)
	var _left := teams.remove(key)
	# note_disconnected rather than remove: a player who drops out of an arena
	# mid-match and comes back within the window keeps their score, and the roster is
	# the only thing in this game that can offer that.
	var _held := roster.note_disconnected(key, game.current_tick())


## One tick of everything this node runs on its own.
##
## Deliberately small: the respawn timers are dot-match's, not dot-spawn's, because
## dot-match already owns the round clock and two systems queuing respawns would
## respawn everybody twice. What this drains is spawn protection and the roster's
## reconnect windows.
func tick(current_tick: int) -> void:
	if not game.is_authority:
		return

	if spawns.protection != null:
		spawns.protection.advance(current_tick)

	var _dropped := roster.advance(current_tick)
	spectate.advance(current_tick)


# --- Reading ----------------------------------------------------------------

## Where a player should enter the world, asked of the richer selector.
##
## Offered rather than imposed: `ArenaGame._on_respawn_due` uses dot-match's choice,
## which is correct and dependency-free. A mode that wants conditions, occupancy or
## visibility scoring calls this instead and gets an explanation with the answer.
func choose_spawn(id: int) -> DotResult:
	var key := str(id)
	var request := DotSpawnRequest.make(
		key, teams.team_of(key), classes.class_of(key), game.current_tick()
	)
	return spawns.choose(request)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("--- player stack")

	if physics != null:
		out.append_array(physics.describe_lines())

	out.append_array(roster.describe_lines())
	out.append_array(teams.describe_lines())
	out.append_array(classes.describe_lines())
	out.append_array(spawns.describe_lines())
	out.append_array(spectate.describe_lines())
	return out


func describe() -> Dictionary:
	return {
		"players": roster.count(),
		"alive": roster.alive_count(),
		"teams": teams.describe(),
		"spawn_sites": spawns.sites().size(),
		"viewers": spectate.viewers().size(),
		"physics": physics.describe() if physics != null else "not applied",
	}


## The dot-team side for one of dot-match's team ids.
##
## [b]An id, not an index, and the difference is the bug this function exists to
## avoid.[/b] dot-match's `standard_pair()` is Red `1` and Blue `2`; a spectator team is
## `31`. Treating `team_of()`'s answer as a position would put team 1 on dot-team's
## first side and team 2 on its second by luck, and would put a spectator nowhere.
##
## So the id is looked up in the match's own ordered team list and the POSITION is what
## crosses over — the nth playing side there is the nth playing side here.
func _side_of_id(team_id: int) -> StringName:
	if game.match_node.teams == null or team_id <= 0:
		return &""

	var playing := teams.teams.playing_ids()
	var listed := game.teams()

	for i in range(listed.size()):
		if listed[i] != null and listed[i].id == team_id:
			return playing[i] if i < playing.size() else &""

	return &""


# --- The callables the addons are given -------------------------------------

func _alive_of_key(key: String) -> bool:
	var player := game.player_for(int(key))
	return player != null and player.is_alive()


func _joined_tick_of_key(key: String) -> int:
	var record := roster.get_record(key)
	return record.joined_tick if record != null else 0


func _score_of_key(key: String) -> float:
	var score := game.match_node.scoreboard.find(key)
	return float(score.score) if score != null else 0.0


## Where a player's EYES are, which is not where their feet are.
##
## dot-spectate's own documentation is explicit about it: a chase camera derived from a
## capsule's origin sits in the floor and a first-person one is at the knees. The
## controller answers it, because the controller is what knows the eye height and the
## pitch.
func _pose_of_key(key: String) -> Transform3D:
	var player := game.player_for(int(key))

	if player == null or player.controller == null:
		return Transform3D.IDENTITY

	return player.controller.eye_transform()


func _enemy_positions(_team: StringName) -> Array:
	# Free-for-all: everybody alive is an enemy, which is the honest answer here and is
	# why the spawn selector is asked for distance at all.
	var out: Array = []

	for player in game.players():
		if player.is_alive() and player.controller != null:
			out.append(player.controller.state.position)

	return out


func _friend_positions(_team: StringName) -> Array:
	return []
