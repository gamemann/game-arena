class_name ArenaMode
extends Resource

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
		"score_limit": rules.score_limit if rules != null else 0,
		"team_based": rules.team_based if rules != null else false,
	}


func _to_string() -> String:
	return "ArenaMode(%s, %d team(s))" % [id, team_count]
