extends Node

const ArenaAwards := preload("arena_awards.gd")
const ArenaBoards := preload("arena_boards.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaStats := preload("arena_stats.gd")

## What a player keeps when the match ends: statistics, achievements and boards.
##
## [b]Three addons that have never heard of each other, joined in one file.[/b]
## dot-stats counts, dot-achievements decides what counting earns you, and
## dot-leaderboard orders what was counted. None of them knows what a kill is; all
## three know what a number is. This node is the only place in the project that knows
## both, and it is deliberately a node rather than lines in [ArenaModule] because a
## listen server, a dedicated server and the headless suite all want it and only one of
## them has a [DotServer].
##
## [codeblock]
## var progress := ArenaProgress.new()
## add_child(progress)
## progress.attach(game)
## progress.begin(session.userid, session.display_name)
## [/codeblock]
##
## [b]The link between stats and achievements is not a signal connection.[/b] dot-stats'
## `recorded` carries the player's SESSION total — its whole design is that a session is
## what a server counts and a delta is what it reports — and an achievement is about a
## lifetime. Wiring one into the other directly adds the running total to the lifetime
## total on every kill: two after the second, five after the third, nine after the
## fourth. [DotAchievementStatsLink] exists for exactly that and it is what is used
## here; the reason it is worth a paragraph is that the wrong version compiles, runs,
## and is only visibly wrong to somebody who reads a player's numbers a week later.

const CHANNEL := "arena.progress"

## Emitted when a player unlocks something, so a HUD can say so.
signal award_unlocked(player_id: int, achievement: DotAchievement)

@export_group("Reporting")

## Send statistics and unlocks to the backbone. Off by default, like both addons'.
@export var report_to_backbone: bool = false

@export_range(0.0, 600.0, 5.0) var report_interval: float = 30.0

@export_group("Storage")

## Where achievement progress is kept. Empty keeps it in memory only.
##
## A dedicated server wants a directory; the headless suite wants memory, because a
## suite that writes a player's lifetime totals to disk is a suite that passes
## differently the second time it is run.
@export_dir var progress_dir: String = ""

var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var boards: DotLeaderboardManager = null

## The differencer between the two. See the class note.
var link: DotAchievementStatsLink = null

var _game: ArenaGame = null

## player id -> seconds of playtime not yet filed as a whole second.
var _playtime: Dictionary = {}

## player id -> kills so far this round.
var _round_kills: Dictionary = {}

var _attached: bool = false

## Whether the combat and match signals of the CURRENT world are connected.
var _bound: bool = false


## Builds the three trackers and connects them to the game.
##
## Call once, after this node is in the tree. [param game] must already have run
## [method ArenaGame.setup] — the combat manager is what the shot and damage counters
## hang off, and it does not exist before then.
func attach(game: ArenaGame) -> DotResult:
	if _attached:
		return DotResult.fail(DotError.CODE_STATE, "Already attached.")

	if game == null or game.combat == null or game.match_node == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"ArenaProgress needs a game that has been set up.",
		)

	_game = game

	var built := _build()

	if not built.ok:
		return built

	game.player_killed.connect(_on_killed)
	bind_world()

	_attached = true
	return DotResult.success(self)


## Connects to the combat manager and the match node the game is running right now.
##
## [b]Separate from [method attach] because those two objects do not survive a map
## change.[/b] [method ArenaGame.change_map] frees both and builds new ones, and a
## progress node still connected to the old pair counts nothing afterwards — silently,
## because a signal that is never emitted is indistinguishable from a quiet game.
##
## The game's own `player_killed` is NOT re-bound here: the game outlives its world, so
## that connection is made once in [method attach] and stays. Deliberately not
## dot-match's `kill_recorded` either — the game emits `player_killed` AFTER the
## scoreboard and the feed have seen it, which is the moment the entry's `streak` field
## is correct.
func bind_world() -> void:
	if _game == null or _game.combat == null or _game.match_node == null:
		return

	_game.combat.shot_resolved.connect(_on_shot_resolved)
	_game.combat.damage_applied.connect(_on_damage_applied)
	_game.match_node.round_started.connect(_on_round_started)
	_game.match_node.round_ended.connect(_on_round_ended)
	_game.match_node.match_ended.connect(_on_match_ended)

	_bound = true


## Disconnects from the current world. Called before the game frees it.
func unbind_world() -> void:
	if not _bound or _game == null:
		return

	if _game.combat != null and is_instance_valid(_game.combat):
		_game.combat.shot_resolved.disconnect(_on_shot_resolved)
		_game.combat.damage_applied.disconnect(_on_damage_applied)

	if _game.match_node != null and is_instance_valid(_game.match_node):
		_game.match_node.round_started.disconnect(_on_round_started)
		_game.match_node.round_ended.disconnect(_on_round_ended)
		_game.match_node.match_ended.disconnect(_on_match_ended)

	_bound = false


## [method unbind_world] and [method bind_world], for a caller that has just swapped
## the world between them.
func rebind_world() -> void:
	unbind_world()
	bind_world()


func _build() -> DotResult:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = ArenaStats.schema()
	stats.report_to_backbone = report_to_backbone
	stats.report_interval = report_interval
	stats.define_on_start = report_to_backbone
	add_child(stats)

	var stats_started := stats.start()

	if not stats_started.ok:
		return stats_started.wrap("The arena stats tracker could not start")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = ArenaAwards.catalogue()
	achievements.report_to_backbone = report_to_backbone
	achievements.autosave_interval = report_interval
	# Registered under its own service name so nothing else has to be handed one; the
	# tracker publishes itself, which is how a console command finds it.
	achievements.register_as = DotAchievementTracker.SERVICE

	if progress_dir != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = progress_dir
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)

	var awards_started := achievements.start()

	if not awards_started.ok:
		return awards_started.wrap("The arena achievement tracker could not start")

	achievements.unlocked.connect(_on_unlocked)

	# The differencer. `stats` is assigned rather than looked up, because this node
	# owns both and a registry lookup would find whichever tracker was registered last
	# in a process running two games — which is exactly the deployment shape this
	# family builds for.
	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	var linked := link.start()

	if not linked.ok:
		return linked.wrap("The stats-to-achievements link could not start")

	boards = DotLeaderboardManager.new()
	boards.name = "Boards"
	boards.report_to_backbone = report_to_backbone
	boards.report_interval = report_interval
	boards.store = DotLeaderboardStoreMemory.new()
	add_child(boards)

	for board in ArenaBoards.definitions():
		var defined := boards.define(board)

		if not defined.ok:
			return defined.wrap("A leaderboard definition was refused")

	return DotResult.success(null)


# --- Players ---------------------------------------------------------------

## Starts counting for a player. Idempotent.
##
## [b]A coroutine, because an achievement store may be remote.[/b]
## [method DotAchievementTracker.begin] awaits its store, and its own note says why:
## the interesting stores are a shared database behind a community's four servers, not
## a file. A caller that does not want to wait may drop the await — nothing below
## depends on the load having finished, and the reason is worth stating because it is
## not obvious: readings that arrive during the load are still counted. dot-stats
## records them regardless, [DotAchievementStatsLink] declines to file them while the
## tracker has no such player AND declines to move its baseline, so the first delta
## after the load carries everything that happened during it.
##
## What must NOT be dropped is the await on the tracker's own call. An un-awaited
## GDScript coroutine returns at its first suspension, so assigning its value to a
## typed variable is a runtime error rather than a compile one — the shape this
## family's notes call out under the fan-out trap.
func begin(player_id: int, display_name: String = "") -> void:
	if not _attached:
		return

	var key := ArenaGame.storage_key(player_id)

	stats.begin(StringName(key), display_name)

	_playtime[player_id] = 0.0
	_round_kills[player_id] = 0

	var began: DotResult = await achievements.begin(key)

	if not began.ok:
		# Not fatal, and deliberately not silent. A store that cannot be read means a
		# player plays with no achievements rather than not playing, which is the same
		# call `ArenaGame.apply_loadout` makes about a loadout store.
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {
			"player": key, "why": began.error.message
		})


## Stops counting, files the session onto the boards, and forgets the baselines.
##
## [b]The boards are written here rather than per kill.[/b] A board submission reads
## the store, compares, writes and re-sorts; doing that six times per kill on a
## sixteen-player server is a sort per kill per board for a number that only matters
## when somebody looks at it. A session is the natural unit — it is also when a
## player's totals stop moving.
func leave(player_id: int) -> void:
	if not _attached:
		return

	var key := ArenaGame.storage_key(player_id)

	_flush_playtime(player_id, true)

	var values := stats.end(StringName(key))

	if values != null and _game != null:
		ArenaBoards.submit_session(
			boards,
			_game.mode.id if _game.mode != null else &"ffa",
			StringName(key),
			_name_of(player_id),
			values
		)

	# Without this the link holds one baseline row per stat per player who has ever
	# connected, for as long as the server is up. Its own documentation says so.
	link.forget(key)

	_playtime.erase(player_id)
	_round_kills.erase(player_id)

	# Last, because it is the only part that may suspend. Everything above has to have
	# happened by the time this function yields: a caller that drops the await — the
	# module does, on a disconnect — must not be able to observe a player who is half
	# gone, still accruing playtime against a session that has already been filed.
	var ended: DotResult = await achievements.end(key)

	if not ended.ok:
		DotLog.debug(CHANNEL, "achievement progress could not be saved", {
			"player": key, "why": ended.error.message
		})


## Records one reading against a player. The single door into dot-stats.
func record(player_id: int, stat_id: StringName, value: float = 1.0) -> void:
	if not _attached:
		return

	stats.record(StringName(ArenaGame.storage_key(player_id)), stat_id, value)


## A player's session values, for a HUD or a console command.
func session_values(player_id: int) -> DotStatsValues:
	if not _attached:
		return DotStatsValues.new()

	return stats.session_values(StringName(ArenaGame.storage_key(player_id)))


## Lifetime achievement points, for a scoreboard column.
func points_of(player_id: int) -> int:
	if not _attached:
		return 0

	return achievements.points_of(ArenaGame.storage_key(player_id))


# --- Time ------------------------------------------------------------------

## Playtime, accumulated as a float and filed as whole seconds.
##
## [constant ArenaStats.PLAYTIME_SEC] is a COUNTER, and a counter fed 0.0166 sixty
## times a second is a counter whose total is a sum of rounding errors by the end of a
## map. The remainder is carried rather than dropped, so a player who joins and leaves
## repeatedly is not quietly credited less time than they played.
func _process(delta: float) -> void:
	if not _attached or _playtime.is_empty():
		return

	for id in _playtime.keys():
		_playtime[id] = float(_playtime[id]) + delta

		if float(_playtime[id]) >= 1.0:
			_flush_playtime(int(id), false)


func _flush_playtime(player_id: int, all_of_it: bool) -> void:
	var held := float(_playtime.get(player_id, 0.0))

	if held <= 0.0:
		return

	var whole := floorf(held) if not all_of_it else roundf(held)

	if whole <= 0.0:
		return

	record(player_id, ArenaStats.PLAYTIME_SEC, whole)
	_playtime[player_id] = held - whole


# --- Events ----------------------------------------------------------------

func _on_killed(entry: DotKillFeed.Entry) -> void:
	var victim := entry.victim_key.to_int()

	if entry.victim_key != "":
		record(victim, ArenaStats.DEATHS)

		if entry.suicide:
			record(victim, ArenaStats.SUICIDES)

		# A death ends a streak, and the streak that mattered is the one the feed
		# entry carries — it is read off the scoreboard at the moment of the kill,
		# which is after the increment and before any reset.
		_round_kills[victim] = _round_kills.get(victim, 0)

	if entry.killer_key == "" or entry.suicide:
		return

	var killer := entry.killer_key.to_int()

	record(killer, ArenaStats.KILLS)

	if entry.headshot:
		record(killer, ArenaStats.HEADSHOTS)

	if entry.team_kill:
		record(killer, ArenaStats.TEAM_KILLS)

	# BEST, not COUNTER: `record` merges through the stat's own kind, so filing the
	# running streak on every kill leaves the highest one. Filing a delta here would
	# be a sum of every streak the player ever had.
	record(killer, ArenaStats.BEST_STREAK, float(entry.streak))

	_round_kills[killer] = int(_round_kills.get(killer, 0)) + 1


func _on_shot_resolved(shot: DotShot) -> void:
	if shot == null or _game == null or _game.player_for(shot.attacker) == null:
		return

	# One shot is one shot, whatever it fired. A shotgun's nine pellets are nine
	# damage events and one trigger pull, and counting the damage events instead is
	# what makes an accuracy figure that says a shotgun player is nine times as
	# accurate as a rifle player.
	record(shot.attacker, ArenaStats.SHOTS_FIRED)

	if shot.hit_anyone():
		record(shot.attacker, ArenaStats.SHOTS_HIT)


func _on_damage_applied(damage: DotDamage) -> void:
	if damage.health_lost <= 0.0 or _game == null:
		return

	# Players only. dot-combat carries entity ids and a game may register anything
	# with it; filing a stat against a monster's id gives it a session, a lifetime
	# progress row and, when it disconnects — which it never does — a leaderboard
	# entry. The check is `player_for`, not an id range, so it is right for whatever
	# else gets registered next.
	if _game.player_for(damage.victim) != null:
		record(damage.victim, ArenaStats.DAMAGE_TAKEN, damage.health_lost)

	# Self damage is not damage dealt. Rocket jumping would otherwise be the fastest
	# way onto the damage board, which is a board about fighting people.
	if damage.attacker == damage.victim or _game.player_for(damage.attacker) == null:
		return

	record(damage.attacker, ArenaStats.DAMAGE_DEALT, damage.health_lost)


func _on_round_started(_round_number: int) -> void:
	for id in _round_kills.keys():
		_round_kills[id] = 0


func _on_round_ended(
	_round_number: int, winner: int, _outcome: DotMatchRules.Outcome
) -> void:
	if _game == null:
		return

	for id in _round_kills.keys():
		var player_id := int(id)

		record(player_id, ArenaStats.ROUNDS_PLAYED)
		record(player_id, ArenaStats.BEST_ROUND_KILLS, float(_round_kills[id]))

		if _won(player_id, winner):
			record(player_id, ArenaStats.ROUNDS_WON)

		_round_kills[id] = 0


func _on_match_ended(winner: int, _outcome: DotMatchRules.Outcome) -> void:
	for id in _round_kills.keys():
		var player_id := int(id)

		record(player_id, ArenaStats.MATCHES_PLAYED)

		if _won(player_id, winner):
			record(player_id, ArenaStats.MATCHES_WON)

	# End of a match is the other moment a player's totals stop moving, and a server
	# that runs for a week would otherwise only ever write a board when somebody left.
	_publish_all()


## Whether [param player_id] is on the winning side of [param winner].
##
## [b]`winner` means two different things and the mode decides which.[/b] In a team
## mode it is a team number; in a free-for-all dot-match has no teams and it is 0,
## which is not a player id — so the winner of a free-for-all round is read off the
## scoreboard instead. Treating 0 as a team in a free-for-all credits nobody, which
## looks exactly like a game where nobody ever wins.
func _won(player_id: int, winner: int) -> bool:
	if _game == null or _game.match_node == null:
		return false

	if _game.mode != null and _game.mode.is_team_mode():
		return winner != 0 and _game.team_of(player_id) == winner

	var leader := _game.match_node.scoreboard.leader()
	return leader != null and leader.key == str(player_id)


func _on_unlocked(player: String, achievement: DotAchievement) -> void:
	award_unlocked.emit(_id_from_key(player), achievement)

	DotLog.info(CHANNEL, "achievement unlocked", {
		"player": player, "id": String(achievement.id), "points": achievement.points
	})


func _publish_all() -> void:
	if _game == null:
		return

	var mode_id: StringName = _game.mode.id if _game.mode != null else &"ffa"

	for id in _playtime.keys():
		var player_id := int(id)
		var key := StringName(ArenaGame.storage_key(player_id))

		ArenaBoards.submit_session(
			boards, mode_id, key, _name_of(player_id), stats.session_values(key)
		)


func _name_of(player_id: int) -> String:
	if _game == null:
		return str(player_id)

	var player := _game.player_for(player_id)
	return player.display_name if player != null else str(player_id)


## The inverse of [method ArenaGame.storage_key].
##
## Padded decimal, so `to_int()` on the tail is exact. Written as a method rather than
## inline because a key format with a parser in one file and a printer in another is
## the shape this family has shipped twice — dot-moderation's punishment kind and
## dot-map's cloud interface are both two ends of one serialisation that never met.
static func _id_from_key(key: String) -> int:
	var cut := key.rfind("-")
	return key.substr(cut + 1).to_int() if cut >= 0 else key.to_int()


func describe() -> Dictionary:
	return {
		"attached": _attached,
		"tracking": _playtime.size(),
		"stats": stats.describe() if stats != null else {},
		"achievements": achievements.describe() if achievements != null else {},
		"boards": boards.describe() if boards != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("progress  %d tracked" % _playtime.size())

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	if boards != null:
		out.append_array(boards.describe_lines())

	return out
