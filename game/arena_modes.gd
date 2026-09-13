extends RefCounted

const ArenaMode := preload("arena_mode.gd")

## Every mode this game ships, by id.
##
## [b]The same shape as `ArenaMap.by_id` / `ids`, on purpose.[/b] A server names a mode
## with a string, a console command lists them, and dot-vote's `DotVoteListSource` can
## be handed [method ids] without either end knowing what a mode is. Nothing here
## imports dot-vote or dot-server.
##
## Every call builds a FRESH resource. Handing out a shared one would let a server that
## adjusted a score limit at runtime edit the mode every later match reads — the
## `Dictionary`-is-a-reference aliasing this family has now shipped four times.

const CHANNEL := "arena.modes"


## Every mode, freshly built.
static func all() -> Array[ArenaMode]:
	return [
		ArenaMode.free_for_all(),
		ArenaMode.team_deathmatch(),
		ArenaMode.siege(),
		ArenaMode.king_of_the_hill(),
		ArenaMode.capture_the_flag(),
	]


## The ids a server or a vote can name.
static func ids() -> Array[StringName]:
	var out: Array[StringName] = []

	for mode in all():
		out.append(mode.id)

	return out


## A mode by id, or null. Callers report their own error: what to do about an unknown
## mode differs between a server booting, a vote resolving and a test.
static func by_id(id: StringName) -> ArenaMode:
	for mode in all():
		if mode.id == id:
			return mode

	return null


## A mode by id, or the default, saying so.
##
## [b]A server must not fail to boot over a typo in one cvar.[/b] It falls back to
## free-for-all and logs which name it did not recognise — the alternative is a
## dedicated server that exits at 3am because somebody wrote `mp_mode teamdm`.
static func by_id_or_default(id: StringName) -> ArenaMode:
	var mode := by_id(id)

	if mode != null:
		return mode

	if id != &"":
		DotLog.warn(
			CHANNEL,
			"unknown mode, using free-for-all",
			{"wanted": str(id), "known": str(ids())}
		)

	return ArenaMode.free_for_all()


## One line each, for a console command or a vote menu.
static func describe_lines() -> Array[String]:
	var out: Array[String] = []

	for mode in all():
		out.append(
			"%-6s %-18s %s"
			% [
				str(mode.id),
				mode.display_name,
				("%d teams" % mode.team_count) if mode.is_team_mode() else "free-for-all"
			]
		)

	return out
