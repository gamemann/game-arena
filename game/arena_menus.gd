extends RefCounted

const ArenaGame := preload("arena_game.gd")

## The in-game menus: pause, settings, controls, scoreboard.
##
## [b]Four screens and about a hundred lines, because dot-ui does the hard part.[/b]
## The stack owns z-order, input blocking, mouse mode and the back key; the settings
## panel builds itself from a `DotConfig`; the rebinder handles conflicts and
## persistence. What is left is deciding which screens exist and what is on them,
## which is the part that is a game's own.

const CHANNEL := "arena.menus"

## What is on the pause menu, top to bottom.
##
## A list of LABELS and no list of ids beside it: [DotPauseScreen] derives the id from the
## label, because two parallel lists are the shape this tree has paid for more than any
## other. `"Interface"` is `&"interface"`, which is the id that screen registers under.
##
## (`const` rather than a `PackedStringArray(...)` call, which is not a constant expression
## in GDScript. It is converted at the one place it is handed over.)
const PAUSE_BUTTONS: Array[String] = [
	"Resume", "Settings", "Interface", "Controls", "Servers", "Leave",
]

## The id of the button the client acts on itself. See [method install].
const LEAVE := &"leave"


## Key bindings, with conflict detection and a file that survives a restart.
class ControlsScreen extends DotScreen:
	var panel: DotBindingsPanel = null

	func _screen_id() -> StringName:
		return &"controls"

	func build(config: DotUiConfig) -> void:
		blocks_input = true

		var container := PanelContainer.new()
		container.set_anchors_preset(Control.PRESET_CENTER)
		container.offset_left = -260.0
		container.offset_right = 260.0
		container.offset_top = -220.0
		container.offset_bottom = 220.0
		add_child(container)

		var column := VBoxContainer.new()
		container.add_child(column)

		var title := Label.new()
		title.text = "Controls"
		title.theme_type_variation = &"DotHeading"
		column.add_child(title)

		panel = DotBindingsPanel.new()
		panel.config = config
		# `dot_fps_` FIRST, and `arena_` beside it, and the pair is the whole screen.
		#
		# `prefix` filters the InputMap, and for the whole life of this screen it was set
		# to `arena_` when there was no `arena_` action at all. This game's movement is
		# registered by `DotFpsSampler.register_default_actions` in
		# `ArenaClient._build_interface` and is therefore named `dot_fps_forward`,
		# `dot_fps_jump` and so on; fire, reload and the scoreboard are matched on a
		# keycode in `_unhandled_input` and are not actions at all. So the rebinder listed
		# nothing: a Controls menu with a title, a Defaults button, a Back button and no
		# controls. Nothing errored, because a filter that matches nothing is a legitimate
		# filter and an empty list is a legitimate list. A rendered frame is what showed it.
		#
		# `arena_` is real now -- `ArenaPresentation._build_chat` creates `arena_chat` and
		# `arena_chat_team` -- and a panel that could filter on only one prefix would show
		# the movement and silently drop the chat keys, which is the same bug one namespace
		# along: a binding a player cannot find on any screen. `also_prefixed` is what lets
		# one panel carry both.
		#
		# game-hungario needs no second prefix: everything it binds, chat included, is
		# already `hungry_`.
		panel.prefix = "dot_fps_"
		panel.also_prefixed = PackedStringArray(["arena_"])
		column.add_child(panel)
		panel.build()
		panel.load_saved()

		# Saving on every change rather than on Back: a player who rebinds and then
		# alt-F4s should not lose it, and there is nothing to batch.
		panel.binding_changed.connect(func(_a: StringName, _e: InputEvent) -> void:
			panel.save()
		)

		var buttons := HBoxContainer.new()
		column.add_child(buttons)

		var reset := Button.new()
		reset.text = "Defaults"
		reset.pressed.connect(func() -> void:
			panel.reset_all()
			panel.save()
		)
		buttons.add_child(reset)

		var back := Button.new()
		back.text = "Back"
		back.pressed.connect(close)
		buttons.add_child(back)


## The scoreboard. Transparent, and does not block input.
##
## Both matter: it is held down during a live game, so it must not stop the player
## moving and must not hide what they are looking at. That is the distinction between
## `blocks_input` and `hides_below` that dot-ui exists to keep straight.
##
## [b]Drawn by dot-menu's `DotMenuScoreboard` since 2026-10-09.[/b] The rows are dot-match's
## records (kills, deaths, assists, score), with the server's roster merged in by key for
## what only the server knows: how long each player has been on and their ping. The ping
## column was a literal 0 before, for as long as this screen existed. Sides are the board's
## teams when the match has more than one.
class ScoreboardScreen extends DotScreen:
	var board: DotMenuScoreboard = null

	var _records: DotScoreboard = null
	var _teams: DotTeamManager = null
	var _me: String = ""

	func _screen_id() -> StringName:
		return &"scoreboard"

	func build(records: DotScoreboard, link: Object = null, teams: DotTeamManager = null) -> void:
		_records = records
		_teams = teams
		blocks_input = false
		hides_below = false
		closable = true
		mouse_mode = DotScreen.Mouse.INHERIT
		mouse_filter = Control.MOUSE_FILTER_IGNORE

		board = DotMenuScoreboard.new()
		board.name = "Board"
		board.title_text = "Arena"
		board.columns = [
			{"key": &"name", "title": "Player", "width": 3.0},
			{"key": &"kills", "title": "K", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"deaths", "title": "D", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"assists", "title": "A", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"score", "title": "Score", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
			{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
		]
		# dot-match's own order: best score, then kills.
		board.sort_with = func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("rank", 0)) < int(b.get("rank", 0))
		board.prepare = _rows_from_match
		if link != null and link.has_signal(&"scoreboard_received"):
			board.feed_from(link)
		add_child(board)

	## Which record is this client's. The roster says so online; offline nobody else will.
	func follow(key: String) -> void:
		_me = key

	func _on_push() -> void:
		if board != null:
			board.open()

	func _on_pop() -> void:
		if board != null:
			board.close()

	func refresh() -> void:
		if board != null and board.is_open():
			board.redraw()

	## The match's records, in the match's order, with the roster's time and ping merged in.
	func _rows_from_match(snap: Dictionary) -> void:
		if _records == null:
			return
		var roster := {}
		for r in (snap.get("players", []) as Array):
			if r is Dictionary:
				roster[str(r.get("id", ""))] = r
		var you := str(snap.get("you", ""))
		var rows: Array = []
		var rank := 1
		var sides := {}
		for record in _records.ranked():
			if not record.present:
				continue
			var known: Dictionary = roster.get(record.key, {})
			rows.append({
				"id": record.key, "rank": rank, "name": record.display_name, "team": record.team,
				"kills": record.kills, "deaths": record.deaths, "assists": record.assists, "score": record.score,
				"seconds": int(known.get("seconds", -1)), "ping": int(known.get("ping", -1)),
				"you": record.key == _me or (you != "" and record.key == you),
			})
			if record.team > 0:
				sides[record.team] = true
			rank += 1
		snap["players"] = rows
		if _teams != null and sides.size() > 1:
			var listed: Array = []
			for id: int in _teams.team_ids():
				var side := _teams.team(id)
				if side != null and not side.is_spectator:
					listed.append({"id": id, "name": side.display_name, "color": side.colour,
						"score": _records.team_score(id)})
			snap["teams"] = listed
		if not snap.has("server"):
			snap["server"] = {"name": "Arena"}


## Registers all four screens with a stack and wires the buttons that navigate.
##
## Returns the pause screen, because that is the one a game opens.
static func install(
	stack: DotScreenStack,
	game: ArenaGame,
	ui_config: DotUiConfig,
	player_settings: Object = null,
	link: Object = null
) -> DotPauseScreen:
	# [b]dot-ui's pause screen, and it used to be a copy of it.[/b] That addon grew
	# `DotPauseScreen` because four clients here had written the same forty lines -- a
	# centred `PanelContainer`, a heading, a column of `Button`s and a focus path -- and
	# this file went on being one of them. What is this game's own is the label list above
	# and what happens when one is pressed.
	var pause := DotPauseScreen.new()
	pause.name = "Pause"
	pause.half_size = Vector2(160.0, 160.0)

	var built_pause := pause.build(PackedStringArray(PAUSE_BUTTONS))

	if not built_pause.ok:
		DotLog.result(CHANNEL, "the pause screen", built_pause)
		pause.free()
		return null

	stack.register(pause)

	# [b]Registered as `interface`, not `settings`, and that distinction is the point.[/b]
	# This screen offers the scale, the safe area, the transition time and how many chat
	# lines the HUD keeps -- real settings, and not one of them is what a player means by
	# the word. The volume, the field of view and the sensitivity are the player's own
	# document, on the screen below; until `settings` pointed at that, a player who opened
	# this menu to turn the game down found a slider for the interface scale.
	#
	# Also dot-ui's screen rather than a second copy of one, which is what `id_override`
	# and `title_text` are for: two of these in one stack is exactly the case that made
	# that setting configurable.
	var interface_screen := DotSettingsScreen.new()
	interface_screen.name = "Interface"
	interface_screen.id_override = &"interface"
	interface_screen.title_text = "Interface"
	interface_screen.half_size = Vector2(280.0, 220.0)

	var built_interface := interface_screen.build(ui_config)

	if built_interface.ok:
		stack.register(interface_screen)
	else:
		DotLog.result(CHANNEL, "the interface screen", built_interface)
		interface_screen.free()

	# The player's own settings, on dot-ui's shared screen rather than a fourth copy of
	# one. Optional, because a suite that drives the menus without a presentation layer is
	# a legitimate caller and the menu greys the button rather than opening nothing.
	if player_settings != null:
		var player_screen := DotSettingsScreen.new()
		player_screen.name = "Settings"

		var built := player_screen.build(player_settings)

		if built.ok:
			stack.register(player_screen)
		else:
			DotLog.result(CHANNEL, "the settings screen", built)
			player_screen.free()


	var controls := ControlsScreen.new()
	controls.name = "Controls"
	controls.build(ui_config)
	stack.register(controls)

	var scoreboard := ScoreboardScreen.new()
	scoreboard.name = "Scoreboard"
	scoreboard.build(game.match_node.scoreboard, link, game.match_node.teams)
	stack.register(scoreboard)

	# [b]Greyed rather than removed.[/b] A button that is absent on one build and present
	# on another is a menu whose shape a player cannot learn; one that is there and dimmed
	# says this client does not have that thing, which is the truth.
	note_screens(stack, pause)

	# Every button but Leave is about the stack and nothing else. What LEAVE means belongs
	# to the client -- an embedded one cannot leave and a single-process test must not --
	# so that one is left for the caller.
	pause.chosen.connect(func(id: StringName) -> void:
		match id:
			&"resume":
				stack.pop(&"pause")
			&"settings", &"interface", &"controls", &"servers":
				# The button id IS the screen id, which is what the label list buys: a
				# parallel table of "which button opens which screen" is two lists that can
				# disagree, and this one cannot. A screen that failed to build is absent
				# rather than empty, and its button is already greyed.
				if stack.screen(id) != null:
					stack.push(id)
	)

	return pause


## Re-checks which buttons have a screen behind them.
##
## [b]For `servers`, which is registered after [method install] returns.[/b] The browser is
## the one screen here that is about something other than this game, so the client builds it
## itself and only when its list came up -- which is after the menus exist. Without this the
## button would be greyed on a client that has a perfectly good server browser.
static func note_screens(stack: DotScreenStack, pause: DotPauseScreen) -> void:
	if stack == null or pause == null:
		return

	for id: StringName in pause.ids():
		var button := pause.button(id)

		if button == null or id in [&"resume", LEAVE]:
			continue

		button.disabled = stack.screen(id) == null
