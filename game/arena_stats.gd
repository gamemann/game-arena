extends RefCounted

## Every per-player number this game counts, declared in one place.
##
## [b]The ids are the contract, and they are the contract three ways.[/b] The same
## strings name a stat in [DotStatsSchema], a requirement in [ArenaAwards]' achievement
## rules, and a board's source in [ArenaBoards]. Three subsystems that never import
## each other agree because they all read the constants below, which is the only reason
## a rename cannot leave two of them counting different things under one name.
##
## dot-stats' own note is worth repeating here because it decides what belongs in this
## file and what does not: [b]a stat is not a board.[/b] A board is one number per
## player, ordered; a stat is many numbers per player, accumulated, and nothing in
## dot-stats orders anything. "Most kills" is a board over the [constant KILLS] stat and
## it lives in [ArenaBoards].
##
## [codeblock]
## var tracker := DotStatsTracker.new()
## tracker.schema = ArenaStats.schema()
## add_child(tracker)
## tracker.begin(&"7", "Someone")
## tracker.record(&"7", ArenaStats.KILLS)
## [/codeblock]

# No `CHANNEL`: this is a schema of ids and two pure functions, and it has nothing to
# report. The tracker that records against it is dot-stats', and logs there.

# --- Fighting --------------------------------------------------------------

const KILLS := &"arena.kills"
const DEATHS := &"arena.deaths"
const SUICIDES := &"arena.suicides"
const TEAM_KILLS := &"arena.team_kills"
const HEADSHOTS := &"arena.headshots"
const DAMAGE_DEALT := &"arena.damage_dealt"
const DAMAGE_TAKEN := &"arena.damage_taken"

# --- Shooting --------------------------------------------------------------

const SHOTS_FIRED := &"arena.shots_fired"
const SHOTS_HIT := &"arena.shots_hit"

# --- Bests -----------------------------------------------------------------

const BEST_STREAK := &"arena.best_streak"
const BEST_ROUND_KILLS := &"arena.best_round_kills"

# --- Match -----------------------------------------------------------------

const ROUNDS_PLAYED := &"arena.rounds_played"
const ROUNDS_WON := &"arena.rounds_won"
const MATCHES_PLAYED := &"arena.matches_played"
const MATCHES_WON := &"arena.matches_won"
const PLAYTIME_SEC := &"arena.playtime_sec"

# --- Sandbox ---------------------------------------------------------------

const PROPS_SPAWNED := &"arena.props_spawned"
const NPC_KILLS := &"arena.npc_kills"


## Every id above, in declaration order. What a caller iterates.
##
## Written out rather than derived, because a constant is not enumerable in GDScript
## and the alternative — reading the schema back — would make this list depend on the
## thing that is built from it.
static func ids() -> Array[StringName]:
	return [
		KILLS, DEATHS, SUICIDES, TEAM_KILLS, HEADSHOTS,
		DAMAGE_DEALT, DAMAGE_TAKEN,
		SHOTS_FIRED, SHOTS_HIT,
		BEST_STREAK, BEST_ROUND_KILLS,
		ROUNDS_PLAYED, ROUNDS_WON, MATCHES_PLAYED, MATCHES_WON, PLAYTIME_SEC,
		PROPS_SPAWNED, NPC_KILLS,
	]


## The schema a [DotStatsTracker] is given.
##
## [b]`publish` is off on everything except the eight figures a player page would
## show.[/b] dot-stats defaults it off per stat deliberately — a server's counters are
## the server's until somebody decides they are public — and the ones left unpublished
## here are inputs to an achievement rather than a number anybody reads: shots fired
## and shots hit exist so "hit 60% of your shots" is checkable, and publishing two
## six-figure counters to say one percentage is a worse trade every time.
static func schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()

	_counter(schema, KILLS, "Kills", "kills", true)
	_counter(schema, DEATHS, "Deaths", "deaths", true)
	_counter(schema, SUICIDES, "Suicides", "deaths", false)
	_counter(schema, TEAM_KILLS, "Team kills", "kills", false)
	_counter(schema, HEADSHOTS, "Headshots", "kills", true)

	_counter(schema, DAMAGE_DEALT, "Damage dealt", "hp", true)
	_counter(schema, DAMAGE_TAKEN, "Damage taken", "hp", false)

	_counter(schema, SHOTS_FIRED, "Shots fired", "shots", false)
	_counter(schema, SHOTS_HIT, "Shots landed", "shots", false)

	_best(schema, BEST_STREAK, "Best kill streak", "kills", true)
	_best(schema, BEST_ROUND_KILLS, "Best round", "kills", true)

	_counter(schema, ROUNDS_PLAYED, "Rounds played", "rounds", false)
	_counter(schema, ROUNDS_WON, "Rounds won", "rounds", true)
	_counter(schema, MATCHES_PLAYED, "Matches played", "matches", false)
	_counter(schema, MATCHES_WON, "Matches won", "matches", true)

	var time := DotStatsDef.make(PLAYTIME_SEC, DotStatsDef.Kind.COUNTER, "Time played")
	time.unit = "s"
	time.decimals = 0
	time.publish = true
	schema.stats.append(time)

	_counter(schema, PROPS_SPAWNED, "Props spawned", "props", false)
	_counter(schema, NPC_KILLS, "Monsters killed", "kills", true)

	return schema


## Accuracy as a fraction, from a values bag. Never a division by zero.
##
## Derived rather than stored: a stored percentage is a number that can disagree with
## the two counters it came from, and this family has shipped that disagreement (the
## merge rule duplicated between dot-stats and the backbone) often enough to know what
## it costs.
static func accuracy_of(values: DotStatsValues) -> float:
	var fired := values.get_value(SHOTS_FIRED, 0.0)

	if fired <= 0.0:
		return 0.0

	return clampf(values.get_value(SHOTS_HIT, 0.0) / fired, 0.0, 1.0)


## Kills per death, counting a death-less player as their kill count.
static func ratio_of(values: DotStatsValues) -> float:
	var deaths := values.get_value(DEATHS, 0.0)
	var kills := values.get_value(KILLS, 0.0)
	return kills if deaths <= 0.0 else kills / deaths


static func _counter(
	schema: DotStatsSchema,
	id: StringName,
	display: String,
	unit: String,
	publish: bool
) -> void:
	var def := DotStatsDef.make(id, DotStatsDef.Kind.COUNTER, display)
	def.unit = unit
	def.publish = publish
	schema.stats.append(def)


static func _best(
	schema: DotStatsSchema,
	id: StringName,
	display: String,
	unit: String,
	publish: bool
) -> void:
	var def := DotStatsDef.make(id, DotStatsDef.Kind.BEST, display)
	def.unit = unit
	def.publish = publish
	schema.stats.append(def)
