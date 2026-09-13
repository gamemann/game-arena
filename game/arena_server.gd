extends Node

const ArenaGame := preload("res://game/arena_game.gd")
const ArenaMap := preload("res://maps/arena_map.gd")

## What a [DotServer] loads as its game scene. Never a client.
##
## [b]Small on purpose.[/b] Everything a dedicated server does is in [ArenaModule];
## this exists because `DotGameManager` loads a SCENE and the game needs one, and
## because [method ArenaGame.setup] is explicit — it takes a map, it can fail, and a
## game that built itself in `_ready` would have no way to report that it had not.
##
## [b]It lives in `game/`, not beside its own scene in `scenes/`.[/b] That is a
## deployment constraint rather than a preference: `dot-server-deploy/setup.sh`
## vendors a game by copying its `game/` wholesale and its `scenes/*.tscn` — only the
## `.tscn` — so a script under `scenes/` is a script that never reaches the build. The
## scene then fails to load with "referenced non-existent resource", the module refuses
## to load because no game registered itself, and the server reports "the game loaded
## but its module did not". Every other game in this family already keeps its server
## scene's script in `game/`; this one now does too.
##
## The order matters and is the only interesting thing here: the game registers itself
## in [DotRegistry] under [constant ArenaGame.SERVICE] during `setup`, and
## `ArenaModule._module_load` refuses to load if it cannot find it. dot-server loads the
## scene before the module for exactly that reason.

const CHANNEL := "arena.server"

var game: ArenaGame = null


func _ready() -> void:
	game = ArenaGame.new()
	game.name = "Game"
	game.is_authority = true
	# HEADLESS: analytic geometry from the box list rather than a physics space. Not a
	# degraded mode — it is exact, it needs no physics server, and it gives the same
	# answer as a client replaying the same tick, which is what makes reconciliation
	# converge at all.
	game.headless = true
	add_child(game)

	var built := game.setup(startup_map())

	DotLog.result(CHANNEL, "the arena was built", built)

	if built.ok:
		game.start(0)


## Which map to boot on, from `-- --map <id>`.
##
## [b]A launch argument and not a cvar, because a cvar is read after the game is
## built.[/b] `ArenaGame.setup` builds the combat trace, the match and every spawn point
## out of the map in one pass and is not re-entrant, so by the time a module has added a
## cvar for an operator to set, the map it would name is already the one running. A
## hot `changelevel` is a real feature and a real amount of work; until it exists, the
## honest interface is the one that is read before anything is built.
##
## An unknown id is refused rather than silently falling back: an operator who typed
## `dm_atruim` and got `dm_box` has no way to tell that from a map that failed to build.
static func startup_map() -> ArenaMap:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--map")

	if index < 0 or index + 1 >= args.size():
		return ArenaMap.dm_box()

	var id := StringName(args[index + 1])
	var map := ArenaMap.by_id(id)

	if map == null:
		DotLog.warn(CHANNEL, "no such map, booting the default instead", {
			"asked": String(id),
			"known": ArenaMap.ids(),
		})
		return ArenaMap.dm_box()

	return map
