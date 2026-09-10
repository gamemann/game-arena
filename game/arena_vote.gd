class_name ArenaVote
extends Node

## The players decide what plays next.
##
## Wraps [DotVoteDirector] over [ArenaVoteSource], and the wrapping is four callables
## and one rule about who calls [method DotVoteDirector.begin]. Everything else — the
## ballot, the counting method, the tie-breaks, the quorum, nominations, rock the vote,
## the cooldowns, the extensions — is dot-vote's fifty-five settings and none of it is
## restated here.
##
## [b]`begin_on_apply` is off, and getting that wrong halves every cooldown.[/b] The
## director can announce a change it just made, and so can the host through its own
## "the map changed" signal — which is the one that has to be connected, because it
## also fires for an operator typing `arena_map` by hand. Both firing means two entries
## in the play history for one play, and a "not in the last five maps" cooldown that is
## quietly a cooldown of two or three. dot-vote's own notes found this by running the
## addon inside a real host, which is the only place it is visible.
##
## [codeblock]
## var vote := ArenaVote.new()
## vote.game = game
## vote.maps = map_director
## add_child(vote)
## vote.setup()
## vote.announce_fn = func(line: String) -> void: server.broadcast_message(line)
## [/codeblock]

const CHANNEL := "arena.vote"

## A ballot opened. The host relays it to clients.
signal vote_opened(options: Array, seconds: float)

## A ballot closed. Carries the whole result, including why.
signal vote_closed(result: DotVoteResult)

## Somebody rocked the vote.
signal rocked(voter: StringName, votes: int, needed: int)

## What is going to happen, once the delay or the round is over.
signal change_due(id: StringName, choice: DotVoteChoice)

@export_group("Wiring")

## Whether this instance decides anything.
##
## Off on a client, which mirrors a vote so it can draw the ballot and must never
## apply a result. That is exactly what [member DotVoteDirector.auto_apply] is for,
## and a client that left it on would try to change its own map.
@export var authoritative: bool = true

var game: ArenaGame = null
var maps: ArenaMapDirector = null

var director: DotVoteDirector = null
var source: ArenaVoteSource = null
var commands: DotVoteCommands = null

## Says a line to the players. Set by the host; a dedicated server points it at chat.
var announce_fn: Callable = Callable()

## Whether a voter is an admin, for `rtv_admin_instant` and nomination bypasses.
var is_admin_fn: Callable = Callable()


## Builds the director over the game's maps and modes.
func setup() -> DotResult:
	if game == null or maps == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The vote needs a game and a map director."
		)

	source = ArenaVoteSource.of(maps.session.catalogue, maps, game)

	if not source.is_usable():
		return DotResult.fail(
			DotError.CODE_STATE, "There is nothing to vote for."
		)

	director = DotVoteDirector.new()
	director.name = "VoteDirector"
	director.rules = _rules()
	director.source = source
	director.auto_apply = authoritative
	# See the class note. The host's own "it changed" signal is what calls begin().
	director.begin_on_apply = false
	# The game's tick drives this, not the frame clock: a server that stalls should not
	# lose that time off its map.
	director.self_advance = false
	director.register_service = authoritative

	# How many players there are. Everything with a threshold in it — the rtv
	# fraction, the quorum, `min_players_to_vote` — is a fraction of this, so a
	# director without it refuses every vote and says only "too few players".
	director.player_count_fn = func() -> int:
		return game.players().size() if game != null else 0

	director.voters_fn = func() -> Array:
		var out: Array = []

		if game == null:
			return out

		for id in game.player_ids():
			out.append(StringName(str(id)))

		return out

	director.is_admin_fn = func(voter: StringName) -> bool:
		return is_admin_fn.is_valid() and bool(is_admin_fn.call(voter))

	# Nobody spectates in this game yet. Declared anyway, because the alternative is
	# `spectators_may_vote` being a setting that reads correctly and decides nothing —
	# and dot-vote's own notes have a whole section on the one that did exactly that.
	director.is_spectator_fn = func(voter: StringName) -> bool:
		if game == null:
			return false

		var player := game.player_for(String(voter).to_int())
		return player == null

	director.announce_fn = func(line: String) -> void:
		if announce_fn.is_valid():
			announce_fn.call(line)

	add_child(director)

	director.vote_opened.connect(
		func(options: Array, seconds: float) -> void:
			vote_opened.emit(options, seconds)
	)
	director.vote_closed.connect(
		func(result: DotVoteResult) -> void: vote_closed.emit(result)
	)
	director.rocked.connect(
		func(voter: StringName, votes: int, needed: int) -> void:
			rocked.emit(voter, votes, needed)
	)
	director.change_due.connect(
		func(id: StringName, choice: DotVoteChoice) -> void:
			change_due.emit(id, choice)
	)

	# The map the server booted on, so the clock starts and the cooldown history has
	# something in it. Everything after this comes through `note_changed`.
	director.begin(source.current_id())

	return DotResult.success(self)


## The rules this game votes by.
##
## [b]Instant runoff, not plurality, and that is the one setting worth arguing
## about.[/b] A six-option map vote decided by plurality is regularly won by something
## a fifth of the server wanted, because the other four fifths split four ways. Every
## timer and arena community that has run a map vote for long enough has ended up here.
func _rules() -> DotVoteRules:
	var rules := DotVoteRules.new()

	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	rules.vote_lead_sec = 90.0
	rules.duration_sec = 1800.0
	rules.vote_duration_sec = 25.0
	rules.method = DotVoteRules.Method.INSTANT_RUNOFF
	rules.tie_break = DotVoteRules.TieBreak.RANDOM
	rules.max_options = 6

	# Extending is real here: an arena match that is one round from a decision should
	# not be cut off by a map clock. Three extensions of ten minutes is the ceiling.
	rules.include_extend = true
	rules.extend_seconds = 600.0
	rules.max_extends = 3

	rules.rtv_enabled = true
	rules.rtv_fraction = 0.6
	rules.rtv_min_players = 2
	rules.rtv_delay_sec = 120.0

	rules.nominations_enabled = true
	rules.nomination_seconding = true
	rules.nomination_slots = 2

	# Applied at the end of a round rather than immediately: a map that changes under
	# a fight in progress is a fight nobody got to finish.
	rules.apply = DotVoteRules.Apply.END_OF_ROUND
	rules.apply_delay_sec = 5.0

	# Two maps ship, so a "not in the last five" cooldown would leave nothing to
	# offer. dot-vote's `cooldown_max_fraction` caps this against the pool size at
	# runtime, and one is the honest number for a catalogue this small.
	rules.cooldown = 1

	return rules


## Tells the director what is running, after a change from ANY cause.
##
## Connected to the map director's own signal by the host. See the class note on
## `begin_on_apply`: this is the one call site, and having two is the bug.
func note_changed() -> void:
	if director != null and source != null:
		director.begin(source.current_id())


## Advances the vote clock. Once per tick, from whatever drives the game.
func advance(delta: float) -> void:
	if director != null:
		director.advance(delta)


## Tells the clock a round ended, for a round-limited vote.
func note_round_end() -> bool:
	return director.note_round_end() if director != null else false


# --- What a player does ----------------------------------------------------

func rock_the_vote(voter: StringName) -> DotResult:
	return (
		director.rock_the_vote(voter) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func nominate(voter: StringName, id: StringName) -> DotResult:
	return (
		director.nominate(voter, _qualify(id)) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func cast_one(voter: StringName, choice: StringName) -> DotResult:
	return (
		director.cast_one(voter, _qualify(choice)) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func is_voting() -> bool:
	return director != null and director.is_voting()


func forget_voter(voter: StringName) -> void:
	if director != null:
		director.forget_voter(voter)


## Accepts a bare map or mode name and returns the prefixed choice id.
##
## [b]A player types `dm_atrium`, not `map:dm_atrium`.[/b] The prefix exists so a
## choice id can never be ambiguous once it is inside the system; it would be a poor
## thing to make somebody type. So this is the one place bare names are resolved, it
## resolves against the ballot's own options rather than guessing, and an id that is
## already qualified passes straight through.
func _qualify(id: StringName) -> StringName:
	var text := String(id)

	if text.begins_with(ArenaVoteSource.MAP_PREFIX) or text.begins_with(ArenaVoteSource.MODE_PREFIX):
		return id

	if source == null:
		return id

	for candidate in source.ids():
		var full := String(candidate)

		if full.ends_with(":" + text):
			return candidate

	return id


func describe() -> Dictionary:
	return {
		"authoritative": authoritative,
		"director": director.describe() if director != null else {},
		"source": source.describe() if source != null else {},
	}


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()
