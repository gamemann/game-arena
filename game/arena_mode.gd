extends Resource

const ArenaMode := preload("arena_mode.gd")

## What is being played: the rules, the sides, and what damage does.
##
## [b]A mode is DATA, not a subclass.[/b] Free-for-all and team deathmatch differ only
## in what is written here, so adding one is writing a resource rather than writing a
## file — which is what makes "configurable" true rather than aspirational. A server
## names one with `mp_mode`, dot-vote can offer several, and neither has to know what
## any of them mean.
##
## The line where that stops holding is real and worth naming: a mode that changes what
## HAPPENS on an event, rather than what an event is worth, needs code. Gun game — where
## a kill replaces your weapon — is the first one that does, and it subclasses
## [DotMatchRules] and hangs it here. Everything up to that point is this resource.
##
## [codeblock]
## var mode := ArenaModes.by_id(&"tdm")
## game.mode = mode
## game.setup(ArenaMap.by_id(mode.preferred_map))
## [/codeblock]

## What a server types, and what dot-vote would offer.
@export var id: StringName = &"ffa"

@export var display_name: String = "Free-For-All"

## One line, for a vote menu or a server listing.
@export_multiline var description: String = ""

@export_group("Rules")

## The match rules. Never null after [method validate].
##
## [b]This resource is duplicated before use.[/b] `ArenaGame` copies it rather than
## handing dot-match the catalogue's own object, because a `Resource` is a reference in
## GDScript and a server that adjusted a score limit at runtime would otherwise be
## editing the mode every later match reads. This family has shipped that exact aliasing
## four times — see `DotLeaderboardDef.scoped()` in the tree's notes.
@export var rules: DotMatchRules = null

@export_group("Sides")

## How many teams play. Zero or one is a free-for-all.
##
## The sides themselves come from [method teams], so a mode with three of them is a
## change here and nowhere else.
@export_range(0, 8, 1) var team_count: int = 0

@export_group("Damage")

## Whether a shot can hurt a team-mate. Meaningless with no teams.
@export var friendly_fire: bool = false

## Whether your own rocket hurts you.
##
## [b]On, deliberately, and not only for realism.[/b] Rocket jumping is a movement
## option, and taking self damage away removes the only reason to hold the rocket
## launcher over the rifle.
@export var self_damage: bool = true

@export_group("World")

## Whether monsters spawn and hunt the players.
##
## [b]A mode field rather than a server cvar, and that is the whole argument for
## [ArenaMode] being a resource.[/b] "Are there monsters" is not a setting an operator
## turns on top of a deathmatch — it changes what the match is, what a kill is worth
## and where you want to stand. A mode that has them and a mode that does not are two
## games, and two games are two resources.
@export var horde: bool = false

## Whether players may spawn physics props.
##
## Off in every shipped mode. A player who can wall themselves in is a player nobody
## can fight, and the props the map places are level furniture rather than a sandbox —
## see [ArenaProps].
@export var player_props: bool = false

## How many props the map scatters as cover, owned by nobody.
@export_range(0, 64, 1) var scatter_props: int = 0

@export_group("Objectives")

## Which objective layout this mode plays, or empty for none.
##
## [b]An id rather than a list of definitions, and that is deliberate.[/b] The layout is
## derived from the MAP's own extent — see [method ArenaObjectives.build] — so a mode
## carrying the definitions would carry `dm_atrium`'s flag positions into every map it
## was ever played on. `ffa`, `tdm` and `siege` leave it empty and are scored on kills,
## which is what [DotMatch] alone has always been enough for.
@export var objective_layout: StringName = &""

@export_group("Map")

## The map this mode is played on if nothing else says. Empty means "whatever is loaded".
##
## A team mode wants a map with tagged spawns, or both sides start in each other's
## laps — see [member ArenaMap.spawn_tags].
@export var preferred_map: StringName = &""


## Free-for-all: everybody against everybody, first to the score limit.
static func free_for_all(limit: int = 25) -> ArenaMode:
	var mode := ArenaMode.new()
	mode.id = &"ffa"
	mode.display_name = "Free-For-All"
	mode.description = "Everybody for themselves. First to %d." % limit
	mode.team_count = 0
	mode.friendly_fire = false
	mode.self_damage = true
	mode.preferred_map = &"dm_atrium"

	var rules := DotMatchRules.deathmatch(limit)
	rules.display_name = "Free-For-All"
	rules.respawn_delay_sec = 2.0
	rules.spawn_protection_sec = 1.5
	rules.warmup_sec = 10.0
	rules.countdown_sec = 3.0
	rules.min_players = 2
	rules.intermission_sec = 8.0
	rules.match_end_sec = 15.0
	rules.suicide_points = -1
	mode.rules = rules

	return mode


## Siege: a free-for-all with monsters in it, and cover you can move.
##
## [b]The mode that exists to run the joins.[/b] It is the only shipped configuration
## where dot-npc, dot-npc-ai, dot-npc-ai-director and dot-props are all live at once
## alongside the five this game already ran — and by this family's own repeated lesson,
## that is where the bugs are rather than in any one of them.
##
## It is also a real game rather than a test fixture. Monsters make the middle of the
## map expensive to hold, and movable cover is the only answer to that a player can
## build themselves — which is the trade the raised centre of `dm_box` has always
## wanted and never had.
static func siege(limit: int = 20) -> ArenaMode:
	var mode := ArenaMode.new()
	mode.id = &"siege"
	mode.display_name = "Siege"
	mode.description = "Everybody for themselves, and the arena is not empty."
	mode.team_count = 0
	mode.friendly_fire = false
	mode.self_damage = true
	mode.horde = true
	mode.player_props = true
	mode.scatter_props = 8
	mode.preferred_map = &"dm_box"

	var rules := DotMatchRules.deathmatch(limit)
	rules.display_name = "Siege"
	# Shorter than free-for-all's. Dying to a monster is not the same as losing a
	# duel, and a long wait after one is a punishment for the wrong thing.
	rules.respawn_delay_sec = 1.5
	rules.spawn_protection_sec = 2.5
	rules.warmup_sec = 10.0
	rules.countdown_sec = 3.0
	rules.min_players = 1
	rules.intermission_sec = 8.0
	rules.match_end_sec = 15.0
	rules.suicide_points = -1
	mode.rules = rules

	return mode


## Team deathmatch: two sides, a shared score, and no shooting your own.
static func team_deathmatch(limit: int = 75) -> ArenaMode:
	var mode := ArenaMode.new()
	mode.id = &"tdm"
	mode.display_name = "Team Deathmatch"
	mode.description = "Red against Blue. First side to %d." % limit
	mode.team_count = 2
	# Off, and the scoring says why: a team kill is worth -1 and does not count towards
	# the killer's total, so friendly fire would only ever cost the shooter. Turning it
	# on is a server's choice, not a mode's default.
	mode.friendly_fire = false
	mode.self_damage = true
	mode.preferred_map = &"dm_atrium"

	var rules := DotMatchRules.team_deathmatch(limit)
	rules.display_name = "Team Deathmatch"
	rules.respawn_delay_sec = 3.0
	rules.spawn_protection_sec = 2.0
	rules.warmup_sec = 10.0
	rules.countdown_sec = 3.0
	rules.min_players = 2
	rules.intermission_sec = 8.0
	rules.match_end_sec = 15.0
	rules.suicide_points = -1
	rules.friendly_points = -1
	mode.rules = rules

	return mode


## King of the hill: one point, two clocks, and the clock that runs is the owner's.
##
## [b]The mode that made this game need dot-objective.[/b] Everything before it is
## scored on kills, so [DotMatch] alone was enough; this one is scored on **holding a
## place**, and the difference is not a score limit — it is a capture curve where the
## second player is worth half a player, a block that pauses rather than undoes, a
## partial capture that decays over a minute, and a clock that FREEZES rather than
## resetting when the point changes hands. That last one is the whole tension of the
## mode and it is the thing every hand-written version gets wrong.
static func king_of_the_hill() -> ArenaMode:
	var mode := ArenaMode.new()
	mode.id = &"koth"
	mode.display_name = "King of the Hill"
	mode.description = "One point in the middle. Hold it for ninety seconds."
	mode.team_count = 2
	mode.friendly_fire = false
	mode.self_damage = true
	mode.objective_layout = &"koth"
	mode.preferred_map = &"dm_atrium"

	# One point wins it. The objective IS the score, so a kill limit on top would be a
	# second way to end a round that nobody is playing for.
	var rules := DotMatchRules.team_deathmatch(1)
	rules.display_name = "King of the Hill"
	rules.respawn_delay_sec = 5.0
	rules.spawn_protection_sec = 2.0
	rules.warmup_sec = 10.0
	rules.countdown_sec = 3.0
	rules.min_players = 2
	rules.intermission_sec = 8.0
	rules.match_end_sec = 15.0
	rules.suicide_points = 0
	rules.friendly_points = -1
	mode.rules = rules

	return mode


## Capture the flag: theirs to yours, and yours has to be home.
##
## The respawn is long on purpose. A capture is a journey across the map and a defender
## who is back in three seconds makes it one nobody completes; five seconds is what
## turns a kill near the flag into time on the clock.
static func capture_the_flag(limit: int = 3) -> ArenaMode:
	var mode := ArenaMode.new()
	mode.id = &"ctf"
	mode.display_name = "Capture the Flag"
	mode.description = "Take theirs to yours. First side to %d." % limit
	mode.team_count = 2
	mode.friendly_fire = false
	mode.self_damage = true
	mode.objective_layout = &"ctf"
	mode.preferred_map = &"dm_atrium"

	var rules := DotMatchRules.team_deathmatch(limit)
	rules.display_name = "Capture the Flag"
	rules.respawn_delay_sec = 5.0
	rules.spawn_protection_sec = 2.0
	rules.warmup_sec = 10.0
	rules.countdown_sec = 3.0
	rules.min_players = 2
	rules.intermission_sec = 8.0
	rules.match_end_sec = 15.0
	# Zero, not -1: a carrier who jumps into a pit to deny a capture has already given
	# the flag back, and charging them a point for it as well is paying twice for one
	# mistake. Deathmatch charges -1 because there the death IS the mistake.
	rules.suicide_points = 0
	rules.friendly_points = -1
	mode.rules = rules

	return mode


## The sides this mode plays with, ready to hand to a [DotTeamManager].
##
## [b]The spawn tags are the point.[/b] `DotTeam.spawn_tag` is what sends a side to its
## own end of the map, and it is read by `DotMatch._spawn_for`; a team mode whose teams
## have no tag spawns both sides out of one pool, which on a symmetric map means each
## side spawning in the other's base about half the time. The tags here are the ones
## `ArenaMap` writes — see [member ArenaMap.spawn_tags].
func teams() -> Array[DotTeam]:
	var out: Array[DotTeam] = []

	if team_count <= 1:
		return out

	var pair := DotTeam.standard_pair()
	pair[0].spawn_tag = &"red"
	pair[1].spawn_tag = &"blue"

	for index in range(min(team_count, pair.size())):
		out.append(pair[index])

	return out


func is_team_mode() -> bool:
	return team_count >= 2


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A mode needs an id.")

	if rules == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "Mode '%s' has no rules." % id
		)

	# A mode's two halves have to agree, and nothing else checks it. `team_based` is
	# what dot-match reads to decide whether to assign anybody a side at all, so a mode
	# claiming two teams over free-for-all rules puts everyone on no team and scores
	# them individually while calling itself Team Deathmatch — correct at every point
	# inside dot-match, and wrong.
	if is_team_mode() != rules.team_based:
		return DotResult.fail(
			DotError.CODE_INVALID,
			(
				"Mode '%s' has team_count %d but rules.team_based is %s."
				% [id, team_count, str(rules.team_based)]
			)
		)

	return rules.validate().wrap("Mode '%s' has unusable rules." % id)


func describe() -> Dictionary:
	return {
		"id": id,
		"display_name": display_name,
		"team_count": team_count,
		"friendly_fire": friendly_fire,
		"self_damage": self_damage,
		"preferred_map": preferred_map,
		"horde": horde,
		"player_props": player_props,
		"scatter_props": scatter_props,
		"score_limit": rules.score_limit if rules != null else 0,
		"team_based": rules.team_based if rules != null else false,
	}


func _to_string() -> String:
	return "ArenaMode(%s, %d team(s))" % [id, team_count]
