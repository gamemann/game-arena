extends Node

const ArenaGame := preload("arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("arena_player.gd")

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

## The loadout the arena's one class names.
const LOADOUT_STANDARD := &"arena_standard"

## What each `loadout_id` in the class catalogue means, in weapon ids.
##
## [b]The game's table, and dot-weapon is explicit about why it is not the addon's.[/b]
## A loadout id and a weapon id are two different id spaces and joining them is a content
## decision — a mode that swapped the rifle for a shotgun would edit this and nothing
## else. `DotWeaponLoadoutBridge` carries the same argument for dot-loadout.
const LOADOUT_WEAPONS := {
	"arena_standard": [&"pistol", &"rifle"],
}

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

## Which map's spawn points are in the director. See [method _ensure_sites_current].
var _sites_from: ArenaMap = null


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

## Builds the physics node, and applies the engine half of it only where that is wanted.
##
## [b]The LAYOUT is built on every instance, including a client that applies nothing.[/b]
## It used to return before creating the node at all when `apply_physics` was off, which
## left a client with no layout — and a collision layout is not a local preference, it is
## the numbers in `collision_layer` on nodes both ends build. A server that put props on
## the prop bit while its clients left them on bit 0 would be two worlds with different
## collision matrices, agreeing only because nothing had ever read the layout.
##
## What `apply_physics` still gates is `setup()`, which writes ProjectSettings: the tick
## rate, gravity and damping. Those are the server's to decide, and a client that
## re-applied its own would simulate at a rate the server does not.
func _build_physics() -> DotResult:
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

	# The layout alone, so `classify` answers on a client too.
	var built := physics.layout.build()

	if not built.ok:
		return built.wrap("The arena's collision layout")

	if not apply_physics:
		return DotResult.success(null)

	var res := physics.setup()

	if res.ok:
		physics_applied.emit(physics.profile)

	return res.wrap("The arena's physics profile")


## Puts [param node] on the layout's [param layer_id] layer, with that layer's mask.
##
## [b]The half of dot-physics that was never used.[/b] The layout was assigned, its layer
## names were written into ProjectSettings for the inspector to show — and every body in
## the game stayed on Godot's default layer 1 with mask 1, so the inspector labelled
## layers nothing followed and props could not touch each other. Naming a layer is only
## half of a layout; this is the other half.
##
## Quiet about a node that is not a collision object: [ArenaPlayer] is a [Node3D] and its
## movement is a shape query rather than a body, so "classify the player" has nothing to
## write. That is not an error, it is this game's movement model.
func classify(node: Node, layer_id: StringName) -> DotResult:
	if physics == null or physics.layout == null:
		return DotResult.fail(DotError.CODE_STATE, "No collision layout.")

	return physics.classify(node, layer_id)


## Puts every collision object under [param root] on [param layer_id].
##
## For a level: one call rather than a call per box, because the geometry is built by
## `ArenaMap` and a loop there would put a physics decision inside a description of
## boxes. Nodes that are not collision objects are skipped, so handing it a whole scene
## is safe. Returns how many were classified.
func classify_tree(root: Node, layer_id: StringName) -> int:
	if root == null or physics == null or physics.layout == null:
		return 0

	var done := 0

	if root is CollisionObject3D or root is CollisionObject2D:
		if classify(root, layer_id).ok:
			done += 1

	for child in root.get_children():
		done += classify_tree(child, layer_id)

	return done


## The mask a player's movement sweeps against, out of the layout.
##
## [b]`DotFpsTunables.collision_mask` defaults to 1 and no game here had ever set it.[/b]
## One is correct only for as long as everything is on bit 0, which is exactly the state
## the layout exists to end — so the moment props moved to the prop bit, a mask of 1
## would have been a player who walks through every crate in the map.
func player_collision_mask() -> int:
	if physics == null or physics.layout == null:
		return 1

	return physics.layout.collision_mask(&"player")


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

	# [b]The one class names its loadout, so the arsenal comes from the document rather
	# than from a hardcoded pair.[/b] `DotWeaponPlayerBridge.give_class_loadout` reads
	# `loadout_id` off a class and looks it up in a table the GAME owns — dot-weapon
	# deliberately does not own the id space between a loadout and a weapon — and until
	# this line neither half had a caller: every player got pistol-and-rifle written into
	# `ArenaPlayer.give_default_loadout`, and the class's own field reached nothing.
	var only := classes.catalogue.classes[0]
	only.loadout_id = LOADOUT_STANDARD
	var _rebuilt := classes.catalogue.build()

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

	refresh_spawn_rules()
	refresh_spawns()


## Re-reads the mode's spawn protection into the director's rules.
##
## [b]One duration, three consumers, and they used to be two durations.[/b] Spawn
## protection is enforced in three places here: [DotHealth]'s invulnerable window, the
## `arena_protected` effect, and — since the director started choosing — dot-spawn's own
## ledger. The mode sets `DotMatchRules.spawn_protection_sec` (1.5 s in a free-for-all,
## 2.5 s in the horde) and the effect table carried a hardcoded two seconds, so a
## free-for-all player was protected for 1.5 s by one gate and 2.0 s by another. Which
## one a hit met depended on the order the two were asked in.
##
## Called on a map change because a mode change goes through one.
func refresh_spawn_rules() -> void:
	if spawns == null or game == null or game.match_node == null:
		return

	spawns.rules.protection_sec = game.match_node.rules.spawn_protection_sec

	# [b]Off, and not because breaking on attack is wrong.[/b] It is the behaviour a
	# deathmatch wants — firing out of your own spawn should end the window. But only
	# ONE of the three gates above can be revoked: [DotHealth] counts to a tick and the
	# effect expires on its own, and neither has a "somebody shot" input. Revoking the
	# ledger alone would make a player who fired stop being protected by the resolver
	# and stay protected by the other two, which is worse than either answer.
	#
	# Turning it on is a change to all three at once. It is not a flag to flip here.
	spawns.rules.protection_breaks_on_attack = false


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
	_sites_from = game.map

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
	apply_class_numbers(player)
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
	# The rules first: a map change carries a mode change, and the mode is what says how
	# long spawn protection lasts. Refreshing the sites against the old duration would
	# grant the previous mode's protection until the next changelevel.
	refresh_spawn_rules()
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

## Rebuilds the sites when they came from a map that is no longer loaded.
##
## [b]Signal order, and it is not hypothetical.[/b] A map change emits `map_changed` and
## respawns everybody, and nothing orders this node's handler before the respawn. When it
## lost that race the director still held the previous map's points and answered — with a
## real site, a real transform and a successful `DotResult` — a coordinate from a map
## nobody was standing in. game-g2gfast hit exactly this and its surf section found it as
## a bot that never left the ground; the only reason it is not already a bug here is that
## `_on_respawn_due` had never asked the director at all.
func _ensure_sites_current() -> void:
	if spawns == null or game == null:
		return

	if _sites_from != game.map:
		refresh_spawns()


## Where a player should enter the world, and the grant of protection that goes with it.
##
## [b]This is the live path, and it was not.[/b] `ArenaGame._on_respawn_due` used
## dot-match's own choice and this was offered beside it — which meant the director was
## built, fed every site on the map, ticked every tick, and never asked anything. The
## visible half of that was harmless (dot-match picks a reasonable point). The invisible
## half was not: [DotSpawnProtection] is granted inside [method DotSpawnDirector.choose]
## and nowhere else, so `spawns.protection.advance()` in [method tick] was draining a
## ledger that was always empty, for ever, while reading exactly like working spawn
## protection.
##
## dot-match's points are still the source — see [method refresh_spawns]. What this adds
## on top of picking one of them is the part dot-match has no model for: enemy distance,
## line of sight, occupancy, per-site cooldown, and the protection window.
func choose_spawn(id: int) -> DotResult:
	_ensure_sites_current()

	var key := str(id)
	var request := DotSpawnRequest.make(
		key, teams.team_of(key), classes.class_of(key), game.current_tick()
	)
	return spawns.choose(request)


## Writes the player's class numbers onto their health and their movement.
##
## [b]The class document reached nothing at all before this.[/b] `DotPlayerClassDef`
## carries `max_health`, `max_armour`, regeneration, a move-speed scale, a jump scale, a
## mass and a knockback scale; the manager decided who was what, emitted it, and every
## one of those numbers was read by nobody. A catalogue a server can validate is only
## half of a class system — the other half is the spawn where it lands.
##
## [b]`base_tunables` is why this can run on every spawn.[/b] The scales multiply, so
## applying one to an object that already carries it compounds: 0.8 twice is 0.64, and a
## player who respawned four times would be at 0.41 of the speed with every number in the
## inspector looking deliberate. `DotPlayerClassApply` reads the untouched base and writes
## the product, which makes a respawn idempotent.
##
## Arena ships one class, so today this changes nothing visible — which is exactly when a
## mechanism is worth wiring, because a mode that swaps the catalogue is then a catalogue
## swap rather than a catalogue swap plus finding out why nothing happened.
func apply_class_numbers(player: ArenaPlayer) -> void:
	if player == null or classes == null:
		return

	var def := classes.def_of(str(player.player_id))

	if def == null:
		return

	# Not reset to full here: `ArenaPlayer.spawn` already calls `DotHealth.reset`, and
	# two resets on one spawn is one of them undoing the other's protection window.
	var _h := DotPlayerClassApply.to_health(def, player.health)
	player.apply_class_movement(def)


## Fills a player's arsenal from what their class says they start with.
##
## Returns whether the class supplied one. False is an ordinary answer — a class with no
## `loadout_id` is legal, and a game with no class catalogue at all is the common case —
## so the caller falls back to its own default rather than leaving somebody unarmed.
func give_class_loadout(player: ArenaPlayer) -> bool:
	if player == null or player.arsenal == null or classes == null:
		return false

	var def := classes.def_of(str(player.player_id))

	if def == null:
		return false

	var res := DotWeaponPlayerBridge.give_class_loadout(
		player.arsenal, def, LOADOUT_WEAPONS
	)

	if not res.ok:
		DotLog.debug(CHANNEL, "no class loadout", {
			"key": str(player.player_id), "why": res.error.message
		})
		return false

	return int(res.value) > 0


## Whether spawn protection should stop [param attacker] hurting [param victim].
##
## Handed to the damage path through [ArenaEffects.adjust_damage], which owns
## `DotDamageResolver.adjust`. Self damage is never blocked and world damage is not
## either — a protected player who walks into a pit is meant to die in it — and both of
## those decisions are [DotSpawnProtection]'s rather than this file's.
func blocks_damage(
	attacker_key: String, victim_key: String, tick: int, world_damage: bool = false
) -> bool:
	if spawns == null or spawns.protection == null:
		return false

	return spawns.protection.blocks(attacker_key, victim_key, tick, world_damage)



## The dot-spectate team number for [param key], derived from the side they are on.
##
## [b]An index, not a hash, and zero means "no side".[/b] dot-spectate keys teams by
## [code]int[/code] and treats 0 as no team at all — two entities with no team are never
## team-mates, so a free-for-all cannot accidentally become a truce. The playing sides
## are numbered from 1 in the order the set declares them, which is the same rule
## `DotTeamRoster._match_team_id` uses to push an assignment down into dot-match.
##
## Somebody unassigned, spectating, or not in the roster at all gets 0. That is the part
## a hardcoded `return 1` got wrong: a spectator read as a team-mate of everybody.
func team_index_of(key: String) -> int:
	if teams == null:
		return 0

	var side := teams.team_of(key)

	if side == &"" or not teams.teams.is_playing(side):
		return 0

	return teams.teams.playing_ids().find(side) + 1


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
