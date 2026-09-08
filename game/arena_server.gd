extends Node

## What a [DotServer] loads as its game scene. Never a client.
##
## [b]Small on purpose.[/b] Everything a dedicated server does is in [ArenaModule];
## this exists because `DotGameManager` loads a SCENE and the game needs one, and
## because [method ArenaGame.setup] is explicit — it takes a map, it can fail, and a
## game that built itself in `_ready` would have no way to report that it had not.
##
## [b]It lives in `game/`, not beside its own scene in `scenes/`.[/b] That is a
## deployment constraint rather than a preference: `dot-server-setup-test/setup.sh`
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

	var built := game.setup(ArenaMap.dm_box())

	DotLog.result(CHANNEL, "the arena was built", built)

	if built.ok:
		game.start(0)
