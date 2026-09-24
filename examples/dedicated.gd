extends Node

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaBrowser := preload("../game/arena_browser.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaServices := preload("../game/arena_services.gd")
const ArenaVote := preload("../game/arena_vote.gd")
const ArenaVoteSource := preload("../game/arena_vote_source.gd")

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

## The app's URL segment on the website, which is this game's code name.
##
## Unique and lowercase because the site already made it so. Display only — a
## listing prints it to say which game this is, and nothing treats it as proof.
const APP_URL := "arena"

## Every check this suite runs. It has no section counter, so this is its only guard
## against a runtime error that aborts a test function part-way: the checks after the
## error never happen, the ones before it still print ok, and "N passed, 0 failed" cannot
## show the difference. See docs/testing.md.
const CHECKS := 105

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

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

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
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	_teardown()
	_cleanup()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A test aborted part-way." % [
			_passed + _failed, checks
		])
		get_tree().quit(1)
		return
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
	# A self-test takes no commands, and its stdin is whatever the runner left open — for the
	# exit probe's copy, a pipe this suite holds for as long as it waits. The console's reader
	# thread blocks in `read_string_from_stdin`, which nothing can wake, and a process with a
	# reader blocked on an open pipe prints its whole result, its leak report, and then never
	# exits: the copy ran to its deadline on every run until this was off.
	config.stdin_console_enabled = false

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	# The query responder is its own addon now, and a server only answers queries
	# if one is plugged in. `_test_browser` asks this server over a real UDP
	# socket, so without the host that section fails rather than skipping — which
	# is the right way round.
	var query_host := DotQueryHost.new()
	query_host.name = "QueryHost"
	query_host.app_url = APP_URL
	query_host.server_ref = DotNodeRef.of_path(NodePath("../Server"))
	add_child(query_host)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	# Into this run's own directory, which is deleted on the way in and out. Before this
	# line every run wrote an hour-long gag into the store a real server enforces.
	ArenaModule.punishments_file = "%s/punishments.json" % SERVER_DIR

	var loaded: DotResult = await _server.modules.load_module(
		"res://game/arena_module.gd"
	)

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

	# dot-map's own commands, on a real console. `map` was dot-server's and it changed the
	# GAME; on a server running one game and several maps that is the one thing an operator
	# typing it does not mean.
	for command in ["map", "maps", "mapinfo"]:
		_check(
			_server.console.find_command(command) != null,
			"and dot-map's %s" % command
		)
	_check(
		_server.console.find_command("game") != null,
		"while `game` is what changes the game, which is what dot-server's `map` used to do"
	)

	# It read "NOT typable in chat" until `sv_chat_commands` landed. Ending a round in
	# progress is still a thing only CHANGEMAP does — what changed is that the flag is what
	# says so, on the line where it was typed, instead of a prefix check that ran first and
	# never looked at who was asking.
	var map_command := _server.console.find_command("map")
	_check(
		map_command != null
			and map_command.permission == DotAdminFlags.CHANGEMAP
			and map_command.allows_chat(_server.console.chat_commands_are_open()),
		"and changing the map is typable in chat by whoever holds changemap, and nobody else"
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

	# [b]The store, and that it is empty before this run writes to it.[/b] The gag below is
	# an hour long against a fixed uid, so a suite that carried its store between runs would
	# find this person already gagged and could not tell its own gag from the last one.
	var store: Object = services.moderation.store
	var store_path := str(store.get("path")) if store != null else ""
	_check(store_path.begins_with(SERVER_DIR),
		"punishments go to this run's own store, not the one a real server enforces", store_path)
	_check(services.moderation.count() == 0,
		"and it starts empty, so nothing a previous run did is in it",
		"%d records" % services.moderation.count())

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

	# dot-vote's commands, which this game never installed. The operator's four did not
	# exist here at all, and the players' five were the module's own chat handler — a
	# second path to the director with none of the first's commands.
	var absent := PackedStringArray()

	for name in [
		"rtv", "unrtv", "nominate", "vote", "timeleft", "nextmap",
		"setnextmap", "nominate_addmap", "forcertv", "votereload",
	]:
		if _server.console.find_command(name) == null:
			absent.append(name)

	_check(
		absent.is_empty(),
		"dot-vote's commands are on the console, the operator's with the players'",
		"missing: %s" % ", ".join(absent)
	)

	# A player's `!nominate dm_atrium`, as chat hands it to the console, from the session
	# the client-spawn section adopted. The ballot's id is `map:dm_atrium`; a command that
	# took the text as it came would nominate an id nothing has.
	var session := _server.session_by_userid(77)

	if _check(session != null, "the adopted player is still here"):
		var replies := PackedStringArray()
		var ctx := session.make_context(
			"nominate", PackedStringArray(["dm_atrium"]), DotCmdContext.Source.CHAT,
			func(line: String) -> void: replies.append(line)
		)
		_server.console.execute("nominate dm_atrium", ctx)
		_check(
			module.vote.director.nominated_ids().has(&"map:dm_atrium"),
			"a player's bare map name is nominated under the ballot's own id",
			"%s / %s" % [str(module.vote.director.nominated_ids()), " ".join(replies)]
		)
		_check(
			module.vote.director.nominations.by_voter(&"77").has(&"map:dm_atrium"),
			"and counted against the voter the rest of the game knows them as (77, not u77)"
		)

	# One clock. The map director's used to run beside the vote's, and whichever expired
	# first won — which at the end of every map was a second ballot over a winner the
	# players had already chosen.
	var map_left := module.maps.session.time_limit.remaining
	var vote_left := module.vote.director.clock.remaining
	module._physics_process(0.5)
	_check(
		is_equal_approx(module.maps.session.time_limit.remaining, map_left)
			and module.vote.director.clock.remaining < vote_left,
		"only the vote's clock runs when there is a vote (map %.1f -> %.1f, vote %.1f -> %.1f)"
			% [map_left, module.maps.session.time_limit.remaining,
				vote_left, module.vote.director.clock.remaining]
	)

	# What reaches the wire. The module turns every `cue_due` into a VOTE event for every
	# ready client; this is the half of that join a server with no client can see.
	var heard: Array = []
	var probe := func(cue: StringName, seconds_left: int, runoff: bool) -> void:
		heard.append([String(cue), seconds_left, runoff])
	module.vote.cue_due.connect(probe)

	# Past the cooldown the ballot opened above left behind.
	module.vote.director.advance(module.vote.director.rules.vote_cooldown_sec + 1.0)

	var was_min := module.vote.director.rules.min_players_to_vote
	module.vote.director.rules.min_players_to_vote = 0
	var started := module.vote.director.start_vote(DotVoteClock.REASON_MANUAL)
	module.vote.director.rules.min_players_to_vote = was_min

	_check(
		started.ok and module.vote.director.is_counting_down(),
		"a vote starts with this game's countdown",
		"" if started.ok else started.error.message
	)
	_check(
		heard.has([String(ArenaVote.CUE_WARNING), 0, false]) and heard.has(["", 10, false]),
		"and its warning cue and first second are handed on for the wire (%s)" % str(heard)
	)

	module.vote.cue_due.disconnect(probe)
	module.vote.director.cancel_countdown()


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
	var again: DotResult = await _server.modules.load_module(
		"res://game/arena_module.gd"
	)
	_check(again.ok, "and it loads again cleanly", str(again.error))
	_check(
		_server.console.find_command("arena_status") != null,
		"with its commands back"
	)


## [b]The one line that leaked mg-buses-from-hell's whole script graph at exit.[/b]
##
## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a
## running [DotServer] loads — which is how every deployed server loads this game — leaves
## every loaded script alive at exit on Godot 4.7.2 (measured in mg-buses-from-hell,
## 8ed866c). This game's event and request both did it, for a typed `of()` factory.
##
## [b]Asserted on the source, because the symptom is where no check can reach.[/b] The
## leak is reported after `quit()`, by the engine, as warnings a CI filter already treats
## as noise; an assertion here runs before any of it exists. So this checks the cause
## instead: every message script in `game/`, read as text.
func _test_no_message_preloads_itself() -> void:
	print("")
	print("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	print("")
	print("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
