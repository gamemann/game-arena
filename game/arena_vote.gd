extends Node

const ArenaGame := preload("arena_game.gd")
const ArenaMapDirector := preload("arena_map_director.gd")
const ArenaVoteSource := preload("arena_vote_source.gd")

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

## The vote's sound cues, as ids in [code]ArenaPresentation.sound_catalogue()[/code]. One
## copy: the rules name them and the catalogue defines them, both from here.
const CUE_START := &"vote_start"
const CUE_END := &"vote_end"
const CUE_WARNING := &"vote_warning"
const CUE_COUNT := &"vote_count"

## The key in the running game's descriptor metadata an operator's overrides are read
## from — [code]metadata: map_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "map_vote"

## A ballot opened. The host relays it to clients.
## An extend raised the match's score limit to [param limit]. The module tells clients.
signal score_limit_raised(limit: int)

signal vote_opened(options: Array, seconds: float)

## A ballot closed. Carries the whole result, including why.
signal vote_closed(result: DotVoteResult)

## Somebody rocked the vote.
signal rocked(voter: StringName, votes: int, needed: int)

## Something for every client to hear or count: a [code]cue_*[/code] id, or a second of
## the countdown before a ballot. One of the two is empty or zero. The module puts it on
## the wire as [constant ArenaEvents.Kind].VOTE; see [method setup].
signal cue_due(cue: StringName, seconds_left: int, runoff: bool)

## What is going to happen, once the delay or the round is over.
signal change_due(id: StringName, choice: DotVoteChoice)

@export_group("Wiring")

## Whether this instance decides anything.
##
## Off on a client, which mirrors a vote so it can draw the ballot and must never
## apply a result. That is exactly what [member DotVoteDirector.auto_apply] is for,
## and a client that left it on would try to change its own map.
@export var authoritative: bool = true

## The file a server owner configures this game's map vote in. Empty skips it.
##
## [b]The rules in [method _rules] are this game's DEFAULTS, not its configuration.[/b]
## They layer the way every [DotConfig] in the family does, so an owner changes a
## number without touching code:
##
## [codeblock]
## _rules()  <  game.yml metadata: map_vote:  <  this file  <  DOT_VOTE_*  <  --vote-*
## [/codeblock]
##
## The file is JSON, keyed exactly as [DotVoteRules] is, enums by name. The end-of-map
## vote and its extend option, which is what an owner usually wants to change:
##
## [codeblock]
## {
##     "end_vote": true,          "vote_lead_sec": 90,
##     "include_extend": true,    "extend_seconds": 600,    "max_extends": 3
## }
## [/codeblock]
##
## [code]DOT_VOTE_EXTEND_SECONDS=900[/code] or [code]--vote-include-extend=false[/code]
## do the same for one run. A result that does not validate is refused whole and the
## defaults below stand, with the reason in the log.
@export var config_path: String = "user://cfg/arena_vote.json"

var game: ArenaGame = null
var maps: ArenaMapDirector = null

var director: DotVoteDirector = null
var source: ArenaVoteSource = null
var commands: DotVoteCommands = null

## Says a line to the players. Set by the host; a dedicated server points it at chat.
var announce_fn: Callable = Callable()

## Whether a voter is an admin, for `rtv_admin_instant` and nomination bypasses.
var is_admin_fn: Callable = Callable()

## What dot-vote's commands are called here. `vote` rather than dot-vote's `votefor`,
## because `!vote 2` is what this game's players have always typed.
const COMMAND_NAMES := {"vote": "vote"}

## The match whose score and rounds the vote is told about. Replaced on every map change,
## because a map change builds a new match; see [method _bind_match].
var _match: DotMatch = null



## Builds the director over the game's maps and modes.
func setup() -> DotResult:
	if game == null or maps == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The vote needs a game and a map director."
		)

	source = ArenaVoteSource.of(maps.session.catalogue, maps, game) as ArenaVoteSource

	if not source.is_usable():
		return DotResult.fail(
			DotError.CODE_STATE, "There is nothing to vote for."
		)

	director = DotVoteDirector.new()
	director.name = "VoteDirector"
	director.rules = configured_rules()
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

	# Two signals, two messages, rather than one merged in here. The director emits a
	# countdown second and that second's cue separately, and merging them would mean
	# working out which cue belongs to which second — which is dot-vote's knowledge, not
	# this file's. A ten-second countdown is twenty small reliable messages.
	director.cue.connect(
		func(id: StringName) -> void: cue_due.emit(id, 0, false)
	)
	director.countdown_tick.connect(
		func(seconds_left: int, runoff: bool) -> void:
			cue_due.emit(&"", seconds_left, runoff)
	)

	# A host that enforces its own score limit has to hear an extend, or the match ends on
	# the old number with the vote believing it extended. dot-match is that host here.
	director.score_limit_changed.connect(_on_score_limit_changed)

	_bind_match()

	# The map the server booted on, so the clock starts and the cooldown history has
	# something in it. Everything after this comes through `note_changed`.
	director.begin(source.current_id())

	return DotResult.success(self)


## [method _rules], with the server owner's layers over it. See [member config_path].
func configured_rules() -> DotVoteRules:
	var rules := _rules()
	var layered := rules.layer_over_defaults(
		config_path, DotVoteGameSource.running_game_metadata(METADATA_KEY)
	)

	if not layered.ok:
		# Loud and not fatal. A server that refused to start over its vote file would be
		# a server an operator cannot get back; this one runs on its tested defaults and
		# says exactly what was wrong.
		DotLog.error(CHANNEL, "the map vote configuration is not usable; using the defaults", {
			"path": config_path,
			"why": layered.error.message,
			"detail": layered.error.detail,
		})

	return rules


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

	# Ten seconds' warning, counted down on every client, before a ballot opens over a
	# fight in progress — a ballot that appears mid-fight is one most people close unread.
	rules.vote_warning_sec = 10.0

	# The ids ArenaPresentation's catalogue plays. dot-vote ships every cue empty and
	# names no audio class; this game has a catalogue, so it has something to name.
	rules.cue_vote_start = String(CUE_START)
	rules.cue_vote_end = String(CUE_END)
	rules.cue_warning = String(CUE_WARNING)
	rules.cue_runoff_warning = String(CUE_WARNING)
	rules.cue_countdown = String(CUE_COUNT)

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

	_bind_match()


## Advances the vote clock, and reports the leading score. Once per tick, from whatever
## drives the game.
func advance(delta: float) -> void:
	if director == null:
		return

	# Every tick, because a mode change builds a new match without `maps.map_changed` —
	# `arena_mode` calls `game.change_map` directly — and a vote left holding the freed one
	# reports no score and hears no round end, so "apply at the end of the round" becomes
	# "when the clock runs out". One comparison when nothing changed.
	_bind_match()
	director.advance(delta)
	_report_score()


## Tells the clock a round ended, for a round-limited vote.
##
## [b]Connected to dot-match's `round_ended`, and it was called by nothing.[/b] This game
## applies a vote's winner at the end of a round, and until this was connected "the end
## of a round" reached the director only as the clock running out — so the rule that a
## map never changes under a fight in progress was written down and not kept.
func note_round_end() -> bool:
	return director.note_round_end() if director != null else false


## The leading score in the match in progress: the best player's frags, or the leading
## team's total in a team mode — whatever dot-match's own score limit is measured on.
##
## [b]Per match, and a match here is a round.[/b] dot-match zeroes the scoreboard at the
## start of every round, so a vote `score_limit` is a frag limit on one match, the way the
## community choosers read the frag limit — not a total across the map.
func leading_score() -> int:
	if _match == null or not is_instance_valid(_match) or _match.scoreboard == null:
		return 0

	if _match.rules != null and _match.rules.team_based:
		var best := 0

		for value: Variant in _match.scoreboard.team_scores().values():
			best = maxi(best, int(value))

		return best

	return _match.scoreboard.best_score()


## Polled rather than connected: a score moves on a kill, an assist, an objective and a
## team award, from four places in dot-match, and one integer compared once a tick is
## cheaper than four connections that have to be remade on every map change.
func _report_score() -> void:
	var top := leading_score()

	# Against the clock's own memory rather than a copy here: the clock zeroes it on every
	# restart — a new map, an extend, a ballot that kept the map — and a cached copy would
	# then hold back a score that had not moved but that the clock had forgotten.
	if top == director.clock.top_score:
		return

	director.note_score(top)


## Follows the game onto its current match. A map change builds a new one and frees the
## old, and a connection to a freed match would simply never fire again.
func _bind_match() -> void:
	var node: DotMatch = game.match_node if game != null else null

	if node == _match:
		return

	if (
		_match != null and is_instance_valid(_match)
		and _match.round_ended.is_connected(_on_round_ended)
	):
		_match.round_ended.disconnect(_on_round_ended)

	_match = node

	if _match != null:
		_match.round_ended.connect(_on_round_ended)


func _on_round_ended(_round: int, _winner: int, _outcome: DotMatchRules.Outcome) -> void:
	note_round_end()


## An extend raised the vote's score limit; raise the match's with it, or the match ends
## on the old number and a new match starts from nothing under a limit it can never
## reach. Only upwards, and only where the match has a limit of its own.
func _on_score_limit_changed(limit: int) -> void:
	if _match == null or not is_instance_valid(_match) or _match.rules == null:
		return

	if _match.rules.score_limit > 0 and limit > _match.rules.score_limit:
		_match.rules.score_limit = limit
		score_limit_raised.emit(limit)

		DotLog.info(CHANNEL, "an extend raised the match's score limit", {"limit": limit})


## dot-vote's commands, on [param host] — the module, so they go when it does.
##
## [b]These are the only vote commands, and that is the point.[/b] This game had its own
## `!rtv`, `!nominate`, `!vote`, `!nextmap` and `!timeleft` in the module's chat handler,
## and none of dot-vote's operator commands — `setnextmap`, `nominate_addmap`,
## `forcertv`, `votereload` — existed here at all. dot-vote's are registered on the
## console with `.with_chat()`, so a `!rtv` the chat handler does not claim reaches them;
## two handlers for one name is the collision [code]TmcVote[/code] documents, where
## [DotConsole] keeps the first registration and the second is silently dead.
func install_commands(host: Object) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote to command.")

	commands = DotVoteCommands.new()
	commands.director = director
	commands.names = COMMAND_NAMES
	# A player types `dm_atrium`; the ballot's id is `map:dm_atrium`.
	commands.resolve_fn = func(text: String) -> StringName:
		return _qualify(StringName(text))
	# This game's voters are the bare session id — `str(userid)`, which is what
	# `voters_fn` lists and what the module forgets on a disconnect. dot-vote's default is
	# `u<userid>`, and two spellings of one voter is a player who can rock the vote twice.
	commands.voter_fn = func(ctx: Object) -> StringName:
		var session: Variant = ctx.get("session")

		if session is Object and (session as Object).get("userid") != null:
			return StringName(str((session as Object).get("userid")))

		return &"console"

	return commands.bind(host)


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
