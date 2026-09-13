extends SceneTree

const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMenus := preload("../game/arena_menus.gd")

## Renders this game's own screens to `screenshots/` so a person can look at them.
##
## [b]Separate from `screenshot.gd`, which renders MAPS.[/b] A map wants a camera framing
## a world and a menu wants a viewport-sized stack with nothing behind it; one script that
## did both would spend most of itself deciding which it was doing.
##
## The screens here are the ones dot-ui does NOT own: this game's pause menu, its controls
## rebinder and its scoreboard. dot-ui's own `tools/screenshot.sh` covers `DotPauseScreen`
## and `DotSettingsScreen`, and rendering those again here would be a second picture of the
## same code.
##
## Run through `tools/screenshot_menus.sh`. [b]Not `--headless`[/b]: that gives a null
## renderer, a 64 x 64 viewport, and every frame it saves is empty — which is worse than no
## screenshot because it looks like one.

const OUT_DIR := "res://screenshots"
const SETTLE := 3

var _stack: DotScreenStack = null
var _hud: ArenaHud = null
var _chat: DotChatWindow = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_stack = DotScreenStack.new()
	_stack.name = "Stack"
	_stack.register_service = false
	_stack.manage_mouse = false
	_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_stack)
	_stack.setup()

	# The movement actions, because the Controls screen filters the InputMap on `dot_fps_`
	# and an empty InputMap draws an empty rebinder -- which is indistinguishable in a
	# picture from the bug this tool found, where the filter named a prefix nothing used.
	# `ArenaClient` calls the same function; this is the same state a player is in.
	DotFpsSampler.register_default_actions()

	# And this game's own two, which `ArenaPresentation._build_chat` creates in a real
	# session. The Controls screen filters on `dot_fps_` AND `arena_`, so a fixture that
	# registered only the movement would draw a rebinder that is missing exactly the
	# actions the second prefix was added for.
	DotInputBinding.ensure_action(&"arena_chat", "Y")
	DotInputBinding.ensure_action(&"arena_chat_team", "U")

	var ui_config := DotUiConfig.new()

	var pause := ArenaMenus.PauseScreen.new()
	pause.name = "Pause"
	pause.build()
	_stack.register(pause)

	var controls := ArenaMenus.ControlsScreen.new()
	controls.name = "Controls"
	controls.build(ui_config)
	_stack.register(controls)

	# A scoreboard with names of the length a real one has, and a row that is the local
	# player, because a highlight that reads at "bo" and not at a real handle is the kind
	# of thing only a picture shows.
	var board := DotScoreboard.new()
	var names := [
		"gamemann", "a_very_long_display_name", "bo", "quiet_one", "newcomer",
	]

	for i in names.size():
		var key := "p%d" % (i + 1)
		board.join(key, names[i])

		# Through the real scoring calls rather than by writing the fields, because a
		# picture of numbers assigned by hand is a picture of an assignment. Each player
		# kills the one below them a few times and dies to the one above.
		for _k in range((names.size() - i) * 2):
			board.note_kill(key, "p%d" % (i + 2), 0)

		board.note_assist(key, 0, 0)

	var scoreboard := ArenaMenus.ScoreboardScreen.new()
	scoreboard.name = "Scoreboard"
	scoreboard.build(board)
	scoreboard.set("_me", "p1")
	_stack.register(scoreboard)

	_build_hud()

	_shots = [
		{"id": &"pause", "file": "menu_pause.png"},
		{"id": &"controls", "file": "menu_controls.png"},
		{"id": &"scoreboard", "file": "menu_scoreboard.png"},
		# Nothing pushed, so what is drawn is the HUD and the chat box over it. This one
		# is about where they are relative to EACH OTHER: the box sits in the same corner
		# as health and armour, and at the default inset it draws its log through both.
		{"id": &"", "file": "hud_chat.png"},
	]


## This game's own HUD, with the chat box over it, both at the real offsets.
func _build_hud() -> void:
	_hud = ArenaHud.new()
	_hud.name = "Hud"
	# Assigned rather than left to `DotHud._ready` to fill in: nothing added during
	# `SceneTree._initialize` is inside the tree yet, so no `_ready` has run and
	# `ArenaHud.build` would read `config.feed_lines` off a null.
	_hud.config = DotUiConfig.new()
	root.add_child(_hud)
	_hud.build(null)

	_chat = DotChatWindow.new()
	_chat.name = "Chat"
	_chat.register_actions = false
	# Nothing expires in a screenshot: under software rendering a frame takes the better
	# part of a second, so a lifetime is spent before the grab and the picture is of an
	# empty log — which looks exactly like a log that cannot draw.
	_chat.lifetime_sec = 0.0
	_chat.margin_left = 24.0
	_chat.margin_bottom = 110.0
	_chat.channels = [
		{"id": &"all", "label": "Say", "colour": Color(0.88, 0.90, 0.94)},
		{"id": &"team", "label": "Say (TEAM)", "colour": Color(0.55, 0.85, 0.60), "team": true},
	]
	_hud.add_child(_chat)

	_chat.add_text("Welcome to the server.", Color(0.80, 0.82, 0.86))
	_chat.add_said("gamemann", "anybody up for a round on the atrium map?")
	_chat.add_said(
		"a_very_long_display_name",
		"a line long enough to have to wrap, which is the ordinary case in chat"
	)
	_chat.add_said("quiet_one", "rotating B, need one more", Color(0.55, 0.85, 0.60))
	_chat.open(&"team")


func _process(_delta: float) -> bool:
	if _done:
		return true

	if _at >= _shots.size():
		_done = true
		return false

	var shot: Dictionary = _shots[_at]

	if _wait == SETTLE:
		_stack.clear()

		if str(shot["id"]) == "":
			# The HUD frame: nothing on the stack, so the HUD below it is what draws.
			_wait -= 1
			return false

		var opened := _stack.push(StringName(shot["id"]))

		if not opened.ok:
			# Said out loud rather than saved as a grey rectangle. A screen registered
			# under a name nothing pushes is exactly the bug this tool found in dot-ui,
			# and a picture of an empty viewport is indistinguishable from a renderer
			# that is not working.
			push_error("could not open '%s': %s" % [shot["id"], opened.error.message])
			_at += 1
			return false

	if _wait > 0:
		_wait -= 1
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join(str(shot["file"]))
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_at += 1
	_wait = SETTLE
	return false
