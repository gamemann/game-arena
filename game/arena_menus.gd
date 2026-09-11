class_name ArenaMenus
extends RefCounted

## The in-game menus: pause, settings, controls, scoreboard.
##
## [b]Four screens and about a hundred lines, because dot-ui does the hard part.[/b]
## The stack owns z-order, input blocking, mouse mode and the back key; the settings
## panel builds itself from a `DotConfig`; the rebinder handles conflicts and
## persistence. What is left is deciding which screens exist and what is on them,
## which is the part that is a game's own.

const CHANNEL := "arena.menus"


## The pause menu. Opaque, so the HUD goes away behind it.
class PauseScreen extends DotScreen:
	signal resume_pressed()
	signal settings_pressed()
	signal interface_pressed()
	signal controls_pressed()
	signal quit_pressed()

	func _screen_id() -> StringName:
		return &"pause"

	func build() -> void:
		hides_below = true
		blocks_input = true
		mouse_mode = DotScreen.Mouse.VISIBLE

		var panel := PanelContainer.new()
		panel.name = "Panel"
		panel.set_anchors_preset(Control.PRESET_CENTER)
		panel.offset_left = -160.0
		panel.offset_right = 160.0
		panel.offset_top = -160.0
		panel.offset_bottom = 160.0
		add_child(panel)

		var column := VBoxContainer.new()
		column.name = "Column"
		panel.add_child(column)

		var title := Label.new()
		title.text = "Paused"
		title.theme_type_variation = &"DotHeading"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(title)

		_add_button(column, "Resume", func() -> void: resume_pressed.emit())
		_add_button(column, "Settings", func() -> void: settings_pressed.emit())
		_add_button(column, "Interface", func() -> void: interface_pressed.emit())
		_add_button(column, "Controls", func() -> void: controls_pressed.emit())
		_add_button(column, "Leave", func() -> void: quit_pressed.emit())

		# Without this the menu opens with nothing focused and cannot be used with a
		# gamepad at all -- which is invisible to anyone testing with a mouse.
		#
		# A path by name, not `button.get_path()`: this runs before the screen is
		# registered with a stack, so it is not in the tree yet and get_path() pushes
		# an error and returns nothing.
		initial_focus = NodePath("Panel/Column/Resume")

	func _add_button(into: Control, text: String, action: Callable) -> Button:
		var button := Button.new()
		button.name = text
		button.text = text
		button.pressed.connect(action)
		into.add_child(button)
		return button


## The INTERFACE's own settings, generated from [DotUiConfig].
##
## [b]Registered as `interface`, not `settings`, and that rename is the point.[/b] This
## screen offers the scale, the safe area, the transition time and how many chat lines the
## HUD keeps — real settings, and not one of them is what a player means by the word. The
## volume, the field of view and the sensitivity live in the presentation layer's
## [code]DotSettingsManager[/code], and until `settings` pointed at that, a player who
## opened this menu to turn the game down found a slider for the interface scale.
##
## The panel reads the config's own `@export` annotations, so this screen never
## restates a setting and cannot drift from one.
class SettingsScreen extends DotScreen:
	var panel: DotSettingsPanel = null

	func _screen_id() -> StringName:
		return &"interface"

	func build(config: DotConfig) -> void:
		hides_below = false
		blocks_input = true

		var container := PanelContainer.new()
		container.set_anchors_preset(Control.PRESET_CENTER)
		container.offset_left = -280.0
		container.offset_right = 280.0
		container.offset_top = -220.0
		container.offset_bottom = 220.0
		add_child(container)

		var column := VBoxContainer.new()
		container.add_child(column)

		var title := Label.new()
		title.text = "Settings"
		title.theme_type_variation = &"DotHeading"
		column.add_child(title)

		panel = DotSettingsPanel.new()
		# Edits are held until Apply. A live panel would call validate() on a
		# half-edited config, which can legitimately be invalid on its way to being
		# valid.
		panel.live = false
		column.add_child(panel)
		panel.bind(config)

		var buttons := HBoxContainer.new()
		column.add_child(buttons)

		var apply := Button.new()
		apply.text = "Apply"
		apply.pressed.connect(func() -> void:
			var res := panel.apply()
			if not res.ok:
				DotLog.result(CHANNEL, "settings", res)
		)
		buttons.add_child(apply)

		var revert := Button.new()
		revert.text = "Revert"
		revert.pressed.connect(panel.revert)
		buttons.add_child(revert)

		var back := Button.new()
		back.text = "Back"
		back.pressed.connect(close)
		buttons.add_child(back)


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
		# `dot_fps_`, not `arena_`, and the difference is the whole screen.
		#
		# `prefix` filters the InputMap, and THERE HAS NEVER BEEN AN `arena_` ACTION. This
		# game's bindable actions are the movement ones, registered by
		# `DotFpsSampler.register_default_actions` in `ArenaClient._build_interface` and
		# therefore named `dot_fps_forward`, `dot_fps_jump` and so on. Everything else this
		# client reads -- fire, reload, the scoreboard -- is matched on a keycode in
		# `_unhandled_input` and is not an action at all.
		#
		# So the rebinder listed nothing, for the whole life of this screen: a Controls
		# menu with a title, a Defaults button, a Back button and no controls. Nothing
		# errored, because a filter that matches nothing is a legitimate filter and an
		# empty list is a legitimate list. A rendered frame is what showed it.
		#
		# game-hungario's `hungry_` is correct by contrast -- `HungryInput._register_actions`
		# really does create `hungry_split`, `hungry_throw` and the rest.
		panel.prefix = "dot_fps_"
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
class ScoreboardScreen extends DotScreen:
	var table: DotTableView = null

	var _board: DotScoreboard = null
	var _me: String = ""

	func _screen_id() -> StringName:
		return &"scoreboard"

	func build(board: DotScoreboard) -> void:
		_board = board
		blocks_input = false
		hides_below = false
		closable = true
		mouse_mode = DotScreen.Mouse.INHERIT

		var container := PanelContainer.new()
		container.set_anchors_preset(Control.PRESET_CENTER)
		container.offset_left = -340.0
		container.offset_right = 340.0
		container.offset_top = -200.0
		container.offset_bottom = 200.0
		add_child(container)

		table = DotTableView.new()
		table.max_rows = 32
		container.add_child(table)
		table.set_columns(DotTableView.scoreboard_columns())

	func follow(key: String) -> void:
		_me = key

	func _on_push() -> void:
		refresh()

	func refresh() -> void:
		if _board == null or table == null:
			return

		var rows: Array[Dictionary] = []

		for record in _board.ranked():
			if not record.present:
				continue

			rows.append({
				&"name": record.display_name,
				&"kills": record.kills,
				&"deaths": record.deaths,
				&"assists": record.assists,
				&"score": record.score,
				&"ping": 0,
				"highlight": record.key == _me,
			})

		table.set_rows(rows)


## Registers all four screens with a stack and wires the buttons that navigate.
##
## Returns the pause screen, because that is the one a game opens.
static func install(
	stack: DotScreenStack,
	game: ArenaGame,
	ui_config: DotUiConfig,
	player_settings: Object = null
) -> PauseScreen:
	var pause := PauseScreen.new()
	pause.name = "Pause"
	pause.build()
	stack.register(pause)

	var interface_screen := SettingsScreen.new()
	interface_screen.name = "Interface"
	interface_screen.build(ui_config)
	stack.register(interface_screen)

	# The player's own settings, on dot-ui's shared screen rather than a fourth copy of
	# one. Optional, because a suite that drives the menus without a presentation layer is
	# a legitimate caller and the menu greys the button rather than opening nothing.
	if player_settings != null:
		var player_screen := DotSettingsScreen.new()
		player_screen.name = "Settings"

		var built := player_screen.build(player_settings)

		if built.ok:
			stack.register(player_screen)
			pause.settings_pressed.connect(func() -> void: stack.push(&"settings"))
		else:
			DotLog.result(CHANNEL, "the settings screen", built)
			player_screen.free()
			var button := pause.get_node_or_null("Panel/Column/Settings") as Button
			if button != null:
				button.disabled = true
	else:
		var button := pause.get_node_or_null("Panel/Column/Settings") as Button
		if button != null:
			button.disabled = true

	var controls := ControlsScreen.new()
	controls.name = "Controls"
	controls.build(ui_config)
	stack.register(controls)

	var scoreboard := ScoreboardScreen.new()
	scoreboard.name = "Scoreboard"
	scoreboard.build(game.match_node.scoreboard)
	stack.register(scoreboard)

	pause.resume_pressed.connect(func() -> void: stack.pop(&"pause"))
	pause.interface_pressed.connect(func() -> void: stack.push(&"interface"))
	pause.controls_pressed.connect(func() -> void: stack.push(&"controls"))

	return pause
