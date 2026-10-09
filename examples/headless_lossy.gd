extends Node

const ArenaEvents := preload("../game/arena_events.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModTools := preload("../game/arena_mod_tools.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## dot-net's lossy UDP relay, by path: a test tool that ships inside the addon so a game
## that links dot_net can reach it, and has no class_name for the same reason.
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## A real arena server, real ENet clients, and real packet loss between them.
##
## [codeblock]
## godot --headless --path . res://examples/headless_lossy.tscn
## godot --headless --path . res://examples/headless_lossy.tscn -- --verbose
## [/codeblock]
##
## [code]--verbose[/code] adds the diagnostics every finding here was made with: A's clock
## every quarter second, its inputs and ENet's packet throttle every half second, input
## transit and snapshot age, and a line per freeze. [code]--ping-rtt[/code] puts a defect
## back as a control: it feeds the clock the heartbeat's round trip instead of ENet's (see
## [method ArenaNetBridge.link_rtt_ms]), and it fails checks. (`--stock-enet` was the other
## until dot-core's DotTransportENet stopped advertising six bytes a second; its own
## `dual_transport_selftest` holds that one now.)
##
## [b]What only this can see.[/b] `headless_net` drops one packet in five, but in its own
## loopback: in order, instantly, never twice, and never a reliable one. A browser's
## "unreliable" is TCP. So until a server listened on ENet as well, nothing here had ever
## had a datagram arrive late, out of order, twice, or not at all -- and a reliable event
## had never been retransmitted. This puts dot-net's relay between a real `DotClientLink`
## on ENet and a real `DotServer` running `ArenaModule`, and plays.
##
## Two clients. **A** goes through the relay and is the one measured: it runs, strafes and
## turns, so its prediction has something to get wrong. **B** connects straight to the
## server and runs a circle, so the server's B is a smooth reference A's interpolation can
## be held to. A dummy the server adds itself is slain every couple of seconds, for a kill
## feed nobody's own movement is caught up in.
##
## A's first three seconds are measured on their own, and then each window plays at one
## setting -- a steady 55 ms each way, then 5% and 20% loss each way with 30..80 ms -- and
## measures: whether A stays connected; how far A's clock error moves once settled; how
## smooth A's drawing of B is (the longest freeze while B moved, the largest jump beyond
## B's own motion, how far the drawing is from where the server had B at that render
## time, extrapolated frames); how far A's prediction is from the server's A, tick for
## tick, and what the predictor corrected; the loss DotNetStats reports against what the
## relay injected; and that every reliable event -- a numbered notice, a kill, a chat line
## either way, a join and a leave -- arrived exactly once and in order.

const PORT := 27094
const DATA := "user://arena_lossy"
const TICK_RATE := 64
const DUMMY_ID := 9001

## The windows: name, loss each way, delay, jitter (so 30..80 ms), seconds.
const WINDOWS := [
	["steady 55 ms", 0.0, 55.0, 0.0, 6.0],
	["5% loss", 0.05, 55.0, 25.0, 10.0],
	["20% loss", 0.20, 55.0, 25.0, 10.0],
]

## How long the first-seconds measurement runs, right after A connects.
const FIRST_SECONDS := 3.0

## Checks per window, and outside them.
const WINDOW_CHECKS := 16
const OTHER_CHECKS := 14

var CHECKS := OTHER_CHECKS + WINDOW_CHECKS * WINDOWS.size()

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0
var _verbose := false

var _server_side: Node = null
var _server: DotServer = null
var _game: ArenaGame = null
var _relay = null

## name -> client record, see [method _connect_client].
var _clients: Dictionary = {}

## Whether the per-frame drivers run.
var _driving := false

## Server truth: session id -> {tick -> Vector3}, recorded every physics frame.
var _server_track: Dictionary = {}

## A's prediction: input tick -> Vector3.
var _predicted: Dictionary = {}

## What a window measures per frame. Reset by [method _begin_window].
var _w: Dictionary = {}

## The reliable streams, as sent and as A received them.
var _sent_notices: Array[String] = []
var _sent_chat: Array[String] = []
var _sent_kills: Array[String] = []
var _sent_a_chat: Array[String] = []
var _got_notices: Array[String] = []
var _got_chat: Array[String] = []
var _got_kills: Array[String] = []
var _got_a_chat: Array[String] = []
var _a_saw_added: Array[int] = []

## Verbose diagnostics: when A sent each input tick, and the transit times seen.
var _w_sent_at: Dictionary = {}
var _last_half := 0
var _last_sent := 0
var _last_got := 0
var _w_seen_up: Dictionary = {}


func _ready() -> void:
	_verbose = "--verbose" in OS.get_cmdline_user_args()
	DotLog.set_level(DotLog.Level.INFO if _verbose else DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: a real server and real ENet clients through real packet loss")
	DotPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE

	if await _boot():
		if await _connect_everyone():
			for window in WINDOWS:
				await _play_window(window)
			await _test_leave()

	await _teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered])
	_check(_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a section that aborted part-way stops adding checks, and only a total can show it")

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- The harness ------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


## The client's ENet packet throttle towards the server, out of 32; -1 off ENet.
func _throttle_of(label: String) -> int:
	var mp: Object = (_clients[label]["link"] as DotClientLink).multiplayer.multiplayer_peer
	var server_peer: Object = mp.call("get_peer", 1) if mp != null and mp.has_method("get_peer") else null
	if server_peer == null or not server_peer.has_method("get_statistic"):
		return -1
	return int(server_peer.call("get_statistic",
		ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_PACKET_THROTTLE")))


func _peer_of(label: String) -> int:
	return (_clients[label]["link"] as DotClientLink).multiplayer.get_unique_id()


func _module() -> ArenaModule:
	return _server.modules.get_module("arena") as ArenaModule if _server != null else null


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	_section("a dual-stack arena server, and the relay in front of its UDP port")

	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	# Its own MultiplayerAPI, and so does each client: one process, three ends, and an RPC
	# is routed by its path relative to the API's root -- `Server/Arena` on every end.
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.register_service = true
	_server_side.add_child(_game)

	var ready := _game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "the arena sets up", str(ready.error)):
		_done()
		return false

	var config := DotServerConfig.new()
	config.hostname = "arena lossy"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % DATA
	config.bans_path = "%s/bans.json" % DATA
	config.audit_log_path = "%s/audit.jsonl" % DATA
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	# No query listener: with one the UDP port is shared through a demux, which is its own
	# measurement (dual-stack-follow-1, point 2). This one is about the game's traffic.
	config.query_enabled = false
	# Its own UDP port, not shared through the demux: that relay is its own measurement too.
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "debug" if _verbose else "error"

	# The server's ENet is dot-core's own: DotTransportENet no longer advertises the engine's
	# channel count as its incoming bandwidth (which throttled every client's commands to
	# 1/32 for its first seconds; see CLAUDE.md "Real loss"), so nothing is built by hand.

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	_server_side.add_child(_server)

	var booted: DotResult = await _server.boot()
	if not _check(booted.ok, "the server boots, WebSocket and ENet on %d" % PORT, str(booted.error)):
		_done()
		return false

	ArenaModule.punishments_file = "%s/punishments.json" % DATA
	var loaded: DotResult = await _server.modules.load_module("res://game/arena_module.gd")
	if not _check(loaded.ok, "the arena module loads", str(loaded.error)):
		_done()
		return false

	_relay = Relay.new()
	_relay.seed = 20261009
	var w: Array = WINDOWS[0]
	_relay.up.configure(float(w[1]), float(w[2]), float(w[3]))
	_relay.down.configure(float(w[1]), float(w[2]), float(w[3]))
	var relayed: DotResult = _relay.start(0, "127.0.0.1", config.effective_enet_port())
	_check(relayed.ok, "the relay listens in front of UDP %d" % config.effective_enet_port(),
		str(relayed.error))
	_done()
	return relayed.ok


## A client: a DotClientLink on ENet only, and the netcode `ArenaClient._build_netcode`
## builds, minus everything that draws.
func _connect_client(label: String, udp_port: int) -> Dictionary:
	var side := Node.new()
	side.name = "Client%s" % label
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Runner %s" % label
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % udp_port
	side.add_child(link)

	var record := {
		"label": label, "side": side, "link": link, "game": null, "net": null,
		"bridge": null, "session": 0, "spawned": [false], "gone": [""], "hello": [{}],
	}
	link.spawned.connect(func() -> void: record["spawned"][0] = true)
	link.disconnected.connect(func(reason: String) -> void: record["gone"][0] = reason)

	# Started without `await`, so a failed join is read off the link rather than waited on.
	link.connect_to_server("127.0.0.1:%d" % PORT)

	await _until(func() -> bool:
		return record["spawned"][0] or record["gone"][0] != "" \
			or link.phase == DotClientLink.Phase.FAILED, 30.0)
	if link.last_error != null and not record["spawned"][0]:
		record["error"] = str(link.last_error)
		return record
	if not record["spawned"][0]:
		record["error"] = "never spawned: %s" % record["gone"][0]
		return record

	var game := ArenaGame.new()
	game.name = "Game"
	game.is_authority = false
	game.headless = true
	game.register_service = false
	side.add_child(game)
	game.setup(ArenaMap.dm_box())

	var net := DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.service_scope = StringName("lossy_%s" % label)
	net.local_peer_id = side.multiplayer.get_unique_id()
	net.auto_tick = false
	net.config_file = ""
	var cfg := DotNetConfig.new()
	cfg.tick_rate = game.tick_rate
	cfg.snapshot_rate = ArenaGame.NET_SNAPSHOT_RATE
	cfg.enable_prediction = true
	cfg.enable_lag_compensation = false
	cfg.max_entities_per_snapshot = 64
	cfg.world_extent = ArenaGame.NET_WORLD_EXTENT
	net.config = cfg
	side.add_child(net)
	net.setup()

	var bridge := ArenaNetBridge.new()
	bridge.name = "Bridge"
	side.add_child(bridge)
	bridge.attach(game, net)
	bridge.open_link(link)
	net.messages.seal()
	# What `ArenaClient` feeds it. `--ping-rtt` puts back the heartbeat alone, which is the
	# control for the clock checks: the first eight seconds of a connection are late then.
	if "--ping-rtt" in OS.get_cmdline_user_args():
		bridge.rtt_source = func() -> float: return float(maxi(0, link.ping_ms()))
	else:
		bridge.rtt_source = func() -> float: return ArenaNetBridge.link_rtt_ms(link)
	bridge.hello_received.connect(func(info: Dictionary) -> void:
		record["hello"][0] = info
		record["session"] = int(info["session_id"])
	)

	record["game"] = game
	record["net"] = net
	record["bridge"] = bridge
	net.start()
	bridge.send_request(ArenaEvents.Ask.READY)

	await _until(func() -> bool: return int(record["session"]) != 0 and net.clock.is_synced(), 20.0)
	return record


func _connect_everyone() -> bool:
	_section("two clients connect, A through the relay at %s" % WINDOWS[0][0])

	var a := await _connect_client("A", _relay.port())
	_clients["A"] = a
	if not _check(a.get("bridge") != null and int(a["session"]) != 0,
			"A connects over ENet through the relay, and is told who it is",
			str(a.get("error", ""))):
		_done()
		return false

	_check((a["link"] as DotClientLink).transport_used == "enet", "on ENet, not WebSocket",
		(a["link"] as DotClientLink).transport_used)

	print("    A's ENet packet throttle: %d/32" % _throttle_of("A"))

	# [b]The first seconds of a connection, which is where the clock had nothing to go on.[/b]
	# A plays from here, before B has even connected. Its round trip used to come from the
	# link's heartbeat, which is -1 until the first one comes back -- two seconds at best,
	# eight in one run -- and until then the clock left the flight time out of its lead
	# and the commands arrived after their ticks. Half a second for the first ones to cross.
	_driving = true
	await _until(func() -> bool: return false, 0.5)
	var first_buffer := _module().net.input_buffer_for(_peer_of("A"))
	var first_starved := first_buffer.starved_count
	var first_late := first_buffer.late_count
	var first_tick := _game.current_tick()
	await _until(func() -> bool: return false, FIRST_SECONDS)
	var first_ticks := _game.current_tick() - first_tick
	var first_in_time := 1.0 - float(first_buffer.starved_count - first_starved) / float(maxi(1, first_ticks))
	_check(first_in_time >= 0.95,
		"in A's first %d seconds the server had its command for %.1f%% of %d ticks, %d late" % [
			int(FIRST_SECONDS), first_in_time * 100.0, first_ticks, first_buffer.late_count - first_late],
		"its clock's round trip %d ms" % int((a["net"] as DotNetManager).clock.rtt_ms()))

	var a_game: ArenaGame = a["game"]
	a_game.player_added.connect(func(p: ArenaPlayer) -> void: _a_saw_added.append(p.player_id))
	(a["bridge"] as ArenaNetBridge).notice_received.connect(func(text: String) -> void:
		if text.begins_with("seq-"):
			_got_notices.append(text)
	)
	(a["bridge"] as ArenaNetBridge).kill_received.connect(func(info: Dictionary) -> void:
		_got_kills.append("%d>%d" % [int(info["killer_id"]), int(info["victim_id"])])
	)
	(a["link"] as DotClientLink).chat_received.connect(func(payload: Dictionary) -> void:
		# dot-server's own line carries `text`; one routed through dot-chat carries `m`.
		var text := str(payload.get("text", payload.get("m", "")))
		if text.begins_with("chat-"):
			_got_chat.append(text)
		elif text.contains("a-says-"):
			# dot-chat puts the speaker in front of a player's line.
			_got_a_chat.append(text.substr(text.find("a-says-")))
		elif _verbose:
			print("    (A got chat %s)" % payload)
	)

	(a["net"] as DotNetManager).snapshot_applied.connect(func(tick: int) -> void:
		if _verbose and not _w.is_empty():
			_w["down_ticks"] = _w.get("down_ticks", []) + [_game.current_tick() - tick]
	)

	var b := await _connect_client("B", _server.config.effective_enet_port())
	_clients["B"] = b
	if not _check(b.get("bridge") != null and int(b["session"]) != 0,
			"B connects straight to the server's UDP port", str(b.get("error", ""))):
		_done()
		return false

	# The dummy the kill feed is about, added on the server alone.
	var dummy := _game.add_player(DUMMY_ID, "Dummy")
	_check(dummy.ok, "the server seats a dummy to slay", str(dummy.error))
	_game.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
		var killer := int(entry.killer_key) if String(entry.killer_key).is_valid_int() else 0
		var victim := int(entry.victim_key) if String(entry.victim_key).is_valid_int() else 0
		_sent_kills.append("%d>%d" % [killer, victim])
	)

	var b_session := int(b["session"])
	var seen := await _until(func() -> bool: return a_game.player_for(b_session) != null, 10.0)
	_check(seen and _a_saw_added.count(b_session) == 1,
		"A is told B joined, exactly once, through the loss",
		"added %s" % [_a_saw_added])

	_done()
	return true


# --- The drivers --------------------------------------------------------------

## A runs forward, strafes left and right, and turns: a constant input is not an input.
func _command_a(tick: int) -> DotFpsCommand:
	var move := DotFpsCommand.new()
	var strafe := 1.0 if (tick / 24) % 2 == 0 else -1.0
	move.move = Vector2(strafe * 0.6, 0.8)
	move.yaw = fmod(float(tick) * 1.4, 360.0)
	move.pitch = 0.0
	return move


## B runs a circle: forward, turning at a steady rate, so its motion is smooth and known.
func _command_b(tick: int) -> DotFpsCommand:
	var move := DotFpsCommand.new()
	move.move = Vector2(0.0, 1.0)
	move.yaw = fmod(float(tick) * 1.0, 360.0)
	return move


func _physics_process(delta: float) -> void:
	if not _driving:
		return

	# Server truth, as of the last tick the module ran.
	var server_tick := _game.current_tick()
	for label in _clients:
		var session := int(_clients[label]["session"])
		var body := _game.player_for(session)
		if body != null:
			if not _server_track.has(session):
				_server_track[session] = {}
			_server_track[session][server_tick] = body.controller.state.position

	for label in _clients:
		var c: Dictionary = _clients[label]
		var net: DotNetManager = c["net"]
		var bridge: ArenaNetBridge = c["bridge"]
		if net == null or not net.is_running():
			continue

		net.stats.roll()
		var ticks := net.clock.advance(delta)
		for i in range(ticks):
			if not net.clock.is_synced():
				continue
			var tick := net.clock.input_tick() - (ticks - 1 - i)
			var move := _command_a(tick) if label == "A" else _command_b(tick)
			var fire := DotWeaponCommand.new()
			bridge.client_tick(tick, move, fire)
			if bridge.link != null:
				bridge.link.send_input(bridge.encode_input(tick, move, fire))

			if label == "A" and _verbose:
				_w_sent_at[tick] = Time.get_ticks_usec()
			if label == "A":
				var own: ArenaPlayer = (c["game"] as ArenaGame).player_for(int(c["session"]))
				if own != null:
					_predicted[tick] = own.controller.state.position

	if _verbose and _clients.has("A") and _clients["A"].get("bridge") != null:
		var now_q := Time.get_ticks_msec() / 500
		if now_q != _last_half:
			_last_half = now_q
			var sent := ((_clients["A"]["bridge"] as ArenaNetBridge).link.inputs_sent)
			var got := int(_module().bridge.inputs_from.get(_peer_of("A"), 0))
			var throttle_client := -1
			var throttle_server := -1
			var stat := ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_PACKET_THROTTLE")
			var cpeer: Object = (_clients["A"]["link"] as DotClientLink).multiplayer.multiplayer_peer
			if cpeer != null and cpeer.has_method("get_peer"):
				var p1: Object = cpeer.call("get_peer", 1)
				if p1 != null:
					throttle_client = int(p1.call("get_statistic", stat))
					var names := ["PEER_PACKET_THROTTLE_LIMIT", "PEER_PACKET_THROTTLE_ACCELERATION", "PEER_PACKET_THROTTLE_DECELERATION", "PEER_LAST_ROUND_TRIP_TIME", "PEER_ROUND_TRIP_TIME_VARIANCE", "PEER_LAST_ROUND_TRIP_TIME_VARIANCE"]
					var parts := PackedStringArray()
					for n in names:
						parts.append("%s=%d" % [n.trim_prefix("PEER_"), int(p1.call("get_statistic", ClassDB.class_get_integer_constant(&"ENetPacketPeer", StringName(n))))])
					print("        %s" % " ".join(parts))
			var enet: Object = _server_side.multiplayer.multiplayer_peer.get("enet")
			if enet != null:
				var pa: Object = enet.call("get_peer", _peer_of("A"))
				if pa != null:
					throttle_server = int(pa.call("get_statistic", stat))
			print("      half-second: A sent %d, server got %d, relay up %s; ENet throttle client %d server %d (of 32)" % [
				sent - _last_sent, got - _last_got, _relay.up.received, throttle_client, throttle_server])
			_last_sent = sent
			_last_got = got

	if not _w.is_empty():
		_sample_clock(server_tick)
		# What the server will find for A on the tick it runs next: there, a hole in what
		# arrived (lost, and not covered), or nothing that far yet (late).
		var buffer: DotNetInput.Buffer = _w["buffer"]
		var due := server_tick + 1
		var newest := buffer.newest()
		if _verbose:
			var slack := (newest.tick - server_tick) if newest != null else -99
			_w["slack"] = _w.get("slack", []) + [slack]
			if newest != null and not _w_seen_up.has(newest.tick) and _w_sent_at.has(newest.tick):
				_w_seen_up[newest.tick] = true
				var ms := float(Time.get_ticks_usec() - int(_w_sent_at[newest.tick])) / 1000.0
				_w["up_ms"] = _w.get("up_ms", []) + [ms]
		if buffer.peek(due) == null:
			if newest != null and newest.tick > due:
				_w["holes"] = int(_w.get("holes", 0)) + 1
			else:
				_w["not_yet"] = int(_w.get("not_yet", 0)) + 1


func _process(_delta: float) -> void:
	if not _driving or _w.is_empty():
		return

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	net.interpolate_frame()
	_sample_render()


## A's clock: its own error, and its real lead over the server it shares a process with.
func _sample_clock(server_tick: int) -> void:
	var net: DotNetManager = _clients["A"]["net"]
	var clock := net.clock
	if not clock.is_synced():
		return

	var target := clock.server_tick() + int(clock.call("_target_lead"))
	var error := target - clock.tick
	var lead := clock.input_tick() - server_tick
	var t := float(Time.get_ticks_msec() - int(_w["started_ms"])) / 1000.0

	_w["clock_samples"].append([t, error, lead])
	if _verbose and int(t * 4.0) != int(_w.get("last_quarter", -1)):
		_w["last_quarter"] = int(t * 4.0)
		print("      t %.2f  error %d  lead %d  rtt %d  jitter %d  target lead %d  est %d  tick %d  server %d" % [
			t, error, lead, int(clock.rtt_ms()), int(clock.jitter_ms()), int(clock.call("_target_lead")),
			clock.server_tick(), clock.tick, server_tick])


## A's drawing of B, against where the server had B at that render time.
func _sample_render() -> void:
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var b_session := int(_clients["B"]["session"])
	var seen := (a["game"] as ArenaGame).player_for(b_session)
	var track: Dictionary = _server_track.get(b_session, {})
	if seen == null or track.is_empty() or not net.clock.is_synced():
		return

	var drawn := seen.global_position
	# Exactly what `DotNetManager.interpolate_frame` hands the interpolator.
	var render_tick := float(net.clock.received_tick()) \
		+ clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0) \
		- net.interpolator.delay_ticks()
	var truth: Variant = _truth_at(track, render_tick)
	var now_ms := Time.get_ticks_msec()

	# The render timeline itself: it should advance by a frame's worth of ticks every
	# frame, never go back, and never leap. A timeline that steps back and forth draws a
	# remote player stuttering even when every position it is asked for is right, which
	# the jump measurement below cannot see because the truth moves back with it.
	var last_render: Variant = _w.get("last_render")
	if last_render != null:
		var step := render_tick - float(last_render)
		var expected := float(now_ms - int(_w["last_ms"])) / 1000.0 * float(TICK_RATE)
		if step < -0.01:
			_w["render_back"] = int(_w.get("render_back", 0)) + 1
			_w["render_back_max"] = maxf(float(_w.get("render_back_max", 0.0)), -step)
		_w["render_lurch_max"] = maxf(float(_w.get("render_lurch_max", 0.0)), absf(step - expected))
	_w["last_render"] = render_tick

	if truth != null:
		_w["render_errors"].append(drawn.distance_to(truth))

	var last: Variant = _w.get("last_drawn")
	var last_truth: Variant = _w.get("last_truth")
	if last != null and truth != null and last_truth != null:
		var moved := drawn.distance_to(last)
		var should := (truth as Vector3).distance_to(last_truth)
		_w["max_jump"] = maxf(float(_w["max_jump"]), moved - should)

		# A freeze: the drawing did not move while the truth did, frame after frame.
		if moved < 0.0005 and should > 0.002:
			if int(_w["freeze_since"]) < 0:
				_w["freeze_since"] = int(_w["last_ms"])
			_w["max_freeze_ms"] = maxi(int(_w["max_freeze_ms"]), now_ms - int(_w["freeze_since"]))
			if _verbose and now_ms - int(_w["freeze_since"]) > 150:
				var b_identity := (a["bridge"] as ArenaNetBridge).behaviour_for(b_session)
				var b_track: Variant = net.interpolator.get("_tracks").get(b_identity.identity.net_id) if b_identity != null else null
				print("      FREEZE %d ms: render %.2f received %d server %d newest-B %s applied %d drawn %s truth %s" % [
					now_ms - int(_w["freeze_since"]), render_tick, net.clock.received_tick(), _game.current_tick(),
					str(b_track.newest_tick()) if b_track != null else "-", net.ack_tick(), drawn, truth])
		else:
			_w["freeze_since"] = -1

	_w["last_drawn"] = drawn
	_w["last_truth"] = truth
	_w["last_ms"] = now_ms
	_w["frames"] = int(_w["frames"]) + 1


static func _truth_at(track: Dictionary, tick: float) -> Variant:
	var lo := int(floorf(tick))
	if not track.has(lo) or not track.has(lo + 1):
		return null
	return (track[lo] as Vector3).lerp(track[lo + 1], tick - float(lo))


# --- A window -----------------------------------------------------------------

func _begin_window() -> void:
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var server_net: DotNetManager = _module().net
	var buffer := server_net.input_buffer_for(int((a["link"] as DotClientLink).multiplayer.get_unique_id()))

	_relay.reset_counts()
	net.interpolator.reset_counts()

	_w = {
		"started_ms": Time.get_ticks_msec(),
		"clock_samples": [],
		"render_errors": [],
		"max_jump": 0.0,
		"max_freeze_ms": 0,
		"freeze_since": -1,
		"last_drawn": null,
		"last_truth": null,
		"last_ms": Time.get_ticks_msec(),
		"frames": 0,
		"stats_lost": net.stats.snapshots_lost,
		"stats_received": net.stats.snapshots_received,
		"replays": int(net.predictor.get("_replays")),
		"corrections": int(net.predictor.get("_corrections_applied")),
		"snaps": int(net.clock.get("_snap_count")),
		"catch_ups": int(net.clock.get("_catch_up_count")),
		"starved": buffer.starved_count,
		"late": buffer.late_count,
		"first_tick": net.clock.input_tick(),
		"buffer": buffer,
		"inputs_sent": (a["bridge"] as ArenaNetBridge).link.inputs_sent,
		"b_inputs_sent": (_clients["B"]["bridge"] as ArenaNetBridge).link.inputs_sent,
		"a_inputs_got": int(_module().bridge.inputs_from.get(_peer_of("A"), 0)),
		"b_inputs_got": int(_module().bridge.inputs_from.get(_peer_of("B"), 0)),
		"inputs_received": _module().bridge.link.inputs_received,
		"snapshots_received": (a["bridge"] as ArenaNetBridge).link.snapshots_received,
	}


func _play_window(window: Array) -> void:
	var title := String(window[0])
	var loss := float(window[1])
	var seconds := float(window[4])
	_section("%s each way, %d..%d ms, %d seconds" % [
		title, int(window[2] - window[3]), int(window[2] + window[3]), int(seconds)])

	_relay.set_impairment(true, loss, float(window[2]), float(window[3]))
	_relay.set_impairment(false, loss, float(window[2]), float(window[3]))

	# Two seconds to settle at the new rate before anything is measured.
	await _until(func() -> bool: return false, 2.0)
	_begin_window()

	var notices_from := _sent_notices.size()
	var chat_from := _sent_chat.size()
	var kills_from := _sent_kills.size()
	var a_chat_from := _sent_a_chat.size()
	var got_notices_from := _got_notices.size()
	var got_chat_from := _got_chat.size()
	var got_kills_from := _got_kills.size()
	var got_a_chat_from := _got_a_chat.size()

	var started := Time.get_ticks_msec()
	var next_notice := started
	var next_chat := started + 150
	var next_a_chat := started + 300
	var next_slay := started + 500
	var link_a: DotClientLink = _clients["A"]["link"]

	while Time.get_ticks_msec() - started < int(seconds * 1000.0):
		var now := Time.get_ticks_msec()
		if now >= next_notice:
			var text := "seq-%d" % _sent_notices.size()
			_sent_notices.append(text)
			_module().bridge.send_event(0, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice(text))
			next_notice += 250
		if now >= next_chat:
			var line := "chat-%d" % _sent_chat.size()
			_sent_chat.append(line)
			_server.chat.broadcast_system(line)
			next_chat += 400
		if now >= next_a_chat:
			var said := "a-says-%d" % _sent_a_chat.size()
			_sent_a_chat.append(said)
			link_a.send_chat(said)
			next_a_chat += 3500
		if now >= next_slay:
			var dummy := _game.player_for(DUMMY_ID)
			if dummy != null and dummy.is_alive():
				ArenaModTools.slay(_game, StringName(str(DUMMY_ID)))
				next_slay += 900
			elif dummy != null:
				_game.respawn_player(DUMMY_ID)
				next_slay += 300
		await get_tree().process_frame

	# Everything sent in the window gets 35 seconds to land; the wait ends the moment it
	# has. 35 because the contract is ENet's own: with dot-core's peer timeouts a reliable
	# command either arrives within 30 s or the peer is dropped, and a drop fails "still
	# connected" above. Twenty failed one run in twenty (2026-10-09). ENet doubles a reliable command's resend timeout every time it goes unacknowledged,
	# and a resend fails if the data OR its acknowledgement is lost: 36% a try at 20% each
	# way, not 20%. Five failures in a row, about one command in a hundred and seventy (a
	# window sends a few hundred), is 31 resend timeouts of ~230 ms, seven seconds; everything
	# behind it on the channel waits too, because ENet delivers a channel in order. Six
	# seconds was written for 20% a try and failed a run in eight on exactly that (2026-10-09).
	# Late is allowed; lost, duplicated or reordered is not, and that is what is checked.
	await _until(func() -> bool:
		return _got_notices.size() - got_notices_from >= _sent_notices.size() - notices_from \
			and _got_kills.size() - got_kills_from >= _sent_kills.size() - kills_from \
			and _got_chat.size() - got_chat_from >= _sent_chat.size() - chat_from \
			and _got_a_chat.size() - got_a_chat_from >= _sent_a_chat.size() - a_chat_from,
		35.0)

	_measure_window(title, loss,
		_sent_notices.slice(notices_from), _got_notices.slice(got_notices_from),
		_sent_kills.slice(kills_from), _got_kills.slice(got_kills_from),
		_sent_chat.slice(chat_from), _got_chat.slice(got_chat_from),
		_sent_a_chat.slice(a_chat_from), _got_a_chat.slice(got_a_chat_from))
	_w = {}
	_done()


func _measure_window(
	title: String, loss: float,
	sent_notices: Array, got_notices: Array,
	sent_kills: Array, got_kills: Array,
	sent_chat: Array, got_chat: Array,
	sent_a_chat: Array, got_a_chat: Array
) -> void:
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var link: DotClientLink = a["link"]
	var said: Dictionary = _relay.describe()

	# --- connection ---
	# Both ends. A client whose server has dropped it does not find out until its own ENet
	# gives up, so asking only the client passed a window in which the server had
	# disconnected A and A had heard nothing for seconds (2026-10-09: ENet's own peer
	# timeouts, now dot-core's DotTransportENet.peer_timeout_*).
	var a_session := int(a["session"])
	var on_server := _game.player_for(a_session) != null
	_check(link.phase == DotClientLink.Phase.PLAYING and String(a["gone"][0]) == "" and on_server,
		"%s: A is still connected and playing, on both ends" % title,
		"gone: '%s', on the server: %s" % [a["gone"][0], on_server])
	var injected_down := float(_relay.down.loss_ratio())
	var injected_up := float(_relay.up.loss_ratio())
	_check(absf(injected_down - loss) < 0.06 and absf(injected_up - loss) < 0.06,
		"%s: the relay injected it (down %.3f, up %.3f)" % [title, injected_down, injected_up])

	# --- the clock ---
	var samples: Array = _w["clock_samples"]
	var settled_errors: Array[int] = []
	var leads: Array[int] = []
	for s in samples:
		if float(s[0]) >= 3.0:
			settled_errors.append(int(s[1]))
		leads.append(int(s[2]))
	var worst_error := 0
	for e in settled_errors:
		worst_error = maxi(worst_error, absi(e))
	var min_lead := 1 << 30
	var max_lead := -(1 << 30)
	for l in leads:
		min_lead = mini(min_lead, l)
		max_lead = maxi(max_lead, l)
	var snaps := int(net.clock.get("_snap_count")) - int(_w["snaps"])
	var catch_ups := int(net.clock.get("_catch_up_count")) - int(_w["catch_ups"])
	var buffer: DotNetInput.Buffer = _w["buffer"]
	var late := buffer.late_count - int(_w["late"])
	var starved := buffer.starved_count - int(_w["starved"])
	var ticks_run := net.clock.input_tick() - int(_w["first_tick"])
	print("    clock: settled error within +-%d ticks over %d samples; real lead %d..%d ticks; %d snaps, %d catch-ups; rtt %d ms, jitter %d ms" % [
		worst_error, settled_errors.size(), min_lead, max_lead, snaps, catch_ups,
		int(net.clock.rtt_ms()), int(net.clock.jitter_ms())])
	print("    server's input buffer for A: %d late, %d starved of %d ticks (%.1f%%)" % [
		late, starved, ticks_run, 100.0 * float(starved) / float(maxi(1, ticks_run))])
	print("    before each server tick, A's input for it was: a hole %d times, not there yet %d times" % [
		int(_w.get("holes", 0)), int(_w.get("not_yet", 0))])
	if _verbose:
		var hist := {}
		for v in _w.get("slack", []):
			hist[v] = int(hist.get(v, 0)) + 1
		var keys := hist.keys()
		keys.sort()
		var parts := PackedStringArray()
		for k in keys:
			parts.append("%d:%d" % [k, hist[k]])
		print("    newest buffered input minus server tick, per physics frame: %s" % " ".join(parts))
		var sent_ticks: Array = _w_sent_at.keys()
		sent_ticks.sort()
		var skipped := 0
		for i in range(1, sent_ticks.size()):
			skipped += maxi(0, int(sent_ticks[i]) - int(sent_ticks[i - 1]) - 1)
		print("    A's input ticks sent so far: %d, %d skipped over" % [sent_ticks.size(), skipped])
		var up: Array = _w.get("up_ms", [])
		up.sort()
		if not up.is_empty():
			print("    A's input, sent to first seen in the server's buffer: p10 %.0f p50 %.0f p90 %.0f max %.0f ms (%d)" % [
				up[int(up.size() * 0.1)], up[up.size() / 2], up[int(up.size() * 0.9)], up[up.size() - 1], up.size()])
		var down: Array = _w.get("down_ticks", [])
		down.sort()
		if not down.is_empty():
			print("    a snapshot's age on arrival at A, in server ticks: p10 %d p50 %d p90 %d max %d (%d)" % [
				down[int(down.size() * 0.1)], down[down.size() / 2], down[int(down.size() * 0.9)], down[down.size() - 1], down.size()])
	var a_link := (a["bridge"] as ArenaNetBridge).link
	var b_sent := (_clients["B"]["bridge"] as ArenaNetBridge).link.inputs_sent - int(_w["b_inputs_sent"])
	print("    per peer at the server: A %d of %d, B %d of %d" % [
		int(_module().bridge.inputs_from.get(_peer_of("A"), 0)) - int(_w["a_inputs_got"]),
		a_link.inputs_sent - int(_w["inputs_sent"]),
		int(_module().bridge.inputs_from.get(_peer_of("B"), 0)) - int(_w["b_inputs_got"]), b_sent])
	print("    the relay: up %d datagrams, %d passed on; down %d, %d passed on; A's link took %d snapshots" % [
		_relay.up.received, _relay.up.delivered, _relay.down.received, _relay.down.delivered,
		a_link.snapshots_received - int(_w["snapshots_received"])])
	_check(worst_error <= 3 and snaps == 0,
		"%s: A's clock error settles within 3 ticks and never snaps" % title,
		"+-%d, %d snaps" % [worst_error, snaps])
	# The number every input fix here moved: the share of the server's ticks that had this
	# client's command when they ran. Without the resent copies a lost packet is a tick on a
	# guess (20% at 20% loss); without ENet's own round trip the first seconds are late; with
	# ENet's throttle left as it is the first five are mostly dropped before the wire; and
	# without a poll in the flight time a steady link is late on every tick.
	var in_time := 1.0 - float(starved) / float(maxi(1, ticks_run))
	_check(in_time >= 0.97 and late <= ticks_run / 100,
		"%s: the server had A's command for %.1f%% of its ticks, %d late" % [title, in_time * 100.0, late],
		"real lead %d..%d ticks" % [min_lead, max_lead])

	# --- A's drawing of B ---
	var errors: Array = _w["render_errors"]
	errors.sort()
	var p50 := float(errors[errors.size() / 2]) if not errors.is_empty() else -1.0
	var p95 := float(errors[int(errors.size() * 0.95)]) if not errors.is_empty() else -1.0
	var worst := float(errors[errors.size() - 1]) if not errors.is_empty() else -1.0
	var extrapolated := net.interpolator.extrapolation_count()
	var sampled := net.interpolator.sample_count()
	print("    A draws B: %d frames, off the server's B at the render time by p50 %.3f / p95 %.3f / max %.3f m; longest freeze %d ms; largest jump past B's own motion %.3f m; %d of %d samples extrapolated, %d stalls; delay %.1f ticks" % [
		int(_w["frames"]), p50, p95, worst, int(_w["max_freeze_ms"]), float(_w["max_jump"]),
		extrapolated, sampled, net.interpolator.stall_count(), net.interpolator.delay_ticks()])
	print("    A's render timeline: went back %d times (at most %.2f ticks); the largest step off a frame's worth was %.2f ticks" % [
		int(_w.get("render_back", 0)), float(_w.get("render_back_max", 0.0)), float(_w.get("render_lurch_max", 0.0))])
	_check(int(_w["frames"]) > 100, "%s: A drew B, frame after frame" % title, "%d" % int(_w["frames"]))
	_check(int(_w["max_freeze_ms"]) <= 100,
		"%s: B never freezes on A's screen while moving (longest %d ms)" % [title, int(_w["max_freeze_ms"])])
	_check(float(_w["max_jump"]) <= 0.5,
		"%s: and never jumps more than half a metre past its own motion (%.3f m)" % [title, float(_w["max_jump"])])
	_check(p95 >= 0.0 and p95 <= 0.1,
		"%s: drawn within 10 cm of where the server had B at that time, 95%% of frames (%.3f m)" % [title, p95])
	_check(int(_w.get("render_back", 0)) <= 2 and float(_w.get("render_back_max", 0.0)) <= 1.05,
		"%s: the render timeline goes back at most twice, a tick at most (%d, %.2f)" % [
			title, int(_w.get("render_back", 0)), float(_w.get("render_back_max", 0.0))])
	var share := float(extrapolated) / float(maxi(1, sampled))
	_check(sampled > 0 and share <= 0.25,
		"%s: at least three frames in four drawn between two snapshots (%.0f%% extrapolated)" % [title, share * 100.0])

	# --- A's own prediction ---
	var track: Dictionary = _server_track.get(int(a["session"]), {})
	var diffs: Array[float] = []
	for tick in _predicted:
		if int(tick) >= int(_w["first_tick"]) and track.has(tick):
			diffs.append((_predicted[tick] as Vector3).distance_to(track[tick]))
	diffs.sort()
	var d50 := diffs[diffs.size() / 2] if not diffs.is_empty() else -1.0
	var d95 := diffs[int(diffs.size() * 0.95)] if not diffs.is_empty() else -1.0
	var dmax := diffs[diffs.size() - 1] if not diffs.is_empty() else -1.0
	var replays := int(net.predictor.get("_replays")) - int(_w["replays"])
	var corrections := int(net.predictor.get("_corrections_applied")) - int(_w["corrections"])
	var rate := float(corrections) / float(maxi(1, replays))
	print("    A's prediction against the server's A, %d ticks: p50 %.3f / p95 %.3f / max %.3f m; %d of %d replays corrected (%.1f%%), worst ever %s" % [
		diffs.size(), d50, d95, dmax, corrections, replays, rate * 100.0,
		net.predictor.describe()["worst_error"]])
	_check(diffs.size() > 200, "%s: A predicted, and the server ran the same ticks" % title,
		"%d" % diffs.size())
	_check(d95 >= 0.0 and d95 <= 0.05 and dmax <= 1.5 and rate <= 0.1,
		"%s: A's prediction within 5 cm of the server's for 95%% of ticks, corrected in %.0f%% of replays" % [title, rate * 100.0],
		"p95 %.3f, max %.3f" % [d95, dmax])

	# --- what DotNetStats says ---
	var lost := net.stats.snapshots_lost - int(_w["stats_lost"])
	var received := net.stats.snapshots_received - int(_w["stats_received"])
	var reported := float(lost) / float(maxi(1, lost + received))
	print("    DotNetStats: %d snapshots received, %d inferred lost: %.3f, against %.3f injected" % [
		received, lost, reported, injected_down])
	_check(absf(reported - injected_down) <= 0.05,
		"%s: DotNetStats reports a loss near the injected one (%.3f vs %.3f)" % [title, reported, injected_down])

	# --- reliable streams ---
	_check(not sent_notices.is_empty() and got_notices == sent_notices,
		"%s: %d numbered notices, each exactly once and in order" % [title, sent_notices.size()],
		"" if got_notices == sent_notices else "got %d: %s" % [got_notices.size(), _missing(sent_notices, got_notices)])
	_check(not sent_kills.is_empty() and got_kills == sent_kills,
		"%s: %d kills on the feed, each exactly once and in order" % [title, sent_kills.size()],
		"" if got_kills == sent_kills else "sent %s got %s" % [sent_kills, got_kills])
	_check(not sent_chat.is_empty() and got_chat == sent_chat
			and not sent_a_chat.is_empty() and got_a_chat == sent_a_chat,
		"%s: %d chat lines down and %d of A's own up and back, each exactly once and in order" % [
			title, sent_chat.size(), sent_a_chat.size()],
		"" if got_chat == sent_chat and got_a_chat == sent_a_chat
			else "down %d/%d, A's %s vs %s" % [got_chat.size(), sent_chat.size(), got_a_chat, sent_a_chat])

	if _verbose:
		print("    relay: %s" % said)


## What [param got] lacks of [param sent], has twice, or has out of order, in a line.
static func _missing(sent: Array, got: Array) -> String:
	var lacks: Array = []
	for item in sent:
		if not got.has(item):
			lacks.append(item)
	var twice: Array = []
	for item in got:
		if got.count(item) > 1 and not twice.has(item):
			twice.append(item)
	return "missing %s, twice %s, first %s, last %s" % [lacks, twice,
		got[0] if not got.is_empty() else "-", got[got.size() - 1] if not got.is_empty() else "-"]


# --- The end ----------------------------------------------------------------

func _test_leave() -> void:
	_section("B leaves, and A is told once")

	var b: Dictionary = _clients["B"]
	var b_session := int(b["session"])
	var a_game: ArenaGame = _clients["A"]["game"]
	(b["link"] as DotClientLink).disconnect_from_server("done")
	var b_net: DotNetManager = b["net"]
	b_net.stop()

	# 35 s, the windows' contract: the link is still at the last window's 20% loss, and a
	# reliable message there either lands inside ENet's 30 s or the peer is dropped. Ten
	# failed a CI release run (v0.1.6) on exactly that tail; the wait ends when A is told.
	var gone := await _until(func() -> bool: return a_game.player_for(b_session) == null, 35.0)
	_check(gone, "A's B is gone once the server has seen the disconnect",
		"the server has %d sessions and %s B in its game" % [
			_server.sessions().size(), "still has" if _game.player_for(b_session) != null else "no longer has"])
	_check(_a_saw_added.count(b_session) == 1, "and was never added a second time",
		str(_a_saw_added))
	_done()


func _teardown() -> void:
	_driving = false

	for label in _clients:
		var c: Dictionary = _clients[label]
		var link: DotClientLink = c["link"]
		if link != null and is_instance_valid(link):
			link.disconnect_from_server("test over")

	await get_tree().process_frame

	for label in _clients:
		var side: Node = _clients[label]["side"]
		if side != null and is_instance_valid(side):
			remove_child(side)
			side.queue_free()
	_clients.clear()

	if _relay != null:
		_relay.stop()

	await get_tree().process_frame

	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")

	if _server_side != null and is_instance_valid(_server_side):
		remove_child(_server_side)
		_server_side.queue_free()

	await get_tree().process_frame
