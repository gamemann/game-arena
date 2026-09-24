extends DotVoteSource

const ArenaGame := preload("arena_game.gd")
const ArenaMapDirector := preload("arena_map_director.gd")
const ArenaMaps := preload("arena_maps.gd")
const ArenaMode := preload("arena_mode.gd")
const ArenaModes := preload("arena_modes.gd")

## What the players of this server get to choose: the map, and the mode.
##
## [b]One source, because a [DotVoteDirector] has one.[/b] dot-vote ships
## [DotVoteMapSource] and [DotVoteGameSource] and neither is quite this: a map source
## alone cannot switch free-for-all to team deathmatch, and running two directors would
## mean two clocks, two rock-the-vote tallies and two cooldowns over one server.
##
## So a choice id carries what kind of change it is, in a prefix:
##
## [codeblock]
## map:dm_atrium     change the map, keep the mode
## mode:tdm          change the mode, keep the map
## [/codeblock]
##
## [b]The prefix IS the routing, and that is deliberate rather than tidy.[/b] Every
## alternative was some form of "look the bare id up in the map catalogue, and if it is
## not there try the mode catalogue" — which is a lookup that silently does the wrong
## thing the day somebody names a mode after a map. A ballot option is a string that
## travels through a nomination, a chat line and a history entry before anything acts
## on it, and a string whose meaning depends on which of two tables happens to hold it
## is a string that will one day mean both.
##
## Modes are offered in their own [member DotVoteChoice.group], so a ballot filled by
## [constant DotVoteRules.Fill.RANDOM] does not spend all six slots on modes.

const CHANNEL := "arena.vote"

const MAP_PREFIX := "map:"
const MODE_PREFIX := "mode:"

const GROUP_MAPS := &"maps"
const GROUP_MODES := &"modes"

## The catalogue maps are offered from. Required.
var catalogue: DotMapCatalogue = null

## What actually changes things. Required for [method apply].
var director: ArenaMapDirector = null

## The game, for the mode that is running and for what a mode change acts on.
var game: ArenaGame = null

## Offer mode changes at all. Off makes this a map vote.
var include_modes: bool = true


## Typed as the base on purpose: a script that names itself inside itself leaks the whole
## script graph at exit on Godot 4.7.2 (docs/gdscript-hazards.md). Callers cast.
static func of(
	p_catalogue: DotMapCatalogue, p_director: ArenaMapDirector, p_game: ArenaGame
) -> DotVoteSource:
	var source = new()
	source.catalogue = p_catalogue
	source.director = p_director
	source.game = p_game
	return source


func source_name() -> String:
	return "arena"


func is_usable() -> bool:
	return catalogue != null and catalogue.size() > 0


func choices() -> Array[DotVoteChoice]:
	var out: Array[DotVoteChoice] = []

	if catalogue == null:
		return out

	var mode: ArenaMode = game.mode if game != null else null

	for def in catalogue.maps:
		if not def.enabled:
			continue

		# A map that cannot host what is being played is not on the ballot. Offering
		# it and refusing the change afterwards is a vote whose winner does not
		# happen, which reads to the players as a broken server.
		if not ArenaMaps.supports_mode(def, mode):
			DotLog.debug(CHANNEL, "a map is off the ballot for the mode being played", {
				"map": String(def.id), "mode": String(mode.id) if mode != null else "",
			})
			continue

		out.append(_map_choice(def))

	if include_modes and game != null:
		for id in ArenaModes.ids():
			var candidate := ArenaModes.by_id(id)

			if candidate == null or (game.mode != null and candidate.id == game.mode.id):
				continue

			# Symmetrically: a mode the CURRENT map cannot host is not offered either.
			if director != null and director.current != null:
				if not ArenaMaps.supports_mode(director.current, candidate):
					continue

			out.append(_mode_choice(candidate))

	return out


func current_id() -> StringName:
	if director != null and director.current != null:
		return StringName(MAP_PREFIX + String(director.current.id))

	if game != null and game.map != null:
		return StringName(MAP_PREFIX + String(game.map.id))

	return &""


func supports_apply() -> bool:
	return director != null


## Makes the winning choice happen.
##
## A coroutine: a map change waits for every peer to have the content before the world
## swaps, and a mode change is a map change to the same map.
func apply(id: StringName) -> DotResult:
	if not supports_apply():
		return DotResult.fail(
			DotError.CODE_STATE, "This vote source has nothing to change with."
		)

	var text := String(id)

	if text.begins_with(MAP_PREFIX):
		return await director.change_to(StringName(text.substr(MAP_PREFIX.length())))

	if text.begins_with(MODE_PREFIX):
		return await _apply_mode(StringName(text.substr(MODE_PREFIX.length())))

	return DotResult.fail(
		DotError.CODE_INVALID,
		"A vote choice must say whether it is a map or a mode.",
		text
	)


## Changes the mode by re-running the current map with it.
##
## [b]There is no cheaper way, and pretending otherwise is the bug.[/b] The mode builds
## the match rules, the team manager and the damage rules, and dot-match reads
## `team_based` to decide whether to assign anybody a side at all — so assigning a new
## mode to a running game leaves a match that scores individually while calling itself
## Team Deathmatch. Going through the same path a map change takes rebuilds all three
## and puts every player back through team assignment, which is what a mode change
## actually is.
func _apply_mode(mode_id: StringName) -> DotResult:
	var mode := ArenaModes.by_id(mode_id)

	if mode == null:
		return DotResult.fail(DotError.CODE_IO, "No such mode.", String(mode_id))

	if director.current == null:
		return DotResult.fail(
			DotError.CODE_STATE, "There is no current map to change the mode on."
		)

	if not ArenaMaps.supports_mode(director.current, mode):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The map running has no tagged spawns, so it cannot host a team mode.",
			"%s / %s" % [String(director.current.id), String(mode_id)]
		)

	# Stamped into the def's own metadata, because the change goes through
	# `ArenaMapSession`, which reads the mode from there. Setting it on the game
	# directly would be assigning the mode to a running match — the thing the note
	# above says not to do.
	director.current.meta["mode"] = String(mode_id)

	# INFO, because a mode change is a map change to the same map — every player is
	# re-teamed and the match restarts — and the director's own line names only the map.
	DotLog.info(CHANNEL, "the vote changes the mode; the map re-runs under it", {
		"map": String(director.current.id),
		"from": String(game.mode.id) if game != null and game.mode != null else "",
		"to": String(mode_id),
	})

	return await director.change_to(director.current.id)


func _map_choice(def: DotMapDef) -> DotVoteChoice:
	var choice := DotVoteChoice.of(
		StringName(MAP_PREFIX + String(def.id)), def.name_or_id()
	)
	choice.group = GROUP_MAPS
	choice.description = def.description
	choice.min_players = def.min_players
	choice.max_players = def.max_players
	choice.meta = {"map": String(def.id)}

	# Per-map vote settings ride in the map's own metadata, under the same `vote` key
	# dot-vote's own sources use. An operator learns the convention once.
	var settings: Variant = def.meta.get("vote")

	if settings is Dictionary:
		_apply_settings(choice, settings as Dictionary)

	return choice


func _mode_choice(mode: ArenaMode) -> DotVoteChoice:
	var choice := DotVoteChoice.of(
		StringName(MODE_PREFIX + String(mode.id)), mode.display_name
	)
	choice.group = GROUP_MODES
	choice.description = "Keep the map, change to %s." % mode.display_name
	choice.meta = {"mode": String(mode.id)}
	return choice


func _apply_settings(choice: DotVoteChoice, settings: Dictionary) -> void:
	if settings.has("weight"):
		choice.weight = float(settings["weight"])

	if settings.has("time_limit_sec"):
		choice.time_limit_sec = float(settings["time_limit_sec"])

	if settings.has("round_limit"):
		choice.round_limit = int(settings["round_limit"])

	if settings.has("nominate_only"):
		choice.nominate_only = bool(settings["nominate_only"])

	if settings.has("cooldown"):
		choice.cooldown_override = int(settings["cooldown"])

	if settings.has("enabled"):
		choice.enabled = bool(settings["enabled"])


func describe() -> Dictionary:
	var out := super.describe()
	out["usable"] = is_usable()
	out["maps"] = catalogue.size() if catalogue != null else 0
	out["modes"] = ArenaModes.ids().size() if include_modes else 0
	return out
