extends RefCounted

const ArenaStats := preload("arena_stats.gd")

## The boards this game orders players on, and the scope every one of them is cut by.
##
## [b]A board is one number per player, ordered. A stat is many numbers per player,
## accumulated.[/b] dot-leaderboard says so in its own notes and the distinction is
## the whole reason both addons are here: [ArenaStats] counts, and these order what was
## counted. [method DotLeaderboardManager.publish_stat] is the bridge — it reads the
## total out of the store rather than taking a value, so a board built this way can
## never disagree with the counter it came from.
##
## [b]Every board is scoped by mode, and that is a decision rather than a default.[/b]
## Kills in a team deathmatch and kills in a free-for-all are not the same achievement:
## one has half the map shooting at you and the other has all of it. A single "most
## kills" board over both is a board whose top is decided by which mode a player
## happened to play. [method DotLeaderboardDef.scoped] cuts one definition into the
## per-mode boards, and [method DotLeaderboardDef.scope_key] sorts the scope's keys so
## two callers who built the same dictionary in different orders address one board
## rather than two holding half the entries each.

const CHANNEL := "arena.boards"

## Most kills, lifetime, per mode.
const KILLS := &"arena.kills"

## Best kill streak, per mode.
const STREAK := &"arena.streak"

## Kills per death, two decimals. A ratio is POINTS, not SCORE.
const RATIO := &"arena.ratio"

## Rounds won.
const WINS := &"arena.wins"

## Damage dealt.
const DAMAGE := &"arena.damage"

## Fewest deaths per round played. A PENALTY board: lower is better.
const DEATHS := &"arena.deaths"


## Every board this game defines, unscoped. [method scope_for] cuts them.
static func definitions() -> Array[DotLeaderboardDef]:
	var out: Array[DotLeaderboardDef] = []

	out.append(_board(KILLS, DotLeaderboardDef.Kind.SCORE, "Most kills", "kills", 0))
	out.append(_board(STREAK, DotLeaderboardDef.Kind.SCORE, "Best streak", "kills", 0))
	out.append(_board(RATIO, DotLeaderboardDef.Kind.POINTS, "Kill/death", "", 2))
	out.append(_board(WINS, DotLeaderboardDef.Kind.SCORE, "Rounds won", "rounds", 0))
	out.append(_board(DAMAGE, DotLeaderboardDef.Kind.SCORE, "Damage dealt", "hp", 0))
	out.append(_board(DEATHS, DotLeaderboardDef.Kind.PENALTY, "Fewest deaths", "deaths", 0))

	return out


## The scope every submission on this server is filed under.
##
## Mode, and deliberately not map. A map is where you played; a mode is what game you
## were playing. Cutting by both would make a board per mode per map — six boards
## become thirty and every one of them holds a sixth of the entries, which is a
## leaderboard nobody is ever on.
static func scope_for(mode_id: StringName) -> Dictionary:
	return {"mode": String(mode_id)}


## Files everything a player's session earned, from their dot-stats values.
##
## [b]One call site, on purpose.[/b] Six boards derived from one values bag is six
## chances for a board to be fed the wrong stat, and the way this family loses those is
## by having the derivation in two places that drift. [ArenaProgress] calls this and
## nothing else does.
##
## Ratio and deaths-per-round are computed here rather than stored as stats, for
## [ArenaStats]' reason: a stored quotient is a third number that can disagree with the
## two it came from.
static func submit_session(
	manager: DotLeaderboardManager,
	mode_id: StringName,
	player_id: StringName,
	player_name: String,
	values: DotStatsValues
) -> void:
	if manager == null or values == null:
		return

	var scope := scope_for(mode_id)

	_submit(manager, KILLS, scope, player_id, player_name,
		values.get_value(ArenaStats.KILLS, 0.0))
	_submit(manager, STREAK, scope, player_id, player_name,
		values.get_value(ArenaStats.BEST_STREAK, 0.0))
	_submit(manager, WINS, scope, player_id, player_name,
		values.get_value(ArenaStats.ROUNDS_WON, 0.0))
	_submit(manager, DAMAGE, scope, player_id, player_name,
		values.get_value(ArenaStats.DAMAGE_DEALT, 0.0))

	# A ratio needs a sample size or the top of the board is whoever got one kill and
	# left. Ten rounds is the smallest number that is not a fluke and the largest that
	# does not shut a casual player out.
	if values.get_value(ArenaStats.ROUNDS_PLAYED, 0.0) >= 10.0:
		_submit(manager, RATIO, scope, player_id, player_name,
			ArenaStats.ratio_of(values))

		var rounds := values.get_value(ArenaStats.ROUNDS_PLAYED, 0.0)
		_submit(manager, DEATHS, scope, player_id, player_name,
			values.get_value(ArenaStats.DEATHS, 0.0) / rounds)


static func _submit(
	manager: DotLeaderboardManager,
	board_id: StringName,
	scope: Dictionary,
	player_id: StringName,
	player_name: String,
	value: float
) -> void:
	if value <= 0.0:
		# Nothing earned is not a result. A zero filed on a SCORE board is harmless
		# and a zero filed on the PENALTY board would take first place for ever.
		return

	var res := manager.submit(board_id, scope, player_id, player_name, value)

	if not res.ok:
		DotLog.debug(CHANNEL, "a board submission was refused", {
			"board": String(board_id), "why": res.error.message
		})


static func _board(
	id: StringName,
	kind: DotLeaderboardDef.Kind,
	display: String,
	unit: String,
	decimals: int
) -> DotLeaderboardDef:
	var board := DotLeaderboardDef.make(id, kind)
	board.display_name = display
	board.unit = unit
	board.decimals = decimals
	board.page_size = 25
	return board
