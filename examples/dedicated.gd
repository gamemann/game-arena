extends Node

## A real [DotServer], listening, with the arena loaded into it.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]What this proves that [code]headless_match[/code] cannot.[/b] That test drives an
## [ArenaGame] directly and never opens a socket. This boots a [DotServer], binds a
## port, loads [ArenaModule] into it, and exercises the module's own surface — its
## console commands, its cvar, its session bookkeeping and its unload path.
##
## dot-platform found two long-standing dot-server bugs the first time it did
## something like this, neither of which was reachable from dot-server's own 104-check
## suite. **A code path only one deployment shape reaches is a code path nothing has
## run**, and a module loaded by no server is exactly that.
##
## It does not connect a client. dot-platform already runs that seam — a real
## `DotClientLink` over a real socket into a real `DotServer` — and repeating it here
## would test dot-server rather than this game.

const PORT := 27078
const SERVER_DIR := "user://arena_dedicated"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server: DotServer = null
var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena dedicated server")
	print("")

	_cleanup()

	var built := await _build()

	if built:
		_test_module_loaded()
		_test_client_spawn()
		_test_commands()
		_test_unload()

	_teardown()
	_cleanup()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	DotPaths.remove_tree(SERVER_DIR)


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


# --- Bring-up --------------------------------------------------------------

func _build() -> bool:
	print("booting")

	# The game first, and registered: ArenaModule finds it through DotRegistry rather
	# than being handed it, which is what makes `load_module(path)` work at all —
	# dot-server loads a module from a script path and has nowhere to pass an argument.
	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = 64
	_game.score_limit = 25
	_game.headless = true
	_game.register_service = true
	add_child(_game)

	var ready := _game.setup(ArenaMap.dm_box())

	if not _check(ready.ok, "the arena sets up", str(ready.error)):
		return false

	_check(
		DotRegistry.get_node_service(ArenaGame.SERVICE) == _game,
		"and registers itself so a module can find it"
	)

	var config := DotServerConfig.new()
	config.hostname = "arena dedicated"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	# Empty means the RCON listener does not open, which is what a test wants and is
	# also what dotserve treats as "RCON is off" rather than as a weak password.
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	var loaded := _server.modules.load_module("res://game/arena_module.gd")

	if not _check(loaded.ok, "the arena module loads into it", str(loaded.error)):
		return false

	return true


func _teardown() -> void:
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
		remove_child(_server)
		_server.queue_free()

	if _game != null and is_instance_valid(_game):
		remove_child(_game)
		_game.queue_free()


# --- Checks ----------------------------------------------------------------

func _test_module_loaded() -> void:
	print("")
	print("the module")

	_check(_server.modules.has_module("arena"), "is listed among the server's modules")

	var module := _server.modules.get_module("arena") as ArenaModule
	_check(module != null, "and is an ArenaModule")

	if module == null:
		return

	_check(module.game == _game, "holding the game it found in the registry")

	# The registration helpers exist so that unloading is safe by construction. A
	# module that registered directly would leave a console command pointing at a
	# freed object, and the console would crash the server the next time anyone ran
	# it.
	for command in ["arena_status", "arena_score", "arena_restart"]:
		_check(
			_server.console.find_command(command) != null,
			"registered %s" % command
		)

	_check(
		_server.console.find_cvar("arena_scorelimit") != null, "and its cvar"
	)


func _test_client_spawn() -> void:
	print("")
	print("a client spawning")

	# **`client_spawn` carries `userid` and `name`. It does not carry `peer_id`.**
	#
	# This module read `event.get_int("peer_id")` and looked the session up by it. That
	# is 0 on every event, `session_of(0)` is null, and a null session is a legitimate
	# thing to find — so the handler returned and **nobody ever joined a dedicated arena
	# server**, silently, for as long as this module has existed.
	#
	# This suite passed its twenty-one checks the whole time, because it never connected
	# a client. It still does not: connecting one is dot-platform's seam and repeating it
	# here would test dot-server. What it does instead is fire the event dot-server fires,
	# with the payload dot-server puts in it, and assert somebody joined — which is the
	# smallest thing that can tell the two spellings apart.
	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null, "the module is loaded"):
		return

	var before := _game.player_ids().size()

	# `adopt_session` exists for exactly this: dot-server's own documentation calls it
	# "a test that needs the session table populated without a socket". Everything that
	# counts players counts sessions, so a participant without one is invisible to the
	# roster, the slots and the queries — and to `session_by_userid`, which is what the
	# module has to call.
	var session := DotClientSession.new()
	session.peer_id = 4242
	session.userid = 77
	session.display_name = "Ada"

	if not _check(_server.adopt_session(session).ok, "a session is adopted"):
		return

	# The payload dot-server actually fires: `{"userid", "name"}`. No peer_id.
	_server.events.fire("client_spawn", {"userid": session.userid, "name": session.display_name})

	_check(
		_game.player_ids().size() == before + 1,
		"a spawning client is added to the match",
		"%d -> %d" % [before, _game.player_ids().size()]
	)
	_check(
		_game.player_for(77) != null,
		"under its SESSION id (77), not its peer id (4242)"
	)
	_check(
		_game.player_for(4242) == null,
		"and the peer id is not a player key here"
	)


func _test_commands() -> void:
	print("")
	print("its commands")

	# Run through the console rather than calling the handlers, so the permission
	# checks and the argument plumbing are exercised too.
	var status := _server.console.execute("arena_status")
	_check(status.ok, "arena_status runs", str(status.error))

	var score := _server.console.execute("arena_score")
	_check(score.ok, "arena_score runs", str(score.error))

	var before := _game.match_node.round_number
	var restart := _server.console.execute("arena_restart")
	_check(restart.ok, "arena_restart runs", str(restart.error))
	_check(
		_game.match_node.round_number <= before,
		"and puts the match back to the start",
		"round %d -> %d" % [before, _game.match_node.round_number]
	)


func _test_unload() -> void:
	print("")
	print("unloading")

	var unloaded := _server.modules.unload_module("arena")
	_check(unloaded.ok, "the module unloads", str(unloaded.error))

	# The point of the helpers: everything the module registered is gone. A stale
	# command is a handler pointing at a freed object.
	_check(
		_server.console.find_command("arena_status") == null,
		"and takes its commands with it"
	)
	_check(
		_server.console.find_cvar("arena_scorelimit") == null,
		"and its cvar"
	)
	_check(not _server.modules.has_module("arena"), "and is no longer listed")

	# Reloading has to work, because that is what a live configuration change does.
	var again := _server.modules.load_module("res://game/arena_module.gd")
	_check(again.ok, "and it loads again cleanly", str(again.error))
	_check(
		_server.console.find_command("arena_status") != null,
		"with its commands back"
	)
