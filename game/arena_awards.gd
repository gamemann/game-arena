extends RefCounted

const ArenaStats := preload("arena_stats.gd")

## What a player can earn here, as a document rather than as code.
##
## Every rule reads an id from [ArenaStats] and nothing else. That is the whole
## integration: dot-achievements never hears about a kill, a weapon or a round — it
## hears that a number moved, which is what makes the catalogue a thing an operator
## could edit into a JSON file without a rebuild ([method DotAchievementCatalogue.save_json_file]
## writes exactly the shape [method DotAchievementCatalogue.from_json_file] reads).
##
## [b]One stat may be read with only one merge rule across the whole catalogue.[/b]
## dot-achievements refuses a catalogue that breaks it, at [method DotAchievementCatalogue.validate]
## rather than at the first reading, and the reason is worth restating: one number
## cannot be both a running total and a personal best. So every rule over
## [constant ArenaStats.BEST_STREAK] and [constant ArenaStats.BEST_ROUND_KILLS] uses
## [constant DotAchievementRule.Merge.HIGHEST] and everything else uses
## [constant DotAchievementRule.Merge.SUM]. The helpers below are the only reason that
## cannot be got wrong one entry at a time.
##
## The counterpart of that rule lives in [ArenaProgress]: dot-stats' `recorded` signal
## carries a session total and an achievement is about a lifetime, so
## [DotAchievementStatsLink] differences SUM stats and passes the rest through. A
## HIGHEST stat here is therefore an absolute in both systems, which is the only way
## "best streak" means the same thing on both sides.

# No `CHANNEL`: a static catalogue document, validated by dot-achievements, which is
# where a refusal is reported. Nothing here runs.

## Categories, so a menu can group them without parsing names.
const CAT_COMBAT := &"combat"
const CAT_SKILL := &"skill"
const CAT_MATCH := &"match"
const CAT_SANDBOX := &"sandbox"


static func catalogue() -> DotAchievementCatalogue:
	var out: Array[DotAchievement] = []

	# --- Kills: the spine, three tiers ------------------------------------
	out.append(_sum(
		&"arena.first_blood", "First Blood", ArenaStats.KILLS, 1,
		"Kill somebody.", CAT_COMBAT, 5, &"arena.killer", 1
	))
	out.append(_sum(
		&"arena.centurion", "Centurion", ArenaStats.KILLS, 100,
		"A hundred kills.", CAT_COMBAT, 25, &"arena.killer", 2
	))
	out.append(_sum(
		&"arena.millennium", "Millennium", ArenaStats.KILLS, 1000,
		"A thousand kills.", CAT_COMBAT, 100, &"arena.killer", 3
	))

	# --- Headshots --------------------------------------------------------
	out.append(_sum(
		&"arena.marksman", "Marksman", ArenaStats.HEADSHOTS, 25,
		"Twenty-five headshots.", CAT_SKILL, 20, &"arena.headhunter", 1
	))
	out.append(_sum(
		&"arena.headhunter", "Headhunter", ArenaStats.HEADSHOTS, 250,
		"Two hundred and fifty headshots.", CAT_SKILL, 60, &"arena.headhunter", 2
	))

	# --- Streaks. HIGHEST, because a streak is a best and not a total. -----
	out.append(_best(
		&"arena.triple", "On a Roll", ArenaStats.BEST_STREAK, 3,
		"Three kills without dying.", CAT_SKILL, 10, &"arena.streak", 1
	))
	out.append(_best(
		&"arena.rampage", "Rampage", ArenaStats.BEST_STREAK, 5,
		"Five kills without dying.", CAT_SKILL, 20, &"arena.streak", 2
	))
	out.append(_best(
		&"arena.unstoppable", "Unstoppable", ArenaStats.BEST_STREAK, 10,
		"Ten kills without dying.", CAT_SKILL, 50, &"arena.streak", 3
	))
	out.append(_best(
		&"arena.big_round", "Carried It", ArenaStats.BEST_ROUND_KILLS, 15,
		"Fifteen kills in one round.", CAT_SKILL, 40
	))

	# --- Damage -----------------------------------------------------------
	out.append(_sum(
		&"arena.heavy_hitter", "Heavy Hitter", ArenaStats.DAMAGE_DEALT, 100000,
		"A hundred thousand points of damage.", CAT_COMBAT, 40
	))

	# --- Match ------------------------------------------------------------
	out.append(_sum(
		&"arena.regular", "Regular", ArenaStats.ROUNDS_PLAYED, 50,
		"Fifty rounds played.", CAT_MATCH, 15
	))
	out.append(_sum(
		&"arena.winner", "Winner", ArenaStats.MATCHES_WON, 1,
		"Win a match.", CAT_MATCH, 15, &"arena.champion", 1
	))
	out.append(_sum(
		&"arena.champion", "Champion", ArenaStats.MATCHES_WON, 25,
		"Win twenty-five matches.", CAT_MATCH, 60, &"arena.champion", 2
	))
	out.append(_sum(
		&"arena.veteran", "Veteran", ArenaStats.PLAYTIME_SEC, 36000,
		"Ten hours in the arena.", CAT_MATCH, 30
	))

	# --- Two-rule entries -------------------------------------------------
	#
	# The pair is the point: dot-achievements ANDs the requirements by default
	# (`require_all`), so "landed a lot of shots AND played a lot of rounds" is two
	# rules rather than a derived percentage. Accuracy is deliberately NOT a stat —
	# see ArenaStats.accuracy_of — because a stored percentage is a third number that
	# can disagree with the two it came from.
	var sharp: Array[DotAchievementRule] = [
		DotAchievementRule.make(ArenaStats.SHOTS_HIT, 5000.0),
		DotAchievementRule.make(ArenaStats.ROUNDS_PLAYED, 100.0),
	]
	var sharp_entry := DotAchievement.make(&"arena.sharpshooter", "Sharpshooter", sharp)
	sharp_entry.description = "Five thousand shots landed over a hundred rounds."
	sharp_entry.category = CAT_SKILL
	sharp_entry.points = 50
	out.append(sharp_entry)

	# --- Monsters, and the sandbox ----------------------------------------
	out.append(_sum(
		&"arena.exterminator", "Exterminator", ArenaStats.NPC_KILLS, 200,
		"Two hundred monsters put down.", CAT_COMBAT, 30
	))
	out.append(_sum(
		&"arena.decorator", "Interior Decorator", ArenaStats.PROPS_SPAWNED, 100,
		"Spawn a hundred props.", CAT_SANDBOX, 10
	))

	# --- One secret one ---------------------------------------------------
	#
	# `secret` withholds the description until it is earned and `hidden` withholds the
	# whole entry. Applied in `to_player_dictionary`, not in a UI: a description a
	# screen chose not to draw is one that was still sent to the client.
	var clumsy := _sum(
		&"arena.gravity", "Gravity Wins", ArenaStats.SUICIDES, 25,
		"Twenty-five deaths nobody else is to blame for.", CAT_COMBAT, 5
	)
	clumsy.secret = true
	out.append(clumsy)

	return DotAchievementCatalogue.of(out)


static func _sum(
	id: StringName,
	display: String,
	stat: StringName,
	threshold: float,
	description: String,
	category: StringName,
	points: int,
	series: StringName = &"",
	tier: int = 0
) -> DotAchievement:
	return _entry(
		id, display, stat, threshold, DotAchievementRule.Merge.SUM,
		description, category, points, series, tier
	)


static func _best(
	id: StringName,
	display: String,
	stat: StringName,
	threshold: float,
	description: String,
	category: StringName,
	points: int,
	series: StringName = &"",
	tier: int = 0
) -> DotAchievement:
	return _entry(
		id, display, stat, threshold, DotAchievementRule.Merge.HIGHEST,
		description, category, points, series, tier
	)


static func _entry(
	id: StringName,
	display: String,
	stat: StringName,
	threshold: float,
	merge: DotAchievementRule.Merge,
	description: String,
	category: StringName,
	points: int,
	series: StringName,
	tier: int
) -> DotAchievement:
	var rules: Array[DotAchievementRule] = [
		DotAchievementRule.make(stat, threshold, DotAchievementRule.Op.AT_LEAST, merge)
	]
	var out := DotAchievement.make(id, display, rules)
	out.description = description
	out.category = category
	out.points = points
	out.series = series
	out.tier = tier
	return out
