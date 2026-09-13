extends Node

const ArenaBrowser := preload("res://game/arena_browser.gd")

## The server browser: dot-browser's client half, on a screen a player can open.
##
## [b]dot-server has answered queries since it was written and nothing had ever
## asked one.[/b] `ArenaModule` contributes a query provider, so a browser reading this
## server gets the mode, the map, the round and how far through it is — and until this
## file existed, the only thing in this family that could read it was a test. That is
## the family's own "produced correctly and consumed by nobody" with the ends swapped,
## and the answer is a client that asks.
##
## [b]Three protocols, and the reason there are three is deployment rather than
## taste.[/b] dot-browser speaks DQP over UDP for a desktop client, DQP as JSON over a
## WebSocket for a browser build — which cannot open a UDP socket at all — and A2S for
## the twenty years of trackers and tooling that speak nothing else.
## [constant DotBrowserTarget.Protocol.AUTO] picks, and it picks by asking
## [DotPlatform] what this build can do rather than by asking what platform it is on.
##
## [b]Filtering is local, and that is a rule rather than an optimisation.[/b] A server
## does not get to decide whether it appears in your list; you queried it, you hold the
## answer, and `DotBrowserFilter` runs over what you hold. A filter the server applied
## would be a filter the server could lie about.
##
## [codeblock]
## var browser := ArenaBrowser.new()
## add_child(browser)
## browser.setup()
## browser.add("play.example.com:27015")
## await browser.refresh()
## [/codeblock]

const CHANNEL := "arena.browser"

## The list changed: a refresh finished, or an entry answered.
signal listing_changed()

## The player asked to join one.
signal join_requested(entry: DotBrowserEntry)

@export_group("Querying")

## How many servers are asked at once.
@export_range(1, 64, 1) var concurrency: int = 8

@export_range(200, 15000, 100) var timeout_ms: int = 2500

@export_group("Favourites")

## Where favourites and history live. Empty keeps them in memory only.
@export var favourites_path: String = "user://arena/servers.json"

var browser: DotBrowser = null
var filter: DotBrowserFilter = null

var _started: bool = false


func setup() -> DotResult:
	if _started:
		return DotResult.success(self)

	browser = DotBrowser.new()
	browser.name = "Browser"
	browser.concurrency = concurrency
	browser.timeout_ms = timeout_ms
	browser.retries = 1
	# Info, players and the GAME section. Not rules: those are a server's whole cvar
	# table and a list does not draw them, so asking is a packet per server per refresh
	# for something nobody reads until they have picked one.
	#
	# [b]The game section is the reason `ArenaModule` has a query provider at all.[/b]
	# `info.map` is dot-server's, and dot-server means by it "the content id of the
	# game that is loaded" — which on a server that never `changegame`s is empty. What
	# a player wants to see is `dm_atrium`, and that is the game's own fact, which is
	# why it arrives under `rules["game"]` rather than overwriting `info.map`.
	# dot-browser nests it deliberately: flattening would collide the first time a
	# game put a field called `map` in it, which is the first time.
	browser.sections = PackedStringArray(["info", "players", "game"])
	browser.conditional = true
	browser.favourites_path = favourites_path
	browser.register_as = DotBrowser.SERVICE
	add_child(browser)

	var started := browser.start()

	if not started.ok:
		return started.wrap("The server browser could not start")

	filter = DotBrowserFilter.new()
	filter.online_only = true
	filter.sort = DotBrowserFilter.Sort.PLAYERS
	filter.favourites_first = true
	browser.filter = filter

	browser.refresh_finished.connect(
		func(_online: int, _total: int) -> void: listing_changed.emit()
	)
	browser.entry_updated.connect(
		func(_entry: DotBrowserEntry) -> void: listing_changed.emit()
	)

	# Whatever the player kept last time. Loaded rather than assumed empty, because a
	# browser that forgot your favourites every launch is one nobody uses twice.
	var loaded := browser.load_favourites()

	DotLog.info(CHANNEL, "the server browser is up", {"favourites": loaded})

	_started = true
	return DotResult.success(self)


## Adds a server by address: `host`, `host:port`, or an IPv6 `[::1]:27015`.
##
## [b]The query port is a separate argument and not a third field in the string.[/b]
## `DotBrowserTarget.parse` takes `host:port` and a three-part string parses as a
## malformed IPv6 address — which fails at `connect_to_host` with "Invalid IPv6
## address", several layers below anything that could say what was wrong.
##
## Zero means "ask the game port", which is what a server that has not moved its query
## listener does. dot-server's default moves it, so a caller that knows both passes
## both: a browser asking the game port of a server whose queries are elsewhere gets
## no answer, and reports it as offline.
func add(address: String, query_port: int = 0) -> DotResult:
	if browser == null:
		return DotResult.fail(DotError.CODE_STATE, "The browser is not up.")

	var parsed := DotBrowserTarget.parse(address, ArenaBrowser.default_port())

	if not parsed.ok:
		return parsed

	var target := parsed.value as DotBrowserTarget

	if query_port > 0:
		target.query_port = query_port

	var entry := browser.add_target(target)
	listing_changed.emit()

	return DotResult.success(entry)


## The port a bare host is assumed to be on.
##
## dot-server's own default, not the long-standing 27015. A list that guessed the wrong
## port would report every server on it as offline, which reads as the browser being
## broken.
static func default_port() -> int:
	return 27015


func refresh() -> DotResult:
	if browser == null:
		return DotResult.fail(DotError.CODE_STATE, "The browser is not up.")

	var res: DotResult = await browser.refresh()
	return res


## What the list should show, filtered and sorted the way the player asked.
func listing() -> Array[DotBrowserEntry]:
	return browser.filtered() if browser != null else []


func favourite(key: String, on: bool) -> void:
	if browser == null:
		return

	if on:
		browser.favourite(key)
	else:
		browser.unfavourite(key)

	listing_changed.emit()


## Records that the player joined one, so it lands in their history.
func note_connected(key: String) -> void:
	if browser != null:
		browser.note_connected(key)


## What the game says about itself, from the query's `game` section.
##
## [b]Not `entry.map`.[/b] That is dot-server's `info.map`, which means "the content id
## of the loaded game" and is empty on a server that has never switched games. The map
## a player wants to read is the game's own, and it arrives nested so it cannot
## overwrite the other.
static func game_field(entry: DotBrowserEntry, key: String, fallback: String = "") -> String:
	if entry == null:
		return fallback

	var section: Variant = entry.rules.get("game")

	if not (section is Dictionary):
		return fallback

	return str((section as Dictionary).get(key, fallback))


func describe_lines() -> PackedStringArray:
	return browser.describe_lines() if browser != null else PackedStringArray()


## The screen. A table, a filter box and two buttons.
##
## [b]Its own class rather than a section of [ArenaMenus], because it is the only
## screen in this game that is about something other than this game.[/b] Everything
## else there — pause, settings, controls, the scoreboard — reads an `ArenaGame`; this
## one reads a list of servers that may include none.
class BrowserScreen extends DotScreen:
	signal join_pressed(entry: DotBrowserEntry)

	var table: DotTableView = null
	var status: Label = null

	var _browser: ArenaBrowser = null
	var _rows: Array[DotBrowserEntry] = []

	func _screen_id() -> StringName:
		return &"servers"

	func build(p_browser: ArenaBrowser) -> void:
		_browser = p_browser

		hides_below = true
		blocks_input = true
		mouse_mode = DotScreen.Mouse.VISIBLE

		var panel := PanelContainer.new()
		panel.name = "Panel"
		panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		# [b]`set_anchors_preset` does not set offsets.[/b] A Control built in code
		# keeps the zero size it was created with, so the whole screen lays out inside
		# nothing and is invisible while being, by every property, correctly
		# configured. This family has shipped that twice and dot-ui had five of them.
		panel.offset_left = 40.0
		panel.offset_top = 40.0
		panel.offset_right = -40.0
		panel.offset_bottom = -40.0
		add_child(panel)

		var column := VBoxContainer.new()
		column.name = "Column"
		panel.add_child(column)

		var title := Label.new()
		title.text = "Servers"
		title.theme_type_variation = &"DotHeading"
		column.add_child(title)

		table = DotTableView.new()
		table.name = "Table"
		table.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var columns: Array[Dictionary] = [
			{"key": "name", "title": "Server", "width": 3.0},
			{"key": "map", "title": "Map", "width": 1.5},
			{"key": "players", "title": "Players", "width": 1.0},
			{"key": "ping", "title": "Ping", "width": 0.7},
		]
		table.set_columns(columns)
		column.add_child(table)

		status = Label.new()
		status.name = "Status"
		status.text = "Nothing yet. Refresh to look."
		column.add_child(status)

		var buttons := HBoxContainer.new()
		buttons.name = "Buttons"
		column.add_child(buttons)

		_button(buttons, "Refresh", _refresh)
		_button(buttons, "Join", _join)
		_button(buttons, "Close", func() -> void: close())

		# By name, not `get_path()`: this runs before the screen is registered with a
		# stack, so it is not in the tree and `get_path()` pushes an error and returns
		# nothing — after which the screen opens with nothing focused, which is
		# unusable with a gamepad and invisible with a mouse.
		initial_focus = NodePath("Panel/Column/Buttons/Refresh")

	func _button(into: Control, text: String, action: Callable) -> Button:
		var button := Button.new()
		button.name = text
		button.text = text
		button.pressed.connect(action)
		into.add_child(button)
		return button

	func _refresh() -> void:
		if _browser == null:
			return

		status.text = "Looking…"
		var done: DotResult = await _browser.refresh()
		status.text = "" if done.ok else done.error.message
		redraw()

	## Redraws the table from the browser's filtered listing.
	func redraw() -> void:
		if _browser == null or table == null:
			return

		_rows = _browser.listing()

		var rows: Array[Dictionary] = []

		for entry in _rows:
			rows.append({
				"name": entry.name,
				# The GAME's map, falling back to dot-server's info field. See
				# `game_field` — the two mean different things and the one a player
				# wants is the game's.
				"map": ArenaBrowser.game_field(entry, "map", entry.map),
				"players": "%d/%d" % [entry.players, entry.max_players],
				"ping": "%d" % entry.ping_ms if entry.is_online() else "-",
			})

		table.set_rows(rows)

		if _rows.is_empty():
			status.text = "No servers match. Try clearing the filter."

	func _join() -> void:
		if _rows.is_empty():
			return

		# The first row, because `DotTableView` is a view rather than a list control
		# and holds no selection. A real client puts a `Tree` here; what this proves
		# is the path from a query to a connection, which is the half that was
		# missing.
		join_pressed.emit(_rows[0])
