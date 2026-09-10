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
		await _test_services()
		_test_maps_and_vote()
		_test_query()
		await _test_browser()
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
	# The query listener, which `_test_browser` needs. On by default on a real server;
	# named here so a suite that stopped exercising it fails rather than skipping.
	config.query_enabled = true
	config.query_port = PORT + 1

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


# --- The rest of the server -------------------------------------------------

## Chat, voice, moderation and the identity chain, on a real server.
##
## [b]Every one of these five addons passes its own suite with a stub host.[/b] What is
## untested anywhere else is that they can all be brought up in one process against one
## [DotServer] — and specifically that dot-moderation is up before the two routers that
## look up its `dot_mute_source`, because a router that starts first finds nothing,
## warns once, and then enforces no gag for the life of the server.
func _test_services() -> void:
	print("")
	print("chat, voice and moderation")

	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null and module.services != null, "the services layer is up"):
		return

	var services := module.services

	_check(services.chat != null, "chat is running")
	_check(services.voice != null, "voice is running")
	_check(services.moderation != null, "moderation is running")

	# The registry names, which are how the three reach each other without importing
	# one another. dot-moderation publishes both; dot-chat's router and dot-voice's
	# router each look one of them up.
	_check(
		DotRegistry.get_service(DotModerationManager.MUTE_SERVICE) != null,
		"and it published a mute source for the two routers to find"
	)
	_check(
		DotRegistry.get_service(DotModerationManager.BAN_SERVICE) != null,
		"and a ban source for the admission check"
	)

	# Four channels, and the one that matters is the radius channel: it is the only
	# one whose audience the players can change by moving.
	var ids := services.chat.channel_ids()
	_check(
		ids.size() == 4,
		"four chat channels are installed",
		", ".join(PackedStringArray(ids.map(func(x: StringName) -> String: return String(x))))
	)
	_check(
		services.chat.has_channel(ArenaServices.CH_NEAR),
		"including a radius channel"
	)

	var near := services.chat.channel(ArenaServices.CH_NEAR)
	_check(
		near != null and near.scope == DotChatChannel.Scope.RADIUS,
		"which really is scoped by distance"
	)

	# The rules. Markup escaping is not cosmetic: a chat line is drawn by a client
	# that may render BBCode, so a player who can write markup can write something
	# that looks like a server announcement.
	_check(services.chat.rules.escape_markup, "markup is escaped")
	_check(services.chat.rules.strip_invisible, "and invisible characters stripped")

	var dirty := DotChatFilter.sanitise(
		"[color=red]server[/color]: free stuff", services.chat.rules
	)
	_check(
		dirty.ok and not String(dirty.value).contains("[color=red]"),
		"and a player cannot write a colour tag",
		str(dirty.value)
	)

	# --- Moderation, which is the whole reason it is not dot-server's mute ---
	#
	# dot-server's mute is two booleans on a session object and a session dies with
	# its connection, so a muted player reconnects and talks. A punishment is a record.
	var subject := DotPunishmentSubject.for_uid("4242")

	# Awaited, and typed. A punishment store may be a shared database behind a
	# community's four servers — the whole reason both halves of the interface are
	# allowed to be coroutines — and an un-awaited one returns at its first suspension.
	var issued: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "suite", 3600
	)

	_check(issued.ok, "a gag can be issued", str(issued.error))
	_check(
		services.moderation.is_gagged_key(subject),
		"and it is held against the person rather than the connection"
	)

	# The unconfigured scope is the case a one-server community always has, and it is
	# the one dot-moderation once had silently enforcing nothing.
	_check(
		services.server_scope == "",
		"this server has no scope, which is the case that has to work"
	)

	# Revoked by ID, not by subject: one person may hold a gag, a mute and a ban at
	# once, and "lift the punishment on this person" is not a question with one answer.
	var record: DotPunishment = issued.value if issued.ok else null
	var lifted: DotResult = (
		await services.moderation.revoke(record.id, "suite", "over")
		if record != null
		else DotResult.fail(DotError.CODE_STATE, "nothing was issued")
	)
	_check(lifted.ok, "and it can be lifted again", str(lifted.error))
	_check(
		not services.moderation.is_gagged_key(subject),
		"leaving nothing behind"
	)

	# --- Identity ---------------------------------------------------------

	if _check(module.identity != null, "the identity layer is up"):
		_check(module.identity.platform != null, "with a platform hub")
		_check(
			DotRegistry.get_node_service(DotPlatformHub.SERVICE) != null,
			"registered, which is how dot-platform's module finds it"
		)
		_check(
			_server.modules.has_module("platform"),
			"and dot-platform's own module is loaded beside this one"
		)

		# Never null, for anybody. A caller that had to branch on "did this player
		# have an avatar" is a caller that draws nothing for a guest.
		var stock := module.identity.avatar_for("arena-player-00000007")
		_check(stock != null, "every player has an avatar, their own or a stock one")

		var conformed := ArenaAvatars.schema().conform(stock, null)
		_check(
			conformed.ok,
			"and a stock avatar conforms to the schema it was built from",
			str(conformed.error)
		)


## dot-map and dot-vote, on a server with a rotation and a ballot.
func _test_maps_and_vote() -> void:
	print("")
	print("maps and the vote")

	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null and module.maps != null, "the map director is up"):
		return

	_check(
		module.maps.current != null and module.maps.current.id == _game.map.id,
		"and it adopted the map the server booted on"
	)

	# The sync host has a transport. Without one it announces a change to nobody and
	# every client carries on playing a map that no longer exists — which is the
	# absence dot-map's own notes call "the structural one".
	_check(
		module.maps.sync != null and module.maps.sync.send_fn.is_valid(),
		"the map sync host has somewhere to send its announcements"
	)

	if not _check(module.vote != null, "the vote is up"):
		return

	var options := module.vote.source.choices()
	_check(options.size() > 0, "and there is something to vote for", "%d" % options.size())

	# Every choice id says what kind of change it is. A bare id would have to be
	# looked up in the map catalogue and then in the mode catalogue, which is a lookup
	# that silently does the wrong thing the day somebody names a mode after a map.
	var unprefixed := PackedStringArray()

	for choice in options:
		var text := String(choice.id)

		if not text.begins_with(ArenaVoteSource.MAP_PREFIX) 				and not text.begins_with(ArenaVoteSource.MODE_PREFIX):
			unprefixed.append(text)

	_check(
		unprefixed.is_empty(),
		"and every choice says whether it is a map or a mode",
		", ".join(unprefixed)
	)

	# A player types `dm_atrium`, not `map:dm_atrium`. The qualifier resolves against
	# the ballot's own options rather than guessing.
	_check(
		module.vote.director.source.has(StringName("map:dm_atrium")),
		"dm_atrium is on the ballot"
	)

	# The cooldown. Two maps ship, so "not in the last five" would leave nothing to
	# offer — dot-vote caps it against the pool at runtime and the rules ask for one.
	_check(
		module.vote.director.rules.cooldown <= 1,
		"the cooldown fits a two-map catalogue",
		"%d" % module.vote.director.rules.cooldown
	)

	# `begin_on_apply` off is what stops one play being counted twice. Two entries in
	# the history for one play is a "last five" cooldown that is quietly two or three.
	_check(
		not module.vote.director.begin_on_apply,
		"and the director does not announce a change the host already announces"
	)

	# Opening one. With one player the quorum and `min_players_to_vote` decide whether
	# it can, so the assertion is that it answers rather than that it succeeds — a
	# refusal is a legitimate answer and the point is that the clock did not latch.
	var opened := module.vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(
		opened.ok or opened.error != null,
		"a vote can be asked for and answers either way",
		"" if opened.ok else opened.error.message
	)

	if opened.ok:
		_check(module.vote.is_voting(), "and the ballot is open")
		module.vote.director.close_vote()
		_check(not module.vote.is_voting(), "and closes again")


## What a server browser is told.
##
## [b]dot-browser is the client half of this and it has never asked a real DotServer
## anything.[/b] This is the server half: a query provider contributing the numbers a
## person filtering a list actually filters on. Without one, a query says only that the
## game is called Arena.
func _test_query() -> void:
	print("")
	print("the server browser's half")

	var module := _server.modules.get_module("arena") as ArenaModule

	if module == null:
		return

	var snapshot := DotQuerySnapshot.new()

	for provider in module._query_providers:
		provider.call("_contribute", snapshot)

	_check(snapshot.game.has("mode"), "the query says what mode is being played")
	_check(snapshot.game.has("map"), "and on what map")
	_check(snapshot.game.has("state"), "and how far through it is")
	_check(
		String(snapshot.game.get("map", "")) == String(_game.map.id),
		"and the map it names is the one that is running",
		str(snapshot.game.get("map", ""))
	)


## dot-browser asking a real [DotServer] — which nothing in this family had done.
##
## [b]This is the seam the family's own notes name.[/b] dot-server has answered A2S and
## its own richer protocol since it was written; dot-browser's suite queries a DQP
## server over a real loopback socket. Neither had ever met the other, and by this
## family's repeated lesson that is where the next bugs are.
##
## The listening query port is the server's own, so this is a real UDP round trip
## between two objects in one process — which is exactly the deployment shape a player
## opening a server list is in, minus the distance.
func _test_browser() -> void:
	print("")
	print("a browser asking this server")

	var browser := ArenaBrowser.new()
	browser.name = "Browser"
	browser.timeout_ms = 2000
	# In memory. A suite that wrote a player's favourites to disk is a suite that
	# passes differently the second time it is run.
	browser.favourites_path = ""
	add_child(browser)

	var started := browser.setup()

	if not _check(started.ok, "the browser starts", str(started.error)):
		browser.queue_free()
		remove_child(browser)
		return

	# The query port, not the game port. dot-server listens for queries separately —
	# a browser that asked the game port would get no answer and report every server
	# as offline, which reads as the browser being broken.
	var query_port := _server.config.query_port

	if query_port <= 0:
		_check(false, "the server has a query port to ask", "query_enabled is off")
		browser.queue_free()
		remove_child(browser)
		return

	# The query port as a separate argument, not a third part of the string. A
	# three-part address parses as a malformed IPv6 one and fails at `connect_to_host`
	# with "Invalid IPv6 address", several layers below anything that could say what
	# was actually wrong.
	var added := browser.add("127.0.0.1:%d" % PORT, query_port)
	_check(added.ok, "a server can be added by address", str(added.error))

	var refreshed: DotResult = await browser.refresh()
	_check(refreshed.ok, "and asked", str(refreshed.error))

	var entries := browser.browser.entries()

	if not _check(entries.size() == 1, "there is one entry", "%d" % entries.size()):
		browser.queue_free()
		remove_child(browser)
		return

	var entry := entries[0]

	_check(
		entry.is_online(),
		"the server answered",
		entry.error.message if entry.error != null else entry.status_name()
	)

	if entry.is_online():
		_check(
			entry.name == _server.config.hostname,
			"with its hostname",
			"%s vs %s" % [entry.name, _server.config.hostname]
		)
		_check(
			entry.max_players == _server.config.max_players,
			"and its slot count",
			"%d vs %d" % [entry.max_players, _server.config.max_players]
		)

		# The game half, which is what `ArenaModule`'s query provider contributes. A
		# `DotGameDescriptor` alone would say only that the game is called Arena — the
		# mode, the map and the state are the provider's, and until a browser asked,
		# nothing had ever read them.
		#
		# [b]It is NOT `entry.map`.[/b] That is dot-server's `info.map`, which means
		# "the content id of the loaded game" and is empty on a server that has never
		# switched games — so the first version of this check read it, got "", and
		# reported a browser fault for a browser that was working. dot-browser nests
		# the game's own section under `rules["game"]` precisely so a game putting a
		# field called `map` in it cannot overwrite the other one.
		_check(
			ArenaBrowser.game_field(entry, "map") == String(_game.map.id),
			"and the map the GAME says it is running",
			"%s vs %s" % [ArenaBrowser.game_field(entry, "map"), String(_game.map.id)]
		)
		_check(
			ArenaBrowser.game_field(entry, "mode") != "",
			"and the mode, which only the query provider knows",
			ArenaBrowser.game_field(entry, "mode")
		)

	# Favourites and history, which is the half a list is actually for.
	browser.favourite(entry.key(), true)
	_check(browser.browser.is_favourite(entry.key()), "a server can be favourited")

	browser.favourite(entry.key(), false)
	_check(
		not browser.browser.is_favourite(entry.key()),
		"and un-favourited again"
	)

	# Filtering is LOCAL. A server does not get to decide whether it appears in your
	# list; you queried it, you hold the answer, and a filter the server applied would
	# be a filter the server could lie about.
	browser.filter.hide_empty = true
	var hidden := browser.listing().size()
	browser.filter.hide_empty = false
	var shown := browser.listing().size()

	_check(
		hidden <= shown,
		"and the filter runs on what this client holds",
		"%d hidden, %d shown" % [hidden, shown]
	)

	browser.queue_free()
	remove_child(browser)


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

	var modes := _server.console.execute("arena_modes")
	_check(modes.ok, "arena_modes runs", str(modes.error))

	# **The cvar that makes the two modes which are not about killing people reachable
	# from a deployment.** `ArenaGame.mode_id` is an export read once at setup, so
	# without this an operator has a game with five modes and one of them.
	var was := String(_game.mode.id)
	var switched := _server.console.execute("arena_mode koth")
	_check(switched.ok, "arena_mode koth runs", str(switched.error))
	_check(
		_game.mode.id == &"koth",
		"and the game is playing it",
		String(_game.mode.id)
	)
	_check(
		_game.objectives != null and _game.objectives.layout == &"koth",
		"with the objectives that mode asks for",
		String(_game.objectives.layout) if _game.objectives != null else "<none>"
	)

	# A mode that does not exist is refused AND the cvar is put back. A cvar reading
	# `koth` on a server playing free-for-all is worse than one that refused, because
	# an operator believes it — and the put-back must not recurse through its own
	# `changed` signal.
	var bad := _server.console.execute("arena_mode not_a_mode")
	_check(bad.ok, "a bad mode does not error the console", str(bad.error))
	_check(
		_game.mode.id == &"koth",
		"and the game keeps playing what it was",
		String(_game.mode.id)
	)
	_check(
		_server.console.get_string("arena_mode", "") == "koth",
		"with the cvar put back to what is actually running",
		_server.console.get_string("arena_mode", "")
	)

	# And back, so the rest of the suite sees the game it expects.
	var restored := _server.console.execute("arena_mode %s" % was)
	_check(restored.ok, "and it changes back", str(restored.error))
	_check(_game.mode.id == StringName(was), "to the mode it started on")


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
