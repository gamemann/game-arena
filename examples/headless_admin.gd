extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## An administrator's live tools, on a real dedicated server, typed the way a person types
## them.
##
## [codeblock]
## godot --headless --path . res://examples/headless_admin.tscn
## [/codeblock]
##
## A real [DotServer] listening on a port, [ArenaModule] loaded into it by path, three
## sessions adopted the way dot-server documents for a test — an administrator, a
## moderator and a player — and every command sent through [method DotConsole.execute]
## with a CHAT context built from the speaker's own session, which is exactly what
## `!noclip` in the chat box becomes. So the permission flag, the chat gate, the target
## resolution, the immunity rule, the audit line and the game's own handler all run, and
## what is asserted is the WORLD afterwards: a body below the floor and outside the wall,
## a hit that took nothing, a frozen player who did not move, a corpse.
##
## [b]Why the world and not the reply.[/b] Every one of these could reply "Ada had noclip
## turned on." while doing nothing — a modifier registered on one machine and not the
## other, a flag on the wrong object, a handler reaching a player who has since been
## rebuilt. The family's own lesson is that a value produced correctly and consumed by
## nothing looks exactly like a value produced wrongly, and only the consumer can tell.
##
## Whether the owning client PREDICTS a forced noclip rather than rubber-banding against it
## is `headless_net`'s, which is where a client exists.

const PORT := 27082
const SERVER_DIR := "user://arena_admin"
const TICK_RATE := 64

const SECTIONS := 8
const CHECKS := 31

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server: DotServer = null
var _game: ArenaGame = null
var _module: ArenaModule = null
var _tick := 0

var _admin: DotClientSession = null
var _moderator: DotClientSession = null
var _player: DotClientSession = null

## What the last command replied, to whoever typed it.
var _replies := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena — an administrator's live tools on a dedicated server")

	DotPaths.remove_tree(SERVER_DIR)

	if await _build():
		await _test_who_may()
		await _test_noclip()
		await _test_god()
		await _test_freeze()
		await _test_slap_and_slay()
		await _test_respawn_clears()
		await _test_immunity_and_self()
		await _test_reporting()

	_teardown()
	DotPaths.remove_tree(SERVER_DIR)

	print("")
	_check_raw(
		_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d, %d expected)" % [_completed, _entered, SECTIONS]
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS + 1:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS + 1
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	return _check_raw(condition, what, detail)


func _check_raw(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


# --- Bring-up ----------------------------------------------------------------

func _build() -> bool:
	print("")
	print("booting")

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 100
	_game.headless = true
	_game.register_service = true
	add_child(_game)

	if not _game.setup(ArenaMap.dm_box()).ok:
		print("  the arena would not set up")
		return false

	# Straight to a live round, so nothing the match does on its own — a warmup, a round
	# start respawning everybody — moves a body in the middle of a check about where it is.
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	_game.match_node.rules.min_players = 1

	var config := DotServerConfig.new()
	config.hostname = "arena admin"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	var booted: DotResult = await _server.boot()

	if not booted.ok:
		print("  the server would not boot: %s" % str(booted.error))
		return false

	var loaded: DotResult = await _server.modules.load_module("res://game/arena_module.gd")

	if not loaded.ok:
		print("  the module would not load: %s" % str(loaded.error))
		return false

	_module = _server.modules.get_module("arena") as ArenaModule

	# This suite drives the ticks itself, so a check can say exactly how many ran.
	_module.set_physics_process(false)

	# Snapshots go nowhere. The three sessions are adopted, which is dot-server's own
	# documented way to populate the session table without a socket — so there is no
	# peer behind them, and the netcode's real send would be an engine RPC error per peer
	# per tick: 1,287 lines on the first run, burying the one line this suite exists to
	# print. The server's tick path is otherwise the real one; whether a CLIENT predicts a
	# forced noclip is headless_net's question.
	_module.net.send_fn = func(_peer: int, _payload: PackedByteArray, _delivery: int) -> void:
		pass

	# The flags an operator's groups.yml hands out: the admin group has cheats, slay and
	# teleport; the moderator group has slay and teleport and NOT cheats.
	_admin = _adopt(4001, 71, "Boss", ["generic", "cheats", "slay", "teleport"], 60)
	_moderator = _adopt(4002, 72, "Mod", ["generic", "kick", "mute", "slay", "teleport"], 20)
	_player = _adopt(4003, 73, "Ada", [], 0)

	_step(8)
	return _game.player_for(73) != null and _game.player_for(71) != null


func _adopt(
	peer: int, userid: int, display_name: String, flags: Array, immunity: int
) -> DotClientSession:
	var session := DotClientSession.new()
	session.peer_id = peer
	session.userid = userid
	session.display_name = display_name
	session.permissions = PackedStringArray(flags)
	session.immunity = immunity
	var _adopted := _server.adopt_session(session)
	_server.events.fire("client_spawn", {"userid": userid, "name": display_name})
	return session


func _teardown() -> void:
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
		remove_child(_server)
		_server.queue_free()

	if _game != null and is_instance_valid(_game):
		remove_child(_game)
		_game.queue_free()


# --- Driving -------------------------------------------------------------------

## Types a `!command` into chat as [param speaker], and waits for the reply.
##
## [b]What `DotChatManager._handle_command` does, step for step, minus the socket.[/b] The
## prefix comes off, `player_command` is fired — which is where this game's own services
## layer claims `!rtv` and the rest, and a mod tool must NOT be claimed there — and the
## line goes to the console with a CHAT context made from the speaker's own session. The
## one difference is the reply sink, which here is a list instead of an RPC, because an
## adopted session has no socket to send a system line down.
func _say(speaker: DotClientSession, line: String) -> PackedStringArray:
	_replies.clear()
	var trimmed := line.trim_prefix("!").strip_edges()
	var tokens := DotConsole.tokenize(trimmed)

	var event := _server.events.fire("player_command", {
		"userid": speaker.userid,
		"name": speaker.display_name,
		"command": tokens[0].to_lower(),
		"args": Array(tokens).slice(1),
		"session": speaker,
	})

	if event.cancelled:
		_replies.append("(claimed by the game before the console saw it)")
		return _replies.duplicate()

	var sink := func(text: String) -> void: _replies.append(text)
	var ctx := speaker.make_context(
		tokens[0].to_lower(), PackedStringArray(Array(tokens).slice(1)),
		DotCmdContext.Source.CHAT, sink
	)
	var _ran := _server.console.execute(trimmed, ctx)

	# The handlers are coroutines — a punishment store may be a remote one — so the reply
	# can arrive a frame after the command returned.
	await get_tree().process_frame
	await get_tree().process_frame
	return _replies.duplicate()


## Runs [param ticks] server ticks with Ada holding [param move].
func _step(ticks: int, move: DotFpsCommand = null) -> void:
	var command := move if move != null else DotFpsCommand.new()
	var behaviour := _module.bridge.behaviour_for(73)

	for _i in range(ticks):
		if behaviour != null:
			behaviour.last_move = command
		_tick += 1
		_module.bridge.server_tick(_tick)


func _move(forward: float, buttons: int = 0, yaw: float = 0.0) -> DotFpsCommand:
	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, forward)
	command.yaw = yaw
	command.buttons = buttons
	return command


func _ada() -> ArenaPlayer:
	return _game.player_for(73)


## On open floor six metres short of the south wall — a spawn point, so nothing is in it.
##
## Not the origin: `dm_box` has its two-tier platform there, and a body teleported inside
## a box is pushed out of it over the next few ticks by the motor's depenetration, which
## reads exactly like a frozen player drifting. That is how this suite first failed.
func _put_ada_on_the_floor() -> void:
	_ada().controller.teleport(Vector3(0.0, 0.05, 18.0), 180.0, 0.0)
	_step(16)


# --- Sections ------------------------------------------------------------------

func _test_who_may() -> void:
	_section("who may")

	var refused := await _say(_player, "!noclip")
	_check(
		" ".join(refused).contains("permission")
		and not DotFpsAdminModifiers.is_noclipped(_ada().controller),
		"a player with no flags is refused, and stays on the ground",
		" / ".join(refused)
	)

	var moderated := await _say(_moderator, "!noclip Ada")
	_check(
		" ".join(moderated).contains("permission")
		and not DotFpsAdminModifiers.is_noclipped(_ada().controller),
		"a moderator cannot noclip anybody: that is cheats, and the group does not have it",
		" / ".join(moderated)
	)

	var frozen := await _say(_moderator, "!freeze Ada")
	_check(
		DotFpsAdminModifiers.is_frozen(_ada().controller),
		"but may freeze a griefer, which is slay", " / ".join(frozen)
	)

	var _unfrozen := await _say(_moderator, "!unfreeze Ada")
	_check(not DotFpsAdminModifiers.is_frozen(_ada().controller), "and let them go again")
	_done()


func _test_noclip() -> void:
	_section("noclip")

	_put_ada_on_the_floor()
	var standing := _ada().controller.state.position

	# The negative control first: the same three seconds of running, with no noclip, must
	# stop at the wall. Otherwise "outside the wall" below proves nothing about noclip.
	_step(TICK_RATE * 3, _move(1.0, 0, 180.0))
	var walled := _ada().controller.state.position
	_check(
		absf(walled.z) < _game.map.extent + 0.5 and absf(walled.x) < _game.map.extent + 0.5,
		"without noclip, three seconds of running ends at the wall",
		"at %s" % str(walled)
	)

	_put_ada_on_the_floor()
	var replies := await _say(_admin, "!noclip Ada")
	_check(
		DotFpsAdminModifiers.is_noclipped(_ada().controller),
		"an admin's !noclip Ada puts her in noclip", " / ".join(replies)
	)

	_step(TICK_RATE * 3, _move(1.0, 0, 180.0))
	var through := _ada().controller.state.position
	_check(
		absf(through.z) > _game.map.extent + 2.0 or absf(through.x) > _game.map.extent + 2.0,
		"and the same run goes straight through the wall",
		"at %s, the wall is at %.0f" % [str(through), _game.map.extent]
	)

	_ada().controller.teleport(standing)
	_step(TICK_RATE, _move(0.0, DotFpsCommand.BUTTON_CROUCH))
	_check(
		_ada().controller.state.position.y < -1.5,
		"and down through the floor", "y %.2f" % _ada().controller.state.position.y
	)

	_step(TICK_RATE * 2, _move(0.0, DotFpsCommand.BUTTON_JUMP))
	_check(
		_ada().controller.state.position.y > 3.0,
		"and up into the air, where she stays", "y %.2f" % _ada().controller.state.position.y
	)

	var _off := await _say(_admin, "!noclip Ada off")
	_step(2)
	_check(
		_ada().controller.state.mode != DotFpsState.Mode.NOCLIP,
		"!noclip Ada off lands her"
	)
	_done()


func _test_god() -> void:
	_section("god")

	_put_ada_on_the_floor()
	var _on := await _say(_admin, "!god Ada")
	var before := _ada().health.health
	var hit := DotDamage.make(71, 73, 50.0, _game.combat.damage_type(&""))
	hit.tick = _game.current_tick()
	_game.combat.apply_damage(hit)

	_check(
		hit.refused and is_equal_approx(_ada().health.health, before),
		"a godded player takes a 50-point hit and loses nothing",
		"%.0f -> %.0f" % [before, _ada().health.health]
	)

	var _off := await _say(_admin, "!god Ada off")
	var landed := DotDamage.make(71, 73, 30.0, _game.combat.damage_type(&""))
	landed.tick = _game.current_tick()
	_game.combat.apply_damage(landed)
	_check(
		_ada().health.health < before,
		"and !god Ada off makes the next one land",
		"%.0f" % _ada().health.health
	)

	var _buddha := await _say(_admin, "!buddha Ada")
	var fatal := DotDamage.make(71, 73, 5000.0, _game.combat.damage_type(&""))
	fatal.tick = _game.current_tick()
	_game.combat.apply_damage(fatal)
	_check(
		_ada().is_alive() and _ada().health.health >= 1.0,
		"buddha takes a fatal hit and leaves her standing on one",
		"%.1f" % _ada().health.health
	)
	var _no_buddha := await _say(_admin, "!buddha Ada off")
	var _hp := await _say(_admin, "!hp Ada 100")
	_check(is_equal_approx(_ada().health.health, 100.0), "and !hp Ada 100 heals her")
	_done()


func _test_freeze() -> void:
	_section("freeze")

	_put_ada_on_the_floor()
	var _on := await _say(_admin, "!freeze Ada")
	var at := _ada().controller.state.position

	_step(TICK_RATE * 2, _move(1.0, DotFpsCommand.BUTTON_JUMP))
	var moved := _ada().controller.state.position.distance_to(at)
	_check(moved < 0.05, "a frozen player holding forward and jump does not move",
		"%.3f m" % moved)
	_check(_ada().arsenal.disabled, "and cannot shoot either")

	var _off := await _say(_admin, "!unfreeze Ada")
	_step(TICK_RATE, _move(1.0))
	_check(
		_ada().controller.state.position.distance_to(at) > 1.0,
		"and !unfreeze lets her run again"
	)

	var _fast := await _say(_admin, "!speed Ada 2")
	_check(
		is_equal_approx(DotFpsAdminModifiers.speed_of(_ada().controller), 2.0),
		"!speed Ada 2 is a modifier the client will predict"
	)
	var _normal := await _say(_admin, "!speed Ada 1")
	_done()


func _test_slap_and_slay() -> void:
	_section("slap and slay")

	_put_ada_on_the_floor()
	var before := _ada().health.health
	var _slap := await _say(_admin, "!slap Ada 10")
	_check(
		is_equal_approx(_ada().health.health, before - 10.0)
		and _ada().controller.state.velocity.y > 1.0,
		"!slap Ada 10 costs ten health and throws her in the air",
		"%.0f health, %.1f m/s up" % [_ada().health.health, _ada().controller.state.velocity.y]
	)

	var _god := await _say(_admin, "!god Ada")
	var deaths := _deaths_of(73)
	var slain := await _say(_admin, "!slay Ada")
	_check(not _ada().is_alive(), "!slay Ada kills her, god mode or not", " / ".join(slain))
	_check(
		_deaths_of(73) == deaths + 1,
		"and the match counts it, because it is ordinary damage through dot-combat"
	)

	var again := await _say(_admin, "!slay Ada")
	_check(" ".join(again).contains("already dead"), "a second slay says she is already dead",
		" / ".join(again))
	_done()


func _test_respawn_clears() -> void:
	_section("a respawn is a new body")

	var _frozen := await _say(_admin, "!freeze Ada")
	var _noclip := await _say(_admin, "!noclip Ada")
	var brought := await _say(_admin, "!respawn Ada")
	_check(_ada().is_alive(), "!respawn Ada brings her back", " / ".join(brought))
	_check(
		not DotFpsAdminModifiers.is_frozen(_ada().controller)
		and not DotFpsAdminModifiers.is_noclipped(_ada().controller),
		"without the freeze or the noclip she died with"
	)
	_check(
		_ada().health.invulnerable
		and _module.services.mod_tools.is_active(&"73", DotModTools.ACTION_GOD),
		"but still godded, because god outlives a death on purpose"
	)
	var _off := await _say(_admin, "!god Ada off")
	_done()


func _test_immunity_and_self() -> void:
	_section("immunity, and yourself")

	var refused := await _say(_moderator, "!slay Boss")
	_check(
		_game.player_for(71).is_alive() and " ".join(refused).contains("immunity"),
		"a moderator cannot slay an administrator", " / ".join(refused)
	)

	var _mine := await _say(_admin, "!noclip")
	_check(
		DotFpsAdminModifiers.is_noclipped(_game.player_for(71).controller),
		"a bare !noclip is the admin's own, and their own immunity does not refuse it"
	)
	var _mine_off := await _say(_admin, "!noclip off")
	_done()


func _test_reporting() -> void:
	_section("what an operator can see")

	var lines := await _say(_admin, "!modtools")
	var joined := " ".join(lines)
	_check(
		joined.contains("abilities") and joined.contains("noclip") and joined.contains("slay"),
		"!modtools lists what this game supports"
	)
	_check(
		joined.contains("blind (the client draws no overlay"),
		"and why it refuses what it does not"
	)

	var audited := FileAccess.get_file_as_string("%s/audit.jsonl" % SERVER_DIR)
	_check(
		audited.contains("\"noclip\"") and audited.contains("\"slay\""),
		"every action is in the server's audit log"
	)

	var history: Array[DotPunishment] = _module.services.moderation.history_for("73")
	var slapped := false
	for record in history:
		if record.evidence.get("action", "") == "slap":
			slapped = true
	_check(slapped, "and on the player's own moderation history", "%d records" % history.size())
	_done()


func _deaths_of(id: int) -> int:
	var record := _game.match_node.scoreboard.find(str(id))
	return record.deaths if record != null else -1
